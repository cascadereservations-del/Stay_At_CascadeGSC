-- Session 74, lane G3: release money_fixes_20261007 part 2. Staff may only SELECT cleaner_rate_schedule; the one writer is
-- admin_add_pay_rate_v1 (owner/admin, validated, audited). anon holds nothing; a user with no staff profile reads nothing.
-- Synthetic rows only: uuids e7600000-..., everything rolls back. Roles are switched with set local role + request.jwt.claims
-- (the pattern of ops_notices_rls.sql). Fixture rows insert as the owner role (the append-only trigger refuses only update/delete).
begin;
select plan(22);

-- policies and grants ------------------------------------------------------------------------------------------------
select is((select array_agg(policyname::text order by policyname) from pg_policies where schemaname = 'public' and tablename = 'cleaner_rate_schedule'),
  array['cleaner_rate_staff_read'], 'exactly one policy remains: cleaner_rate_staff_read');
select ok((select cmd = 'SELECT' and roles = array['authenticated']::name[] and qual like '%current_staff_authorized%' and qual like '%read_operations%'
             from pg_policies where schemaname = 'public' and tablename = 'cleaner_rate_schedule'),
  'that policy is SELECT for authenticated, gated by read_operations on the row''s property');
select ok(not has_table_privilege('anon', 'public.cleaner_rate_schedule', 'select, insert, update, delete, truncate, references, trigger'),
  'anon holds no privilege on the rate table');
select ok(has_table_privilege('authenticated', 'public.cleaner_rate_schedule', 'select')
      and not has_table_privilege('authenticated', 'public.cleaner_rate_schedule', 'insert, update, delete, truncate, references, trigger'),
  'authenticated holds SELECT only');
select ok(has_table_privilege('service_role', 'public.cleaner_rate_schedule', 'select') and has_table_privilege('service_role', 'public.cleaner_rate_schedule', 'insert'),
  'service_role (telegram-expense, submit-cleaning) keeps its access');
select ok((select relrowsecurity from pg_class where oid = 'public.cleaner_rate_schedule'::regclass), 'RLS is on');

-- fixtures: property A (admin + cleaner), property B (nobody), a user with no staff profile -----------------------------
insert into public.properties(id, name, is_active) values
  ('e7600000-0000-4000-8000-0000000000a1', 'Synthetic Rates A', true),
  ('e7600000-0000-4000-8000-0000000000b2', 'Synthetic Rates B', true);
insert into auth.users(id) values
  ('e7600000-0000-4000-8000-000000000001'), ('e7600000-0000-4000-8000-000000000002'), ('e7600000-0000-4000-8000-000000000003');
insert into public.staff_access_profiles(user_id, role) values
  ('e7600000-0000-4000-8000-000000000001', 'admin'), ('e7600000-0000-4000-8000-000000000002', 'cleaner');
insert into public.staff_property_access(user_id, property_id) values
  ('e7600000-0000-4000-8000-000000000001', 'e7600000-0000-4000-8000-0000000000a1'),
  ('e7600000-0000-4000-8000-000000000002', 'e7600000-0000-4000-8000-0000000000a1');
insert into public.cleaner_rate_schedule(id, property_id, effective_from, regular_rate, general_rate, transport_rate, note) values
  ('e7600000-0000-4000-8000-0000000000f1', 'e7600000-0000-4000-8000-0000000000a1', date '1900-01-01', 500, 1000, 150, 'zz fixture A'),
  ('e7600000-0000-4000-8000-0000000000f2', 'e7600000-0000-4000-8000-0000000000b2', date '1900-01-01', 777, 777, null, 'zz fixture B');

-- anon (the public key) ------------------------------------------------------------------------------------------------
set local role anon;
select throws_ok($$select count(*) from public.cleaner_rate_schedule$$, '42501', null, 'anon cannot read the rates');
select throws_ok($$insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate)
  values ('e7600000-0000-4000-8000-0000000000a1', date '2030-01-01', 1, 1)$$, '42501', null, 'anon cannot insert a rate');
reset role;

-- a signed-in cleaner on property A --------------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub','e7600000-0000-4000-8000-000000000002','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select is((select regular_rate from public.cleaner_rate_schedule where property_id = 'e7600000-0000-4000-8000-0000000000a1'), 500::numeric,
  'a cleaner reads the rate of her property');
select is((select count(*)::int from public.cleaner_rate_schedule where property_id = 'e7600000-0000-4000-8000-0000000000b2'), 0,
  'a cleaner does not read another property''s rate');
select throws_ok($$insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate)
  values ('e7600000-0000-4000-8000-0000000000a1', date '2030-01-01', 9999, 9999)$$, '42501', null, 'a cleaner cannot insert a rate');
select throws_ok($$update public.cleaner_rate_schedule set regular_rate = 1 where id = 'e7600000-0000-4000-8000-0000000000f1'$$, '42501', null,
  'a cleaner cannot update a rate');
select throws_ok($$delete from public.cleaner_rate_schedule where id = 'e7600000-0000-4000-8000-0000000000f1'$$, '42501', null,
  'a cleaner cannot delete a rate');
select throws_ok($$select public.admin_add_pay_rate_v1('e7600000-0000-4000-8000-0000000000a1', date '2030-01-01', 600, 1100, 150, 'cleaner tries')$$, '42501', null,
  'a cleaner cannot add a rate through the RPC either');
reset role;

-- an admin on property A -----------------------------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub','e7600000-0000-4000-8000-000000000001','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select is((select regular_rate from public.cleaner_rate_schedule where property_id = 'e7600000-0000-4000-8000-0000000000a1'), 500::numeric, 'an admin reads the rate');
select throws_ok($$insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate)
  values ('e7600000-0000-4000-8000-0000000000a1', date '2030-01-01', 9999, 9999)$$, '42501', null,
  'an admin cannot insert a rate straight through the API (no validation, no typed reason)');
select throws_ok($$update public.cleaner_rate_schedule set regular_rate = 1 where id = 'e7600000-0000-4000-8000-0000000000f1'$$, '42501', null, 'an admin cannot update a rate');
select ok((select (public.admin_add_pay_rate_v1('e7600000-0000-4000-8000-0000000000a1', public.manila_today() + 1, 600, 1100, 150, 'zz rate for the test')->>'ok')::boolean),
  'an admin adds a rate through admin_add_pay_rate_v1');
select is((select (public.admin_pay_rates_v1('e7600000-0000-4000-8000-0000000000a1')->'next'->>'regular_rate')::numeric), 600::numeric,
  'the dashboard Pay rates read (admin_pay_rates_v1) still answers and shows the new rate as the next one');
select is((select count(*)::int from public.cleaner_rate_schedule where property_id = 'e7600000-0000-4000-8000-0000000000a1'), 2,
  'the admin reads both rows of her property after the RPC wrote one');
reset role;

-- a user with no staff profile ---------------------------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub','e7600000-0000-4000-8000-000000000003','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select is((select count(*)::int from public.cleaner_rate_schedule), 0, 'a signed-in user with no staff profile reads no rate');
reset role;

-- history is still append-only for everyone, and the owner role can still read what the RPC wrote -----------------------------
select throws_ok($$update public.cleaner_rate_schedule set regular_rate = 1 where id = 'e7600000-0000-4000-8000-0000000000f1'$$, '55000', null,
  'the append-only trigger still refuses an update from the table owner');

select * from finish();
rollback;
