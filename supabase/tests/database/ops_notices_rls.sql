-- Session 74: release ops_notices_rls_20261007. anon can neither read nor write ops_notices; a signed-in cleaner reads
-- but cannot write; an admin writes only for a property it has access to; a user with no staff profile sees nothing.
-- Runs as the owner; roles are switched with set local role + request.jwt.claims (as staff_home_v1.sql does).
-- Synthetic rows only: uuids e7400000-..., everything rolls back.
begin;
select plan(18);

-- policies and grants ------------------------------------------------------------------------------------------------
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'ops_notices' and 'anon' = any(roles)), 0,
  'no ops_notices policy names anon');
select is((select array_agg(policyname::text order by policyname) from pg_policies where schemaname = 'public' and tablename = 'ops_notices'),
  array['ops_notices_manage', 'ops_notices_staff_read'], 'exactly the two staff policies remain');
select ok(not has_table_privilege('anon', 'public.ops_notices', 'select, insert, update, delete, truncate, references, trigger'),
  'anon holds no privilege on ops_notices');
select ok(has_table_privilege('authenticated', 'public.ops_notices', 'select') and has_table_privilege('authenticated', 'public.ops_notices', 'insert')
      and has_table_privilege('authenticated', 'public.ops_notices', 'update')
      and not has_table_privilege('authenticated', 'public.ops_notices', 'delete, truncate, references, trigger'),
  'authenticated keeps select/insert/update only (RLS decides the rows; deletes go through admin_soft_delete_v1)');
select ok(has_table_privilege('service_role', 'public.ops_notices', 'select') and has_table_privilege('service_role', 'public.ops_notices', 'insert')
      and has_table_privilege('service_role', 'public.ops_notices', 'update') and has_table_privilege('service_role', 'public.ops_notices', 'delete'),
  'service_role (power-watch, telegram-expense, calendar-sync) keeps its access');
select ok((select relrowsecurity from pg_class where oid = 'public.ops_notices'::regclass), 'RLS is still on');

-- fixtures: two properties, an admin with access to A only, a cleaner on A, a user with no staff profile -----------------
insert into public.properties(id, name, is_active) values
  ('e7400000-0000-4000-8000-0000000000a1', 'Synthetic Notices A', true),
  ('e7400000-0000-4000-8000-0000000000b2', 'Synthetic Notices B', true);
insert into auth.users(id) values
  ('e7400000-0000-4000-8000-000000000001'), ('e7400000-0000-4000-8000-000000000002'), ('e7400000-0000-4000-8000-000000000003');
insert into public.staff_access_profiles(user_id, role) values
  ('e7400000-0000-4000-8000-000000000001', 'admin'), ('e7400000-0000-4000-8000-000000000002', 'cleaner');
insert into public.staff_property_access(user_id, property_id) values
  ('e7400000-0000-4000-8000-000000000001', 'e7400000-0000-4000-8000-0000000000a1'),
  ('e7400000-0000-4000-8000-000000000002', 'e7400000-0000-4000-8000-0000000000a1');
insert into public.ops_notices(id, property_id, notice_type, title, effective_date, source) values
  ('e7400000-0000-4000-8000-0000000000f1', 'e7400000-0000-4000-8000-0000000000a1', 'brownout', 'zz fixture brownout', '2026-12-01', 'socoteco');

-- anon (the public key) ------------------------------------------------------------------------------------------------
set local role anon;
select throws_ok($$insert into public.ops_notices(id, property_id, notice_type, title, effective_date, source)
  values ('e7400000-0000-4000-8000-0000000000f2', 'e7400000-0000-4000-8000-0000000000a1', 'brownout', 'zz forged', '2026-12-02', 'socoteco')$$,
  '42501', null, 'anon cannot insert a brownout notice');
select throws_ok($$select count(*) from public.ops_notices$$, '42501', null, 'anon cannot read notices (staff Telegram ids stay private)');
select throws_ok($$update public.ops_notices set is_active = false where id = 'e7400000-0000-4000-8000-0000000000f1'$$, '42501', null,
  'anon cannot update a notice');
reset role;

-- a signed-in cleaner -----------------------------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub','e7400000-0000-4000-8000-000000000002','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select is((select count(*)::int from public.ops_notices where id = 'e7400000-0000-4000-8000-0000000000f1'), 1, 'a cleaner reads the notice board');
select throws_ok($$insert into public.ops_notices(id, property_id, notice_type, title, effective_date, source)
  values ('e7400000-0000-4000-8000-0000000000f3', 'e7400000-0000-4000-8000-0000000000a1', 'brownout', 'zz cleaner forged', '2026-12-03', 'staff')$$,
  '42501', null, 'a cleaner cannot insert a notice directly (Telegram /brownout goes through the service role)');
update public.ops_notices set is_active = false where id = 'e7400000-0000-4000-8000-0000000000f1';
reset role;
select is((select is_active from public.ops_notices where id = 'e7400000-0000-4000-8000-0000000000f1'), true,
  'a cleaner''s update touches no row');

-- a user with no staff profile ----------------------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub','e7400000-0000-4000-8000-000000000003','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select is((select count(*)::int from public.ops_notices), 0, 'a signed-in user with no staff profile sees no notice');
reset role;

-- an admin (the dashboard Notices page) ---------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub','e7400000-0000-4000-8000-000000000001','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select lives_ok($$insert into public.ops_notices(id, property_id, notice_type, title, effective_date, source)
  values ('e7400000-0000-4000-8000-0000000000f4', 'e7400000-0000-4000-8000-0000000000a1', 'reminder', 'zz admin reminder', '2026-12-04', null)$$,
  'an admin creates a notice for its property');
select is((select count(*)::int from public.ops_notices where id = 'e7400000-0000-4000-8000-0000000000f4'), 1, 'and reads it back (the dashboard''s insert ... select)');
select lives_ok($$update public.ops_notices set is_active = false where id = 'e7400000-0000-4000-8000-0000000000f1'$$, 'an admin updates a notice');
select throws_ok($$insert into public.ops_notices(id, property_id, notice_type, title, effective_date, source)
  values ('e7400000-0000-4000-8000-0000000000f5', 'e7400000-0000-4000-8000-0000000000b2', 'reminder', 'zz other property', '2026-12-05', null)$$,
  '42501', null, 'an admin cannot write a notice for a property it has no access to');
reset role;
select is((select is_active from public.ops_notices where id = 'e7400000-0000-4000-8000-0000000000f1'), false, 'the admin update landed');

select * from finish();
rollback;
