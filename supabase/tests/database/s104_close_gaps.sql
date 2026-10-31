-- s104 "close the remaining meter-check gaps": admin_report_blocks_v1 / admin_resolve_report_block_v1 (photo-date findings, archived flag, probe-proof ids, same-day sibling),
-- meter_settle_estimates_v1 (only a staff answer makes B), system_tasks_sweep_v1 (information tasks after 3 days, impossible dates skipped), get_meter_photo_followups (checkout + guest).
--
-- Behavioural, hand-computed. Everything is created inside this transaction on synthetic properties (b1... uuids) and goes with the closing rollback.
-- RPCs run as authenticated with the jwt claim set like s101; tables are read after reset role; the settle and the sweep run as the migration owner.
--
-- P1 list (lookback 14, now = N): R9 mismatch + a date line (N-1d), R1 mismatch with both photo objects on file (N-2d), R2 verdict ok + 1 date line, no objects (N-3d, session
--   Ana Synthetic, checkout 2026-10-21), R3 ok + 2 lines, electric object only (N-4d), R4 ok + 1 line, electric object, no water path (N-5d).
--   Not listed: R5 (empty lines array), R6 (no lines), R7 (lines, already answered), R8 (lines, 20 days old: listed with lookback 30 only).
--   Listed = 5 in the order R9, R1, R2, R3, R4. reason: R9 / R1 mismatch, R2 photo_date. archived: R1 false (both objects), R2 true (no object), R3 true (water object gone),
--   R4 false (a meter with no path is not archived), R9 false (no paths).
-- P6 photo date, correct_numbers: Q (ok, 2 nights) was 105 / 11 after 100 / 10; the admin types 106 / 11.5:
--   electric delta 106 - 100 = 6.00, per night 3.00; water delta 11.5 - 10 = 1.500, per night 0.750.
-- P2 same-day sibling (stay date 2026-10-20): E 08:00 (3990 -> 4000), M 12:00 held (4000 -> 4292, 2 nights), T 15:00 the same day (4292 -> 4312, 1 night, water 81.852 -> 82.5),
--   N 2026-10-22 (4312 -> 4330). The admin corrects M to 4300 / 81.000: M electric delta 300.00, per night 150.00. The next reading is T (same day, later), NOT N:
--   T electric prev 4300, delta 4312 - 4300 = 12.00, per night 12.00; water prev 81.000, delta 82.500 - 81.000 = 1.500, per night 1.500. N and E stay as they were.
-- P3 / P7 / P8 settle: A 100 / 10 ok, G pending 110 / 11 (2 nights), B 140 / 12 mismatch answered with the admin sentence. P3: answered by a cleaner (typed the sentence through
--   resolve_meter_followup_v1) -> nothing settles. P8: answered by nobody (null) -> nothing settles. P7: answered by an admin -> settles, exactly as the s102 P5 numbers:
--   G prev 100 / 10, delta 10.00 / 1.000, per night 5.00 / 0.500; B prev 110 / 11, delta 30.00 / 1.000, per night 15.00 / 0.500.
-- P4 sweep: information tasks I1 (4 days old) closed, I2 (2 days old) open, I3 (the settle's own, new) open, a 10-day-old low_stock untouched; two refs that match the pattern but
--   are not dates (2026-13-45, 2026-02-30) stay open without an error.
-- P5 follow-ups: SF1 (1 day ago, guest 'Ysabel ' with a trailing blank, checkout 2026-10-21, mismatch), SF2 (2 days ago, blank guest, no checkout, unreadable).
begin;
select plan(112);

-- catalogue, bodies and grants ---------------------------------------------------------------------------------------------------------------------
select has_function('public', 'admin_report_blocks_v1', array['uuid', 'integer'], 'admin_report_blocks_v1 exists');
select has_function('public', 'admin_resolve_report_block_v1', array['uuid', 'text', 'numeric', 'numeric', 'text'], 'admin_resolve_report_block_v1 exists');
select has_function('public', 'get_meter_photo_followups', array['uuid', 'integer'], 'get_meter_photo_followups exists');
select is((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.admin_report_blocks_v1(uuid,integer)'::regprocedure), '437b4a6bfb30df1c47a6cff06ee3371b', 'admin_report_blocks_v1 is the s104 body');
select is((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.admin_resolve_report_block_v1(uuid,text,numeric,numeric,text)'::regprocedure), 'b882191dbc2d651d55c46cb74b8dfa12', 'admin_resolve_report_block_v1 is the s104 body');
select is((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.meter_settle_estimates_v1(uuid)'::regprocedure), 'a239c861c8656cd76f372b07d4e6e64b', 'meter_settle_estimates_v1 is the s104 body');
select is((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.system_tasks_sweep_v1()'::regprocedure), '0fdd80d252523c39cc30003475fb21bb', 'system_tasks_sweep_v1 is the s104 body');
select is((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.get_meter_photo_followups(uuid,integer)'::regprocedure), '8d49875bdd4f94e4040c7de55c8c2c55', 'get_meter_photo_followups is the s104 body');
select is((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.admin_request_meter_resend_v1(uuid,text)'::regprocedure), '44ef5eab6a378d9a33beccc08f21dfad', 'admin_request_meter_resend_v1 is the s104 body');
select is((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.s104_meter_vision_guard_v1()'::regprocedure), '0ce8d9932da9a0bd7982e25353409d1e', 's104_meter_vision_guard_v1 is the s104 body');
select ok(has_function_privilege('authenticated', 'public.admin_request_meter_resend_v1(uuid,text)', 'execute') and not has_function_privilege('anon', 'public.admin_request_meter_resend_v1(uuid,text)', 'execute')
          and not has_function_privilege('service_role', 'public.admin_request_meter_resend_v1(uuid,text)', 'execute'), 'resend: authenticated only');
select ok(has_function_privilege('authenticated', 'public.admin_report_blocks_v1(uuid,integer)', 'execute') and not has_function_privilege('anon', 'public.admin_report_blocks_v1(uuid,integer)', 'execute')
          and not has_function_privilege('service_role', 'public.admin_report_blocks_v1(uuid,integer)', 'execute'), 'list: authenticated only');
select ok(has_function_privilege('authenticated', 'public.admin_resolve_report_block_v1(uuid,text,numeric,numeric,text)', 'execute') and not has_function_privilege('anon', 'public.admin_resolve_report_block_v1(uuid,text,numeric,numeric,text)', 'execute')
          and not has_function_privilege('service_role', 'public.admin_resolve_report_block_v1(uuid,text,numeric,numeric,text)', 'execute'), 'answer: authenticated only');
select ok(has_function_privilege('authenticated', 'public.get_meter_photo_followups(uuid,integer)', 'execute') and has_function_privilege('service_role', 'public.get_meter_photo_followups(uuid,integer)', 'execute')
          and not has_function_privilege('anon', 'public.get_meter_photo_followups(uuid,integer)', 'execute'), 'follow-ups: authenticated and service_role, never anon');
select ok(has_function_privilege('service_role', 'public.meter_settle_estimates_v1(uuid)', 'execute') and not has_function_privilege('authenticated', 'public.meter_settle_estimates_v1(uuid)', 'execute')
          and not has_function_privilege('anon', 'public.meter_settle_estimates_v1(uuid)', 'execute'), 'settle: service_role only');
select ok(not has_function_privilege('anon', 'public.system_tasks_sweep_v1()', 'execute') and not has_function_privilege('authenticated', 'public.system_tasks_sweep_v1()', 'execute')
          and not has_function_privilege('service_role', 'public.system_tasks_sweep_v1()', 'execute'), 'the sweep still has no grants');
select is((select proargnames[3:17] from pg_proc where oid = 'public.admin_report_blocks_v1(uuid,integer)'::regprocedure),
  array['reading_id', 'session_id', 'cleaner_name', 'checkout_date', 'recorded_at', 'typed_electric', 'typed_water', 'prev_electric', 'prev_water', 'photo_electric', 'photo_water',
        'photo_note_electric', 'photo_note_water', 'photo_path_electric', 'photo_path_water'], 'list: the 15 existing columns keep their order');
select is((select proargnames[18:21] from pg_proc where oid = 'public.admin_report_blocks_v1(uuid,integer)'::regprocedure), array['reason', 'photo_date_lines', 'photo_archived', 'resend_requested_at'], 'list: the four new columns are at the end');
select is((select proargnames[13:15] from pg_proc where oid = 'public.get_meter_photo_followups(uuid,integer)'::regprocedure), array['checkout_date', 'guest_name', 'resend_requested_at'], 'follow-ups: checkout_date, guest_name and resend_requested_at are at the end');

select ok(exists (select 1 from pg_trigger t join pg_proc p on p.oid = t.tgfoid where t.tgrelid = 'public.meter_readings'::regclass and t.tgname = 's104_meter_vision_guard' and not t.tgisinternal
                     and t.tgenabled = 'O' and (t.tgtype & 2) = 2 and (t.tgtype & 16) = 16 and not p.prosecdef and p.proconfig = array['search_path=""']), 'the vision guard is an enabled BEFORE UPDATE trigger on meter_readings, security invoker, empty search_path');

-- people and properties -----------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values
 ('b1000000-0000-4000-8000-000000000001', 'S104 list', true),
 ('b1000000-0000-4000-8000-000000000002', 'S104 same day sibling', true),
 ('b1000000-0000-4000-8000-000000000003', 'S104 settle cleaner answer', true),
 ('b1000000-0000-4000-8000-000000000004', 'S104 sweep', true),
 ('b1000000-0000-4000-8000-000000000005', 'S104 follow-ups', true),
 ('b1000000-0000-4000-8000-000000000006', 'S104 photo date correct', true),
 ('b1000000-0000-4000-8000-000000000007', 'S104 settle admin answer', true),
 ('b1000000-0000-4000-8000-000000000008', 'S104 settle nobody answer', true),
 ('b1000000-0000-4000-8000-000000000009', 'S104 cleaner own readings', true),
 ('b1000000-0000-4000-8000-000000000010', 'S104 settle dated photo unanswered', true),
 ('b1000000-0000-4000-8000-000000000011', 'S104 settle dated photo answered', true),
 ('b1000000-0000-4000-8000-000000000012', 'S104 out of order and resend', true),
 ('b1000000-0000-4000-8000-000000000013', 'S104 out of order correct', true) on conflict (id) do nothing;
insert into auth.users(id) values ('b2000000-0000-4000-8000-000000000001'), ('b2000000-0000-4000-8000-000000000002') on conflict (id) do nothing;
insert into public.staff_access_profiles(user_id, role, disabled_at, sessions_revoked_after) values
 ('b2000000-0000-4000-8000-000000000001', 'admin', null, null),
 ('b2000000-0000-4000-8000-000000000002', 'cleaner', null, null)
on conflict (user_id) do update set role = excluded.role, disabled_at = null, sessions_revoked_after = null;
insert into public.staff_property_access(user_id, property_id) values
 ('b2000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001'),
 ('b2000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000002'),
 ('b2000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000005'),
 ('b2000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000006'),
 ('b2000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000012'),
 ('b2000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000013'),
 ('b2000000-0000-4000-8000-000000000002', 'b1000000-0000-4000-8000-000000000009') on conflict do nothing;

-- P1: the list --------------------------------------------------------------------------------------------------------------------------------------
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, nights_stayed, checkout_date, cleaned_at) values
 ('b3000000-0000-4000-8000-000000000001', 's104-p1-ana', 'Ana Synthetic', 'b1000000-0000-4000-8000-000000000001', 'turnover', 'b2000000-0000-4000-8000-000000000002', 1, '2026-10-21', now() - interval '3 days');
insert into storage.objects(bucket_id, name) values
 ('cleaning-photos', 's104/r1-e.jpg'), ('cleaning-photos', 's104/r1-w.jpg'), ('cleaning-photos', 's104/r3-e.jpg'), ('cleaning-photos', 's104/r4-e.jpg');
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, water_curr, vision_verdict, vision_resolved_at, vision_raw) values
 ('b4000000-0000-4000-8000-000000000009', null, 'b1000000-0000-4000-8000-000000000001', now() - interval '1 day', 100, 110, 10, 11, 'mismatch', null,
  '{"photo_date_lines":["y"]}'::jsonb),
 ('b4000000-0000-4000-8000-000000000001', null, 'b1000000-0000-4000-8000-000000000001', now() - interval '2 days', 4000, 4292, 80, 81.852, 'mismatch', null,
  '{"electric":{"reading":431.2,"note":"the dial shows 4 3 1 2"},"water":{"reading":806},"paths":{"electric":"s104/r1-e.jpg","water":"s104/r1-w.jpg"}}'::jsonb),
 ('b4000000-0000-4000-8000-000000000002', 'b3000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001', now() - interval '3 days', 4000, 4312, 80, 80.7, 'ok', null,
  '{"photo_date_lines":["Electric photo taken Oct 23, checkout Oct 21"],"paths":{"electric":"s104/r2-e.jpg","water":"s104/r2-w.jpg"}}'::jsonb),
 ('b4000000-0000-4000-8000-000000000003', null, 'b1000000-0000-4000-8000-000000000001', now() - interval '4 days', 4000, 4312, 80, 80.7, 'ok', null,
  '{"photo_date_lines":["a","b"],"paths":{"electric":"s104/r3-e.jpg","water":"s104/r3-w.jpg"}}'::jsonb),
 ('b4000000-0000-4000-8000-000000000004', null, 'b1000000-0000-4000-8000-000000000001', now() - interval '5 days', 4000, 4312, 80, 80.7, 'ok', null,
  '{"photo_date_lines":["c"],"paths":{"electric":"s104/r4-e.jpg"}}'::jsonb),
 ('b4000000-0000-4000-8000-000000000005', null, 'b1000000-0000-4000-8000-000000000001', now() - interval '2 days', 4000, 4312, 80, 80.7, 'ok', null, '{"photo_date_lines":[]}'::jsonb),
 ('b4000000-0000-4000-8000-000000000006', null, 'b1000000-0000-4000-8000-000000000001', now() - interval '2 days', 4000, 4312, 80, 80.7, 'ok', null, '{"paths":{}}'::jsonb),
 ('b4000000-0000-4000-8000-000000000007', null, 'b1000000-0000-4000-8000-000000000001', now() - interval '2 days', 4000, 4312, 80, 80.7, 'ok', now(), '{"photo_date_lines":["d"]}'::jsonb),
 ('b4000000-0000-4000-8000-000000000008', null, 'b1000000-0000-4000-8000-000000000001', now() - interval '20 days', 4000, 4312, 80, 80.7, 'ok', null, '{"photo_date_lines":["e"]}'::jsonb);

-- P6: a photo-date reading to correct ------------------------------------------------------------------------------------------------------------------
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, nights_stayed, checkout_date, cleaned_at) values
 ('b3000000-0000-4000-8000-000000000061', 's104-p6-q', 'Quin Synthetic', 'b1000000-0000-4000-8000-000000000006', 'turnover', 'b2000000-0000-4000-8000-000000000002', 2, '2026-10-20', '2026-10-20 12:00+08');
insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, recorded_at, electric_prev, electric_curr, electric_delta, water_prev, water_curr, water_delta,
                                  kwh_per_night, m3_per_night, vision_verdict, vision_raw) values
 ('b4000000-0000-4000-8000-000000000061', 'b3000000-0000-4000-8000-000000000061', 'b1000000-0000-4000-8000-000000000006', 'b2000000-0000-4000-8000-000000000002', '2026-10-20 12:00+08',
  100, 105, 5.00, 10, 11, 1.000, 2.50, 0.500, 'ok', '{"photo_date_lines":["Water photo taken Oct 25, checkout Oct 20"]}'::jsonb);

-- P2: E, M (held), T (same day, later), N --------------------------------------------------------------------------------------------------------------
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, nights_stayed, checkout_date, cleaned_at) values
 ('b3000000-0000-4000-8000-000000000021', 's104-p2-e', 'Early Synthetic', 'b1000000-0000-4000-8000-000000000002', 'turnover', 'b2000000-0000-4000-8000-000000000002', 1, '2026-10-20', '2026-10-20 08:00+08'),
 ('b3000000-0000-4000-8000-000000000022', 's104-p2-m', 'Held Synthetic', 'b1000000-0000-4000-8000-000000000002', 'turnover', 'b2000000-0000-4000-8000-000000000002', 2, '2026-10-20', '2026-10-20 12:00+08'),
 ('b3000000-0000-4000-8000-000000000023', 's104-p2-t', 'Deep Synthetic', 'b1000000-0000-4000-8000-000000000002', 'turnover', 'b2000000-0000-4000-8000-000000000002', 1, '2026-10-20', '2026-10-20 15:00+08'),
 ('b3000000-0000-4000-8000-000000000024', 's104-p2-n', 'Next Synthetic', 'b1000000-0000-4000-8000-000000000002', 'turnover', 'b2000000-0000-4000-8000-000000000002', 2, '2026-10-22', '2026-10-22 12:00+08');
insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, recorded_at, electric_prev, electric_curr, electric_delta, water_prev, water_curr, water_delta,
                                  kwh_per_night, m3_per_night, vision_verdict, meter_flag) values
 ('b4000000-0000-4000-8000-000000000021', 'b3000000-0000-4000-8000-000000000021', 'b1000000-0000-4000-8000-000000000002', 'b2000000-0000-4000-8000-000000000002', '2026-10-20 08:00+08',
  3990, 4000, 10.00, 79, 80, 1.000, 10.00, 1.000, 'ok', null),
 ('b4000000-0000-4000-8000-000000000022', 'b3000000-0000-4000-8000-000000000022', 'b1000000-0000-4000-8000-000000000002', 'b2000000-0000-4000-8000-000000000002', '2026-10-20 12:00+08',
  4000.00, 4292, 292.00, 80.000, 81.852, 1.852, 146.00, 0.926, 'mismatch', null),
 ('b4000000-0000-4000-8000-000000000023', 'b3000000-0000-4000-8000-000000000023', 'b1000000-0000-4000-8000-000000000002', 'b2000000-0000-4000-8000-000000000002', '2026-10-20 15:00+08',
  4292.00, 4312, 20.00, 81.852, 82.500, 0.648, 20.00, 0.648, 'ok', null),
 ('b4000000-0000-4000-8000-000000000024', 'b3000000-0000-4000-8000-000000000024', 'b1000000-0000-4000-8000-000000000002', 'b2000000-0000-4000-8000-000000000002', '2026-10-22 12:00+08',
  4312.00, 4330, 18.00, 82.500, 83.000, 0.500, 9.00, 0.250, 'ok', null);

-- P3 / P7 / P8: A verified, G pending, B mismatch answered (by a cleaner / by an admin / by nobody) ------------------------------------------------------------
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, nights_stayed, checkout_date, cleaned_at) values
 ('b3000000-0000-4000-8000-000000000031', 's104-p3-a', 'Synthetic Cleaner', 'b1000000-0000-4000-8000-000000000003', 'turnover', 'b2000000-0000-4000-8000-000000000002', 1, '2026-10-10', '2026-10-10 12:00+08'),
 ('b3000000-0000-4000-8000-000000000032', 's104-p3-g', 'Synthetic Cleaner', 'b1000000-0000-4000-8000-000000000003', 'turnover', 'b2000000-0000-4000-8000-000000000002', 2, '2026-10-12', '2026-10-12 12:00+08'),
 ('b3000000-0000-4000-8000-000000000033', 's104-p3-b', 'Synthetic Cleaner', 'b1000000-0000-4000-8000-000000000003', 'turnover', 'b2000000-0000-4000-8000-000000000002', 2, '2026-10-14', '2026-10-14 12:00+08'),
 ('b3000000-0000-4000-8000-000000000071', 's104-p7-a', 'Synthetic Cleaner', 'b1000000-0000-4000-8000-000000000007', 'turnover', 'b2000000-0000-4000-8000-000000000002', 1, '2026-10-10', '2026-10-10 12:00+08'),
 ('b3000000-0000-4000-8000-000000000072', 's104-p7-g', 'Synthetic Cleaner', 'b1000000-0000-4000-8000-000000000007', 'turnover', 'b2000000-0000-4000-8000-000000000002', 2, '2026-10-12', '2026-10-12 12:00+08'),
 ('b3000000-0000-4000-8000-000000000073', 's104-p7-b', 'Synthetic Cleaner', 'b1000000-0000-4000-8000-000000000007', 'turnover', 'b2000000-0000-4000-8000-000000000002', 2, '2026-10-14', '2026-10-14 12:00+08'),
 ('b3000000-0000-4000-8000-000000000081', 's104-p8-a', 'Synthetic Cleaner', 'b1000000-0000-4000-8000-000000000008', 'turnover', 'b2000000-0000-4000-8000-000000000002', 1, '2026-10-10', '2026-10-10 12:00+08'),
 ('b3000000-0000-4000-8000-000000000082', 's104-p8-g', 'Synthetic Cleaner', 'b1000000-0000-4000-8000-000000000008', 'turnover', 'b2000000-0000-4000-8000-000000000002', 2, '2026-10-12', '2026-10-12 12:00+08'),
 ('b3000000-0000-4000-8000-000000000083', 's104-p8-b', 'Synthetic Cleaner', 'b1000000-0000-4000-8000-000000000008', 'turnover', 'b2000000-0000-4000-8000-000000000002', 2, '2026-10-14', '2026-10-14 12:00+08');
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date) values
 ('b1000000-0000-4000-8000-000000000003', 's104-p3-ce', 'airbnb', 'confirmed', '2026-10-12', '2026-10-14'),
 ('b1000000-0000-4000-8000-000000000007', 's104-p7-ce', 'airbnb', 'confirmed', '2026-10-12', '2026-10-14'),
 ('b1000000-0000-4000-8000-000000000008', 's104-p8-ce', 'airbnb', 'confirmed', '2026-10-12', '2026-10-14');
insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, electric_curr, water_curr, vision_verdict, vision_resolved_at, vision_resolved_by, meter_flag, vision_resolved_note) values
 ('b4000000-0000-4000-8000-000000000031', 'b3000000-0000-4000-8000-000000000031', 'b1000000-0000-4000-8000-000000000003', 'b2000000-0000-4000-8000-000000000002', 100, 10, 'ok', null, null, null, null),
 ('b4000000-0000-4000-8000-000000000032', 'b3000000-0000-4000-8000-000000000032', 'b1000000-0000-4000-8000-000000000003', 'b2000000-0000-4000-8000-000000000002', 110, 11, null, null, null, 'estimate_pending', null),
 ('b4000000-0000-4000-8000-000000000033', 'b3000000-0000-4000-8000-000000000033', 'b1000000-0000-4000-8000-000000000003', 'b2000000-0000-4000-8000-000000000002', 140, 12, 'mismatch', now(), 'b2000000-0000-4000-8000-000000000002', null, 'Typed numbers confirmed by an admin'),
 ('b4000000-0000-4000-8000-000000000071', 'b3000000-0000-4000-8000-000000000071', 'b1000000-0000-4000-8000-000000000007', 'b2000000-0000-4000-8000-000000000002', 100, 10, 'ok', null, null, null, null),
 ('b4000000-0000-4000-8000-000000000072', 'b3000000-0000-4000-8000-000000000072', 'b1000000-0000-4000-8000-000000000007', 'b2000000-0000-4000-8000-000000000002', 110, 11, null, null, null, 'estimate_pending', null),
 ('b4000000-0000-4000-8000-000000000073', 'b3000000-0000-4000-8000-000000000073', 'b1000000-0000-4000-8000-000000000007', 'b2000000-0000-4000-8000-000000000002', 140, 12, 'mismatch', now(), 'b2000000-0000-4000-8000-000000000001', null, 'Typed numbers confirmed by an admin'),
 ('b4000000-0000-4000-8000-000000000081', 'b3000000-0000-4000-8000-000000000081', 'b1000000-0000-4000-8000-000000000008', 'b2000000-0000-4000-8000-000000000002', 100, 10, 'ok', null, null, null, null),
 ('b4000000-0000-4000-8000-000000000082', 'b3000000-0000-4000-8000-000000000082', 'b1000000-0000-4000-8000-000000000008', 'b2000000-0000-4000-8000-000000000002', 110, 11, null, null, null, 'estimate_pending', null),
 ('b4000000-0000-4000-8000-000000000083', 'b3000000-0000-4000-8000-000000000083', 'b1000000-0000-4000-8000-000000000008', 'b2000000-0000-4000-8000-000000000002', 140, 12, 'mismatch', now(), null, null, 'Typed numbers confirmed by an admin');

-- P5: the follow-ups ---------------------------------------------------------------------------------------------------------------------------------
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, nights_stayed, checkout_date, cleaned_at, last_guest_name) values
 ('b3000000-0000-4000-8000-000000000051', 's104-p5-1', 'Ana Synthetic', 'b1000000-0000-4000-8000-000000000005', 'turnover', 'b2000000-0000-4000-8000-000000000002', 1, '2026-10-21', now() - interval '1 day', 'Ysabel '),
 ('b3000000-0000-4000-8000-000000000052', 's104-p5-2', 'Ana Synthetic', 'b1000000-0000-4000-8000-000000000005', 'turnover', 'b2000000-0000-4000-8000-000000000002', 1, null, now() - interval '2 days', '   ');
insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, electric_curr, water_curr, vision_verdict) values
 ('b4000000-0000-4000-8000-000000000051', 'b3000000-0000-4000-8000-000000000051', 'b1000000-0000-4000-8000-000000000005', 'b2000000-0000-4000-8000-000000000002', 4000, 80, 'mismatch'),
 ('b4000000-0000-4000-8000-000000000052', 'b3000000-0000-4000-8000-000000000052', 'b1000000-0000-4000-8000-000000000005', 'b2000000-0000-4000-8000-000000000002', 4001, 81, 'unreadable');

-- P1 more: a finding on a reading the photo reader could not read stays with the cleaner follow-up (not listed, not answerable here)
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, water_curr, vision_verdict, vision_resolved_at, vision_raw) values
 ('b4000000-0000-4000-8000-000000000010', null, 'b1000000-0000-4000-8000-000000000001', now() - interval '1 day', 4000, 4312, 80, 80.7, 'unreadable', null, '{"photo_date_lines":["z"]}'::jsonb);

-- P9: the cleaner's own readings. TR is verdict ok; TM is an unresolved mismatch on a session of hers (resolve_meter_followup_v1 must still work)
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, nights_stayed, checkout_date, cleaned_at) values
 ('b3000000-0000-4000-8000-000000000092', 's104-p9-m', 'Cleaner Synthetic', 'b1000000-0000-4000-8000-000000000009', 'turnover', 'b2000000-0000-4000-8000-000000000002', 1, '2026-10-21', now() - interval '1 day');
insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, electric_curr, water_curr, vision_verdict, meter_flag) values
 ('b4000000-0000-4000-8000-000000000091', null, 'b1000000-0000-4000-8000-000000000009', 'b2000000-0000-4000-8000-000000000002', 100, 10, 'ok', null),
 ('b4000000-0000-4000-8000-000000000092', 'b3000000-0000-4000-8000-000000000092', 'b1000000-0000-4000-8000-000000000009', 'b2000000-0000-4000-8000-000000000002', 200, 20, 'mismatch', null);

-- P10 / P11: the s102 gap again, B is verdict ok but its photo carries a date finding (P10 unanswered, P11 answered)
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, nights_stayed, checkout_date, cleaned_at) values
 ('b3000000-0000-4000-8000-000000000101', 's104-p10-a', 'Synthetic Cleaner', 'b1000000-0000-4000-8000-000000000010', 'turnover', 'b2000000-0000-4000-8000-000000000002', 1, '2026-10-10', '2026-10-10 12:00+08'),
 ('b3000000-0000-4000-8000-000000000102', 's104-p10-g', 'Synthetic Cleaner', 'b1000000-0000-4000-8000-000000000010', 'turnover', 'b2000000-0000-4000-8000-000000000002', 2, '2026-10-12', '2026-10-12 12:00+08'),
 ('b3000000-0000-4000-8000-000000000103', 's104-p10-b', 'Synthetic Cleaner', 'b1000000-0000-4000-8000-000000000010', 'turnover', 'b2000000-0000-4000-8000-000000000002', 2, '2026-10-14', '2026-10-14 12:00+08'),
 ('b3000000-0000-4000-8000-000000000111', 's104-p11-a', 'Synthetic Cleaner', 'b1000000-0000-4000-8000-000000000011', 'turnover', 'b2000000-0000-4000-8000-000000000002', 1, '2026-10-10', '2026-10-10 12:00+08'),
 ('b3000000-0000-4000-8000-000000000112', 's104-p11-g', 'Synthetic Cleaner', 'b1000000-0000-4000-8000-000000000011', 'turnover', 'b2000000-0000-4000-8000-000000000002', 2, '2026-10-12', '2026-10-12 12:00+08'),
 ('b3000000-0000-4000-8000-000000000113', 's104-p11-b', 'Synthetic Cleaner', 'b1000000-0000-4000-8000-000000000011', 'turnover', 'b2000000-0000-4000-8000-000000000002', 2, '2026-10-14', '2026-10-14 12:00+08');
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date) values
 ('b1000000-0000-4000-8000-000000000010', 's104-p10-ce', 'airbnb', 'confirmed', '2026-10-12', '2026-10-14'),
 ('b1000000-0000-4000-8000-000000000011', 's104-p11-ce', 'airbnb', 'confirmed', '2026-10-12', '2026-10-14');
insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, electric_curr, water_curr, vision_verdict, vision_resolved_at, meter_flag, vision_raw) values
 ('b4000000-0000-4000-8000-000000000101', 'b3000000-0000-4000-8000-000000000101', 'b1000000-0000-4000-8000-000000000010', 'b2000000-0000-4000-8000-000000000002', 100, 10, 'ok', null, null, null),
 ('b4000000-0000-4000-8000-000000000102', 'b3000000-0000-4000-8000-000000000102', 'b1000000-0000-4000-8000-000000000010', 'b2000000-0000-4000-8000-000000000002', 110, 11, null, null, 'estimate_pending', null),
 ('b4000000-0000-4000-8000-000000000103', 'b3000000-0000-4000-8000-000000000103', 'b1000000-0000-4000-8000-000000000010', 'b2000000-0000-4000-8000-000000000002', 140, 12, 'ok', null, null, '{"photo_date_lines":["Water photo taken Oct 25, checkout Oct 14"]}'::jsonb),
 ('b4000000-0000-4000-8000-000000000111', 'b3000000-0000-4000-8000-000000000111', 'b1000000-0000-4000-8000-000000000011', 'b2000000-0000-4000-8000-000000000002', 100, 10, 'ok', null, null, null),
 ('b4000000-0000-4000-8000-000000000112', 'b3000000-0000-4000-8000-000000000112', 'b1000000-0000-4000-8000-000000000011', 'b2000000-0000-4000-8000-000000000002', 110, 11, null, null, 'estimate_pending', null),
 ('b4000000-0000-4000-8000-000000000113', 'b3000000-0000-4000-8000-000000000113', 'b1000000-0000-4000-8000-000000000011', 'b2000000-0000-4000-8000-000000000002', 140, 12, 'ok', now(), null, '{"photo_date_lines":["Water photo taken Oct 25, checkout Oct 14"]}'::jsonb);

-- P12 / P13: readings flagged under_review (out of order, the report was accepted). UR and UR3 on P12 (UR3 gets a resend request), UR2 on P13 is corrected to 110 / 11 (2 nights:
--   electric delta 110 - 100 = 10.00, per night 5.00; water delta 11 - 10 = 1.000, per night 0.500). The resend notice reads
--   "Please send a new photo of the meter for the 22 Oct stay (Ysabel). photo was blurry".
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, nights_stayed, checkout_date, cleaned_at, last_guest_name) values
 ('b3000000-0000-4000-8000-000000000121', 's104-p12-1', 'Cleaner Synthetic', 'b1000000-0000-4000-8000-000000000012', 'turnover', 'b2000000-0000-4000-8000-000000000002', 1, '2026-10-21', now() - interval '1 day', null),
 ('b3000000-0000-4000-8000-000000000122', 's104-p12-2', 'Cleaner Synthetic', 'b1000000-0000-4000-8000-000000000012', 'turnover', 'b2000000-0000-4000-8000-000000000002', 1, '2026-10-22', now() - interval '12 hours', 'Ysabel'),
 ('b3000000-0000-4000-8000-000000000131', 's104-p13-1', 'Cleaner Synthetic', 'b1000000-0000-4000-8000-000000000013', 'turnover', 'b2000000-0000-4000-8000-000000000002', 2, '2026-10-20', now() - interval '1 day', null);
insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, recorded_at, electric_prev, electric_curr, water_prev, water_curr, vision_verdict, meter_flag) values
 ('b4000000-0000-4000-8000-000000000121', 'b3000000-0000-4000-8000-000000000121', 'b1000000-0000-4000-8000-000000000012', 'b2000000-0000-4000-8000-000000000002', now() - interval '1 day', 100, 90, 10, 9, 'ok', 'under_review'),
 ('b4000000-0000-4000-8000-000000000122', 'b3000000-0000-4000-8000-000000000122', 'b1000000-0000-4000-8000-000000000012', 'b2000000-0000-4000-8000-000000000002', now() - interval '12 hours', 100, 95, 10, 9.5, 'ok', 'under_review'),
 ('b4000000-0000-4000-8000-000000000131', 'b3000000-0000-4000-8000-000000000131', 'b1000000-0000-4000-8000-000000000013', 'b2000000-0000-4000-8000-000000000002', now() - interval '1 day', 100, 90, 10, 9, 'ok', 'under_review');

-- meter settle: only a staff answer makes B ---------------------------------------------------------------------------------------------------------
select is(public.meter_settle_estimates_v1('b1000000-0000-4000-8000-000000000003') ->> 'settled', '0', 'a cleaner who typed the admin sentence does not make B: nothing settles');
select is(public.meter_settle_estimates_v1('b1000000-0000-4000-8000-000000000008') ->> 'settled', '0', 'an answer with no resolver does not make B: nothing settles');
select is((select count(*) from public.meter_readings where id in ('b4000000-0000-4000-8000-000000000032', 'b4000000-0000-4000-8000-000000000082') and meter_flag = 'estimate_pending' and electric_prev is null), 2::bigint, 'both gaps stay estimate_pending, untouched');
select is(public.meter_settle_estimates_v1('b1000000-0000-4000-8000-000000000007') ->> 'settled', '1', 'a real admin answer makes B: the gap settles');
select ok((select meter_flag = 'typed_accepted' and electric_prev = 100 and electric_delta = 10.00 and kwh_per_night = 5.00 and water_prev = 10 and water_delta = 1.000 and m3_per_night = 0.500
             from public.meter_readings where id = 'b4000000-0000-4000-8000-000000000072'), 'P7 G: kept, prev 100 / 10, delta 10.00 / 1.000, per night 5.00 / 0.500');
select ok((select electric_prev = 110 and electric_delta = 30.00 and kwh_per_night = 15.00 and water_prev = 11 and water_delta = 1.000 and m3_per_night = 0.500
             from public.meter_readings where id = 'b4000000-0000-4000-8000-000000000073'), 'P7 B: prev 110 / 11, delta 30.00 / 1.000, per night 15.00 / 0.500');
select is(public.meter_settle_estimates_v1('b1000000-0000-4000-8000-000000000010') ->> 'settled', '0', 'a B whose photo date is off and nobody answered is not used: nothing settles');
select is(public.meter_settle_estimates_v1('b1000000-0000-4000-8000-000000000011') ->> 'settled', '1', 'the same B once it was answered (vision_resolved_at) settles the gap');
select ok((select position('staff_access_allowed' in prosrc) > 0 and position('vision_resolved_at is not null' in prosrc) > 0 from pg_proc where oid = 'public.meter_settle_estimates_v1(uuid)'::regprocedure),
  'the settle checks the resolver with staff_access_allowed and keeps the answered-mismatch rule');

-- the sweep -------------------------------------------------------------------------------------------------------------------------------------------
do $do$
begin
  perform public.system_task_open_v1('b1000000-0000-4000-8000-000000000004', 'meter_estimate_settled', 'b3000000-0000-4000-8000-0000000000a1', 'Meter readings settled I1', null, 'low');
  perform public.system_task_open_v1('b1000000-0000-4000-8000-000000000004', 'meter_estimate_settled', 'b3000000-0000-4000-8000-0000000000a2', 'Meter readings settled I2', null, 'low');
  perform public.system_task_open_v1('b1000000-0000-4000-8000-000000000004', 'low_stock', 'b4-low-stock', 'Low stock old', null, 'low');
  perform public.system_task_open_v1('b1000000-0000-4000-8000-000000000004', 'guest_details', '2026-13-45:b7000000-0000-4000-8000-000000000001', 'Impossible date guest', null, 'low');
  perform public.system_task_open_v1('b1000000-0000-4000-8000-000000000004', 'missed_cleaning', '2026-02-30', 'Impossible date cleaning', null, 'low');
  update public.follow_up_tasks set created_at = now() - interval '4 days' where idempotency_key = 'system:meter_estimate_settled:b3000000-0000-4000-8000-0000000000a1';
  update public.follow_up_tasks set created_at = now() - interval '2 days' where idempotency_key = 'system:meter_estimate_settled:b3000000-0000-4000-8000-0000000000a2';
  update public.follow_up_tasks set created_at = now() - interval '10 days' where idempotency_key = 'system:low_stock:b4-low-stock';
end $do$;
select is((select count(*) from public.follow_up_tasks where source_kind = 'meter_estimate_settled' and source_ref = 'b3000000-0000-4000-8000-000000000073' and status = 'open'), 1::bigint,
  'the settle filed its own information task (I3, new)');
create temp table s104_first as select public.system_tasks_sweep_v1() as r;
select ok((select (r ->> 'info')::int >= 1 from s104_first), 'first sweep closed at least the synthetic 4-day-old information task');
select ok((select status = 'done' and completed_at is not null and completion_note = 'Information only - closed after 3 days.' from public.follow_up_tasks
            where idempotency_key = 'system:meter_estimate_settled:b3000000-0000-4000-8000-0000000000a1'), 'I1: older than 3 days -> closed with the information note');
select is((select status from public.follow_up_tasks where idempotency_key = 'system:meter_estimate_settled:b3000000-0000-4000-8000-0000000000a2'), 'open', 'I2: 2 days old -> stays open');
select is((select status from public.follow_up_tasks where source_kind = 'meter_estimate_settled' and source_ref = 'b3000000-0000-4000-8000-000000000073'), 'open', 'I3: the settle''s own new task stays open');
select is((select status from public.follow_up_tasks where idempotency_key = 'system:low_stock:b4-low-stock'), 'open', 'a 10-day-old task of another kind is untouched');
select is((select status from public.follow_up_tasks where idempotency_key = 'system:guest_details:2026-13-45:b7000000-0000-4000-8000-000000000001'), 'open', 'an impossible guest_details date is skipped, no error');
select is((select status from public.follow_up_tasks where idempotency_key = 'system:missed_cleaning:2026-02-30'), 'open', 'an impossible missed_cleaning date is skipped, no error');
select ok((select position('invalid_datetime_format' in prosrc) > 0 and position('datetime_field_overflow' in prosrc) > 0 from pg_proc where oid = 'public.system_tasks_sweep_v1()'::regprocedure),
  'the sweep handles an impossible date by name (silently), only other errors reach the warning');
select is(public.system_tasks_sweep_v1(), '{"guest_details":0,"missed_cleaning":0,"meter":0,"info":0}'::jsonb, 'second sweep closes nothing');

-- the admin: list, photo-date findings, probes --------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"b2000000-0000-4000-8000-000000000002","aal":"aal1"}';
select throws_ok($$select * from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14)$$, '42501', null, 'a cleaner is refused the list');
select throws_ok($$select public.admin_resolve_report_block_v1('b4000000-0000-4000-8000-000000000001', 'typed_is_right', null, null, null)$$, '42501', 'inspect_cleaning denied', 'a cleaner is refused an existing id: 42501');
select throws_ok($$select public.admin_resolve_report_block_v1('b4000000-0000-4000-8000-0000000000ff', 'typed_is_right', null, null, null)$$, '42501', 'inspect_cleaning denied', 'a missing id looks exactly the same to a cleaner (ids cannot be probed)');
select throws_ok($$update public.meter_readings set vision_verdict = 'mismatch' where id = 'b4000000-0000-4000-8000-000000000091'$$, '42501', 'The photo check result of a meter reading can only be changed by the system or an admin.', 'a cleaner PATCH of vision_verdict is refused');
select throws_ok($$update public.meter_readings set meter_flag = 'misread' where id = 'b4000000-0000-4000-8000-000000000091'$$, '42501', 'The photo check result of a meter reading can only be changed by the system or an admin.', 'a cleaner PATCH of meter_flag is refused');
select throws_ok($$update public.meter_readings set vision_resolved_at = now(), vision_resolved_note = 'self answered' where id = 'b4000000-0000-4000-8000-000000000092'$$, '42501', 'The photo check result of a meter reading can only be changed by the system or an admin.', 'a cleaner cannot stamp vision_resolved_* on her own reading');
select lives_ok($$update public.meter_readings set electric_curr = 101 where id = 'b4000000-0000-4000-8000-000000000091'$$, 'a cleaner change to electric_curr alone is still allowed by the policy');
select lives_ok($$update public.meter_readings set vision_verdict = 'ok', electric_curr = 102 where id = 'b4000000-0000-4000-8000-000000000091'$$, 'writing a vision column back to the value it already has is not a change');
select is(public.resolve_meter_followup_v1('b3000000-0000-4000-8000-000000000092', 'I re-sent the photo') ->> 'outcome', 'resolved', 'resolve_meter_followup_v1 (security definer) still stamps the answer under the guard');
select throws_ok($$select public.admin_request_meter_resend_v1('b4000000-0000-4000-8000-000000000122', 'please')$$, '42501', 'inspect_cleaning denied', 'a cleaner cannot ask for a resend (an existing id)');
select throws_ok($$select public.admin_request_meter_resend_v1('b4000000-0000-4000-8000-0000000000ff', 'please')$$, '42501', 'inspect_cleaning denied', 'a missing id looks exactly the same to the resend request');
set local request.jwt.claims = '{"sub":"b2000000-0000-4000-8000-000000000001","aal":"aal1"}';
select throws_ok($$select public.admin_resolve_report_block_v1('b4000000-0000-4000-8000-0000000000ff', 'typed_is_right', null, null, null)$$, '42501', 'inspect_cleaning denied', 'a missing id is 42501 for an admin too');
select throws_ok($$select public.admin_resolve_report_block_v1('b4000000-0000-4000-8000-000000000001', 'delete_it', null, null, null)$$, '22023', 'unknown action', 'an unknown action is still refused');

select is((select count(*) from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14)), 5::bigint, 'the list holds the mismatches and the photo-date findings of P1 (5)');
select is((select array_agg(reading_id order by recorded_at desc, reading_id) from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14)),
  array['b4000000-0000-4000-8000-000000000009', 'b4000000-0000-4000-8000-000000000001', 'b4000000-0000-4000-8000-000000000002', 'b4000000-0000-4000-8000-000000000003', 'b4000000-0000-4000-8000-000000000004']::uuid[],
  'newest first: R9, R1, R2, R3, R4');
select ok(not exists (select 1 from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14)
                       where reading_id in ('b4000000-0000-4000-8000-000000000005', 'b4000000-0000-4000-8000-000000000006', 'b4000000-0000-4000-8000-000000000007', 'b4000000-0000-4000-8000-000000000008')),
  'an empty lines array, no lines, an answered finding and a 20-day-old finding are not listed');
select is((select count(*) from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 30)), 6::bigint, 'a 30-day lookback also lists the 20-day-old finding');
select is((select reason from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14) where reading_id = 'b4000000-0000-4000-8000-000000000001'), 'mismatch', 'R1: reason mismatch');
select is((select reason from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14) where reading_id = 'b4000000-0000-4000-8000-000000000002'), 'photo_date', 'R2: reason photo_date');
select is((select reason from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14) where reading_id = 'b4000000-0000-4000-8000-000000000009'), 'mismatch', 'R9: a mismatch that also has date lines is still a mismatch');
select is((select photo_date_lines from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14) where reading_id = 'b4000000-0000-4000-8000-000000000002'), array['Electric photo taken Oct 23, checkout Oct 21'], 'R2: the date line is listed');
select is((select photo_date_lines from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14) where reading_id = 'b4000000-0000-4000-8000-000000000003'), array['a', 'b'], 'R3: both date lines, in order');
select is((select photo_date_lines from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14) where reading_id = 'b4000000-0000-4000-8000-000000000001'), '{}'::text[], 'R1: no date lines gives an empty array');
select is((select photo_date_lines from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14) where reading_id = 'b4000000-0000-4000-8000-000000000009'), array['y'], 'R9: the date line of a mismatch is listed too');
select is((select photo_archived from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14) where reading_id = 'b4000000-0000-4000-8000-000000000001'), false, 'R1: both photo objects exist -> not archived');
select is((select photo_archived from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14) where reading_id = 'b4000000-0000-4000-8000-000000000002'), true, 'R2: paths on file, no object -> archived');
select is((select photo_archived from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14) where reading_id = 'b4000000-0000-4000-8000-000000000003'), true, 'R3: the water object is gone -> archived');
select is((select photo_archived from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14) where reading_id = 'b4000000-0000-4000-8000-000000000004'), false, 'R4: the one path has its object and there is no water path -> not archived');
select is((select photo_archived from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14) where reading_id = 'b4000000-0000-4000-8000-000000000009'), false, 'R9: no paths at all -> not archived');
select ok((select typed_electric = 4292 and prev_electric = 4000 and photo_electric = 431.2 and photo_water = 806 and photo_note_electric = 'the dial shows 4 3 1 2' and photo_path_electric = 's104/r1-e.jpg'
             from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14) where reading_id = 'b4000000-0000-4000-8000-000000000001'), 'R1: the existing columns are unchanged');
select ok((select cleaner_name = 'Ana Synthetic' and checkout_date = '2026-10-21'::date from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14) where reading_id = 'b4000000-0000-4000-8000-000000000002'),
  'R2: the cleaner and the checkout day are listed');

select ok(not exists (select 1 from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 30) where reading_id = 'b4000000-0000-4000-8000-000000000010'), 'an unreadable photo with a date line is not listed (it stays with the cleaner follow-up)');
select throws_ok($$select public.admin_resolve_report_block_v1('b4000000-0000-4000-8000-000000000010', 'typed_is_right', null, null, null)$$, '22023', 'That reading is not holding up a report.', 'and it cannot be answered through the admin card either');

-- answering a photo-date finding --------------------------------------------------------------------------------------------------------------------------
select throws_ok($$select public.admin_resolve_report_block_v1('b4000000-0000-4000-8000-000000000006', 'typed_is_right', null, null, null)$$, '22023', 'That reading is not holding up a report.', 'a reading with no finding cannot be answered');
select throws_ok($$select public.admin_resolve_report_block_v1('b4000000-0000-4000-8000-000000000007', 'typed_is_right', null, null, null)$$, '22023', 'That reading has already been answered.', 'an answered finding cannot be answered again');
select is(public.admin_resolve_report_block_v1('b4000000-0000-4000-8000-000000000002', 'typed_is_right', null, null, 'dates are fine') ->> 'ok', 'true', 'typed_is_right works on a photo-date finding');
select is((select count(*) from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000001', 14)), 4::bigint, 'the answered finding left the list');
select is(public.admin_resolve_report_block_v1('b4000000-0000-4000-8000-000000000061', 'correct_numbers', 106, 11.5, 'photo shows 106') ->> 'ok', 'true', 'correct_numbers works on a photo-date finding');

-- the same-day sibling is the next reading ---------------------------------------------------------------------------------------------------------------
select is(public.admin_resolve_report_block_v1('b4000000-0000-4000-8000-000000000022', 'correct_numbers', 4300, 81, null) ->> 'ok', 'true', 'P2: M is corrected to 4300 / 81 (T, the same-day reading, is the next one)');

-- out of order readings and the resend request -------------------------------------------------------------------------------------------------------------
select is((select count(*) from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000012', 14)), 2::bigint, 'P12 lists its two under_review readings');
select ok((select reason = 'meter_order' and resend_requested_at is null and typed_electric = 90 and prev_electric = 100 from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000012', 14) where reading_id = 'b4000000-0000-4000-8000-000000000121'),
  'UR: reason meter_order, no resend yet, the typed number and the last reading are shown');
select throws_ok($$select public.admin_request_meter_resend_v1('b4000000-0000-4000-8000-000000000122', repeat('x', 151))$$, '22023', 'a note is at most 150 characters', 'a resend note over 150 characters is refused');
select throws_ok($$select public.admin_request_meter_resend_v1('b4000000-0000-4000-8000-000000000122', 'mail me at a@b.com')$$, '22023', 'A note cannot hold a phone number, e-mail or amount.', 'a resend note with an e-mail is refused');
select throws_ok($$select public.admin_request_meter_resend_v1('b4000000-0000-4000-8000-0000000000ff', 'please')$$, '42501', 'inspect_cleaning denied', 'a missing id is 42501 for an admin too');
select is(public.admin_request_meter_resend_v1('b4000000-0000-4000-8000-000000000122', 'photo was blurry') ->> 'ok', 'true', 'the resend request succeeds (the guard lets the definer write through)');
select ok((select resend_requested_at is not null and reason = 'meter_order' from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000012', 14) where reading_id = 'b4000000-0000-4000-8000-000000000122'),
  'UR3: still listed, now with resend_requested_at');
select is((select count(*) from public.admin_report_blocks_v1('b1000000-0000-4000-8000-000000000012', 14)), 2::bigint, 'asking for a resend does not resolve the row');
select is(public.admin_resolve_report_block_v1('b4000000-0000-4000-8000-000000000121', 'typed_is_right', null, null, null) ->> 'ok', 'true', 'typed_is_right answers an under_review reading');
select throws_ok($$select public.admin_request_meter_resend_v1('b4000000-0000-4000-8000-000000000121', null)$$, '22023', 'That reading has already been answered.', 'an answered reading cannot be asked for a resend');
select is(public.admin_resolve_report_block_v1('b4000000-0000-4000-8000-000000000131', 'correct_numbers', 110, 11, null) ->> 'ok', 'true', 'correct_numbers answers an under_review reading');
select throws_ok($$select public.admin_resolve_report_block_v1('b4000000-0000-4000-8000-000000000131', 'correct_numbers', 120, 12, null)$$, '22023', 'That reading has already been answered.', 'and it is answered once');
reset role;

select ok((select vision_verdict = 'ok' and meter_flag is null and electric_curr = 102 and vision_resolved_at is null from public.meter_readings where id = 'b4000000-0000-4000-8000-000000000091'),
  'TR: the refused PATCHes left the verdict and the flag alone, the allowed electric change went through');
select ok((select vision_resolved_by = 'b2000000-0000-4000-8000-000000000002' and vision_resolved_note = 'I re-sent the photo' from public.meter_readings where id = 'b4000000-0000-4000-8000-000000000092'),
  'TM: only the follow-up function stamped the answer, with her words');
select ok((select meter_flag is null and vision_resolved_at is not null and vision_resolved_by = 'b2000000-0000-4000-8000-000000000001' and vision_resolved_note = 'Typed numbers confirmed by an admin'
             from public.meter_readings where id = 'b4000000-0000-4000-8000-000000000121'), 'UR: typed_is_right cleared the under_review flag and stamped the admin');
select ok((select meter_flag is null and electric_curr = 110 and water_curr = 11 and electric_delta = 10.00 and kwh_per_night = 5.00 and water_delta = 1.000 and m3_per_night = 0.500 and vision_resolved_at is not null
             from public.meter_readings where id = 'b4000000-0000-4000-8000-000000000131'), 'UR2: corrected to 110 / 11, flag cleared, delta 10.00 / 1.000, per night 5.00 / 0.500');
select ok((select meter_flag = 'under_review' and vision_resolved_at is null and vision_raw ->> 'resend_requested_by' = 'b2000000-0000-4000-8000-000000000001' and vision_raw ->> 'resend_requested_note' = 'photo was blurry'
                  and (vision_raw ->> 'resend_requested_at')::timestamptz > now() - interval '5 minutes'
             from public.meter_readings where id = 'b4000000-0000-4000-8000-000000000122'), 'UR3: the request is stamped (who, when, note) and the row is still under_review and unresolved');
select ok(exists (select 1 from public.admin_audit_log where entity_table = 'meter_readings' and entity_id = 'b4000000-0000-4000-8000-000000000122' and reason like 'Asked the cleaner to resend the meter photo%'), 'the resend request is in the audit history');
select is((select count(*) from public.ops_notices where property_id = 'b1000000-0000-4000-8000-000000000012'), 1::bigint, 'exactly one staff notice was posted for P12');
select ok((select notice_type = 'note' and source = 'system' and audience = 'staff' and is_active and title = 'New meter photo needed'
                  and description = 'Please send a new photo of the meter for the 22 Oct stay (Ysabel). photo was blurry' and expires_at > now() + interval '6 days'
             from public.ops_notices where property_id = 'b1000000-0000-4000-8000-000000000012'), 'the notice: type note, source system, audience staff, the agreed sentence plus the note, 7 days');
select ok((select vision_resolved_note = 'Typed numbers confirmed by an admin: dates are fine' and vision_verdict = 'ok' and vision_resolved_by = 'b2000000-0000-4000-8000-000000000001'
             from public.meter_readings where id = 'b4000000-0000-4000-8000-000000000002'), 'R2: the note, the admin and the untouched verdict are stored');
select ok((select electric_curr = 106 and water_curr = 11.5 and electric_delta = 6.00 and kwh_per_night = 3.00 and water_delta = 1.500 and m3_per_night = 0.750
                  and vision_resolved_note = 'Numbers corrected by an admin from the photo: photo shows 106' and vision_verdict = 'ok'
             from public.meter_readings where id = 'b4000000-0000-4000-8000-000000000061'), 'Q: 106 / 11.5, delta 6.00 / 1.500, per night 3.00 / 0.750, verdict still ok');
select ok((select electric_delta = 300.00 and kwh_per_night = 150.00 and water_delta = 1.000 and m3_per_night = 0.500 from public.meter_readings where id = 'b4000000-0000-4000-8000-000000000022'),
  'M: delta 300.00 / 1.000, per night 150.00 / 0.500');
select ok((select electric_prev = 4300 and electric_delta = 12.00 and kwh_per_night = 12.00 from public.meter_readings where id = 'b4000000-0000-4000-8000-000000000023'), 'T: electric re-pointed to 4300, delta 12.00, per night 12.00');
select ok((select water_prev = 81 and water_delta = 1.500 and m3_per_night = 1.500 from public.meter_readings where id = 'b4000000-0000-4000-8000-000000000023'), 'T: water re-pointed to 81.000, delta 1.500, per night 1.500');
select ok((select electric_prev = 4312 and electric_delta = 18.00 and kwh_per_night = 9.00 and water_prev = 82.500 and water_delta = 0.500 from public.meter_readings where id = 'b4000000-0000-4000-8000-000000000024'),
  'N (the following stay) is not touched');
select ok((select electric_prev = 3990 and electric_delta = 10.00 and water_prev = 79 from public.meter_readings where id = 'b4000000-0000-4000-8000-000000000021'), 'E (earlier the same day) is not touched');
select ok(exists (select 1 from public.admin_audit_log where entity_table = 'meter_readings' and entity_id = 'b4000000-0000-4000-8000-000000000023' and reason like 'Numbers corrected by an admin from the photo%'),
  'the re-pointed same-day reading is in the audit history');

-- follow-ups: the checkout day and the guest ----------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"b2000000-0000-4000-8000-000000000001","aal":"aal1"}';
select is((select count(*) from public.get_meter_photo_followups('b1000000-0000-4000-8000-000000000005', 14)), 2::bigint, 'P5 raises its two sessions');
select is((select array_agg(session_id order by cleaned_at desc) from public.get_meter_photo_followups('b1000000-0000-4000-8000-000000000005', 14)),
  array['b3000000-0000-4000-8000-000000000051', 'b3000000-0000-4000-8000-000000000052']::uuid[], 'newest first, as before');
select ok((select checkout_date = '2026-10-21'::date and guest_name = 'Ysabel' and reason = 'the photo does not show the number that was typed' and vision_verdict = 'mismatch'
             from public.get_meter_photo_followups('b1000000-0000-4000-8000-000000000005', 14) where session_id = 'b3000000-0000-4000-8000-000000000051'), 'SF1: checkout 2026-10-21, guest trimmed to Ysabel, the old columns unchanged');
select ok((select checkout_date is null and guest_name is null and reason = 'the photo could not be read' from public.get_meter_photo_followups('b1000000-0000-4000-8000-000000000005', 14) where session_id = 'b3000000-0000-4000-8000-000000000052'),
  'SF2: no checkout date and a blank guest give nulls');
select ok((select resend_requested_at is not null and reason = 'a new photo of this meter was asked for' and guest_name = 'Ysabel' and checkout_date = '2026-10-22'::date
             from public.get_meter_photo_followups('b1000000-0000-4000-8000-000000000012', 14) where session_id = 'b3000000-0000-4000-8000-000000000122'), 'a resend request raises the session for the cleaner, with the new column');
select is((select count(*) from public.get_meter_photo_followups('b1000000-0000-4000-8000-000000000012', 14)), 1::bigint, 'P12 raises only the requested one');
reset role;

select * from finish();
rollback;
