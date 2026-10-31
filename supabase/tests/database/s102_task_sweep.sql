-- s102 "system tasks close themselves": system_tasks_sweep_v1 (hourly sweep) and the meter_settle_estimates_v1 change (an admin-answered mismatch counts as B).
--
-- Behavioural, hand-computed. Everything is created inside this transaction on synthetic properties (e5... uuids) and goes with the closing rollback.
-- The rehearsal database is a restored backup, so it also holds REAL open tasks that the sweep may close: the first sweep's counts are asserted as ">= the
-- synthetic ones", every synthetic task is asserted by its own (kind, ref), and the second sweep must return zeros (nothing closable is left anywhere).
--
-- P1 guest_details (stays checking in 2026-11-10 / 11 / 12):
--   T1 ref 2026-11-11:g1  g1 has a phone  -> details on file                                  -> CLOSED (details note)
--   T2 ref 2026-11-10:g2  g2 has no ID, phone or e-mail, a confirmed stay checks in 11-10    -> stays OPEN
--   T3 ref 2026-11-12:g3  g3 has nothing, the only event checking in 11-12 is cancelled      -> CLOSED (stay no longer on the calendar)
--   T4 ref 'garbage' and T5 ref 2026-13-45:g2 (matches the pattern, not a date)               -> untouched, no error
-- P2 missed_cleaning (P3 holds a session for 2026-11-03 that must not count for P2):
--   T6 ref 2026-11-01 a session of P2 checked out that day                                   -> CLOSED (report on file)
--   T7 ref 2026-11-02 only a blocked event checks out                                        -> CLOSED (no confirmed stay)
--   T8 ref today-30   a confirmed stay checked out, no report, 30 days old                   -> stays OPEN (a real aged-out problem)
--   T9 ref 2026-11-03 a confirmed stay checked out, the only session is on P3                -> stays OPEN
--   T10 ref 2026-11-04 already done with the note 'kept as is' (no confirmed stay, would close if it were open) -> unchanged
-- P4 meter tasks: reading flags typed_accepted (S1) / estimate_pending (S2, S3) / estimated (S4):
--   meter_no_photo S1 CLOSED, S2 not tasked; meter_no_photo S3 stays open; meter_estimate_waiting S2 stays open, S4 CLOSED; meter_no_photo ref 'not-a-uuid' untouched.
-- P5 meter settle, answered mismatch. A: checkout 2026-10-10, 1 night, 100.00 kWh / 10.000 m3, vision ok. G: checkout 2026-10-12, 2 nights, estimate_pending, typed 110 / 11.
--   B: checkout 2026-10-14 (confirmed stay), 2 nights, 140 / 12, vision mismatch with vision_resolved_at set. Typed numbers are in order (100 <= 110 <= 140, 10 <= 11 <= 12), so they are kept:
--   G  flag typed_accepted; electric prev 100, delta 110 - 100 = 10.00, per night 10.00 / 2 = 5.00; water prev 10, delta 11 - 10 = 1.000, per night 1.000 / 2 = 0.500.
--   B  electric prev 110, delta 140 - 110 = 30.00, per night 30.00 / 2 = 15.00; water prev 11, delta 12 - 11 = 1.000, per night 0.500.
--   A meter_estimate_waiting task for G's session is opened before the settle: once G is settled the sweep closes it.
-- P6 the same gap but B's mismatch is NOT answered: nothing settles (waiting 1, settled 0), G stays estimate_pending, and the settle itself opens the
--   meter_estimate_waiting task for G's session (G checked out 2026-10-12, more than 7 days before any date this runs): the sweep must leave it open.
begin;
select plan(35);

-- catalogue and grants ------------------------------------------------------------------------------------------------------------------------------
select has_function('public', 'system_tasks_sweep_v1', array[]::name[], 'system_tasks_sweep_v1 exists');
select is_definer('public', 'system_tasks_sweep_v1', array[]::name[], 'the sweep is security definer');
select ok((select proconfig = array['search_path=""'] from pg_proc where oid = 'public.system_tasks_sweep_v1()'::regprocedure), 'the sweep has an empty search_path');
select ok(not has_function_privilege('anon', 'public.system_tasks_sweep_v1()', 'execute') and not has_function_privilege('authenticated', 'public.system_tasks_sweep_v1()', 'execute')
          and not has_function_privilege('service_role', 'public.system_tasks_sweep_v1()', 'execute'), 'the sweep has no execute grant for anon, authenticated or service_role');
create function pg_temp.s102_cron_ok() returns boolean language plpgsql as $f$
begin
  if to_regclass('cron.job') is null then return true; end if; -- rehearsal copy without pg_cron
  return exists (select 1 from cron.job where jobname = 'system-tasks-sweep' and active and schedule = '50 * * * *' and command like '%system_tasks_sweep_v1%');
end $f$;
select ok(pg_temp.s102_cron_ok(), 'cron job system-tasks-sweep exists at 50 * * * * (or pg_cron is absent)');
select ok((select position('vision_resolved_at is not null' in prosrc) > 0 from pg_proc where oid = 'public.meter_settle_estimates_v1(uuid)'::regprocedure), 'meter_settle_estimates_v1 counts an answered mismatch as B');
select ok(has_function_privilege('service_role', 'public.meter_settle_estimates_v1(uuid)', 'execute') and not has_function_privilege('authenticated', 'public.meter_settle_estimates_v1(uuid)', 'execute')
          and not has_function_privilege('anon', 'public.meter_settle_estimates_v1(uuid)', 'execute'), 'meter_settle_estimates_v1 keeps its grants: service_role only');

-- fixtures ------------------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values
 ('e5000000-0000-4000-8000-000000000001', 'S102 guest details', true),
 ('e5000000-0000-4000-8000-000000000002', 'S102 missed cleaning', true),
 ('e5000000-0000-4000-8000-000000000003', 'S102 other property', true),
 ('e5000000-0000-4000-8000-000000000004', 'S102 meter tasks', true),
 ('e5000000-0000-4000-8000-000000000005', 'S102 settle answered', true),
 ('e5000000-0000-4000-8000-000000000006', 'S102 settle unanswered', true) on conflict (id) do nothing;
insert into auth.users(id) values ('e6000000-0000-4000-8000-000000000001') on conflict (id) do nothing;

-- P1
insert into public.guests(id, property_id, name, phone) values
 ('e7000000-0000-4000-8000-000000000001', 'e5000000-0000-4000-8000-000000000001', 'S102 Has Phone', '0917 000 0001');
insert into public.guests(id, property_id, name) values
 ('e7000000-0000-4000-8000-000000000002', 'e5000000-0000-4000-8000-000000000001', 'S102 Missing Two'),
 ('e7000000-0000-4000-8000-000000000003', 'e5000000-0000-4000-8000-000000000001', 'S102 Missing Three');
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date) values
 ('e5000000-0000-4000-8000-000000000001', 's102-p1-a', 'airbnb', 'confirmed', '2026-11-11', '2026-11-13'),
 ('e5000000-0000-4000-8000-000000000001', 's102-p1-b', 'airbnb', 'confirmed', '2026-11-10', '2026-11-11'),
 ('e5000000-0000-4000-8000-000000000001', 's102-p1-c', 'airbnb', 'cancelled', '2026-11-12', '2026-11-14');

-- P2 / P3
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date) values
 ('e5000000-0000-4000-8000-000000000002', 's102-p2-a', 'airbnb', 'confirmed', '2026-10-30', '2026-11-01'),
 ('e5000000-0000-4000-8000-000000000002', 's102-p2-b', 'airbnb', 'blocked',   '2026-11-01', '2026-11-02'),
 ('e5000000-0000-4000-8000-000000000002', 's102-p2-c', 'airbnb', 'confirmed', current_date - 32, current_date - 30),
 ('e5000000-0000-4000-8000-000000000002', 's102-p2-d', 'airbnb', 'confirmed', '2026-11-01', '2026-11-03');
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, nights_stayed, checkout_date, cleaned_at) values
 ('e8000000-0000-4000-8000-000000000001', 's102-p2-s', 'Synthetic Cleaner', 'e5000000-0000-4000-8000-000000000002', 'turnover', 'e6000000-0000-4000-8000-000000000001', 2, '2026-11-01', '2026-11-01 12:00+08'),
 ('e8000000-0000-4000-8000-000000000002', 's102-p3-s', 'Synthetic Cleaner', 'e5000000-0000-4000-8000-000000000003', 'turnover', 'e6000000-0000-4000-8000-000000000001', 2, '2026-11-03', '2026-11-03 12:00+08');

-- P4: four sessions, readings with different flags
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, nights_stayed, checkout_date, cleaned_at) values
 ('e8000000-0000-4000-8000-000000000011', 's102-p4-1', 'Synthetic Cleaner', 'e5000000-0000-4000-8000-000000000004', 'turnover', 'e6000000-0000-4000-8000-000000000001', 1, '2026-11-01', '2026-11-01 12:00+08'),
 ('e8000000-0000-4000-8000-000000000012', 's102-p4-2', 'Synthetic Cleaner', 'e5000000-0000-4000-8000-000000000004', 'turnover', 'e6000000-0000-4000-8000-000000000001', 1, '2026-11-02', '2026-11-02 12:00+08'),
 ('e8000000-0000-4000-8000-000000000013', 's102-p4-3', 'Synthetic Cleaner', 'e5000000-0000-4000-8000-000000000004', 'turnover', 'e6000000-0000-4000-8000-000000000001', 1, '2026-11-03', '2026-11-03 12:00+08'),
 ('e8000000-0000-4000-8000-000000000014', 's102-p4-4', 'Synthetic Cleaner', 'e5000000-0000-4000-8000-000000000004', 'turnover', 'e6000000-0000-4000-8000-000000000001', 1, '2026-11-04', '2026-11-04 12:00+08');
insert into public.meter_readings(session_id, property_id, submitted_by_user_id, electric_curr, water_curr, meter_flag) values
 ('e8000000-0000-4000-8000-000000000011', 'e5000000-0000-4000-8000-000000000004', 'e6000000-0000-4000-8000-000000000001', 5001, 50.001, 'typed_accepted'),
 ('e8000000-0000-4000-8000-000000000012', 'e5000000-0000-4000-8000-000000000004', 'e6000000-0000-4000-8000-000000000001', 5002, 50.002, 'estimate_pending'),
 ('e8000000-0000-4000-8000-000000000013', 'e5000000-0000-4000-8000-000000000004', 'e6000000-0000-4000-8000-000000000001', 5003, 50.003, 'estimate_pending'),
 ('e8000000-0000-4000-8000-000000000014', 'e5000000-0000-4000-8000-000000000004', 'e6000000-0000-4000-8000-000000000001', 5004, 50.004, 'estimated');

-- P5 (answered) and P6 (unanswered): A verified, G pending, B mismatch (answered in P5 only)
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, nights_stayed, checkout_date, cleaned_at) values
 ('e8000000-0000-4000-8000-000000000021', 's102-p5-a', 'Synthetic Cleaner', 'e5000000-0000-4000-8000-000000000005', 'turnover', 'e6000000-0000-4000-8000-000000000001', 1, '2026-10-10', '2026-10-10 12:00+08'),
 ('e8000000-0000-4000-8000-000000000022', 's102-p5-g', 'Synthetic Cleaner', 'e5000000-0000-4000-8000-000000000005', 'turnover', 'e6000000-0000-4000-8000-000000000001', 2, '2026-10-12', '2026-10-12 12:00+08'),
 ('e8000000-0000-4000-8000-000000000023', 's102-p5-b', 'Synthetic Cleaner', 'e5000000-0000-4000-8000-000000000005', 'turnover', 'e6000000-0000-4000-8000-000000000001', 2, '2026-10-14', '2026-10-14 12:00+08'),
 ('e8000000-0000-4000-8000-000000000031', 's102-p6-a', 'Synthetic Cleaner', 'e5000000-0000-4000-8000-000000000006', 'turnover', 'e6000000-0000-4000-8000-000000000001', 1, '2026-10-10', '2026-10-10 12:00+08'),
 ('e8000000-0000-4000-8000-000000000032', 's102-p6-g', 'Synthetic Cleaner', 'e5000000-0000-4000-8000-000000000006', 'turnover', 'e6000000-0000-4000-8000-000000000001', 2, '2026-10-12', '2026-10-12 12:00+08'),
 ('e8000000-0000-4000-8000-000000000033', 's102-p6-b', 'Synthetic Cleaner', 'e5000000-0000-4000-8000-000000000006', 'turnover', 'e6000000-0000-4000-8000-000000000001', 2, '2026-10-14', '2026-10-14 12:00+08');
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date) values
 ('e5000000-0000-4000-8000-000000000005', 's102-p5-ce', 'airbnb', 'confirmed', '2026-10-12', '2026-10-14'),
 ('e5000000-0000-4000-8000-000000000006', 's102-p6-ce', 'airbnb', 'confirmed', '2026-10-12', '2026-10-14');
insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, electric_curr, water_curr, vision_verdict, vision_resolved_at, meter_flag) values
 ('e9000000-0000-4000-8000-000000000021', 'e8000000-0000-4000-8000-000000000021', 'e5000000-0000-4000-8000-000000000005', 'e6000000-0000-4000-8000-000000000001', 100, 10, 'ok', null, null),
 ('e9000000-0000-4000-8000-000000000022', 'e8000000-0000-4000-8000-000000000022', 'e5000000-0000-4000-8000-000000000005', 'e6000000-0000-4000-8000-000000000001', 110, 11, null, null, 'estimate_pending'),
 ('e9000000-0000-4000-8000-000000000023', 'e8000000-0000-4000-8000-000000000023', 'e5000000-0000-4000-8000-000000000005', 'e6000000-0000-4000-8000-000000000001', 140, 12, 'mismatch', now(), null),
 ('e9000000-0000-4000-8000-000000000031', 'e8000000-0000-4000-8000-000000000031', 'e5000000-0000-4000-8000-000000000006', 'e6000000-0000-4000-8000-000000000001', 100, 10, 'ok', null, null),
 ('e9000000-0000-4000-8000-000000000032', 'e8000000-0000-4000-8000-000000000032', 'e5000000-0000-4000-8000-000000000006', 'e6000000-0000-4000-8000-000000000001', 110, 11, null, null, 'estimate_pending'),
 ('e9000000-0000-4000-8000-000000000033', 'e8000000-0000-4000-8000-000000000033', 'e5000000-0000-4000-8000-000000000006', 'e6000000-0000-4000-8000-000000000001', 140, 12, 'mismatch', null, null);

-- the open tasks, exactly as the jobs file them -------------------------------------------------------------------------------------------------------
do $do$
begin
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000001', 'guest_details', '2026-11-11:e7000000-0000-4000-8000-000000000001', 'Guest details T1', null, 'low');
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000001', 'guest_details', '2026-11-10:e7000000-0000-4000-8000-000000000002', 'Guest details T2', null, 'low');
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000001', 'guest_details', '2026-11-12:e7000000-0000-4000-8000-000000000003', 'Guest details T3', null, 'low');
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000001', 'guest_details', 'garbage', 'Guest details T4', null, 'low');
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000001', 'guest_details', '2026-13-45:e7000000-0000-4000-8000-000000000002', 'Guest details T5', null, 'low');
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000002', 'missed_cleaning', '2026-11-01', 'Missed cleaning T6', null, 'low');
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000002', 'missed_cleaning', '2026-11-02', 'Missed cleaning T7', null, 'low');
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000002', 'missed_cleaning', (current_date - 30)::text, 'Missed cleaning T8', null, 'low');
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000002', 'missed_cleaning', '2026-11-03', 'Missed cleaning T9', null, 'low');
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000002', 'missed_cleaning', '2026-11-04', 'Missed cleaning T10', null, 'low');
  update public.follow_up_tasks set status = 'done', completed_at = '2026-01-01 00:00+00', completion_note = 'kept as is'
   where idempotency_key = 'system:missed_cleaning:2026-11-04';
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000004', 'meter_no_photo', 'e8000000-0000-4000-8000-000000000011', 'Meter no photo S1', null, 'low');
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000004', 'meter_estimate_waiting', 'e8000000-0000-4000-8000-000000000012', 'Meter waiting S2', null, 'low');
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000004', 'meter_no_photo', 'e8000000-0000-4000-8000-000000000013', 'Meter no photo S3', null, 'low');
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000004', 'meter_estimate_waiting', 'e8000000-0000-4000-8000-000000000014', 'Meter waiting S4', null, 'low');
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000004', 'meter_no_photo', 'not-a-uuid', 'Meter no photo bad ref', null, 'low');
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000004', 'low_stock', 'e5-low', 'Low stock other kind', null, 'low');
  perform public.system_task_open_v1('e5000000-0000-4000-8000-000000000005', 'meter_estimate_waiting', 'e8000000-0000-4000-8000-000000000022', 'Meter waiting G5', null, 'low');
end $do$;

-- meter settle: the admin-answered mismatch counts as B ----------------------------------------------------------------------------------------------
select is(public.meter_settle_estimates_v1('e5000000-0000-4000-8000-000000000005') ->> 'settled', '1', 'answered mismatch as B: the gap settles');
select ok((select meter_flag = 'typed_accepted' and electric_curr = 110 and water_curr = 11 from public.meter_readings where id = 'e9000000-0000-4000-8000-000000000022'), 'G keeps its typed numbers and is typed_accepted');
select ok((select electric_prev = 100 and electric_delta = 10.00 and kwh_per_night = 5.00 and water_prev = 10 and water_delta = 1.000 and m3_per_night = 0.500 from public.meter_readings where id = 'e9000000-0000-4000-8000-000000000022'), 'G: prev 100 / 10, delta 10.00 / 1.000, per night 5.00 / 0.500');
select ok((select electric_prev = 110 and electric_delta = 30.00 and kwh_per_night = 15.00 and water_prev = 11 and water_delta = 1.000 and m3_per_night = 0.500 from public.meter_readings where id = 'e9000000-0000-4000-8000-000000000023'), 'B: prev 110 / 11, delta 30.00 / 1.000, per night 15.00 / 0.500');
select is(public.meter_settle_estimates_v1('e5000000-0000-4000-8000-000000000006') ->> 'settled', '0', 'unanswered mismatch as B: nothing settles');
select is((select count(*) from public.meter_readings where id = 'e9000000-0000-4000-8000-000000000032' and meter_flag = 'estimate_pending' and electric_prev is null), 1::bigint, 'unanswered: G stays estimate_pending, untouched');

-- the sweep -------------------------------------------------------------------------------------------------------------------------------------------
create temp table s102_first as select public.system_tasks_sweep_v1() as r;
select ok((select (r ->> 'guest_details')::int >= 2 from s102_first), 'first sweep closed at least the 2 synthetic guest_details tasks');
select ok((select (r ->> 'missed_cleaning')::int >= 2 from s102_first), 'first sweep closed at least the 2 synthetic missed_cleaning tasks');
select ok((select (r ->> 'meter')::int >= 3 from s102_first), 'first sweep closed at least the 3 synthetic meter tasks (S1, S4, G5)');

select ok((select status = 'done' and completed_at is not null and completion_note = 'Closed automatically: the guest''s ID or contact details are now on file.'
             from public.follow_up_tasks where idempotency_key = 'system:guest_details:2026-11-11:e7000000-0000-4000-8000-000000000001'), 'T1: details on file -> closed with its note');
select is((select status from public.follow_up_tasks where idempotency_key = 'system:guest_details:2026-11-10:e7000000-0000-4000-8000-000000000002'), 'open', 'T2: details missing and the stay is on the calendar -> stays open');
select ok((select status = 'done' and completed_at is not null and completion_note = 'Closed automatically: this stay is no longer on the calendar.'
             from public.follow_up_tasks where idempotency_key = 'system:guest_details:2026-11-12:e7000000-0000-4000-8000-000000000003'), 'T3: only a cancelled event -> closed as no longer on the calendar');
select is((select status from public.follow_up_tasks where idempotency_key = 'system:guest_details:garbage'), 'open', 'T4: a malformed ref is skipped, no error');
select is((select status from public.follow_up_tasks where idempotency_key = 'system:guest_details:2026-13-45:e7000000-0000-4000-8000-000000000002'), 'open', 'T5: an impossible date is skipped, no error');
select ok((select status = 'done' and completed_at is not null and completion_note = 'Closed automatically: the cleaning report for this checkout is now on file.'
             from public.follow_up_tasks where idempotency_key = 'system:missed_cleaning:2026-11-01'), 'T6: a session of the property with that checkout date -> closed');
select ok((select status = 'done' and completed_at is not null and completion_note = 'Closed automatically: no confirmed stay checks out on this day any more.'
             from public.follow_up_tasks where idempotency_key = 'system:missed_cleaning:2026-11-02'), 'T7: only a blocked event -> closed as no confirmed stay');
select is((select status from public.follow_up_tasks where idempotency_key = 'system:missed_cleaning:' || (current_date - 30)::text), 'open', 'T8: a confirmed stay with no report stays open even when 30 days old');
select is((select status from public.follow_up_tasks where idempotency_key = 'system:missed_cleaning:2026-11-03'), 'open', 'T9: a session of another property does not close it');
select ok((select status = 'done' and completion_note = 'kept as is' and completed_at = '2026-01-01 00:00+00' from public.follow_up_tasks where idempotency_key = 'system:missed_cleaning:2026-11-04'), 'T10: an already-done task is not touched');
select ok((select status = 'done' and completion_note = 'Closed automatically: the meter readings have settled.' from public.follow_up_tasks where idempotency_key = 'system:meter_no_photo:e8000000-0000-4000-8000-000000000011'), 'S1: reading no longer pending -> meter_no_photo closed');
select is((select status from public.follow_up_tasks where idempotency_key = 'system:meter_estimate_waiting:e8000000-0000-4000-8000-000000000012'), 'open', 'S2: reading still estimate_pending -> meter_estimate_waiting stays open');
select is((select status from public.follow_up_tasks where idempotency_key = 'system:meter_no_photo:e8000000-0000-4000-8000-000000000013'), 'open', 'S3: reading still estimate_pending -> meter_no_photo stays open');
select ok((select status = 'done' and completion_note = 'Closed automatically: the meter readings have settled.' from public.follow_up_tasks where idempotency_key = 'system:meter_estimate_waiting:e8000000-0000-4000-8000-000000000014'), 'S4: reading estimated -> meter_estimate_waiting closed');
select is((select status from public.follow_up_tasks where idempotency_key = 'system:meter_no_photo:not-a-uuid'), 'open', 'a malformed uuid ref is skipped, no error');
select is((select status from public.follow_up_tasks where idempotency_key = 'system:meter_estimate_waiting:e8000000-0000-4000-8000-000000000022'), 'done', 'G5: settled by the answered mismatch, so its waiting task closed');
select is((select count(*) from public.follow_up_tasks where source_kind = 'meter_estimate_waiting' and source_ref = 'e8000000-0000-4000-8000-000000000032' and status = 'open'), 1::bigint, 'G6: the settle opened a waiting task and the sweep leaves it open while G is pending');
select is((select status from public.follow_up_tasks where idempotency_key = 'system:low_stock:e5-low'), 'open', 'a task of another kind is untouched');

-- idempotence ------------------------------------------------------------------------------------------------------------------------------------------
select is(public.system_tasks_sweep_v1(), '{"guest_details":0,"missed_cleaning":0,"meter":0}'::jsonb, 'second sweep closes nothing');

select * from finish();
rollback;
