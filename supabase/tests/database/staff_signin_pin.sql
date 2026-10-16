-- Session 89: staff_signin_list_v2 kind = pin when app_metadata.signin_kind = 'pin' or the e-mail is a staff-domain login.
-- Synthetic accounts only (e-mails zz.pn.*); every row assertion filters on that handle. Inside begin/rollback.
begin;
select plan(10);

select ok(has_function_privilege('anon', 'public.staff_signin_list_v2()', 'execute'), 'anon can call v2');
select ok(has_function_privilege('authenticated', 'public.staff_signin_list_v2()', 'execute'), 'authenticated can call v2');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'public.staff_signin_list_v2()'::regprocedure and a.grantee = 0),
  'PUBLIC has no execute grant');
select is(pg_get_function_result('public.staff_signin_list_v2()'::regprocedure), 'TABLE(label text, handle text, kind text, team text)',
  'the shape is unchanged: no new column, no leak');

insert into auth.users(id, email, raw_app_meta_data, raw_user_meta_data) values
  ('e8900000-0000-4000-8000-0000000000b1', 'zz.pn.meta@example.test', '{"display_name":"Zz Meta","signin_kind":"pin"}', '{}'),
  ('e8900000-0000-4000-8000-0000000000b2', 'zz.pn.domain@staff.cascade.invalid', '{"display_name":"Zz Domain"}', '{}'),
  ('e8900000-0000-4000-8000-0000000000b3', 'zz.pn.plain@example.test', '{"display_name":"Zz Plain"}', '{}'),
  ('e8900000-0000-4000-8000-0000000000b4', 'zz.pn.pwkind@example.test', '{"display_name":"Zz Pw","signin_kind":"password"}', '{}'),
  ('e8900000-0000-4000-8000-0000000000b5', 'zz.pn.pwdomain@staff.cascade.invalid', '{"display_name":"Zz PwDomain","signin_kind":"password"}', '{}');
insert into public.staff_access_profiles(user_id, role, disabled_at) values
  ('e8900000-0000-4000-8000-0000000000b1', 'admin', null),
  ('e8900000-0000-4000-8000-0000000000b2', 'cleaner', null),
  ('e8900000-0000-4000-8000-0000000000b3', 'admin', null),
  ('e8900000-0000-4000-8000-0000000000b4', 'admin', null),
  ('e8900000-0000-4000-8000-0000000000b5', 'cleaner', null);

select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
select set_config('role', 'anon', true);

select is((select kind from public.staff_signin_list_v2() where handle = 'zz.pn.meta@example.test'), 'pin', 'signin_kind pin in metadata gives pin');
select is((select kind from public.staff_signin_list_v2() where handle = 'zz.pn.domain@staff.cascade.invalid'), 'pin', 'staff-domain e-mail gives pin');
select is((select kind from public.staff_signin_list_v2() where handle = 'zz.pn.plain@example.test'), 'password', 'otherwise password');
select is((select kind from public.staff_signin_list_v2() where handle = 'zz.pn.pwkind@example.test'), 'password', 'signin_kind password on a real e-mail stays password');
-- documented behaviour: the staff domain wins, because that domain has always meant a PIN login (s88 and earlier).
select is((select kind from public.staff_signin_list_v2() where handle = 'zz.pn.pwdomain@staff.cascade.invalid'), 'pin', 'staff domain stays pin even if the key says password');

select set_config('role', 'authenticated', true);
select is((select kind from public.staff_signin_list_v2() where handle = 'zz.pn.meta@example.test'), 'pin', 'a signed-in session reads the same pin kind');

reset role;
select * from finish();
rollback;
