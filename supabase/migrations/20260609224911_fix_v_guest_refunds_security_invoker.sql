
DROP VIEW IF EXISTS public.v_guest_refunds;

CREATE VIEW public.v_guest_refunds
WITH (security_invoker = true)
AS
 SELECT r.id AS refund_id,
    r.transaction_date AS refund_date,
    r.gross_amount AS refund_amount,
    r.payee_name AS recipient,
    r.refund_rail,
    r.refund_ref AS payment_reference,
    r.notes,
    r.external_ref AS booking_ref,
    r.logged_by,
    i.gross_amount AS original_payout,
    i.transaction_date AS payout_date,
    i.source AS income_source,
    COALESCE(i.gross_amount, 0::numeric) - r.gross_amount AS net_after_refund,
        CASE
            WHEN r.refund_rail = 'resolution_center'::text THEN true
            ELSE false
        END AS airbnb_netted,
    ar.guest_name
   FROM transactions r
     LEFT JOIN transactions i ON i.external_ref = r.external_ref AND i.txn_type = 'income'::text AND i.source = 'airbnb_payout_email'::text AND i.status = 'confirmed'::text
     LEFT JOIN airbnb_reservations ar ON ar.confirmation_code = r.external_ref
  WHERE r.txn_type = 'expense'::text AND r.source = 'refund'::text AND r.status = 'confirmed'::text;

COMMENT ON VIEW public.v_guest_refunds IS 'Guest refund records joined with original payout and reservation data. Uses SECURITY INVOKER so RLS on base tables is enforced.';
;
