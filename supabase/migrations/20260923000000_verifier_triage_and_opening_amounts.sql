-- 20260923000000_verifier_triage_and_opening_amounts.sql
-- Session 44 (Opus 5): the SQL half of SPEC-18 step 3, SPEC-19 step 4 and SPEC-20 steps 1 and 4
-- (D-211, D-213, D-216). The TypeScript half is live since 2026-09-22 22:44Z.
--
-- Both functions below are restated in full because create or replace has no other form. Neither body
-- was retyped: each was cut from its applied migration by a script that first asserted the cut hashes to
-- the live md5(prosrc) (run_system_verifier_v1 178b72de3f830cc7a2ab7acd0d7711bb, approve_opening_balances_v1
-- c63e53a873439c1b7a5a95f7c060f88f, both read 2026-09-22), then applied exact one-hit replacements.
--
-- run_system_verifier_v1:
--   * V10:stale is red. It means every V10 check has gone silent.
--   * checkouts_cleaned is red when any listed checkout is on or after the Manila date 72 hours ago.
--   * title is the problem phrase from health_check_problem_v1, never the passing label (D-209, F2).
--     The label is kept in detail.label.
--   * detail no longer carries ran_at. The daily run refreshes the health checks first, so ran_at moved
--     every night, apply_verifier_run_v1 saw a changed detail, and every acknowledged V10 finding
--     reopened after one day - K16 included (found this session). The first run after this release sees
--     the new shape once and reopens acknowledged V10 rows one last time; acknowledge them after it.
--
-- approve_opening_balances_v1: refuses a line with neither a debit nor a credit (SPEC-19 step 4).
-- Of the four coalesce(..., 0) the spec names, this is the only one that could post without an amount:
-- post_journal_v1 (lines 296, 312) already raises on such a line through its "exactly one positive side"
-- rule, and save_opening_balance_batch_v1 (line 438) only reports totals. The pgTAP proves both.
--
-- job_heartbeats.last_succeeded_at defaults to now(), so a row seeded before its cron exists is born
-- alive instead of raising JOB_NEVER_SUCCEEDED (two false alerts on 2026-09-21). A job that then never
-- runs still alerts, as JOB_HEARTBEAT_STALE after its interval. An explicit null is still stored as null.

begin;

-- 1. One problem phrase per health check. Mirrors SUBJECT in waves
--    supabase/functions/_shared/cascade-core/health-labels.ts, sentence-cased; the pgTAP pins all eleven.
create or replace function public.health_check_problem_v1(p_check_key text)
returns text
language sql
immutable
set search_path to ''
as $function$
  select case p_check_key
    when 'payout_rows_linked'          then 'Payout e-mail not linked to a stay'
    when 'completed_stays_paid'        then 'Completed stay with no payout'
    when 'payout_totals_agree'         then 'Payout totals disagree'
    when 'checkouts_cleaned'           then 'Checkout with no cleaning logged'
    when 'cleaner_fees_settled'        then 'Cleaning fee not settled'
    when 'meter_readings_reviewed'     then 'Meter readings to review'
    when 'inventory_ledger_consistent' then 'Inventory count disagrees with its movements'
    when 'ledger_duplicates'           then 'Duplicate ledger rows'
    when 'ledger_position'             then 'Cash position does not balance'
    when 'journals_balanced'           then 'Journal does not balance'
    when 'concierge_handoffs_open'     then 'Guest handoff waiting'
    else 'System health check ' || replace(coalesce(p_check_key, 'unknown'), '_', ' ') || ' needs a look'
  end
$function$;

revoke all on function public.health_check_problem_v1(text) from public, anon, authenticated;
grant execute on function public.health_check_problem_v1(text) to service_role;

-- 2. The checks ---------------------------------------------------------------
create or replace function public.run_system_verifier_v1(
  p_property_id uuid,
  p_scope       text default 'hourly',
  p_now         timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_found jsonb := '[]'::jsonb;
  v_daily boolean := (p_scope = 'daily');
  v_sync  timestamptz;
  v_mode  text;
  v_mode_since timestamptz;
  v_hc_ran timestamptz;
begin
  if p_scope not in ('hourly', 'daily') then
    raise exception 'scope must be hourly or daily' using errcode = '22023';
  end if;

  -- V1 - two non-cancelled stays overlap. Red: a guest is at the door.
  -- The pair is keyed by both ids in a fixed order, so the same overlap seen
  -- from either side is one finding and not two.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V1:' || least(a.id, b.id)::text || ':' || greatest(a.id, b.id)::text,
      'check_id', 'V1',
      'severity', 'red',
      'title',    'Two stays overlap',
      'detail',   jsonb_build_object(
        'a', jsonb_build_object('id', a.id, 'source', a.source, 'guest', a.guest_name, 'from', a.checkin_date, 'to', a.checkout_date, 'status', a.status),
        'b', jsonb_build_object('id', b.id, 'source', b.source, 'guest', b.guest_name, 'from', b.checkin_date, 'to', b.checkout_date, 'status', b.status))))
    from public.calendar_events a
    join public.calendar_events b
      on a.id < b.id
     and a.property_id = b.property_id
     and a.checkin_date < b.checkout_date
     and b.checkin_date < a.checkout_date
    where a.property_id = p_property_id
      and a.status <> 'cancelled' and b.status <> 'cancelled'
      and a.checkout_date > p_now::date
  ), '[]'::jsonb);

  -- V2 - a confirmed direct booking with no live calendar row. Red: the nights
  -- are still sellable to somebody else.
  -- calendar_events carries no booking id column; the link is the uid, written
  -- as direct:<booking id> by submit-booking and read exactly that way by
  -- expire_booking_holds_v1. That is an exact join, not the date match the
  -- design fell back to.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V2:' || b.id::text,
      'check_id', 'V2',
      'severity', 'red',
      'title',    'Confirmed booking with no calendar block',
      'detail',   jsonb_build_object('booking', b.id, 'guest', b.guest_name, 'from', b.checkin_date, 'to', b.checkout_date)))
    from public.booking_inquiries b
    where b.property_id = p_property_id
      and b.status = 'confirmed'
      and b.checkout_date > p_now::date
      and not exists (
        select 1 from public.calendar_events c
        where c.uid = 'direct:' || b.id::text and c.status <> 'cancelled')
  ), '[]'::jsonb);

  -- V3 - a direct hold with nothing live behind it, hiding sellable nights.
  -- detail.auto_safe says whether an existing, tested function would already
  -- have cancelled this row: it would, when the inquiry itself is expired or
  -- cancelled, because that is exactly what expire_booking_holds_v1 does. A
  -- hold with NO inquiry at all may be a date somebody blocked by hand, so it
  -- waits for a person.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V3:' || c.id::text,
      'check_id', 'V3',
      'severity', 'yellow',
      'title',    'Calendar hold with no live booking behind it',
      'detail',   jsonb_build_object(
        'event', c.id, 'uid', c.uid, 'guest', c.guest_name, 'from', c.checkin_date, 'to', c.checkout_date,
        'inquiry_status', (select b.status from public.booking_inquiries b where 'direct:' || b.id::text = c.uid),
        'auto_safe', (c.status = 'blocked' and exists (
           select 1 from public.booking_inquiries b
           where 'direct:' || b.id::text = c.uid and b.status in ('expired', 'cancelled'))))))
    from public.calendar_events c
    where c.property_id = p_property_id
      and c.source = 'direct'
      and c.status <> 'cancelled'
      and c.checkout_date > p_now::date
      and not exists (
        select 1 from public.booking_inquiries b
        where 'direct:' || b.id::text = c.uid and b.status in ('pending', 'confirmed'))
  ), '[]'::jsonb);

  -- V4 - a Concierge booking flow stuck at the money step for over 6 hours.
  -- concierge_threads is not property-scoped; there is one property.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V4:' || t.psid,
      'check_id', 'V4',
      'severity', 'yellow',
      'title',    'Messenger booking stuck at the payment step',
      'detail',   jsonb_build_object(
        'psid', t.psid, 'guest', t.guest_name, 'step', t.booking_flow->>'step',
        'since', t.booking_flow->>'updated_at',
        'email', t.booking_flow->>'email',
        'from',  t.booking_flow->>'checkin',
        'to',    t.booking_flow->>'checkout')))
    from public.concierge_threads t
    where t.booking_flow->>'step' in ('await_receipt', 'receipt_sent')
      and (t.booking_flow->>'updated_at')::timestamptz < p_now - interval '6 hours'
  ), '[]'::jsonb);

  -- V5 - a guest question nobody has answered in 12 hours.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V5:' || h.id::text,
      'check_id', 'V5',
      'severity', 'yellow',
      'title',    'Guest handoff open over 12 hours',
      'detail',   jsonb_build_object('id', h.id, 'guest', h.guest_name, 'risk', h.risk, 'since', h.created_at, 'asked', left(coalesce(h.guest_text, ''), 200))))
    from public.concierge_handoffs h
    where h.status = 'open' and h.created_at < p_now - interval '12 hours'
  ), '[]'::jsonb);

  -- V6 - arriving within three days with no ID on file. Daily only: it is a
  -- this-week job, and raising it every hour would be noise.
  if v_daily then
    v_found := v_found || coalesce((
      select jsonb_agg(jsonb_build_object(
        'key',      'V6:' || b.id::text,
        'check_id', 'V6',
        'severity', 'yellow',
        'title',    'Arriving soon with no ID on file',
        'detail',   jsonb_build_object('booking', b.id, 'guest', b.guest_name, 'arrives', b.checkin_date)))
      from public.booking_inquiries b
      where b.property_id = p_property_id
        and b.status = 'confirmed'
        and b.checkin_date >= p_now::date
        and b.checkin_date <= p_now::date + 3
        and not exists (
          select 1 from public.guest_profile_details g
          where g.guest_id = b.guest_id and g.id_on_file is true)
    ), '[]'::jsonb);
  end if;

  -- V11 - the Concierge has been off auto for over two hours. A singleton key:
  -- it is one condition, not one per row.
  -- app_settings.value is JSONB, so s.value::text is "auto" WITH the quotes and
  -- would never equal 'auto'. Written the obvious way, this check raised a
  -- permanent yellow against a Concierge that was on auto the whole time; CI
  -- caught it because migration 20260911000000 seeds the setting as "suggest".
  -- #>> '{}' unwraps a jsonb scalar to its text, which is the only comparison
  -- that is right for both.
  select s.value #>> '{}', s.updated_at into v_mode, v_mode_since
    from public.app_settings s where s.key = 'concierge_mode';
  if v_mode is not null and v_mode <> 'auto' and v_mode_since < p_now - interval '2 hours' then
    v_found := v_found || jsonb_build_array(jsonb_build_object(
      'key', 'V11', 'check_id', 'V11', 'severity', 'yellow',
      'title', 'Concierge is not on auto',
      'detail', jsonb_build_object('mode', v_mode, 'since', v_mode_since)));
  end if;

  -- V12 - the Airbnb feed has gone quiet. Red: a booking landing now would be
  -- invisible, and B36 makes the reaper abort without telling anyone.
  -- The status literal is 'ok'. It is NOT 'success' - read against production
  -- on 2026-09-21, where 3513 rows are 'ok' and 95 are 'error'. The design's
  -- literal was wrong and this check would have alerted on a healthy feed.
  select max(l.synced_at) into v_sync
    from public.calendar_sync_log l
   where l.property_id = p_property_id
     and l.source = 'airbnb' and l.status = 'ok' and coalesce(l.event_count, 0) > 0;
  if v_sync is null or v_sync < p_now - interval '3 hours' then
    v_found := v_found || jsonb_build_array(jsonb_build_object(
      'key', 'V12', 'check_id', 'V12', 'severity', 'red',
      'title', 'Airbnb feed has gone quiet',
      'detail', jsonb_build_object('last_good_sync', v_sync)));
  end if;

  -- V10 - the ten System health checks, once a day. Severity is the check's
  -- own: fail is red, warn is yellow.
  --
  -- This READS admin_health_check_runs rather than calling
  -- run_health_checks_service_v1, and the difference matters. The health checks
  -- persist their result, so the table IS the answer; calling the function from
  -- here would make this function a writer, which would break two things it
  -- promises - that it is `stable`, and that ?dry=1 has no side effect at all.
  -- The system-verifier Edge Function calls run_health_checks_service_v1 first
  -- on the daily scope, so what this reads is minutes old. If that call is ever
  -- lost, V10:stale below says so out loud instead of quietly reporting a run
  -- from last week. (Production's stored run was seven days old when this was
  -- written, which is exactly how that failure looks.)
  if v_daily then
    select max(h.ran_at) into v_hc_ran
      from public.admin_health_check_runs h where h.property_id = p_property_id;

    if v_hc_ran is null or v_hc_ran < p_now - interval '36 hours' then
      v_found := v_found || jsonb_build_array(jsonb_build_object(
        'key', 'V10:stale', 'check_id', 'V10', 'severity', 'red',
        'title', 'System health has not been run',
        'detail', jsonb_build_object('last_run', v_hc_ran)));
    end if;

    v_found := v_found || coalesce((
      select jsonb_agg(jsonb_build_object(
        'key',      'V10:' || h.check_key,
        'check_id', 'V10',
        'severity', case when h.status = 'fail' then 'red'
                         -- D-213: a checkout (Manila date) inside the last 72 hours with no
                         -- cleaning is today's work, not a list item.
                         when h.check_key = 'checkouts_cleaned' and exists (
                           select 1 from jsonb_array_elements(
                               case when jsonb_typeof(h.detail) = 'array' then h.detail else '[]'::jsonb end) e
                            where e->>'checkout' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                              and (e->>'checkout')::date >= ((p_now at time zone 'Asia/Manila') - interval '72 hours')::date)
                           then 'red'
                         else 'yellow' end,
        'title',    public.health_check_problem_v1(h.check_key),
        'detail',   jsonb_build_object(
                      'check', h.check_key, 'status', h.status, 'n', h.count,
                      'label', h.label, 'd', h.detail)
                    -- K16: ledger_duplicates n=2 is explained, not broken. Both
                    -- pairs were gone through on 2026-09-14 (D-124) and left as
                    -- they are. Stored acknowledged by apply_verifier_run_v1, so
                    -- it never alerts unless the count moves off 2.
                    || case when h.check_key = 'ledger_duplicates' and h.count = 2
                            then jsonb_build_object('accepted', true, 'note',
                              'Both duplicate pairs were checked on 2026-09-14 and are legitimate. This will alert only if the count changes.')
                            else '{}'::jsonb end))
      from public.admin_health_check_runs h
      where h.property_id = p_property_id and h.status <> 'pass'
    ), '[]'::jsonb);
  end if;

  return jsonb_build_object('scope', p_scope, 'ran_at', p_now, 'found', v_found);
end;
$function$;

revoke all on function public.run_system_verifier_v1(uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public.run_system_verifier_v1(uuid, text, timestamptz) to service_role;

comment on function public.run_system_verifier_v1(uuid, text, timestamptz) is
  'SPEC-11 checks V1-V6, V10, V11, V12. Reads only, stores nothing, decides nothing about alerting. V10 titles are problem phrases; checkouts_cleaned inside 72 h and V10:stale are red (D-213). service_role only.';

-- 3. Opening balances refuse a line with no amount ----------------------------
create or replace function public.approve_opening_balances_v1(p_batch_id uuid, p_review_note text, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare b public.acct_opening_balance_batches%rowtype; v_debit numeric; v_credit numeric; v_res jsonb; v_lines jsonb;
begin
  select * into b from public.acct_opening_balance_batches where id = p_batch_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'batch not found'; end if;
  perform public.acct_require_post(b.property_id);
  if b.status = 'approved' then return jsonb_build_object('ok', true, 'replayed', true, 'journalId', b.journal_id); end if;
  if exists (select 1 from public.acct_settings s where s.property_id = b.property_id and s.opening_batch_id is not null) then raise exception using errcode = '23505', message = 'opening balances are already approved for this property'; end if;
  if nullif(btrim(coalesce(b.reference_notes, '')), '') is null then raise exception using errcode = '22023', message = 'supporting references are required before approval'; end if;
  -- SPEC-19 (D-211): a line with no debit and no credit at all is a dropped or renamed amount. The sums
  -- below would count it as 0 and the filter before posting would drop it, so the batch posted without it.
  -- An empty string is the form's own 'not this side' and still passes.
  if exists (select 1 from jsonb_array_elements(b.lines) x where x->>'debit' is null and x->>'credit' is null) then
    raise exception using errcode = '22023', message = 'an opening balance line has no debit or credit amount; nothing was posted';
  end if;
  select coalesce(sum(coalesce(nullif(x->>'debit', '')::numeric, 0)), 0), coalesce(sum(coalesce(nullif(x->>'credit', '')::numeric, 0)), 0) into v_debit, v_credit from jsonb_array_elements(b.lines) x;
  if v_debit = 0 and v_credit = 0 then raise exception using errcode = '22023', message = 'no balances entered'; end if;
  if v_debit <> v_credit then raise exception using errcode = '22023', message = format('opening balances do not balance (difference %s); resolve it, the system will not invent a balancing figure', v_debit - v_credit); end if;
  insert into public.acct_settings(property_id, accounting_start) values (b.property_id, b.accounting_start) on conflict (property_id) do update set accounting_start = excluded.accounting_start, updated_at = now();
  insert into public.acct_periods(property_id, period_start) values (b.property_id, b.accounting_start) on conflict do nothing;
  select jsonb_agg((x - 'memo') || jsonb_build_object('memo', 'Opening balance: ' || coalesce(x->>'memo', ''))) into v_lines from jsonb_array_elements(b.lines) x where coalesce(nullif(x->>'debit', '')::numeric, 0) > 0 or coalesce(nullif(x->>'credit', '')::numeric, 0) > 0;
  v_res := public.post_journal_v1(b.property_id, b.accounting_start, 'Opening balances as at ' || b.accounting_start::text, v_lines, 'acct_opening_balance_batches', b.id::text, 'opening_balance', b.reference_notes, p_idempotency_key, null);
  update public.acct_opening_balance_batches set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), review_note = p_review_note, journal_id = (v_res->>'journalId')::uuid, version = version + 1 where id = b.id;
  update public.acct_settings set opening_batch_id = b.id where property_id = b.property_id;
  return v_res || jsonb_build_object('batchId', b.id, 'accountingStart', b.accounting_start);
end;
$$;
revoke all on function public.approve_opening_balances_v1(uuid, text, text) from public, anon, service_role;
grant execute on function public.approve_opening_balances_v1(uuid, text, text) to authenticated;

-- 4. Seeded heartbeats are born alive -----------------------------------------
alter table public.job_heartbeats alter column last_succeeded_at set default now();

commit;
