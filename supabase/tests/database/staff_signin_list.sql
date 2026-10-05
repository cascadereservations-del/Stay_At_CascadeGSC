-- Session 71, D-303.2: staff_signin_list_v1, the anon-callable name list for the Cascade Staff sign-in dropdown.
-- Synthetic accounts only (e-mails zz.sl.*), so restored production staff never interfere: every assertion about rows filters on
-- that prefix. Inside begin/rollback. Fixtures insert as the owner; anon and authenticated are impersonated with set_config('role').
begin;
select plan(16);

select ok((select p.prosecdef and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = 'public.staff_signin_list_v1()'::regprocedure),
  'the RPC is security definer with an empty search_path');
select ok(has_function_privilege('anon', 'public.staff_signin_list_v1()', 'execute'), 'anon can call staff_signin_list_v1');
select ok(has_function_privilege('authenticated', 'public.staff_signin_list_v1()', 'execute'), 'authenticated can call staff_signin_list_v1');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'public.staff_signin_list_v1()'::regprocedure and a.grantee = 0),
  'PUBLIC has no execute grant (only the two API roles do)');
select is(pg_get_function_result('public.staff_signin_list_v1()'::regprocedure), 'TABLE(label text, handle text, kind text)',
  'the shape is label, handle, kind and nothing else: no role, no user id');

-- Fixtures. A, B, C, D, H can sign in; E is disabled, F is banned, G has no staff profile.
insert into auth.users(id, email, raw_app_meta_data, raw_user_meta_data, banned_until) values
  ('e3710000-0000-4000-8000-0000000000a1', 'zz.sl.alma@staff.cascade.invalid', '{"display_name":"Zz Alma"}', '{"display_name":"stale name"}', null),
  ('e3710000-0000-4000-8000-0000000000a2', 'zz.sl.bea@staff.cascade.invalid', '{}', '{"display_name":"Zz Bea"}', null),
  ('e3710000-0000-4000-8000-0000000000a3', 'zz.sl.cy@staff.cascade.invalid', '{}', '{}', null),
  ('e3710000-0000-4000-8000-0000000000a4', 'zz.sl.dora@example.test', '{"display_name":"Zz Dora"}', '{}', null),
  ('e3710000-0000-4000-8000-0000000000a5', 'zz.sl.eve@staff.cascade.invalid', '{"display_name":"Zz Eve"}', '{}', null),
  ('e3710000-0000-4000-8000-0000000000a6', 'zz.sl.fay@staff.cascade.invalid', '{"display_name":"Zz Fay"}', '{}', now() + interval '1 day'),
  ('e3710000-0000-4000-8000-0000000000a7', 'zz.sl.gus@staff.cascade.invalid', '{"display_name":"Zz Gus"}', '{}', null),
  ('e3710000-0000-4000-8000-0000000000a8', 'zz.sl.hal@staff.cascade.invalid', '{"display_name":"Zz Hal"}', '{}', now() - interval '1 day');
insert into public.staff_access_profiles(user_id, role, disabled_at) values
  ('e3710000-0000-4000-8000-0000000000a1', 'cleaner', null),
  ('e3710000-0000-4000-8000-0000000000a2', 'inspector', null),
  ('e3710000-0000-4000-8000-0000000000a3', 'maintenance', null),
  ('e3710000-0000-4000-8000-0000000000a4', 'admin', null),
  ('e3710000-0000-4000-8000-0000000000a5', 'cleaner', now()),
  ('e3710000-0000-4000-8000-0000000000a6', 'cleaner', null),
  ('e3710000-0000-4000-8000-0000000000a8', 'cleaner', null);

select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
select set_config('role', 'anon', true);

select is((select count(*)::int from public.staff_signin_list_v1() where handle like 'zz.sl.%'), 5,
  'anon sees the five active synthetic accounts and not the disabled, banned or profile-less ones');
select is((select array_agg(t.label order by t.n) from public.staff_signin_list_v1() with ordinality as t(label, handle, kind, n) where t.handle like 'zz.sl.%'),
  array['Zz Alma', 'Zz Bea', 'Zz Dora', 'Zz Hal', 'Zz Sl Cy'], 'ordered by label');
select is((select label from public.staff_signin_list_v1() where handle = 'zz.sl.alma@staff.cascade.invalid'), 'Zz Alma',
  'the label is app_metadata.display_name (what the dashboard shows) before user_metadata');
select is((select label from public.staff_signin_list_v1() where handle = 'zz.sl.bea@staff.cascade.invalid'), 'Zz Bea',
  'the label falls back to user_metadata.display_name');
select is((select label from public.staff_signin_list_v1() where handle = 'zz.sl.cy@staff.cascade.invalid'), 'Zz Sl Cy',
  'the label falls back to the e-mail local part, dots as spaces, capitalised');
select is((select kind from public.staff_signin_list_v1() where handle = 'zz.sl.alma@staff.cascade.invalid'), 'pin',
  'a staff.cascade.invalid account is a PIN account');
select ok((select kind = 'password' and handle = 'zz.sl.dora@example.test' from public.staff_signin_list_v1() where label = 'Zz Dora'),
  'a mailbox account is a password account and carries its e-mail as the handle');
select is((select count(*)::int from public.staff_signin_list_v1() where handle in ('zz.sl.eve@staff.cascade.invalid', 'zz.sl.fay@staff.cascade.invalid')), 0,
  'a disabled account and a banned account are not listed');
select is((select count(*)::int from public.staff_signin_list_v1() where handle = 'zz.sl.gus@staff.cascade.invalid'), 0,
  'an Auth user with no staff profile is not listed');
select is((select count(*)::int from public.staff_signin_list_v1() where handle = 'zz.sl.hal@staff.cascade.invalid'), 1,
  'an expired ban does not hide the account');

select set_config('role', 'authenticated', true);
select is((select count(*)::int from public.staff_signin_list_v1() where handle like 'zz.sl.%'), 5, 'a signed-in staff session reads the same list');

reset role;
select * from finish();
rollback;
