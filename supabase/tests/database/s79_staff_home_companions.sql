-- Session 79 (lane B), TASKS #42: staff_home_v1 lists the people on the current and next stay (name, has_photo) for owner and admin
-- sessions only. Synthetic property e7a00000-...-b0 and guests; every lookup is scoped to them. Roles are impersonated with
-- request.jwt.claims as calendar_day_flags.sql does. Everything rolls back.
begin;
select plan(20);

select ok((select prosecdef and proconfig = array['search_path=""'] from pg_proc where oid = 'public.staff_home_v1(uuid)'::regprocedure),
  'staff_home_v1 stays security definer with an empty search_path');
select ok(has_function_privilege('authenticated', 'public.staff_home_v1(uuid)', 'execute') and not has_function_privilege('anon', 'public.staff_home_v1(uuid)', 'execute'),
  'staff_home_v1 grants unchanged: authenticated yes, anon no');
select ok(not has_function_privilege('authenticated', 'public.staff_guest_companions_v1(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.staff_guest_companions_v1(uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.staff_guest_companions_v1(uuid)', 'execute'),
  'the companions helper is internal only');
select ok(pg_get_functiondef('public.staff_home_v1(uuid)'::regprocedure) !~* '(id_type|id_photo_path|id_number|contact_number)',
  'staff_home_v1 names no ID type, photo path, ID number or contact column');

insert into public.properties(id, name, is_active) values ('e7a00000-0000-4000-8000-0000000000b0', 'Synthetic S79 Staff Home', true);
insert into auth.users(id) values ('e7a00000-0000-4000-8000-000000000001'), ('e7a00000-0000-4000-8000-000000000002'), ('e7a00000-0000-4000-8000-000000000003');
insert into public.staff_access_profiles(user_id, role) values
  ('e7a00000-0000-4000-8000-000000000001', 'cleaner'), ('e7a00000-0000-4000-8000-000000000002', 'admin'), ('e7a00000-0000-4000-8000-000000000003', 'owner');
insert into public.staff_property_access(user_id, property_id) values
  ('e7a00000-0000-4000-8000-000000000001', 'e7a00000-0000-4000-8000-0000000000b0'),
  ('e7a00000-0000-4000-8000-000000000002', 'e7a00000-0000-4000-8000-0000000000b0');

insert into public.guests(id, property_id, name) values
  ('e7a00000-0000-4000-8000-0000000000c1', 'e7a00000-0000-4000-8000-0000000000b0', 'Zz Sh Current'),
  ('e7a00000-0000-4000-8000-0000000000c2', 'e7a00000-0000-4000-8000-0000000000b0', 'Zz Sh Next');
insert into public.booking_inquiries(id, property_id, guest_id, guest_name, guest_email, checkin_date, checkout_date, pax, status, source) values
  ('e7a00000-0000-4000-8000-0000000000d1', 'e7a00000-0000-4000-8000-0000000000b0', 'e7a00000-0000-4000-8000-0000000000c1', 'Zz Sh Current', 'zzsh1@example.com', current_date - 1, current_date + 2, 2, 'confirmed', 'direct'),
  ('e7a00000-0000-4000-8000-0000000000d2', 'e7a00000-0000-4000-8000-0000000000b0', 'e7a00000-0000-4000-8000-0000000000c2', 'Zz Sh Next', 'zzsh2@example.com', current_date + 5, current_date + 7, 2, 'confirmed', 'direct');
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  ('e7a00000-0000-4000-8000-0000000000b0', 'cascade-direct-e7a00000-0000-4000-8000-0000000000d1', 'direct', 'confirmed', 'Zz Sh Current', current_date - 1, current_date + 2),
  ('e7a00000-0000-4000-8000-0000000000b0', 'cascade-direct-e7a00000-0000-4000-8000-0000000000d2', 'direct', 'confirmed', 'Zz Sh Next', current_date + 5, current_date + 7);
-- Current guest: Zz Sh Second (created later, has a photo) and Zz Sh First (created earlier, no photo). Next guest: one person with a photo.
insert into public.guest_companions(guest_id, property_id, name, id_type, id_photo_path, created_at) values
  ('e7a00000-0000-4000-8000-0000000000c1', 'e7a00000-0000-4000-8000-0000000000b0', 'Zz Sh Second', 'passport', 'e7a00000-0000-4000-8000-0000000000e2/e7a00000-0000-4000-8000-0000000000f2.jpg', now() - interval '1 hour'),
  ('e7a00000-0000-4000-8000-0000000000c1', 'e7a00000-0000-4000-8000-0000000000b0', 'Zz Sh First', 'other', null, now() - interval '2 hours'),
  ('e7a00000-0000-4000-8000-0000000000c2', 'e7a00000-0000-4000-8000-0000000000b0', 'Zz Sh Third', 'national_id', 'e7a00000-0000-4000-8000-0000000000e3/e7a00000-0000-4000-8000-0000000000f3.jpg', now());

-- the owner --------------------------------------------------------------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('sub','e7a00000-0000-4000-8000-000000000003','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
select is(public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')->'current_guest'->>'uid', 'cascade-direct-e7a00000-0000-4000-8000-0000000000d1', 'owner: the current guest is the fixture stay');
select is(public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')->'current_guest'->'companions',
  '[{"name":"Zz Sh First","has_photo":false},{"name":"Zz Sh Second","has_photo":true}]'::jsonb, 'owner: current guest companions, ordered by creation, name and has_photo only');
select is(public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')->'next_guest'->'companions',
  '[{"name":"Zz Sh Third","has_photo":true}]'::jsonb, 'owner: next guest companions');
select ok(jsonb_build_array(public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')->'current_guest'->'companions', public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')->'next_guest'->'companions')::text !~ '(e7a00000-0000-4000-8000-0000000000e[23]|passport|national_id|\.jpg)',
  'owner: no photo path and no ID type in the companions lists (the guest id_photo_path is the s78 ID box, unchanged)');
select is((select count(*)::int from jsonb_object_keys((public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')->'current_guest'->'companions'->0))), 2,
  'owner: each companion has exactly two keys');
select ok(public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')->'current_guest' ? 'phone', 'owner: the D-319 contact fields are still there');

-- the admin --------------------------------------------------------------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('sub','e7a00000-0000-4000-8000-000000000002','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select is(public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')->'current_guest'->'companions',
  '[{"name":"Zz Sh First","has_photo":false},{"name":"Zz Sh Second","has_photo":true}]'::jsonb, 'admin: current guest companions');
select is(public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')->'next_guest'->'companions',
  '[{"name":"Zz Sh Third","has_photo":true}]'::jsonb, 'admin: next guest companions');
select ok(jsonb_build_array(public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')->'current_guest'->'companions', public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')->'next_guest'->'companions')::text !~ '(e7a00000-0000-4000-8000-0000000000e[23]|passport|national_id|\.jpg)',
  'admin: no photo path and no ID type in the companions lists (the guest id_photo_path is the s78 ID box, unchanged)');

-- the cleaner: the key is absent --------------------------------------------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('sub','e7a00000-0000-4000-8000-000000000001','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select is(public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')->'current_guest'->>'uid', 'cascade-direct-e7a00000-0000-4000-8000-0000000000d1', 'cleaner: still sees the current stay');
select ok(not (public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')->'current_guest' ? 'companions'), 'cleaner: no companions key on the current guest');
select ok(not (public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')->'next_guest' ? 'companions'), 'cleaner: no companions key on the next guest');
select ok(public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')::text !~ '(Zz Sh First|Zz Sh Second|Zz Sh Third)', 'cleaner: no companion name anywhere in the payload');
select ok(not (public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')->'current_guest' ? 'phone'), 'cleaner: still no contact details');

-- a guest with nobody on file, seen by an owner, gets an empty list (not an absent key) --------------------------------------
reset role;
delete from public.guest_companions where guest_id = 'e7a00000-0000-4000-8000-0000000000c2';
select set_config('request.jwt.claims', json_build_object('sub','e7a00000-0000-4000-8000-000000000003','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
select is(public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')->'next_guest'->'companions', '[]'::jsonb, 'owner: nobody on file is an empty array');

-- anon still cannot call it ---------------------------------------------------------------------------------------------------
select set_config('role', 'anon', true);
select throws_ok($$select public.staff_home_v1('e7a00000-0000-4000-8000-0000000000b0')$$, '42501', null, 'anon cannot read the staff home');
reset role;

select * from finish();
rollback;
