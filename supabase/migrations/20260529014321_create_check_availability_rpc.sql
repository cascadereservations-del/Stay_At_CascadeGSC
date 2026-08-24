
CREATE OR REPLACE FUNCTION public.check_availability(
  p_checkin     date,
  p_checkout    date,
  p_property_id uuid DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_conflicts jsonb;
BEGIN
  IF p_checkin IS NULL OR p_checkout IS NULL THEN
    RETURN jsonb_build_object('available', false, 'error', 'dates_required');
  END IF;
  IF p_checkin >= p_checkout THEN
    RETURN jsonb_build_object('available', false, 'error', 'checkin_must_be_before_checkout');
  END IF;
  IF p_checkin < CURRENT_DATE THEN
    RETURN jsonb_build_object('available', false, 'error', 'checkin_in_past');
  END IF;

  -- Overlap: existing event blocks if it starts before our checkout AND ends after our checkin.
  -- Checkout day of existing booking == our checkin day is allowed (back-to-back).
  SELECT jsonb_agg(jsonb_build_object(
    'checkin',   to_char(checkin_date,  'YYYY-MM-DD'),
    'checkout',  to_char(checkout_date, 'YYYY-MM-DD'),
    'summary',   COALESCE(raw_summary, 'Blocked')
  ))
  INTO v_conflicts
  FROM public.calendar_events
  WHERE property_id = p_property_id
    AND status NOT IN ('cancelled')
    AND checkin_date  < p_checkout
    AND checkout_date > p_checkin;

  IF v_conflicts IS NULL THEN
    RETURN jsonb_build_object('available', true, 'conflicts', '[]'::jsonb);
  ELSE
    RETURN jsonb_build_object('available', false, 'conflicts', v_conflicts);
  END IF;
END;
$$;

-- Expose to anon so the booking form can check live without auth
GRANT EXECUTE ON FUNCTION public.check_availability(date, date, uuid) TO anon;
;
