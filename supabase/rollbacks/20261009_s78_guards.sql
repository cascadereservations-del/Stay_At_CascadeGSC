-- Compensating rollback for 20261009020000_s78_guards.sql: drops calendar_events_direct_no_overlap, restores
-- run_system_verifier_v1 (md5(replace(prosrc, chr(13), '')) 471e8af96bbdc4259b98665deeecc738, the s78_small_sql_20261009
-- body this release was applied on) and
-- apply_verifier_run_v1 (490973908baae36a34908f6efd702936), and drops booking_submit_allowed_v1 and booking_submit_attempts
-- (hashed request counts only). Ship the submit-booking rollback first: s78 submit-booking calls booking_submit_allowed_v1,
-- though it lets a request through when the call fails. btree_gist stays installed (harmless, nothing else uses it).
-- Once V8 leaves the scope arrays no run resolves an open V8 finding, so the last statement closes them here.
begin;

alter table public.calendar_events drop constraint if exists calendar_events_direct_no_overlap;

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
      -- s77 (TASKS #24): an Airbnb block that calendar-sync labelled as the mirror of THIS direct stay
      -- (block_reason 'direct', note 'DIR <first 8 of the booking id> ...') is our own block, not a second
      -- stay. coalesce: a uid that is not a direct uid never hides a pair.
      and not coalesce(
            (a.source = 'airbnb' and a.status = 'blocked' and a.block_reason = 'direct' and b.source = 'direct'
               and position(upper(left(public.stay_uid_inquiry_v1(b.uid)::text, 8)) in upper(coalesce(a.block_note, ''))) > 0)
         or (b.source = 'airbnb' and b.status = 'blocked' and b.block_reason = 'direct' and a.source = 'direct'
               and position(upper(left(public.stay_uid_inquiry_v1(a.uid)::text, 8)) in upper(coalesce(b.block_note, ''))) > 0),
          false)
  ), '[]'::jsonb);

  -- V1m - that mirror block runs past the direct stay, so nights show taken on Airbnb with no guest
  -- (Angel 2026-10-08: block Oct 8-12, stay Oct 8-11). Yellow, check_id V1 so both scopes resolve it.
  -- Dates and ids only, so an acknowledgement holds until a date moves.
  -- ponytail: one block mirroring two back-to-back direct stays would flag here; split the block, or add
  -- a not-exists over the other direct stays if that ever happens.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V1m:' || m.id::text,
      'check_id', 'V1',
      'severity', 'yellow',
      'title',    'Airbnb block runs past the direct stay',
      'detail',   jsonb_build_object(
        'block', m.id, 'stay', s.id, 'uid', s.uid, 'guest', s.guest_name,
        'stay_from', s.checkin_date, 'stay_to', s.checkout_date,
        'block_from', m.checkin_date, 'block_to', m.checkout_date)))
    from public.calendar_events m
    join public.calendar_events s
      on s.property_id = m.property_id
     and s.source = 'direct' and s.status <> 'cancelled'
     and s.checkin_date < m.checkout_date and m.checkin_date < s.checkout_date
     and position(upper(left(public.stay_uid_inquiry_v1(s.uid)::text, 8)) in upper(coalesce(m.block_note, ''))) > 0
    where m.property_id = p_property_id
      and m.source = 'airbnb' and m.status = 'blocked' and m.block_reason = 'direct'
      and m.checkout_date > p_now::date
      and (m.checkin_date < s.checkin_date or m.checkout_date > s.checkout_date)
  ), '[]'::jsonb);

  -- V2 - a confirmed direct booking with no live calendar row. Red: the nights
  -- are still sellable to somebody else.
  -- s77: the uid is direct:<id> while a hold and cascade-direct-<id> once confirmed (inquiry_one_tap renames
  -- it); stay_uid_inquiry_v1 reads both. Matching only direct: raised V2 and V3 on Angel's confirmed stay.
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
        where public.stay_uid_inquiry_v1(c.uid) = b.id and c.status <> 'cancelled')
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
        'inquiry_status', (select b.status from public.booking_inquiries b where b.id = public.stay_uid_inquiry_v1(c.uid)),
        'auto_safe', (c.status = 'blocked' and exists (
           select 1 from public.booking_inquiries b
           where b.id = public.stay_uid_inquiry_v1(c.uid) and b.status in ('expired', 'cancelled'))))))
    from public.calendar_events c
    where c.property_id = p_property_id
      and c.source = 'direct'
      and c.status <> 'cancelled'
      and c.checkout_date > p_now::date
      and not exists (
        select 1 from public.booking_inquiries b
        where b.id = public.stay_uid_inquiry_v1(c.uid) and b.status in ('pending', 'confirmed'))
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

  -- V7 - a calendar row and the reservation it is linked to disagree on dates (D-225, D-235).
  -- The Airbnb calendar is the primary record. When both rows are confirmed (auto_safe),
  -- apply_verifier_run_v1 corrects the reservation's dates from the calendar and closes this.
  -- Detail carries dates and ids only, so an acknowledgement holds until a date changes (D-217.2).
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V7:' || ar.confirmation_code,
      'check_id', 'V7',
      'severity', 'yellow',
      'title',    'Calendar and reservation disagree on dates',
      'detail',   jsonb_build_object(
        'code', ar.confirmation_code, 'guest', ar.guest_name, 'reservation', ar.id,
        'email_from', ar.checkin_date, 'email_to', ar.checkout_date,
        'calendar_from', ce.checkin_date, 'calendar_to', ce.checkout_date,
        'event', ce.id,
        'auto_safe', (ar.status = 'confirmed' and ce.status = 'confirmed'))))
    from public.calendar_events ce
    join public.airbnb_reservations ar on ar.id = ce.linked_reservation_id
    where ce.property_id = p_property_id
      and ce.source = 'airbnb' and ce.status <> 'cancelled'
      and ar.status <> 'cancelled'
      and ce.checkout_date >= (p_now at time zone 'Asia/Manila')::date - 1
      and (ce.checkin_date is distinct from ar.checkin_date or ce.checkout_date is distinct from ar.checkout_date)
  ), '[]'::jsonb);

  -- V7b - an Airbnb stay on the calendar with no booking e-mail behind it after 24 hours (D-235.2).
  -- The feed carries the confirmation code, so the link is exact; no link means the corroborating
  -- e-mail never arrived or was never parsed. It closes itself when calendar-sync makes the link.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V7b:' || ce.uid,
      'check_id', 'V7b',
      'severity', 'yellow',
      'title',    'Airbnb stay with no booking e-mail',
      'detail',   jsonb_build_object(
        'uid', ce.uid, 'code', substring(ce.raw_description from 'reservations/details/([A-Z0-9]{10})'),
        'from', ce.checkin_date, 'to', ce.checkout_date, 'since', ce.created_at)))
    from public.calendar_events ce
    where ce.property_id = p_property_id
      and ce.source = 'airbnb' and ce.status = 'confirmed'
      and ce.linked_reservation_id is null
      and ce.raw_description ~ 'reservations/details/[A-Z0-9]{10}'
      and ce.created_at < p_now - interval '24 hours'
      and ce.checkout_date >= (p_now at time zone 'Asia/Manila')::date - 1
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
        -- D-232 (supersedes D-213 for checkouts_cleaned): a missing cleaning report is
        -- missed-cleaning-alert's job in OPS, so here it is yellow like every other warn.
        'severity', case when h.status = 'fail' then 'red' else 'yellow' end,
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
  'SPEC-11 checks V1-V7b, V10, V11, V12 (V13 is raised by the Edge Function). Reads only, stores nothing, decides nothing about alerting. V1 skips our own Airbnb mirror of a direct stay and raises V1m (yellow, detail carries the stay uid) when that block runs past the stay; V2/V3 read direct:<id> and cascade-direct-<id>. V7 is yellow and auto-corrected when both rows are confirmed (D-235); checkouts_cleaned is yellow on warn (D-232). service_role only.';

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
    -- V13 (model budget) is raised by the system-verifier Edge Function in both scopes (D-227).
    -- V14-V18 (API governor, D-294) are raised by the Edge Function in the daily scope; V14-V15 hourly too (urgent).
    when 'hourly' then array['V1','V2','V3','V4','V5','V7','V7b','V11','V12','V13','V14','V15']
    else                array['V1','V2','V3','V4','V5','V6','V7','V7b','V10','V11','V12','V13','V14','V15','V16','V17','V18']
  end;

  -- Everything seen in this run: insert it, or mark it seen again. A finding
  -- that has been acknowledged stays acknowledged unless its shape changed,
  -- which is what the design's detail->>'n' comparison is for; here the whole
  -- detail is compared, because these checks carry ids rather than a count.
  for r in select value as v from jsonb_array_elements(p_found) loop
    -- An ALREADY-ACCEPTED finding is born acknowledged and never alerts. Only
    -- V10 sets detail.accepted, and only for K16's ledger_duplicates n=2. The
    -- on-conflict branch below still flips it back to open the moment the
    -- detail changes, which is what makes this safe: accepting a shape is not
    -- accepting the check forever.
    insert into public.verifier_findings as f
      (key, check_id, severity, title, detail, status, first_seen, last_seen)
    values (r.v->>'key', r.v->>'check_id', r.v->>'severity', r.v->>'title',
            coalesce(r.v->'detail', '{}'::jsonb),
            case when coalesce(r.v->'detail'->>'accepted', '') = 'true'
                 then 'acknowledged' else 'open' end,
            p_now, p_now)
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

  -- Auto-resolution 3 (D-235): the Airbnb calendar is the primary record. A confirmed reservation
  -- whose dates disagree with its confirmed calendar row takes the calendar's dates (nights is generated
  -- from them). Money is never touched: the payout e-mail reconciles it, and payout_totals_agree judges it.
  for r in
    select f.key, (f.detail->>'reservation')::uuid as res_id,
           (f.detail->>'calendar_from')::date as cal_from, (f.detail->>'calendar_to')::date as cal_to,
           (f.detail->>'email_from')::date as em_from, (f.detail->>'email_to')::date as em_to
      from public.verifier_findings f
     where f.check_id = 'V7' and f.status = 'open'
       and f.last_seen = p_now
       and (f.detail->>'auto_safe')::boolean is true
  loop
    update public.airbnb_reservations
       set checkin_date = r.cal_from, checkout_date = r.cal_to
     where id = r.res_id and status = 'confirmed';
    if found then
      update public.verifier_findings
         set status = 'resolved', resolved_at = p_now, resolved_by = 'auto',
             detail = detail || jsonb_build_object('auto', format(
               'The Airbnb calendar is the primary record, so the reservation dates were corrected from it: %s to %s became %s to %s.',
               coalesce(to_char(r.em_from, 'Mon FMDD'), 'no date'), coalesce(to_char(r.em_to, 'Mon FMDD'), 'no date'),
               to_char(r.cal_from, 'Mon FMDD'), to_char(r.cal_to, 'Mon FMDD')))
       where key = r.key;
      v_resolved := v_resolved || jsonb_build_array(jsonb_build_object('key', r.key, 'title', 'Reservation dates corrected from the Airbnb calendar', 'auto', true));
    end if;
  end loop;

  -- V7b is a weekly line plus ONE Follow-ups task per stay (D-218); the task closes itself below.
  for r in
    select f.detail->>'uid' as uid, f.detail->>'code' as code, f.detail->>'from' as d_from, f.detail->>'to' as d_to
      from public.verifier_findings f
     where f.check_id = 'V7b' and f.status = 'open' and f.last_seen = p_now
  loop
    perform public.system_task_open_v1(
      (select ce.property_id from public.calendar_events ce where ce.uid = r.uid limit 1),
      'airbnb_unmatched', r.uid,
      'Find the booking e-mail for Airbnb ' || coalesce(r.code, 'stay') || ' (' || r.d_from || ' to ' || r.d_to || ')',
      'The Airbnb calendar shows this stay but no booking e-mail matched it in 24 hours. Check the cascadereservations inbox, or the reservation on Airbnb.',
      'normal');
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

  perform public.system_task_close_missing_v1('airbnb_unmatched',
    array(select f.detail->>'uid' from public.verifier_findings f where f.check_id = 'V7b' and f.status in ('open', 'acknowledged')),
    null, 'Closed automatically: the booking e-mail arrived and the stay is linked.');

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
  'Records a verifier run: what is new, what is due a reminder, what has gone. Performs the three safe auto-resolutions (V3 ghost hold, V4 dead flow, V7 reservation dates from the Airbnb calendar) and keeps one task per V7b. Resolves only checks the given scope ran (V14-V18, the API governor checks, run in the daily scope). An accepted finding (K16) is born acknowledged. service_role only.';

drop function if exists public.booking_submit_allowed_v1(text, integer);
drop table if exists public.booking_submit_attempts;

update public.verifier_findings
   set status = 'resolved', resolved_at = now(), resolved_by = 'rollback'
 where check_id = 'V8' and status in ('open', 'acknowledged');

commit;
