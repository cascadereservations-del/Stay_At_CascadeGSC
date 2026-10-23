-- Session 97 (lane SQL): release s97_id_face_box_20261030. guest_companions.id_face_box (CHECK) and id_face_tried_at (both reset when the photo path changes), id_face_todo_v1
-- (hands out and stamps, newest photo first, not again within the hour, cap 20), set_id_face_box_v1, staff_guest_card_v1 (id_face_box beside id_photo_path, same gate) and the grants.
-- Synthetic fixtures only (uuids e9700000-...). Their created_at is in the FUTURE so id_face_todo_v1 (never-tried first, then newest photo first) lists them ahead of any real row in a
-- restored backup; every todo assertion is scoped to the fixture ids. Everything rolls back.
begin;
select plan(57);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth, storage to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid), public.current_staff_active(text[]) to authenticated, service_role;

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
  ('e9700000-0000-4000-8000-0000000000c3', 'e9700000-0000-4000-8000-0000000000b0', 'Zz S97 Other'),
  ('e9700000-0000-4000-8000-0000000000c5', 'e9700000-0000-4000-8000-0000000000b0', 'Zz S97 Bulk');
-- e1: the primary photo of guest c1 (its name matches the guest).  e2: a second photo of c1.  e3: no photo.  e4: photo of guest c3.
insert into public.guest_companions(id, guest_id, property_id, name, id_photo_path, created_at) values
  ('e9700000-0000-4000-8000-0000000000e1', 'e9700000-0000-4000-8000-0000000000c1', 'e9700000-0000-4000-8000-0000000000b0', 'Zz S97 One',   'e9700000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg', now() + interval '1 day'),
  ('e9700000-0000-4000-8000-0000000000e2', 'e9700000-0000-4000-8000-0000000000c1', 'e9700000-0000-4000-8000-0000000000b0', 'Zz S97 Two',   'e9700000-0000-4000-8000-0000000000e2/11111111-0000-4000-8000-000000000002.jpg', now() + interval '2 days'),
  ('e9700000-0000-4000-8000-0000000000e3', 'e9700000-0000-4000-8000-0000000000c1', 'e9700000-0000-4000-8000-0000000000b0', 'Zz S97 Three', null, now() + interval '3 days'),
  ('e9700000-0000-4000-8000-0000000000e4', 'e9700000-0000-4000-8000-0000000000c3', 'e9700000-0000-4000-8000-0000000000b0', 'Zz S97 Four',  'e9700000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg', now() + interval '4 days');

-- real photos of a restored backup must not compete with the fixtures: stamp them as just tried (rolled back)
update public.guest_companions set id_face_tried_at = now() where id::text not like 'e9700000-%' and id_photo_path is not null;

-- 1. columns, CHECK, reset ----------------------------------------------------------------------------------------------------------------------
select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.guest_companions'::regclass and attname = 'id_face_box' and not attisdropped), 'jsonb', 'id_face_box is jsonb');
select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.guest_companions'::regclass and attname = 'id_face_tried_at' and not attisdropped), 'timestamp with time zone', 'id_face_tried_at is timestamptz');
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
update public.guest_companions set id_face_box = '{"x":0.7,"y":0.6,"w":0.3,"h":0.4,"src":"none"}', id_face_tried_at = now() where id = 'e9700000-0000-4000-8000-0000000000e2';
select is((select id_face_box ->> 'src' from public.guest_companions where id = 'e9700000-0000-4000-8000-0000000000e2'), 'none', 'the edge box x + w = 1 and src none is accepted');
update public.guest_companions set notes = 'unrelated edit' where id = 'e9700000-0000-4000-8000-0000000000e1';
select is((select id_face_box ->> 'x' from public.guest_companions where id = 'e9700000-0000-4000-8000-0000000000e1'), '0.25', 'an unrelated edit keeps the box');
update public.guest_companions set id_photo_path = 'e9700000-0000-4000-8000-0000000000e2/11111111-0000-4000-8000-0000000000ff.jpg' where id = 'e9700000-0000-4000-8000-0000000000e2';
select ok((select id_face_box is null and id_face_tried_at is null from public.guest_companions where id = 'e9700000-0000-4000-8000-0000000000e2'), 'replacing the photo resets the box AND the tried stamp to null');

-- 2. id_face_todo_v1: order, stamping, not again within the hour, cap ------------------------------------------------------------------------------
-- e1 holds a box, e2 was just reset (never tried), e3 has no photo, e4 is never tried. Newest photo first: e4 (+4 days) before e2 (+2 days).
select is((select jsonb_agg(e ->> 'companion_id') from jsonb_array_elements(public.id_face_todo_v1(2)) e), '["e9700000-0000-4000-8000-0000000000e4", "e9700000-0000-4000-8000-0000000000e2"]'::jsonb, 'a newer photo comes before an older one; a row with a box and a row with no photo are not listed');
select is((select count(*)::int from public.guest_companions where id in ('e9700000-0000-4000-8000-0000000000e4', 'e9700000-0000-4000-8000-0000000000e2') and id_face_tried_at is not null), 2, 'the rows it handed out are stamped id_face_tried_at');
select is((select count(*)::int from jsonb_array_elements(public.id_face_todo_v1(20)) e where (e ->> 'companion_id') in ('e9700000-0000-4000-8000-0000000000e4', 'e9700000-0000-4000-8000-0000000000e2')), 0, 'a row handed out is not handed out again within the hour');
update public.guest_companions set id_face_tried_at = now() - interval '2 hours' where id = 'e9700000-0000-4000-8000-0000000000e4';
select is((select count(*)::int from jsonb_array_elements(public.id_face_todo_v1(20)) e where (e ->> 'companion_id') = 'e9700000-0000-4000-8000-0000000000e4'), 1, 'after an hour a photo that never got a box is handed out again');
-- 22 more photos, newest of all: one goes to the p_limit 1 call, 20 come out of the next, the last one after that
insert into public.guest_companions(id, guest_id, property_id, name, id_photo_path, created_at)
  select ('e9700000-0000-4000-8000-0000000001' || lpad(g::text, 2, '0'))::uuid, 'e9700000-0000-4000-8000-0000000000c5', 'e9700000-0000-4000-8000-0000000000b0', 'Zz S97 Bulk ' || g,
         'e9700000-0000-4000-8000-0000000001' || lpad(g::text, 2, '0') || '/22222222-0000-4000-8000-000000000000.jpg', now() + interval '10 days' + g * interval '1 minute'
    from generate_series(1, 22) g;
select is(public.id_face_todo_v1(0), '[]'::jsonb, 'p_limit 0 is empty and stamps nothing');
select is(jsonb_array_length(public.id_face_todo_v1(1)), 1, 'p_limit 1 returns one entry (21 rows are left due)');
create temp table s97_first on commit drop as select e from jsonb_array_elements(public.id_face_todo_v1(1000)) e;
select is((select count(*)::int from s97_first), 20, 'rows due and a huge limit: exactly 20 are handed out (21 were due)');
select is((select (select count(*) from jsonb_object_keys(e))::int from s97_first limit 1), 2, 'an entry has exactly two keys (companion_id, path): no name, no number');
select is((select count(*)::int from s97_first where (e ->> 'companion_id') like 'e9700000-0000-4000-8000-0000000001%'), 20, 'the 20 are the newest photos (the bulk ones)');
select is((select count(*)::int from jsonb_array_elements(public.id_face_todo_v1(1000)) e where (e ->> 'companion_id') like 'e9700000-0000-4000-8000-0000000001%'), 1, 'the next call hands out the 1 left over, never the 20 again');

-- 3. set_id_face_box_v1 -----------------------------------------------------------------------------------------------------------------------
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000e1', 'e9700000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg', '{"x":0.2,"y":0.1,"w":0.3,"h":0.4,"src":"vision"}'), true, 'set stores a valid box and returns true');
select is((select id_face_box ->> 'w' from public.guest_companions where id = 'e9700000-0000-4000-8000-0000000000e1'), '0.3', 'the box is on the row');
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000e4', 'e9700000-0000-4000-8000-0000000000e4/OLD.jpg', '{"x":0.2,"y":0.1,"w":0.3,"h":0.4,"src":"vision"}'), false, 'a replaced photo (path no longer current) is skipped: false');
select is((select id_face_box from public.guest_companions where id = 'e9700000-0000-4000-8000-0000000000e4'), null, 'and nothing was written');
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000e4', 'e9700000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg', '{"x":0.2,"y":0.1,"w":0,"h":0.4,"src":"vision"}'), false, 'an invalid box returns false and does not raise');
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000e4', 'e9700000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg', 'null'::jsonb), false, 'a json null box returns false');
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000e4', 'e9700000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg', null), false, 'a SQL null box returns false');
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000fe', 'x', '{"x":0.2,"y":0.1,"w":0.3,"h":0.4,"src":"vision"}'), false, 'an unknown companion returns false');
-- the waves no-face payload (cross-lane): all five keys
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000e4', 'e9700000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg', '{"src":"none"}'), false, 'a bare {"src":"none"} is refused (false): the CHECK keeps all five keys');
select is(public.set_id_face_box_v1('e9700000-0000-4000-8000-0000000000e4', 'e9700000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg', '{"x":0,"y":0,"w":1,"h":1,"src":"none"}'), true, 'the waves no-face payload is accepted (true)');
select is((select id_face_box from public.guest_companions where id = 'e9700000-0000-4000-8000-0000000000e4'), '{"x":0,"y":0,"w":1,"h":1,"src":"none"}'::jsonb, 'and stored exactly as given');
update public.guest_companions set id_face_tried_at = null where id in ('e9700000-0000-4000-8000-0000000000e1', 'e9700000-0000-4000-8000-0000000000e4');
select is((select count(*)::int from jsonb_array_elements(public.id_face_todo_v1(1000)) e where (e ->> 'companion_id') in ('e9700000-0000-4000-8000-0000000000e1', 'e9700000-0000-4000-8000-0000000000e4')), 0, 'rows stored with a vision box or the no-face payload are never listed again, even with a null tried stamp');

-- 4. staff_guest_card_v1 carries id_face_box beside id_photo_path (same gate) -------------------------------------------------------------------
update public.guest_companions set id_face_box = '{"x":0.5,"y":0.5,"w":0.2,"h":0.2,"src":"vision"}' where id = 'e9700000-0000-4000-8000-0000000000e2';
set local role service_role;
set local request.jwt.claims = '{"sub":"e9700000-0000-4000-8000-000000000002"}';
select is(public.staff_guest_card_v1('e9700000-0000-4000-8000-0000000000b0', 'e9700000-0000-4000-8000-0000000000c1', current_date) ->> 'id_photo_path', 'e9700000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg', 'admin: the card returns the primary photo path');
select is(public.staff_guest_card_v1('e9700000-0000-4000-8000-0000000000b0', 'e9700000-0000-4000-8000-0000000000c1', current_date) -> 'id_face_box', '{"x":0.2,"y":0.1,"w":0.3,"h":0.4,"src":"vision"}'::jsonb, 'admin: id_face_box is the box of that primary companion (not the second photo)');
select is(public.staff_guest_card_v1('e9700000-0000-4000-8000-0000000000b0', 'e9700000-0000-4000-8000-0000000000c3', current_date) -> 'id_face_box', '{"x":0,"y":0,"w":1,"h":1,"src":"none"}'::jsonb, 'admin: a no-face box is returned as stored');
select is(public.staff_guest_card_v1('e9700000-0000-4000-8000-0000000000b0', 'e9700000-0000-4000-8000-0000000000c5', current_date) -> 'id_face_box', 'null'::jsonb, 'admin: a photo with no box yet gives a null box');
select is(public.staff_guest_card_v1('e9700000-0000-4000-8000-0000000000b0', null, current_date) -> 'id_face_box', 'null'::jsonb, 'no guest at all: the box is null');
reset role;
set local role service_role;
set local request.jwt.claims = '{"sub":"e9700000-0000-4000-8000-000000000001"}';
select is(public.staff_guest_card_v1('e9700000-0000-4000-8000-0000000000b0', 'e9700000-0000-4000-8000-0000000000c1', current_date) -> 'id_face_box', '{"x":0.2,"y":0.1,"w":0.3,"h":0.4,"src":"vision"}'::jsonb, 'cleaner (read_operations, D-302.1: every active staff account sees the ID photo): the same path and box');
reset role;
set local role service_role;
set local request.jwt.claims = '{"sub":"e9700000-0000-4000-8000-000000000004"}';
select ok((select c -> 'id_photo_path' = 'null'::jsonb and c -> 'id_face_box' = 'null'::jsonb and c ? 'id_face_box'
             from (select public.staff_guest_card_v1('e9700000-0000-4000-8000-0000000000b0', 'e9700000-0000-4000-8000-0000000000c1', current_date) c) x), 'gate closed (a user with no staff profile): path and box are both null, never a box without the gate');
reset role;
set local role service_role;
set local request.jwt.claims = '{}';
select ok((select c -> 'id_photo_path' = 'null'::jsonb and c -> 'id_face_box' = 'null'::jsonb
             from (select public.staff_guest_card_v1('e9700000-0000-4000-8000-0000000000b0', 'e9700000-0000-4000-8000-0000000000c1', current_date) c) x), 'gate closed (no session): path and box are both null');
reset role;

-- 5. grants, heartbeat ------------------------------------------------------------------------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.id_face_todo_v1(integer)', 'execute') and not has_function_privilege('authenticated', 'public.id_face_todo_v1(integer)', 'execute')
          and has_function_privilege('service_role', 'public.id_face_todo_v1(integer)', 'execute'), 'id_face_todo_v1: service_role only');
select ok(not has_function_privilege('anon', 'public.set_id_face_box_v1(uuid,text,jsonb)', 'execute') and not has_function_privilege('authenticated', 'public.set_id_face_box_v1(uuid,text,jsonb)', 'execute')
          and has_function_privilege('service_role', 'public.set_id_face_box_v1(uuid,text,jsonb)', 'execute'), 'set_id_face_box_v1: service_role only');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where a.grantee = 0
                       and p.oid in ('public.id_face_todo_v1(integer)'::regprocedure, 'public.set_id_face_box_v1(uuid,text,jsonb)'::regprocedure, 'public.staff_guest_card_v1(uuid,uuid,date)'::regprocedure)), 'no PUBLIC execute on the three functions (ML-21)');
select ok(not has_function_privilege('anon', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute') and not has_function_privilege('authenticated', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute')
          and has_function_privilege('service_role', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute'), 'the card keeps its grants closed (service_role only)');
select ok(not has_function_privilege('anon', 'public.guest_companions_reset_face_box()', 'execute') and not has_function_privilege('authenticated', 'public.guest_companions_reset_face_box()', 'execute'), 'the trigger function is closed to API roles');
select ok((select provolatile = 'v' from pg_proc where oid = 'public.id_face_todo_v1(integer)'::regprocedure), 'id_face_todo_v1 is VOLATILE (it stamps)');
select ok((select expected_interval_seconds = 86400 and not ops_risk and last_succeeded_at is not null from public.job_heartbeats where job_name = 'id-face-locate'), 'heartbeat id-face-locate: 86400 s, no ops risk, seeded');
select is(pg_get_function_result('public.staff_photo_rotation_v1(text[])'::regprocedure), 'TABLE(path text, rotation smallint)', 'staff_photo_rotation_v1 is untouched (path, rotation)');
set local role anon;
select throws_ok($$select public.id_face_todo_v1(20)$$, '42501', null, 'anon is refused when it calls id_face_todo_v1');
reset role;

select * from finish();
rollback;
