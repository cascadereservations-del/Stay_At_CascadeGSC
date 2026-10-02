-- Compensating rollback for release stay_chains_20261002 (D-290). Restores the four functions to their text before the
-- release (md5(prosrc) verify_turnover 895d50d992b48fa4d4c264a1a15f819b, get_missed_cleanings 321f462e7b3e0cfa5ce33d09234f08cb,
-- verify_booking 32597e37d1fc428984d2070ebb53d703, due_guest_messages_v1 4513e1e984dc255f2fbf88764184fe89) and drops the six
-- new functions. CREATE OR REPLACE keeps every grant. Nothing else depends on the new functions; the edge functions only call
-- the four old ones. The power-watch cron change (supabase/sql/2026-10-02-s67-power-watch-15m.sql) is separate; undo it with the
-- one-line cron.alter_job at the foot of that file.
-- After a rollback a same-guest chain is again two stays: turnover-verifier raises no_session_found for the first checkout.
begin;

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
  order by ce.checkout_date desc;
end;
$function$;

create or replace function public.due_guest_messages_v1(p_now timestamp with time zone DEFAULT now())
 returns table(booking_id uuid, message_key text)
 language sql
 stable security definer
 set search_path to ''
as $function$
  with t as (select (p_now at time zone 'Asia/Manila')::date as d),
  b as (
    select bi.id, bi.checkin_date, bi.checkout_date, bi.updated_at, bi.guest_id,
           bi.checkout_date - bi.checkin_date as nights
      from public.booking_inquiries bi, t
     where bi.status = 'confirmed'
       and bi.source = 'direct'
       and bi.checkout_date >= t.d
  ), due as (
    select b.id, 'confirmation'::text as k
      from b, t
     where b.updated_at > p_now - interval '48 hours'
       and b.checkout_date > t.d
    union all
    select b.id, 'pre_arrival'::text
      from b
     where p_now >= ((b.checkin_date - 2) + time '15:00') at time zone 'Asia/Manila'
       and p_now <  ((b.checkin_date - 2) + time '21:00') at time zone 'Asia/Manila'
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
    union all
    select b.id, 'after_departure'::text
      from b
     where p_now >= (b.checkout_date + time '16:00') at time zone 'Asia/Manila'
       and p_now <  (b.checkout_date + time '22:00') at time zone 'Asia/Manila'
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
BEGIN
  -- Find the booking whose check-in date matches exactly. Confirmed only.
  SELECT guest_name, raw_summary, checkin_date, checkout_date, nights, checkin_time, checkout_time
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

  -- Expiry: checkout + 1 day grace (mirrors client computeExpiry).
  v_expired := (v_cal.checkout_date + 1) < CURRENT_DATE;

  -- Expired bookings return dates only — never PII.
  IF v_expired THEN
    RETURN jsonb_build_object(
      'found', true, 'expired', true,
      'checkin_date', v_cal.checkin_date,
      'checkout_date', v_cal.checkout_date,
      'nights', v_cal.nights
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
      'checkout_date', v_cal.checkout_date,
      'nights', v_cal.nights,
      'checkin_time', v_cal.checkin_time,
      'checkout_time', v_cal.checkout_time
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
      'checkout_date', v_cal.checkout_date,
      'nights', v_cal.nights
    );
  END IF;

  RETURN jsonb_build_object(
    'found', true, 'expired', false, 'match', true,
    'first_name', v_first,
    'last_name',  nullif(v_last, ''),
    'full_name',  v_full,
    'checkin_date', v_cal.checkin_date,
    'checkout_date', v_cal.checkout_date,
    'nights', v_cal.nights,
    'checkin_time', v_cal.checkin_time,
    'checkout_time', v_cal.checkout_time
  );
END;
$function$;

drop function if exists public.guests_missing_details_v1(uuid[]);
drop function if exists public.system_task_close_v1(text, text, text);
drop function if exists public.stay_chains_v1(uuid, date, date);
drop function if exists public.stay_continues_v1(uuid, date);
drop function if exists public.stay_same_guest_v1(uuid, uuid);
drop function if exists public.stay_uid_inquiry_v1(text);

commit;
