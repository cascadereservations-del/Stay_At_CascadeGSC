
-- Enable RLS on calendar_events (blocks anon direct reads)
ALTER TABLE public.calendar_events ENABLE ROW LEVEL SECURITY;

-- Authenticated users (admin/owner) can read all events for their work
CREATE POLICY "authenticated_read_all" ON public.calendar_events
  FOR SELECT TO authenticated USING (true);

-- Service role bypasses RLS automatically; no policy needed for it.
-- Anon gets no direct read policy — must go through SECURITY DEFINER functions.

-- Convert get_welcome_info to SECURITY DEFINER so it continues to work
-- for any RPC callers now that anon can't directly read calendar_events.
CREATE OR REPLACE FUNCTION public.get_welcome_info(
  p_date        date    DEFAULT CURRENT_DATE,
  p_property_id uuid    DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_cal       record;
  v_res       record;
  v_first     text;
  v_last      text;
  v_full_name text;
BEGIN
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

  IF v_cal.guest_name IS NOT NULL AND trim(v_cal.guest_name) <> '' THEN
    v_full_name := trim(v_cal.guest_name);
  ELSE
    SELECT guest_name INTO v_res
    FROM public.airbnb_reservations
    WHERE property_id  = p_property_id
      AND status       NOT IN ('cancelled')
      AND checkin_date BETWEEN v_cal.checkin_date - 2 AND v_cal.checkin_date + 2
    ORDER BY ABS(checkin_date - v_cal.checkin_date) ASC, created_at DESC
    LIMIT 1;
    v_full_name := CASE
      WHEN v_res.guest_name IS NOT NULL AND trim(v_res.guest_name) <> ''
        THEN trim(v_res.guest_name)
      ELSE coalesce(nullif(trim(v_cal.raw_summary), ''), 'Guest')
    END;
  END IF;

  v_first := trim(split_part(v_full_name, ' ', 1));
  v_last  := trim(split_part(v_full_name, ' ', 2));
  IF lower(v_first) IN ('reserved', 'airbnb', 'not', '') THEN
    v_first := 'Guest'; v_last := null;
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
$function$;

GRANT EXECUTE ON FUNCTION public.get_welcome_info(date, uuid) TO anon, authenticated;
;
