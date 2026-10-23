-- Session 98 (lane SQL): release s98_face_queue_today_first_20261031. id_face_todo_v1 lists first the companions of guests with a stay in progress or a check-in within the next
-- 7 days (Manila date), soonest check-in first; then the s97 order. Same eligibility, cap 20, stamping and grants.
-- Synthetic fixtures only (uuids e9800000-...). Their created_at is in the FUTURE; real photos of a restored backup are stamped as just tried, so they cannot compete.
-- Everything rolls back. s97_id_face_box.sql still passes unchanged: its fixtures have no stay, so for them the order rule is the s97 one.
begin;
select plan(17);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth, storage to anon, authenticated, service_role;

create temp table s98_d on commit drop as select (now() at time zone 'Asia/Manila')::date d;

insert into public.properties(id, name, is_active) values ('e9800000-0000-4000-8000-0000000000b0', 'Synthetic S98 A', true);
-- c1 in the house, c2 arrives tomorrow, c3 arrives in 7 days (inside), c4 in 8 days (outside), c5 no stay, c6 cancelled stay arriving tomorrow, c7 stay that ended today
insert into public.guests(id, property_id, name) values
  ('e9800000-0000-4000-8000-0000000000c1', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 House'),
  ('e9800000-0000-4000-8000-0000000000c2', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 Tomorrow'),
  ('e9800000-0000-4000-8000-0000000000c3', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 Day7'),
  ('e9800000-0000-4000-8000-0000000000c4', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 Day8'),
  ('e9800000-0000-4000-8000-0000000000c5', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 NoStay'),
  ('e9800000-0000-4000-8000-0000000000c6', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 Cancelled'),
  ('e9800000-0000-4000-8000-0000000000c7', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 Ended');
insert into public.airbnb_reservations(id, property_id, confirmation_code, status, guest_id, guest_name, checkin_date, checkout_date)
  select ('e9800000-0000-4000-8000-0000000000d' || r.k)::uuid, 'e9800000-0000-4000-8000-0000000000b0', 'ZZS98R' || r.k, r.st,
         ('e9800000-0000-4000-8000-0000000000c' || r.k)::uuid, 'Zz S98 ' || r.k, (select d from s98_d) + r.i, (select d from s98_d) + r.o
    from (values ('1', 'confirmed', -1, 2), ('2', 'confirmed', 1, 3), ('3', 'confirmed', 7, 9), ('4', 'confirmed', 8, 10), ('6', 'cancelled', 1, 3), ('7', 'completed', -2, 0)) r(k, st, i, o);
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date, linked_reservation_id)
  select 'e9800000-0000-4000-8000-0000000000b0', 'zz-s98-' || r.k, 'airbnb', r.st, 'Zz S98 ' || r.k, (select d from s98_d) + r.i, (select d from s98_d) + r.o, ('e9800000-0000-4000-8000-0000000000d' || r.k)::uuid
    from (values ('1', 'confirmed', -1, 2), ('2', 'confirmed', 1, 3), ('3', 'confirmed', 7, 9), ('4', 'confirmed', 8, 10), ('6', 'cancelled', 1, 3), ('7', 'confirmed', -2, 0)) r(k, st, i, o);
-- 0101 house; 0102 house, no photo; 0103 tomorrow; 0104 tomorrow, face box already stored; 0105 day 7; 0106 day 8; 0107 no stay; 0108 cancelled; 0109 ended today.
-- Newest photo first would list 0109, 0108, 0107, 0106, 0105, 0103, 0101: the reverse of the check-in order.
insert into public.guest_companions(id, guest_id, property_id, name, id_photo_path, id_face_box, created_at) values
  ('e9800000-0000-4000-8000-000000000101', 'e9800000-0000-4000-8000-0000000000c1', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 One',   'e9800000-0000-4000-8000-000000000101/p.jpg', null, now() + interval '1 day'),
  ('e9800000-0000-4000-8000-000000000102', 'e9800000-0000-4000-8000-0000000000c1', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 Two',   null, null, now() + interval '9 days'),
  ('e9800000-0000-4000-8000-000000000103', 'e9800000-0000-4000-8000-0000000000c2', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 Three', 'e9800000-0000-4000-8000-000000000103/p.jpg', null, now() + interval '2 days'),
  ('e9800000-0000-4000-8000-000000000104', 'e9800000-0000-4000-8000-0000000000c2', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 Four',  'e9800000-0000-4000-8000-000000000104/p.jpg', '{"x":0.1,"y":0.1,"w":0.2,"h":0.2,"src":"vision"}', now() + interval '12 hours'),
  ('e9800000-0000-4000-8000-000000000105', 'e9800000-0000-4000-8000-0000000000c3', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 Five',  'e9800000-0000-4000-8000-000000000105/p.jpg', null, now() + interval '3 days'),
  ('e9800000-0000-4000-8000-000000000106', 'e9800000-0000-4000-8000-0000000000c4', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 Six',   'e9800000-0000-4000-8000-000000000106/p.jpg', null, now() + interval '4 days'),
  ('e9800000-0000-4000-8000-000000000107', 'e9800000-0000-4000-8000-0000000000c5', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 Seven', 'e9800000-0000-4000-8000-000000000107/p.jpg', null, now() + interval '5 days'),
  ('e9800000-0000-4000-8000-000000000108', 'e9800000-0000-4000-8000-0000000000c6', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 Eight', 'e9800000-0000-4000-8000-000000000108/p.jpg', null, now() + interval '6 days'),
  ('e9800000-0000-4000-8000-000000000109', 'e9800000-0000-4000-8000-0000000000c7', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 Nine',  'e9800000-0000-4000-8000-000000000109/p.jpg', null, now() + interval '7 days');

-- real photos of a restored backup must not compete with the fixtures: stamp them as just tried (rolled back)
update public.guest_companions set id_face_tried_at = now() where id::text not like 'e9800000-%' and id_photo_path is not null;

-- 1. cap and stamping -------------------------------------------------------------------------------------------------------------------------
select is(public.id_face_todo_v1(0), '[]'::jsonb, 'p_limit 0 is empty');
select is((select count(*)::int from public.guest_companions where id::text like 'e9800000-%' and id_face_tried_at is not null), 0, 'and stamps nothing');
select is((select jsonb_agg(e ->> 'companion_id') from jsonb_array_elements(public.id_face_todo_v1(2)) e),
          '["e9800000-0000-4000-8000-000000000101", "e9800000-0000-4000-8000-000000000103"]'::jsonb,
          'p_limit 2: the guest in the house first, then the guest arriving tomorrow, ahead of every newer photo');
select is((select count(*)::int from public.guest_companions where id::text like 'e9800000-%' and id_face_tried_at is not null), 2, 'exactly the two rows it handed out are stamped');
select is((select jsonb_agg(e ->> 'companion_id') from jsonb_array_elements(public.id_face_todo_v1(1)) e), '["e9800000-0000-4000-8000-000000000105"]'::jsonb,
          'p_limit 1: the guest arriving in 7 days (still inside the window) is next');

-- 2. the whole order ---------------------------------------------------------------------------------------------------------------------------
update public.guest_companions set id_face_tried_at = null where id::text like 'e9800000-%';
-- today-first group by check-in (0101, 0103, 0105); then the s97 order, newest photo first (0109 ended today, 0108 cancelled, 0107 no stay, 0106 arrives in 8 days).
-- 0102 has no photo and 0104 already has a box: neither is listed.
select is((select jsonb_agg(e.v ->> 'companion_id' order by e.n) from jsonb_array_elements(public.id_face_todo_v1(1000)) with ordinality e(v, n) where (e.v ->> 'companion_id') like 'e9800000-%'),
          '["e9800000-0000-4000-8000-000000000101", "e9800000-0000-4000-8000-000000000103", "e9800000-0000-4000-8000-000000000105", "e9800000-0000-4000-8000-000000000109", "e9800000-0000-4000-8000-000000000108", "e9800000-0000-4000-8000-000000000107", "e9800000-0000-4000-8000-000000000106"]'::jsonb,
          'in the house, tomorrow, day 7, then the rest newest first: a stay that ended today, a cancelled stay, no stay and day 8 get no priority; no-photo and boxed rows are absent');
select is((select count(*)::int from public.guest_companions where id::text like 'e9800000-%' and id_face_tried_at is not null), 7, 'all seven listed rows are stamped');
select is((select count(*)::int from jsonb_array_elements(public.id_face_todo_v1(1000)) e where (e ->> 'companion_id') like 'e9800000-%'), 0, 'a row handed out is not handed out again within the hour');
update public.guest_companions set id_face_tried_at = now() - interval '2 hours' where id::text like 'e9800000-%';
select is((select jsonb_agg(e ->> 'companion_id') from jsonb_array_elements(public.id_face_todo_v1(1)) e), '["e9800000-0000-4000-8000-000000000101"]'::jsonb, 'after an hour the guest in the house is handed out again, still first');

-- 3. cap 20 with the today group ahead of a larger, newer backlog ---------------------------------------------------------------------------------
update public.guest_companions set id_face_tried_at = null where id::text like 'e9800000-%';
insert into public.guest_companions(id, guest_id, property_id, name, id_photo_path, created_at)
  select ('e9800000-0000-4000-8000-000000000200' || lpad(g::text, 2, '0'))::uuid, 'e9800000-0000-4000-8000-0000000000c5', 'e9800000-0000-4000-8000-0000000000b0', 'Zz S98 Bulk ' || g,
         'e9800000-0000-4000-8000-000000000200' || lpad(g::text, 2, '0') || '/p.jpg', now() + interval '10 days' + g * interval '1 minute'
    from generate_series(1, 22) g;
create temp table s98_first on commit drop as select e.v, e.n from jsonb_array_elements(public.id_face_todo_v1(1000)) with ordinality e(v, n);
select is((select count(*)::int from s98_first), 20, 'rows due and a huge limit: exactly 20 are handed out');
select is((select jsonb_agg(v ->> 'companion_id' order by n) from s98_first where n <= 3),
          '["e9800000-0000-4000-8000-000000000101", "e9800000-0000-4000-8000-000000000103", "e9800000-0000-4000-8000-000000000105"]'::jsonb, 'the three today-first photos lead, though 22 newer photos are due');
select is((select count(*)::int from s98_first where (v ->> 'companion_id') like 'e9800000-0000-4000-8000-000000000200%'), 17, 'the other 17 places go to the newest backlog photos');
select is((select (select count(*) from jsonb_object_keys(v))::int from s98_first limit 1), 2, 'an entry still has exactly two keys (companion_id, path)');

-- 4. grants, volatility ------------------------------------------------------------------------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.id_face_todo_v1(integer)', 'execute') and not has_function_privilege('authenticated', 'public.id_face_todo_v1(integer)', 'execute')
          and has_function_privilege('service_role', 'public.id_face_todo_v1(integer)', 'execute'), 'id_face_todo_v1: service_role only');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where a.grantee = 0 and p.oid = 'public.id_face_todo_v1(integer)'::regprocedure), 'no PUBLIC execute (ML-21)');
select ok((select provolatile = 'v' and prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'public.id_face_todo_v1(integer)'::regprocedure), 'id_face_todo_v1 is VOLATILE, security definer, search_path empty');
set local role anon;
select throws_ok($$select public.id_face_todo_v1(20)$$, '42501', null, 'anon is refused when it calls id_face_todo_v1');
reset role;

select * from finish();
rollback;
