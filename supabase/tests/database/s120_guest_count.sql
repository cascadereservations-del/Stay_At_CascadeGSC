-- Session 120 (lane SC): release s120_guest_count_20261120. stay_staying.guest_count, set_stay_guest_count_v1, staff_guest_stay_v1 and the
-- guest_count / booked_guests keys of the `staying` object in staff_home_v1 current_guest / next_guest (contract docs/s120/CONTRACT-guest-count.md).
-- Synthetic fixtures only (global keys e1200001-..., property ...b0 and ...b1, stay uids zz-s120gc-*); every lookup is scoped to them because a real backup holds real rows.
-- Refusals are tested by calling as the refused role. calendar_events.nights is a generated column and is never sent.
-- Everything rolls back.
begin;
select plan(55);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid), public.current_staff_active(text[]) to authenticated, service_role;
grant execute on function public.staff_home_v1(uuid) to authenticated, service_role;

-- fixtures -------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values
  ('e1200001-0000-4000-8000-0000000000b0', 'Synthetic S120 GC A', true),
  ('e1200001-0000-4000-8000-0000000000b1', 'Synthetic S120 GC B', true);
insert into auth.users(id) values
  ('e1200001-0000-4000-8000-000000000001'), ('e1200001-0000-4000-8000-000000000002'),
  ('e1200001-0000-4000-8000-000000000003'), ('e1200001-0000-4000-8000-000000000004');
insert into public.staff_access_profiles(user_id, role) values
  ('e1200001-0000-4000-8000-000000000001', 'cleaner'),
  ('e1200001-0000-4000-8000-000000000002', 'admin'),
  ('e1200001-0000-4000-8000-000000000003', 'finance');
-- 04 has no staff profile at all. The admin has no access to property B.
insert into public.staff_property_access(user_id, property_id) values
  ('e1200001-0000-4000-8000-000000000001', 'e1200001-0000-4000-8000-0000000000b0'),
  ('e1200001-0000-4000-8000-000000000002', 'e1200001-0000-4000-8000-0000000000b0'),
  ('e1200001-0000-4000-8000-000000000003', 'e1200001-0000-4000-8000-0000000000b0');
insert into public.guests(id, property_id, name) values
  ('e1200001-0000-4000-8000-0000000000c1', 'e1200001-0000-4000-8000-0000000000b0', 'Zz S120 Guest One'),
  ('e1200001-0000-4000-8000-0000000000c2', 'e1200001-0000-4000-8000-0000000000b0', 'Zz S120 Guest Two'),
  ('e1200001-0000-4000-8000-0000000000c3', 'e1200001-0000-4000-8000-0000000000b0', 'Zz S120 Guest Three'),
  ('e1200001-0000-4000-8000-0000000000c4', 'e1200001-0000-4000-8000-0000000000b0', 'Zz S120 Guest Four');
-- Manila date is used for every stay: staff_home_v1 and staff_current_next_stays_v1 read "today" in Asia/Manila.
-- cur (guest one, booked 2) is in the house now, nxt (guest one, booked 3) is the next arrival, past (guest two) is over, bare (guest four, booked unknown) is later, far has no reservation.
insert into public.airbnb_reservations(id, property_id, confirmation_code, source, status, guest_id, guest_name, guest_count, checkin_date, checkout_date) values
  ('e1200001-0000-4000-8000-0000000000d1', 'e1200001-0000-4000-8000-0000000000b0', 'ZZS120GC1', 'airbnb', 'confirmed', 'e1200001-0000-4000-8000-0000000000c1', 'Zz S120 Guest One',
     2, (now() at time zone 'Asia/Manila')::date - 1, (now() at time zone 'Asia/Manila')::date + 2),
  ('e1200001-0000-4000-8000-0000000000d2', 'e1200001-0000-4000-8000-0000000000b0', 'ZZS120GC2', 'airbnb', 'confirmed', 'e1200001-0000-4000-8000-0000000000c1', 'Zz S120 Guest One',
     3, (now() at time zone 'Asia/Manila')::date + 3, (now() at time zone 'Asia/Manila')::date + 5),
  ('e1200001-0000-4000-8000-0000000000d3', 'e1200001-0000-4000-8000-0000000000b0', 'ZZS120GC3', 'airbnb', 'completed', 'e1200001-0000-4000-8000-0000000000c2', 'Zz S120 Guest Two',
     1, (now() at time zone 'Asia/Manila')::date - 10, (now() at time zone 'Asia/Manila')::date - 8),
  ('e1200001-0000-4000-8000-0000000000d4', 'e1200001-0000-4000-8000-0000000000b0', 'ZZS120GC4', 'airbnb', 'confirmed', 'e1200001-0000-4000-8000-0000000000c4', 'Zz S120 Guest Four',
     null, (now() at time zone 'Asia/Manila')::date + 20, (now() at time zone 'Asia/Manila')::date + 22);
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date, linked_reservation_id) values
  ('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur',  'airbnb', 'confirmed', 'Zz S120 Guest One',  (now() at time zone 'Asia/Manila')::date - 1,  (now() at time zone 'Asia/Manila')::date + 2,  'e1200001-0000-4000-8000-0000000000d1'),
  ('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-nxt',  'airbnb', 'confirmed', 'Zz S120 Guest One',  (now() at time zone 'Asia/Manila')::date + 3,  (now() at time zone 'Asia/Manila')::date + 5,  'e1200001-0000-4000-8000-0000000000d2'),
  ('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-past', 'airbnb', 'confirmed', 'Zz S120 Guest Two',  (now() at time zone 'Asia/Manila')::date - 10, (now() at time zone 'Asia/Manila')::date - 8,  'e1200001-0000-4000-8000-0000000000d3'),
  ('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-bare', 'airbnb', 'confirmed', 'Zz S120 Guest Four', (now() at time zone 'Asia/Manila')::date + 20, (now() at time zone 'Asia/Manila')::date + 22, 'e1200001-0000-4000-8000-0000000000d4');
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  ('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-far',   'airbnb', 'confirmed', 'Zz S120 Far',   (now() at time zone 'Asia/Manila')::date + 9,  (now() at time zone 'Asia/Manila')::date + 11),
  ('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-blk',   'airbnb', 'blocked',   null,            (now() at time zone 'Asia/Manila')::date + 30, (now() at time zone 'Asia/Manila')::date + 32),
  ('e1200001-0000-4000-8000-0000000000b1', 'zz-s120gc-other', 'airbnb', 'confirmed', 'Zz S120 Other', (now() at time zone 'Asia/Manila')::date + 3,  (now() at time zone 'Asia/Manila')::date + 5);

-- 1-3. closed tables, closed grants -------------------------------------------------------------------------------------------------------------
select ok((select bool_and(relrowsecurity) from pg_class where oid in ('public.stay_staying'::regclass, 'public.stay_staying_history'::regclass)), 'RLS is still on for both tables');
select ok(not has_table_privilege('authenticated', 'public.stay_staying', 'select, insert, update, delete')
      and not has_table_privilege('anon', 'public.stay_staying', 'select, insert, update, delete')
      and not has_table_privilege('service_role', 'public.stay_staying', 'select, insert, update, delete'), 'stay_staying still has no direct grant for any API role');
select ok(not has_function_privilege('anon', 'public.set_stay_guest_count_v1(uuid,text,integer,integer,text,text)', 'execute')
      and not has_function_privilege('service_role', 'public.set_stay_guest_count_v1(uuid,text,integer,integer,text,text)', 'execute')
      and not has_function_privilege('anon', 'public.staff_guest_stay_v1(uuid,uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.staff_guest_stay_v1(uuid,uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.stay_guest_count_json_v1(uuid,text)', 'execute')
      and not has_function_privilege('anon', 'public.stay_guest_count_json_v1(uuid,text)', 'execute'),
  'the RPCs follow the set_stay_staying_v1 pattern (no anon, no service_role) and the helper has no API grant');

-- 4-10. the gate: only owner/admin of the property -------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200001-0000-4000-8000-000000000004"}';
select throws_ok($$select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur', 2, 0, null, 'gate-1')$$,
  '42501', 'forbidden', 'a user with no staff profile cannot set the count');
select throws_ok($$select public.staff_guest_stay_v1('e1200001-0000-4000-8000-0000000000b0', 'e1200001-0000-4000-8000-0000000000c1')$$,
  '42501', 'forbidden', 'a user with no staff profile cannot read a guest stay');
reset role;
set local role authenticated;
set local request.jwt.claims = '{}';
select throws_ok($$select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur', 2, 0, null, 'gate-2')$$,
  '42501', 'forbidden', 'no session cannot set the count');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200001-0000-4000-8000-000000000001"}';
select throws_ok($$select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur', 2, 0, null, 'gate-3')$$,
  '42501', 'forbidden', 'a cleaner cannot set the count');
select throws_ok($$select public.staff_guest_stay_v1('e1200001-0000-4000-8000-0000000000b0', 'e1200001-0000-4000-8000-0000000000c1')$$,
  '42501', 'forbidden', 'a cleaner cannot read a guest stay');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200001-0000-4000-8000-000000000003"}';
select throws_ok($$select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur', 2, 0, null, 'gate-4')$$,
  '42501', 'forbidden', 'finance cannot set the count');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200001-0000-4000-8000-000000000002"}';
select throws_ok($$select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b1', 'zz-s120gc-other', 2, 0, null, 'gate-5')$$,
  '42501', 'forbidden', 'an admin of property A cannot set a count in property B');
reset role;

-- 11-18. admin: validation ---------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200001-0000-4000-8000-000000000002"}';
select throws_ok($$select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur', 0, 0, null, 'val-1')$$, '22023', 'count_invalid', 'a count of 0 is refused');
select throws_ok($$select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur', 4, 0, null, 'val-2')$$, '22023', 'count_invalid', 'a count of 4 is refused');
select throws_ok($$select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur', null, 0, null, 'val-3')$$, '22023', 'count_invalid', 'a null count is refused');
select throws_ok($$select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', ' ', 2, 0, null, 'val-4')$$, '22023', 'uid_required', 'a blank stay uid is refused');
select throws_ok($$select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur', 2, 0, null, null)$$, '22023', 'idempotency_key_invalid', 'an idempotency key is required');
select throws_ok($$select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-nope', 2, 0, null, 'val-5')$$, 'P0002', 'stay_not_found', 'an unknown stay is refused');
select throws_ok($$select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-blk', 2, 0, null, 'val-6')$$, 'P0002', 'stay_not_found', 'a calendar block is not a stay');
reset role;
select is((select count(*)::int from public.stay_staying where property_id = 'e1200001-0000-4000-8000-0000000000b0'), 0, 'every refused call wrote nothing');

-- 19-27. admin writes: lock, idempotent replay, history -----------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200001-0000-4000-8000-000000000002"}';
select is((select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur', 2, 0, 'counted at the door', 'k1')),
  '{"ok": true, "guest_count": 2, "version": 1}'::jsonb, 'admin: the first count starts the row at version 1');
select is((select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur', 2, 0, 'counted at the door', 'k1')),
  '{"ok": true, "guest_count": 2, "version": 1, "replay": true}'::jsonb, 'the same key with the same count replays the first result (even with a now-stale expected version)');
select throws_ok($$select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur', 3, 1, null, 'k1')$$,
  '22023', 'idempotency_key_reused', 'the same key with another count is refused');
select throws_ok($$select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur', 3, 0, null, 'k2')$$,
  '40001', null, 'a stale expected version (0 after the first write) is 40001');
select throws_ok($$select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur', 3, null, null, 'k2')$$,
  '40001', null, 'a null expected version on an existing row is 40001');
select is((select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur', 3, 1, null, 'k3')),
  '{"ok": true, "guest_count": 3, "version": 2}'::jsonb, 'the right expected version moves it to 2');
reset role;
select is((select count(*)::int from public.stay_staying_history where property_id = 'e1200001-0000-4000-8000-0000000000b0' and stay_uid = 'zz-s120gc-cur' and action = 'count'), 2,
  'two writes, two count history rows (the replay and the refusals added none)');
select is((select before_state is null and (after_state ->> 'guest_count')::int = 2 and changed_by = 'e1200001-0000-4000-8000-000000000002' and reason = 'counted at the door' and idempotency_key = 'k1'
  from public.stay_staying_history where property_id = 'e1200001-0000-4000-8000-0000000000b0' and stay_uid = 'zz-s120gc-cur' and idempotency_key = 'k1'), true,
  'the first history row has no before, the after, the actor, the reason and the key');
-- a key belongs to one write: names first, then a count with the same key
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200001-0000-4000-8000-000000000002"}';
select is((select public.set_stay_staying_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-nxt', 'Ana', 'admin', 0, null, 'kk')),
  '{"ok": true, "replay": false, "version": 1, "names": "Ana", "source": "admin"}'::jsonb, 'admin: names on the next stay (the s119 write is unchanged)');
select throws_ok($$select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-nxt', 2, 1, null, 'kk')$$,
  '22023', 'idempotency_key_reused', 'a key first used for names cannot be replayed as a count');
reset role;

-- 28-33. a count with no names, and names and count side by side ------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200001-0000-4000-8000-000000000002"}';
select is((select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-far', 1, 0, null, 'k4')),
  '{"ok": true, "guest_count": 1, "version": 1}'::jsonb, 'admin: a count on a stay nobody typed names for');
select is((select public.set_stay_guest_count_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-nxt', 2, 1, null, 'k5')),
  '{"ok": true, "guest_count": 2, "version": 2}'::jsonb, 'admin: a count on a stay that already has names');
select is((select public.set_stay_staying_v1('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur', 'Ana and Ben', 'admin', 2, null, 'k6') ->> 'version'), '3',
  'admin: typing names on a stay that holds a count moves the version');
reset role;
select is((select names is null and source is null and guest_count = 1 from public.stay_staying where property_id = 'e1200001-0000-4000-8000-0000000000b0' and stay_uid = 'zz-s120gc-far'), true,
  'a row with a count and no names is valid (names null iff source null still holds)');
select is((select names = 'Ana' and source = 'admin' and guest_count = 2 from public.stay_staying where property_id = 'e1200001-0000-4000-8000-0000000000b0' and stay_uid = 'zz-s120gc-nxt'), true,
  'the count did not touch the names');
select is((select names = 'Ana and Ben' and guest_count = 3 from public.stay_staying where property_id = 'e1200001-0000-4000-8000-0000000000b0' and stay_uid = 'zz-s120gc-cur'), true,
  'typing names did not touch the count');

-- 34-36. the table refuses a count outside 1..3 and an unknown history action --------------------------------------------------------------------------
select throws_ok($$insert into public.stay_staying(property_id, stay_uid, guest_count) values ('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-chk4', 4)$$, '23514', null, 'the table refuses a count of 4');
select throws_ok($$insert into public.stay_staying(property_id, stay_uid, guest_count) values ('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-chk0', 0)$$, '23514', null, 'the table refuses a count of 0');
select throws_ok($$insert into public.stay_staying_history(property_id, stay_uid, action) values ('e1200001-0000-4000-8000-0000000000b0', 'zz-s120gc-cur', 'bogus')$$, '23514', null, 'the history refuses an unknown action');

-- 37-40. staff_home_v1: the new keys, display data, no extra personal data -------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200001-0000-4000-8000-000000000001"}';
select is((select public.staff_home_v1('e1200001-0000-4000-8000-0000000000b0') -> 'current_guest' -> 'staying'),
  '{"names": "Ana and Ben", "source": "admin", "version": 3, "suggestion": null, "guest_count": 3, "booked_guests": 2}'::jsonb,
  'cleaner: current_guest.staying carries the correction (3), the booked number (2) and the version');
select is((select array_agg(k order by k) from jsonb_object_keys(public.staff_home_v1('e1200001-0000-4000-8000-0000000000b0') -> 'current_guest' -> 'staying') k),
  array['booked_guests', 'guest_count', 'names', 'source', 'suggestion', 'version'], 'cleaner: the staying object holds exactly those six keys, two more than before and both are counts');
select ok((select jsonb_typeof(h -> 'current_guest' -> 'staying' -> 'guest_count') = 'number' and jsonb_typeof(h -> 'current_guest' -> 'staying' -> 'booked_guests') = 'number'
            and jsonb_typeof(h -> 'next_guest' -> 'staying' -> 'booked_guests') = 'number'
       from (select public.staff_home_v1('e1200001-0000-4000-8000-0000000000b0') h) q), 'cleaner: the two new keys are plain numbers');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200001-0000-4000-8000-000000000003"}';
select is((select public.staff_home_v1('e1200001-0000-4000-8000-0000000000b0') -> 'next_guest' -> 'staying'),
  '{"names": "Ana", "source": "admin", "version": 2, "guest_count": 2, "booked_guests": 3}'::jsonb, 'finance: next_guest.staying has the new keys and still no suggestion key');
reset role;
-- a stay with no row and a reservation of unknown size: both keys present, both null
update public.calendar_events set checkin_date = (now() at time zone 'Asia/Manila')::date - 1, checkout_date = (now() at time zone 'Asia/Manila')::date + 2
  where property_id = 'e1200001-0000-4000-8000-0000000000b0' and uid = 'zz-s120gc-bare';
update public.calendar_events set checkin_date = (now() at time zone 'Asia/Manila')::date - 20, checkout_date = (now() at time zone 'Asia/Manila')::date - 18
  where property_id = 'e1200001-0000-4000-8000-0000000000b0' and uid = 'zz-s120gc-cur';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200001-0000-4000-8000-000000000001"}';
select is((select public.staff_home_v1('e1200001-0000-4000-8000-0000000000b0') -> 'current_guest' -> 'staying'),
  '{"names": null, "source": null, "version": 0, "suggestion": null, "guest_count": null, "booked_guests": null}'::jsonb,
  'cleaner: a stay with no row and no booked number reads version 0 and two null counts');
reset role;
-- cur is now a past stay (20 to 18 days ago) so the next_guest and a current guest are re-read below; put cur back so the staff_guest_stay_v1 cases start from the same layout
update public.calendar_events set checkin_date = (now() at time zone 'Asia/Manila')::date - 1, checkout_date = (now() at time zone 'Asia/Manila')::date + 2
  where property_id = 'e1200001-0000-4000-8000-0000000000b0' and uid = 'zz-s120gc-cur';
update public.calendar_events set checkin_date = (now() at time zone 'Asia/Manila')::date + 20, checkout_date = (now() at time zone 'Asia/Manila')::date + 22
  where property_id = 'e1200001-0000-4000-8000-0000000000b0' and uid = 'zz-s120gc-bare';

-- 41-49. staff_guest_stay_v1: current, then next, never a past stay, null when none, version 0 without a row ------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200001-0000-4000-8000-000000000002"}';
select is((select public.staff_guest_stay_v1('e1200001-0000-4000-8000-0000000000b0', 'e1200001-0000-4000-8000-0000000000c1')),
  jsonb_build_object('uid', 'zz-s120gc-cur', 'checkin_date', (now() at time zone 'Asia/Manila')::date - 1, 'checkout_date', (now() at time zone 'Asia/Manila')::date + 2,
                     'booked_guests', 2, 'guest_count', 3, 'version', 3),
  'the guest in the house now: the current stay, with the booked number, the correction and the version');
reset role;
update public.calendar_events set checkout_date = (now() at time zone 'Asia/Manila')::date, checkin_date = (now() at time zone 'Asia/Manila')::date - 3
  where property_id = 'e1200001-0000-4000-8000-0000000000b0' and uid = 'zz-s120gc-cur';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200001-0000-4000-8000-000000000002"}';
select is((select public.staff_guest_stay_v1('e1200001-0000-4000-8000-0000000000b0', 'e1200001-0000-4000-8000-0000000000c1')),
  jsonb_build_object('uid', 'zz-s120gc-nxt', 'checkin_date', (now() at time zone 'Asia/Manila')::date + 3, 'checkout_date', (now() at time zone 'Asia/Manila')::date + 5,
                     'booked_guests', 3, 'guest_count', 2, 'version', 2),
  'once the current stay has checked out the next stay is returned');
select is((select public.staff_guest_stay_v1('e1200001-0000-4000-8000-0000000000b0', 'e1200001-0000-4000-8000-0000000000c2')), null::jsonb, 'a guest with only a past stay gets null: past stays are never returned');
select is((select public.staff_guest_stay_v1('e1200001-0000-4000-8000-0000000000b0', 'e1200001-0000-4000-8000-0000000000c3')), null::jsonb, 'a guest with no stay at all gets null');
select is((select public.staff_guest_stay_v1('e1200001-0000-4000-8000-0000000000b0', null)), null::jsonb, 'a null guest gets null');
select is((select public.staff_guest_stay_v1('e1200001-0000-4000-8000-0000000000b0', 'e1200001-0000-4000-8000-0000000000c4')),
  jsonb_build_object('uid', 'zz-s120gc-bare', 'checkin_date', (now() at time zone 'Asia/Manila')::date + 20, 'checkout_date', (now() at time zone 'Asia/Manila')::date + 22,
                     'booked_guests', null, 'guest_count', null, 'version', 0),
  'a stay with no stay_staying row and no booked number: nulls and version 0');
select throws_ok($$select public.staff_guest_stay_v1('e1200001-0000-4000-8000-0000000000b1', 'e1200001-0000-4000-8000-0000000000c1')$$, '42501', 'forbidden', 'an admin of property A cannot read a guest stay of property B');
reset role;
-- the guest of a stay is resolved the way staff_home_v1 does (staff_stay_guest_id_v1). Fixtures: a guest of property B with a linked reservation and stay in B (c5), and a guest of property A (c6)
-- whose reservation matches the dates of the unlinked stay zz-s120gc-far (the date fallback, unique match)
insert into public.guests(id, property_id, name) values
  ('e1200001-0000-4000-8000-0000000000c5', 'e1200001-0000-4000-8000-0000000000b1', 'Zz S120 Guest Five'),
  ('e1200001-0000-4000-8000-0000000000c6', 'e1200001-0000-4000-8000-0000000000b0', 'Zz S120 Guest Six');
insert into public.airbnb_reservations(id, property_id, confirmation_code, source, status, guest_id, guest_name, guest_count, checkin_date, checkout_date) values
  ('e1200001-0000-4000-8000-0000000000d5', 'e1200001-0000-4000-8000-0000000000b1', 'ZZS120GC5', 'airbnb', 'confirmed', 'e1200001-0000-4000-8000-0000000000c5', 'Zz S120 Guest Five',
     2, (now() at time zone 'Asia/Manila')::date + 3, (now() at time zone 'Asia/Manila')::date + 5),
  ('e1200001-0000-4000-8000-0000000000d6', 'e1200001-0000-4000-8000-0000000000b0', 'ZZS120GC6', 'airbnb', 'confirmed', 'e1200001-0000-4000-8000-0000000000c6', 'Zz S120 Guest Six',
     2, (now() at time zone 'Asia/Manila')::date + 9, (now() at time zone 'Asia/Manila')::date + 11);
update public.calendar_events set linked_reservation_id = 'e1200001-0000-4000-8000-0000000000d5' where property_id = 'e1200001-0000-4000-8000-0000000000b1' and uid = 'zz-s120gc-other';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200001-0000-4000-8000-000000000002"}';
select is((select public.staff_guest_stay_v1('e1200001-0000-4000-8000-0000000000b0', 'e1200001-0000-4000-8000-0000000000c5')), null::jsonb,
  'a guest of property B (with a stay there) asked for in property A returns null: no stay of B is ever returned');
select is((select public.staff_guest_stay_v1('e1200001-0000-4000-8000-0000000000b0', 'e1200001-0000-4000-8000-0000000000c6')),
  jsonb_build_object('uid', 'zz-s120gc-far', 'checkin_date', (now() at time zone 'Asia/Manila')::date + 9, 'checkout_date', (now() at time zone 'Asia/Manila')::date + 11,
                     'booked_guests', null, 'guest_count', 1, 'version', 1),
  'date fallback: an unlinked stay whose dates match exactly one reservation resolves to that reservation''s guest (booked number stays null: it is read through the link)');
reset role;
select is((select count(*)::int from public.stay_staying where property_id = 'e1200001-0000-4000-8000-0000000000b1'), 0, 'nothing was written in property B');

-- 50-52. the re-cut body -------------------------------------------------------------------------------------------------------------------------------
select is((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.staff_home_v1(uuid)'::regprocedure), 'd9303dae42b567632024bba98c0df34e', 'staff_home_v1 is the s120 guest-count body');
select ok((select prosecdef and provolatile = 's' and proconfig = array['search_path=""'] from pg_proc where oid = 'public.staff_home_v1(uuid)'::regprocedure), 'staff_home_v1 is still stable, security definer, empty search_path');
select is((select (length(prosrc) - length(replace(prosrc, 'stay_guest_count_json_v1', ''))) / length('stay_guest_count_json_v1') from pg_proc where oid = 'public.staff_home_v1(uuid)'::regprocedure), 2,
  'the helper is called exactly twice in staff_home_v1 (current and next)');

select * from finish();
rollback;
