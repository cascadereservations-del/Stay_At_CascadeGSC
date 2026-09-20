-- Compensating rollback for 20260920010000_prior_receipt_use.sql.
-- Drops the advisory cross-booking read and its two indexes. No evidence row is touched: the
-- function only ever read them, and the indexes carry no data of their own.
-- Deploy the previous upload-booking-receipt FIRST, or its prior_receipt_use_v1 call starts
-- failing. That failure is caught and logged, and the card is still sent without the duplicate
-- group, so this order is a tidiness rule rather than a safety one.
begin;

drop function if exists public.prior_receipt_use_v1(uuid);
drop index if exists public.payment_evidence_property_reference_idx;
drop index if exists public.payment_evidence_property_hash_idx;

commit;
