-- Session 94 (lane SQL): release s94_pay_ahead_20261027. Pay a turnover before its report exists: staff_pay_admin_create_v2 (advance lines), the cleanadv settle,
-- the link trigger on cleaning_sessions, reports_owed / advance_candidates, the paid notice, v1 as a wrapper, settled sessions leaving the meter follow-ups,
-- meter_photo_prechecks. Synthetic fixtures only (uuids c9400000-...); every lookup is scoped to them because a real backup holds real rows. Everything rolls back.
begin;
select plan(52);

grant usage on schema public, auth, storage to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal2', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;

-- fixtures: payee Zzhoney (a1), another cleaner (a2), admin (a3); checkouts D1..D3 owed, D4 already reported, D5 outside the window
insert into auth.users(id, email) values
  ('c9400000-0000-4000-8000-0000000000a1', 'zz-s94-honey@example.com'), ('c9400000-0000-4000-8000-0000000000a2', 'zz-s94-other@example.com'),
  ('c9400000-0000-4000-8000-0000000000a3', 'zz-s94-admin@example.com');
insert into public.staff_access_profiles(user_id, role) values
  ('c9400000-0000-4000-8000-0000000000a1', 'cleaner'), ('c9400000-0000-4000-8000-0000000000a2', 'cleaner'), ('c9400000-0000-4000-8000-0000000000a3', 'admin');
insert into public.properties(id, name, is_active) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Cascade Hideaway', true) on conflict (id) do nothing;
insert into public.staff_property_access(user_id, property_id) select u, '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
  from unnest(array['c9400000-0000-4000-8000-0000000000a1', 'c9400000-0000-4000-8000-0000000000a2', 'c9400000-0000-4000-8000-0000000000a3']::uuid[]) u;
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '1900-01-01', 250, 250, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '1900-01-01');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, transport_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2026-09-30', 500, 1000, 150, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-09-30');
-- guests sort first (checkin 60 days back) so a real calendar row on the same date cannot change the guest read
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s94-d1', 'airbnb', 'confirmed', 'Aaazzone Reyes',   current_date - 60, current_date - 3),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s94-d2', 'airbnb', 'confirmed', 'Aaazztwo Cruz',    current_date - 60, current_date - 4),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s94-d3', 'airbnb', 'confirmed', 'Aaazzthree Lim',  current_date - 60, current_date - 5),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s94-d4', 'airbnb', 'confirmed', 'Aaazzfour Uy',    current_date - 60, current_date - 6);
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, submitted_by_user_id) values
  ('c9400000-0000-4000-8000-0000000000b4', 'zz-c94-d4', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', current_date - 6, 'turnover', 'c9400000-0000-4000-8000-0000000000a1'),
  ('c9400000-0000-4000-8000-0000000000b9', 'zz-c94-old', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', current_date - 9, 'turnover', 'c9400000-0000-4000-8000-0000000000a1');

-- a real backup holds real sessions on the same dates: make them mid-stay (never a match for a checkout) so only the fixtures decide what is missed; rolled back with the suite
update public.cleaning_sessions set cleaning_type = 'mid_stay' where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and submission_id not like 'zz-c94-%';
-- a real backup holds live advance lines on real dates: cancel every non-fixture request inside this transaction so only the fixtures hold dates; rolled back with the suite
update public.staff_pay_requests set status = 'cancelled', cancelled_at = now() where status <> 'cancelled' and idempotency_key not like 'zz-c94-%';

-- 1. happy path: two advance dates, one with transport ---------------------------------------------------------------------------------------------
select pg_temp.as_user('c9400000-0000-4000-8000-0000000000a3');
insert into _t select 'r1', public.staff_pay_admin_create_v2('c9400000-0000-4000-8000-0000000000a1', '[]'::jsonb, '{}'::uuid[],
  jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 3)::text, 'transport', true), jsonb_build_object('checkout_date', (current_date - 4)::text, 'transport', false)),
  'zz-c94-key-0001');
reset role;
select is((select v->>'ok' from _t where k = 'r1'), 'true', 'create_v2 accepts two owed checkouts');
select is((select (v->>'total')::numeric from _t where k = 'r1'), 1150::numeric, 'total = 500 + 150 transport + 500');
select is((select count(*)::int from jsonb_array_elements((select v->'lines' from _t where k = 'r1')) l where l->>'kind' = 'advance' and not l ? 'session_id' and l->>'date' = l->>'checkout_date'), 2,
  'both lines are kind advance, carry checkout_date = date and no session_id');
select is((select l->>'guest' from jsonb_array_elements((select v->'lines' from _t where k = 'r1')) l where l->>'checkout_date' = (current_date - 3)::text), 'Aaazzone', 'the line names the guest by first name');
select is((select (l->>'amount')::numeric from jsonb_array_elements((select v->'lines' from _t where k = 'r1')) l where l->>'checkout_date' = (current_date - 3)::text), 650::numeric, 'a line with transport is 650');

-- 2. refusals ---------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('c9400000-0000-4000-8000-0000000000a3');
insert into _t select 'not_owed4', public.staff_pay_admin_create_v2('c9400000-0000-4000-8000-0000000000a1', '[]'::jsonb, '{}'::uuid[],
  jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 6)::text)), 'zz-c94-key-0002');
insert into _t select 'not_owed5', public.staff_pay_admin_create_v2('c9400000-0000-4000-8000-0000000000a1', '[]'::jsonb, '{}'::uuid[],
  jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 45)::text)), 'zz-c94-key-0003');
insert into _t select 'taken', public.staff_pay_admin_create_v2('c9400000-0000-4000-8000-0000000000a1', '[]'::jsonb, '{}'::uuid[],
  jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 3)::text)), 'zz-c94-key-0004');
insert into _t select 'dup', public.staff_pay_admin_create_v2('c9400000-0000-4000-8000-0000000000a1', '[]'::jsonb, '{}'::uuid[],
  jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 5)::text), jsonb_build_object('checkout_date', (current_date - 5)::text)), 'zz-c94-key-0005');
insert into _t select 'badfmt', public.staff_pay_admin_create_v2('c9400000-0000-4000-8000-0000000000a1', '[]'::jsonb, '{}'::uuid[],
  jsonb_build_array(jsonb_build_object('checkout_date', '2026-13-45')), 'zz-c94-key-0006');
insert into _t select 'empty', public.staff_pay_admin_create_v2('c9400000-0000-4000-8000-0000000000a1', '[]'::jsonb, '{}'::uuid[], null, 'zz-c94-key-0007');
reset role;
select is((select v->>'reason' from _t where k = 'not_owed4'), 'advance_not_owed', 'a checkout that already has a report is advance_not_owed');
select is((select v->>'reason' from _t where k = 'not_owed5'), 'advance_not_owed', 'a date outside the 30-day missed list is advance_not_owed');
select is((select v->>'reason' from _t where k = 'taken'), 'advance_taken', 'a date held by a live request is advance_taken');
select is((select v->>'ref' from _t where k = 'taken'), (select v->>'ref' from _t where k = 'r1'), 'and the refusal names that request');
select is((select v->>'reason' from _t where k = 'dup'), 'bad_request', 'the same date twice in one call is bad_request');
select is((select v->>'reason' from _t where k = 'badfmt'), 'bad_request', 'an impossible date is bad_request');
select is((select v->>'reason' from _t where k = 'empty'), 'no_lines', 'nothing to pay is no_lines');

-- 3. v1 still works, as a wrapper --------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('c9400000-0000-4000-8000-0000000000a3');
insert into _t select 'v1', public.staff_pay_admin_create_v1('c9400000-0000-4000-8000-0000000000a1', '[{"id":"c9400000-0000-4000-8000-0000000000b9","transport":false}]'::jsonb, '{}'::uuid[], 'zz-c94-key-0008');
reset role;
select is((select v->>'ok' from _t where k = 'v1'), 'true', 'staff_pay_admin_create_v1 still makes a request for a reported session');
select is((select (v->>'total')::numeric from _t where k = 'v1'), 500::numeric, 'at the same price as before');

-- 4. staff and admin read models ----------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('c9400000-0000-4000-8000-0000000000a1');
insert into _t select 'cand1', public.staff_pay_candidates_v1();
reset role;
select is((select jsonb_array_length(v->'reports_owed') from _t where k = 'cand1'), 2, 'candidates: two reports owed for the payee');
select is((select v->'reports_owed'->0->>'ref' from _t where k = 'cand1'), (select v->>'ref' from _t where k = 'r1'), 'each entry carries the request ref');
select ok((select v ? 'sessions' and v ? 'claims' and v ? 'missing_reports' and v ? 'requests' from _t where k = 'cand1'), 'the rest of the candidates payload is unchanged');
select pg_temp.as_user('c9400000-0000-4000-8000-0000000000a3');
insert into _t select 'list1', public.staff_pay_admin_list_v1();
reset role;
select is((select count(*)::int from jsonb_array_elements((select v->'advance_candidates' from _t where k = 'list1')) a where a->>'checkout_date' = (current_date - 5)::text and a->>'guest' = 'Aaazzthree'), 1,
  'admin list offers the owed checkout nobody holds, with the guest and rate');
select is((select count(*)::int from jsonb_array_elements((select v->'advance_candidates' from _t where k = 'list1')) a where a->>'checkout_date' in ((current_date - 3)::text, (current_date - 4)::text, (current_date - 6)::text)), 0,
  'and not the held ones or the reported one');

select is((select count(*)::int from jsonb_array_elements((select v->'payees' from _t where k = 'list1')) a where a->>'user_id' in ('c9400000-0000-4000-8000-0000000000a1', 'c9400000-0000-4000-8000-0000000000a2') and a ? 'name' and a ? 'has_qr'), 2,
  'admin list: payees offers the cleaners (user_id, name, has_qr)');
select is((select l->>'checkout_date' from jsonb_array_elements((select l2->'lines' from jsonb_array_elements((select v->'requests' from _t where k = 'list1')) l2 where l2->>'ref' = (select v->>'ref' from _t where k = 'r1'))) l where l->>'guest' = 'Aaazzone'), (current_date - 3)::text,
  'admin list: an advance line passes guest and checkout_date through');

-- 5. the link trigger ------------------------------------------------------------------------------------------------------------------------------------
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, submitted_by_user_id) values
  ('c9400000-0000-4000-8000-0000000000b1', 'zz-c94-d1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', current_date - 3, 'turnover', 'c9400000-0000-4000-8000-0000000000a1'),
  ('c9400000-0000-4000-8000-0000000000b8', 'zz-c94-mid', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', current_date - 4, 'mid_stay', 'c9400000-0000-4000-8000-0000000000a1'),
  ('c9400000-0000-4000-8000-0000000000b7', 'zz-c94-oth', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzother', current_date - 8, 'turnover', 'c9400000-0000-4000-8000-0000000000a2');
select is((select pay_request_id from public.cleaning_sessions where id = 'c9400000-0000-4000-8000-0000000000b1'), (select (v->>'id')::uuid from _t where k = 'r1'), 'a later report by the payee joins the request that paid its checkout ahead');
select ok((select fee_paid_at is null from public.cleaning_sessions where id = 'c9400000-0000-4000-8000-0000000000b1'), 'and is not stamped paid while the request is open');
select ok((select pay_request_id is null from public.cleaning_sessions where id = 'c9400000-0000-4000-8000-0000000000b8'), 'a mid-stay report is never linked');
select ok((select pay_request_id is null from public.cleaning_sessions where id = 'c9400000-0000-4000-8000-0000000000b7'), 'nor is a report by someone who is not the payee');
select pg_temp.as_user('c9400000-0000-4000-8000-0000000000a1');
insert into _t select 'cand2', public.staff_pay_candidates_v1();
reset role;
select is((select jsonb_array_length(v->'reports_owed') from _t where k = 'cand2'), 1, 'candidates: one report still owed after D1 was filed');
select is((select count(*)::int from jsonb_array_elements((select v->'sessions' from _t where k = 'cand2')) s where s->>'id' = 'c9400000-0000-4000-8000-0000000000b1'), 0, 'the linked report is not offered again as an unpaid candidate');

-- 6. pay it: settle writes one cleanadv row per line, once ------------------------------------------------------------------------------------------------
select pg_temp.as_user('c9400000-0000-4000-8000-0000000000a3');
insert into _t select 'pay', public.staff_pay_admin_step_v1((select (v->>'id')::uuid from _t where k = 'r1'), 'pay');
reset role;
insert into _t select 'settle', public.staff_pay_settle_v1((select (v->>'id')::uuid from _t where k = 'r1'), null, 'Zz Admin', 'match',
  jsonb_build_object('file_unique_id', 'zz-c94-proof-1', 'sha256', 'zz-c94-sha-1', 'amount', 1150, 'reference', 'ZZC94REF1'));
select is((select v->>'ok' from _t where k = 'settle'), 'true', 'staff_pay_settle_v1 settles a request made of advance lines');
select is((select count(*)::int from public.transactions where external_ref like 'cleanadv:' || (select v->>'id' from _t where k = 'r1') || ':%'
             and txn_type = 'expense' and category = 'cleaning' and status = 'confirmed' and source = 'cleaner_fee'), 2, 'two cleanadv expense rows');
select is((select sum(gross_amount) from public.transactions where external_ref like 'cleanadv:' || (select v->>'id' from _t where k = 'r1') || ':%'), 1150::numeric, 'worth 1,150 together');
select is((select logged_by from public.transactions where external_ref = 'cleanadv:' || (select v->>'id' from _t where k = 'r1') || ':' || (current_date - 3)), 'Zz Admin', 'logged_by is the actor when no Telegram id is given');
select ok((select notes like '%paid ahead, report owed%' from public.transactions where external_ref = 'cleanadv:' || (select v->>'id' from _t where k = 'r1') || ':' || (current_date - 3)), 'the note says paid ahead, report owed');
select ok((select fee_paid_at is not null and fee_amount = 650 and fee_txn_id = (select t.id from public.transactions t where t.external_ref = 'cleanadv:' || (select v->>'id' from _t where k = 'r1') || ':' || (current_date - 3))
             from public.cleaning_sessions where id = 'c9400000-0000-4000-8000-0000000000b1'), 'the report already filed for D1 is stamped paid with its row');
select ok((select status = 'paid' from public.staff_pay_requests where id = (select (v->>'id')::uuid from _t where k = 'r1')), 'the request is paid');
select lives_ok($q$select public.staff_pay_settle_v1((select (v->>'id')::uuid from _t where k = 'r1'), null, 'Zz Admin', 'match', null)$q$, 'a second settle pass runs');
select is((select count(*)::int from public.transactions where external_ref like 'cleanadv:' || (select v->>'id' from _t where k = 'r1') || ':%'), 2, 'a second pass writes no second row (idempotent on the ref)');

-- 7. the paid notice names the report still owed; a report filed after payment is stamped paid at once --------------------------------------------------------------
insert into _t select 'notice', public.staff_pay_notice_v1((select (v->>'id')::uuid from _t where k = 'r1'), 'claim');
select is((select v->'reports_owed' from _t where k = 'notice'), to_jsonb(array[(current_date - 4)::text]), 'staff_pay_notice_v1 lists the checkout dates still owed');
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, submitted_by_user_id) values
  ('c9400000-0000-4000-8000-0000000000b2', 'zz-c94-d2', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', current_date - 4, 'turnover', 'c9400000-0000-4000-8000-0000000000a1');
select ok((select pay_request_id = (select (v->>'id')::uuid from _t where k = 'r1') and fee_paid_at = (select paid_at from public.staff_pay_requests where id = pay_request_id) and fee_amount = 500
             and fee_txn_id = (select t.id from public.transactions t where t.external_ref = 'cleanadv:' || (select v->>'id' from _t where k = 'r1') || ':' || (current_date - 4))
             from public.cleaning_sessions where id = 'c9400000-0000-4000-8000-0000000000b2'), 'a report filed after payment joins the paid request and is stamped paid with its row');

-- 8. meter follow-ups: a settled session drops out ---------------------------------------------------------------------------------------------------------------
insert into public.meter_readings(session_id, property_id, vision_verdict) values
  ('c9400000-0000-4000-8000-0000000000b1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'unreadable'),
  ('c9400000-0000-4000-8000-0000000000b4', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'unreadable');
select pg_temp.as_user('c9400000-0000-4000-8000-0000000000a3');
insert into _t select 'f', coalesce(jsonb_agg(f.session_id), '[]'::jsonb) from public.get_meter_photo_followups('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 30) f;
reset role;
select is((select v @> jsonb_build_array('c9400000-0000-4000-8000-0000000000b4'::text) from _t where k = 'f'), true, 'follow-ups: an unpaid session with an unreadable photo is listed');
select is((select v @> jsonb_build_array('c9400000-0000-4000-8000-0000000000b1'::text) from _t where k = 'f'), false, 'follow-ups: the paid session with the same verdict is not');

-- 9. cancel releases a session the trigger linked -----------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('c9400000-0000-4000-8000-0000000000a3');
insert into _t select 'r3', public.staff_pay_admin_create_v2('c9400000-0000-4000-8000-0000000000a1', '[]'::jsonb, '{}'::uuid[],
  jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 5)::text)), 'zz-c94-key-0009');
reset role;
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, submitted_by_user_id) values
  ('c9400000-0000-4000-8000-0000000000b3', 'zz-c94-d3', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', current_date - 5, 'turnover', 'c9400000-0000-4000-8000-0000000000a1');
select is((select pay_request_id from public.cleaning_sessions where id = 'c9400000-0000-4000-8000-0000000000b3'), (select (v->>'id')::uuid from _t where k = 'r3'), 'D3: the report joins the open advance request');
select pg_temp.as_user('c9400000-0000-4000-8000-0000000000a3');
insert into _t select 'cancel3', public.staff_pay_admin_step_v1((select (v->>'id')::uuid from _t where k = 'r3'), 'cancel');
reset role;
select ok((select pay_request_id is null from public.cleaning_sessions where id = 'c9400000-0000-4000-8000-0000000000b3') and (select v->>'ok' = 'true' from _t where k = 'cancel3'), 'cancelling the request releases the linked report (it is a candidate again)');

-- 9b. consecutive checkouts never take each other's report; a guest-less row is not a stay to pay ---------------------------------------------------------------
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s94-e1', 'airbnb', 'confirmed', 'Aaazzfive Ong', current_date - 60, current_date - 12),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s94-e2', 'airbnb', 'confirmed', 'Aaazzsix Tan',  current_date - 60, current_date - 11),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s94-e3', 'airbnb', 'confirmed', null,             current_date - 60, current_date - 13);
select pg_temp.as_user('c9400000-0000-4000-8000-0000000000a3');
insert into _t select 'r4', public.staff_pay_admin_create_v2('c9400000-0000-4000-8000-0000000000a1', '[]'::jsonb, '{}'::uuid[],
  jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 12)::text), jsonb_build_object('checkout_date', (current_date - 11)::text)), 'zz-c94-key-0011');
insert into _t select 'noguest', public.staff_pay_admin_create_v2('c9400000-0000-4000-8000-0000000000a1', '[]'::jsonb, '{}'::uuid[],
  jsonb_build_array(jsonb_build_object('checkout_date', (current_date - 13)::text)), 'zz-c94-key-0012');
reset role;
select is((select coalesce(v->>'reason', 'ok') || ' ' || coalesce(v->>'date', '') from _t where k = 'r4'), 'ok ', 'D and D+1 advance request is made');
select is((select v->>'reason' from _t where k = 'noguest'), 'advance_not_owed', 'a missed row with no guest is advance_not_owed');
-- the report for D+1 (cd-11) is filed first, at midday Manila on its own day
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, submitted_by_user_id, cleaned_at) values
  ('c9400000-0000-4000-8000-0000000000c2', 'zz-c94-e2', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', current_date - 11, 'turnover', 'c9400000-0000-4000-8000-0000000000a1', ((current_date - 11)::text || ' 12:00+08')::timestamptz);
select is((select pay_request_id from public.cleaning_sessions where id = 'c9400000-0000-4000-8000-0000000000c2'), (select (v->>'id')::uuid from _t where k = 'r4'), 'the D+1 report joins the request');
select pg_temp.as_user('c9400000-0000-4000-8000-0000000000a1');
insert into _t select 'cand4', public.staff_pay_candidates_v1();
reset role;
select is((select jsonb_agg(e->>'date') from jsonb_array_elements((select v->'reports_owed' from _t where k = 'cand4')) e where e->>'ref' = (select v->>'ref' from _t where k = 'r4')), to_jsonb(array[(current_date - 12)::text]),
  'D is still owed after the D+1 report (it did not take the line of D)');
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, submitted_by_user_id, cleaned_at) values
  ('c9400000-0000-4000-8000-0000000000c1', 'zz-c94-e1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', current_date - 12, 'turnover', 'c9400000-0000-4000-8000-0000000000a1', ((current_date - 12)::text || ' 12:00+08')::timestamptz);
select is((select pay_request_id from public.cleaning_sessions where id = 'c9400000-0000-4000-8000-0000000000c1'), (select (v->>'id')::uuid from _t where k = 'r4'), 'then the D report joins the same request');
select pg_temp.as_user('c9400000-0000-4000-8000-0000000000a3');
insert into _t select 'pay4', public.staff_pay_admin_step_v1((select (v->>'id')::uuid from _t where k = 'r4'), 'pay');
reset role;
insert into _t select 'settle4', public.staff_pay_settle_v1((select (v->>'id')::uuid from _t where k = 'r4'), null, 'Zz Admin', 'match',
  jsonb_build_object('file_unique_id', 'zz-c94-proof-4', 'sha256', 'zz-c94-sha-4', 'amount', 1000, 'reference', 'ZZC94REF4'));
select ok((select bool_and(cs.fee_txn_id = (select t.id from public.transactions t where t.external_ref = 'cleanadv:' || cs.pay_request_id || ':' || cs.checkout_date)) and count(*) = 2
             from public.cleaning_sessions cs where cs.id in ('c9400000-0000-4000-8000-0000000000c1', 'c9400000-0000-4000-8000-0000000000c2') and cs.fee_paid_at is not null),
          'each report is stamped with its own cleanadv transaction');
select is((select count(*)::int from public.transactions where external_ref like 'cleanadv:' || (select v->>'id' from _t where k = 'r4') || ':%'), 2, 'and exactly two cleanadv rows exist for the request');

-- 10. a line kind settle does not know is refused, not paid as a claim ------------------------------------------------------------------------------------------------
insert into public.staff_pay_requests(id, property_id, payee_user_id, payee_name, idempotency_key, status, lines, total_amount)
values ('c9400000-0000-4000-8000-0000000000e1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'c9400000-0000-4000-8000-0000000000a1', 'Zzhoney', 'zz-c94-key-0010', 'paying',
        '[{"kind":"zzz","date":"2026-10-01","amount":10}]'::jsonb, 10);
select is((select public.staff_pay_settle_v1('c9400000-0000-4000-8000-0000000000e1', null, 'Zz', 'match', null) ->> 'reason'), 'bad_line', 'settle refuses a line of an unknown kind');

-- 11. prechecks table: service_role only -------------------------------------------------------------------------------------------------------------------------------
select ok((select relrowsecurity from pg_class where oid = 'public.meter_photo_prechecks'::regclass), 'meter_photo_prechecks has RLS on');
select ok(has_table_privilege('service_role', 'public.meter_photo_prechecks', 'insert') and not has_table_privilege('authenticated', 'public.meter_photo_prechecks', 'select')
          and not has_table_privilege('anon', 'public.meter_photo_prechecks', 'select'), 'only service_role can touch meter_photo_prechecks');

select * from finish();
rollback;
