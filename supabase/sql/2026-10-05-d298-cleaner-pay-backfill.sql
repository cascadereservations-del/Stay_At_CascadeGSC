-- Session 70 (D-298.1, D-300 defaults): one-off ledger backfill of the cleans Honey was already paid for at PHP 650. The ledger stops at
-- the 13 Sep payout (the 2026-09-14 backfill), so these cleans show as unpaid and the new Payment Request page would offer them again.
-- Run AFTER release staff_pay_requests_20261005 and BEFORE the staff page goes live:
--   Git Bash, CASCADE_SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe, stay-site/scripts/migrations/run-sql-on-host.sh <this file>
-- It is not a migration (no ledger row). run-sql-on-host.sh runs under ON_ERROR_STOP, so a failed assertion rolls its block back and
-- stops the file before the next block.
--
-- Two transactions, so Lloyd can drop Block B:
--   Block A  CONFIRMED (D-298.1): sessions 63c2ef1a (Sep 27 check-out) + bfa29bb6 (Sep 28 check-out) at 650 each, plus the PHP 40
--            KitKat claim 6a13890a on bfa29bb6 = PHP 1,340, PAID.
--   Block B  PRESUMED paid at 650 in earlier payouts, approved in D-300 defaults: seven cleans, Sep 14 to Sep 25 check-outs
--            = PHP 4,550. Drop this block and Honey sees those seven in the app at 650 (no transport toggle).
-- Ledger rows have the shape bookCleaningFee writes (txn_type expense / category cleaning / source cleaner_fee / external_ref
-- cleanfee:<session>) and, for the claim, category supplies / external_ref claim:<id>; logged_by = 'backfill D-298'.
-- transaction_date = the session date (the pay dates are not recorded); fee_paid_at = now(), as the 2026-09-14 backfill did.
-- Re-running changes nothing: a session that is already paid, or already has a non-void cleanfee: row, is skipped, and each
-- block's assertion checks the END state (the counts, the sum and the paid markers), so it also holds on a second run and raises,
-- rolling its block back, if a session or the claim was missing, was paid another way, or the amounts differ.
--
-- Rollback: void the logged_by = 'backfill D-298' rows; set fee_amount, fee_paid_at, fee_txn_id to null on those sessions;
-- set the claim back to pending_review (reviewed_at and review_note null).
-- Read-only check afterwards: no Honey session before 2026-09-30 is unpaid, and run_health_checks cleaner_fees_settled = pass.

-- ===== Block A: confirmed, PHP 1,340 =====
begin;

with s as (
  select id, coalesce(checkout_date, checkin_date, cleaned_at::date) as d, cleaner_name
    from public.cleaning_sessions
   where id = any(array['63c2ef1a-442d-442c-bef4-8acbad5336bd', 'bfa29bb6-f8be-4b4a-b22c-e32689177702']::uuid[])
     and fee_paid_at is null
     and not exists (select 1 from public.transactions t where t.external_ref = 'cleanfee:' || id and t.status <> 'void')
   for update),
t as (
  insert into public.transactions(property_id, txn_type, category, status, source, gross_amount, payee_name,
                                  transaction_date, external_ref, notes, logged_by)
  select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'expense', 'cleaning', 'confirmed', 'cleaner_fee', 650, s.cleaner_name,
         s.d, 'cleanfee:' || s.id, 'Cleaning fee - ' || s.cleaner_name || ', ' || s.d || ', Turnover. backfill D-298.', 'backfill D-298'
    from s returning id, external_ref)
update public.cleaning_sessions c set fee_amount = 650, fee_paid_at = now(), fee_txn_id = t.id
  from t where t.external_ref = 'cleanfee:' || c.id;

with k as (
  select id, expense_date, description
    from public.cleaning_expense_claims
   where id = '6a13890a-248d-421e-8236-ab9958e7d33a' and status in ('pending_review', 'approved') and pay_request_id is null
     and not exists (select 1 from public.transactions t where t.external_ref = 'claim:' || id and t.status <> 'void')
   for update),
t as (
  insert into public.transactions(property_id, txn_type, category, status, source, gross_amount, payee_name,
                                  transaction_date, external_ref, notes, logged_by)
  select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'expense', 'supplies', 'confirmed', 'cleaner_fee', 40, 'Honey',
         k.expense_date, 'claim:' || k.id, 'Staff expense - ' || k.description || '. backfill D-298.', 'backfill D-298'
    from k returning id, external_ref)
update public.cleaning_expense_claims c
   set status = 'paid', reviewed_at = now(), review_note = 'backfill D-298 (paid with the PHP 1,340 payout)'
  from t where t.external_ref = 'claim:' || c.id;

do $$
declare n_sessions int; n_claims int; v_sum numeric; n_paid int; n_claim_paid int;
begin
  select count(*), coalesce(sum(gross_amount), 0) into n_sessions, v_sum from public.transactions
   where logged_by = 'backfill D-298' and status <> 'void' and category = 'cleaning'
     and external_ref in ('cleanfee:63c2ef1a-442d-442c-bef4-8acbad5336bd', 'cleanfee:bfa29bb6-f8be-4b4a-b22c-e32689177702');
  select count(*), v_sum + coalesce(sum(gross_amount), 0) into n_claims, v_sum from public.transactions
   where logged_by = 'backfill D-298' and status <> 'void' and category = 'supplies' and external_ref = 'claim:6a13890a-248d-421e-8236-ab9958e7d33a';
  select count(*) into n_paid from public.cleaning_sessions
   where id in ('63c2ef1a-442d-442c-bef4-8acbad5336bd', 'bfa29bb6-f8be-4b4a-b22c-e32689177702') and fee_amount = 650 and fee_paid_at is not null and fee_txn_id is not null;
  select count(*) into n_claim_paid from public.cleaning_expense_claims where id = '6a13890a-248d-421e-8236-ab9958e7d33a' and status = 'paid';
  if n_sessions <> 2 or n_claims <> 1 or v_sum <> 1340 or n_paid <> 2 or n_claim_paid <> 1 then
    raise exception 'Block A expected 2 sessions + 1 claim, ledger sum 1340; got % sessions, % claims, sum %, % paid sessions, % paid claims',
      n_sessions, n_claims, v_sum, n_paid, n_claim_paid;
  end if;
end $$;

commit;

-- ===== Block B: presumed, PHP 4,550 (drop this block to keep those seven cleans unpaid) =====
begin;

with s as (
  select id, coalesce(checkout_date, checkin_date, cleaned_at::date) as d, cleaner_name
    from public.cleaning_sessions
   where id = any(array[
           '68363825-e74d-49c6-8e0a-f1edb94261af', 'fe81722c-2004-4f1c-ba38-182ca190cd5a', 'b0561420-8d44-4048-8ede-426a76a53e7c',
           '1c332d83-165c-41c7-becb-8718e646bda0', '74b717e1-4909-43c6-a5c4-6466e1484b11', 'dfe00df2-bd18-448c-87a4-d0b560a59f6a',
           '1dfc07ea-866e-4d6f-b07e-020f5d060fbd']::uuid[])
     and fee_paid_at is null
     and not exists (select 1 from public.transactions t where t.external_ref = 'cleanfee:' || id and t.status <> 'void')
   for update),
t as (
  insert into public.transactions(property_id, txn_type, category, status, source, gross_amount, payee_name,
                                  transaction_date, external_ref, notes, logged_by)
  select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'expense', 'cleaning', 'confirmed', 'cleaner_fee', 650, s.cleaner_name,
         s.d, 'cleanfee:' || s.id, 'Cleaning fee - ' || s.cleaner_name || ', ' || s.d || ', Turnover. backfill D-298.', 'backfill D-298'
    from s returning id, external_ref)
update public.cleaning_sessions c set fee_amount = 650, fee_paid_at = now(), fee_txn_id = t.id
  from t where t.external_ref = 'cleanfee:' || c.id;

do $$
declare n_sessions int; v_sum numeric; n_paid int;
begin
  select count(*), coalesce(sum(gross_amount), 0) into n_sessions, v_sum from public.transactions
   where logged_by = 'backfill D-298' and status <> 'void' and category = 'cleaning'
     and external_ref in ('cleanfee:68363825-e74d-49c6-8e0a-f1edb94261af', 'cleanfee:fe81722c-2004-4f1c-ba38-182ca190cd5a',
                          'cleanfee:b0561420-8d44-4048-8ede-426a76a53e7c', 'cleanfee:1c332d83-165c-41c7-becb-8718e646bda0',
                          'cleanfee:74b717e1-4909-43c6-a5c4-6466e1484b11', 'cleanfee:dfe00df2-bd18-448c-87a4-d0b560a59f6a',
                          'cleanfee:1dfc07ea-866e-4d6f-b07e-020f5d060fbd');
  select count(*) into n_paid from public.cleaning_sessions
   where id in ('68363825-e74d-49c6-8e0a-f1edb94261af', 'fe81722c-2004-4f1c-ba38-182ca190cd5a', 'b0561420-8d44-4048-8ede-426a76a53e7c',
                '1c332d83-165c-41c7-becb-8718e646bda0', '74b717e1-4909-43c6-a5c4-6466e1484b11', 'dfe00df2-bd18-448c-87a4-d0b560a59f6a',
                '1dfc07ea-866e-4d6f-b07e-020f5d060fbd')
     and fee_amount = 650 and fee_paid_at is not null and fee_txn_id is not null;
  if n_sessions <> 7 or v_sum <> 4550 or n_paid <> 7 then
    raise exception 'Block B expected 7 sessions, ledger sum 4550; got % sessions, sum %, % paid sessions', n_sessions, v_sum, n_paid;
  end if;
end $$;

commit;
