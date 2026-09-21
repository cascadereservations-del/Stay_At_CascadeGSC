-- Compensating rollback for release health_checks_core_v10_20260921
--   20260921020000_health_checks_core.sql
--   20260921030000_verifier_v10.sql
--
-- ORDER MATTERS ONLY ONE WAY. If the system-verifier Edge Function has already
-- been deployed and scheduled (SPEC-11 session 2), unschedule its two cron jobs
-- first: the daily one calls run_health_checks_service_v1, which this drops.
-- Before session 2 there is no caller at all and this can be run as it stands.
--
-- What comes back: run_health_checks_v1 with its original sixty-line body,
-- restored byte-for-byte from 20260916150000_admin_overview_handoffs_open.sql
-- lines 109-199, which was verified identical to the deployed function on
-- 2026-09-21 (md5(prosrc) 527fb1e6054d4858310f2c32d0493f33, 9982 bytes, both
-- sides). The dashboard's System health button is therefore exactly what it was.
--
-- run_system_verifier_v1 and apply_verifier_run_v1 go back to their phase-1
-- text, restored the same way from 20260921010000_system_verifier_phase1.sql.
-- V1-V6, V11 and V12 keep working; only V10 stops existing.
--
-- Open V10 findings ARE deleted, and only those. They are machine-derived from
-- admin_health_check_runs, which this does not touch, so re-applying re-raises
-- whatever is still true. Findings from every other check are left alone.

begin;

-- 1. The verifier, back to phase 1 -------------------------------------------
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

  return jsonb_build_object('scope', p_scope, 'ran_at', p_now, 'found', v_found);
end;
$function$;

revoke all on function public.run_system_verifier_v1(uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public.run_system_verifier_v1(uuid, text, timestamptz) to service_role;

comment on function public.run_system_verifier_v1(uuid, text, timestamptz) is
  'SPEC-11 phase 1 checks V1-V6, V11, V12. Reads only, stores nothing, decides nothing about alerting. service_role only.';


create or replace function public.apply_verifier_run_v1(
  p_scope text,
  p_found jsonb,
  p_now   timestamptz default now()
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_checks text[];
  v_new      jsonb := '[]'::jsonb;
  v_remind   jsonb := '[]'::jsonb;
  v_resolved jsonb := '[]'::jsonb;
  r record;
begin
  if p_scope not in ('hourly', 'daily') then
    raise exception 'scope must be hourly or daily' using errcode = '22023';
  end if;
  if p_found is null or jsonb_typeof(p_found) <> 'array' then
    raise exception 'p_found must be a json array' using errcode = '22023';
  end if;

  v_checks := case p_scope
    when 'hourly' then array['V1','V2','V3','V4','V5','V11','V12']
    else                array['V1','V2','V3','V4','V5','V6','V11','V12']
  end;

  -- Everything seen in this run: insert it, or mark it seen again. A finding
  -- that has been acknowledged stays acknowledged unless its shape changed,
  -- which is what the design's detail->>'n' comparison is for; here the whole
  -- detail is compared, because these checks carry ids rather than a count.
  for r in select value as v from jsonb_array_elements(p_found) loop
    insert into public.verifier_findings as f
      (key, check_id, severity, title, detail, first_seen, last_seen)
    values (r.v->>'key', r.v->>'check_id', r.v->>'severity', r.v->>'title',
            coalesce(r.v->'detail', '{}'::jsonb), p_now, p_now)
    on conflict (key) do update
      set last_seen = p_now,
          severity  = excluded.severity,
          title     = excluded.title,
          detail    = excluded.detail,
          status    = case
                        when f.status = 'resolved' then 'open'
                        when f.status = 'acknowledged' and f.detail <> excluded.detail then 'open'
                        else f.status
                      end,
          resolved_at = null,
          resolved_by = null;
  end loop;

  -- Auto-resolution 1: a ghost hold whose inquiry is already expired or
  -- cancelled. This writes exactly what expire_booking_holds_v1 writes, on
  -- exactly the rows it would have written to, and nothing else.
  for r in
    select f.key, (f.detail->>'event')::uuid as event_id
      from public.verifier_findings f
     where f.check_id = 'V3' and f.status = 'open'
       and f.last_seen = p_now
       and (f.detail->>'auto_safe')::boolean is true
  loop
    update public.calendar_events set status = 'cancelled'
     where id = r.event_id and status = 'blocked';
    if found then
      update public.verifier_findings
         set status = 'resolved', resolved_at = p_now, resolved_by = 'auto',
             detail = detail || jsonb_build_object('auto', 'The booking behind this hold had already expired, so the hold was cancelled the same way the hold releaser would have.')
       where key = r.key;
      v_resolved := v_resolved || jsonb_build_array(jsonb_build_object('key', r.key, 'title', 'Calendar hold with no live booking behind it', 'auto', true));
    end if;
  end loop;

  -- Auto-resolution 2: a stuck Messenger flow whose booking is already dead.
  -- The thread carries no booking id, so the match is the guest's e-mail AND
  -- both dates, and all three must be present. No match means no change: the
  -- safe direction is always to leave the flow alone and tell a person.
  for r in
    select f.key, f.detail->>'psid' as psid
      from public.verifier_findings f
     where f.check_id = 'V4' and f.status = 'open'
       and f.last_seen = p_now
       and coalesce(f.detail->>'email', '') <> ''
       and coalesce(f.detail->>'from', '')  <> ''
       and coalesce(f.detail->>'to', '')    <> ''
       and exists (
         select 1 from public.booking_inquiries b
          where lower(b.guest_email) = lower(f.detail->>'email')
            and b.checkin_date  = (f.detail->>'from')::date
            and b.checkout_date = (f.detail->>'to')::date
            and b.status in ('expired', 'cancelled'))
  loop
    update public.concierge_threads
       set booking_flow = booking_flow || jsonb_build_object('step', 'cancelled', 'updated_at', p_now)
     where psid = r.psid;
    if found then
      update public.verifier_findings
         set status = 'resolved', resolved_at = p_now, resolved_by = 'auto',
             detail = detail || jsonb_build_object('auto', 'The booking this conversation was waiting on had already expired, so the flow was closed and the guest can start again.')
       where key = r.key;
      v_resolved := v_resolved || jsonb_build_array(jsonb_build_object('key', r.key, 'title', 'Messenger booking stuck at the payment step', 'auto', true));
    end if;
  end loop;

  -- Gone: open findings of a check this scope ran, that this run did not see.
  for r in
    update public.verifier_findings f
       set status = 'resolved', resolved_at = p_now, resolved_by = 'auto'
     where f.status in ('open', 'acknowledged')
       and f.check_id = any (v_checks)
       and f.last_seen < p_now
    returning f.key, f.title, f.severity
  loop
    v_resolved := v_resolved || jsonb_build_array(jsonb_build_object('key', r.key, 'title', r.title, 'auto', false));
  end loop;

  -- Worth saying out loud: never alerted, or alerted long enough ago to be
  -- worth repeating. Acknowledged findings are never reminded about; that is
  -- the whole point of the button.
  for r in
    update public.verifier_findings f
       set last_alerted_at = p_now
     where f.status = 'open'
       and f.last_seen = p_now
       and (f.last_alerted_at is null
            or f.last_alerted_at < p_now - (case when f.severity = 'red' then interval '24 hours' else interval '7 days' end))
    returning f.key, f.check_id, f.severity, f.title, f.detail, f.first_seen
  loop
    if r.first_seen = p_now then
      v_new := v_new || jsonb_build_array(jsonb_build_object('key', r.key, 'check_id', r.check_id, 'severity', r.severity, 'title', r.title, 'detail', r.detail));
    else
      v_remind := v_remind || jsonb_build_array(jsonb_build_object('key', r.key, 'check_id', r.check_id, 'severity', r.severity, 'title', r.title, 'detail', r.detail));
    end if;
  end loop;

  return jsonb_build_object('new', v_new, 'remind', v_remind, 'resolved', v_resolved);
end;
$function$;

revoke all on function public.apply_verifier_run_v1(text, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_verifier_run_v1(text, jsonb, timestamptz) to service_role;

comment on function public.apply_verifier_run_v1(text, jsonb, timestamptz) is
  'Records a verifier run: what is new, what is due a reminder, what has gone. Performs the two safe auto-resolutions. Resolves only checks the given scope actually ran. service_role only.';

-- 4. Known, stop reminding ---------------------------------------------------

-- 2. The health checks, back to one function ---------------------------------
create or replace function public.run_health_checks_v1(p_property_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_today date; v_fin boolean; v_hc record; v_out jsonb := '[]'::jsonb; v_checks jsonb := '[]'::jsonb;
begin
  perform public.admin_require('read_operations', p_property_id);
  v_fin := public.current_staff_authorized('read_finance', p_property_id);
  v_today := public.manila_today();

  -- Ledger ↔ reservations: every confirmed payout e-mail names its stay.
  v_checks := v_checks || (select jsonb_build_object('k', 'payout_rows_linked', 'l', 'Payout e-mails linked to a stay', 's', case when count(*) = 0 then 'pass' else 'fail' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'ref', t.external_ref, 'date', t.transaction_date, 'amount', t.gross_amount)) filter (where t.id is not null), '[]'::jsonb))
  from (select * from public.transactions where property_id = p_property_id and source = 'airbnb_payout_email' and status = 'confirmed' and reservation_id is null limit 20) t);

  -- Reservations ↔ payouts: every completed stay has a confirmed payout row.
  v_checks := v_checks || (select jsonb_build_object('k', 'completed_stays_paid', 'l', 'Completed stays with a payout row', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('code', rr.confirmation_code, 'guest', rr.guest_name, 'checkout', rr.checkout_date, 'payout', rr.host_payout)) filter (where rr.id is not null), '[]'::jsonb))
  from (select * from public.airbnb_reservations x where x.property_id = p_property_id and x.status = 'completed' and x.checkout_date < v_today
        and not exists (select 1 from public.transactions t where t.reservation_id = x.id and t.source = 'airbnb_payout_email' and t.status = 'confirmed') limit 20) rr);

  -- Payout totals: Σ reservation payout_amount = Σ payout e-mails + Σ Airbnb adjustments.
  v_checks := v_checks || (select jsonb_build_object('k', 'payout_totals_agree', 'l', 'Reservation payouts equal payout e-mails plus adjustments', 's', case when abs(d.diff) < 1 then 'pass' else 'warn' end, 'n', 0, 'd',
    jsonb_build_object('reservationPayouts', d.res, 'payoutEmails', d.em, 'adjustments', d.adj, 'difference', d.diff))
  from (select res, em, adj, res - em - adj diff from (
    select (select coalesce(sum(payout_amount), 0) from public.airbnb_reservations where property_id = p_property_id and payout_amount is not null) res,
           (select coalesce(sum(gross_amount), 0) from public.transactions where property_id = p_property_id and source = 'airbnb_payout_email' and status = 'confirmed') em,
           (select coalesce(sum(gross_amount), 0) from public.transactions where property_id = p_property_id and source = 'airbnb' and txn_type = 'expense' and category = 'airbnb_adjustment' and status = 'confirmed') adj) x) d);

  -- Cleaning log ↔ stays: a checkout in the last 90 days has a cleaning within three days.
  v_checks := v_checks || (select jsonb_build_object('k', 'checkouts_cleaned', 'l', 'Checkouts (90 days) followed by a cleaning', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('code', s.confirmation_code, 'guest', s.guest_name, 'checkout', s.checkout_date)) filter (where s.id is not null), '[]'::jsonb))
  from (select * from public.airbnb_reservations x where x.property_id = p_property_id and x.status = 'completed' and x.checkout_date >= v_today - 90 and x.checkout_date < v_today
        and not exists (select 1 from public.cleaning_sessions c where c.property_id = p_property_id and (c.checkout_date = x.checkout_date or (c.cleaned_at::date between x.checkout_date and x.checkout_date + 3))) limit 20) s);

  -- Cleaning log ↔ ledger: every fee owed is settled by a live transaction.
  if v_fin then
    v_checks := v_checks || (select jsonb_build_object('k', 'cleaner_fees_settled', 'l', 'Cleaning fees settled in the ledger', 's', case when count(*) = 0 then 'pass' else 'fail' end, 'n', count(*)::int, 'd',
      coalesce(jsonb_agg(jsonb_build_object('session', c.id, 'guest', c.last_guest_name, 'cleaned', c.cleaned_at::date, 'fee', c.fee_amount)) filter (where c.id is not null), '[]'::jsonb))
    from (select * from public.cleaning_sessions x where x.property_id = p_property_id and coalesce(x.fee_amount, 0) > 0
          and (x.fee_paid_at is null or x.fee_txn_id is null or not exists (select 1 from public.transactions t where t.id = x.fee_txn_id and t.status <> 'void')) limit 20) c);
  end if;

  -- Meter readings: first entries and negative re-entries carry a review flag.
  v_checks := v_checks || (select jsonb_build_object('k', 'meter_readings_reviewed', 'l', 'Odd meter readings reviewed', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'session', m.session_id, 'recorded', m.recorded_at::date, 'electricDelta', m.electric_delta, 'waterDelta', m.water_delta)) filter (where m.id is not null), '[]'::jsonb))
  from (select * from public.meter_readings x where x.property_id = p_property_id and x.meter_flag is null
        and (coalesce(x.electric_prev, 0) = 0 or coalesce(x.water_prev, 0) = 0 or coalesce(x.electric_delta, 0) < 0 or coalesce(x.water_delta, 0) < 0) limit 20) m);

  -- Inventory: ledger-controlled items agree with their last movement; nothing negative.
  v_checks := v_checks || (select jsonb_build_object('k', 'inventory_ledger_consistent', 'l', 'Inventory quantities agree with movements', 's', case when count(*) = 0 then 'pass' else 'fail' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('item', i.name, 'onHand', i.qty_on_hand, 'lastMovement', i.last_after)) filter (where i.id is not null), '[]'::jsonb))
  from (select x.id, x.name, x.qty_on_hand, (select quantity_after from public.inventory_stock_movements m where m.item_id = x.id order by sequence_no desc limit 1) last_after
        from public.inventory_items x where x.property_id = p_property_id and x.is_active) i
  where i.qty_on_hand < 0 or (i.last_after is not null and i.last_after <> i.qty_on_hand));

  if v_fin then
    -- Ledger: duplicate live rows (same date, amount, payee, type, source).
    v_checks := v_checks || (select jsonb_build_object('k', 'ledger_duplicates', 'l', 'Duplicate ledger rows', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
      coalesce(jsonb_agg(jsonb_build_object('date', g.transaction_date, 'amount', g.gross_amount, 'payee', g.payee, 'n', g.n)), '[]'::jsonb))
    from (select transaction_date, gross_amount, coalesce(payee_name, '') payee, count(*) n from public.transactions
          where property_id = p_property_id and status <> 'void' and source not in ('airbnb','airbnb_email')
          group by transaction_date, gross_amount, coalesce(payee_name, ''), txn_type, source having count(*) > 1 limit 20) g);

    -- Ledger position: income − expenses − drawings on confirmed, non-mirror rows.
    v_checks := v_checks || (select jsonb_build_object('k', 'ledger_position', 'l', 'Cash position: income − expenses − drawings', 's', case when abs(p.net) < 1 then 'pass' else 'warn' end, 'n', 0, 'd',
      jsonb_build_object('income', p.inc, 'expenses', p.exp, 'drawings', p.drw, 'net', p.net, 'asOf', v_today))
    from (select inc, exp, drw, inc - exp - drw net from (
      select coalesce(sum(gross_amount) filter (where txn_type = 'income'), 0) inc, coalesce(sum(gross_amount) filter (where txn_type = 'expense'), 0) exp, coalesce(sum(gross_amount) filter (where txn_type = 'drawing'), 0) drw
      from public.transactions where property_id = p_property_id and status = 'confirmed' and source not in ('airbnb','airbnb_email') and transaction_date <= v_today) x) p);

    -- Journals: every posted journal balances.
    v_checks := v_checks || (select jsonb_build_object('k', 'journals_balanced', 'l', 'Posted journals balance', 's', case when count(*) = 0 then 'pass' else 'fail' end, 'n', count(*)::int, 'd',
      coalesce(jsonb_agg(jsonb_build_object('journalNo', j.journal_no, 'debits', j.d, 'credits', j.c)), '[]'::jsonb))
    from (select j.journal_no, sum(l.debit) d, sum(l.credit) c from public.acct_journals j join public.acct_journal_lines l on l.journal_id = j.id
          where j.property_id = p_property_id and j.status = 'posted' group by j.journal_no having sum(l.debit) <> sum(l.credit) limit 20) j);
  end if;

  -- Messenger handoffs (Sprint 0, 2026-09-16): open cards a human has not answered. Counted here
  -- so a status-literal drift (the 'pending' bug fixed in this release) shows up in System health.
  v_checks := v_checks || (select jsonb_build_object('k', 'concierge_handoffs_open', 'l', 'Messenger handoffs awaiting a human reply', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'guest', h.guest_name, 'risk', h.risk, 'created', h.created_at)) filter (where h.id is not null), '[]'::jsonb))
  from (select * from public.concierge_handoffs x where x.status = 'open' order by x.created_at desc limit 20) h);

  for v_hc in select e->>'k' k, e->>'l' l, e->>'s' s, (e->>'n')::int n, e->'d' d from jsonb_array_elements(v_checks) e loop
    insert into public.admin_health_check_runs(property_id, check_key, label, status, count, detail, ran_at, ran_by)
    values (p_property_id, v_hc.k, v_hc.l, v_hc.s, v_hc.n, v_hc.d, now(), auth.uid())
    on conflict (property_id, check_key) do update set label = excluded.label, status = excluded.status, count = excluded.count, detail = excluded.detail, ran_at = excluded.ran_at, ran_by = excluded.ran_by;
  end loop;
  select coalesce(jsonb_agg(to_jsonb(h) order by h.check_key), '[]'::jsonb) into v_out from public.admin_health_check_runs h where h.property_id = p_property_id and (v_fin or h.check_key not in ('cleaner_fees_settled','ledger_duplicates','ledger_position','journals_balanced'));
  return jsonb_build_object('ranAt', now(), 'checks', v_out);
end;
$$;

revoke all on function public.run_health_checks_v1(uuid) from public;
revoke all on function public.run_health_checks_v1(uuid) from anon;
grant execute on function public.run_health_checks_v1(uuid) to authenticated;

drop function if exists public.run_health_checks_service_v1(uuid);
drop function if exists public.health_checks_core_v1(uuid, boolean);

-- 3. The findings V10 raised --------------------------------------------------
delete from public.verifier_findings where check_id = 'V10';

commit;
