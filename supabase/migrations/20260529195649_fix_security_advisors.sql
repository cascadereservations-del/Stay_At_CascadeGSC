
-- ══════════════════════════════════════════════════════════════════
-- FIX 1: RLS policies — user_metadata → app_metadata + (select …)
-- user_metadata is user-editable; app_metadata is service-role-only.
-- (select …) wrapper evaluates once per query, not per row (fixes
-- "Auth RLS Initialization Plan" advisory simultaneously).
-- ══════════════════════════════════════════════════════════════════

-- transactions
DROP POLICY IF EXISTS transactions_owner_admin_all ON public.transactions;
CREATE POLICY transactions_owner_admin_all ON public.transactions
  FOR ALL TO authenticated
  USING      ((select auth.jwt() -> 'app_metadata' ->> 'role') = ANY (ARRAY['owner','admin']))
  WITH CHECK ((select auth.jwt() -> 'app_metadata' ->> 'role') = ANY (ARRAY['owner','admin']));

-- guests
DROP POLICY IF EXISTS guests_owner_admin_all ON public.guests;
CREATE POLICY guests_owner_admin_all ON public.guests
  FOR ALL TO authenticated
  USING      ((select auth.jwt() -> 'app_metadata' ->> 'role') = ANY (ARRAY['owner','admin']))
  WITH CHECK ((select auth.jwt() -> 'app_metadata' ->> 'role') = ANY (ARRAY['owner','admin']));

-- expense_categories
DROP POLICY IF EXISTS expense_categories_owner_admin_all ON public.expense_categories;
CREATE POLICY expense_categories_owner_admin_all ON public.expense_categories
  FOR ALL TO authenticated
  USING      ((select auth.jwt() -> 'app_metadata' ->> 'role') = ANY (ARRAY['owner','admin']))
  WITH CHECK ((select auth.jwt() -> 'app_metadata' ->> 'role') = ANY (ARRAY['owner','admin']));

-- airbnb_transactions
DROP POLICY IF EXISTS airbnb_txn_owner_admin_all ON public.airbnb_transactions;
CREATE POLICY airbnb_txn_owner_admin_all ON public.airbnb_transactions
  FOR ALL TO authenticated
  USING      ((select auth.jwt() -> 'app_metadata' ->> 'role') = ANY (ARRAY['owner','admin']))
  WITH CHECK ((select auth.jwt() -> 'app_metadata' ->> 'role') = ANY (ARRAY['owner','admin']));

-- cleaner_rate_schedule
DROP POLICY IF EXISTS cleaner_rate_owner_admin_all ON public.cleaner_rate_schedule;
CREATE POLICY cleaner_rate_owner_admin_all ON public.cleaner_rate_schedule
  FOR ALL TO authenticated
  USING      ((select auth.jwt() -> 'app_metadata' ->> 'role') = ANY (ARRAY['owner','admin']))
  WITH CHECK ((select auth.jwt() -> 'app_metadata' ->> 'role') = ANY (ARRAY['owner','admin']));

-- ══════════════════════════════════════════════════════════════════
-- FIX 2: Security Definer Views → security_invoker = on
-- Recreate all three airbnb views with security_invoker so they
-- respect the calling user's RLS context, not the definer's.
-- ══════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW public.airbnb_cleans
WITH (security_invoker = on) AS
SELECT
  confirmation_code,
  guest_name,
  start_date,
  end_date AS clean_date,
  nights,
  ( SELECT s.regular_rate FROM public.cleaner_rate_schedule s
    WHERE s.property_id = r.property_id AND s.effective_from <= r.end_date
    ORDER BY s.effective_from DESC LIMIT 1 ) AS applicable_regular_rate,
  ( SELECT s.general_rate FROM public.cleaner_rate_schedule s
    WHERE s.property_id = r.property_id AND s.effective_from <= r.end_date
    ORDER BY s.effective_from DESC LIMIT 1 ) AS applicable_general_rate
FROM public.airbnb_transactions r
WHERE row_type = 'reservation' AND end_date IS NOT NULL;

CREATE OR REPLACE VIEW public.airbnb_guest_summary
WITH (security_invoker = on) AS
SELECT
  guest_name,
  count(*)                        AS stays,
  sum(nights)                     AS total_nights,
  round(sum(amount), 2)           AS total_host_net,
  min(start_date)                 AS first_stay,
  max(end_date)                   AS last_checkout
FROM public.airbnb_transactions
WHERE row_type = 'reservation' AND guest_name IS NOT NULL
GROUP BY guest_name
ORDER BY round(sum(amount), 2) DESC;

CREATE OR REPLACE VIEW public.airbnb_monthly_revenue
WITH (security_invoker = on) AS
SELECT
  to_char(date_trunc('month', end_date::timestamptz), 'YYYY-MM') AS month,
  count(*)                                                         AS stays,
  sum(nights)                                                      AS room_nights,
  round(sum(gross_earnings), 2)                                    AS gross_earnings,
  round(sum(service_fee),    2)                                    AS airbnb_service_fees,
  round(sum(amount),         2)                                    AS host_net,
  round(avg(amount / NULLIF(nights, 0)::numeric), 2)              AS avg_net_per_night
FROM public.airbnb_transactions
WHERE row_type = 'reservation' AND end_date IS NOT NULL
GROUP BY to_char(date_trunc('month', end_date::timestamptz), 'YYYY-MM')
ORDER BY 1;

-- ══════════════════════════════════════════════════════════════════
-- FIX 3: Also update CONVENTIONS — note role check uses app_metadata
-- (No SQL needed; KB update follows separately)
-- ══════════════════════════════════════════════════════════════════
;
