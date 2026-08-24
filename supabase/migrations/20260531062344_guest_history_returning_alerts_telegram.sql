
-- ── 1. Telegram config placeholders (fill via Supabase Dashboard → Table Editor) ──
INSERT INTO public.app_settings (key, value) VALUES
  ('telegram_bot_token',       '"PASTE_BOT_TOKEN_HERE"'::jsonb),
  ('telegram_marifel_chat_id', '"PASTE_MARIFEL_CHAT_ID_HERE"'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- ── 2. Returning-guest alerts table ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.returning_guest_alerts (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at        timestamptz DEFAULT now(),
  property_id       uuid        REFERENCES public.properties(id),
  guest_name        text        NOT NULL,
  current_checkin   date,
  current_checkout  date,
  current_nights    int,
  previous_stays    int         DEFAULT 0,
  total_nights      int         DEFAULT 0,
  last_stay_checkin date,
  last_stay_checkout date,
  telegram_sent     boolean     DEFAULT false,
  telegram_sent_at  timestamptz,
  source            text        DEFAULT 'welcome_guide'
);

ALTER TABLE public.returning_guest_alerts ENABLE ROW LEVEL SECURITY;
-- No public read/write; only service role and SECURITY DEFINER functions can touch it.

-- ── 3. get_guest_history ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_guest_history(
  p_full_name   text,
  p_property_id uuid DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_first      text;
  v_count      int  := 0;
  v_nights_sum int  := 0;
  v_last       record;
BEGIN
  v_first := trim(split_part(trim(p_full_name), ' ', 1));

  -- Count past completed stays matching this guest (full name preferred, first name fallback)
  SELECT COUNT(*), COALESCE(SUM(r.nights), 0)
  INTO v_count, v_nights_sum
  FROM public.airbnb_reservations r
  WHERE r.property_id = p_property_id
    AND r.status IN ('completed', 'confirmed')
    AND r.checkout_date < CURRENT_DATE
    AND (
      lower(r.guest_name) = lower(p_full_name)
      OR lower(r.guest_name) LIKE lower(v_first) || ' %'
      OR lower(r.guest_name) LIKE '% ' || lower(v_first)
    );

  -- Most recent completed stay
  SELECT r.checkin_date, r.checkout_date, r.nights, r.guest_name
  INTO v_last
  FROM public.airbnb_reservations r
  WHERE r.property_id = p_property_id
    AND r.status IN ('completed', 'confirmed')
    AND r.checkout_date < CURRENT_DATE
    AND (
      lower(r.guest_name) = lower(p_full_name)
      OR lower(r.guest_name) LIKE lower(v_first) || ' %'
    )
  ORDER BY r.checkout_date DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'is_returning',   v_count > 0,
    'previous_stays', v_count,
    'total_stays',    v_count + 1,   -- includes current stay
    'total_nights',   v_nights_sum,
    'last_stay', CASE WHEN v_last IS NOT NULL THEN jsonb_build_object(
      'checkin',  v_last.checkin_date,
      'checkout', v_last.checkout_date,
      'nights',   v_last.nights
    ) ELSE NULL END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_guest_history TO anon;

-- ── 4. log_returning_guest_alert (logs + fires Telegram via pg_net) ───────────────
CREATE OR REPLACE FUNCTION public.log_returning_guest_alert(
  p_guest_name         text,
  p_current_checkin    date,
  p_current_checkout   date,
  p_current_nights     int,
  p_previous_stays     int,
  p_total_nights       int,
  p_last_stay_checkin  date DEFAULT NULL,
  p_last_stay_checkout date DEFAULT NULL,
  p_property_id        uuid DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id        uuid;
  v_bot_token text;
  v_chat_id   text;
  v_ordinal   text;
  v_msg       text;
BEGIN
  -- Insert log record
  INSERT INTO public.returning_guest_alerts (
    property_id, guest_name,
    current_checkin, current_checkout, current_nights,
    previous_stays, total_nights,
    last_stay_checkin, last_stay_checkout
  ) VALUES (
    p_property_id, p_guest_name,
    p_current_checkin, p_current_checkout, p_current_nights,
    p_previous_stays, p_total_nights,
    p_last_stay_checkin, p_last_stay_checkout
  ) RETURNING id INTO v_id;

  -- Read Telegram credentials from app_settings
  SELECT (value #>> '{}') INTO v_bot_token
  FROM public.app_settings WHERE key = 'telegram_bot_token';

  SELECT (value #>> '{}') INTO v_chat_id
  FROM public.app_settings WHERE key = 'telegram_marifel_chat_id';

  -- Only fire if credentials are configured (not placeholder)
  IF v_bot_token IS NULL OR v_bot_token LIKE '%PASTE%'
  OR v_chat_id  IS NULL OR v_chat_id  LIKE '%PASTE%' THEN
    RETURN v_id;  -- logged but not sent yet
  END IF;

  -- Ordinal suffix
  v_ordinal := CASE (p_previous_stays + 1)
    WHEN 1 THEN '1st' WHEN 2 THEN '2nd' WHEN 3 THEN '3rd'
    ELSE (p_previous_stays + 1)::text || 'th'
  END;

  -- Build Telegram message
  v_msg :=
    '🔔 *Returning Guest Alert*' || E'\n\n' ||
    '👤 *' || p_guest_name || '*' || E'\n' ||
    '📅 ' || to_char(p_current_checkin,  'Mon DD') || ' → ' ||
             to_char(p_current_checkout, 'Mon DD, YYYY') ||
             ' (' || p_current_nights || ' night' || CASE WHEN p_current_nights = 1 THEN '' ELSE 's' END || ')' || E'\n' ||
    '🏠 Visit *' || v_ordinal || '* at Cascade Hideaway' || E'\n\n' ||
    '📊 *Guest History*' || E'\n' ||
    '• Previous stays: ' || p_previous_stays || E'\n' ||
    '• Total nights stayed: ' || p_total_nights ||
    CASE WHEN p_last_stay_checkin IS NOT NULL THEN
      E'\n• Last visit: ' || to_char(p_last_stay_checkin, 'Mon DD') ||
      ' → ' || to_char(p_last_stay_checkout, 'Mon DD, YYYY')
    ELSE '' END ||
    E'\n\n' ||
    '_Verified via Welcome Guide_ ✓';

  -- Async HTTP call to Telegram (pg_net — non-blocking)
  PERFORM net.http_post(
    url     := 'https://api.telegram.org/bot' || v_bot_token || '/sendMessage',
    body    := jsonb_build_object(
                 'chat_id',    v_chat_id,
                 'text',       v_msg,
                 'parse_mode', 'Markdown'
               ),
    headers := '{"Content-Type":"application/json"}'::jsonb
  );

  UPDATE public.returning_guest_alerts
  SET telegram_sent = true, telegram_sent_at = now()
  WHERE id = v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.log_returning_guest_alert TO anon;
;
