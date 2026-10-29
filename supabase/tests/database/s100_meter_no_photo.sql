-- s100 (D-352) "No meter photo was taken": the stay-order skip rule, the cleaner's report and the settle job.
--
-- Behavioural, hand-computed. The worked example is the contract's: Abe 4240 / 80.699 (check-out 17 Oct, 1 night), Shaneen pending 4273 / 81.58 (19 Oct, 2 nights),
-- Ysabel pending (21 Oct, 1 night), James verified 4312 / 82.5 (22 Oct, 1 night). Electric usage 72 over 4 nights = 18 a night: Shaneen 4240 + 36 = 4276.00,
-- Ysabel 4240 + 54 = 4294.00, James prev 4294.00 delta 18.00. Water 1.801 over 4 nights: Shaneen 80.699 + 0.9005 = 81.5995 -> 81.600, Ysabel 80.699 + 1.35075 = 82.04975 -> 82.050.
-- Every fixture is created inside this transaction and goes with the closing rollback. RPCs are called as authenticated with the jwt claim set like
-- meter_followup_resolution.sql; tables are read after reset role.
begin;
select plan(99);

-- catalogue and grants ------------------------------------------------------------------------------------------------------------------------------
select has_table('public', 'meter_skip_exceptions', 'meter_skip_exceptions exists');
select ok((select relrowsecurity from pg_class where oid = 'public.meter_skip_exceptions'::regclass), 'meter_skip_exceptions has RLS on');
select ok(not has_table_privilege('authenticated', 'public.meter_skip_exceptions', 'select'), 'authenticated cannot read the exceptions table');
select has_function('public', 'can_skip_meter_photos_v2', array['uuid', 'date'], 'can_skip_meter_photos_v2 exists');
select has_function('public', 'report_no_meter_photo_v1', array['uuid', 'text'], 'report_no_meter_photo_v1 exists');
select has_function('public', 'meter_settle_estimates_v1', array['uuid'], 'meter_settle_estimates_v1 exists');
select has_function('public', 'meter_no_photo_notice_v1', array['uuid'], 'meter_no_photo_notice_v1 exists');
select ok(has_function_privilege('authenticated', 'public.can_skip_meter_photos_v2(uuid,date)', 'execute') and not has_function_privilege('anon', 'public.can_skip_meter_photos_v2(uuid,date)', 'execute'), 'v2: authenticated yes, anon no');
select ok(has_function_privilege('authenticated', 'public.report_no_meter_photo_v1(uuid,text)', 'execute') and not has_function_privilege('anon', 'public.report_no_meter_photo_v1(uuid,text)', 'execute'), 'report: authenticated yes, anon no');
select ok(has_function_privilege('service_role', 'public.meter_settle_estimates_v1(uuid)', 'execute') and not has_function_privilege('authenticated', 'public.meter_settle_estimates_v1(uuid)', 'execute') and not has_function_privilege('anon', 'public.meter_settle_estimates_v1(uuid)', 'execute'), 'settle: service_role only');
select ok(has_function_privilege('service_role', 'public.meter_no_photo_notice_v1(uuid)', 'execute') and not has_function_privilege('authenticated', 'public.meter_no_photo_notice_v1(uuid)', 'execute'), 'notice: service_role only');
select ok(not has_function_privilege('authenticated', 'public.s_meter_skip_check_v1(uuid,date,uuid)', 'execute') and not has_function_privilege('service_role', 'public.s_meter_skip_check_v1(uuid,date,uuid)', 'execute'), 'the internal rule has no grants');
select ok((select position('estimate_pending' in prosrc) > 0 and position('typed_accepted' in prosrc) > 0 and position('''estimated''' in prosrc) > 0 from pg_proc where oid = 'public.review_meter_reading_v1(uuid,text,text)'::regprocedure), 'review_meter_reading_v1 whitelists the three new flags');
select ok(has_function_privilege('authenticated', 'public.review_meter_reading_v1(uuid,text,text)', 'execute') and not has_function_privilege('anon', 'public.review_meter_reading_v1(uuid,text,text)', 'execute') and not has_function_privilege('service_role', 'public.review_meter_reading_v1(uuid,text,text)', 'execute'), 'review_meter_reading_v1 keeps its grants: authenticated only');

-- people and properties -----------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values
 ('d1000000-0000-4000-8000-000000000001', 'S100 settle fail', true),
 ('d1000000-0000-4000-8000-000000000002', 'S100 settle pass', true),
 ('d1000000-0000-4000-8000-000000000003', 'S100 settle wait missing', true),
 ('d1000000-0000-4000-8000-000000000004', 'S100 settle wait unchecked', true),
 ('d1000000-0000-4000-8000-000000000005', 'S100 stay order', true),
 ('d1000000-0000-4000-8000-000000000006', 'S100 report', true),
 ('d1000000-0000-4000-8000-000000000007', 'S100 other', true),
 ('d1000000-0000-4000-8000-000000000008', 'S100 waiting old', true),
 ('d1000000-0000-4000-8000-000000000009', 'S100 waiting recent', true),
 ('d1000000-0000-4000-8000-00000000000a', 'S100 water only', true) on conflict (id) do nothing;
insert into auth.users(id) values
 ('d2000000-0000-4000-8000-000000000001'), ('d2000000-0000-4000-8000-000000000002'),
 ('d2000000-0000-4000-8000-000000000003'), ('d2000000-0000-4000-8000-000000000004') on conflict (id) do nothing;
insert into public.staff_access_profiles(user_id, role, disabled_at, sessions_revoked_after) values
 ('d2000000-0000-4000-8000-000000000001', 'cleaner', null, null),
 ('d2000000-0000-4000-8000-000000000002', 'cleaner', null, null),
 ('d2000000-0000-4000-8000-000000000003', 'cleaner', null, null),
 ('d2000000-0000-4000-8000-000000000004', 'admin', null, null)
on conflict (user_id) do update set role = excluded.role, disabled_at = null, sessions_revoked_after = null;
insert into public.staff_property_access(user_id, property_id) values
 ('d2000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000005'),
 ('d2000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000006'),
 ('d2000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000007'),
 ('d2000000-0000-4000-8000-000000000003', 'd1000000-0000-4000-8000-000000000006'),
 ('d2000000-0000-4000-8000-000000000004', 'd1000000-0000-4000-8000-000000000006') on conflict do nothing;

-- the contract's worked example: 4 stays, A verified, two pending, B verified (or not) --------------------------------------------------------------
create function pg_temp.s100_fixture(p_prop uuid, p_tag text, p_ys_e numeric, p_ys_w numeric, p_james text) returns void language plpgsql as $f$
declare v_u constant uuid := 'd2000000-0000-4000-8000-000000000001';
begin
  insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date) values
    (p_prop, p_tag || '-17', 'airbnb', 'confirmed', '2026-10-16', '2026-10-17'),
    (p_prop, p_tag || '-19', 'airbnb', 'confirmed', '2026-10-17', '2026-10-19'),
    (p_prop, p_tag || '-21', 'airbnb', 'confirmed', '2026-10-20', '2026-10-21'),
    (p_prop, p_tag || '-22', 'airbnb', 'confirmed', '2026-10-21', '2026-10-22');
  insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, last_guest_name, nights_stayed, checkout_date, cleaned_at) values
    (md5(p_tag || 'abe')::uuid, p_tag || '-abe', 'Synthetic Cleaner', p_prop, 'turnover', v_u, 'Abe', 1, '2026-10-17', '2026-10-17 12:00+08'),
    (md5(p_tag || 'sha')::uuid, p_tag || '-sha', 'Synthetic Cleaner', p_prop, 'turnover', v_u, 'Shaneen', 2, '2026-10-19', '2026-10-28 07:22+08'),
    (md5(p_tag || 'ysa')::uuid, p_tag || '-ysa', 'Synthetic Cleaner', p_prop, 'turnover', v_u, 'Ysabel', 1, '2026-10-21', '2026-10-29 09:00+08');
  insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, electric_curr, water_curr, vision_verdict, meter_flag) values
    (md5(p_tag || 'abe-m')::uuid, md5(p_tag || 'abe')::uuid, p_prop, v_u, 4240, 80.699, 'ok', null),
    (md5(p_tag || 'sha-m')::uuid, md5(p_tag || 'sha')::uuid, p_prop, v_u, 4273, 81.58, 'mismatch', 'estimate_pending'),
    (md5(p_tag || 'ysa-m')::uuid, md5(p_tag || 'ysa')::uuid, p_prop, v_u, p_ys_e, p_ys_w, null, 'estimate_pending');
  if p_james <> 'none' then
    insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, last_guest_name, nights_stayed, checkout_date, cleaned_at)
    values (md5(p_tag || 'jam')::uuid, p_tag || '-jam', 'Synthetic Cleaner', p_prop, 'turnover', v_u, 'James', 1, '2026-10-22', '2026-10-30 09:00+08');
    insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, electric_curr, water_curr, vision_verdict, meter_flag)
    values (md5(p_tag || 'jam-m')::uuid, md5(p_tag || 'jam')::uuid, p_prop, v_u, 4312, 82.5, case p_james when 'ok' then 'ok' else null end, null);
  end if;
end $f$;

select pg_temp.s100_fixture('d1000000-0000-4000-8000-000000000001', 'p1', 4200, 81.0, 'ok');
select pg_temp.s100_fixture('d1000000-0000-4000-8000-000000000002', 'p2', 4290, 82.0, 'ok');
select pg_temp.s100_fixture('d1000000-0000-4000-8000-000000000003', 'p3', 4200, 81.0, 'none');
select pg_temp.s100_fixture('d1000000-0000-4000-8000-000000000004', 'p4', 4200, 81.0, 'unchecked');

-- settle: the fail case (Ysabel typed below Abe) -> the contract's exact averaged numbers ----------------------------------------------------------
select is(public.meter_settle_estimates_v1('d1000000-0000-4000-8000-000000000001') ->> 'settled', '1', 'fail case: one gap settled');
select is((select electric_curr from public.meter_readings where id = md5('p1sha-m')::uuid), 4276.00::numeric, 'Shaneen electric 4276.00');
select is((select water_curr from public.meter_readings where id = md5('p1sha-m')::uuid), 81.600::numeric, 'Shaneen water 81.600 (81.5995 rounded to 3 dp)');
select is((select electric_curr from public.meter_readings where id = md5('p1ysa-m')::uuid), 4294.00::numeric, 'Ysabel electric 4294.00');
select is((select water_curr from public.meter_readings where id = md5('p1ysa-m')::uuid), 82.050::numeric, 'Ysabel water 82.050 (82.04975 rounded)');
select is((select count(*) from public.meter_readings where id in (md5('p1sha-m')::uuid, md5('p1ysa-m')::uuid) and meter_flag = 'estimated'
             and meter_override_note = 'D-352 electric per-night average between 2026-10-17 and 2026-10-22; water per-night average between 2026-10-17 and 2026-10-22'), 2::bigint, 'both pending rows are estimated and say which meters and between which dates');
select is((select electric_prev from public.meter_readings where id = md5('p1jam-m')::uuid), 4294.00::numeric, 'James prev is the last pending value');
select is((select electric_delta from public.meter_readings where id = md5('p1jam-m')::uuid), 18.00::numeric, 'James delta 18.00');
select is((select water_prev from public.meter_readings where id = md5('p1jam-m')::uuid), 82.050::numeric, 'James water prev 82.050');
select is((select count(*) from public.meter_readings where id = md5('p1jam-m')::uuid and meter_flag is null and electric_curr = 4312 and water_curr = 82.5), 1::bigint, 'James keeps his own numbers and stays unflagged');
select is((select electric_prev from public.meter_readings where id = md5('p1sha-m')::uuid), 4240.00::numeric, 'Shaneen prev is Abe');
select is((select electric_delta from public.meter_readings where id = md5('p1sha-m')::uuid), 36.00::numeric, 'Shaneen delta 36.00');
select is((select kwh_per_night from public.meter_readings where id = md5('p1sha-m')::uuid), 18.00::numeric, 'Shaneen 18.00 kWh a night');
select is((select count(*) from public.follow_up_tasks where source_kind = 'meter_estimate_settled' and source_ref = md5('p1jam')::uuid::text and title like 'Meter readings settled for %Shaneen%'), 1::bigint, 'one settled task, on the next stay');

-- idempotence: a second run changes nothing -----------------------------------------------------------------------------------------------------------
create temp table s100_snap as
  select md5(string_agg(mr.id::text || coalesce(mr.electric_curr::text, '') || coalesce(mr.electric_prev::text, '') || coalesce(mr.water_curr::text, '') || coalesce(mr.water_prev::text, '')
         || coalesce(mr.meter_flag, '') || coalesce(mr.meter_override_note, ''), '|' order by mr.id)) as h
  from public.meter_readings mr where mr.property_id = 'd1000000-0000-4000-8000-000000000001';
select is(public.meter_settle_estimates_v1('d1000000-0000-4000-8000-000000000001') ->> 'rows', '0', 'second run touches no row');
select is((select md5(string_agg(mr.id::text || coalesce(mr.electric_curr::text, '') || coalesce(mr.electric_prev::text, '') || coalesce(mr.water_curr::text, '') || coalesce(mr.water_prev::text, '')
         || coalesce(mr.meter_flag, '') || coalesce(mr.meter_override_note, ''), '|' order by mr.id)) from public.meter_readings mr where mr.property_id = 'd1000000-0000-4000-8000-000000000001'),
          (select h from s100_snap), 'second run leaves every value and flag as it was');
select is((select count(*) from public.follow_up_tasks where source_kind = 'meter_estimate_settled' and source_ref = md5('p1jam')::uuid::text), 1::bigint, 'second run opens no second task');

-- settle: the pass case keeps the typed numbers -----------------------------------------------------------------------------------------------------
select is(public.meter_settle_estimates_v1('d1000000-0000-4000-8000-000000000002') ->> 'settled', '1', 'pass case: one gap settled');
select is((select count(*) from public.meter_readings where (id, electric_curr, water_curr) in ((md5('p2sha-m')::uuid, 4273.00, 81.58), (md5('p2ysa-m')::uuid, 4290.00, 82.0))), 2::bigint, 'typed numbers kept exactly');
select is((select count(*) from public.meter_readings where id in (md5('p2sha-m')::uuid, md5('p2ysa-m')::uuid) and meter_flag = 'typed_accepted' and meter_override_note is null), 2::bigint, 'flagged typed_accepted, no override note');
select is((select electric_prev from public.meter_readings where id = md5('p2ysa-m')::uuid), 4273.00::numeric, 'pass case chain: Ysabel prev is Shaneen');
select is((select electric_delta from public.meter_readings where id = md5('p2jam-m')::uuid), 22.00::numeric, 'pass case chain: James delta 22.00 from Ysabel');

-- settle: waiting ------------------------------------------------------------------------------------------------------------------------------------
select is(public.meter_settle_estimates_v1('d1000000-0000-4000-8000-000000000003') ->> 'waiting', '1', 'B missing: the gap waits');
select is((select count(*) from public.meter_readings where property_id = 'd1000000-0000-4000-8000-000000000003' and meter_flag = 'estimate_pending' and electric_curr in (4273, 4200)), 2::bigint, 'B missing: both rows stay pending with their typed numbers');
select is(public.meter_settle_estimates_v1('d1000000-0000-4000-8000-000000000004') ->> 'waiting', '1', 'B not vision ok (unchecked): the gap waits');
select is((select count(*) from public.meter_readings where property_id = 'd1000000-0000-4000-8000-000000000004' and meter_flag = 'estimate_pending'), 2::bigint, 'B unchecked: both rows stay pending');
select is(public.meter_settle_estimates_v1('d1000000-0000-4000-8000-000000000003') ->> 'settled', '0', 'B missing: nothing settled');
select is((select count(*) from public.meter_readings where (id, electric_curr, water_curr, meter_flag) in ((md5('p3sha-m')::uuid, 4273, 81.58, 'estimate_pending'), (md5('p3ysa-m')::uuid, 4200, 81.0, 'estimate_pending')) and electric_prev is null and electric_delta is null), 2::bigint, 'B missing: the pending rows keep their typed numbers and gain no prev/delta');
select is(public.meter_settle_estimates_v1('d1000000-0000-4000-8000-000000000004') ->> 'settled', '0', 'B unchecked: nothing settled');
select is((select count(*) from public.meter_readings where (id, electric_curr, water_curr, meter_flag) in ((md5('p4sha-m')::uuid, 4273, 81.58, 'estimate_pending'), (md5('p4ysa-m')::uuid, 4200, 81.0, 'estimate_pending')) and electric_prev is null and electric_delta is null), 2::bigint, 'B unchecked: the pending rows keep their typed numbers and gain no prev/delta');
-- the next stay's report arrives, verified: now it settles
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, last_guest_name, nights_stayed, checkout_date, cleaned_at)
values (md5('p3jam')::uuid, 'p3-jam', 'Synthetic Cleaner', 'd1000000-0000-4000-8000-000000000003', 'turnover', 'd2000000-0000-4000-8000-000000000001', 'James', 1, '2026-10-22', '2026-10-30 09:00+08');
insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, electric_curr, water_curr, vision_verdict, meter_flag)
values (md5('p3jam-m')::uuid, md5('p3jam')::uuid, 'd1000000-0000-4000-8000-000000000003', 'd2000000-0000-4000-8000-000000000001', 4312, 82.5, 'ok', null);
select is(public.meter_settle_estimates_v1('d1000000-0000-4000-8000-000000000003') ->> 'settled', '1', 'once the next stay is verified the waiting gap settles');
select is((select electric_curr from public.meter_readings where id = md5('p3ysa-m')::uuid), 4294.00::numeric, 'and the average lands (Ysabel 4294.00)');

-- F2 / F5: a mini gap: A verified 100 / 10, one pending stay (Gwen, 2 nights), the next stay B (2 nights, 140 / 12 when it has filed) ----------------------------
create function pg_temp.s100_mini(p_prop uuid, p_tag text, p_a date, p_e numeric, p_w numeric, p_b boolean) returns void language plpgsql as $f$
declare v_u constant uuid := 'd2000000-0000-4000-8000-000000000001';
begin
  insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date) values
    (p_prop, p_tag || '-a', 'airbnb', 'confirmed', p_a - 1, p_a),
    (p_prop, p_tag || '-p', 'airbnb', 'confirmed', p_a, p_a + 2),
    (p_prop, p_tag || '-b', 'airbnb', 'confirmed', p_a + 2, p_a + 4);
  insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, last_guest_name, nights_stayed, checkout_date, cleaned_at) values
    (md5(p_tag || 'a')::uuid, p_tag || '-a', 'Synthetic Cleaner', p_prop, 'turnover', v_u, 'Abe', 1, p_a, '2026-06-01 12:00+08'),
    (md5(p_tag || 'p')::uuid, p_tag || '-p', 'Synthetic Cleaner', p_prop, 'turnover', v_u, 'Gwen', 2, p_a + 2, '2026-06-02 12:00+08');
  insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, electric_curr, water_curr, vision_verdict, meter_flag) values
    (md5(p_tag || 'a-m')::uuid, md5(p_tag || 'a')::uuid, p_prop, v_u, 100, 10, 'ok', null),
    (md5(p_tag || 'p-m')::uuid, md5(p_tag || 'p')::uuid, p_prop, v_u, p_e, p_w, null, 'estimate_pending');
  if p_b then
    insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, last_guest_name, nights_stayed, checkout_date, cleaned_at)
    values (md5(p_tag || 'b')::uuid, p_tag || '-b', 'Synthetic Cleaner', p_prop, 'turnover', v_u, 'Hal', 2, p_a + 4, '2026-06-03 12:00+08');
    insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, electric_curr, water_curr, vision_verdict, meter_flag)
    values (md5(p_tag || 'b-m')::uuid, md5(p_tag || 'b')::uuid, p_prop, v_u, 140, 12, 'ok', null);
  end if;
end $f$;
-- 8: the last pending stay checked out long ago (2026-08-05) and B never filed; 9: it checked out 4 days ago; 10: water below A, electric in order, B verified.
select pg_temp.s100_mini('d1000000-0000-4000-8000-000000000008', 'w8', date '2026-08-03', 120, 12, false);
select pg_temp.s100_mini('d1000000-0000-4000-8000-000000000009', 'w9', ((now() at time zone 'Asia/Manila')::date - 6), 120, 12, false);
select pg_temp.s100_mini('d1000000-0000-4000-8000-00000000000a', 'wa', date '2026-06-03', 120, 9, true);

select is(public.meter_settle_estimates_v1('d1000000-0000-4000-8000-000000000008') ->> 'waiting', '1', 'F2: an old gap with no B waits');
select is((select count(*) from public.follow_up_tasks where source_kind = 'meter_estimate_waiting' and source_ref = md5('w8p')::uuid::text and priority = 'low' and status = 'open'
             and title = 'Meter readings waiting for the next stay''s report' and detail like 'The meter readings of Gwen are still estimates. The report for the next stay (checking out 7 Aug) has not been filed%'), 1::bigint, 'F2: and opens one low task that says which stay and which report');
select is(public.meter_settle_estimates_v1('d1000000-0000-4000-8000-000000000008') ->> 'waiting', '1', 'F2: a second run still waits');
select is((select count(*) from public.follow_up_tasks where source_kind = 'meter_estimate_waiting' and source_ref = md5('w8p')::uuid::text), 1::bigint, 'F2: and opens no second task');
select is(public.meter_settle_estimates_v1('d1000000-0000-4000-8000-000000000009') ->> 'waiting', '1', 'F2: a recent gap with no B waits');
select is((select count(*) from public.follow_up_tasks where source_kind = 'meter_estimate_waiting' and property_id = 'd1000000-0000-4000-8000-000000000009'), 0::bigint, 'F2: a gap under 7 days old opens no task');

select is(public.meter_settle_estimates_v1('d1000000-0000-4000-8000-00000000000a') ->> 'settled', '1', 'F5: water-only gap settles');
select is((select count(*) from public.meter_readings where id = md5('wap-m')::uuid and electric_curr = 120.00 and water_curr = 11.000 and meter_flag = 'estimated'), 1::bigint,
          'F5: electric kept, water 10 + 2 x 2 / 4 = 11.000, flag estimated');
select is((select meter_override_note from public.meter_readings where id = md5('wap-m')::uuid), 'D-352 water per-night average between 2026-06-03 and 2026-06-07',
          'F5: the note names water and the dates, not electric');

-- stay order: can_skip_meter_photos_v2 -----------------------------------------------------------------------------------------------------------------
-- stays check out 10, 12, 14, 16 Sep. The 10 Sep report (no photos) was filed LAST; the 14 Sep report was filed earlier. A blocked calendar row is not a stay.
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date) values
 ('d1000000-0000-4000-8000-000000000005', 'o-10', 'airbnb', 'confirmed', '2026-09-09', '2026-09-10'),
 ('d1000000-0000-4000-8000-000000000005', 'o-12', 'airbnb', 'confirmed', '2026-09-10', '2026-09-12'),
 ('d1000000-0000-4000-8000-000000000005', 'o-14', 'airbnb', 'confirmed', '2026-09-12', '2026-09-14'),
 ('d1000000-0000-4000-8000-000000000005', 'o-16', 'airbnb', 'confirmed', '2026-09-14', '2026-09-16'),
 ('d1000000-0000-4000-8000-000000000005', 'o-13x', 'manual', 'blocked', '2026-09-12', '2026-09-13');
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, last_guest_name, checkout_date, cleaned_at, meter_photos_skipped, meter_photo_skip_note) values
 ('d3000000-0000-4000-8000-000000000010', 'o-s10', 'Synthetic Cleaner', 'd1000000-0000-4000-8000-000000000005', 'turnover', 'd2000000-0000-4000-8000-000000000001', 'G10', '2026-09-10', now(), true, 'phone broke'),
 ('d3000000-0000-4000-8000-000000000014', 'o-s14', 'Synthetic Cleaner', 'd1000000-0000-4000-8000-000000000005', 'turnover', 'd2000000-0000-4000-8000-000000000001', 'G14', '2026-09-14', now() - interval '5 days', false, null);

set local role authenticated;
set local request.jwt.claims = '{"sub":"d2000000-0000-4000-8000-000000000001","aal":"aal1"}';
select is((public.can_skip_meter_photos_v2('d1000000-0000-4000-8000-000000000005', '2026-09-12') ->> 'allowed'), 'false', 'the stay next to a skipped one is refused');
select is((public.can_skip_meter_photos_v2('d1000000-0000-4000-8000-000000000005', '2026-09-12') ->> 'neighbour_checkout'), '2026-09-10', 'it names the neighbour');
select is((public.can_skip_meter_photos_v2('d1000000-0000-4000-8000-000000000005', '2026-09-12') ->> 'reason'), 'neighbour_skipped', 'with the contract reason');
select is((public.can_skip_meter_photos_v2('d1000000-0000-4000-8000-000000000005', '2026-09-14') ->> 'allowed'), 'true', 'late filing does not fool it: the 14 Sep stay is not next to a skipped one');
select is((select allowed from public.can_skip_meter_photos('d1000000-0000-4000-8000-000000000005')), false, 'v1 (filing order) would have refused the 14 Sep stay');
select is((public.can_skip_meter_photos_v2('d1000000-0000-4000-8000-000000000005', '2026-09-16') ->> 'allowed'), 'true', 'the 16 Sep stay is two away: allowed');
select is((public.can_skip_meter_photos_v2('d1000000-0000-4000-8000-000000000005', '2026-09-10') ->> 'allowed'), 'true', 'the skipped stay is not refused by its own skip; its neighbours are clean');
select is((public.can_skip_meter_photos_v2('d1000000-0000-4000-8000-000000000005', null) ->> 'allowed'), 'false', 'a null date falls back to the v1 rule (latest by cleaned_at skipped)');
set local request.jwt.claims = '{"sub":"d2000000-0000-4000-8000-000000000002","aal":"aal1"}';
select throws_ok($$select public.can_skip_meter_photos_v2('d1000000-0000-4000-8000-000000000005', '2026-09-12')$$, '42501', null, 'staff of another property is refused');
reset role;

-- an exception on one side only does not lift it; the pair does
insert into public.meter_skip_exceptions(property_id, checkout_date, note) values ('d1000000-0000-4000-8000-000000000005', '2026-09-12', 'phone malfunction');
set local role authenticated;
set local request.jwt.claims = '{"sub":"d2000000-0000-4000-8000-000000000001","aal":"aal1"}';
select is((public.can_skip_meter_photos_v2('d1000000-0000-4000-8000-000000000005', '2026-09-12') ->> 'allowed'), 'false', 'exception on this stay only: still refused');
reset role;
delete from public.meter_skip_exceptions where checkout_date = '2026-09-12';
insert into public.meter_skip_exceptions(property_id, checkout_date, note) values ('d1000000-0000-4000-8000-000000000005', '2026-09-10', 'phone malfunction');
set local role authenticated;
set local request.jwt.claims = '{"sub":"d2000000-0000-4000-8000-000000000001","aal":"aal1"}';
select is((public.can_skip_meter_photos_v2('d1000000-0000-4000-8000-000000000005', '2026-09-12') ->> 'allowed'), 'false', 'exception on the neighbour only: still refused');
reset role;
insert into public.meter_skip_exceptions(property_id, checkout_date, note) values ('d1000000-0000-4000-8000-000000000005', '2026-09-12', 'phone malfunction');
set local role authenticated;
set local request.jwt.claims = '{"sub":"d2000000-0000-4000-8000-000000000001","aal":"aal1"}';
select is((public.can_skip_meter_photos_v2('d1000000-0000-4000-8000-000000000005', '2026-09-12') ->> 'allowed'), 'true', 'the exception pair lifts it');
reset role;
-- the service role (submit-cleaning) may ask too
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select set_config('request.jwt.claim.role', 'service_role', true);
select is((public.can_skip_meter_photos_v2('d1000000-0000-4000-8000-000000000005', '2026-09-16') ->> 'allowed'), 'true', 'service_role may ask');
reset role;

-- the cleaner's report ---------------------------------------------------------------------------------------------------------------------------------
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date) values
 ('d1000000-0000-4000-8000-000000000006', 'r-05', 'airbnb', 'confirmed', '2026-08-04', '2026-08-05'),
 ('d1000000-0000-4000-8000-000000000006', 'r-07', 'airbnb', 'confirmed', '2026-08-05', '2026-08-07'),
 ('d1000000-0000-4000-8000-000000000006', 'r-09', 'airbnb', 'confirmed', '2026-08-07', '2026-08-09'),
 ('d1000000-0000-4000-8000-000000000006', 'r-20', 'airbnb', 'confirmed', '2026-08-19', '2026-08-20'),
 ('d1000000-0000-4000-8000-000000000006', 'r-sep01', 'airbnb', 'confirmed', '2026-08-30', '2026-09-01'),
 ('d1000000-0000-4000-8000-000000000006', 'r-sep03', 'airbnb', 'confirmed', '2026-09-01', '2026-09-03');
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, last_guest_name, checkout_date, cleaned_at) values
 ('d3000000-0000-4000-8000-000000000107', 'r-s07', 'Synthetic Cleaner', 'd1000000-0000-4000-8000-000000000006', 'turnover', 'd2000000-0000-4000-8000-000000000001', 'Test Guest R1', '2026-08-07', now()),
 ('d3000000-0000-4000-8000-000000000109', 'r-s09', 'Synthetic Cleaner', 'd1000000-0000-4000-8000-000000000006', 'turnover', 'd2000000-0000-4000-8000-000000000001', 'Test Guest R2', '2026-08-09', now()),
 ('d3000000-0000-4000-8000-000000000120', 'r-s20', 'Synthetic Cleaner', 'd1000000-0000-4000-8000-000000000006', 'turnover', 'd2000000-0000-4000-8000-000000000001', 'Test Guest R3', '2026-08-20', now()),
 ('d3000000-0000-4000-8000-000000000131', 'r-s01', 'Synthetic Cleaner', 'd1000000-0000-4000-8000-000000000006', 'turnover', 'd2000000-0000-4000-8000-000000000001', 'Test Guest R4', '2026-09-03', now());
insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, electric_curr, water_curr, vision_verdict, vision_checked_at, meter_flag) values
 ('d4000000-0000-4000-8000-000000000107', 'd3000000-0000-4000-8000-000000000107', 'd1000000-0000-4000-8000-000000000006', 'd2000000-0000-4000-8000-000000000001', 4273, 81.58, 'mismatch', now(), null),
 ('d4000000-0000-4000-8000-000000000120', 'd3000000-0000-4000-8000-000000000120', 'd1000000-0000-4000-8000-000000000006', 'd2000000-0000-4000-8000-000000000001', 4300, 82.0, 'mismatch', now(), null),
 ('d4000000-0000-4000-8000-000000000131', 'd3000000-0000-4000-8000-000000000131', 'd1000000-0000-4000-8000-000000000006', 'd2000000-0000-4000-8000-000000000001', 4400, 83.0, 'mismatch', now(), 'misread');

set local role authenticated;
set local request.jwt.claims = '{"aal":"aal1"}';
select throws_ok($$select public.report_no_meter_photo_v1('d3000000-0000-4000-8000-000000000107', 'Phone malfunction')$$, '42501', null, 'no signed-in user: refused');
set local request.jwt.claims = '{"sub":"d2000000-0000-4000-8000-000000000002","aal":"aal1"}';
select throws_ok($$select public.report_no_meter_photo_v1('d3000000-0000-4000-8000-000000000107', 'Phone malfunction')$$, '42501', null, 'staff of another property: refused');
set local request.jwt.claims = '{"sub":"d2000000-0000-4000-8000-000000000003","aal":"aal1"}';
select throws_ok($$select public.report_no_meter_photo_v1('d3000000-0000-4000-8000-000000000107', 'Phone malfunction')$$, '42501', null, 'another cleaner of the same property, not the submitter: refused');
set local request.jwt.claims = '{"sub":"d2000000-0000-4000-8000-000000000001","aal":"aal1"}';
select is(public.report_no_meter_photo_v1('d3000000-0000-4000-8000-0000000000ff', 'Phone malfunction') ->> 'reason', 'not_found', 'an unknown session is not_found');
select is(public.report_no_meter_photo_v1('d3000000-0000-4000-8000-000000000107', ' abc ') ->> 'reason', 'note_required', 'a note under 4 characters is refused');
select is(public.report_no_meter_photo_v1('d3000000-0000-4000-8000-000000000107', repeat('x', 301)) ->> 'reason', 'note_required', 'a note over 300 characters is refused');
reset role;
select is((select count(*) from public.cleaning_sessions where id = 'd3000000-0000-4000-8000-000000000107' and meter_photos_skipped), 0::bigint, 'refusals changed nothing');

set local role authenticated;
set local request.jwt.claims = '{"sub":"d2000000-0000-4000-8000-000000000001","aal":"aal1"}';
select is(public.report_no_meter_photo_v1('d3000000-0000-4000-8000-000000000107', '  Phone broke, no meter photo  ') -> 'ok', 'true'::jsonb, 'the submitter reports: ok');
reset role;
select is((select count(*) from public.cleaning_sessions where id = 'd3000000-0000-4000-8000-000000000107' and meter_photos_skipped and meter_photo_skip_note = 'Phone broke, no meter photo'), 1::bigint, 'session: skipped, trimmed note kept');
select is((select count(*) from public.meter_readings where id = 'd4000000-0000-4000-8000-000000000107' and meter_flag = 'estimate_pending' and vision_resolved_at is not null
             and vision_resolved_by = 'd2000000-0000-4000-8000-000000000001' and vision_resolved_note = 'No meter photo was taken: Phone broke, no meter photo' and vision_verdict = 'mismatch' and electric_curr = 4273), 1::bigint,
          'reading: estimate_pending, block answered on the record, typed numbers and the finding untouched');
select is((select count(*) from public.follow_up_tasks where source_kind = 'meter_no_photo' and source_ref = 'd3000000-0000-4000-8000-000000000107'
             and title = 'No meter photo: Test Guest R1 (checked out 7 Aug)' and detail like 'Synthetic Cleaner said: Phone broke, no meter photo. The typed reading is kept%'), 1::bigint, 'one admin task, in plain words');
set local role authenticated;
set local request.jwt.claims = '{"sub":"d2000000-0000-4000-8000-000000000001","aal":"aal1"}';
select is((select count(*) from public.get_meter_photo_followups('d1000000-0000-4000-8000-000000000006', 3650) where session_id = 'd3000000-0000-4000-8000-000000000107'), 0::bigint, 'the block lifts: no longer raised at sign-in');

-- idempotent: the Staff app may call it again after a partial failure
select is(public.report_no_meter_photo_v1('d3000000-0000-4000-8000-000000000107', 'Phone broke, no meter photo') -> 'ok', 'true'::jsonb, 'a second tap is ok');
reset role;
select is((select count(*) from public.follow_up_tasks where source_kind = 'meter_no_photo' and source_ref = 'd3000000-0000-4000-8000-000000000107'), 1::bigint, 'and opens no second task');

-- consecutive: the 9 Aug stay is next to the skipped 7 Aug stay, no exception
set local role authenticated;
set local request.jwt.claims = '{"sub":"d2000000-0000-4000-8000-000000000004","aal":"aal1"}';
select is(public.report_no_meter_photo_v1('d3000000-0000-4000-8000-000000000109', 'Phone broke again') ->> 'reason', 'neighbour_skipped', 'two stays in a row are refused, even for an admin');
select ok(length(public.report_no_meter_photo_v1('d3000000-0000-4000-8000-000000000109', 'Phone broke again') ->> 'message') > 20, 'with a plain sentence for the cleaner');
select is(public.report_no_meter_photo_v1('d3000000-0000-4000-8000-000000000120', 'Cleaner phone lost') -> 'ok', 'true'::jsonb, 'an admin may report on a cleaner''s behalf');
-- the admin review accepts the new flags and still refuses unknown ones
select throws_ok($$select public.review_meter_reading_v1('d4000000-0000-4000-8000-000000000107', 'bogus_flag', 'checked')$$, '22023', null, 'review: an unknown flag is still refused');
select is(public.review_meter_reading_v1('d4000000-0000-4000-8000-000000000107', 'typed_accepted', 'checked by admin') ->> 'flag', 'typed_accepted', 'review: typed_accepted is now accepted');
set local request.jwt.claims = '{"sub":"d2000000-0000-4000-8000-000000000001","aal":"aal1"}';
select is(public.report_no_meter_photo_v1('d3000000-0000-4000-8000-000000000131', 'No photo taken today') -> 'ok', 'true'::jsonb, 'a session with a misread flag can still be reported');
reset role;
select is((select count(*) from public.cleaning_sessions where id = 'd3000000-0000-4000-8000-000000000109' and not meter_photos_skipped), 1::bigint, 'the refused session was not changed');
select is((select vision_resolved_by from public.meter_readings where id = 'd4000000-0000-4000-8000-000000000120'), 'd2000000-0000-4000-8000-000000000004'::uuid, 'the admin is on the record as the one who answered');
select is((select meter_flag from public.meter_readings where id = 'd4000000-0000-4000-8000-000000000131'), 'misread', 'misread stays misread');

-- F1: the skip was declared at submit and the reading is a vision mismatch nobody has answered -> the report answers it and lifts the block ---------------------
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, last_guest_name, checkout_date, cleaned_at, meter_photos_skipped, meter_photo_skip_note) values
 ('d3000000-0000-4000-8000-000000000150', 'r-s150', 'Synthetic Cleaner', 'd1000000-0000-4000-8000-000000000006', 'turnover', 'd2000000-0000-4000-8000-000000000001', 'Test Guest F1', '2026-07-15', now(), true, 'declared at submit');
insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, electric_curr, water_curr, vision_verdict, vision_checked_at, meter_flag) values
 ('d4000000-0000-4000-8000-000000000150', 'd3000000-0000-4000-8000-000000000150', 'd1000000-0000-4000-8000-000000000006', 'd2000000-0000-4000-8000-000000000001', 4350, 83.5, 'mismatch', now(), null);
set local role authenticated;
set local request.jwt.claims = '{"sub":"d2000000-0000-4000-8000-000000000001","aal":"aal1"}';
select is((select count(*) from public.get_meter_photo_followups('d1000000-0000-4000-8000-000000000006', 3650) where session_id = 'd3000000-0000-4000-8000-000000000150'), 1::bigint, 'F1: before the report the session is raised at sign-in');
select is(public.report_no_meter_photo_v1('d3000000-0000-4000-8000-000000000150', 'Phone broke, no meter photo') -> 'ok', 'true'::jsonb, 'F1: a session already skipped but unanswered is answered: ok');
select is((select count(*) from public.get_meter_photo_followups('d1000000-0000-4000-8000-000000000006', 3650) where session_id = 'd3000000-0000-4000-8000-000000000150'), 0::bigint, 'F1: and is no longer raised');
reset role;
select is((select count(*) from public.meter_readings where id = 'd4000000-0000-4000-8000-000000000150' and meter_flag = 'estimate_pending' and vision_resolved_at is not null
             and vision_resolved_by = 'd2000000-0000-4000-8000-000000000001' and vision_resolved_note = 'No meter photo was taken: Phone broke, no meter photo' and electric_curr = 4350), 1::bigint,
          'F1: the reading is estimate_pending and answered, typed number kept');

-- F6: an earlier answer is kept and added to; under_review becomes estimate_pending, first_reading stays ---------------------------------------------------
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id, last_guest_name, checkout_date, cleaned_at) values
 ('d3000000-0000-4000-8000-000000000151', 'r-s151', 'Synthetic Cleaner', 'd1000000-0000-4000-8000-000000000006', 'turnover', 'd2000000-0000-4000-8000-000000000001', 'Test Guest F6a', '2026-07-16', now()),
 ('d3000000-0000-4000-8000-000000000152', 'r-s152', 'Synthetic Cleaner', 'd1000000-0000-4000-8000-000000000006', 'turnover', 'd2000000-0000-4000-8000-000000000001', 'Test Guest F6b', '2026-07-17', now());
insert into public.meter_readings(id, session_id, property_id, submitted_by_user_id, electric_curr, water_curr, vision_verdict, vision_checked_at, meter_flag, vision_resolved_at, vision_resolved_by, vision_resolved_note) values
 ('d4000000-0000-4000-8000-000000000151', 'd3000000-0000-4000-8000-000000000151', 'd1000000-0000-4000-8000-000000000006', 'd2000000-0000-4000-8000-000000000001', 4360, 83.6, 'mismatch', now(), 'under_review', timestamptz '2026-09-01 10:00+00', 'd2000000-0000-4000-8000-000000000004', 'Checked by Lloyd'),
 ('d4000000-0000-4000-8000-000000000152', 'd3000000-0000-4000-8000-000000000152', 'd1000000-0000-4000-8000-000000000006', 'd2000000-0000-4000-8000-000000000001', 4370, 83.7, null, null, 'first_reading', null, null, null);
set local role authenticated;
set local request.jwt.claims = '{"sub":"d2000000-0000-4000-8000-000000000001","aal":"aal1"}';
select is(public.report_no_meter_photo_v1('d3000000-0000-4000-8000-000000000151', 'Camera was broken') -> 'ok', 'true'::jsonb, 'F6: the report on an already answered reading is ok');
select is(public.report_no_meter_photo_v1('d3000000-0000-4000-8000-000000000152', 'Camera was broken') -> 'ok', 'true'::jsonb, 'F6: and on a first reading');
reset role;
select is((select count(*) from public.meter_readings where id = 'd4000000-0000-4000-8000-000000000151' and meter_flag = 'estimate_pending' and vision_resolved_at = timestamptz '2026-09-01 10:00+00'
             and vision_resolved_by = 'd2000000-0000-4000-8000-000000000004' and vision_resolved_note = 'Checked by Lloyd | No meter photo was taken: Camera was broken'), 1::bigint,
          'F6: under_review becomes estimate_pending; the earlier answer (when, who) is kept and the note appended');
select is((select meter_flag from public.meter_readings where id = 'd4000000-0000-4000-8000-000000000152'), 'first_reading', 'F6: a first reading is a real number and keeps its flag');

select * from finish();
rollback;
