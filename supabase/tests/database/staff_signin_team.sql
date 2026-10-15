-- Session 88: staff_signin_list_v2, the sign-in name list with a team column (staff | admin).
-- Synthetic accounts only (e-mails zz.st.*); every row assertion filters on that prefix. Inside begin/rollback.
begin;
select plan(13);

select ok((select p.prosecdef and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = 'public.staff_signin_list_v2()'::regprocedure),
  'v2 is security definer with an empty search_path');
select ok(has_function_privilege('anon', 'public.staff_signin_list_v2()', 'execute'), 'anon can call v2');
select ok(has_function_privilege('authenticated', 'public.staff_signin_list_v2()', 'execute'), 'authenticated can call v2');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'public.staff_signin_list_v2()'::regprocedure and a.grantee = 0),
  'PUBLIC has no execute grant');
select is(pg_get_function_result('public.staff_signin_list_v2()'::regprocedure), 'TABLE(label text, handle text, kind text, team text)',
  'the shape is label, handle, kind, team and nothing else');
select ok(has_function_privilege('anon', 'public.staff_signin_list_v1()', 'execute'), 'v1 is still there and callable');

insert into auth.users(id, email, raw_app_meta_data, raw_user_meta_data, banned_until) values
  ('e8800000-0000-4000-8000-0000000000a1', 'zz.st.cleaner@staff.cascade.invalid', '{"display_name":"Zz Cleaner"}', '{}', null),
  ('e8800000-0000-4000-8000-0000000000a2', 'zz.st.inspector@staff.cascade.invalid', '{"display_name":"Zz Inspector"}', '{}', null),
  ('e8800000-0000-4000-8000-0000000000a3', 'zz.st.maint@staff.cascade.invalid', '{"display_name":"Zz Maint"}', '{}', null),
  ('e8800000-0000-4000-8000-0000000000a4', 'zz.st.owner@example.test', '{"display_name":"Zz Owner"}', '{}', null),
  ('e8800000-0000-4000-8000-0000000000a5', 'zz.st.admin@example.test', '{"display_name":"Zz Admin"}', '{}', null),
  ('e8800000-0000-4000-8000-0000000000a6', 'zz.st.finance@example.test', '{"display_name":"Zz Finance"}', '{}', null),
  ('e8800000-0000-4000-8000-0000000000a7', 'zz.st.off@staff.cascade.invalid', '{"display_name":"Zz Off"}', '{}', null),
  ('e8800000-0000-4000-8000-0000000000a8', 'zz.st.banned@example.test', '{"display_name":"Zz Banned"}', '{}', now() + interval '1 day');
insert into public.staff_access_profiles(user_id, role, disabled_at) values
  ('e8800000-0000-4000-8000-0000000000a1', 'cleaner', null),
  ('e8800000-0000-4000-8000-0000000000a2', 'inspector', null),
  ('e8800000-0000-4000-8000-0000000000a3', 'maintenance', null),
  ('e8800000-0000-4000-8000-0000000000a4', 'owner', null),
  ('e8800000-0000-4000-8000-0000000000a5', 'admin', null),
  ('e8800000-0000-4000-8000-0000000000a6', 'finance', null),
  ('e8800000-0000-4000-8000-0000000000a7', 'cleaner', now()),
  ('e8800000-0000-4000-8000-0000000000a8', 'admin', null);

select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
select set_config('role', 'anon', true);

select is((select count(*)::int from public.staff_signin_list_v2() where handle like 'zz.st.%'), 6,
  'one row per active synthetic profile; disabled and banned are not listed');
select ok((select bool_and(team in ('staff', 'admin')) from public.staff_signin_list_v2()), 'team is only staff or admin');
select ok((select bool_and(team = 'staff') from public.staff_signin_list_v2() where handle in
  ('zz.st.cleaner@staff.cascade.invalid', 'zz.st.inspector@staff.cascade.invalid', 'zz.st.maint@staff.cascade.invalid')),
  'cleaner, inspector and maintenance are staff');
select ok((select bool_and(team = 'admin') from public.staff_signin_list_v2() where handle in
  ('zz.st.owner@example.test', 'zz.st.admin@example.test', 'zz.st.finance@example.test')),
  'owner, admin and finance are admin');
-- the two join checks read auth.users and staff_access_profiles, which anon cannot read: run them as the owner.
reset role;
select is((select count(*)::int from public.staff_signin_list_v2() v join auth.users u on lower(u.email) = v.handle
   join public.staff_access_profiles p on p.user_id = u.id where v.team = 'staff' and p.role in ('owner', 'admin', 'finance')), 0,
  'no owner, admin or finance row is staff');
select is((select count(*)::int from public.staff_signin_list_v2() v join auth.users u on lower(u.email) = v.handle
   join public.staff_access_profiles p on p.user_id = u.id where v.team = 'admin' and p.role not in ('owner', 'admin', 'finance')), 0,
  'no other role is admin');

select set_config('role', 'authenticated', true);
select is((select count(*)::int from public.staff_signin_list_v2() where handle like 'zz.st.%'), 6, 'a signed-in session reads the same list');

reset role;
select * from finish();
rollback;
