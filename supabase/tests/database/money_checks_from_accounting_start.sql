-- Session 45: release money_checks_from_accounting_start_20260923 (D-219.1).
-- One pair per re-scoped check: before the accounting start stays silent, on or after it fires.
-- Every fixture lives inside this transaction and goes with the closing rollback.

begin;
select plan(7);

insert into public.properties(id, name, is_active) values ('e1000000-0000-4000-8000-000000000045', 'Synthetic Money 45', true);
insert into public.acct_settings(property_id, accounting_start) values ('e1000000-0000-4000-8000-000000000045', '2026-09-01');

create function pg_temp.chk(k text) returns jsonb language sql as $$
  select e from jsonb_array_elements(public.health_checks_core_v1('e1000000-0000-4000-8000-000000000045', true)->'checks') e
   where e->>'check_key' = k
$$;

-- host_payout stays null on purpose: trg_reservation_reconcile creates a payout income row for any completed
-- stay with a host_payout, which would hide exactly the missing payout these checks look for.

-- completed_stays_paid -------------------------------------------------------------
insert into public.airbnb_reservations(property_id, confirmation_code, guest_name, checkin_date, checkout_date, status, payout_amount)
values ('e1000000-0000-4000-8000-000000000045', 'HMSYNTH45OLD', 'Historical Guest', '2026-01-05', '2026-01-06', 'completed', 1309.02);
select is(pg_temp.chk('completed_stays_paid')->>'status', 'pass',
  'a stay before the accounting start with no payout e-mail is historical and stays silent');

insert into public.airbnb_reservations(property_id, confirmation_code, guest_name, checkin_date, checkout_date, status, payout_amount)
values ('e1000000-0000-4000-8000-000000000045', 'HMSYNTH45NEW', 'Current Guest', '2026-09-05', '2026-09-06', 'completed', 1500.00);
select is(pg_temp.chk('completed_stays_paid')->>'status', 'warn',
  'a stay after the accounting start with no payout e-mail is found');
select is((pg_temp.chk('completed_stays_paid')->>'count')::int, 1,
  'and only that one - the historical stay is not counted');

-- payout_totals_agree -----------------------------------------------------------------
-- The historical stay's 1,309.02 is never matched; only the current stay's 1,500 is judged.
insert into public.transactions(property_id, txn_type, category, gross_amount, source, status, transaction_date, reservation_id)
select 'e1000000-0000-4000-8000-000000000045', 'income', 'accommodation', 1500.00, 'airbnb_payout_email', 'confirmed', '2026-09-07', id
  from public.airbnb_reservations where confirmation_code = 'HMSYNTH45NEW';
select is(pg_temp.chk('payout_totals_agree')->>'status', 'pass',
  'from the start, promised equals received, and the historical gap is not counted');
update public.airbnb_reservations set payout_amount = 1600.00 where confirmation_code = 'HMSYNTH45NEW';
select is(pg_temp.chk('payout_totals_agree')->>'status', 'warn',
  'a payout that disagrees after the start is found');

-- ledger_position -----------------------------------------------------------------
-- The 1,500 payout above is income since the start; an expense larger than it takes the position below zero.
select is(pg_temp.chk('ledger_position')->>'status', 'pass',
  'money left over is not a problem');
insert into public.transactions(property_id, txn_type, category, gross_amount, source, status, transaction_date)
values ('e1000000-0000-4000-8000-000000000045', 'expense', 'supplies', 2000.00, 'manual', 'confirmed', '2026-09-08');
select is(pg_temp.chk('ledger_position')->>'status', 'warn',
  'a cash position below zero is found');

select * from finish();
rollback;
