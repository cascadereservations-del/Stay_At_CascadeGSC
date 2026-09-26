-- Session 56: release guest_messages_3_6_20260927 (SPEC-05 messages 3-6, D-249). Every boundary of the four new keys.
-- D-249 is pinned as built: a 5- or 6-night stay gets mid_stay on check-in day + 3, a 7+ night stay on day + 4, under 5
-- nights none (SPEC-05's "a 5-night stay gets no mid_stay" and the design's "7 nights" are superseded).
-- Every fixture goes with the closing rollback. `at(n, 'hh:mi')` = Manila wall time on current_date + n.
begin;
select plan(24);

create function pg_temp.at(n int, hm text) returns timestamptz language sql stable as
$$ select ((current_date + n) + hm::time) at time zone 'Asia/Manila' $$;
create function pg_temp.due(id uuid, k text, t timestamptz) returns boolean language sql as
$$ select exists (select 1 from public.due_guest_messages_v1(t) d where d.booking_id = id and d.message_key = k) $$;

insert into public.properties(id, name, is_active) values ('e1000000-0000-4000-8000-000000000056', 'Synthetic Guest Messages 56', true);
insert into public.guests(id, property_id, name) values
  ('e6560000-0000-4000-8000-0000000000a1', 'e1000000-0000-4000-8000-000000000056', 'Synthetic Dina'),
  ('e6560000-0000-4000-8000-0000000000a2', 'e1000000-0000-4000-8000-000000000056', 'Synthetic Noel');
insert into public.guest_profile_details(guest_id, property_id, id_on_file) values
  ('e6560000-0000-4000-8000-0000000000a1', 'e1000000-0000-4000-8000-000000000056', true),
  ('e6560000-0000-4000-8000-0000000000a2', 'e1000000-0000-4000-8000-000000000056', false);

-- F5/F7/F3: 5-, 7- and 3-night stays from day 10.  X: cancelled 5 nights.  O: checks out today (day 0).
-- D1: ID on file, check-in day 3.  D2: no ID, day 3.  D3: ID on file, day 10.
insert into public.booking_inquiries(id, property_id, guest_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, status, source, submitted_at, total_amount, deposit_amount)
values
  ('e6560000-0000-4000-8000-000000000005', 'e1000000-0000-4000-8000-000000000056', null, 'Synthetic Five', 'f5@example.com', '09170000051', current_date + 10, current_date + 15, 'confirmed', 'direct', now(), 8900, 4450),
  ('e6560000-0000-4000-8000-000000000007', 'e1000000-0000-4000-8000-000000000056', null, 'Synthetic Seven', 'f7@example.com', '09170000052', current_date + 10, current_date + 17, 'confirmed', 'direct', now(), 12460, 6230),
  ('e6560000-0000-4000-8000-000000000003', 'e1000000-0000-4000-8000-000000000056', null, 'Synthetic Three', 'f3@example.com', '09170000053', current_date + 10, current_date + 13, 'confirmed', 'direct', now(), 5340, 2670),
  ('e6560000-0000-4000-8000-00000000000c', 'e1000000-0000-4000-8000-000000000056', null, 'Synthetic Xed', 'x@example.com', '09170000054', current_date + 10, current_date + 15, 'cancelled', 'direct', now(), 8900, 4450),
  ('e6560000-0000-4000-8000-00000000000f', 'e1000000-0000-4000-8000-000000000056', null, 'Synthetic Out', 'o@example.com', '09170000055', current_date - 2, current_date, 'confirmed', 'direct', now(), 3560, 1780),
  ('e6560000-0000-4000-8000-0000000000d1', 'e1000000-0000-4000-8000-000000000056', 'e6560000-0000-4000-8000-0000000000a1', 'Synthetic Dina', 'd1@example.com', '09170000056', current_date + 3, current_date + 5, 'confirmed', 'direct', now(), 3560, 1780),
  ('e6560000-0000-4000-8000-0000000000d2', 'e1000000-0000-4000-8000-000000000056', 'e6560000-0000-4000-8000-0000000000a2', 'Synthetic Noel', 'd2@example.com', '09170000057', current_date + 3, current_date + 5, 'confirmed', 'direct', now(), 3560, 1780),
  ('e6560000-0000-4000-8000-0000000000d3', 'e1000000-0000-4000-8000-000000000056', 'e6560000-0000-4000-8000-0000000000a1', 'Synthetic Dina', 'd3@example.com', '09170000058', current_date + 10, current_date + 12, 'confirmed', 'direct', now(), 3560, 1780);

-- mid_stay (D-249)
select ok(not pg_temp.due('e6560000-0000-4000-8000-000000000005', 'mid_stay', pg_temp.at(13, '14:59')), 'mid_stay 5 nights: not before 15:00 on day 3');
select ok(pg_temp.due('e6560000-0000-4000-8000-000000000005', 'mid_stay', pg_temp.at(13, '15:00')), 'mid_stay 5 nights: due 15:00 on day 3');
select ok(not pg_temp.due('e6560000-0000-4000-8000-000000000005', 'mid_stay', pg_temp.at(14, '15:00')), 'mid_stay 5 nights: not on day 4 (check-out within 2 days)');
select ok(pg_temp.due('e6560000-0000-4000-8000-000000000007', 'mid_stay', pg_temp.at(14, '15:00')), 'mid_stay 7 nights: due 15:00 on day 4');
select ok(not pg_temp.due('e6560000-0000-4000-8000-000000000007', 'mid_stay', pg_temp.at(13, '15:00')), 'mid_stay 7 nights: not on day 3');
select ok(pg_temp.due('e6560000-0000-4000-8000-000000000007', 'mid_stay', pg_temp.at(14, '20:59'))
      and not pg_temp.due('e6560000-0000-4000-8000-000000000007', 'mid_stay', pg_temp.at(14, '21:00')), 'mid_stay: a 6-hour window');
select ok(not pg_temp.due('e6560000-0000-4000-8000-000000000003', 'mid_stay', pg_temp.at(13, '15:00'))
      and not pg_temp.due('e6560000-0000-4000-8000-000000000003', 'mid_stay', pg_temp.at(12, '15:00')), 'mid_stay: a 3-night stay gets none');

-- checkout_reminder and after_departure (F3 checks out on day 13)
select ok(not pg_temp.due('e6560000-0000-4000-8000-000000000003', 'checkout_reminder', pg_temp.at(13, '08:59')), 'checkout_reminder: not at 08:59');
select ok(pg_temp.due('e6560000-0000-4000-8000-000000000003', 'checkout_reminder', pg_temp.at(13, '09:00')), 'checkout_reminder: due 09:00 on check-out day');
select ok(not pg_temp.due('e6560000-0000-4000-8000-000000000003', 'checkout_reminder', pg_temp.at(13, '12:00')), 'checkout_reminder: never after the noon check-out');
select ok(not pg_temp.due('e6560000-0000-4000-8000-000000000003', 'after_departure', pg_temp.at(13, '15:59')), 'after_departure: not at 15:59');
select ok(pg_temp.due('e6560000-0000-4000-8000-000000000003', 'after_departure', pg_temp.at(13, '16:00')), 'after_departure: due 16:00 on check-out day');
select ok(not pg_temp.due('e6560000-0000-4000-8000-000000000003', 'after_departure', pg_temp.at(13, '22:00'))
      and not pg_temp.due('e6560000-0000-4000-8000-000000000003', 'after_departure', pg_temp.at(14, '16:00')), 'after_departure: the window closes at 22:00');
select ok(not pg_temp.due('e6560000-0000-4000-8000-00000000000f', 'confirmation', pg_temp.at(0, '10:00'))
      and pg_temp.due('e6560000-0000-4000-8000-00000000000f', 'checkout_reminder', pg_temp.at(0, '10:00')), 'check-out day: the reminder is due, a confirmation is not');

-- cancelled, logged
select ok(not exists (select 1 from public.due_guest_messages_v1(pg_temp.at(13, '15:00')) where booking_id = 'e6560000-0000-4000-8000-00000000000c')
      and not exists (select 1 from public.due_guest_messages_v1(pg_temp.at(15, '09:30')) where booking_id = 'e6560000-0000-4000-8000-00000000000c'), 'a cancelled booking is due nothing');
insert into public.guest_message_log(booking_id, message_key, channel, status) values ('e6560000-0000-4000-8000-000000000007', 'mid_stay', 'email', 'failed');
select ok(not pg_temp.due('e6560000-0000-4000-8000-000000000007', 'mid_stay', pg_temp.at(14, '16:00')), 'a logged key is never due twice, even a failed one');

-- door_code_offer
select ok(pg_temp.due('e6560000-0000-4000-8000-0000000000d1', 'door_code_offer', pg_temp.at(0, '10:00')), 'door_code_offer: ID on file, check-in in 3 days');
select ok(not pg_temp.due('e6560000-0000-4000-8000-0000000000d2', 'door_code_offer', pg_temp.at(0, '10:00')), 'door_code_offer: never without the ID');
select ok(not pg_temp.due('e6560000-0000-4000-8000-0000000000d3', 'door_code_offer', pg_temp.at(0, '10:00'))
      and pg_temp.due('e6560000-0000-4000-8000-0000000000d3', 'door_code_offer', pg_temp.at(3, '10:00')), 'door_code_offer: from 7 days before check-in');
insert into public.guest_message_log(booking_id, message_key, channel, status, detail) values ('e6560000-0000-4000-8000-0000000000d1', 'door_code', 'card_only', 'skipped', 'card offered');
select ok(not pg_temp.due('e6560000-0000-4000-8000-0000000000d1', 'door_code_offer', pg_temp.at(1, '10:00')), 'door_code_offer: once (the door_code row locks it)');

-- messages 1 and 2 unchanged; grants; settings
select ok(pg_temp.due('e6560000-0000-4000-8000-000000000005', 'confirmation', now()), 'confirmation still due for a booking touched now');
select ok(pg_temp.due('e6560000-0000-4000-8000-000000000005', 'pre_arrival', pg_temp.at(8, '15:00')), 'pre_arrival still due on check-in day - 2 at 15:00');
select ok(has_function_privilege('service_role', 'public.due_guest_messages_v1(timestamptz)', 'execute')
      and not has_function_privilege('anon', 'public.due_guest_messages_v1(timestamptz)', 'execute')
      and not has_function_privilege('authenticated', 'public.due_guest_messages_v1(timestamptz)', 'execute'), 'only service_role asks what is due');
select ok((select value #>> '{}' from public.app_settings where key = 'review_airbnb_url') = 'https://airbnb.com/h/cascadesgsc'
      and exists (select 1 from public.app_settings where key = 'review_facebook_url')
      and exists (select 1 from public.app_settings where key = 'review_google_url'), 'the three review links exist');

select * from finish();
rollback;
