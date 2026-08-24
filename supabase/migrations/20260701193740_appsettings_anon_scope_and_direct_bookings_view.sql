
-- 1) Scope anon read of app_settings: block secrets/PII, keep public config readable.
DROP POLICY IF EXISTS "anon select" ON public.app_settings;
CREATE POLICY "anon select public" ON public.app_settings
  FOR SELECT TO anon
  USING (
        key NOT ILIKE '%token%'
    AND key NOT ILIKE '%secret%'
    AND key NOT ILIKE '%pin_hash%'
    AND key NOT ILIKE '%ical%'
    AND key NOT ILIKE '%chat_id%'
    AND key NOT IN ('email_recipients', 'users')
  );

-- 2) Read-only view of direct bookings for the admin dashboard (no email/phone PII;
--    view runs with owner rights so anon can read it without direct table access).
CREATE OR REPLACE VIEW public.v_direct_bookings
WITH (security_invoker = false) AS
SELECT
  id,
  upper(left(id::text, 8))            AS ref,
  guest_name,
  checkin_date,
  checkout_date,
  (checkout_date - checkin_date)      AS nights,
  pax,
  total_amount,
  deposit_amount,
  status,
  (receipt_image_path IS NOT NULL)    AS has_receipt,
  updated_at
FROM public.booking_inquiries
WHERE source = 'direct';

GRANT SELECT ON public.v_direct_bookings TO anon, authenticated;
;
