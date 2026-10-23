-- Session 97 (lane SQL): release s97_id_face_box_20261030. guest_companions.id_face_box (CHECK, reset on photo change), id_face_todo_v1, set_id_face_box_v1,
-- staff_photo_rotation_v1 (now also returns id_face_box, same gate) and the grants. Synthetic fixtures only (uuids e9700000-..., property ...b0); the fixtures carry
-- created_at in 2000 so id_face_todo_v1 (oldest first) lists them ahead of any real row in a restored backup. Everything rolls back.
begin;
select plan(55);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth, storage to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid), public.current_staff_active(text[]) to authenticated, service_role;
grant execute on function public.staff_can_view_guest_id_object_v1(text) to authenticated, service_role;

insert into public.properties(id, name, is_active) values ('e9700000-0000-4000-8000-0000000000b0', 'Synthetic S97 A', true);
insert into auth.users(id) values ('e9700000-0000-4000-8000-000000000001'), ('e9700000-0000-4000-8000-000000000002'), ('e9700000-0000-4000-8000-000000000004');
insert into public.staff_access_profiles(user_id, role) values
  ('e9700000-0000-4000-8000-000000000001', 'cleaner'),
  ('e9700000-0000-4000-8000-000000000002', 'admin');
insert into public.staff_property_access(user_id, property_id) values
  ('e9700000-0000-4000-8000-000000000001', 'e9700000-0000-4000-8000-0000000000b0'),
  ('e9700000-0000-4000-8000-000000000002', 'e9700000-0000-4000-8000-0000000000b0');
insert into public.guests(id, property_id, name) values
  ('e9700000-0000-4000-8000-0000000000c1', 'e9700000-0000-4000-8000-0000000000b0', 'Zz S97 One'),
  ('e9700000-0000-4000-8000-0000000000c3', 'e9700000-0000-4000-8000-0000000000b0', 'Zz S97 Other');
-- e1: photo, no box.  e2: photo, no box.  e3: no photo.  e4: photo, other guest (the admin sees it, the cleaner does not).
insert into public.guest_companions(id, guest_id, property_id, name, id_photo_path, created_at) values
  ('e9700000-0000-4000-8000-0000000000e1', 'e9700000-0000-4000-8000-0000000000c1', 'e9700000-0000-4000-8000-0000000000b0', 'Zz S97 One',   'e9700000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg', '2000-01-01'),
  ('e9700000-0000-4000-8000-0000000000e2', 'e9700000-0000-4000-8000-0000000000c1', 'e9700000-0000-4000-8000-0000000000b0', 'Zz S97 Two',   'e9700000-0000-4000-8000-0000000000e2/11111111-0000-4000-8000-000000000002.jpg', '2000-01-02'),
  ('e9700000-0000-4000-8000-0000000000e3', 'e9700000-0000-4000-8000-0000000000c1', 'e9700000-0000-4000-8000-0000000000b0', 'Zz S97 Three', null, '2000-01-03'),
  ('e9700000-0000-4000-8000-0000000000e4', 'e9700000-0000-4000-8000-0000000000c3', 'e9700000-0000-4000-8000-0000000000b0', 'Zz S97 Four',  'e9700000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg', '2000-01-04');

-- 1. column, CHECK, reset ---------------------------------------------------------------------------------------------------------------------
select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.guest_companions'::regclass and attname = 'id_face_box' and not attisdropped), 'jsonb', 'id_face_box is jsonb');
select is((select id_face_box from public.guest_companions where id = 'e9700000-0000-4000-8000-0000000000e1'), null, 'a new row has no face box (null)');
select throws_ok($$update public.guest_companions set id_face_box = '{"x":1,"y":0.1,"w":0.1,"h":0.1,"src":"vision"}' where id = 'e9700000-0000-4000-8000-0000000000e1'$$, '23514', null, 'CHECK: x = 1 is refused');
select throws_ok($$update public.guest_companions set id_face_box = '{"x":0.1,"y":-0.1,"w":0.1,"h":0.1,"src":"vision"}' where id = 'e9700000-0000-4000-8000-0000000000e1'$$, '23514', null, 'CHECK: y < 0 is refused');
select throws_ok($$update public.guest_companions set id_face_box = '{"x":0.1,"y":0.1,"w":0,"h":0.1,"src":"vision"}' where id = 'e9700000-0000-4000-8000-0000000000e1'$$, '23514', null, 'CHECK: w = 0 is refused');
select throws_ok($$update public.guest_companions set id_face_box = '{"x":0.1,"y":0.1,"w":0.1,"h":1.2,"src":"vision"}' where id = 'e9700000-0000-4000-8000-0000000000e1'$$, '23514', null, 'CHECK: h > 1 is refused');
select throws_ok($$update public.guest_companions set id_face_box = '{"x":0.6,"y":0.1,"w":0.5,"h":0.1,"src":"vision"}' where id = 'e9700000-0000-4000-8000-0000000000e1'$$, '23514', null, 'CHECK: x + w above 1.0001 is refused');
select throws_ok($$update public.guest_companions set id_face_box = '{"x":0.1,"y":0.6,"w":0.1,"h":0.5,"src":"vision"}' where id = 'e9700000-0000-4000-8000-0000000000e1'$$, '23514', null, 'CHECK: y + h above 1.0001 is refused');
select throws_ok($$update public.guest_companions set id_face_box = '{"x":0.1,"y":0.1,"w":0.1,"h":0.1,"src":"gps"}' where id = 'e9700000-0000-4000-8000-0000000000e1'$$, '23514', null, 'CHECK: an unknown src is refused');
select throws_ok($$update public.guest_companions set id_face_box = '{"x":0.1,"y":0.1,"w":0.1,"h":0.1}' where id = 'e9700000-0000-4000-8000-0000000000e1'$$, '23514', null, 'CHECK: a missing src is refused');
select throws_ok($$update public.guest_companions set id_face_box = '{"x":0.1,"y":0.1,"w":0.1,"h":0.1,"src":"vision","name":"x"}' where id = 'e9700000-0000-4000-8000-0000000000e1'$$, '23514', null, 'CHECK: an extra key is refused (nothing but numbers can be stored)');
select throws_ok($$update public.guest_companions set id_face_box = '{"x":"0.1","y":0.1,"w":0.1,"h":0.1,"src":"vision"}' where id = 'e9700000-0000-4000-8000-0000000000e1'$$, '23514', null, 'CHECK: a number sent as text is refused');
select throws_ok($$update public.guest_companions set id_face_box = '[0.1,0.1,0.1,0.1]' where id = 'e9700000-0000-4000-8000-0000000000e1'$$, '23514', null, 'CHECK: an array is refused');
update public.guest_companions set id_face_box = '{"x":0.25,"y":0.1,"w":0.3,"h":0.4,"src":"vision"}' where id = 'e9700000-0000-4000-8000-0000000000e1';
select is((select id_face_box from public.guest_companions where id = 'e9700000-0000-4000-8000-0000000000e1'), '{"x":0.25,"y":0.1,"w":0.3,"h":0.4,"src":"vision"}'::jsonb, 'a valid vision box is stored');
update public.guest_companions set id_face_box = '{"x":0.7,"y":0.6,"w":0.3,"h":0.4,"src":"none"}' where id = 'e9700000-0000-4000-8000-0000000000e2';
select is((select id_face_box ->> 'src' from public.guest_companions where id = 'e9700000-0000-4000-8000-0000000000e2'), 'none', 'the edge box x + w = 1 and src none is accepted');
update public.guest_companions set notes = 'unrelated edit' where id = 'e9700000-0000-4000-8000-0000000000e1';
select is((select id_face_box ->> 'x' from public.guest_companions where id = 'e9700000-0000-4000-8000-0000000000e1'), '0.25', 'an unrelated edit keeps the box');
update public.guest_companions set id_photo_path = 'e9700000-0000-4000-8000-0000000000e2/11111111-0000-4000-8000-0000000000ff.jpg' where id = 'e9700000-0000-4000-8000-0000000000e2';
select is((select id_face_box from public.guest_companions where id = 'e9700000-0000-4000-8000-0000000000e2'), null, 'replacing the photo resets the box to null');
update public.guest_companions set id_face_box = null where id = 'e9700000-0000-4000-8000-0000000000e1';

-- 2. id_face_todo_v1 --------------------------------------------------------------------------------------------------------------------------
select is((select jsonb_agg(e ->> 'companion_id' order by e ->> 'companion_id') from jsonb_array_elements(public.id_face_todo_v1(20)) e where (e ->> 'companion_id') like 'e9700000-%'),
  '["e9700000-0000-4000-8000-0000000000e1", "e9700000-0000-4000-8000-0000000000e2", "e9700000-0000-4000-8000-0000000000e4"]'::jsonb, 'todo lists the photos without a box (not the row with no photo)');
select is((select e ->> 'path' from jsonb_array_elements(public.id_face_todo_v1(20)) e where e ->> 'companion_id' = 'e9700000-0000-4000-8000-0000000000e1'), 'e9700000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg', 'each entry carries the storage path');
select is((select (select count(*) from jsonb_object_keys(e))::int from jsonb_array_elements(public.id_face_todo_v1(1)) e), 2, 'an entry has exactly two keys (companion_id, path): no name, no number');
select is(jsonb_array_length(public.id_face_todo_v1(1)), 1, 'p_limit 1 returns one entry');
select ok(jsonb_array_length(public.id_face_todo_v1(1000)) <= 20, 'a huge limit is capped at 20');
select is(public.id_face_todo_v1(0), '[]'::jsonb, 'p_limit 0 is empty');
select is((public.id_face_todo_v1(1) -> 0 ->> 'companion_id'), 'e9700000-0000-4000-8000-0000000000e1', 'oldest first');

-- 3. set_id_face_box_v1 -----------------------------------------------------------------------------------------------------------------------
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000e1', 'e9700000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg', '{"x":0.2,"y":0.1,"w":0.3,"h":0.4,"src":"vision"}'), true, 'set stores a valid box and returns true');
select is((select id_face_box ->> 'w' from public.guest_companions where id = 'e9700000-0000-4000-8000-0000000000e1'), '0.3', 'the box is on the row');
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000e4', 'e9700000-0000-4000-8000-0000000000e4/OLD.jpg', '{"x":0.2,"y":0.1,"w":0.3,"h":0.4,"src":"vision"}'), false, 'a replaced photo (path no longer current) is skipped: false');
select is((select id_face_box from public.guest_companions where id = 'e9700000-0000-4000-8000-0000000000e4'), null, 'and nothing was written');
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000e4', 'e9700000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg', '{"x":0.2,"y":0.1,"w":0,"h":0.4,"src":"vision"}'), false, 'an invalid box returns false and does not raise');
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000e4', 'e9700000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg', 'null'::jsonb), false, 'a json null box returns false');
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000e4', 'e9700000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg', null), false, 'a SQL null box returns false');
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000fe', 'x', '{"x":0.2,"y":0.1,"w":0.3,"h":0.4,"src":"vision"}'), false, 'an unknown companion returns false');
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000e4', 'e9700000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg', '{"x":0,"y":0,"w":1,"h":1,"src":"none"}'), true, 'src none (no face found) is stored');
select ok(not exists (select 1 from jsonb_array_elements(public.id_face_todo_v1(20)) e where e ->> 'companion_id' in ('e9700000-0000-4000-8000-0000000000e1', 'e9700000-0000-4000-8000-0000000000e4')), 'a stored box (vision or none) leaves the todo list');

-- 3b. the waves no-face payload (cross-lane): all five keys, {"x":0,"y":0,"w":1,"h":1,"src":"none"}
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000e2', 'e9700000-0000-4000-8000-0000000000e2/11111111-0000-4000-8000-0000000000ff.jpg', '{"src":"none"}'), false, 'a bare {"src":"none"} is refused (false): the CHECK keeps all five keys');
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000e2', 'e9700000-0000-4000-8000-0000000000e2/11111111-0000-4000-8000-0000000000ff.jpg', '{"x":0,"y":0,"w":1,"h":1,"src":"none"}'), true, 'the waves no-face payload is accepted (true)');
select is((select id_face_box from public.guest_companions where id = 'e9700000-0000-4000-8000-0000000000e2'), '{"x":0,"y":0,"w":1,"h":1,"src":"none"}'::jsonb, 'and stored exactly as given');
select ok(not exists (select 1 from jsonb_array_elements(public.id_face_todo_v1(20)) e where e ->> 'companion_id' = 'e9700000-0000-4000-8000-0000000000e2'), 'a row stored with the no-face payload is no longer in the todo list (not retried)');

-- 4. staff_photo_rotation_v1 carries the box (same gate) --------------------------------------------------------------------------------------
select is(pg_get_function_result('public.staff_photo_rotation_v1(text[])'::regprocedure), 'TABLE(path text, rotation smallint, id_face_box jsonb)', 'staff_photo_rotation_v1 returns path, rotation, id_face_box');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9700000-0000-4000-8000-000000000002"}';
select is((select id_face_box ->> 'x' from public.staff_photo_rotation_v1(array['e9700000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg'])), '0.2', 'admin: the box comes back with the path');
select is((select count(*)::int from public.staff_photo_rotation_v1(array['e9700000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg', 'e9700000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg', 'no/such.jpg'])), 2, 'admin: both photos, not the unknown path');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9700000-0000-4000-8000-000000000001"}';
select is((select count(*)::int from public.staff_photo_rotation_v1(array['e9700000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg', 'e9700000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg'])), 0, 'cleaner: neither photo is viewable (no stay in the house), so no box leaks');
select throws_ok($$select * from public.staff_photo_rotation_v1((select array_agg('p' || g) from generate_series(1, 51) g))$$, '22023', 'too_many_paths', 'cleaner: 51 paths are refused');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9700000-0000-4000-8000-000000000004"}';
select throws_ok($$select * from public.staff_photo_rotation_v1(array['x'])$$, '42501', 'forbidden', 'a user with no staff profile is refused');
reset role;

-- 4b. staff_guest_card_v1 carries id_face_box beside id_photo_path (same gate) -------------------------------------------------------------------
select ok(public.staff_guest_card_v1('e9700000-0000-4000-8000-0000000000b0', 'e9700000-0000-4000-8000-0000000000c1', current_date) ? 'id_face_box', 'the card has an id_face_box key');
select is(public.staff_guest_card_v1('e9700000-0000-4000-8000-0000000000b0', 'e9700000-0000-4000-8000-0000000000c1', current_date) -> 'id_face_box', 'null'::jsonb, 'no stay in the house: the gate hides the photo path, so the box is null too (never leaks past the gate)');
select is(public.staff_guest_card_v1('e9700000-0000-4000-8000-0000000000b0', null, current_date) -> 'id_face_box', 'null'::jsonb, 'no guest at all: the box is null');
select ok(not has_function_privilege('anon', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute') and not has_function_privilege('authenticated', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute')
          and has_function_privilege('service_role', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute'), 'the card keeps its grants closed (service_role only)');

-- 5. grants, heartbeat ------------------------------------------------------------------------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.id_face_todo_v1(integer)', 'execute') and not has_function_privilege('authenticated', 'public.id_face_todo_v1(integer)', 'execute')
          and has_function_privilege('service_role', 'public.id_face_todo_v1(integer)', 'execute'), 'id_face_todo_v1: service_role only');
select ok(not has_function_privilege('anon', 'public.set_id_face_box_v1(uuid,text,jsonb)', 'execute') and not has_function_privilege('authenticated', 'public.set_id_face_box_v1(uuid,text,jsonb)', 'execute')
          and has_function_privilege('service_role', 'public.set_id_face_box_v1(uuid,text,jsonb)', 'execute'), 'set_id_face_box_v1: service_role only');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where a.grantee = 0
                       and p.oid in ('public.id_face_todo_v1(integer)'::regprocedure, 'public.set_id_face_box_v1(uuid,text,jsonb)'::regprocedure, 'public.staff_photo_rotation_v1(text[])'::regprocedure)), 'no PUBLIC execute on the three functions (ML-21)');
select ok(not has_function_privilege('anon', 'public.staff_photo_rotation_v1(text[])', 'execute') and has_function_privilege('authenticated', 'public.staff_photo_rotation_v1(text[])', 'execute'), 'staff_photo_rotation_v1: authenticated yes, anon no');
select ok(not has_function_privilege('anon', 'public.guest_companions_reset_face_box()', 'execute') and not has_function_privilege('authenticated', 'public.guest_companions_reset_face_box()', 'execute'), 'the trigger function is closed to API roles');
select ok((select expected_interval_seconds = 86400 and not ops_risk and last_succeeded_at is not null from public.job_heartbeats where job_name = 'id-face-locate'), 'heartbeat id-face-locate: 86400 s, no ops risk, seeded');
set local role anon;
select throws_ok($$select public.id_face_todo_v1(20)$$, '42501', null, 'anon is refused when it calls id_face_todo_v1');
reset role;

select * from finish();
rollback;
