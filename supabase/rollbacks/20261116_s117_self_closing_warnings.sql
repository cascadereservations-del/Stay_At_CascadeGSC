-- Rollback of 20261116000000_s117_self_closing_warnings.sql (release s117_self_closing_warnings_20261116).
-- Puts the s115 bodies of run_system_verifier_v1 and apply_verifier_run_v1 and the s91 bodies of health_checks_core_v1 and kpi_recompute_v1 back, the OmniRoute cap back to 0.5 (only while 0.15), (each guarded by the md5 of the s117 body, CR stripped), drops the two s117 functions,
-- and renames 'Kettle / Water Heater' back to 'Heater (Heatek)' only while that name is unchanged and the old name is free. Tasks the sweep closed stay closed (they were true when closed).
begin;

do $$
begin
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.run_system_verifier_v1(uuid,text,timestamp with time zone)')) is distinct from 'bb709544080df0208be141673daeb5d6' then
    raise exception 's117 rollback: public.run_system_verifier_v1(uuid,text,timestamp with time zone) is not the s117 body (md5 %): re-cut it from the live body',
      (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.run_system_verifier_v1(uuid,text,timestamp with time zone)')) using errcode = '55000';
  end if;
end $$;

do $$
begin
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.apply_verifier_run_v1(text,jsonb,timestamp with time zone)')) is distinct from 'efc09d51a134419b8825e74a78d53345' then
    raise exception 's117 rollback: public.apply_verifier_run_v1(text,jsonb,timestamp with time zone) is not the s117 body (md5 %): re-cut it from the live body',
      (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.apply_verifier_run_v1(text,jsonb,timestamp with time zone)')) using errcode = '55000';
  end if;
end $$;

do $$
begin
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.health_checks_core_v1(uuid,boolean)')) is distinct from '8fa278d109b83976fa07dc06c5d19826' then
    raise exception 's117 rollback: public.health_checks_core_v1(uuid,boolean) is not the s117 body (md5 %): re-cut it from the live body',
      (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.health_checks_core_v1(uuid,boolean)')) using errcode = '55000';
  end if;
end $$;

do $$
begin
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.kpi_recompute_v1(uuid,date,date)')) is distinct from '9a3b117e1aeed18cbbbc9d5503998b38' then
    raise exception 's117 rollback: public.kpi_recompute_v1(uuid,date,date) is not the s117 body (md5 %): re-cut it from the live body',
      (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.kpi_recompute_v1(uuid,date,date)')) using errcode = '55000';
  end if;
end $$;

create or replace function public.apply_verifier_run_v1(p_scope text, p_found jsonb, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $body$
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
    -- V8 (receipt reused on two live bookings, s78) runs in both scopes, so a finding that is gone resolves either way.
    -- V19 (month KPIs against the raw books, s91) is raised by run_system_verifier_v1 in the daily scope only.
    -- s115: V20 (pay records vs calendar and reports) and V22 (paid API credit gone) are raised by run_system_verifier_v1 in both scopes, V21 (calendar vs reservations) in the daily scope.
    when 'hourly' then array['V1','V2','V3','V4','V5','V7','V7b','V8','V11','V12','V13','V14','V15','V20','V22','V23']
    else                array['V1','V2','V3','V4','V5','V6','V7','V7b','V8','V10','V11','V12','V13','V14','V15','V16','V17','V18','V19','V20','V21','V22','V23']
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

  -- s115: an acknowledged RED finding that is still being seen re-opens after 3 days, so one old "Mark handled" cannot hide an outage for good (the alert step then re-announces it).
  -- The alert step below then sends it again (red repeats after 24 hours). Yellow stays acknowledged; an accepted finding (acknowledged_at null) is untouched.
  update public.verifier_findings f set status = 'open'
   where f.status = 'acknowledged' and f.severity = 'red' and f.last_seen = p_now and f.acknowledged_at < p_now - interval '3 days';

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
$body$
;
revoke all on function public.apply_verifier_run_v1(text,jsonb,timestamp with time zone) from public, anon, authenticated;
grant execute on function public.apply_verifier_run_v1(text,jsonb,timestamp with time zone) to service_role;

create or replace function public.run_system_verifier_v1(p_property_id uuid, p_scope text DEFAULT 'hourly'::text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $body$
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
      and (m.checkin_date < s.checkin_date - greatest(coalesce((select case when jsonb_typeof(a.value) = 'number' then floor((a.value #>> '{}')::numeric)::integer end
                         from public.app_settings a where a.key = 'airbnb_prep_nights'), 1), 0)
           or m.checkout_date > s.checkout_date + greatest(coalesce((select case when jsonb_typeof(a.value) = 'number' then floor((a.value #>> '{}')::numeric)::integer end
                         from public.app_settings a where a.key = 'airbnb_prep_nights'), 1), 0))
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

  -- V8 - one receipt is evidence on two live bookings (s78, TASKS #20; DESIGN-conflict-verifier V8). Red: one payment
  -- may be counted for two stays. SPEC-44 refuses only a TYPED reference already seen on another booking, at the
  -- paid-outside confirm. This catches the rest: the same uploaded image (content_hash; Messenger receipts reach the same
  -- table through upload-booking-receipt), a reference read off a receipt on one booking and read or typed on another,
  -- and - when one side has no reference - the same amount uploaded within 30 minutes of each other.
  -- Both bookings must still be live (pending or confirmed) and one of them not yet checked out: a guest who resent the
  -- same receipt after their hold lapsed is an honest resend and stays quiet. One finding per pair of bookings, keyed by
  -- both ids in a fixed order. Detail is ids, dates, statuses and the match only, so an acknowledgement holds until one
  -- of those moves (a pending booking that gets confirmed re-opens it, on purpose).
  -- manual_evidence hashes are derived from the one-tap key, never from an image, so they never match as an image.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V8:' || p.a_id::text || ':' || p.b_id::text,
      'check_id', 'V8',
      'severity', 'red',
      'title',    'One receipt on two bookings',
      'detail',   jsonb_build_object(
        'match',     to_jsonb(p.matches),
        'reference', p.reference,
        'amount',    p.amount,
        'a', jsonb_build_object('booking', ba.id, 'guest', ba.guest_name, 'status', ba.status, 'from', ba.checkin_date, 'to', ba.checkout_date),
        'b', jsonb_build_object('booking', bb.id, 'guest', bb.guest_name, 'status', bb.status, 'from', bb.checkin_date, 'to', bb.checkout_date)))
      order by p.a_id, p.b_id)
    from (
      select x.booking_id as a_id, y.booking_id as b_id,
             array_agg(distinct case
               when x.content_hash = y.content_hash
                    and x.source_type <> 'manual_evidence' and y.source_type <> 'manual_evidence' then 'image'
               when x.normalized_reference = y.normalized_reference then 'reference'
               else 'amount_time' end) as matches,
             max(x.normalized_reference) filter (where x.normalized_reference = y.normalized_reference) as reference,
             max(coalesce(x.normalized_amount, y.normalized_amount)) as amount
        from public.payment_evidence_candidates x
        join public.payment_evidence_candidates y
          on y.property_id = x.property_id
         and x.booking_id < y.booking_id
         and (   (x.content_hash = y.content_hash
                  and x.source_type <> 'manual_evidence' and y.source_type <> 'manual_evidence')
              or x.normalized_reference = y.normalized_reference
              or (x.source_type = 'receipt_ocr' and y.source_type = 'receipt_ocr'
                  and x.normalized_amount = y.normalized_amount
                  and (x.normalized_reference is null or y.normalized_reference is null)
                  and x.observed_at between y.observed_at - interval '30 minutes' and y.observed_at + interval '30 minutes'))
       where x.property_id = p_property_id
       group by x.booking_id, y.booking_id
    ) p
    join public.booking_inquiries ba on ba.id = p.a_id
    join public.booking_inquiries bb on bb.id = p.b_id
    where ba.status in ('pending', 'confirmed') and bb.status in ('pending', 'confirmed')
      and greatest(ba.checkout_date, bb.checkout_date) > p_now::date
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

  -- s91 V19 begin
  -- V19 - the month KPIs against a second count from the raw books (docs/s91/KPI-AUDIT.md 3.3). Daily only; the current Manila month and the
  -- three before. Red: a headline number differs; yellow: finance summary, cleaner fees, or a hygiene count. audience: Finance group (D-306).
  if v_daily then
    v_found := v_found || public.kpi_reconcile_window_v1(p_property_id, (p_now at time zone 'Asia/Manila')::date);
  end if;
  -- s91 V19 end

  -- s115 V20 begin
  -- V20 - pay records against the calendar and the reports (docs/s115/PLAN.md 5). Both scopes. Keys carry ids last; detail is ids, dates and names only,
  -- so an acknowledgement holds until one of them moves. audience: Finance group, except report_no_stay (OPS).
  -- advance_no_stay: a live paid-ahead line for a date that is no confirmed checkout (the 6FF96A06 case: a cancelled booking's blocked row).
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V20:advance_no_stay:' || q.ref || ':' || a.d,
      'check_id', 'V20',
      'severity', 'red',
      'title',    'Paid-ahead line is for a date with no confirmed checkout',
      'detail',   jsonb_build_object('ref', q.ref, 'date', a.d, 'payee', q.payee_name)))
    from public.staff_pay_requests q
    cross join lateral (select (l.value ->> 'checkout_date')::date as d from jsonb_array_elements(q.lines) l where l.value ->> 'kind' = 'advance') a
    where q.property_id = p_property_id and q.status <> 'cancelled' and q.created_at > p_now - interval '90 days' and a.d is not null
      and not exists (select 1 from public.calendar_events ce
                       where ce.property_id = q.property_id and ce.status = 'confirmed' and ce.checkout_date = a.d)
  ), '[]'::jsonb);

  -- paid_no_link: paid ahead more than 3 days ago, no report linked to the line, and the payee has a report within a day of that date that is on no paid request.
  -- report_date is that report's checkout date (contract amendment 1), so the card can say which date the report on file is for.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V20:paid_no_link:' || q.ref || ':' || a.d,
      'check_id', 'V20',
      'severity', 'red',
      'title',    'Paid ahead, but the report on file is for another date',
      'detail',   jsonb_build_object('ref', q.ref, 'date', a.d, 'payee', q.payee_name, 'session', s.id, 'report_date', s.checkout_date)))
    from public.staff_pay_requests q
    cross join lateral (select (l.value ->> 'checkout_date')::date as d from jsonb_array_elements(q.lines) l where l.value ->> 'kind' = 'advance') a
    cross join lateral (
      select cs.id, cs.checkout_date
        from public.cleaning_sessions cs
       where cs.property_id = q.property_id and cs.submitted_by_user_id = q.payee_user_id
         and coalesce(cs.cleaning_type, 'checkout') <> 'mid_stay'
         and cs.checkout_date between a.d - 1 and a.d + 1 and cs.fee_paid_at is null
         and (cs.pay_request_id is null
              or not exists (select 1 from public.staff_pay_requests r2 where r2.id = cs.pay_request_id and r2.status = 'paid'))
       order by abs(cs.checkout_date - a.d), cs.cleaned_at limit 1) s
    where q.property_id = p_property_id and q.status = 'paid' and q.paid_at < p_now - interval '3 days'
      and q.created_at > p_now - interval '90 days' and a.d is not null
      and public.s_advance_session_v1(q.id, a.d) is null
  ), '[]'::jsonb);

  -- stuck_paying: a request has sat in "paying" for more than a day.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V20:stuck_paying:' || q.ref,
      'check_id', 'V20',
      'severity', 'yellow',
      'title',    'Payment request stuck in paying',
      'detail',   jsonb_build_object('ref', q.ref, 'date', (select min(coalesce(l.value ->> 'checkout_date', l.value ->> 'date')) from jsonb_array_elements(q.lines) l),
                                     'payee', q.payee_name, 'since', coalesce(q.paying_at, q.updated_at))))
    from public.staff_pay_requests q
    where q.property_id = p_property_id and q.status = 'paying' and coalesce(q.paying_at, q.updated_at) < p_now - interval '24 hours'
  ), '[]'::jsonb);

  -- session_twice: one report on two live requests, or a report whose fee transaction was voided.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V20:session_twice:' || u.sid,
      'check_id', 'V20',
      'severity', 'red',
      'title',    'One cleaning report is paid or requested twice',
      'detail',   jsonb_build_object('ref', u.refs, 'date', u.d, 'payee', u.payee, 'session', u.sid)))
    from (
      select distinct on (z.sid) z.sid, z.refs, z.d, z.payee
        from (
          select x.sid, string_agg(x.ref, ' ' order by x.ref) as refs, min(x.d) as d, min(x.payee_name) as payee
            from (select q.id, q.ref, q.payee_name, l.value ->> 'session_id' as sid, coalesce(l.value ->> 'date', l.value ->> 'checkout_date') as d
                    from public.staff_pay_requests q cross join lateral jsonb_array_elements(q.lines) l
                   where q.property_id = p_property_id and q.status <> 'cancelled' and q.created_at > p_now - interval '90 days'
                     and l.value ->> 'session_id' is not null) x
           group by x.sid having count(distinct x.id) > 1
          union all
          select cs.id::text, r.ref, cs.checkout_date::text, r.payee_name
            from public.cleaning_sessions cs
            join public.transactions t on t.id = cs.fee_txn_id
            left join public.staff_pay_requests r on r.id = cs.pay_request_id
           where cs.property_id = p_property_id and t.status = 'void' and cs.cleaned_at > p_now - interval '90 days'
        ) z
       order by z.sid, z.refs
    ) u
  ), '[]'::jsonb);

  -- report_no_stay: a turnover report (90 days) whose checkout matches no confirmed stay. Yellow, OPS.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V20:report_no_stay:' || cs.id::text,
      'check_id', 'V20',
      'severity', 'yellow',
      'title',    'Cleaning report for a date with no confirmed stay',
      'detail',   jsonb_build_object('session', cs.id, 'date', cs.checkout_date, 'payee', cs.cleaner_name)))
    from public.cleaning_sessions cs
    where cs.property_id = p_property_id and coalesce(cs.cleaning_type, 'checkout') in ('checkout', 'turnover')
      and cs.checkout_date is not null and cs.cleaned_at > p_now - interval '90 days'
      and not exists (select 1 from public.calendar_events ce
                       where ce.property_id = cs.property_id and ce.status = 'confirmed' and ce.checkout_date = cs.checkout_date)
  ), '[]'::jsonb);
  -- s115 V20 end

  -- s115 V21 begin
  -- V21 - the calendar against the Airbnb reservations. Daily only; rows that ended in the last two weeks or are still ahead.
  if v_daily then
    -- block_named: a blocked row that carries a guest's name whose reservation (same name, same dates) is cancelled: calendar-sync kept the cancelled stay as a block.
    v_found := v_found || coalesce((
      select jsonb_agg(jsonb_build_object(
        'key',      'V21:block_named:' || ce.id::text,
        'check_id', 'V21',
        'severity', 'yellow',
        'title',    'Blocked calendar row still carries a cancelled guest''s name',
        'detail',   jsonb_build_object('event', ce.id, 'guest', ce.guest_name, 'from', ce.checkin_date, 'to', ce.checkout_date, 'code', ar.confirmation_code)))
      from public.calendar_events ce
      join public.airbnb_reservations ar
        on ar.property_id = ce.property_id and ar.status = 'cancelled'
       and ar.checkin_date = ce.checkin_date and ar.checkout_date = ce.checkout_date
       and (lower(btrim(ar.guest_name)) = lower(btrim(ce.guest_name)) or position(lower(btrim(ce.guest_name)) in lower(btrim(ar.guest_name))) = 1)
      where ce.property_id = p_property_id and ce.status = 'blocked' and nullif(btrim(coalesce(ce.guest_name, '')), '') is not null
        and ce.checkout_date >= (p_now at time zone 'Asia/Manila')::date - 14
    ), '[]'::jsonb);

    -- confirmed_cancelled: a confirmed calendar row whose linked reservation is cancelled.
    v_found := v_found || coalesce((
      select jsonb_agg(jsonb_build_object(
        'key',      'V21:confirmed_cancelled:' || ce.id::text,
        'check_id', 'V21',
        'severity', 'red',
        'title',    'Confirmed calendar row for a cancelled reservation',
        'detail',   jsonb_build_object('event', ce.id, 'guest', ce.guest_name, 'from', ce.checkin_date, 'to', ce.checkout_date, 'code', ar.confirmation_code)))
      from public.calendar_events ce
      join public.airbnb_reservations ar on ar.id = ce.linked_reservation_id
      where ce.property_id = p_property_id and ce.status = 'confirmed' and ar.status = 'cancelled'
        and ce.checkout_date >= (p_now at time zone 'Asia/Manila')::date - 14
    ), '[]'::jsonb);
  end if;
  -- s115 V21 end

  -- s115 V22 begin
  -- V22 - a paid model provider has refused every call (HTTP 402) in the last day and answered none since: the credit is used up. Probes are ignored.
  -- features are the call titles refused since the last good call, in words a person reads (contract amendment 1).
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V22:credit_gone:' || pv.provider,
      'check_id', 'V22',
      'severity', 'red',
      'title',    'Paid API credit is used up',
      'detail',   jsonb_build_object('provider', pv.provider, 'since', y.since, 'features', y.features)))
    from (select distinct u.provider
            from public.llm_usage u
           where u.at > p_now - interval '24 hours' and u.at <= p_now and coalesce(u.probe, false) = false
             and u.ok is not true and u.error like '%\_402') pv
    cross join lateral (select max(o.at) as last_ok from public.llm_usage o
                         where o.provider = pv.provider and o.ok is true and coalesce(o.probe, false) = false
                           and o.at > p_now - interval '30 days' and o.at <= p_now) k
    cross join lateral (
      select min(w.at) as since, coalesce(jsonb_agg(distinct w.nm order by w.nm), '[]'::jsonb) as features
        from (select x.at,
                     case btrim(coalesce(x.title, ''))
                       when 'Cascade ID face box'   then 'the ID face box'
                       when 'Cascade Guest Details' then 'guest details'
                       when 'Cascade Meter'         then 'meter readings'
                       when 'Cascade Power Watch'   then 'Power Watch'
                       else lower(left(regexp_replace(btrim(coalesce(x.title, 'unknown')), '^Cascade ', ''), 1))
                            || substr(regexp_replace(btrim(coalesce(x.title, 'unknown')), '^Cascade ', ''), 2)
                     end as nm
                from public.llm_usage x
               where x.provider = pv.provider and x.error like '%\_402' and coalesce(x.probe, false) = false
                 and x.at > coalesce(k.last_ok, p_now - interval '30 days') and x.at <= p_now) w) y
    where y.since is not null
  ), '[]'::jsonb);
  -- s115 V22 end

  -- s115 V23 begin
  -- V23 - the meter chain: each reading should start where the previous one ended. An overlap or a gap means a reading was missed, doubled or estimated. It raises exactly the readings
  -- kpi_tab_v1 leaves out of the per-day figures (both read public.meter_chain_v1, ML-10), until they are put right. Last 60 days. Finance group.
  -- detail (cards.ts v23Facts): reading = this reading's meter value, prev = the reading before it ended at, expected_prev = this one says it started from, checkout, reading_id.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V23:meter_chain:' || x.id::text,
      'check_id', 'V23',
      'severity', 'yellow',
      'title',    'Meter reading does not continue the previous one',
      'detail',   jsonb_build_object('reading', x.electric_curr, 'checkout', x.cd, 'prev', x.pc, 'expected_prev', x.electric_prev, 'reading_id', x.id)))
    from public.meter_chain_v1(p_property_id) x
    where not x.chain_ok and x.recorded_at > p_now - interval '60 days'
  ), '[]'::jsonb);
  -- s115 V23 end

  return jsonb_build_object('scope', p_scope, 'ran_at', p_now, 'found', v_found);
end;
$body$
;
revoke all on function public.run_system_verifier_v1(uuid,text,timestamp with time zone) from public, anon, authenticated;
grant execute on function public.run_system_verifier_v1(uuid,text,timestamp with time zone) to service_role;

create or replace function public.health_checks_core_v1(p_property_id uuid, p_fin boolean)
returns jsonb language plpgsql security definer set search_path = '' as $body$
declare v_today date; v_start date; v_fin boolean; v_hc record; v_out jsonb := '[]'::jsonb; v_checks jsonb := '[]'::jsonb;
begin
  v_fin := p_fin;
  v_today := public.manila_today();
  -- D-219: money before the accounting start is historical and accepted (Lloyd 2026-09-23). No start on
  -- record means no cut-off, which is how every check behaved before this.
  v_start := coalesce((select s.accounting_start from public.acct_settings s where s.property_id = p_property_id), '-infinity'::date);

  -- Ledger ↔ reservations: every confirmed payout e-mail names its stay.
  v_checks := v_checks || (select jsonb_build_object('k', 'payout_rows_linked', 'l', 'Payout e-mails linked to a stay', 's', case when count(*) = 0 then 'pass' else 'fail' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'ref', t.external_ref, 'date', t.transaction_date, 'amount', t.gross_amount)) filter (where t.id is not null), '[]'::jsonb))
  from (select * from public.transactions where property_id = p_property_id and source = 'airbnb_payout_email' and status = 'confirmed' and reservation_id is null limit 20) t);

  -- Reservations ↔ payouts: every completed stay has a confirmed payout row.
  v_checks := v_checks || (select jsonb_build_object('k', 'completed_stays_paid', 'l', 'Completed stays with a payout row', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('code', rr.confirmation_code, 'guest', rr.guest_name, 'checkout', rr.checkout_date, 'payout', rr.host_payout)) filter (where rr.id is not null), '[]'::jsonb))
  from (select * from public.airbnb_reservations x where x.property_id = p_property_id and x.status = 'completed' and x.checkout_date < v_today and x.checkout_date >= v_start
        and not exists (select 1 from public.transactions t where t.reservation_id = x.id and t.source = 'airbnb_payout_email' and t.status = 'confirmed') limit 20) rr);

  -- Payout totals: Σ reservation payout_amount = Σ payout e-mails + Σ Airbnb adjustments.
  v_checks := v_checks || (select jsonb_build_object('k', 'payout_totals_agree', 'l', 'Reservation payouts equal payout e-mails plus adjustments', 's', case when abs(d.diff) < 1 then 'pass' else 'warn' end, 'n', 0, 'd',
    jsonb_build_object('reservationPayouts', d.res, 'payoutEmails', d.em, 'adjustments', d.adj, 'difference', d.diff))
  from (select res, em, adj, res - em - adj diff from (
    select (select coalesce(sum(payout_amount), 0) from public.airbnb_reservations where property_id = p_property_id and payout_amount is not null and checkout_date >= v_start) res,
           (select coalesce(sum(t.gross_amount), 0) from public.transactions t join public.airbnb_reservations r on r.id = t.reservation_id
             where t.property_id = p_property_id and t.source = 'airbnb_payout_email' and t.status = 'confirmed' and r.checkout_date >= v_start) em,
           (select coalesce(sum(gross_amount), 0) from public.transactions where property_id = p_property_id and source = 'airbnb' and txn_type = 'expense' and category = 'airbnb_adjustment' and status = 'confirmed' and transaction_date >= v_start) adj) x) d);

  -- Cleaning log ↔ stays: a checkout in the last 90 days has a cleaning within three days.
  v_checks := v_checks || (select jsonb_build_object('k', 'checkouts_cleaned', 'l', 'Checkouts (90 days) followed by a cleaning', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('code', s.confirmation_code, 'guest', s.guest_name, 'checkout', s.checkout_date)) filter (where s.id is not null), '[]'::jsonb))
  from (select * from public.airbnb_reservations x where x.property_id = p_property_id and x.status = 'completed' and x.checkout_date >= v_today - 90 and x.checkout_date < v_today
        and not exists (select 1 from public.cleaning_sessions c where c.property_id = p_property_id and (c.checkout_date = x.checkout_date or (c.cleaned_at::date between x.checkout_date and x.checkout_date + 3))) limit 20) s);

  -- Cleaning log ↔ ledger. SPEC-37: the fee stays NULL until the cleaner asks to be paid, so an unpaid clean is
  -- normal for a while. A fee marked paid with no live transaction is a ledger defect (fail); a clean still unpaid
  -- 14 days after it was done is a reminder (warn). An explicit 0 is no fee (get_admin_overview_v1's rule).
  if v_fin then
    v_checks := v_checks || (select jsonb_build_object('k', 'cleaner_fees_settled', 'l', 'Cleaning fees settled in the ledger', 's', case when bool_or(c.fee_paid_at is not null) then 'fail' when count(*) > 0 then 'warn' else 'pass' end, 'n', count(*)::int, 'd',
      coalesce(jsonb_agg(jsonb_build_object('session', c.id, 'guest', c.last_guest_name, 'cleaned', c.cleaned_at::date, 'fee', c.fee_amount, 'paid', c.fee_paid_at::date)) filter (where c.id is not null), '[]'::jsonb))
    from (select * from public.cleaning_sessions x where x.property_id = p_property_id and (x.fee_amount is null or x.fee_amount > 0)
          and ((x.fee_paid_at is not null and (x.fee_txn_id is null or not exists (select 1 from public.transactions t where t.id = x.fee_txn_id and t.status <> 'void')))
            or (x.fee_paid_at is null and x.cleaned_at < now() - interval '14 days'))
          order by x.fee_paid_at is null, x.cleaned_at limit 20) c);
  end if;

  -- Meter readings: first entries and negative re-entries carry a review flag.
  v_checks := v_checks || (select jsonb_build_object('k', 'meter_readings_reviewed', 'l', 'Odd meter readings reviewed', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'session', m.session_id, 'recorded', m.recorded_at::date, 'electricDelta', m.electric_delta, 'waterDelta', m.water_delta)) filter (where m.id is not null), '[]'::jsonb))
  from (select * from public.meter_readings x where x.property_id = p_property_id and x.meter_flag is null
        and (coalesce(x.electric_prev, 0) = 0 or coalesce(x.water_prev, 0) = 0 or coalesce(x.electric_delta, 0) < 0 or coalesce(x.water_delta, 0) < 0) limit 20) m);

  -- Inventory: ledger-controlled items agree with their last movement; nothing negative.
  v_checks := v_checks || (select jsonb_build_object('k', 'inventory_ledger_consistent', 'l', 'Inventory quantities agree with movements', 's', case when count(*) = 0 then 'pass' else 'fail' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('item', i.name, 'onHand', i.qty_on_hand, 'lastMovement', i.last_after)) filter (where i.id is not null), '[]'::jsonb))
  from (select x.id, x.name, x.qty_on_hand, x.movement_controlled_at, (select quantity_after from public.inventory_stock_movements m where m.item_id = x.id order by sequence_no desc limit 1) last_after
        from public.inventory_items x where x.property_id = p_property_id and x.is_active) i
  where i.qty_on_hand < 0 or (i.movement_controlled_at is not null and i.last_after is not null and i.last_after <> i.qty_on_hand));

  if v_fin then
    -- Ledger: duplicate live rows (same date, amount, payee, type, source).
    v_checks := v_checks || (select jsonb_build_object('k', 'ledger_duplicates', 'l', 'Duplicate ledger rows', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
      coalesce(jsonb_agg(jsonb_build_object('date', g.transaction_date, 'amount', g.gross_amount, 'payee', g.payee, 'n', g.n)), '[]'::jsonb))
    from (select transaction_date, gross_amount, coalesce(payee_name, '') payee, count(*) n from public.transactions
          where property_id = p_property_id and status <> 'void' and source not in ('airbnb','airbnb_email')
          group by transaction_date, gross_amount, coalesce(payee_name, ''), txn_type, source having count(*) > 1 limit 20) g);

    -- Ledger position: income − expenses − drawings on confirmed, non-mirror rows.
    v_checks := v_checks || (select jsonb_build_object('k', 'ledger_position', 'l', 'Cash position: income − expenses − drawings', 's', case when p.opening + p.net < 0 then 'warn' else 'pass' end, 'n', 0, 'd',
      -- D-219: income - expenses - drawings is money left over, never expected to be zero. The position is
      -- the opening cash plus what moved since the accounting start; only a position below zero is wrong.
      -- net carries the position, so the problem sentence reads the amount it is about.
      jsonb_build_object('opening', p.opening, 'income', p.inc, 'expenses', p.exp, 'drawings', p.drw, 'net', p.opening + p.net, 'since', v_start, 'asOf', v_today))
    from (select inc, exp, drw, inc - exp - drw net,
            (select coalesce(sum(l.debit - l.credit), 0) from public.acct_journal_lines l join public.acct_journals j on j.id = l.journal_id join public.acct_accounts a on a.id = l.account_id
              where j.property_id = p_property_id and j.event_kind = 'opening_balance' and j.status = 'posted' and a.is_cash) opening
          from (
      select coalesce(sum(gross_amount) filter (where txn_type = 'income'), 0) inc, coalesce(sum(gross_amount) filter (where txn_type = 'expense'), 0) exp, coalesce(sum(gross_amount) filter (where txn_type = 'drawing'), 0) drw
      from public.transactions where property_id = p_property_id and status = 'confirmed' and source not in ('airbnb','airbnb_email') and transaction_date <= v_today and transaction_date >= v_start) x) p);

    -- Journals: every posted journal balances.
    v_checks := v_checks || (select jsonb_build_object('k', 'journals_balanced', 'l', 'Posted journals balance', 's', case when count(*) = 0 then 'pass' else 'fail' end, 'n', count(*)::int, 'd',
      coalesce(jsonb_agg(jsonb_build_object('journalNo', j.journal_no, 'debits', j.d, 'credits', j.c)), '[]'::jsonb))
    from (select j.journal_no, sum(l.debit) d, sum(l.credit) c from public.acct_journals j join public.acct_journal_lines l on l.journal_id = j.id
          where j.property_id = p_property_id and j.status = 'posted' group by j.journal_no having sum(l.debit) <> sum(l.credit) limit 20) j);

    -- s91 kpi_reconciled begin
    -- V19 as a health row: the month KPIs against a second count from the raw books (current Manila month and the three before). Red findings fail it,
    -- yellow ones warn. n counts findings; d names month, metric, shown and recomputed (hygiene rows carry n instead).
    v_checks := v_checks || (select jsonb_build_object('k', 'kpi_reconciled', 'l', 'Month KPIs reconcile with the raw books',
      's', case when count(*) filter (where e.f ->> 'severity' = 'red') > 0 then 'fail' when count(*) > 0 then 'warn' else 'pass' end, 'n', count(*)::int, 'd',
      coalesce(jsonb_agg(jsonb_build_object('month', e.f -> 'detail' ->> 'month', 'metric', e.f -> 'detail' ->> 'metric', 'shown', e.f -> 'detail' -> 'shown',
                                            'recomputed', e.f -> 'detail' -> 'recomputed', 'n', e.f -> 'detail' -> 'n')) filter (where e.f is not null), '[]'::jsonb))
    from jsonb_array_elements(public.kpi_reconcile_window_v1(p_property_id, v_today)) e(f));
    -- s91 kpi_reconciled end
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
  select coalesce(jsonb_agg(to_jsonb(h) order by h.check_key), '[]'::jsonb) into v_out from public.admin_health_check_runs h where h.property_id = p_property_id and (v_fin or h.check_key not in ('cleaner_fees_settled','ledger_duplicates','ledger_position','journals_balanced','kpi_reconciled'));
  return jsonb_build_object('ranAt', now(), 'checks', v_out);
end;
$body$;
revoke all on function public.health_checks_core_v1(uuid, boolean) from public, anon, authenticated;
grant execute on function public.health_checks_core_v1(uuid, boolean) to service_role;

create or replace function public.kpi_recompute_v1(p_property_id uuid, p_start date, p_end_exclusive date)
returns jsonb language sql stable security definer set search_path = '' as $body$
  with st as (
    select r.id stay_id, r.guest_id, r.status, r.checkin_date ci, r.checkout_date co, r.checkout_date - r.checkin_date n,
           coalesce((select round(sum(x.gross_earnings) - coalesce(sum(x.cleaning_fee), 0), 2) from public.airbnb_transactions x
                      where x.property_id = r.property_id and x.confirmation_code = r.confirmation_code and x.row_type = 'reservation'),
                    round(r.host_payout + coalesce(r.host_service_fee, 0), 2)) rev
    from public.airbnb_reservations r
    where r.property_id = p_property_id and r.source is distinct from 'direct' and r.status in ('confirmed', 'completed')
    union all
    select i.id, i.guest_id, i.status, i.checkin_date, i.checkout_date, i.checkout_date - i.checkin_date, i.total_amount
    from public.booking_inquiries i
    where i.property_id = p_property_id and i.status in ('confirmed', 'completed') and coalesce(i.guest_name, '') !~* '^synthetic'
  ), nights as (
    select st.*, st.ci + g.k d, g.k idx
    from st cross join lateral generate_series(0, st.n - 1) g(k)
    where st.ci + g.k >= p_start and st.ci + g.k < p_end_exclusive
  ), alloc as (
    select nights.*, case when rev is null then null
                          else (floor(round(rev * 100) / n) + case when idx < (round(rev * 100)::bigint % n) then 1 else 0 end) / 100.0 end amt
    from nights
  ), dead as (
    select t.external_ref ref
    from public.transactions t
    join public.airbnb_reservations r on r.property_id = t.property_id and r.confirmation_code = t.external_ref
    where t.property_id = p_property_id and t.source = 'airbnb_email' and t.income_stage = 'estimated' and t.status = 'confirmed'
      and (r.status = 'cancelled'
           or exists (select 1 from public.transactions p where p.reservation_id = r.id and p.source = 'airbnb_payout_email' and p.status = 'confirmed'))
  ), drift as (
    select q.id
    from public.staff_pay_requests q
    where q.property_id = p_property_id and q.status <> 'cancelled' and jsonb_typeof(q.lines) = 'array'
      and q.total_amount <> (select sum((l ->> 'amount')::numeric) from jsonb_array_elements(q.lines) l)
  )
  select jsonb_build_object(
    'sold_nights', count(distinct d),
    'revenue', coalesce(round(sum(amt), 2), 0),
    'revenue_nights', count(*) filter (where amt is not null),
    'revenue_missing_nights', count(*) filter (where amt is null),
    'adr', round(sum(amt) / nullif(count(*) filter (where amt is not null), 0), 2),
    'cash_received', (select coalesce(sum(t.gross_amount), 0) from public.transactions t
                       where t.property_id = p_property_id and t.txn_type = 'income' and t.status = 'confirmed'
                         and t.transaction_date >= p_start and t.transaction_date < p_end_exclusive and t.source not in ('airbnb', 'airbnb_email')),
    'cleaner_fee_ledger', (select coalesce(sum(t.gross_amount), 0) from public.transactions t
                            where t.property_id = p_property_id and t.source = 'cleaner_fee' and t.category = 'cleaning' and t.status = 'confirmed'
                              and t.transaction_date >= p_start and t.transaction_date < p_end_exclusive),
    'cleaner_fee_sessions', (select coalesce(sum(c.fee_amount), 0) from public.cleaning_sessions c join public.transactions t on t.id = c.fee_txn_id
                              where c.property_id = p_property_id and t.status = 'confirmed'
                                and t.transaction_date >= p_start and t.transaction_date < p_end_exclusive),
    'pay_request_line_drift', (select count(*) from drift),
    'pay_request_line_drift_ids', (select coalesce(jsonb_agg(x.id), '[]'::jsonb) from (select id from drift order by id limit 10) x),
    'direct_mirror_dups', (select count(*) from public.airbnb_reservations r join public.booking_inquiries i on r.confirmation_code = 'DIRECT:' || i.id::text
                            where r.property_id = p_property_id and r.status <> 'cancelled' and i.status in ('confirmed', 'completed')
                              and i.checkin_date < p_end_exclusive and i.checkout_date > p_start),
    'confirmed_estimates_dead', (select count(*) from dead),
    'confirmed_estimates_dead_refs', (select coalesce(jsonb_agg(x.ref), '[]'::jsonb) from (select ref from dead order by ref limit 10) x),
    'split_payout_stays', (select count(*) from (select confirmation_code from public.airbnb_transactions
                                                  where property_id = p_property_id and row_type = 'reservation' group by 1 having count(*) > 1) s)
  ) from alloc;
$body$;
revoke all on function public.kpi_recompute_v1(uuid, date, date) from public, anon, authenticated, service_role;

-- OmniRoute key cap back to 0.5, only while it still reads 0.15
do $d$
declare v_idx integer;
begin
  select (e.ord - 1)::integer into v_idx
    from public.app_settings s, jsonb_array_elements(case when jsonb_typeof(s.value -> 'caps') = 'array' then s.value -> 'caps' else '[]'::jsonb end) with ordinality e(el, ord)
   where s.key = 'api_caps' and e.el ->> 'id' = 'omniroute-key' and (e.el ->> 'cap')::numeric = 0.15;
  if v_idx is null then raise notice 's117 rollback: omniroute cap not at 0.15, left as it is'; return; end if;
  update public.app_settings set value = jsonb_set(value, array['caps', v_idx::text, 'cap'], to_jsonb(0.5::numeric)) where key = 'api_caps';
end $d$;

drop function public.system_tasks_expire_v1(timestamp with time zone);
drop function public.api_usage_last_calls_v1();

update public.inventory_items set name = 'Heater (Heatek)'
where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid and is_active and name = 'Kettle / Water Heater'
  and not exists (select 1 from public.inventory_items x where x.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid and x.name = 'Heater (Heatek)');

commit;
