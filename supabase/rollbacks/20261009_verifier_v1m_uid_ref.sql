-- Compensating rollback for 20261009000000_verifier_v1m_uid_ref.sql: restores the live bodies read 2026-10-08
-- (run_system_verifier_v1 md5 d803b9fd248dce1fe4795032bae7efcf, staff_verifier_facts_v1 md5 3ba47c71d13c6d845d8709ba1f274b77).
-- Reads only; verifier_findings refresh on the next run.
begin;

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
        'block', m.id, 'stay', s.id, 'guest', s.guest_name,
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

create or replace function public.staff_verifier_facts_v1(p_check_id text, p_detail jsonb)
returns jsonb language sql immutable set search_path to '' as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'ref',        upper(coalesce(substring(p_detail->>'booking' from '^[0-9a-fA-F]{8}'), substring(p_detail->>'stay' from '^[0-9a-fA-F]{8}'),
                                 substring(p_detail->>'uid' from '^cascade-direct-([0-9a-fA-F]{8})'))),
    'guest_first', nullif(public.staff_redact_v1(split_part(btrim(coalesce(p_detail->>'guest', p_detail#>>'{a,guest}', '')), ' ', 1)), ''),
    'from',       case when coalesce(p_detail->>'from', p_detail#>>'{a,from}', p_detail->>'arrives', p_detail->>'stay_from') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                       then coalesce(p_detail->>'from', p_detail#>>'{a,from}', p_detail->>'arrives', p_detail->>'stay_from') end,
    'to',         case when coalesce(p_detail->>'to', p_detail#>>'{a,to}', p_detail->>'stay_to') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                       then coalesce(p_detail->>'to', p_detail#>>'{a,to}', p_detail->>'stay_to') end,
    'block_from', case when p_detail->>'block_from' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then p_detail->>'block_from' end,
    'block_to',   case when p_detail->>'block_to' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then p_detail->>'block_to' end,
    'check',      case when p_check_id = 'V10' and p_detail->>'check' ~ '^[a-z_]{1,40}$' then p_detail->>'check' end,
    'n',          case when p_check_id = 'V10' and jsonb_typeof(p_detail->'n') = 'number' then p_detail->'n' end));
$$;

revoke all on function public.run_system_verifier_v1(uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public.run_system_verifier_v1(uuid, text, timestamptz) to service_role;
revoke all on function public.staff_verifier_facts_v1(text, jsonb) from public, anon, authenticated, service_role;

comment on function public.run_system_verifier_v1(uuid, text, timestamptz) is
  'SPEC-11 checks V1-V7b, V10, V11, V12 (V13 is raised by the Edge Function). Reads only, stores nothing, decides nothing about alerting. V1 skips our own Airbnb mirror of a direct stay and raises V1m (yellow, detail carries the stay uid) when that block runs past the stay; V2/V3 read direct:<id> and cascade-direct-<id>. V7 is yellow and auto-corrected when both rows are confirmed (D-235); checkouts_cleaned is yellow on warn (D-232). service_role only.';

commit;
