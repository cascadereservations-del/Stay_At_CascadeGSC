-- Compensating rollback for BOTH migrations in release prior_receipt_use_20260920:
--   20260920010000_prior_receipt_use.sql       (cross-booking receipt read + two indexes)
--   20260920020000_finance_week_decisions.sql  (weekly confirm/decline counts per reviewer)
-- Both functions only ever read, so nothing is lost but the reads themselves; the indexes carry no
-- data of their own and payment_evidence_candidates is untouched.
-- Deploy the previous upload-booking-receipt and daily-digest FIRST, or their calls start failing.
-- Both failures are caught and logged, and both messages still go out without their added line, so
-- this order is a tidiness rule rather than a safety one.
begin;

drop function if exists public.finance_decisions_week_v1(uuid, timestamptz);
drop function if exists public.prior_receipt_use_v1(uuid);
drop index if exists public.payment_evidence_property_reference_idx;
drop index if exists public.payment_evidence_property_hash_idx;

commit;
