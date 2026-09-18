begin;
select plan(13);

select is((select count(*)::int from pg_policies where schemaname='public' and tablename='app_settings' and policyname='auth all'), 0, 'the open staff policy is gone');
select is((select count(*)::int from pg_policies where schemaname='public' and tablename='app_settings'), 3, 'three policies: anon read, staff read, admin write');

-- Fixtures: an admin with the property, a cleaner with the property, two settings rows of our own.
insert into auth.users(id) values('f3000000-0000-4000-8000-0000000000a1'),('f3000000-0000-4000-8000-0000000000a2');
insert into public.staff_access_profiles(user_id,role) values('f3000000-0000-4000-8000-0000000000a1','admin'),('f3000000-0000-4000-8000-0000000000a2','cleaner');
-- The baseline database CI builds has no production rows, so this FK fails there while passing on a
-- restored backup. Create it if absent; the whole suite is inside begin/rollback, so nothing persists.
insert into public.properties(id,name,is_active) values('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd','Cascade Hideaway',true) on conflict (id) do nothing;
insert into public.staff_property_access(user_id,property_id) values
  ('f3000000-0000-4000-8000-0000000000a1','6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'),
  ('f3000000-0000-4000-8000-0000000000a2','6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');
insert into public.app_settings(key, value) values ('s30_public_probe', '"a"'::jsonb), ('s30_secret_probe', '"hidden"'::jsonb)
  on conflict (key) do update set value = excluded.value;
insert into public.app_settings(key, value) values ('admin_pin_hash', '"x"'::jsonb) on conflict (key) do nothing;

-- Cleaner session (aal1, as every session is since D-094).
select set_config('request.jwt.claims', json_build_object('sub','f3000000-0000-4000-8000-0000000000a2','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role','authenticated',true);
select is((select count(*)::int from public.app_settings where key='s30_public_probe'), 1, 'a cleaner reads a public key');
select is((select count(*)::int from public.app_settings where key in ('s30_secret_probe','admin_pin_hash')), 0, 'a cleaner cannot read secret-named keys');
with u as (update public.app_settings set value='"b"'::jsonb where key='s30_public_probe' returning 1)
select is((select count(*)::int from u), 0, 'a cleaner cannot update a setting');
select throws_ok($$insert into public.app_settings(key,value) values('s30_cleaner_insert','"x"'::jsonb)$$, '42501', null, 'a cleaner cannot insert a setting');
select ok(not public.inventory_human_authorized('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid), 'a cleaner is still refused for stock movements');

-- Admin session, aal1.
select set_config('request.jwt.claims', json_build_object('sub','f3000000-0000-4000-8000-0000000000a1','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select is((select count(*)::int from public.app_settings where key in ('s30_secret_probe','admin_pin_hash')), 2, 'an admin reads every key');
with u as (update public.app_settings set value='"c"'::jsonb where key='s30_public_probe' returning 1)
select is((select count(*)::int from u), 1, 'an admin updates a setting');
with u as (update public.app_settings set value='"pwned"'::jsonb where key='admin_pin_hash' returning 1)
select is((select count(*)::int from u), 0, 'nobody rewrites the PIN hash through the API');
select ok(public.inventory_human_authorized('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid), 'an aal1 admin with the property may move stock (D-094)');

-- Anon: the guide's Wi-Fi read path is untouched.
reset role;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select set_config('role','anon',true);
select is((select count(*)::int from public.app_settings where key='s30_public_probe'), 1, 'anon still reads a public key');
select is((select count(*)::int from public.app_settings where key in ('s30_secret_probe','admin_pin_hash')), 0, 'anon still cannot read secret-named keys');
reset role;

select * from finish();
rollback;
