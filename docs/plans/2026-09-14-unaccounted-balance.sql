-- One-time balancing row (Lloyd 2026-09-14): "PHP 110,089 is unaccounted expenses ... current balance as
-- of sept 13, 2026 is zero. just create a one time transaction to balance everything - note: unaccounted".
-- The amount is computed here, not typed: income - expenses - drawings on confirmed non-mirror rows dated
-- on or before 2026-09-13. Idempotent on external_ref; audited by the row trigger with the reason below.
-- Run (PowerShell):
--   & "C:\Program Files\Git\bin\bash.exe" -lc 'cd /c/Users/Lloyd/Claude/Projects/Cascade/stay-site && CASCADE_SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe bash scripts/migrations/run-sql-on-host.sh docs/plans/2026-09-14-unaccounted-balance.sql'
begin;

select public.admin_audit_context_v1('unaccounted balancing row as of 2026-09-13 (Lloyd 2026-09-14: balance is zero, book the rest as unaccounted expense)');

with pos as (
  select
    (select coalesce(sum(gross_amount),0) from public.transactions where txn_type = 'income' and status = 'confirmed' and source not in ('airbnb','airbnb_email') and transaction_date <= '2026-09-13')
  - (select coalesce(sum(gross_amount),0) from public.transactions where txn_type = 'expense' and status = 'confirmed' and source not in ('airbnb','airbnb_email') and transaction_date <= '2026-09-13')
  - (select coalesce(sum(gross_amount),0) from public.transactions where txn_type = 'drawing' and status = 'confirmed' and transaction_date <= '2026-09-13') as amt
)
insert into public.transactions (property_id, txn_type, category, status, source, transaction_date, gross_amount, currency, payee_name, notes, external_ref, logged_by)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid, 'expense', 'unaccounted', 'confirmed', 'manual', '2026-09-13'::date, round(pos.amt, 2), 'PHP', 'Unaccounted',
       'Unaccounted. One-time balancing entry: expenses paid before 2026-09-13 with no receipt or record (includes Jan-May 2026 cleaning by Jary/Hazel Ann and any other untracked spend). Lloyd 2026-09-14: cash balance was zero on 2026-09-13.',
       'unaccounted:2026-09-13', 'ledger-truth-2026-09-14'
from pos
where pos.amt > 0
  and not exists (select 1 from public.transactions t where t.external_ref = 'unaccounted:2026-09-13');

do $$
declare v numeric;
begin
  select
    (select coalesce(sum(gross_amount),0) from public.transactions where txn_type = 'income' and status = 'confirmed' and source not in ('airbnb','airbnb_email') and transaction_date <= '2026-09-13')
  - (select coalesce(sum(gross_amount),0) from public.transactions where txn_type = 'expense' and status = 'confirmed' and source not in ('airbnb','airbnb_email') and transaction_date <= '2026-09-13')
  - (select coalesce(sum(gross_amount),0) from public.transactions where txn_type = 'drawing' and status = 'confirmed' and transaction_date <= '2026-09-13')
  into v;
  if v <> 0 then raise exception 'position on 2026-09-13 is %, not 0.00', v; end if;
end $$;

select 'unaccounted_row' k, transaction_date::text || ' PHP ' || gross_amount || ' ' || left(id::text, 8) v from public.transactions where external_ref = 'unaccounted:2026-09-13'
union all select 'position_2026_09_13', '0.00'
union all select 'position_2026_09_14', (
  (select coalesce(sum(gross_amount),0) from public.transactions where txn_type = 'income' and status = 'confirmed' and source not in ('airbnb','airbnb_email') and transaction_date <= '2026-09-14')
  - (select coalesce(sum(gross_amount),0) from public.transactions where txn_type = 'expense' and status = 'confirmed' and source not in ('airbnb','airbnb_email') and transaction_date <= '2026-09-14')
  - (select coalesce(sum(gross_amount),0) from public.transactions where txn_type = 'drawing' and status = 'confirmed' and transaction_date <= '2026-09-14'))::text;

commit;
