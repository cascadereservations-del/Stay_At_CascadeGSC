-- Session 67: release stay_chains_20261002 (D-290). A same-guest chain (one stay ends the day the next begins, same guest) is one stay:
-- no turnover to verify, no missed cleaning, no checkout or after-departure message on the first booking, the booking check shows the
-- final checkout. A real turnover (different guests) is never a chain. Synthetic fixtures only; they go with the closing rollback.
-- Dates are offsets from current_date. Property P is private to this suite, so the restored production rows never interfere.
--   -13..-9   chain A   two Airbnb reservations, same guest_id (the HMYDBYKYPC / HM3EXQ5Z8D shape), junction -11
--   -8..-4    pair B    two Airbnb reservations, DIFFERENT guest_ids, identical names: a turnover, guest_id decides
--   +20..+24  direct    two direct inquiries, same guest_id, different event names, junction +22
--   +30..+34  last-4    two Airbnb events, no links, different names, same "Phone Number (Last 4 Digits)", junction +32
--   +40..+44  last-4    same shape, different last-4: a turnover
--   +50..+54  name      same real name, one lower-cased with a trailing space, no ids, junction +52
--   +60..+64  name      both "Reserved": a placeholder is not a name
--   +70..+74  blocked   second row is a block;  +80..+84 second row cancelled;  +90..+94 first row cancelled
begin;
select plan(57);

create function pg_temp.at(n int, hm text) returns timestamptz language sql stable as
$$ select ((current_date + n) + hm::time) at time zone 'Asia/Manila' $$;
create function pg_temp.due(id uuid, k text, t timestamptz) returns boolean language sql as
$$ select exists (select 1 from public.due_guest_messages_v1(t) d where d.booking_id = id and d.message_key = k) $$;
create function pg_temp.cont(n int) returns boolean language sql as
$$ select public.stay_continues_v1('e1000000-0000-4000-8000-000000000067', current_date + n) $$;

insert into public.properties(id, name, is_active) values ('e1000000-0000-4000-8000-000000000067', 'Synthetic Stay Chains 67', true);
insert into public.guests(id, property_id, name) values
  ('e6700000-0000-4000-8000-0000000000a1', 'e1000000-0000-4000-8000-000000000067', 'Synthetic Alpha'),
  ('e6700000-0000-4000-8000-0000000000a2', 'e1000000-0000-4000-8000-000000000067', 'Synthetic Twin'),
  ('e6700000-0000-4000-8000-0000000000a3', 'e1000000-0000-4000-8000-000000000067', 'Synthetic Twin'),
  ('e6700000-0000-4000-8000-0000000000a4', 'e1000000-0000-4000-8000-000000000067', 'Synthetic Dee'),
  ('e6700000-0000-4000-8000-0000000000a5', 'e1000000-0000-4000-8000-000000000067', 'Synthetic Eve'),
  ('e6700000-0000-4000-8000-0000000000a6', 'e1000000-0000-4000-8000-000000000067', 'Synthetic Fay'),
  ('e6700000-0000-4000-8000-0000000000a7', 'e1000000-0000-4000-8000-000000000067', 'Synthetic Gus');

insert into public.airbnb_reservations(id, property_id, confirmation_code, status, guest_id, guest_name, checkin_date, checkout_date) values
  ('e6700000-0000-4000-8000-0000000000b1', 'e1000000-0000-4000-8000-000000000067', 'HMSYNTH671', 'completed', 'e6700000-0000-4000-8000-0000000000a1', 'Synthetic Alpha', current_date - 13, current_date - 11),
  ('e6700000-0000-4000-8000-0000000000b2', 'e1000000-0000-4000-8000-000000000067', 'HMSYNTH672', 'completed', 'e6700000-0000-4000-8000-0000000000a1', 'Synthetic Alpha', current_date - 11, current_date - 9),
  ('e6700000-0000-4000-8000-0000000000b3', 'e1000000-0000-4000-8000-000000000067', 'HMSYNTH673', 'completed', 'e6700000-0000-4000-8000-0000000000a2', 'Synthetic Twin',  current_date - 8,  current_date - 6),
  ('e6700000-0000-4000-8000-0000000000b4', 'e1000000-0000-4000-8000-000000000067', 'HMSYNTH674', 'completed', 'e6700000-0000-4000-8000-0000000000a3', 'Synthetic Twin',  current_date - 6,  current_date - 4);

insert into public.booking_inquiries(id, property_id, guest_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, status, source, submitted_at, total_amount, deposit_amount) values
  ('c0de1111-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000067', 'e6700000-0000-4000-8000-0000000000a4', 'Synthetic Dee', 'dee1@example.com', '09170000671', current_date + 20, current_date + 22, 'confirmed', 'direct', now() - interval '5 days', 3560, 1780),
  ('c0de2222-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000067', 'e6700000-0000-4000-8000-0000000000a4', 'Synthetic Dee', 'dee2@example.com', '09170000671', current_date + 22, current_date + 24, 'confirmed', 'direct', now() - interval '1 day',  3560, 1780),
  ('c0de3333-0000-4000-8000-000000000003', 'e1000000-0000-4000-8000-000000000067', 'e6700000-0000-4000-8000-0000000000a5', 'Synthetic Eve', 'eve@example.com',  '09170000672', current_date + 30, current_date + 32, 'confirmed', 'direct', now() - interval '5 days', 3560, 1780),
  ('c0de4444-0000-4000-8000-000000000004', 'e1000000-0000-4000-8000-000000000067', 'e6700000-0000-4000-8000-0000000000a6', 'Synthetic Fay', 'fay@example.com',  '09170000673', current_date + 32, current_date + 34, 'confirmed', 'direct', now() - interval '1 day',  3560, 1780),
  ('c0de5555-0000-4000-8000-000000000005', 'e1000000-0000-4000-8000-000000000067', 'e6700000-0000-4000-8000-0000000000a7', 'Synthetic Gus', 'gus1@example.com', '09170000674', current_date + 40, current_date + 42, 'confirmed', 'direct', now(),                    3560, 1780),
  ('c0de6666-0000-4000-8000-000000000006', 'e1000000-0000-4000-8000-000000000067', 'e6700000-0000-4000-8000-0000000000a7', 'Synthetic Gus', 'gus2@example.com', '09170000674', current_date + 42, current_date + 44, 'confirmed', 'direct', now() - interval '3 days', 3560, 1780);

insert into public.calendar_events(id, property_id, uid, source, status, checkin_date, checkout_date, guest_name, guest_phone, raw_description, linked_reservation_id) values
  ('e6700000-0000-4000-8000-0000000000c1', 'e1000000-0000-4000-8000-000000000067', 'synth-67-a1@airbnb.com', 'airbnb', 'confirmed', current_date - 13, current_date - 11, 'Synthetic Alpha', null, null, 'e6700000-0000-4000-8000-0000000000b1'),
  ('e6700000-0000-4000-8000-0000000000c2', 'e1000000-0000-4000-8000-000000000067', 'synth-67-a2@airbnb.com', 'airbnb', 'confirmed', current_date - 11, current_date - 9, 'Synthetic Alpha', null, null, 'e6700000-0000-4000-8000-0000000000b2'),
  ('e6700000-0000-4000-8000-0000000000c3', 'e1000000-0000-4000-8000-000000000067', 'synth-67-b1@airbnb.com', 'airbnb', 'confirmed', current_date - 8,  current_date - 6, 'Synthetic Twin',  null, null, 'e6700000-0000-4000-8000-0000000000b3'),
  ('e6700000-0000-4000-8000-0000000000c4', 'e1000000-0000-4000-8000-000000000067', 'synth-67-b2@airbnb.com', 'airbnb', 'confirmed', current_date - 6,  current_date - 4, 'Synthetic Twin',  null, null, 'e6700000-0000-4000-8000-0000000000b4'),
  ('e6700000-0000-4000-8000-0000000000d1', 'e1000000-0000-4000-8000-000000000067', 'direct:c0de1111-0000-4000-8000-000000000001', 'direct', 'confirmed', current_date + 20, current_date + 22, 'Synthetic Dee',  '09170000671', null, null),
  ('e6700000-0000-4000-8000-0000000000d2', 'e1000000-0000-4000-8000-000000000067', 'direct:c0de2222-0000-4000-8000-000000000002', 'direct', 'confirmed', current_date + 22, current_date + 24, 'Synthetic D.',   '09170000671', null, null),
  ('e6700000-0000-4000-8000-0000000000e1', 'e1000000-0000-4000-8000-000000000067', 'synth-67-l4a@airbnb.com', 'airbnb', 'confirmed', current_date + 30, current_date + 32, 'Synthetic Lee', null, E'Reservation URL: x\nPhone Number (Last 4 Digits): 4242', null),
  ('e6700000-0000-4000-8000-0000000000e2', 'e1000000-0000-4000-8000-000000000067', 'synth-67-l4b@airbnb.com', 'airbnb', 'confirmed', current_date + 32, current_date + 34, 'Synthetic Mar', null, E'Reservation URL: y\nPhone Number (Last 4 Digits): 4242', null),
  ('e6700000-0000-4000-8000-0000000000e3', 'e1000000-0000-4000-8000-000000000067', 'synth-67-l4c@airbnb.com', 'airbnb', 'confirmed', current_date + 40, current_date + 42, 'Synthetic Ned', null, E'Phone Number (Last 4 Digits): 1111', null),
  ('e6700000-0000-4000-8000-0000000000e4', 'e1000000-0000-4000-8000-000000000067', 'synth-67-l4d@airbnb.com', 'airbnb', 'confirmed', current_date + 42, current_date + 44, 'Synthetic Oma', null, E'Phone Number (Last 4 Digits): 2222', null),
  ('e6700000-0000-4000-8000-0000000000f1', 'e1000000-0000-4000-8000-000000000067', 'synth-67-n1@airbnb.com', 'airbnb', 'confirmed', current_date + 50, current_date + 52, 'Synthetic Pip',   null, null, null),
  ('e6700000-0000-4000-8000-0000000000f2', 'e1000000-0000-4000-8000-000000000067', 'synth-67-n2@airbnb.com', 'airbnb', 'confirmed', current_date + 52, current_date + 54, ' synthetic pip ', null, null, null),
  ('e6700000-0000-4000-8000-000000000101', 'e1000000-0000-4000-8000-000000000067', 'synth-67-p1@airbnb.com', 'airbnb', 'confirmed', current_date + 60, current_date + 62, 'Reserved', null, null, null),
  ('e6700000-0000-4000-8000-000000000102', 'e1000000-0000-4000-8000-000000000067', 'synth-67-p2@airbnb.com', 'airbnb', 'confirmed', current_date + 62, current_date + 64, 'Reserved', null, null, null),
  ('e6700000-0000-4000-8000-000000000111', 'e1000000-0000-4000-8000-000000000067', 'synth-67-bl1@airbnb.com', 'airbnb', 'confirmed', current_date + 70, current_date + 72, 'Synthetic Quin', null, null, null),
  ('e6700000-0000-4000-8000-000000000112', 'e1000000-0000-4000-8000-000000000067', 'synth-67-bl2@airbnb.com', 'airbnb', 'blocked',   current_date + 72, current_date + 74, 'Synthetic Quin', null, null, null),
  ('e6700000-0000-4000-8000-000000000121', 'e1000000-0000-4000-8000-000000000067', 'synth-67-cx1@airbnb.com', 'airbnb', 'confirmed', current_date + 80, current_date + 82, 'Synthetic Rae', null, null, null),
  ('e6700000-0000-4000-8000-000000000122', 'e1000000-0000-4000-8000-000000000067', 'synth-67-cx2@airbnb.com', 'airbnb', 'cancelled', current_date + 82, current_date + 84, 'Synthetic Rae', null, null, null),
  ('e6700000-0000-4000-8000-000000000131', 'e1000000-0000-4000-8000-000000000067', 'synth-67-cx3@airbnb.com', 'airbnb', 'cancelled', current_date + 90, current_date + 92, 'Synthetic Sol', null, null, null),
  ('e6700000-0000-4000-8000-000000000132', 'e1000000-0000-4000-8000-000000000067', 'synth-67-cx4@airbnb.com', 'airbnb', 'confirmed', current_date + 92, current_date + 94, 'Synthetic Sol', null, null, null);

-- 1-5 stay_continues_v1: what is a chain
select ok(pg_temp.cont(-11), 'airbnb to airbnb, same guest_id: the checkout is a continuation');
select ok(not pg_temp.cont(-9), 'the end of the chain is a real checkout');
select ok(not pg_temp.cont(-6), 'two guests with the same name but different guest_ids: a turnover, guest_id decides');
select ok(pg_temp.cont(22), 'direct to direct, same guest_id (the event names differ): a continuation');
select ok(not pg_temp.cont(24), 'the end of the direct chain is a real checkout');
-- 6-11 fallbacks
select ok(pg_temp.cont(32), 'no ids, the same phone last-4 on both Airbnb rows: a continuation');
select ok(not pg_temp.cont(42), 'no ids, different last-4 and different names: a turnover');
select ok(pg_temp.cont(52), 'no ids, the same real name (case and spaces ignored): a continuation');
select ok(not pg_temp.cont(62), 'both rows "Reserved": a placeholder is not a name, a turnover');
select ok(not pg_temp.cont(72), 'a block on the junction is not a stay');
select ok(not pg_temp.cont(82) and not pg_temp.cont(92), 'a cancelled row on either side is not a stay');
-- 12 pair function
select ok(public.stay_same_guest_v1('e6700000-0000-4000-8000-0000000000c1', 'e6700000-0000-4000-8000-0000000000c2')
      and not public.stay_same_guest_v1('e6700000-0000-4000-8000-0000000000c3', 'e6700000-0000-4000-8000-0000000000c4')
      and not public.stay_same_guest_v1('e6700000-0000-4000-8000-0000000000c1', gen_random_uuid()), 'stay_same_guest_v1: same guest true, different false, unknown row false');

-- 13-15 stay_chains_v1
select is((select array_agg(junction_date order by junction_date) from public.stay_chains_v1('e1000000-0000-4000-8000-000000000067', current_date - 14, current_date + 100)),
  array[current_date - 11, current_date + 22, current_date + 32, current_date + 52], 'stay_chains_v1: exactly the four same-guest junctions, no turnover, block or cancelled row');
select is((select array_agg(junction_date) from public.stay_chains_v1('e1000000-0000-4000-8000-000000000067', current_date + 30, current_date + 40)),
  array[current_date + 32], 'stay_chains_v1: the range limits the junctions');
select is((select row(guest_id, first_uid, first_source, first_code, first_checkin, next_uid, next_code, next_checkout)::text
             from public.stay_chains_v1('e1000000-0000-4000-8000-000000000067', current_date - 14, current_date - 1)),
  row('e6700000-0000-4000-8000-0000000000a1'::uuid, 'synth-67-a1@airbnb.com', 'airbnb', 'HMSYNTH671', current_date - 13, 'synth-67-a2@airbnb.com', 'HMSYNTH672', current_date - 9)::text,
  'stay_chains_v1: guest, both uids, both Airbnb confirmation codes, first check-in and final checkout');
select is((select row(first_code, first_source, next_code)::text from public.stay_chains_v1('e1000000-0000-4000-8000-000000000067', current_date + 22, current_date + 22)),
  row('c0de1111', 'direct', 'c0de2222')::text, 'stay_chains_v1: a direct stay is coded by the first 8 characters of its inquiry id');

-- 17-19 verify_turnover
select is(public.verify_turnover(current_date - 11, 'e1000000-0000-4000-8000-000000000067'),
  jsonb_build_object('check_passed', true, 'session_id', null, 'cleaner_name', null, 'total_photo_count', null, 'is_complete', null,
                     'incomplete_reasons', null, 'issues', array['no_checkout_scheduled', 'stay_continues']),
  'verify_turnover: a continued checkout passes with no_checkout_scheduled + stay_continues (turnover-verifier stays silent)');
select is(public.verify_turnover(current_date - 9, 'e1000000-0000-4000-8000-000000000067') -> 'issues', '["no_session_found"]'::jsonb,
  'verify_turnover: the end of the chain with no cleaning session still fails no_session_found');
select is(public.verify_turnover(current_date - 6, 'e1000000-0000-4000-8000-000000000067') -> 'issues', '["no_session_found"]'::jsonb,
  'verify_turnover: a real turnover (different guests) still fails no_session_found');
select is(public.verify_turnover(current_date - 1, 'e1000000-0000-4000-8000-000000000067') -> 'issues', '["no_checkout_scheduled"]'::jsonb,
  'verify_turnover: a day with no checkout is unchanged');

-- 21-23 get_missed_cleanings
select is((select array_agg(checkout_date order by checkout_date desc) from public.get_missed_cleanings('e1000000-0000-4000-8000-000000000067', 14)),
  array[current_date - 4, current_date - 6, current_date - 9], 'get_missed_cleanings: the continued checkout is not missing; the chain end and both turnover checkouts are');
select ok(not exists (select 1 from public.get_missed_cleanings('e1000000-0000-4000-8000-000000000067', 14) where checkout_date = current_date - 11),
  'get_missed_cleanings: nothing is reported for the continued checkout');
select is((select days_overdue from public.get_missed_cleanings('e1000000-0000-4000-8000-000000000067', 14) where checkout_date = current_date - 9), 9,
  'get_missed_cleanings: days_overdue is unchanged');

-- 24-31 due_guest_messages_v1 (direct chain c0de1111 -> c0de2222; control c0de3333 -> c0de4444, two guests; reversed c0de5555 -> c0de6666)
select ok(not pg_temp.due('c0de1111-0000-4000-8000-000000000001', 'checkout_reminder', pg_temp.at(22, '10:00'))
      and not pg_temp.due('c0de1111-0000-4000-8000-000000000001', 'after_departure', pg_temp.at(22, '17:00')),
  'direct chain: the first booking gets no checkout_reminder and no after_departure');
select ok(pg_temp.due('c0de2222-0000-4000-8000-000000000002', 'checkout_reminder', pg_temp.at(24, '10:00'))
      and pg_temp.due('c0de2222-0000-4000-8000-000000000002', 'after_departure', pg_temp.at(24, '17:00')),
  'direct chain: the continuation still gets both at the real checkout');
select ok(pg_temp.due('c0de1111-0000-4000-8000-000000000001', 'confirmation', now())
      and pg_temp.due('c0de1111-0000-4000-8000-000000000001', 'pre_arrival', pg_temp.at(18, '16:00')),
  'direct chain: the first booking keeps its confirmation and pre_arrival');
select ok(not pg_temp.due('c0de2222-0000-4000-8000-000000000002', 'confirmation', now())
      and not pg_temp.due('c0de2222-0000-4000-8000-000000000002', 'pre_arrival', pg_temp.at(20, '16:00')),
  'direct chain: the continuation, made after the first, gets no confirmation and no pre_arrival');
select ok(pg_temp.due('c0de3333-0000-4000-8000-000000000003', 'checkout_reminder', pg_temp.at(32, '10:00'))
      and pg_temp.due('c0de4444-0000-4000-8000-000000000004', 'confirmation', now())
      and pg_temp.due('c0de4444-0000-4000-8000-000000000004', 'pre_arrival', pg_temp.at(30, '16:00')),
  'a true turnover (two guests, same day) is untouched: reminder, confirmation and pre_arrival all due');
select ok(not pg_temp.due('c0de5555-0000-4000-8000-000000000005', 'checkout_reminder', pg_temp.at(42, '10:00'))
      and pg_temp.due('c0de6666-0000-4000-8000-000000000006', 'confirmation', now()),
  'a continuation made BEFORE the earlier booking keeps its confirmation; the first still skips its checkout reminder');
select is((select count(*)::int from public.due_guest_messages_v1(pg_temp.at(22, '10:00')) where booking_id in ('c0de1111-0000-4000-8000-000000000001', 'c0de2222-0000-4000-8000-000000000002')), 0,
  'direct chain: nothing at all is due for the pair on the junction morning');

-- 32-38 verify_booking
select is((select (public.verify_booking(current_date + 20, null, 'e1000000-0000-4000-8000-000000000067') ->> 'checkout_date')::date), current_date + 24,
  'verify_booking: a chain reports the final checkout date');
select is((select (public.verify_booking(current_date + 20, null, 'e1000000-0000-4000-8000-000000000067') ->> 'nights')::int), 4, 'verify_booking: and the summed nights');
select ok(public.verify_booking(current_date + 20, 's', 'e1000000-0000-4000-8000-000000000067') @> jsonb_build_object('match', true, 'full_name', 'Synthetic Dee')
      and (public.verify_booking(current_date + 20, 's', 'e1000000-0000-4000-8000-000000000067') ->> 'checkout_date')::date = current_date + 24,
  'verify_booking: the initial step still matches and shows the final checkout');
select is((public.verify_booking(current_date + 20, 'z', 'e1000000-0000-4000-8000-000000000067') - 'checkin_date' - 'checkout_date' - 'nights'),
  '{"found": true, "expired": false, "match": false}'::jsonb, 'verify_booking: a wrong initial still returns no name');
select is((select (public.verify_booking(current_date + 30, null, 'e1000000-0000-4000-8000-000000000067') ->> 'checkout_date')::date), current_date + 34,
  'verify_booking: the last-4 chain reports its final checkout too');
select is((select (public.verify_booking(current_date + 70, null, 'e1000000-0000-4000-8000-000000000067') ->> 'checkout_date')::date), current_date + 72,
  'verify_booking: a stay followed by a block is not extended');
select is((select (public.verify_booking(current_date - 8, null, 'e1000000-0000-4000-8000-000000000067') ->> 'checkout_date')::date), current_date - 6,
  'verify_booking: a stay followed by another guest is not extended');
select ok(public.verify_booking(current_date - 13, 's', 'e1000000-0000-4000-8000-000000000067') = jsonb_build_object(
    'found', true, 'expired', true, 'checkin_date', current_date - 13, 'checkout_date', current_date - 9, 'nights', 4),
  'verify_booking: an expired chain expires on its FINAL checkout and returns dates only, no name');
select is(public.verify_booking(current_date + 999, null, 'e1000000-0000-4000-8000-000000000067'), '{"found": false}'::jsonb, 'verify_booking: not found is unchanged');

-- 41-47 grants and security
select ok(has_function_privilege('service_role', 'public.stay_chains_v1(uuid, date, date)', 'execute')
      and not has_function_privilege('authenticated', 'public.stay_chains_v1(uuid, date, date)', 'execute')
      and not has_function_privilege('anon', 'public.stay_chains_v1(uuid, date, date)', 'execute'), 'stay_chains_v1 (guest names, booking codes) is service_role only');
select ok(has_function_privilege('service_role', 'public.stay_continues_v1(uuid, date)', 'execute')
      and has_function_privilege('authenticated', 'public.stay_continues_v1(uuid, date)', 'execute')
      and not has_function_privilege('anon', 'public.stay_continues_v1(uuid, date)', 'execute'), 'stay_continues_v1: service_role and authenticated, never anon');
select ok(has_function_privilege('service_role', 'public.stay_same_guest_v1(uuid, uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.stay_same_guest_v1(uuid, uuid)', 'execute')
      and not has_function_privilege('anon', 'public.stay_same_guest_v1(uuid, uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.stay_uid_inquiry_v1(text)', 'execute')
      and not has_function_privilege('anon', 'public.stay_uid_inquiry_v1(text)', 'execute'), 'the two helpers match: service_role and authenticated, never anon');
select ok(has_function_privilege('service_role', 'public.system_task_close_v1(text, text, text)', 'execute')
      and not has_function_privilege('authenticated', 'public.system_task_close_v1(text, text, text)', 'execute')
      and not has_function_privilege('anon', 'public.system_task_close_v1(text, text, text)', 'execute'), 'system_task_close_v1 is service_role only');
select ok(has_function_privilege('anon', 'public.verify_booking(date, text, uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.verify_turnover(date, uuid)', 'execute')
      and has_function_privilege('service_role', 'public.get_missed_cleanings(uuid, integer)', 'execute')
      and has_function_privilege('service_role', 'public.due_guest_messages_v1(timestamptz)', 'execute'), 'the four changed functions keep their grants (verify_booking stays anon by design, D-228)');
select ok((select prosecdef from pg_proc where oid = 'public.verify_booking(date, text, uuid)'::regprocedure)
      and (select prosecdef from pg_proc where oid = 'public.due_guest_messages_v1(timestamptz)'::regprocedure)
      and not (select prosecdef from pg_proc where oid = 'public.verify_turnover(date, uuid)'::regprocedure)
      and not (select prosecdef from pg_proc where oid = 'public.get_missed_cleanings(uuid, integer)'::regprocedure), 'SECURITY DEFINER / INVOKER is unchanged on all four');
select ok((select bool_and(p.proconfig = array['search_path=""']) from pg_proc p where p.pronamespace = 'public'::regnamespace
            and p.proname in ('verify_turnover', 'get_missed_cleanings', 'verify_booking', 'due_guest_messages_v1', 'stay_uid_inquiry_v1',
                              'stay_same_guest_v1', 'stay_continues_v1', 'stay_chains_v1', 'system_task_close_v1', 'guests_missing_details_v1')), 'every function here pins search_path to empty');

-- 48-52 system_task_close_v1
create temp table t67 as select public.system_task_open_v1('e1000000-0000-4000-8000-000000000067', 'stay_chain', '2030-01-01', 'Synthetic chain task', 'detail', 'normal') id;
insert into public.follow_up_tasks(property_id, purpose, title, status, source_kind, source_ref, idempotency_key)
values ('e1000000-0000-4000-8000-000000000067', 'other', 'A task a person wrote', 'open', 'stay_chain', '2030-01-02', 'manual-task-000000067');
select ok(public.system_task_close_v1('stay_chain', '2030-01-01', 'Closed: the stay continues.'), 'system_task_close_v1 closes the task and says so');
select is((select status || ' / ' || completion_note from public.follow_up_tasks where id = (select id from t67)), 'done / Closed: the stay continues.', 'with the reason written on it');
select ok(not public.system_task_close_v1('stay_chain', '2030-01-01', 'again') and not public.system_task_close_v1('stay_chain', '2030-12-31', 'nothing there'),
  'closing a task that is already done, or that does not exist, returns false');
select is((select status from public.follow_up_tasks where idempotency_key = 'manual-task-000000067'), 'open', 'a task a person wrote (no system key) is never touched');
select throws_ok($$select public.system_task_close_v1('Bad Kind!', 'x', 'n')$$, '22023', null, 'a malformed kind is refused');

-- guests_missing_details_v1 (orchestrator addendum): of the given ids, those with no ID on file and no phone or email anywhere
insert into public.guests(id, property_id, name, phone, email) values
  ('e6700000-0000-4000-8000-000000000191', 'e1000000-0000-4000-8000-000000000067', 'Synthetic Gm1 nothing', null, null),
  ('e6700000-0000-4000-8000-000000000192', 'e1000000-0000-4000-8000-000000000067', 'Synthetic Gm2 phone', '09170000681', null),
  ('e6700000-0000-4000-8000-000000000193', 'e1000000-0000-4000-8000-000000000067', 'Synthetic Gm3 email', null, 'gm3@example.com'),
  ('e6700000-0000-4000-8000-000000000194', 'e1000000-0000-4000-8000-000000000067', 'Synthetic Gm4 profile contact', null, null),
  ('e6700000-0000-4000-8000-000000000195', 'e1000000-0000-4000-8000-000000000067', 'Synthetic Gm5 id on file', null, null),
  ('e6700000-0000-4000-8000-000000000196', 'e1000000-0000-4000-8000-000000000067', 'Synthetic Gm6 blanks', '   ', ' '),
  ('e6700000-0000-4000-8000-000000000197', 'e1000000-0000-4000-8000-000000000067', 'Synthetic Gm7 not asked', null, null);
insert into public.guest_profile_details(guest_id, property_id, contact_number, id_on_file) values
  ('e6700000-0000-4000-8000-000000000194', 'e1000000-0000-4000-8000-000000000067', '09170000682', false),
  ('e6700000-0000-4000-8000-000000000195', 'e1000000-0000-4000-8000-000000000067', null, true),
  ('e6700000-0000-4000-8000-000000000196', 'e1000000-0000-4000-8000-000000000067', '  ', false);
select is((select array_agg(guest_id order by guest_id) from public.guests_missing_details_v1(array[
    'e6700000-0000-4000-8000-000000000191', 'e6700000-0000-4000-8000-000000000192', 'e6700000-0000-4000-8000-000000000193',
    'e6700000-0000-4000-8000-000000000194', 'e6700000-0000-4000-8000-000000000195', 'e6700000-0000-4000-8000-000000000196', gen_random_uuid()]::uuid[])),
  array['e6700000-0000-4000-8000-000000000191', 'e6700000-0000-4000-8000-000000000196']::uuid[],
  'guests_missing_details_v1: only the guest with nothing, and the one with blank phone, email and contact (phone, email, profile contact and ID on file each count)');
select is((select count(*)::int from public.guests_missing_details_v1(array[]::uuid[])), 0, 'guests_missing_details_v1: an empty list gives no rows');
select ok(has_function_privilege('service_role', 'public.guests_missing_details_v1(uuid[])', 'execute')
      and not has_function_privilege('authenticated', 'public.guests_missing_details_v1(uuid[])', 'execute')
      and not has_function_privilege('anon', 'public.guests_missing_details_v1(uuid[])', 'execute')
      and (select prosecdef from pg_proc where oid = 'public.guests_missing_details_v1(uuid[])'::regprocedure), 'guests_missing_details_v1 is a definer function for service_role only');

-- stay_chains_v1 contract for its callers (daily-digest, PostgREST): uids exactly as stored, dates as type date
select is((select array[first_uid, next_uid] from public.stay_chains_v1('e1000000-0000-4000-8000-000000000067', current_date + 22, current_date + 22)),
  array[(select uid from public.calendar_events where id = 'e6700000-0000-4000-8000-0000000000d1'),
        (select uid from public.calendar_events where id = 'e6700000-0000-4000-8000-0000000000d2')],
  'stay_chains_v1: first_uid and next_uid equal calendar_events.uid exactly (direct rows keep direct:<id>)');
select is(pg_get_function_result('public.stay_chains_v1(uuid, date, date)'::regprocedure),
  'TABLE(junction_date date, guest_id uuid, guest_name text, first_uid text, first_source text, first_code text, first_checkin date, next_uid text, next_code text, next_checkout date)',
  'stay_chains_v1: the date columns are type date and the rest are as documented');
select is((select to_jsonb(x) ->> 'junction_date' || ' ' || (to_jsonb(x) ->> 'first_checkin') || ' ' || (to_jsonb(x) ->> 'next_checkout')
             from public.stay_chains_v1('e1000000-0000-4000-8000-000000000067', current_date + 22, current_date + 22) x),
  (current_date + 22)::text || ' ' || (current_date + 20)::text || ' ' || (current_date + 24)::text,
  'stay_chains_v1: dates serialise as YYYY-MM-DD');

select * from finish();
rollback;
