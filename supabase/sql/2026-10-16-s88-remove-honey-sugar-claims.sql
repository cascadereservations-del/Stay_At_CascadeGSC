-- One-off reviewed SQL (session 88, owner decision Lloyd 2026-10-16): Honey's two PHP 20 sugar claims are removed, not reimbursed.
-- Run with run-sql-on-host.sh from this repo. Keyed on explicit ids; a re-run stops at the guard (nothing changes).
-- Claims: 5c64d9d6 (2026-10-04) and d3bf2dd1 (2026-10-05). Both are pending_review and unpaid (the s87 undo put them back).
-- Change: status 'rejected', reviewed_at now(), review_note set. No row is deleted, and no pay request or ledger row is touched.
-- To undo: set status back to 'pending_review' and clear reviewed_at and review_note on the same two ids.

begin;

set local cascade.audit_reason = 'session 88: owner decision 2026-10-16, Honey sugar claims removed, not reimbursed';

do $$
begin
  if (select count(*) from public.cleaning_expense_claims
       where id in ('5c64d9d6-93c0-47b4-b7c2-abb7b5526930', 'd3bf2dd1-9272-40da-8e37-10d5069369ff')
         and status = 'pending_review' and pay_request_id is null and amount = 20.00 and description = 'sugar') <> 2 then
    raise exception 'the two sugar claims are not both pending_review, unpaid, PHP 20.00 and sugar (already removed?)';
  end if;
end $$;

update public.cleaning_expense_claims
   set status = 'rejected', reviewed_at = now(), review_note = 'Removed by Lloyd 2026-10-16: sugar not reimbursed'
 where id in ('5c64d9d6-93c0-47b4-b7c2-abb7b5526930', 'd3bf2dd1-9272-40da-8e37-10d5069369ff');

do $$
declare v int;
begin
  select count(*) into v from public.cleaning_expense_claims
   where id in ('5c64d9d6-93c0-47b4-b7c2-abb7b5526930', 'd3bf2dd1-9272-40da-8e37-10d5069369ff')
     and status = 'rejected' and pay_request_id is null;
  if v <> 2 then raise exception 'the two claims are not both rejected and unpaid: %', v; end if;
  raise notice 'removed: the two sugar claims are rejected (not reimbursed); no row deleted';
end $$;

commit;
