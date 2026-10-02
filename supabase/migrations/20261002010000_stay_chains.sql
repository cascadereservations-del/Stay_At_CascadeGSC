-- 20261002010000_stay_chains.sql
-- Session 67, D-290: release stay_chains_20261002.
-- A same-guest chain is one stay. Airbnb sometimes splits an extension into two reservations (HMYDBYKYPC Sep 28 - Oct 2
-- then HM3EXQ5Z8D Oct 2 - 4, one guest): the checkout on Oct 2 is not a turnover, nobody cleans, and
-- turnover-verifier would raise a false no_session_found at 2026-10-03 00:00 UTC.
--
-- New (read helpers, no table or column change):
--   stay_uid_inquiry_v1(uid)                 the booking_inquiries id inside a direct calendar uid, else null
--   stay_same_guest_v1(event_a, event_b)     same guest? guest_id decides when both rows have one; otherwise the same real
--                                            name, or the same phone last-4 (Airbnb raw_description, or the end of guest_phone)
--   stay_continues_v1(property, date)        a confirmed stay ends on the date and another confirmed stay of the same guest
--                                            starts on it
--   stay_chains_v1(property, from, to)       one row per junction, for the operator (guest name and codes: service_role only)
--   system_task_close_v1(kind, ref, note)    close ONE system task by its key (service_role only)
--   guests_missing_details_v1(guest_ids)     of the given guests, those with no ID on file and no phone or email anywhere
--                                            (guests.phone/email, guest_profile_details.contact_number): daily-digest's
--                                            "details missing" line. service_role only.
-- Changed (create or replace, same signature, grants and security as live):
--   verify_turnover        a continued checkout passes with issues {no_checkout_scheduled, stay_continues}
--                          (turnover-verifier already treats no_checkout_scheduled as silent)
--   get_missed_cleanings   a checkout that chains into the same guest's next stay is not a missed cleaning
--   due_guest_messages_v1  direct chains: no checkout_reminder / after_departure on the first booking; no confirmation /
--                          pre_arrival on the continuation when the earlier booking was made first
--   verify_booking         a stay that chains forward reports the final checkout_date and the summed nights; expiry uses the
--                          final checkout. Same PII rules, same keys.
-- Caller grants: stay_same_guest_v1, stay_continues_v1 and stay_uid_inquiry_v1 go to authenticated and service_role because
-- verify_turnover and get_missed_cleanings run as the caller and authenticated may already call them. They are SECURITY
-- INVOKER, so RLS still decides what a caller can see; anon gets nothing. stay_chains_v1 returns names and booking codes:
-- service_role only.
-- Live md5(prosrc) before this release: verify_turnover 895d50d992b48fa4d4c264a1a15f819b, get_missed_cleanings
-- 321f462e7b3e0cfa5ce33d09234f08cb, verify_booking 32597e37d1fc428984d2070ebb53d703, due_guest_messages_v1
-- 4513e1e984dc255f2fbf88764184fe89. The rollback restores exactly these.

begin;

create or replace function public.stay_uid_inquiry_v1(p_uid text)
returns uuid language sql immutable set search_path to '' as $$
  select (regexp_match(p_uid, '^(?:direct:|cascade-direct-)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$', 'i'))[1]::uuid;
$$;

create or replace function public.stay_same_guest_v1(p_a uuid, p_b uuid)
returns boolean language sql stable set search_path to '' as $$
  with k as (
    select ce.id,
           coalesce(r.guest_id, bi.guest_id) as gid,
           case when split_part(lower(btrim(coalesce(ce.guest_name, ''))), ' ', 1) in ('', 'reserved', 'airbnb', 'not', 'guest')
                then null else lower(btrim(ce.guest_name)) end as nm,
           coalesce(substring(ce.raw_description from 'Phone Number \(Last 4 Digits\): *([0-9]{4})'),
                    substring(regexp_replace(coalesce(ce.guest_phone, ''), '\D', '', 'g') from '([0-9]{4})$')) as l4
      from public.calendar_events ce
      left join public.airbnb_reservations r on r.id = ce.linked_reservation_id
      left join public.booking_inquiries bi on bi.id = public.stay_uid_inquiry_v1(ce.uid)
     where ce.id in (p_a, p_b)
  )
  select coalesce((
    select case when a.gid is not null and b.gid is not null then a.gid = b.gid
                else (a.nm is not null and a.nm = b.nm) or (a.l4 is not null and a.l4 = b.l4) end
      from k a, k b
     where a.id = p_a and b.id = p_b
  ), false);
$$;

create or replace function public.stay_continues_v1(p_property_id uuid, p_date date)
returns boolean language sql stable set search_path to '' as $$
  select exists (
    select 1
      from public.calendar_events a
      join public.calendar_events b
        on b.property_id = a.property_id and b.checkin_date = a.checkout_date and b.id <> a.id
     where a.property_id = p_property_id
       and a.checkout_date = p_date
       and a.status = 'confirmed'
       and b.status = 'confirmed'
       and public.stay_same_guest_v1(a.id, b.id)
  );
$$;

create or replace function public.stay_chains_v1(p_property_id uuid, p_from date, p_to date)
returns table(junction_date date, guest_id uuid, guest_name text, first_uid text, first_source text, first_code text,
              first_checkin date, next_uid text, next_code text, next_checkout date)
language sql stable set search_path to '' as $$
  -- first_* is the stay that ends on the junction date, next_* the stay that starts on it. A three-stay chain is two rows.
  select a.checkout_date,
         coalesce(ra.guest_id, ia.guest_id, rb.guest_id, ib.guest_id),
         coalesce(nullif(btrim(a.guest_name), ''), nullif(btrim(b.guest_name), '')),
         a.uid,
         a.source,
         coalesce(ra.confirmation_code, left(ia.id::text, 8)),
         a.checkin_date,
         b.uid,
         coalesce(rb.confirmation_code, left(ib.id::text, 8)),
         b.checkout_date
    from public.calendar_events a
    join public.calendar_events b
      on b.property_id = a.property_id and b.checkin_date = a.checkout_date and b.id <> a.id and b.status = 'confirmed'
    left join public.airbnb_reservations ra on ra.id = a.linked_reservation_id
    left join public.booking_inquiries ia on ia.id = public.stay_uid_inquiry_v1(a.uid)
    left join public.airbnb_reservations rb on rb.id = b.linked_reservation_id
    left join public.booking_inquiries ib on ib.id = public.stay_uid_inquiry_v1(b.uid)
   where a.property_id = p_property_id
     and a.status = 'confirmed'
     and a.checkout_date between p_from and p_to
     and public.stay_same_guest_v1(a.id, b.id)
   order by a.checkout_date, a.checkin_date;
$$;

create or replace function public.system_task_close_v1(p_source_kind text, p_source_ref text, p_note text)
returns boolean
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare n integer;
begin
  if p_source_kind is null or p_source_kind !~ '^[a-z_]{3,40}$' then
    raise exception 'source kind must be 3-40 lowercase letters or underscores' using errcode = '22023';
  end if;
  if p_source_ref is null or char_length(p_source_ref) not between 1 and 100 then
    raise exception 'source ref is required' using errcode = '22023';
  end if;
  update public.follow_up_tasks
     set status = 'done',
         completed_at = now(),
         completion_note = left(coalesce(p_note, 'Closed automatically: the problem is no longer reported.'), 500)
   where idempotency_key = 'system:' || p_source_kind || ':' || p_source_ref
     and status in ('open', 'in_progress');
  get diagnostics n = row_count;
  return n > 0;
end;
$function$;

create or replace function public.guests_missing_details_v1(p_guest_ids uuid[])
returns table(guest_id uuid)
language sql stable security definer set search_path to '' as $$
  select g.id
    from public.guests g
    left join public.guest_profile_details d on d.guest_id = g.id
   where g.id = any(p_guest_ids)
     and not coalesce(d.id_on_file, false)
     and coalesce(btrim(d.contact_number), '') = ''
     and coalesce(btrim(g.phone), '') = ''
     and coalesce(btrim(g.email), '') = '';
$$;

revoke all on function public.stay_uid_inquiry_v1(text) from public, anon, authenticated;
revoke all on function public.stay_same_guest_v1(uuid, uuid) from public, anon, authenticated;
revoke all on function public.stay_continues_v1(uuid, date) from public, anon, authenticated;
revoke all on function public.stay_chains_v1(uuid, date, date) from public, anon, authenticated;
revoke all on function public.system_task_close_v1(text, text, text) from public, anon, authenticated;
revoke all on function public.guests_missing_details_v1(uuid[]) from public, anon, authenticated;
grant execute on function public.stay_uid_inquiry_v1(text) to authenticated, service_role;
grant execute on function public.stay_same_guest_v1(uuid, uuid) to authenticated, service_role;
grant execute on function public.stay_continues_v1(uuid, date) to authenticated, service_role;
grant execute on function public.stay_chains_v1(uuid, date, date) to service_role;
grant execute on function public.system_task_close_v1(text, text, text) to service_role;
grant execute on function public.guests_missing_details_v1(uuid[]) to service_role;

comment on function public.stay_same_guest_v1(uuid, uuid) is
  'D-290: are two calendar_events the same guest? guest_id decides when both rows have one; else the same real name, or the same phone last-4. Invoker, RLS applies.';
comment on function public.stay_continues_v1(uuid, date) is
  'D-290: a confirmed stay ends on p_date and another confirmed stay of the same guest starts on it, so the checkout is not a turnover.';
comment on function public.stay_chains_v1(uuid, date, date) is
  'D-290: one row per same-guest junction in the range (guest name and booking codes). service_role only.';
comment on function public.system_task_close_v1(text, text, text) is
  'D-290: closes the ONE open system task with key system:<kind>:<ref>; returns whether one was closed. service_role only.';
comment on function public.guests_missing_details_v1(uuid[]) is
  'D-290: which of these guests have no ID on file and no phone or email on record. Definer, service_role only.';

-- verify_turnover: Check 0 gains one branch. Everything else is the live text.
create or replace function public.verify_turnover(p_checkout_date date, p_property_id uuid DEFAULT NULL::uuid)
 returns jsonb
 language plpgsql
 set search_path to ''
as $function$
DECLARE
  v_property_id uuid;
  v_session record;
  v_meter record;
  v_issues text[] := '{}';
  v_check_passed boolean := true;
  v_guest_checkout_exists boolean;
BEGIN
  IF p_property_id IS NULL THEN
    SELECT id INTO v_property_id FROM public.properties LIMIT 1;
  ELSE
    v_property_id := p_property_id;
  END IF;

  -- Check 0: did a guest actually check out on this date?
  -- A blocked or cancelled event is not a stay and needs no turnover.
  SELECT EXISTS (
    SELECT 1
    FROM public.calendar_events
    WHERE property_id = v_property_id
      AND checkout_date = p_checkout_date
      AND status = 'confirmed'
  ) INTO v_guest_checkout_exists;

  IF NOT v_guest_checkout_exists THEN
    RETURN jsonb_build_object(
      'check_passed', true,
      'session_id', null,
      'cleaner_name', null,
      'total_photo_count', null,
      'is_complete', null,
      'incomplete_reasons', null,
      'issues', ARRAY['no_checkout_scheduled']
    );
  END IF;

  -- Check 0b (D-290): the same guest checks in again on this date, so nobody cleans and no turnover is owed.
  -- no_checkout_scheduled keeps turnover-verifier silent; stay_continues says why.
  IF public.stay_continues_v1(v_property_id, p_checkout_date) THEN
    RETURN jsonb_build_object(
      'check_passed', true,
      'session_id', null,
      'cleaner_name', null,
      'total_photo_count', null,
      'is_complete', null,
      'incomplete_reasons', null,
      'issues', ARRAY['no_checkout_scheduled', 'stay_continues']
    );
  END IF;

  -- Check 1: session exists for this checkout_date
  SELECT * INTO v_session
  FROM public.cleaning_sessions
  WHERE property_id = v_property_id
    AND checkout_date = p_checkout_date
  ORDER BY created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'check_passed', false,
      'session_id', null,
      'cleaner_name', null,
      'total_photo_count', null,
      'is_complete', null,
      'incomplete_reasons', null,
      'issues', ARRAY['no_session_found']
    );
  END IF;

  -- Check 2: meter reading exists
  SELECT * INTO v_meter
  FROM public.meter_readings
  WHERE session_id = v_session.id
  LIMIT 1;

  IF NOT FOUND THEN
    v_issues := array_append(v_issues, 'no_meter_reading');
    v_check_passed := false;
  ELSE
    -- Check 3: sane kwh_per_night (catches stored 0.0000/night bug)
    IF (v_session.nights_stayed IS NOT NULL AND v_session.nights_stayed > 0)
       AND (v_meter.kwh_per_night IS NULL OR v_meter.kwh_per_night = 0) THEN
      v_issues := array_append(v_issues, 'meter_zero_kwh_per_night');
      -- Warning only — not a hard fail (could be a short stay with minimal usage)
    END IF;
  END IF;

  -- Check 4: photo count >= 5
  IF v_session.total_photo_count IS NULL OR v_session.total_photo_count < 5 THEN
    v_issues := array_append(v_issues, 'low_photo_count');
    v_check_passed := false;
  END IF;

  -- Check 5: session completeness
  IF v_session.is_complete IS NOT TRUE THEN
    v_issues := array_append(v_issues, 'session_incomplete');
    IF v_session.incomplete_reasons IS NOT NULL AND
       array_length(v_session.incomplete_reasons, 1) > 0 THEN
      v_issues := v_issues || v_session.incomplete_reasons;
    END IF;
    v_check_passed := false;
  END IF;

  RETURN jsonb_build_object(
    'check_passed', v_check_passed,
    'session_id', v_session.id,
    'cleaner_name', v_session.cleaner_name,
    'total_photo_count', COALESCE(v_session.total_photo_count, 0),
    'is_complete', v_session.is_complete,
    'incomplete_reasons', v_session.incomplete_reasons,
    'issues', v_issues
  );
END;
$function$;

-- get_missed_cleanings: one added condition. A row whose checkout chains into the same guest's next stay is not a missed cleaning.
create or replace function public.get_missed_cleanings(p_property_id uuid DEFAULT NULL::uuid, p_lookback integer DEFAULT 14)
 returns table(guest_name text, checkin_date date, checkout_date date, source text, days_overdue integer)
 language plpgsql
 stable
 set search_path to ''
as $function$
declare
  v_prop_id uuid;
  v_today   date;
begin
  -- 00:00 UTC cron = 08:00 Manila, so "today" in Manila is CURRENT_DATE here.
  v_today   := current_date;
  v_prop_id := coalesce(p_property_id, (select id from public.properties limit 1));

  return query
  select
    nullif(trim(coalesce(ce.guest_name, '')), '') as guest_name,
    ce.checkin_date,
    ce.checkout_date,
    ce.source,
    (v_today - ce.checkout_date)::integer as days_overdue
  from public.calendar_events ce
  where ce.property_id = v_prop_id
    and ce.status <> 'cancelled'
    and ce.checkout_date <  v_today
    and ce.checkout_date >= v_today - p_lookback
    and not exists (
      select 1
      from public.cleaning_sessions cs
      where cs.property_id = v_prop_id
        and coalesce(cs.cleaning_type, 'checkout') <> 'mid_stay'
        and (
          cs.checkout_date = ce.checkout_date
          -- filed a day late but clearly for this stay
          or cs.cleaned_at::date between ce.checkout_date and ce.checkout_date + 1
        )
    )
    -- D-290: the same guest checks in again on this checkout date, so nobody cleans
    and not exists (
      select 1
      from public.calendar_events nx
      where ce.status = 'confirmed'
        and nx.property_id = ce.property_id
        and nx.status = 'confirmed'
        and nx.checkin_date = ce.checkout_date
        and nx.id <> ce.id
        and public.stay_same_guest_v1(ce.id, nx.id)
    )
  order by ce.checkout_date desc;
end;
$function$;

-- due_guest_messages_v1: has_prev / has_next on each booking, four message kinds gated by them. Everything else is the live text.
create or replace function public.due_guest_messages_v1(p_now timestamp with time zone DEFAULT now())
 returns table(booking_id uuid, message_key text)
 language sql
 stable security definer
 set search_path to ''
as $function$
  with t as (select (p_now at time zone 'Asia/Manila')::date as d),
  b as (
    select bi.id, bi.checkin_date, bi.checkout_date, bi.updated_at, bi.guest_id,
           bi.checkout_date - bi.checkin_date as nights,
           -- D-290, direct chains (same guest_id, confirmed direct, one ends the day the other starts). has_next: another
           -- booking of this guest starts the day this one ends. has_prev: one ends the day this one starts and was made
           -- first. A chain that cannot be proven (no guest_id, no submitted_at) behaves as before.
           exists (select 1 from public.booking_inquiries n
                    where n.id <> bi.id and bi.guest_id is not null and n.guest_id = bi.guest_id
                      and n.property_id = bi.property_id and n.status = 'confirmed' and n.source = 'direct'
                      and n.checkin_date = bi.checkout_date) as has_next,
           exists (select 1 from public.booking_inquiries p
                    where p.id <> bi.id and bi.guest_id is not null and p.guest_id = bi.guest_id
                      and p.property_id = bi.property_id and p.status = 'confirmed' and p.source = 'direct'
                      and p.checkout_date = bi.checkin_date and p.submitted_at < bi.submitted_at) as has_prev
      from public.booking_inquiries bi, t
     where bi.status = 'confirmed'
       and bi.source = 'direct'
       and bi.checkout_date >= t.d
  ), due as (
    select b.id, 'confirmation'::text as k
      from b, t
     where b.updated_at > p_now - interval '48 hours'
       and b.checkout_date > t.d
       and not b.has_prev
    union all
    select b.id, 'pre_arrival'::text
      from b
     where p_now >= ((b.checkin_date - 2) + time '15:00') at time zone 'Asia/Manila'
       and p_now <  ((b.checkin_date - 2) + time '21:00') at time zone 'Asia/Manila'
       and not b.has_prev
       and not exists (
         select 1 from public.guest_message_log c
          where c.booking_id = b.id and c.message_key = 'confirmation'
            and c.created_at > ((b.checkin_date + time '14:00') at time zone 'Asia/Manila') - interval '48 hours')
    union all
    select b.id, 'mid_stay'::text
      from b
     where b.nights >= 5
       and p_now >= ((b.checkin_date + case when b.nights <= 6 then 3 else 4 end) + time '15:00') at time zone 'Asia/Manila'
       and p_now <  ((b.checkin_date + case when b.nights <= 6 then 3 else 4 end) + time '21:00') at time zone 'Asia/Manila'
    union all
    select b.id, 'checkout_reminder'::text
      from b
     where p_now >= (b.checkout_date + time '09:00') at time zone 'Asia/Manila'
       and p_now <  (b.checkout_date + time '12:00') at time zone 'Asia/Manila'
       and not b.has_next
    union all
    select b.id, 'after_departure'::text
      from b
     where p_now >= (b.checkout_date + time '16:00') at time zone 'Asia/Manila'
       and p_now <  (b.checkout_date + time '22:00') at time zone 'Asia/Manila'
       and not b.has_next
    union all
    select b.id, 'door_code_offer'::text
      from b
      join public.guest_profile_details g on g.guest_id = b.guest_id, t
     where g.id_on_file
       and b.checkin_date between t.d and t.d + 7
  )
  select d.id, d.k
    from due d
   where not exists (
     select 1 from public.guest_message_log l
      where l.booking_id = d.id
        and l.message_key = case d.k when 'door_code_offer' then 'door_code' else d.k end);
$function$;

-- verify_booking: the found stay is walked forward while the same guest checks in on its checkout date (at most 10 stays).
-- The answer carries the final checkout_date / checkout_time and the summed nights. Keys and PII rules are unchanged.
create or replace function public.verify_booking(p_checkin_date date, p_initial text DEFAULT NULL::text, p_property_id uuid DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
DECLARE
  v_cal     record;
  v_res     record;
  v_first   text;
  v_last    text;
  v_full    text;
  v_expired boolean;
  v_match   boolean;
  v_il      text;
  v_out_date date;
  v_out_nights integer;
  v_out_time time;
BEGIN
  -- Find the booking whose check-in date matches exactly. Confirmed only.
  SELECT id, guest_name, raw_summary, checkin_date, checkout_date, nights, checkin_time, checkout_time
  INTO v_cal
  FROM public.calendar_events
  WHERE property_id  = p_property_id
    AND status       = 'confirmed'
    AND checkin_date = p_checkin_date
  ORDER BY updated_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('found', false);
  END IF;

  -- Same-guest chain (D-290): follow the stays that start on the previous checkout date.
  WITH RECURSIVE chain AS (
    SELECT v_cal.id AS id, v_cal.checkout_date AS checkout_date, v_cal.nights AS nights,
           v_cal.checkout_time AS checkout_time, 0 AS depth
    UNION ALL
    SELECT n.id, n.checkout_date, coalesce(c.nights, 0) + n.nights, n.checkout_time, c.depth + 1
      FROM chain c
      JOIN LATERAL (
        SELECT ce.id, ce.checkout_date, coalesce(ce.nights, ce.checkout_date - ce.checkin_date) AS nights, ce.checkout_time
          FROM public.calendar_events ce
         WHERE ce.property_id   = p_property_id
           AND ce.status        = 'confirmed'
           AND ce.checkin_date  = c.checkout_date
           AND ce.checkout_date > c.checkout_date
           AND ce.id           <> c.id
           AND public.stay_same_guest_v1(c.id, ce.id)
         ORDER BY ce.updated_at DESC
         LIMIT 1
      ) n ON true
     WHERE c.depth < 10
  )
  SELECT checkout_date, nights, checkout_time
  INTO v_out_date, v_out_nights, v_out_time
  FROM chain
  ORDER BY depth DESC
  LIMIT 1;

  -- Expiry: checkout + 1 day grace (mirrors client computeExpiry).
  v_expired := (v_out_date + 1) < CURRENT_DATE;

  -- Expired bookings return dates only — never PII.
  IF v_expired THEN
    RETURN jsonb_build_object(
      'found', true, 'expired', true,
      'checkin_date', v_cal.checkin_date,
      'checkout_date', v_out_date,
      'nights', v_out_nights
    );
  END IF;

  -- Resolve name (mirror get_welcome_info: calendar first, else reservation cross-ref).
  IF v_cal.guest_name IS NOT NULL AND trim(v_cal.guest_name) <> '' THEN
    v_full := trim(v_cal.guest_name);
  ELSE
    SELECT guest_name INTO v_res
    FROM public.airbnb_reservations
    WHERE property_id = p_property_id
      AND status NOT IN ('cancelled')
      AND checkin_date BETWEEN v_cal.checkin_date - 2 AND v_cal.checkin_date + 2
    ORDER BY ABS(checkin_date - v_cal.checkin_date) ASC, created_at DESC
    LIMIT 1;
    v_full := CASE
      WHEN v_res.guest_name IS NOT NULL AND trim(v_res.guest_name) <> '' THEN trim(v_res.guest_name)
      ELSE coalesce(nullif(trim(v_cal.raw_summary), ''), 'Guest')
    END;
  END IF;

  v_first := trim(split_part(v_full, ' ', 1));
  v_last  := trim(split_part(v_full, ' ', 2));
  IF lower(v_first) IN ('reserved','airbnb','not','') THEN
    v_first := 'Guest'; v_last := NULL;
  END IF;

  -- Date-only step (no initial yet): dates only, no PII.
  IF p_initial IS NULL OR length(trim(p_initial)) = 0 THEN
    RETURN jsonb_build_object(
      'found', true, 'expired', false,
      'checkin_date', v_cal.checkin_date,
      'checkout_date', v_out_date,
      'nights', v_out_nights,
      'checkin_time', v_cal.checkin_time,
      'checkout_time', v_out_time
    );
  END IF;

  -- Initial match (case-insensitive, first OR last initial). Placeholder skips the check.
  v_il := lower(left(trim(p_initial), 1));
  IF lower(v_first) = 'guest' THEN
    v_match := true;
  ELSE
    v_match := (v_il = lower(left(v_first, 1)))
            OR (v_last IS NOT NULL AND v_last <> '' AND v_il = lower(left(v_last, 1)));
  END IF;

  IF NOT v_match THEN
    RETURN jsonb_build_object(
      'found', true, 'expired', false, 'match', false,
      'checkin_date', v_cal.checkin_date,
      'checkout_date', v_out_date,
      'nights', v_out_nights
    );
  END IF;

  RETURN jsonb_build_object(
    'found', true, 'expired', false, 'match', true,
    'first_name', v_first,
    'last_name',  nullif(v_last, ''),
    'full_name',  v_full,
    'checkin_date', v_cal.checkin_date,
    'checkout_date', v_out_date,
    'nights', v_out_nights,
    'checkin_time', v_cal.checkin_time,
    'checkout_time', v_out_time
  );
END;
$function$;

commit;
