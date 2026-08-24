
CREATE OR REPLACE FUNCTION public.verify_booking(
  p_checkin_date date,
  p_initial      text DEFAULT NULL,
  p_property_id  uuid DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
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

REVOKE ALL ON FUNCTION public.verify_booking(date, text, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.verify_booking(date, text, uuid) TO anon, authenticated;
;
