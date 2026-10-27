-- Session 99 (lane SQL): release s99_staff_pay_ahead_20261101 (D-348). A cleaner includes check-outs with no report yet in her own pay request:
-- staff_pay_request_create_v2 (advance lines), the v1 wrapper, staff_pay_candidates_v1.advance, and the reminder ledger (staff_report_reminders, due_v1, claim/release/sent).
-- Synthetic fixtures only (uuids c9900000-...); every lookup is scoped to them because a real backup holds real rows. Everything rolls back.
begin;
select plan(85);

grant usage on schema public, auth, storage to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal2', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;

-- fixtures: payee Zzhoney (a1), another cleaner (a2), admin (a3), maintenance (a4: may not submit cleanings).
-- Check-outs: D1 -3, D2 -4, D3 -5, D4 -6 (already reported), D5 -7 (the admin pays it ahead), D6 -8 (a rate row with no transport applies on that day only).
insert into auth.users(id, email) values
  ('c9900000-0000-4000-8000-0000000000a1', 'zz-s99-honey@example.com'), ('c9900000-0000-4000-8000-0000000000a2', 'zz-s99-other@example.com'),
  ('c9900000-0000-4000-8000-0000000000a3', 'zz-s99-admin@example.com'), ('c9900000-0000-4000-8000-0000000000a4', 'zz-s99-maintenance@example.com');
insert into public.staff_access_profiles(user_id, role) values
  ('c9900000-0000-4000-8000-0000000000a1', 'cleaner'), ('c9900000-0000-4000-8000-0000000000a2', 'cleaner'), ('c9900000-0000-4000-8000-0000000000a3', 'admin'), ('c9900000-0000-4000-8000-0000000000a4', 'maintenance');
insert into public.properties(id, name, is_active) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Cascade Hideaway', true) on conflict (id) do nothing;
insert into public.staff_property_access(user_id, property_id) select u, '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
  from unnest(array['c9900000-0000-4000-8000-0000000000a1', 'c9900000-0000-4000-8000-0000000000a2', 'c9900000-0000-4000-8000-0000000000a3', 'c9900000-0000-4000-8000-0000000000a4']::uuid[]) u;
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '1900-01-01', 250, 250, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '1900-01-01');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, transport_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2026-09-30', 500, 1000, 150, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-09-30');
-- D6 (-8) has a rate with no transport; the next day's row puts transport 150 back, so only D6 is affected
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, transport_rate, note) values
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', current_date - 8, 500, 1000, null, 'zz s99 no transport'),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', current_date - 7, 500, 1000, 150, 'zz s99 transport back');
-- guests sort first (checkin 60 days back) so a real calendar row on the same date cannot change the guest read
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s99-d1', 'airbnb', 'confirmed', 'Aaazzone Reyes',  current_date - 60, current_date - 3),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s99-d2', 'airbnb', 'confirmed', 'Aaazztwo Cruz',   current_date - 60, current_date - 4),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s99-d3', 'airbnb', 'confirmed', 'Aaazzthree Lim', current_date - 60, current_date - 5),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s99-d4', 'airbnb', 'confirmed', 'Aaazzfour Uy',   current_date - 60, current_date - 6),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s99-d5', 'airbnb', 'confirmed', 'Aaazzfive Tan',  current_date - 60, current_date - 7),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s99-d6', 'airbnb', 'confirmed', 'Aaazzsix Go',    current_date - 60, current_date - 8);
-- D4 is reported; two more reports (checkout -9 and -10) are unpaid sessions for the v1 / mixed requests
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, submitted_by_user_id) values
  ('c9900000-0000-4000-8000-0000000000b4', 'zz-c99-d4', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', current_date - 6,  'turnover', 'c9900000-0000-4000-8000-0000000000a1'),
  ('c9900000-0000-4000-8000-0000000000b9', 'zz-c99-s9', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', current_date - 9,  'turnover', 'c9900000-0000-4000-8000-0000000000a1'),
  ('c9900000-0000-4000-8000-0000000000b6', 'zz-c99-s10', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', current_date - 10, 'turnover', 'c9900000-0000-4000-8000-0000000000a1');
-- a real backup holds real sessions on the same dates: make them mid-stay (never a match for a checkout) so only the fixtures decide what is missed; rolled back with the suite
update public.cleaning_sessions set cleaning_type = 'mid_stay' where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and coalesce(submission_id, '') not like 'zz-c99-%';
-- the same for real calendar stays (guests, Airbnb blocks): get_missed_cleanings reads calendar_events and the suite must see only its own zz-s99 rows; rolled back with the suite
update public.calendar_events set status = 'cancelled' where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and coalesce(uid, '') not like 'zz-s99-%';
-- a real backup holds live advance lines on real dates: cancel every non-fixture request inside this transaction so only the fixtures hold dates; rolled back with the suite
update public.staff_pay_requests set status = 'cancelled', cancelled_at = now() where status <> 'cancelled' and idempotency_key not like 'zz-c99-%';

-- 1. candidates.advance before anything is held ---------------------------------------------------------------------------------------------------
select pg_temp.as_user('c9900000-0000-4000-8000-0000000000a1');
insert into _t select 'cand0', public.staff_pay_candidates_v1();
reset role;
select is((select count(*)::int from jsonb_array_elements((select v->'advance' from _t where k = 'cand0')) a
            where a->>'checkout_date' in ((current_date - 3)::text, (current_date - 4)::text, (current_date - 5)::text, (current_date - 7)::text, (current_date - 8)::text)), 5,
  'candidates.advance lists the five owed fixture checkouts, once each');
select is((select count(*)::int from jsonb_array_elements((select v->'advance' from _t where k = 'cand0')) a where a->>'checkout_date' = (current_date - 6)::text), 0,
  'a checkout that already has a report is not offered');
select ok((select (a->>'base')::numeric = 500 and (a->>'transport')::numeric = 150 from jsonb_array_elements((select v->'advance' from _t where k = 'cand0')) a where a->>'checkout_date' = (current_date - 3)::text),
  'priced as a turnover with the transport the rate allows');
select ok((select (a->'transport') = 'null'::jsonb and (a->>'base')::numeric = 500 from jsonb_array_elements((select v->'advance' from _t where k = 'cand0')) a where a->>'checkout_date' = (current_date - 8)::text),
  'transport is null on a day whose rate has none');
select is((select count(*)::int from jsonb_array_elements((select v->'advance' from _t where k = 'cand0')) a where a ? 'guest'), 0, 'no guest names in the staff list');
select ok((select v ? 'sessions' and v ? 'claims' and v ? 'missing_reports' and v ? 'requests' and v ? 'reports_owed' and v ? 'payee_name' from _t where k = 'cand0'), 'every existing key is still there');

-- 2. the admin pays D5 ahead first (s94 path), so the cleaner's own path must see it as taken ------------------------------------------------------
select pg_temp.as_user('c9900000-0000-4000-8000-0000000000a3');
insert into _t select 'adm', public.staff_pay_admin_create_v2('c9900000-0000-4000-8000-0000000000a1', '[]'::jsonb, '{}'::uuid[],
  jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 7)::text)), 'zz-c99-adm-0001');
reset role;
select is((select v->>'ok' from _t where k = 'adm'), 'true', 'the admin path still pays a date ahead');
select pg_temp.as_user('c9900000-0000-4000-8000-0000000000a1');
insert into _t select 'cand1', public.staff_pay_candidates_v1();
reset role;
select is((select count(*)::int from jsonb_array_elements((select v->'advance' from _t where k = 'cand1')) a where a->>'checkout_date' = (current_date - 7)::text), 0,
  'candidates.advance drops a date the admin already pays ahead');

-- 3. happy path: two dates, one with transport -----------------------------------------------------------------------------------------------------
select pg_temp.as_user('c9900000-0000-4000-8000-0000000000a1');
insert into _t select 'r1', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb,
  jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 3)::text, 'transport', true), jsonb_build_object('checkout_date', (current_date - 4)::text, 'transport', false)),
  'zz-c99-key-0001');
reset role;
select is((select v->>'ok' from _t where k = 'r1'), 'true', 'create_v2 accepts two owed checkouts for the signed-in cleaner');
select is((select (v->>'total')::numeric from _t where k = 'r1'), 1150::numeric, 'total = 500 + 150 transport + 500');
select is((select count(*)::int from jsonb_array_elements((select v->'lines' from _t where k = 'r1')) l where l->>'kind' = 'advance' and not l ? 'session_id' and l->>'date' = l->>'checkout_date' and l->>'type' = 'turnover'), 2,
  'both lines are kind advance, turnover, checkout_date = date, no session_id');
select is((select l->>'guest' from jsonb_array_elements((select v->'lines' from _t where k = 'r1')) l where l->>'checkout_date' = (current_date - 3)::text), 'Aaazzone', 'the line names the guest by first name');
select is((select (l->>'amount')::numeric from jsonb_array_elements((select v->'lines' from _t where k = 'r1')) l where l->>'checkout_date' = (current_date - 3)::text), 650::numeric, 'a line with transport is 650');
select ok((select payee_user_id = 'c9900000-0000-4000-8000-0000000000a1' and created_by_user_id is null and status = 'requested' and total_amount = 1150
             from public.staff_pay_requests where id = (select (v->>'request_id')::uuid from _t where k = 'r1')),
  'the row belongs to the caller (payee = auth.uid()), is requested and is not marked as admin-made');
select pg_temp.as_user('c9900000-0000-4000-8000-0000000000a1');
insert into _t select 'r1b', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb,
  jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 3)::text)), 'zz-c99-key-0001');
reset role;
select ok((select (v->>'replay')::boolean and v->>'ref' = (select v->>'ref' from _t where k = 'r1') and (v->>'total')::numeric = 1150 from _t where k = 'r1b'), 'the same key replays the first request, whatever it is sent this time');

-- 4. refusals, each with a fresh key; none may leave a row ----------------------------------------------------------------------------------------
select pg_temp.as_user('c9900000-0000-4000-8000-0000000000a1');
insert into _t select 'not_owed4', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb, jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 6)::text)), 'zz-c99-ref-0002');
insert into _t select 'not_owed45', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb, jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 45)::text)), 'zz-c99-ref-0003');
insert into _t select 'taken', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb, jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 3)::text)), 'zz-c99-ref-0004');
insert into _t select 'taken_adm', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb, jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 7)::text)), 'zz-c99-ref-0005');
insert into _t select 'dup', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb,
  jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 5)::text), jsonb_build_object('checkout_date', (current_date - 5)::text)), 'zz-c99-ref-0006');
insert into _t select 'badfmt', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb, jsonb_build_array(jsonb_build_object('checkout_date', '2026-13-45')), 'zz-c99-ref-0007');
insert into _t select 'notobj', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb, '["x"]'::jsonb, 'zz-c99-ref-0008');
insert into _t select 'badtr', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb, jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 5)::text, 'transport', 'yes')), 'zz-c99-ref-0009');
insert into _t select 'notr', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb, jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 8)::text, 'transport', true)), 'zz-c99-ref-0010');
insert into _t select 'empty', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb, null, 'zz-c99-ref-0011');
insert into _t select 'shortkey', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb, jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 5)::text)), 'short');
reset role;
select is((select v->>'reason' from _t where k = 'not_owed4'), 'advance_not_owed', 'a checkout that already has a report is advance_not_owed');
select is((select v->>'reason' from _t where k = 'not_owed45'), 'advance_not_owed', 'a date outside the 30-day missed list is advance_not_owed');
select is((select v->>'reason' from _t where k = 'taken'), 'advance_taken', 'a date held by a live request is advance_taken');
select is((select v->>'ref' from _t where k = 'taken'), (select v->>'ref' from _t where k = 'r1'), 'and the refusal names that request');
select ok((select v->>'reason' = 'advance_taken' and v->>'ref' = (select v->>'ref' from _t where k = 'adm') from _t where k = 'taken_adm'), 'a date the admin path holds is advance_taken, with the admin request ref');
select is((select v->>'reason' from _t where k = 'dup'), 'bad_request', 'the same date twice in one call is bad_request');
select is((select v->>'reason' from _t where k = 'badfmt'), 'bad_request', 'an impossible date is bad_request');
select is((select v->>'reason' from _t where k = 'notobj'), 'bad_request', 'an advance entry that is not an object is bad_request');
select is((select v->>'reason' from _t where k = 'badtr'), 'bad_request', 'a transport that is not a boolean is bad_request');
select is((select v->>'reason' from _t where k = 'notr'), 'transport_not_allowed', 'transport on a day whose rate has none is transport_not_allowed');
select is((select v->>'reason' from _t where k = 'empty'), 'no_lines', 'nothing to pay is no_lines');
select is((select v->>'reason' from _t where k = 'shortkey'), 'bad_request', 'a short idempotency key is bad_request');
select is((select count(*)::int from public.staff_pay_requests where idempotency_key like 'zz-c99-ref-%'), 0, 'no refusal left a row behind');
select is((select count(*)::int from public.staff_pay_requests, jsonb_array_elements(lines) l where l->>'kind' = 'advance' and l->>'checkout_date' = (current_date - 5)::text and status <> 'cancelled'), 0, 'and D3 is still free');

-- 5. a clean session and an advance date in one request; the v1 wrapper -------------------------------------------------------------------------------
select pg_temp.as_user('c9900000-0000-4000-8000-0000000000a1');
insert into _t select 'mix', public.staff_pay_request_create_v2('[{"id":"c9900000-0000-4000-8000-0000000000b6","transport":false}]'::jsonb, '{}'::uuid[], '[]'::jsonb,
  jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 5)::text)), 'zz-c99-key-0002');
insert into _t select 'v1', public.staff_pay_request_create_v1('[{"id":"c9900000-0000-4000-8000-0000000000b9","transport":false}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'zz-c99-key-0003');
insert into _t select 'v1b', public.staff_pay_request_create_v1('[{"id":"c9900000-0000-4000-8000-0000000000b9","transport":false}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'zz-c99-key-0003');
reset role;
select ok((select v->>'ok' = 'true' and (v->>'total')::numeric = 1000 and v->'lines'->0->>'kind' = 'clean' and v->'lines'->1->>'kind' = 'advance' and jsonb_array_length(v->'lines') = 2 from _t where k = 'mix'),
  'a clean and an advance date make one request of 1,000, clean line first');
select is((select pay_request_id from public.cleaning_sessions where id = 'c9900000-0000-4000-8000-0000000000b6'), (select (v->>'request_id')::uuid from _t where k = 'mix'), 'the clean session is locked to the mixed request');
select ok((select v->>'ok' = 'true' and (v->>'total')::numeric = 500 and jsonb_array_length(v->'lines') = 1 and v->'lines'->0->>'kind' = 'clean' and v ? 'finance_message_id' from _t where k = 'v1'),
  'staff_pay_request_create_v1 still makes the same request as before (500, one clean line, same keys)');
select ok((select (v->>'replay')::boolean and v->>'ref' = (select v->>'ref' from _t where k = 'v1') from _t where k = 'v1b'), 'v1 replays on its key');

-- 6. candidates.advance after the requests; a cancelled request frees its dates -----------------------------------------------------------------------
select pg_temp.as_user('c9900000-0000-4000-8000-0000000000a1');
insert into _t select 'cand2', public.staff_pay_candidates_v1();
reset role;
select is((select count(*)::int from jsonb_array_elements((select v->'advance' from _t where k = 'cand2')) a
            where a->>'checkout_date' in ((current_date - 3)::text, (current_date - 4)::text, (current_date - 5)::text, (current_date - 7)::text)), 0, 'candidates.advance no longer offers any date a live request holds');
select is((select count(*)::int from jsonb_array_elements((select v->'advance' from _t where k = 'cand2')) a where a->>'checkout_date' = (current_date - 8)::text), 1, 'it still offers the free one');
-- r1 holds two dates, the mixed request one, the admin request one
select is((select jsonb_array_length(v->'reports_owed') from _t where k = 'cand2'), 4, 'reports_owed (s94) lists the four advance lines, unchanged');
update public.staff_pay_requests set status = 'cancelled' where id = (select (v->>'request_id')::uuid from _t where k = 'r1');
select pg_temp.as_user('c9900000-0000-4000-8000-0000000000a1');
insert into _t select 'cand3', public.staff_pay_candidates_v1();
insert into _t select 'again', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb, jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 3)::text)), 'zz-c99-key-0004');
reset role;
select is((select count(*)::int from jsonb_array_elements((select v->'advance' from _t where k = 'cand3')) a where a->>'checkout_date' in ((current_date - 3)::text, (current_date - 4)::text)), 2, 'a cancelled request frees its dates in the candidates');
select is((select v->>'ok' from _t where k = 'again'), 'true', 'and a new request may take a freed date');

-- 7. who may call ----------------------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('c9900000-0000-4000-8000-0000000000a4');
insert into _t select 'a4_may', to_jsonb(public.current_staff_authorized('submit_cleaning', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'));
insert into _t select 'admin_self', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb, jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 4)::text)), 'zz-c99-key-0005');
reset role;
select is((select v from _t where k = 'a4_may'), 'false'::jsonb, 'the maintenance user is not authorised to submit cleanings');
select is((select v->>'reason' from _t where k = 'admin_self'), 'not_authorized', 'a role that may not submit cleanings gets not_authorized (and no row)');
select ok(has_function_privilege('authenticated', 'public.staff_pay_request_create_v2(jsonb,uuid[],jsonb,jsonb,text)', 'execute')
          and not has_function_privilege('anon', 'public.staff_pay_request_create_v2(jsonb,uuid[],jsonb,jsonb,text)', 'execute')
          and not has_function_privilege('service_role', 'public.staff_pay_request_create_v2(jsonb,uuid[],jsonb,jsonb,text)', 'execute'), 'create_v2: authenticated only');
select ok(has_function_privilege('authenticated', 'public.staff_pay_request_create_v1(jsonb,uuid[],jsonb,text)', 'execute')
          and not has_function_privilege('anon', 'public.staff_pay_request_create_v1(jsonb,uuid[],jsonb,text)', 'execute')
          and not has_function_privilege('service_role', 'public.staff_pay_request_create_v1(jsonb,uuid[],jsonb,text)', 'execute'), 'create_v1: authenticated only');
select ok(has_function_privilege('authenticated', 'public.staff_pay_candidates_v1()', 'execute') and has_function_privilege('service_role', 'public.staff_pay_candidates_v1()', 'execute')
          and not has_function_privilege('anon', 'public.staff_pay_candidates_v1()', 'execute'), 'candidates: authenticated and service_role, not anon');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where a.grantee = 0
                       and p.oid in ('public.staff_pay_request_create_v2(jsonb,uuid[],jsonb,jsonb,text)'::regprocedure, 'public.staff_pay_request_create_v1(jsonb,uuid[],jsonb,text)'::regprocedure,
                                     'public.staff_pay_candidates_v1()'::regprocedure, 'public.staff_report_reminders_due_v1(timestamptz)'::regprocedure,
                                     'public.staff_report_reminder_claim_v1(uuid,date,smallint)'::regprocedure, 'public.staff_report_reminder_release_v1(uuid,date,smallint)'::regprocedure,
                                     'public.staff_report_reminder_sent_v1(uuid,date,smallint)'::regprocedure)), 'no new or replaced function is executable by PUBLIC');

-- 8. the reminder ledger: fixed dates and a fixed p_now so nothing depends on today -------------------------------------------------------------------
-- A: Zzhoney, made 2026-09-20 09:00 Manila, owes 09-12 and 09-15. B: cancelled. D: older than 30 days at p_now. E: another payee.
insert into public.staff_pay_requests(id, property_id, payee_user_id, payee_name, idempotency_key, status, lines, total_amount, created_at) values
  ('c9900000-0000-4000-8000-0000000000e1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'c9900000-0000-4000-8000-0000000000a1', 'Zzhoney', 'zz-c99-due-0001', 'requested',
   '[{"kind":"advance","checkout_date":"2026-09-12","date":"2026-09-12","type":"turnover","base":500,"transport":0,"amount":500},{"kind":"advance","checkout_date":"2026-09-15","date":"2026-09-15","type":"turnover","base":500,"transport":0,"amount":500}]'::jsonb, 1000, timestamptz '2026-09-20 09:00:00+08'),
  ('c9900000-0000-4000-8000-0000000000e2', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'c9900000-0000-4000-8000-0000000000a1', 'Zzhoney', 'zz-c99-due-0002', 'cancelled',
   '[{"kind":"advance","checkout_date":"2026-09-10","date":"2026-09-10","type":"turnover","base":500,"transport":0,"amount":500}]'::jsonb, 500, timestamptz '2026-09-20 09:00:00+08'),
  ('c9900000-0000-4000-8000-0000000000e3', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'c9900000-0000-4000-8000-0000000000a1', 'Zzhoney', 'zz-c99-due-0003', 'requested',
   '[{"kind":"advance","checkout_date":"2026-07-30","date":"2026-07-30","type":"turnover","base":500,"transport":0,"amount":500}]'::jsonb, 500, timestamptz '2026-08-01 10:00:00+08'),
  ('c9900000-0000-4000-8000-0000000000e4', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'c9900000-0000-4000-8000-0000000000a2', 'Zzother', 'zz-c99-due-0004', 'requested',
   '[{"kind":"advance","checkout_date":"2026-09-16","date":"2026-09-16","type":"turnover","base":500,"transport":0,"amount":500}]'::jsonb, 500, timestamptz '2026-09-20 09:00:00+08');
create function pg_temp.due(p_now text) returns table(request_id uuid, checkout_date date, stage smallint, owed_dates date[]) language sql as $$
  select d.request_id, d.checkout_date, d.stage, d.owed_dates from public.staff_report_reminders_due_v1(p_now::timestamptz) d
   where d.request_id in ('c9900000-0000-4000-8000-0000000000e1', 'c9900000-0000-4000-8000-0000000000e2', 'c9900000-0000-4000-8000-0000000000e3', 'c9900000-0000-4000-8000-0000000000e4');
$$;
select is((select count(*)::int from pg_temp.due('2026-09-20 18:00:00+08')), 0, 'due: nothing before a full day has passed');
select is((select count(*)::int from pg_temp.due('2026-09-21 10:00:00+08')), 3, 'due: after a day, stage 1 for A (two dates) and E; not the cancelled B, not the 50-day-old D');
select ok((select bool_and(stage = 1) from pg_temp.due('2026-09-21 10:00:00+08')), 'and all of them are stage 1');
select ok((select bool_and(owed_dates = array['2026-09-12', '2026-09-15']::date[]) from pg_temp.due('2026-09-21 10:00:00+08') where request_id = 'c9900000-0000-4000-8000-0000000000e1'), 'owed_dates carries all of the payee''s still-owed dates, for one message');
select is((select owed_dates from pg_temp.due('2026-09-21 10:00:00+08') where request_id = 'c9900000-0000-4000-8000-0000000000e4'), array['2026-09-16']::date[], 'and never another payee''s');
select is((select count(*)::int from pg_temp.due('2026-09-22 07:59:00+08')), 0, 'due: not before 08:00 Manila');
select is((select count(*)::int from pg_temp.due('2026-09-22 08:00:00+08')), 3, 'due: 08:00 Manila is in');
select is((select count(*)::int from pg_temp.due('2026-09-22 19:59:00+08')), 3, 'due: 19:59 Manila is in');
select is((select count(*)::int from pg_temp.due('2026-09-22 20:00:00+08')), 0, 'due: not from 20:00 Manila');
select is((select count(*)::int from pg_temp.due('2026-09-22 02:00:00+00')), 3, 'due: the hour is read in Manila (02:00 UTC = 10:00 Manila)');

-- 9. claim, release, sent ---------------------------------------------------------------------------------------------------------------------------
select is(public.staff_report_reminder_claim_v1('c9900000-0000-4000-8000-0000000000e1', date '2026-09-12', 1::smallint), true, 'claim: the first call inserts');
select is(public.staff_report_reminder_claim_v1('c9900000-0000-4000-8000-0000000000e1', date '2026-09-12', 1::smallint), false, 'claim: the second call for the same key is false');
select is((select payee_user_id from public.staff_report_reminders where request_id = 'c9900000-0000-4000-8000-0000000000e1' and checkout_date = '2026-09-12' and stage = 1), 'c9900000-0000-4000-8000-0000000000a1'::uuid, 'the claim takes the payee from the request');
select is((select count(*)::int from pg_temp.due('2026-09-21 10:00:00+08') where request_id = 'c9900000-0000-4000-8000-0000000000e1'), 1, 'a claimed stage is not due again');
select is(public.staff_report_reminder_claim_v1('c9900000-0000-4000-8000-0000000000ff', date '2026-09-12', 1::smallint), false, 'claim: an unknown request claims nothing');
select throws_ok($q$select public.staff_report_reminder_claim_v1('c9900000-0000-4000-8000-0000000000e1', date '2026-09-12', 2::smallint)$q$, '23514', null, 'only stages 1 and 3 exist');
select lives_ok($q$select public.staff_report_reminder_release_v1('c9900000-0000-4000-8000-0000000000e1', date '2026-09-12', 1::smallint)$q$, 'release runs');
select is((select count(*)::int from pg_temp.due('2026-09-21 10:00:00+08') where request_id = 'c9900000-0000-4000-8000-0000000000e1'), 2, 'a released claim is due again');
select is(public.staff_report_reminder_claim_v1('c9900000-0000-4000-8000-0000000000e1', date '2026-09-12', 1::smallint), true, 'and can be claimed again');
select lives_ok($q$select public.staff_report_reminder_sent_v1('c9900000-0000-4000-8000-0000000000e1', date '2026-09-12', 1::smallint)$q$, 'sent runs');
select lives_ok($q$select public.staff_report_reminder_release_v1('c9900000-0000-4000-8000-0000000000e1', date '2026-09-12', 1::smallint)$q$, 'release after sent runs');
select ok((select sent_at is not null from public.staff_report_reminders where request_id = 'c9900000-0000-4000-8000-0000000000e1' and checkout_date = '2026-09-12' and stage = 1), 'a sent claim keeps its row: release deletes only unsent claims');

-- 9b. A1: an unsent claim older than an hour counts as not taken, and claim_v1 takes it over ------------------------------------------------------
select is(public.staff_report_reminder_claim_v1('c9900000-0000-4000-8000-0000000000e4', date '2026-09-16', 1::smallint), true, 'A1: E is claimed at stage 1');
update public.staff_report_reminders set claimed_at = timestamptz '2026-09-21 09:00:00+08' where request_id = 'c9900000-0000-4000-8000-0000000000e4' and checkout_date = '2026-09-16' and stage = 1;
select is((select count(*)::int from pg_temp.due('2026-09-21 09:30:00+08') where request_id = 'c9900000-0000-4000-8000-0000000000e4'), 0, 'A1: a claim 30 minutes old is still held (not due)');
select is((select count(*)::int from pg_temp.due('2026-09-21 10:30:00+08') where request_id = 'c9900000-0000-4000-8000-0000000000e4'), 1, 'A1: an unsent claim 90 minutes old is due again');
update public.staff_report_reminders set claimed_at = now() - interval '2 hours' where request_id = 'c9900000-0000-4000-8000-0000000000e4' and checkout_date = '2026-09-16' and stage = 1;
select is(public.staff_report_reminder_claim_v1('c9900000-0000-4000-8000-0000000000e4', date '2026-09-16', 1::smallint), true, 'A1: claim_v1 takes over a stale unsent claim');
select is(public.staff_report_reminder_claim_v1('c9900000-0000-4000-8000-0000000000e4', date '2026-09-16', 1::smallint), false, 'A1: and the fresh claim it made cannot be taken again');
update public.staff_report_reminders set claimed_at = now() - interval '2 hours' where request_id = 'c9900000-0000-4000-8000-0000000000e1' and checkout_date = '2026-09-12' and stage = 1;
select is(public.staff_report_reminder_claim_v1('c9900000-0000-4000-8000-0000000000e1', date '2026-09-12', 1::smallint), false, 'A1: a claim that was sent is never taken over, however old');

-- 10. stage 3 and the filed report -----------------------------------------------------------------------------------------------------------------
select ok((select count(*) = 3 and bool_and(stage = 3) from pg_temp.due('2026-09-23 10:00:00+08')), 'due: after three days every owed date is at stage 3, even one whose stage 1 was sent');
select is(public.staff_report_reminder_claim_v1('c9900000-0000-4000-8000-0000000000e1', date '2026-09-15', 3::smallint), true, 'claim stage 3 (stage 1 was never sent for 09-15)');
select is((select count(*)::int from pg_temp.due('2026-09-21 10:00:00+08') where request_id = 'c9900000-0000-4000-8000-0000000000e1' and checkout_date = '2026-09-15'), 0, 'never stage 1 after stage 3 is claimed');
-- the cleaner files the 09-12 report: the s94 trigger links it to A, so that date is no longer owed
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, submitted_by_user_id) values
  ('c9900000-0000-4000-8000-0000000000bb', 'zz-c99-filed', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', date '2026-09-12', 'turnover', 'c9900000-0000-4000-8000-0000000000a1');
select is((select pay_request_id from public.cleaning_sessions where id = 'c9900000-0000-4000-8000-0000000000bb'), 'c9900000-0000-4000-8000-0000000000e1'::uuid, 'the filed report joins request A (s94 trigger)');
select is((select count(*)::int from pg_temp.due('2026-09-23 10:00:00+08') where request_id = 'c9900000-0000-4000-8000-0000000000e1'), 0, 'due: a date whose report is filed is not reminded (09-15 was already claimed at stage 3)');
select is((select owed_dates from pg_temp.due('2026-09-23 10:00:00+08') where request_id = 'c9900000-0000-4000-8000-0000000000e4'), array['2026-09-16']::date[], 'and another payee is unaffected');

-- 11. the ledger is closed to the API roles ---------------------------------------------------------------------------------------------------------
select ok((select relrowsecurity from pg_class where oid = 'public.staff_report_reminders'::regclass), 'staff_report_reminders has RLS on');
select ok(has_table_privilege('service_role', 'public.staff_report_reminders', 'select') and has_table_privilege('service_role', 'public.staff_report_reminders', 'insert')
          and has_table_privilege('service_role', 'public.staff_report_reminders', 'update') and has_table_privilege('service_role', 'public.staff_report_reminders', 'delete')
          and not has_table_privilege('authenticated', 'public.staff_report_reminders', 'select') and not has_table_privilege('anon', 'public.staff_report_reminders', 'select'), 'only service_role can touch it');
select ok(has_function_privilege('service_role', 'public.staff_report_reminders_due_v1(timestamptz)', 'execute') and has_function_privilege('service_role', 'public.staff_report_reminder_claim_v1(uuid,date,smallint)', 'execute')
          and has_function_privilege('service_role', 'public.staff_report_reminder_release_v1(uuid,date,smallint)', 'execute') and has_function_privilege('service_role', 'public.staff_report_reminder_sent_v1(uuid,date,smallint)', 'execute')
          and not has_function_privilege('authenticated', 'public.staff_report_reminders_due_v1(timestamptz)', 'execute') and not has_function_privilege('anon', 'public.staff_report_reminders_due_v1(timestamptz)', 'execute')
          and not has_function_privilege('authenticated', 'public.staff_report_reminder_claim_v1(uuid,date,smallint)', 'execute') and not has_function_privilege('authenticated', 'public.staff_report_reminder_release_v1(uuid,date,smallint)', 'execute')
          and not has_function_privilege('authenticated', 'public.staff_report_reminder_sent_v1(uuid,date,smallint)', 'execute'), 'the four reminder functions are service_role only');
select pg_temp.as_user('c9900000-0000-4000-8000-0000000000a1');
select throws_ok($q$select count(*) from public.staff_report_reminders$q$, '42501', null, 'a signed-in cleaner cannot read the ledger');
select throws_ok($q$select * from public.staff_report_reminders_due_v1()$q$, '42501', null, 'a signed-in cleaner cannot ask what is due');
reset role;
select is((select count(*)::int from public.staff_pay_requests, jsonb_array_elements(lines) l where idempotency_key like 'zz-c99-key-%' and l->>'kind' = 'advance' and status <> 'cancelled' and created_by_user_id is not null), 0,
  'invariant: no cleaner-made advance line carries created_by_user_id');

select ok(has_table_privilege('service_role', 'public.staff_report_reminders', 'select') and has_table_privilege('service_role', 'public.staff_report_reminders', 'insert')
          and not has_table_privilege('service_role', 'public.staff_report_reminders', 'truncate') and not has_table_privilege('service_role', 'public.staff_report_reminders', 'references')
          and not has_table_privilege('service_role', 'public.staff_report_reminders', 'trigger'), 'S1: service_role has table DML only, no truncate, references or trigger');

select * from finish();
rollback;
