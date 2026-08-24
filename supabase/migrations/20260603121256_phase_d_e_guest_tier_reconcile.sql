
-- ══════════════════════════════════════════════════════════════
-- PHASE D — Guest enrichment
-- ══════════════════════════════════════════════════════════════

-- D1: Add tier column to guests
--   NULL   = first-time guest (default)
--   'returning' = 2–3 stays
--   'vip'       = 4+ stays OR any single stay ≥ 10 nights
ALTER TABLE guests ADD COLUMN IF NOT EXISTS tier text DEFAULT NULL;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS total_stays integer DEFAULT 0;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS total_nights_stayed integer DEFAULT 0;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS first_stay_date date DEFAULT NULL;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS last_stay_date date DEFAULT NULL;

-- D2: Backfill guest stats from airbnb_reservations (completed stays only)
UPDATE guests g SET
  total_stays         = sub.stay_count,
  total_nights_stayed = sub.night_total,
  first_stay_date     = sub.first_stay,
  last_stay_date      = sub.last_stay,
  tier = CASE
    WHEN sub.stay_count >= 4 OR sub.night_total >= 10 THEN 'vip'
    WHEN sub.stay_count >= 2 THEN 'returning'
    ELSE NULL
  END,
  updated_at = now()
FROM (
  SELECT
    guest_id,
    COUNT(*) FILTER (WHERE status IN ('completed','confirmed')) AS stay_count,
    COALESCE(SUM(nights) FILTER (WHERE status = 'completed'), 0) AS night_total,
    MIN(checkin_date) AS first_stay,
    MAX(checkin_date) AS last_stay
  FROM airbnb_reservations
  WHERE guest_id IS NOT NULL
  GROUP BY guest_id
) sub
WHERE g.id = sub.guest_id;

-- D3: Backfill returning_guest_alerts for completed bookings where guest had prior stays
-- This is a historical record — telegram_sent=true since notifications weren't sent at the time
INSERT INTO returning_guest_alerts (
  property_id, guest_name, current_checkin, current_checkout, current_nights,
  previous_stays, total_nights, last_stay_checkin, last_stay_checkout,
  telegram_sent, telegram_sent_at, source
)
SELECT
  ar.property_id,
  ar.guest_name,
  ar.checkin_date,
  ar.checkout_date,
  ar.nights,
  (prior.stay_count - 1) AS previous_stays,    -- excludes the current stay
  prior.total_nights AS total_nights,
  prior.prev_checkin AS last_stay_checkin,
  prior.prev_checkout AS last_stay_checkout,
  true AS telegram_sent,                        -- historical; alert wasn't sent in real-time
  ar.created_at AS telegram_sent_at,
  'backfill_phase_d' AS source
FROM airbnb_reservations ar
JOIN (
  -- For each reservation, count how many completed stays the same guest had BEFORE it
  SELECT
    ar2.id AS reservation_id,
    COUNT(*) OVER (PARTITION BY ar2.guest_id ORDER BY ar2.checkin_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS stay_count,
    SUM(ar2.nights) OVER (PARTITION BY ar2.guest_id ORDER BY ar2.checkin_date ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS total_nights,
    LAG(ar2.checkin_date) OVER (PARTITION BY ar2.guest_id ORDER BY ar2.checkin_date) AS prev_checkin,
    LAG(ar2.checkout_date) OVER (PARTITION BY ar2.guest_id ORDER BY ar2.checkin_date) AS prev_checkout
  FROM airbnb_reservations ar2
  WHERE ar2.guest_id IS NOT NULL AND ar2.status IN ('completed','confirmed')
) prior ON prior.reservation_id = ar.id
WHERE prior.stay_count >= 2   -- only rows where guest had at least 1 prior stay
  AND ar.status IN ('completed','confirmed')
ON CONFLICT DO NOTHING;

-- ══════════════════════════════════════════════════════════════
-- PHASE E — Reconciliation function
-- ══════════════════════════════════════════════════════════════

-- E1: Core reconciliation function
-- Called after a payout email confirms a booking is financially settled.
-- Authority model:
--   FINANCIAL fields (host_payout, guest_paid) → always from airbnb_transactions (CSV truth)
--   DATE fields (checkin, checkout)             → from transactions for COMPLETED bookings only
--   OPERATIONAL fields (guest_name, guest_count, times, status) → never touched here (email authority)
CREATE OR REPLACE FUNCTION reconcile_reservation_from_transactions(p_code TEXT)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_host_payout   NUMERIC;
  v_guest_paid    NUMERIC;
  v_checkout_date DATE;
  v_checkin_date  DATE;
  v_res_status    TEXT;
  v_changed       BOOLEAN := false;
BEGIN
  -- Only proceed if this code has transaction rows
  IF NOT EXISTS (
    SELECT 1 FROM public.airbnb_transactions
    WHERE confirmation_code = p_code AND row_type IN ('reservation','adjustment')
  ) THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'no_transactions');
  END IF;

  -- Net host payout = sum of reservation amounts + any adjustments (adjustments are signed)
  SELECT
    SUM(amount),
    MAX(end_date),
    MIN(start_date)
  INTO v_host_payout, v_checkout_date, v_checkin_date
  FROM public.airbnb_transactions
  WHERE confirmation_code = p_code
    AND row_type IN ('reservation', 'adjustment');

  -- Guest paid = sum of gross_earnings from reservation rows only
  SELECT SUM(gross_earnings)
  INTO v_guest_paid
  FROM public.airbnb_transactions
  WHERE confirmation_code = p_code AND row_type = 'reservation';

  -- Get current status to decide if date reconciliation applies
  SELECT status INTO v_res_status
  FROM public.airbnb_reservations
  WHERE confirmation_code = p_code;

  IF v_res_status IS NULL THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'reservation_not_found');
  END IF;

  -- For COMPLETED bookings: reconcile financials AND dates (stay is over, CSV is ground truth)
  -- For CONFIRMED bookings: reconcile financials only (stay is future, email dates more current)
  -- For CANCELLED: never touch
  IF v_res_status = 'cancelled' THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'cancelled');
  END IF;

  IF v_res_status = 'completed' THEN
    UPDATE public.airbnb_reservations SET
      host_payout    = COALESCE(v_host_payout, host_payout),
      payout_amount  = COALESCE(v_host_payout, payout_amount),
      guest_paid     = COALESCE(v_guest_paid, guest_paid),
      checkin_date   = COALESCE(v_checkin_date, checkin_date),
      checkout_date  = COALESCE(v_checkout_date, checkout_date),
      updated_at     = now()
    WHERE confirmation_code = p_code;
  ELSE
    -- Confirmed/upcoming: financials only, dates stay from email
    UPDATE public.airbnb_reservations SET
      host_payout    = COALESCE(v_host_payout, host_payout),
      payout_amount  = COALESCE(v_host_payout, payout_amount),
      guest_paid     = COALESCE(v_guest_paid, guest_paid),
      updated_at     = now()
    WHERE confirmation_code = p_code;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'code', p_code,
    'status', v_res_status,
    'host_payout', v_host_payout,
    'guest_paid', v_guest_paid,
    'checkout_date', v_checkout_date
  );
END;
$$;

-- E2: Convenience function — reconcile ALL completed reservations in one call
-- Safe to run after any CSV import.
CREATE OR REPLACE FUNCTION reconcile_all_completed_reservations()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_code  TEXT;
  v_total INTEGER := 0;
  v_ok    INTEGER := 0;
  v_skip  INTEGER := 0;
  v_result JSONB;
BEGIN
  FOR v_code IN
    SELECT DISTINCT confirmation_code
    FROM public.airbnb_reservations
    WHERE status = 'completed'
      AND confirmation_code IS NOT NULL
    ORDER BY confirmation_code
  LOOP
    v_result := public.reconcile_reservation_from_transactions(v_code);
    v_total := v_total + 1;
    IF (v_result->>'skipped')::boolean THEN
      v_skip := v_skip + 1;
    ELSE
      v_ok := v_ok + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('total', v_total, 'reconciled', v_ok, 'skipped', v_skip);
END;
$$;

-- E3: Function to update guest stats + tier after a new stay is added
-- Called by airbnb-email-sync after upsert so guest record always reflects current truth.
CREATE OR REPLACE FUNCTION refresh_guest_stats(p_guest_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_stays  INTEGER;
  v_nights INTEGER;
  v_first  DATE;
  v_last   DATE;
  v_tier   TEXT;
BEGIN
  SELECT
    COUNT(*) FILTER (WHERE status IN ('completed','confirmed')),
    COALESCE(SUM(nights) FILTER (WHERE status = 'completed'), 0),
    MIN(checkin_date),
    MAX(checkin_date)
  INTO v_stays, v_nights, v_first, v_last
  FROM public.airbnb_reservations
  WHERE guest_id = p_guest_id;

  v_tier := CASE
    WHEN v_stays >= 4 OR v_nights >= 10 THEN 'vip'
    WHEN v_stays >= 2 THEN 'returning'
    ELSE NULL
  END;

  UPDATE public.guests SET
    total_stays = v_stays,
    total_nights_stayed = v_nights,
    first_stay_date = v_first,
    last_stay_date = v_last,
    tier = v_tier,
    updated_at = now()
  WHERE id = p_guest_id;
END;
$$;
;
