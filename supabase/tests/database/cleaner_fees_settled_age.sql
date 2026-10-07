-- Session 76: release cleaner_fees_settled_age_20261007. System health "cleaner_fees_settled" under SPEC-37:
-- an unpaid clean (fee NULL or > 0) is normal until 14 days after the clean, then warn; a fee marked paid with no
-- live transaction is fail; an explicit 0 is no fee; other properties never leak in. Grants and definer unchanged.
-- Synthetic rows only: uuids e7610000-..., everything rolls back.
begin;
select plan(11);

select ok((select prosecdef and proconfig = array['search_path=""'] from pg_proc where oid = 'public.health_checks_core_v1(uuid,boolean)'::regprocedure),
  'the core stays security definer with an empty search_path');
select ok(has_function_privilege('service_role', 'public.health_checks_core_v1(uuid,boolean)', 'execute')
      and not has_function_privilege('authenticated', 'public.health_checks_core_v1(uuid,boolean)', 'execute')
      and not has_function_privilege('anon', 'public.health_checks_core_v1(uuid,boolean)', 'execute'),
  'the core is still service_role only');

insert into public.properties(id, name, is_active) values
  ('e7610000-0000-4000-8000-0000000000a1', 'Synthetic Fee Check A', true),
  ('e7610000-0000-4000-8000-0000000000b2', 'Synthetic Fee Check B', true);

create function pg_temp.chk(p uuid) returns jsonb language sql as $$
  select e from jsonb_array_elements(public.health_checks_core_v1(p, true)->'checks') e where e->>'check_key' = 'cleaner_fees_settled'
$$;

insert into public.transactions(id, property_id, txn_type, category, gross_amount, source, status, transaction_date) values
  ('e7610000-0000-4000-8000-0000000000f1', 'e7610000-0000-4000-8000-0000000000a1', 'expense', 'supplies', 650, 'manual', 'confirmed', current_date),
  ('e7610000-0000-4000-8000-0000000000f2', 'e7610000-0000-4000-8000-0000000000a1', 'expense', 'supplies', 650, 'manual', 'void', current_date);

-- Normal state: unpriced and unpaid 3 days, explicit 0 unpaid 30 days, paid 650 with a live transaction.
insert into public.cleaning_sessions(id, property_id, submission_id, cleaner_name, cleaned_at, cleaning_type, fee_amount, fee_paid_at, fee_txn_id) values
  ('e7610000-0000-4000-8000-0000000000c1', 'e7610000-0000-4000-8000-0000000000a1', 'zz-fck-1', 'Fixture', now() - interval '3 days',  'turnover', null, null, null),
  ('e7610000-0000-4000-8000-0000000000c2', 'e7610000-0000-4000-8000-0000000000a1', 'zz-fck-2', 'Fixture', now() - interval '30 days', 'turnover', 0,    null, null),
  ('e7610000-0000-4000-8000-0000000000c3', 'e7610000-0000-4000-8000-0000000000a1', 'zz-fck-3', 'Fixture', now() - interval '25 days', 'turnover', 650,  now() - interval '5 days', 'e7610000-0000-4000-8000-0000000000f1'),
  ('e7610000-0000-4000-8000-0000000000c9', 'e7610000-0000-4000-8000-0000000000b2', 'zz-fck-9', 'Fixture', now() - interval '20 days', 'turnover', null, null, null);
select is(pg_temp.chk('e7610000-0000-4000-8000-0000000000a1')->>'status', 'pass',
  'a 3-day-old unpaid clean, an explicit 0 and a paid fee with a live transaction are all settled-or-normal');
select is(pg_temp.chk('e7610000-0000-4000-8000-0000000000b2')->>'status', 'warn',
  'property B: its own unpriced clean unpaid 20 days is a reminder');

-- Age threshold: unpaid 15 days (priced) and 20 days (unpriced) warn; 13 days does not.
insert into public.cleaning_sessions(id, property_id, submission_id, cleaner_name, cleaned_at, cleaning_type, fee_amount, fee_paid_at, fee_txn_id) values
  ('e7610000-0000-4000-8000-0000000000c4', 'e7610000-0000-4000-8000-0000000000a1', 'zz-fck-4', 'Fixture', now() - interval '20 days', 'deep_clean', null, null, null),
  ('e7610000-0000-4000-8000-0000000000c5', 'e7610000-0000-4000-8000-0000000000a1', 'zz-fck-5', 'Fixture', now() - interval '15 days', 'mid_stay',   500,  null, null),
  ('e7610000-0000-4000-8000-0000000000c6', 'e7610000-0000-4000-8000-0000000000a1', 'zz-fck-6', 'Fixture', now() - interval '13 days', 'turnover',   null, null, null);
select is(pg_temp.chk('e7610000-0000-4000-8000-0000000000a1')->>'status', 'warn',
  'a clean unpaid more than 14 days is a warn, not a fail');
select is((pg_temp.chk('e7610000-0000-4000-8000-0000000000a1')->>'count')::int, 2,
  'exactly the 20-day unpriced and the 15-day priced cleans; 13 days, explicit 0 and other properties excluded');

-- Ledger defects: paid against a void transaction, paid with no transaction at all.
insert into public.cleaning_sessions(id, property_id, submission_id, cleaner_name, cleaned_at, cleaning_type, fee_amount, fee_paid_at, fee_txn_id) values
  ('e7610000-0000-4000-8000-0000000000c7', 'e7610000-0000-4000-8000-0000000000a1', 'zz-fck-7', 'Fixture', now() - interval '2 days', 'turnover', 500, now() - interval '1 day', 'e7610000-0000-4000-8000-0000000000f2');
select is(pg_temp.chk('e7610000-0000-4000-8000-0000000000a1')->>'status', 'fail',
  'a fee marked paid against a void transaction is a fail, whatever its age');
select is(pg_temp.chk('e7610000-0000-4000-8000-0000000000a1')->'detail'->0->>'session', 'e7610000-0000-4000-8000-0000000000c7',
  'the ledger defect is listed first');
insert into public.cleaning_sessions(id, property_id, submission_id, cleaner_name, cleaned_at, cleaning_type, fee_amount, fee_paid_at, fee_txn_id) values
  ('e7610000-0000-4000-8000-0000000000c8', 'e7610000-0000-4000-8000-0000000000a1', 'zz-fck-8', 'Fixture', now() - interval '1 day', 'turnover', null, now(), null);
select is((pg_temp.chk('e7610000-0000-4000-8000-0000000000a1')->>'count')::int, 4,
  'a fee marked paid with no transaction id is counted too (2 overdue + 2 defects)');

-- Settling clears it: link the live transaction to both defects and pay the overdue ones.
update public.cleaning_sessions set fee_txn_id = 'e7610000-0000-4000-8000-0000000000f1'
 where id in ('e7610000-0000-4000-8000-0000000000c7', 'e7610000-0000-4000-8000-0000000000c8');
select is(pg_temp.chk('e7610000-0000-4000-8000-0000000000a1')->>'status', 'warn',
  'with the defects linked to a live transaction only the overdue reminder remains');
update public.cleaning_sessions set fee_amount = coalesce(fee_amount, 500), fee_paid_at = now(), fee_txn_id = 'e7610000-0000-4000-8000-0000000000f1'
 where id in ('e7610000-0000-4000-8000-0000000000c4', 'e7610000-0000-4000-8000-0000000000c5');
select is(pg_temp.chk('e7610000-0000-4000-8000-0000000000a1')->>'status', 'pass',
  'paying the overdue cleans returns the check to pass');

select * from finish();
rollback;
