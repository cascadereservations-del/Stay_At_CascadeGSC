-- s101 "Cleaning reports on hold": admin_report_blocks_v1 (the list) and admin_resolve_report_block_v1 (clear or correct).
--
-- Behavioural, hand-computed. Worked example (property P1): the stay before the held one ended at 4000.00 kWh / 80.000 m3. The held reading M (2 nights) was typed
-- 4292 / 81.852 and the photo reader returned 431.2 / 806 (two decimal misreads), so it is on hold. The next stay N (1 night) was recorded 4312.00 / 82.500 with its
-- previous pointing at M's old numbers (4292.00 / 81.852). A decoy D (flagged estimate_pending, 4299 / 80.9, between M and N) must never act as a neighbour.
-- The admin corrects M to 4300 / 81.000:
--   M  electric delta 4300 - 4000 = 300.00, per night 300 / 2 = 150.00; water delta 81.000 - 80.000 = 1.000, per night 0.500.
--   N  re-pointed: electric prev 4300, delta 4312 - 4300 = 12.00, per night 12.00; water prev 81.000, delta 82.500 - 81.000 = 1.500, per night 1.500.
-- Property P2 holds three mismatch rows for typed_is_right: two inside the 14-day lookback, one 20 days old (listed nowhere, never touched).
-- Every fixture is created inside this transaction and goes with the closing rollback. RPCs are called as authenticated with the jwt claim set like
-- meter_followup_resolution.sql; tables are read after reset role.
begin;
select plan(65);

-- catalogue and grants ------------------------------------------------------------------------------------------------------------------------------
select has_function('public', 'admin_report_blocks_v1', array['uuid', 'integer'], 'admin_report_blocks_v1 exists');
select has_function('public', 'admin_resolve_report_block_v1', array['uuid', 'text', 'numeric', 'numeric', 'text'], 'admin_resolve_report_block_v1 exists');
select is_definer('public', 'admin_report_blocks_v1', array['uuid', 'integer'], 'the list is security definer');
select is_definer('public', 'admin_resolve_report_block_v1', array['uuid', 'text', 'numeric', 'numeric', 'text'], 'the answer is security definer');
select ok(has_function_privilege('authenticated', 'public.admin_report_blocks_v1(uuid,integer)', 'execute') and not has_function_privilege('anon', 'public.admin_report_blocks_v1(uuid,integer)', 'execute'), 'list: authenticated yes, anon no');
select ok(has_function_privilege('authenticated', 'public.admin_resolve_report_block_v1(uuid,text,numeric,numeric,text)', 'execute') and not has_function_privilege('anon', 'public.admin_resolve_report_block_v1(uuid,text,numeric,numeric,text)', 'execute'), 'answer: authenticated yes, anon no');
select ok(not has_function_privilege('service_role', 'public.admin_report_blocks_v1(uuid,integer)', 'execute') and not has_function_privilege('service_role', 'public.admin_resolve_report_block_v1(uuid,text,numeric,numeric,text)', 'execute'), 'neither is granted to service_role');

-- people and properties -----------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values
 ('e1000000-0000-4000-8000-000000000001', 'S101 held readings', true),
 ('e1000000-0000-4000-8000-000000000002', 'S101 typed is right', true),
 ('e1000000-0000-4000-8000-000000000003', 'S101 other', true) on conflict (id) do nothing;
insert into auth.users(id) values
 ('e2000000-0000-4000-8000-000000000001'), ('e2000000-0000-4000-8000-000000000002'), ('e2000000-0000-4000-8000-000000000003') on conflict (id) do nothing;
insert into public.staff_access_profiles(user_id, role, disabled_at, sessions_revoked_after) values
 ('e2000000-0000-4000-8000-000000000001', 'admin', null, null),
 ('e2000000-0000-4000-8000-000000000002', 'cleaner', null, null),
 ('e2000000-0000-4000-8000-000000000003', 'cleaner', null, null)
on conflict (user_id) do update set role = excluded.role, disabled_at = null, sessions_revoked_after = null;
insert into public.staff_property_access(user_id, property_id) values
 ('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001'),
 ('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000002'),
 ('e2000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001'),
 ('e2000000-0000-4000-8000-000000000003', 'e1000000-0000-4000-8000-000000000003') on conflict do nothing;

-- P1: M (held), D (decoy, no photo), N (next stay) ---------------------------------------------------------------------------------------------------
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, nights_stayed, checkout_date, cleaned_at) values
 ('e3000000-0000-4000-8000-000000000001', 's101-m', 'Honey Synthetic', 'e1000000-0000-4000-8000-000000000001', 'turnover', 'e2000000-0000-4000-8000-000000000002', 2, current_date - 5, now() - interval '3 days'),
 ('e3000000-0000-4000-8000-000000000002', 's101-d', 'Decoy Synthetic', 'e1000000-0000-4000-8000-000000000001', 'turnover', 'e2000000-0000-4000-8000-000000000002', 1, current_date - 4, now() - interval '2 days'),
 ('e3000000-0000-4000-8000-000000000003', 's101-n', 'Next Synthetic', 'e1000000-0000-4000-8000-000000000001', 'turnover', 'e2000000-0000-4000-8000-000000000002', 1, current_date - 3, now() - interval '1 day');
insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, recorded_at, electric_prev, electric_curr, electric_delta, water_prev, water_curr, water_delta,
                                  kwh_per_night, m3_per_night, vision_electric, vision_water, vision_verdict, vision_raw, meter_flag) values
 ('e4000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000002', now() - interval '3 days',
  4000.00, 4292, 292.00, 80.000, 81.852, 1.852, 146.00, 0.926, 431.2, 806, 'mismatch',
  '{"electric":{"reading":431.2,"note":"the dial shows 4 3 1 2 with the last digit red"},"water":{"reading":806,"note":"the decimal point is hidden"},"paths":{"electric":"s101/m-electric.jpg","water":"s101/m-water.jpg"}}'::jsonb, null),
 ('e4000000-0000-4000-8000-000000000002', 'e3000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000002', now() - interval '2 days',
  null, 4299, null, null, 80.9, null, null, null, null, null, null, null, 'estimate_pending'),
 ('e4000000-0000-4000-8000-000000000003', 'e3000000-0000-4000-8000-000000000003', 'e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000002', now() - interval '1 day',
  4292.00, 4312, 20.00, 81.852, 82.500, 0.648, 20.00, 0.648, 4312, 82.5, 'ok', null, null);

-- P2: three mismatch rows with no session; M4 is 20 days old ----------------------------------------------------------------------------------------
insert into public.meter_readings(id, property_id, recorded_at, electric_curr, water_curr, vision_verdict) values
 ('e4000000-0000-4000-8000-000000000012', 'e1000000-0000-4000-8000-000000000002', now() - interval '2 days', 4292, 81.852, 'mismatch'),
 ('e4000000-0000-4000-8000-000000000013', 'e1000000-0000-4000-8000-000000000002', now() - interval '1 day', 4300, 82, 'mismatch'),
 ('e4000000-0000-4000-8000-000000000014', 'e1000000-0000-4000-8000-000000000002', now() - interval '20 days', 4100, 80, 'mismatch');

-- the cleaner of P1 may read the list (read_operations) but not answer it; a cleaner of another property may do neither -------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e2000000-0000-4000-8000-000000000002","aal":"aal1"}';
select is((select count(*) from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000001', 14)), 1::bigint, 'the list holds exactly the one mismatch of P1');
select is((select reading_id from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000001', 14)), 'e4000000-0000-4000-8000-000000000001'::uuid, 'it is the held reading');
select is((select typed_electric from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000001', 14)), 4292::numeric, 'typed electric is shown');
select is((select prev_electric from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000001', 14)), 4000::numeric, 'the last reading is shown');
select is((select photo_electric from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000001', 14)), 431.2::numeric, 'the photo reader electric number is shown');
select is((select photo_water from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000001', 14)), 806::numeric, 'the photo reader water number is shown');
select is((select photo_note_water from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000001', 14)), 'the decimal point is hidden', 'the reader note comes from vision_raw');
select is((select photo_path_electric from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000001', 14)), 's101/m-electric.jpg', 'the photo path comes from vision_raw');
select is((select cleaner_name from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000001', 14)), 'Honey Synthetic', 'the cleaner is named');
select is((select checkout_date from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000001', 14)), current_date - 5, 'the stay is named by its check-out date');
select throws_ok($$select * from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000002', 14)$$, '42501', null, 'a cleaner without access to the property cannot list it');
select throws_ok($$select public.admin_resolve_report_block_v1('e4000000-0000-4000-8000-000000000001', 'typed_is_right', null, null, null)$$, '42501', null, 'a cleaner cannot clear a held report (inspect_cleaning)');
set local request.jwt.claims = '{"sub":"e2000000-0000-4000-8000-000000000003","aal":"aal1"}';
select throws_ok($$select * from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000001', 14)$$, '42501', null, 'a cleaner of another property cannot list P1');
select throws_ok($$select public.admin_resolve_report_block_v1('e4000000-0000-4000-8000-000000000001', 'typed_is_right', null, null, null)$$, '42501', null, 'a cleaner of another property cannot clear it');

-- the admin: every refusal first, nothing may be written ------------------------------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"e2000000-0000-4000-8000-000000000001","aal":"aal1"}';
select throws_ok($$select public.admin_resolve_report_block_v1('e4000000-0000-4000-8000-000000000001', 'delete_it', null, null, null)$$, '22023', null, 'an unknown action is refused');
select throws_ok($$select public.admin_resolve_report_block_v1('e4000000-0000-4000-8000-000000000001', 'correct_numbers', 4300, null, null)$$, '22023', null, 'correct_numbers needs the water number');
select throws_ok($$select public.admin_resolve_report_block_v1('e4000000-0000-4000-8000-000000000001', 'correct_numbers', null, 81, null)$$, '22023', null, 'correct_numbers needs the electric number');
select throws_ok($$select public.admin_resolve_report_block_v1('e4000000-0000-4000-8000-000000000001', 'correct_numbers', 0, 81, null)$$, '22023', null, 'zero is not a reading');
select throws_ok($$select public.admin_resolve_report_block_v1('e4000000-0000-4000-8000-000000000001', 'correct_numbers', 3999, 81, null)$$, '22023', null, 'electric below the last reading is refused');
select throws_ok($$select public.admin_resolve_report_block_v1('e4000000-0000-4000-8000-000000000001', 'correct_numbers', 4300, 79, null)$$, '22023', null, 'water below the last reading is refused');
select throws_ok($$select public.admin_resolve_report_block_v1('e4000000-0000-4000-8000-000000000001', 'correct_numbers', 4313, 81, null)$$, '22023', null, 'electric above the next stay is refused');
select throws_ok($$select public.admin_resolve_report_block_v1('e4000000-0000-4000-8000-000000000001', 'correct_numbers', 4300, 82.6, null)$$, '22023', null, 'water above the next stay is refused');
select throws_ok($$select public.admin_resolve_report_block_v1('e4000000-0000-4000-8000-0000000000ff', 'typed_is_right', null, null, null)$$, '22023', null, 'an unknown reading is refused');
select throws_ok($$select public.admin_resolve_report_block_v1('e4000000-0000-4000-8000-000000000003', 'typed_is_right', null, null, null)$$, '22023', null, 'a reading that holds nothing up cannot be answered');
select is((select count(*) from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000001', 14)), 1::bigint, 'after the refusals the report is still on hold');

-- correct the numbers --------------------------------------------------------------------------------------------------------------------------------
select is(public.admin_resolve_report_block_v1('e4000000-0000-4000-8000-000000000001', 'correct_numbers', 4300, 81, 're-read from the photo') ->> 'ok', 'true', 'correct_numbers succeeds (the decoy is not a neighbour)');
select throws_ok($$select public.admin_resolve_report_block_v1('e4000000-0000-4000-8000-000000000001', 'typed_is_right', null, null, null)$$, '22023', null, 'a second answer is refused: already answered');
select is((select count(*) from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000001', 14)), 0::bigint, 'the list is empty once it is answered');
reset role;

select is((select electric_curr from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000001'), 4300::numeric, 'M electric is the corrected number');
select is((select water_curr from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000001'), 81::numeric, 'M water is the corrected number');
select is((select electric_delta from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000001'), 300::numeric, 'M electric delta 4300 - 4000');
select is((select water_delta from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000001'), 1::numeric, 'M water delta 81.000 - 80.000');
select is((select kwh_per_night from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000001'), 150::numeric, 'M kWh per night 300 / 2');
select is((select m3_per_night from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000001'), 0.5::numeric, 'M m3 per night 1 / 2');
select is((select vision_resolved_by from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000001'), 'e2000000-0000-4000-8000-000000000001'::uuid, 'it names the admin who answered');
select is((select vision_resolved_note from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000001'), 'Numbers corrected by an admin from the photo: re-read from the photo', 'the note says what was done');
select is((select vision_verdict from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000001'), 'mismatch', 'the finding itself is not erased');
select is((select electric_prev from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000003'), 4300::numeric, 'N electric previous re-pointed to 4300');
select is((select electric_delta from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000003'), 12::numeric, 'N electric delta 4312 - 4300');
select is((select kwh_per_night from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000003'), 12::numeric, 'N kWh per night 12 / 1');
select is((select water_prev from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000003'), 81::numeric, 'N water previous re-pointed to 81.000');
select is((select water_delta from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000003'), 1.5::numeric, 'N water delta 82.500 - 81.000');
select is((select m3_per_night from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000003'), 1.5::numeric, 'N m3 per night 1.5 / 1');
select ok((select electric_prev is null and electric_delta is null and water_prev is null and meter_flag = 'estimate_pending' and electric_curr = 4299 from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000002'), 'the no-photo decoy was not touched');
-- submit-cleaning's block query (index.ts, METER_BLOCK_LOOKBACK_DAYS = 14), copied
select is((select count(*) from public.meter_readings where property_id = 'e1000000-0000-4000-8000-000000000001' and vision_verdict = 'mismatch' and vision_resolved_at is null and recorded_at >= now() - interval '14 days'), 0::bigint, 'submit-cleaning no longer finds a block on P1');
select ok(exists (select 1 from public.admin_audit_log where entity_table = 'meter_readings' and entity_id = 'e4000000-0000-4000-8000-000000000001' and actor_user_id = 'e2000000-0000-4000-8000-000000000001' and reason like 'Numbers corrected by an admin from the photo%'), 'the correction is in the audit history');
select ok(exists (select 1 from public.admin_audit_log where entity_table = 'meter_readings' and entity_id = 'e4000000-0000-4000-8000-000000000003' and reason like 'Numbers corrected by an admin from the photo%'), 'so is the re-pointed next stay');

-- typed numbers are right -----------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e2000000-0000-4000-8000-000000000001","aal":"aal1"}';
select is((select count(*) from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000002', 14)), 2::bigint, 'P2 lists its two recent mismatches and not the 20-day-old one');
select is((select cleaner_name from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000002', 14) limit 1), null, 'a row with no session still lists');
select is(public.admin_resolve_report_block_v1('e4000000-0000-4000-8000-000000000012', 'typed_is_right', null, null, 'photo is blurry') ->> 'action', 'typed_is_right', 'typed_is_right succeeds with a note');
select is((select count(*) from public.admin_report_blocks_v1('e1000000-0000-4000-8000-000000000002', 14)), 1::bigint, 'one is left on hold');
select is(public.admin_resolve_report_block_v1('e4000000-0000-4000-8000-000000000013', 'typed_is_right', null, null, null) ->> 'ok', 'true', 'typed_is_right succeeds without a note');
reset role;
select is((select vision_resolved_note from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000012'), 'Typed numbers confirmed by an admin: photo is blurry', 'the note is kept after the standard sentence');
select is((select vision_resolved_note from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000013'), 'Typed numbers confirmed by an admin', 'with no note only the standard sentence is kept');
select ok((select electric_curr = 4292 and water_curr = 81.852 and vision_resolved_by = 'e2000000-0000-4000-8000-000000000001' from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000012'), 'typed_is_right leaves the numbers as typed and names the admin');
select is((select count(*) from public.meter_readings where property_id = 'e1000000-0000-4000-8000-000000000002' and vision_verdict = 'mismatch' and vision_resolved_at is null and recorded_at >= now() - interval '14 days'), 0::bigint, 'submit-cleaning no longer finds a block on P2');
select is((select vision_resolved_at from public.meter_readings where id = 'e4000000-0000-4000-8000-000000000014'), null, 'the 20-day-old row was never touched');
select ok(exists (select 1 from public.admin_audit_log where entity_table = 'meter_readings' and entity_id = 'e4000000-0000-4000-8000-000000000012' and reason = 'Typed numbers confirmed by an admin: photo is blurry'), 'typed_is_right is in the audit history');

select * from finish();
rollback;