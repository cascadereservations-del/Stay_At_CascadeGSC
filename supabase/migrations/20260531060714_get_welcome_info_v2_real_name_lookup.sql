
-- get_welcome_info v2: cross-references airbnb_reservations for real guest name
-- when calendar_events has null guest_name (Airbnb iCal anonymises to "Reserved")
CREATE OR REPLACE FUNCTION public.get_welcome_info(
  p_date        date    DEFAULT CURRENT_DATE,
  p_property_id uuid    DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_cal       record;
  v_res       record;
  v_first     text;
  v_last      text;
  v_full_name text;
BEGIN
  -- 1. Find the active calendar event
  SELECT guest_name, raw_summary, checkin_date, checkout_date, nights, checkin_time, checkout_time
  INTO v_cal
  FROM public.calendar_events
  WHERE property_id   = p_property_id
    AND status        = 'confirmed'
    AND checkin_date <= p_date
    AND checkout_date > p_date
  ORDER BY checkin_date DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('found', false);
  END IF;

  -- 2. Determine name: prefer calendar guest_name, else cross-reference airbnb_reservations
  --    Match on overlapping date ranges (±2 days tolerance for timezone drift)
  IF v_cal.guest_name IS NOT NULL AND trim(v_cal.guest_name) <> '' THEN
    v_full_name := trim(v_cal.guest_name);
  ELSE
    SELECT guest_name
    INTO v_res
    FROM public.airbnb_reservations
    WHERE property_id   = p_property_id
      AND status        NOT IN ('cancelled')
      AND checkin_date  BETWEEN v_cal.checkin_date - 2 AND v_cal.checkin_date + 2
    ORDER BY ABS(checkin_date - v_cal.checkin_date) ASC, created_at DESC
    LIMIT 1;

    v_full_name := CASE
      WHEN v_res.guest_name IS NOT NULL AND trim(v_res.guest_name) <> ''
        THEN trim(v_res.guest_name)
      ELSE coalesce(nullif(trim(v_cal.raw_summary), ''), 'Guest')
    END;
  END IF;

  -- 3. Extract first and last name
  v_first := trim(split_part(v_full_name, ' ', 1));
  v_last  := trim(split_part(v_full_name, ' ', 2));

  -- Sanitise placeholder values
  IF lower(v_first) IN ('reserved', 'airbnb', 'not', '') THEN
    v_first := 'Guest';
    v_last  := null;
  END IF;

  RETURN jsonb_build_object(
    'found',         true,
    'first_name',    v_first,
    'last_name',     nullif(v_last, ''),
    'full_name',     v_full_name,
    'checkin_date',  v_cal.checkin_date,
    'checkout_date', v_cal.checkout_date,
    'nights',        v_cal.nights,
    'checkin_time',  v_cal.checkin_time,
    'checkout_time', v_cal.checkout_time
  );
END;
$$;
;
