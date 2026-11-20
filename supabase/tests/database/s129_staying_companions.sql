-- Session 129 (lane SQL): release s129_staying_companions_20261129, D-390. staff_guest_companions_v1 is open to every ACTIVE staff profile (any role, disabled_at null), so staff_home_v1 puts
-- companions [{name, has_photo}] on current_guest and next_guest for cleaner and laundry sessions too. staff_home_v1 itself is not replaced.
-- Synthetic fixtures only (uuids e1290010-..., property ...b0, guests ...c1 current and ...c2 next, "Zz S129 ..." names); every lookup is scoped to them. Roles are impersonated with request.jwt.claims
-- as s79_staff_home_companions.sql does; the internal helper (no grant to any API role) is called as the postgres role with claims set, which is how staff_home_v1 (security definer, owned by postgres) calls it.
-- Everything rolls back.
begin;
select plan(26);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite); staff_home_v1 as production has it: authenticated and service_role, not public or anon
alter role service_role bypassrls;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
revoke all on function public.staff_home_v1(uuid) from public, anon;
grant execute on function public.staff_home_v1(uuid) to authenticated, service_role;

create function pg_temp.claims(p_sub text, p_role text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', nullif(p_sub, ''), 'role', p_role, 'aal', 'aal1', 'iat', extract(epoch from now())::bigint)::text, true);
$$;

-- the function itself ---------------------------------------------------------------------------------------------------------------------------------
select ok((select prosecdef and provolatile = 's' and proconfig = array['search_path=""'] and prorettype = 'jsonb'::regtype and prolang = (select oid from pg_language where lanname = 'sql')
             from pg_proc where oid = 'public.staff_guest_companions_v1(uuid)'::regprocedure),
  'staff_guest_companions_v1 is still sql, stable, security definer, search_path empty, returns jsonb');
select ok(not has_function_privilege('authenticated', 'public.staff_guest_companions_v1(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.staff_guest_companions_v1(uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.staff_guest_companions_v1(uuid)', 'execute'),
  'no API role has execute on the helper (revoke repeated by the migration)');
select is((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.staff_guest_companions_v1(uuid)'::regprocedure), 'f1dac1d94870fb2575343b796fb94485',
  'staff_guest_companions_v1 is the s129 body (original owner/admin body was ab34f947cec8caa410540216fd3b39f1)');
select is((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.staff_home_v1(uuid)'::regprocedure), 'b85530233f55696b136e4a49d1ed255c',
  'staff_home_v1 is NOT replaced: still the s120 guest-count body');

-- fixtures ---------------------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values ('e1290010-0000-4000-8000-0000000000b0', 'Synthetic S129 Staying', true);
insert into auth.users(id) values ('e1290010-0000-4000-8000-000000000011'), ('e1290010-0000-4000-8000-000000000012'), ('e1290010-0000-4000-8000-000000000013'), ('e1290010-0000-4000-8000-000000000014'),
  ('e1290010-0000-4000-8000-000000000015'), ('e1290010-0000-4000-8000-000000000016'), ('e1290010-0000-4000-8000-000000000017'), ('e1290010-0000-4000-8000-000000000018'), ('e1290010-0000-4000-8000-000000000019'), ('e1290010-0000-4000-8000-000000000020');
-- 11 cleaner, 12 laundry, 13 admin, 14 owner, 15 cleaner disabled, 16 no staff profile, 17 inspector, 18 finance, 19 maintenance, 20 cleaner active with no property access
insert into public.staff_access_profiles(user_id, role, disabled_at) values
  ('e1290010-0000-4000-8000-000000000011', 'cleaner', null), ('e1290010-0000-4000-8000-000000000012', 'laundry', null), ('e1290010-0000-4000-8000-000000000013', 'admin', null),
  ('e1290010-0000-4000-8000-000000000014', 'owner', null), ('e1290010-0000-4000-8000-000000000015', 'cleaner', now()), ('e1290010-0000-4000-8000-000000000017', 'inspector', null),
  ('e1290010-0000-4000-8000-000000000018', 'finance', null), ('e1290010-0000-4000-8000-000000000019', 'maintenance', null), ('e1290010-0000-4000-8000-000000000020', 'cleaner', null);
insert into public.staff_property_access(user_id, property_id) values
  ('e1290010-0000-4000-8000-000000000011', 'e1290010-0000-4000-8000-0000000000b0'), ('e1290010-0000-4000-8000-000000000012', 'e1290010-0000-4000-8000-0000000000b0'),
  ('e1290010-0000-4000-8000-000000000013', 'e1290010-0000-4000-8000-0000000000b0'), ('e1290010-0000-4000-8000-000000000015', 'e1290010-0000-4000-8000-0000000000b0');

insert into public.guests(id, property_id, name) values
  ('e1290010-0000-4000-8000-0000000000c1', 'e1290010-0000-4000-8000-0000000000b0', 'Zz S129 Current'),
  ('e1290010-0000-4000-8000-0000000000c2', 'e1290010-0000-4000-8000-0000000000b0', 'Zz S129 Next');
insert into public.booking_inquiries(id, property_id, guest_id, guest_name, guest_email, checkin_date, checkout_date, pax, status, source) values
  ('e1290010-0000-4000-8000-0000000000d1', 'e1290010-0000-4000-8000-0000000000b0', 'e1290010-0000-4000-8000-0000000000c1', 'Zz S129 Current', 'zzs1291@example.com', current_date - 1, current_date + 2, 3, 'confirmed', 'direct'),
  ('e1290010-0000-4000-8000-0000000000d2', 'e1290010-0000-4000-8000-0000000000b0', 'e1290010-0000-4000-8000-0000000000c2', 'Zz S129 Next', 'zzs1292@example.com', current_date + 5, current_date + 7, 2, 'confirmed', 'direct');
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  ('e1290010-0000-4000-8000-0000000000b0', 'cascade-direct-e1290010-0000-4000-8000-0000000000d1', 'direct', 'confirmed', 'Zz S129 Current', current_date - 1, current_date + 2),
  ('e1290010-0000-4000-8000-0000000000b0', 'cascade-direct-e1290010-0000-4000-8000-0000000000d2', 'direct', 'confirmed', 'Zz S129 Next', current_date + 5, current_date + 7);
-- Current guest: Beth (earlier, no photo, with a phone, an ID number and a note that must never come out) and Ann (later, with a photo and an e-mail typed into the name, which staff_redact_v1 hides).
-- Next guest: Cara with a photo.
insert into public.guest_companions(guest_id, property_id, name, contact_number, id_type, id_number, id_photo_path, notes, created_at) values
  ('e1290010-0000-4000-8000-0000000000c1', 'e1290010-0000-4000-8000-0000000000b0', 'Zz S129 Beth', '09171234567', 'other', 'ZZ-129-X', null, 'zz129 note', now() - interval '2 hours'),
  ('e1290010-0000-4000-8000-0000000000c1', 'e1290010-0000-4000-8000-0000000000b0', 'Zz S129 Ann zz129@example.com', null, 'passport', null, 'e1290010-0000-4000-8000-0000000000e2/e1290010-0000-4000-8000-0000000000f2.jpg', null, now() - interval '1 hour'),
  ('e1290010-0000-4000-8000-0000000000c2', 'e1290010-0000-4000-8000-0000000000b0', 'Zz S129 Cara', null, 'national_id', null, 'e1290010-0000-4000-8000-0000000000e3/e1290010-0000-4000-8000-0000000000f3.jpg', null, now());

-- the cleaner (the role D-390 opens up) ----------------------------------------------------------------------------------------------------------
select pg_temp.claims('e1290010-0000-4000-8000-000000000011', 'authenticated');
select set_config('role', 'authenticated', true);
select is(public.staff_home_v1('e1290010-0000-4000-8000-0000000000b0')->'current_guest'->'companions',
  '[{"name":"Zz S129 Beth","has_photo":false},{"name":"Zz S129 Ann [hidden]","has_photo":true}]'::jsonb,
  'cleaner: current guest companions, by creation, e-mail in a name redacted, has_photo only');
select is(public.staff_home_v1('e1290010-0000-4000-8000-0000000000b0')->'next_guest'->'companions',
  '[{"name":"Zz S129 Cara","has_photo":true}]'::jsonb, 'cleaner: next guest companions');
select is((select count(*)::int from jsonb_array_elements(public.staff_home_v1('e1290010-0000-4000-8000-0000000000b0')->'current_guest'->'companions') e, jsonb_object_keys(e) k where k not in ('name', 'has_photo')), 0,
  'cleaner: no key other than name and has_photo on a companion');
select ok(jsonb_build_array(public.staff_home_v1('e1290010-0000-4000-8000-0000000000b0')->'current_guest'->'companions', public.staff_home_v1('e1290010-0000-4000-8000-0000000000b0')->'next_guest'->'companions')::text
      !~ '(09171234567|ZZ-129-X|zz129@example|zz129 note|passport|national_id|id_photo_path|id_number|contact_number|e1290010-0000-4000-8000-0000000000e|\.jpg)',
  'cleaner: no phone, e-mail, ID number, ID type, note or photo path anywhere in the companions lists');

-- the laundry role -----------------------------------------------------------------------------------------------------------------------------------
select pg_temp.claims('e1290010-0000-4000-8000-000000000012', 'authenticated');
select is(public.staff_home_v1('e1290010-0000-4000-8000-0000000000b0')->'current_guest'->'companions',
  '[{"name":"Zz S129 Beth","has_photo":false},{"name":"Zz S129 Ann [hidden]","has_photo":true}]'::jsonb, 'laundry: current guest companions');
select is(public.staff_home_v1('e1290010-0000-4000-8000-0000000000b0')->'next_guest'->'companions',
  '[{"name":"Zz S129 Cara","has_photo":true}]'::jsonb, 'laundry: next guest companions');

-- owner and admin: unchanged ---------------------------------------------------------------------------------------------------------------------
select pg_temp.claims('e1290010-0000-4000-8000-000000000013', 'authenticated');
select is(public.staff_home_v1('e1290010-0000-4000-8000-0000000000b0')->'current_guest'->'companions',
  '[{"name":"Zz S129 Beth","has_photo":false},{"name":"Zz S129 Ann [hidden]","has_photo":true}]'::jsonb, 'admin: current guest companions, unchanged');
select pg_temp.claims('e1290010-0000-4000-8000-000000000014', 'authenticated');
select is(public.staff_home_v1('e1290010-0000-4000-8000-0000000000b0')->'next_guest'->'companions',
  '[{"name":"Zz S129 Cara","has_photo":true}]'::jsonb, 'owner: next guest companions, unchanged');

-- refusals through staff_home_v1 (42501 from its read_operations gate): an active profile with no property access row, and a disabled profile that does have one -----------
select pg_temp.claims('e1290010-0000-4000-8000-000000000020', 'authenticated');
select throws_ok($$select public.staff_home_v1('e1290010-0000-4000-8000-0000000000b0')$$, '42501', null, 'an active cleaner with no staff_property_access row cannot read the staff home');
select pg_temp.claims('e1290010-0000-4000-8000-000000000015', 'authenticated');
select throws_ok($$select public.staff_home_v1('e1290010-0000-4000-8000-0000000000b0')$$, '42501', null, 'a disabled cleaner cannot read the staff home');

-- direct calls to the helper as the postgres role with claims set (what staff_home_v1 does inside) ---------------------------------------------
reset role;
select pg_temp.claims('e1290010-0000-4000-8000-000000000015', 'authenticated');
select is(public.staff_guest_companions_v1('e1290010-0000-4000-8000-0000000000c1'), '{}'::jsonb, 'a profile with disabled_at set gets nothing');
select pg_temp.claims('e1290010-0000-4000-8000-000000000016', 'authenticated');
select is(public.staff_guest_companions_v1('e1290010-0000-4000-8000-0000000000c1'), '{}'::jsonb, 'a signed-in user with no staff profile gets nothing');
select pg_temp.claims('', 'anon');
select is(public.staff_guest_companions_v1('e1290010-0000-4000-8000-0000000000c1'), '{}'::jsonb, 'anon (no sub) gets nothing');
select pg_temp.claims('e1290010-0000-4000-8000-000000000017', 'authenticated');
select ok(public.staff_guest_companions_v1('e1290010-0000-4000-8000-0000000000c2') ? 'companions', 'inspector: active profile, companions present');
select pg_temp.claims('e1290010-0000-4000-8000-000000000018', 'authenticated');
select ok(public.staff_guest_companions_v1('e1290010-0000-4000-8000-0000000000c2') ? 'companions', 'finance: active profile, companions present');
select pg_temp.claims('e1290010-0000-4000-8000-000000000019', 'authenticated');
select ok(public.staff_guest_companions_v1('e1290010-0000-4000-8000-0000000000c2') ? 'companions', 'maintenance: active profile, companions present');
select is(public.staff_guest_companions_v1(null), '{}'::jsonb, 'an active profile with a null guest id gets nothing (key absent when guest_id is null)');
select is(public.staff_guest_companions_v1('e1290010-0000-4000-8000-0000000000c9'), '{"companions":[]}'::jsonb, 'an active profile and a guest with no companions row gets an empty list');

-- a guest with nobody on file gets [] through staff_home_v1, for a cleaner -----------------------------------------------------------------------
delete from public.guest_companions where guest_id = 'e1290010-0000-4000-8000-0000000000c2';
select pg_temp.claims('e1290010-0000-4000-8000-000000000011', 'authenticated');
select set_config('role', 'authenticated', true);
select is(public.staff_home_v1('e1290010-0000-4000-8000-0000000000b0')->'next_guest'->'companions', '[]'::jsonb, 'cleaner: nobody on file is an empty array, not an absent key');

-- no API role can call the helper directly -------------------------------------------------------------------------------------------------------
select throws_ok($$select public.staff_guest_companions_v1('e1290010-0000-4000-8000-0000000000c1')$$, '42501', null, 'authenticated cannot call the helper directly');
select set_config('role', 'anon', true);
select throws_ok($$select public.staff_guest_companions_v1('e1290010-0000-4000-8000-0000000000c1')$$, '42501', null, 'anon cannot call the helper directly');
select pg_temp.claims('', 'service_role');
select set_config('role', 'service_role', true);
select throws_ok($$select public.staff_guest_companions_v1('e1290010-0000-4000-8000-0000000000c1')$$, '42501', null, 'service_role cannot call the helper directly');
reset role;

select * from finish();
rollback;
