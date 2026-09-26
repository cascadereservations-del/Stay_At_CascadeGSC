-- Session 54: release guest_message_log_20260926 (SPEC-05 messages 1 and 2, D-253, D-257).
-- What is due, around every boundary; the log row is the once-only lock. Every fixture goes with the closing rollback.
begin;
select plan(14);

insert into public.properties(id, name, is_active) values ('e1000000-0000-4000-8000-000000000054', 'Synthetic Guest Messages 54', true);

-- A: confirmed just now, far ahead.   P: confirmed long ago (log row 10 days old), check-in in 20 days.
-- L: confirmed 47 h before its 14:00 check-in.   X: cancelled.   O: stay already over, touched just now.
insert into public.booking_inquiries(id, property_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, status, source, submitted_at, total_amount, deposit_amount)
values
  ('ea540000-0000-4000-8000-00000000000a', 'e1000000-0000-4000-8000-000000000054', 'Synthetic Ana', 'ana@example.com', '09170000001', current_date + 30, current_date + 32, 'confirmed', 'direct', now(), 3560, 1780),
  ('ea540000-0000-4000-8000-00000000000b', 'e1000000-0000-4000-8000-000000000054', 'Synthetic Pia', 'pia@example.com', '09170000002', current_date + 20, current_date + 22, 'confirmed', 'direct', now(), 3560, 1780),
  ('ea540000-0000-4000-8000-00000000000c', 'e1000000-0000-4000-8000-000000000054', 'Synthetic Lee', 'lee@example.com', '09170000003', current_date + 40, current_date + 41, 'confirmed', 'direct', now(), 1780, 890),
  ('ea540000-0000-4000-8000-00000000000d', 'e1000000-0000-4000-8000-000000000054', 'Synthetic Xia', 'xia@example.com', '09170000004', current_date + 20, current_date + 22, 'cancelled', 'direct', now(), 3560, 1780),
  ('ea540000-0000-4000-8000-00000000000e', 'e1000000-0000-4000-8000-000000000054', 'Synthetic Old', 'old@example.com', '09170000005', current_date - 3, current_date - 1, 'confirmed', 'direct', now(), 1780, 890);

insert into public.guest_message_log(booking_id, message_key, channel, status, created_at) values
  ('ea540000-0000-4000-8000-00000000000b', 'confirmation', 'email', 'sent', now() - interval '10 days'),
  ('ea540000-0000-4000-8000-00000000000c', 'confirmation', 'messenger', 'sent', ((current_date + 38) + time '15:00') at time zone 'Asia/Manila');

select ok(exists (select 1 from public.due_guest_messages_v1() where booking_id = 'ea540000-0000-4000-8000-00000000000a' and message_key = 'confirmation'),
  'a booking confirmed just now is due its confirmation');
insert into public.guest_message_log(booking_id, message_key, channel, status) values ('ea540000-0000-4000-8000-00000000000a', 'confirmation', 'messenger', 'failed');
select ok(not exists (select 1 from public.due_guest_messages_v1() where booking_id = 'ea540000-0000-4000-8000-00000000000a'),
  'a logged key is never due again, even a failed one');
select throws_ok($$insert into public.guest_message_log(booking_id, message_key, channel, status) values ('ea540000-0000-4000-8000-00000000000a', 'confirmation', 'email', 'sent')$$, '23505', null,
  'a second row for the same booking and key is refused: the lock');

select ok(not exists (select 1 from public.due_guest_messages_v1(((current_date + 18) + time '14:59') at time zone 'Asia/Manila') where booking_id = 'ea540000-0000-4000-8000-00000000000b' and message_key = 'pre_arrival'),
  'pre_arrival: not due at 14:59 Manila on check-in day - 2');
select ok(exists (select 1 from public.due_guest_messages_v1(((current_date + 18) + time '15:00') at time zone 'Asia/Manila') where booking_id = 'ea540000-0000-4000-8000-00000000000b' and message_key = 'pre_arrival'),
  'pre_arrival: due at 15:00');
select ok(exists (select 1 from public.due_guest_messages_v1(((current_date + 18) + time '20:59') at time zone 'Asia/Manila') where booking_id = 'ea540000-0000-4000-8000-00000000000b' and message_key = 'pre_arrival'),
  'pre_arrival: still due at 20:59 (a failed run is caught by the next)');
select ok(not exists (select 1 from public.due_guest_messages_v1(((current_date + 18) + time '21:00') at time zone 'Asia/Manila') where booking_id = 'ea540000-0000-4000-8000-00000000000b' and message_key = 'pre_arrival'),
  'pre_arrival: the window closes at 21:00');
select ok(not exists (select 1 from public.due_guest_messages_v1(((current_date + 18) + time '16:00') at time zone 'Asia/Manila') where booking_id = 'ea540000-0000-4000-8000-00000000000b' and message_key = 'confirmation'),
  'an old booking is never due a confirmation');
select ok(not exists (select 1 from public.due_guest_messages_v1(((current_date + 38) + time '16:00') at time zone 'Asia/Manila') where booking_id = 'ea540000-0000-4000-8000-00000000000c' and message_key = 'pre_arrival'),
  'a booking confirmed 47 h before check-in gets no pre_arrival');
select ok(not exists (select 1 from public.due_guest_messages_v1(((current_date + 18) + time '16:00') at time zone 'Asia/Manila') where booking_id = 'ea540000-0000-4000-8000-00000000000d')
      and not exists (select 1 from public.due_guest_messages_v1() where booking_id = 'ea540000-0000-4000-8000-00000000000d'),
  'a cancelled booking is due nothing');
select ok(not exists (select 1 from public.due_guest_messages_v1() where booking_id = 'ea540000-0000-4000-8000-00000000000e'),
  'a stay that is over is due nothing, however recently it was touched');

select ok(has_function_privilege('service_role', 'public.due_guest_messages_v1(timestamptz)', 'execute')
      and not has_function_privilege('anon', 'public.due_guest_messages_v1(timestamptz)', 'execute')
      and not has_function_privilege('authenticated', 'public.due_guest_messages_v1(timestamptz)', 'execute'),
  'only service_role asks what is due');
select ok((select relrowsecurity from pg_class where oid = 'public.guest_message_log'::regclass)
      and not has_table_privilege('anon', 'public.guest_message_log', 'select')
      and not has_table_privilege('authenticated', 'public.guest_message_log', 'select')
      and has_table_privilege('service_role', 'public.guest_message_log', 'insert'),
  'the log is RLS on and service_role only');
select ok(exists (select 1 from public.job_heartbeats where job_name = 'guest-messages-hourly'),
  'the hourly job has its heartbeat row');

select * from finish();
rollback;
