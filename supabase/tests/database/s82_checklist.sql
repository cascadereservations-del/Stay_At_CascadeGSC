-- Session 82 (lane K): release s82_checklist_20261015. get_cleanable_bookings and get_booking_for_date offer a calendar block only when it
-- was scheduled (staff-answered maintenance, or a live maintenance / deep_clean day flag on the date) and only for a date it covers;
-- guest stays are unchanged. Cleaner, owner/admin, anon and a non-staff user are exercised.
-- Time: now() is the transaction start, so it is frozen for the suite. Every fixture date is relative to the Manila date of now().
-- Synthetic fixtures only (uuids e8200000-...); every lookup is scoped to them because a real backup holds real rows. Everything rolls back.
begin;
select plan(23);

alter role service_role bypassrls;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
grant execute on function public.get_cleanable_bookings(date, uuid, integer, integer), public.get_booking_for_date(date, uuid) to anon, authenticated, service_role;
grant execute on function public.k_calendar_row_offered(uuid, text, text, text, date, date, date) to anon, authenticated, service_role;
grant select on public.calendar_events to anon, authenticated;

insert into public.properties(id, name, is_active) values
  ('e8200000-0000-4000-8000-0000000000a1', 'Synthetic S82 K', true);
insert into auth.users(id) values
  ('e8200000-0000-4000-8000-0000000000e1'), ('e8200000-0000-4000-8000-0000000000e2'), ('e8200000-0000-4000-8000-0000000000e4');
insert into public.staff_access_profiles(user_id, role) values
  ('e8200000-0000-4000-8000-0000000000e1', 'cleaner'),
  ('e8200000-0000-4000-8000-0000000000e2', 'admin');
insert into public.staff_property_access(user_id, property_id) values
  ('e8200000-0000-4000-8000-0000000000e1', 'e8200000-0000-4000-8000-0000000000a1'),
  ('e8200000-0000-4000-8000-0000000000e2', 'e8200000-0000-4000-8000-0000000000a1');
-- e4 has no staff profile.

-- D = the Manila date of now(); F = a later date that carries the day flags
create temp table k_d on commit drop as select (now() at time zone 'Asia/Manila')::date as d;
grant select on k_d to anon, authenticated;

insert into public.calendar_events(id, property_id, uid, source, checkin_date, checkout_date, guest_name, status, block_reason, block_reason_source) values
  -- a past block the system assumed was maintenance: NOT scheduled
  ('e8200000-0000-4000-8000-0000000000b1', 'e8200000-0000-4000-8000-0000000000a1', 'zz-k-1', 'airbnb', (select d - 5 from k_d), (select d - 3 from k_d), null, 'blocked', 'maintenance', 'assumed'),
  -- a block covering today that staff answered as maintenance: scheduled
  ('e8200000-0000-4000-8000-0000000000b2', 'e8200000-0000-4000-8000-0000000000a1', 'zz-k-2', 'airbnb', (select d from k_d), (select d + 1 from k_d), null, 'blocked', 'maintenance', 'staff'),
  -- a guest who checked out three days ago
  ('e8200000-0000-4000-8000-0000000000b3', 'e8200000-0000-4000-8000-0000000000a1', 'zz-k-3', 'airbnb', (select d - 6 from k_d), (select d - 3 from k_d), 'Zz Guest', 'confirmed', null, null),
  -- a past block that staff answered as maintenance: scheduled, but the date has gone (no look-back for blocks)
  ('e8200000-0000-4000-8000-0000000000b4', 'e8200000-0000-4000-8000-0000000000a1', 'zz-k-4', 'airbnb', (select d - 5 from k_d), (select d - 3 from k_d), null, 'blocked', 'maintenance', 'staff'),
  -- a pending direct hold: status blocked, has a name, no reason
  ('e8200000-0000-4000-8000-0000000000b5', 'e8200000-0000-4000-8000-0000000000a1', 'zz-k-5', 'direct', (select d from k_d), (select d + 2 from k_d), 'Zz Hold', 'blocked', null, null),
  -- a brownout block covering F-1 .. F+1, carrying a live deep_clean flag on F only
  ('e8200000-0000-4000-8000-0000000000b6', 'e8200000-0000-4000-8000-0000000000a1', 'zz-k-6', 'airbnb', (select d + 9 from k_d), (select d + 12 from k_d), null, 'blocked', 'brownout', 'auto'),
  -- an assumed block covering G, whose maintenance flag was cleared
  ('e8200000-0000-4000-8000-0000000000b7', 'e8200000-0000-4000-8000-0000000000a1', 'zz-k-7', 'airbnb', (select d + 19 from k_d), (select d + 22 from k_d), null, 'blocked', 'maintenance', 'assumed'),
  -- a cancelled staff block covering today
  ('e8200000-0000-4000-8000-0000000000b8', 'e8200000-0000-4000-8000-0000000000a1', 'zz-k-8', 'airbnb', (select d from k_d), (select d + 1 from k_d), null, 'cancelled', 'maintenance', 'staff'),
  -- a guest arriving today
  ('e8200000-0000-4000-8000-0000000000b9', 'e8200000-0000-4000-8000-0000000000a1', 'zz-k-9', 'airbnb', (select d from k_d), (select d + 3 from k_d), 'Zz Arrival', 'confirmed', null, null);
insert into public.calendar_day_flags(property_id, date, kind, label, cleared_at) values
  ('e8200000-0000-4000-8000-0000000000a1', (select d + 10 from k_d), 'deep_clean', 'Zz deep clean', null),
  ('e8200000-0000-4000-8000-0000000000a1', (select d + 20 from k_d), 'maintenance', 'Zz cleared', now()),
  ('e8200000-0000-4000-8000-0000000000a1', (select d + 30 from k_d), 'brownout', 'Zz brownout flag', null);

-- cleaner: the stay picker --------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e8200000-0000-4000-8000-0000000000e1"}';
select is((select count(*)::int from public.get_cleanable_bookings((select d from k_d), 'e8200000-0000-4000-8000-0000000000a1') where event_id = 'e8200000-0000-4000-8000-0000000000b1'), 0,
  'cleaner: a past block the system only assumed was maintenance is not offered');
select is((select kind from public.get_cleanable_bookings((select d from k_d), 'e8200000-0000-4000-8000-0000000000a1') where event_id = 'e8200000-0000-4000-8000-0000000000b2'), 'block',
  'cleaner: staff-scheduled maintenance covering today is offered, as kind block');
select is((select kind from public.get_cleanable_bookings((select d from k_d), 'e8200000-0000-4000-8000-0000000000a1') where event_id = 'e8200000-0000-4000-8000-0000000000b3'), 'checkout',
  'cleaner: a guest who checked out 3 days ago is still offered (look-back unchanged)');
select is((select count(*)::int from public.get_cleanable_bookings((select d from k_d), 'e8200000-0000-4000-8000-0000000000a1') where event_id = 'e8200000-0000-4000-8000-0000000000b4'), 0,
  'cleaner: even a scheduled block is not offered once its date has gone (no look-back for blocks)');
select is((select kind from public.get_cleanable_bookings((select d from k_d), 'e8200000-0000-4000-8000-0000000000a1') where event_id = 'e8200000-0000-4000-8000-0000000000b9'), 'checkin',
  'cleaner: a guest arriving today is unchanged');
select is((select count(*)::int from public.get_cleanable_bookings((select d from k_d), 'e8200000-0000-4000-8000-0000000000a1') where event_id in ('e8200000-0000-4000-8000-0000000000b5', 'e8200000-0000-4000-8000-0000000000b8')), 0,
  'cleaner: a pending direct hold and a cancelled block are not offered');
select is((select kind from public.get_cleanable_bookings((select d + 10 from k_d), 'e8200000-0000-4000-8000-0000000000a1') where event_id = 'e8200000-0000-4000-8000-0000000000b6'), 'block',
  'cleaner: a deep_clean day flag on the date offers the block that covers it');
select is((select count(*)::int from public.get_cleanable_bookings((select d + 11 from k_d), 'e8200000-0000-4000-8000-0000000000a1') where event_id = 'e8200000-0000-4000-8000-0000000000b6'), 0,
  'cleaner: the next day, with no flag, the same block is not offered');
select is((select count(*)::int from public.get_cleanable_bookings((select d + 20 from k_d), 'e8200000-0000-4000-8000-0000000000a1') where event_id = 'e8200000-0000-4000-8000-0000000000b7'), 0,
  'cleaner: a cleared maintenance flag offers nothing');
select is(public.k_calendar_row_offered('e8200000-0000-4000-8000-0000000000a1', 'blocked', 'other', 'auto', (select d + 29 from k_d), (select d + 31 from k_d), (select d + 30 from k_d)), false,
  'cleaner: a brownout flag is not a maintenance or deep_clean flag');
select is((select count(*)::int from public.get_booking_for_date((select d from k_d), 'e8200000-0000-4000-8000-0000000000a1')), 1,
  'cleaner: get_booking_for_date still answers for today');
reset role;

-- get_booking_for_date --------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e8200000-0000-4000-8000-0000000000e1"}';
select is((select count(*)::int from public.get_booking_for_date((select d - 3 from k_d), 'e8200000-0000-4000-8000-0000000000a1') where event_id = 'e8200000-0000-4000-8000-0000000000b3'), 1,
  'get_booking_for_date: the guest checkout date still returns the stay');
select is((select count(*)::int from public.get_booking_for_date((select d - 3 from k_d), 'e8200000-0000-4000-8000-0000000000a1') where event_id in ('e8200000-0000-4000-8000-0000000000b1', 'e8200000-0000-4000-8000-0000000000b4')), 0,
  'get_booking_for_date: the checkout date of a block returns no block');
select is((select count(*)::int from public.get_booking_for_date((select d + 9 from k_d), 'e8200000-0000-4000-8000-0000000000a1')), 0,
  'get_booking_for_date: the first day of an unscheduled block returns nothing');
select is((select count(*)::int from public.get_booking_for_date((select d + 10 from k_d), 'e8200000-0000-4000-8000-0000000000a1')), 0,
  'get_booking_for_date: a flag date inside a block returns nothing because the lookup keys on check-in or check-out only');
reset role;

-- owner / admin sees the same rule ----------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e8200000-0000-4000-8000-0000000000e2"}';
select is((select count(*)::int from public.get_cleanable_bookings((select d from k_d), 'e8200000-0000-4000-8000-0000000000a1') where event_id = 'e8200000-0000-4000-8000-0000000000b1'), 0,
  'admin: the assumed past block is not offered either');
select is((select count(*)::int from public.get_cleanable_bookings((select d from k_d), 'e8200000-0000-4000-8000-0000000000a1') where event_id = 'e8200000-0000-4000-8000-0000000000b2'), 1,
  'admin: the scheduled block is offered');
reset role;

-- not staff and anon -------------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e8200000-0000-4000-8000-0000000000e4"}';
select throws_ok($$select * from public.get_cleanable_bookings((select d from k_d), 'e8200000-0000-4000-8000-0000000000a1')$$, '42501', null, 'a user with no staff profile is refused');
select is((select count(*)::int from public.get_booking_for_date((select d from k_d), 'e8200000-0000-4000-8000-0000000000a1')), 0, 'a user with no staff profile sees no row through get_booking_for_date');
reset role;
set local role anon;
select is(public.k_calendar_row_offered('e8200000-0000-4000-8000-0000000000a1', 'blocked', 'brownout', 'auto', (select d + 9 from k_d), (select d + 12 from k_d), (select d + 10 from k_d)), false,
  'anon: the predicate cannot be used to learn that a day flag exists');
select lives_ok($$select * from public.get_booking_for_date((select d from k_d), 'e8200000-0000-4000-8000-0000000000a1')$$, 'anon: get_booking_for_date still runs without an error');
reset role;

-- contract ----------------------------------------------------------------------------------------------------------------------------------------
select is(pg_get_function_result('public.get_cleanable_bookings(date,uuid,integer,integer)'::regprocedure),
  'TABLE(event_id uuid, checkin_date date, checkout_date date, nights integer, guest_name text, kind text, already_reported boolean)',
  'get_cleanable_bookings keeps its return columns');
select is(pg_get_function_result('public.get_booking_for_date(date,uuid)'::regprocedure),
  'TABLE(event_id uuid, checkin_date date, checkout_date date, nights integer, guest_name text, source text, status text, match_type text)',
  'get_booking_for_date keeps its return columns');
select * from finish();
rollback;
