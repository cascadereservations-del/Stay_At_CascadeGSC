
-- Fix SECURITY DEFINER on v_income_canonical by recreating with security_invoker = on
-- Also add income_stage to SELECT (was omitted in original creation)
CREATE OR REPLACE VIEW public.v_income_canonical
WITH (security_invoker = on)
AS
SELECT
  id, property_id, created_at, updated_at,
  txn_type, category, status, source,
  transaction_date, gross_amount, currency,
  or_number, payee_name, payee_tin,
  tax_base, tax_amount, tax_treatment,
  receipt_image_path, ocr_confidence, ocr_raw,
  booking_id, logged_by, notes, external_ref,
  income_stage
FROM transactions
WHERE txn_type = 'income'
  AND (
    (source = 'airbnb'           AND status = 'confirmed')
 OR (source = 'airbnb_email'    AND status = 'pending_review')
 OR (source <> ALL (ARRAY['airbnb','airbnb_email','airbnb_payout_email']))
  );
;
