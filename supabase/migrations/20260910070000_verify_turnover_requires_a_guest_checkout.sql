-- verify_turnover: only check a turnover when a guest actually checked out.
--
-- The function looked for a cleaning_sessions row on the given date and never
-- asked whether anyone had left that day. turnover-verifier calls it
-- unconditionally for yesterday, so every day without a guest checkout produced
-- "No cleaning session found for this checkout" in the Finance group.
--
-- Observed 2026-09-10:
--   2026-09-09  only a BLOCKED airbnb event ended        -> alerted, false alarm
--   2026-09-08  nothing ended at all                     -> alerted, false alarm
--   2026-09-07  a CONFIRMED guest stay ended, 0 sessions -> never checked
--
-- It alerted on the two days that did not matter and missed the one that did.
-- A daily false alarm is worse than silence: it teaches everyone to scroll past
-- turnover alerts, which is the exact failure the alert exists to prevent.
--
-- Lloyd's decision 2026-09-10: a blocked period ending is not a turnover. Only
-- a confirmed guest stay requires cleaning. Statuses in use are 'confirmed',
-- 'blocked' and 'cancelled', across sources 'airbnb' and 'direct'; both sources
-- carry real guests, so the filter is on status alone.
--
-- New behaviour: when no confirmed stay ends on p_checkout_date the function
-- returns check_passed = true with issues = ['no_checkout_scheduled'], so the
-- caller can stay silent while still recording that the day was examined.
-- Every other branch is unchanged.

create or replace function public.verify_turnover(p_checkout_date date, p_property_id uuid default null::uuid)
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

-- Assertions against the live data that motivated the change. These run inside
-- the apply transaction, so a wrong result rolls the whole thing back.
do $$
declare
  v_property_id uuid;
  v_blocked jsonb;
  v_nothing jsonb;
  v_real_miss jsonb;
begin
  select id into v_property_id from public.properties limit 1;

  -- 2026-09-09: only a blocked event ended. Must now be silent.
  v_blocked := public.verify_turnover('2026-09-09'::date, v_property_id);
  if not (v_blocked->'issues' ? 'no_checkout_scheduled') then
    raise exception '2026-09-09 (blocked period) should report no_checkout_scheduled, got %', v_blocked->'issues';
  end if;

  -- 2026-09-08: nothing ended at all. Must now be silent.
  v_nothing := public.verify_turnover('2026-09-08'::date, v_property_id);
  if not (v_nothing->'issues' ? 'no_checkout_scheduled') then
    raise exception '2026-09-08 (no event) should report no_checkout_scheduled, got %', v_nothing->'issues';
  end if;

  -- 2026-09-07: a confirmed guest stay ended with no cleaning session.
  -- This one is a genuine miss and must STILL fail.
  v_real_miss := public.verify_turnover('2026-09-07'::date, v_property_id);
  if not (v_real_miss->'issues' ? 'no_session_found') then
    raise exception '2026-09-07 (real missed turnover) must still report no_session_found, got %', v_real_miss->'issues';
  end if;
  if (v_real_miss->>'check_passed')::boolean then
    raise exception '2026-09-07 must not pass - it is a real missed turnover';
  end if;

  raise notice 'verify_turnover: false alarms silenced, real miss still caught';
end $$;
