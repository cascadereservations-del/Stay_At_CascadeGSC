-- Session 115 (lane S): release s115_integrity_20261114. docs/s115/PLAN.md sections 2, 4, 5.
--   get_missed_cleanings counts only a CONFIRMED calendar row; the pay screen and create_v2 inherit it (advance_not_owed on a blocked date);
--   staff_guest_card_v1 notes carry "YYYY-MM-DD: Turnover report: ..." from an earlier stay's turnover (redaction still applies); get_guest_timeline_v1 has a turnover_report event;
--   run_system_verifier_v1 V20 / V21 / V22 and apply_verifier_run_v1 scopes + the 7-day expiry of an acknowledged RED finding.
-- Synthetic fixtures only (uuids c1150000-.../e1150000-...). A real backup holds real rows, so the real property's calendar, sessions, requests and llm_usage are neutralised
-- inside this transaction; everything rolls back.
begin;
select plan(86);

grant usage on schema public, auth, storage to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal2', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
-- the finding for a key prefix, from a verifier run held in _t
create function pg_temp.f(p_run text, p_like text) returns jsonb language sql as $$
  select coalesce((select jsonb_agg(x) from _t, jsonb_array_elements(_t.v -> 'found') x where _t.k = p_run and x ->> 'key' like p_like), '[]'::jsonb);
$$;

-- ===== fixtures on the real property id (the pay functions hard-code it) =====
insert into auth.users(id, email) values
  ('c1150000-0000-4000-8000-0000000000a1', 'zz-s115-honey@example.com'), ('c1150000-0000-4000-8000-0000000000a3', 'zz-s115-admin@example.com');
insert into public.staff_access_profiles(user_id, role) values ('c1150000-0000-4000-8000-0000000000a1', 'cleaner'), ('c1150000-0000-4000-8000-0000000000a3', 'admin');
insert into public.properties(id, name, is_active) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Cascade Hideaway', true) on conflict (id) do nothing;
insert into public.staff_property_access(user_id, property_id) select u, '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
  from unnest(array['c1150000-0000-4000-8000-0000000000a1', 'c1150000-0000-4000-8000-0000000000a3']::uuid[]) u;
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '1900-01-01', 250, 250, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '1900-01-01');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, transport_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2026-09-30', 500, 1000, 150, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-09-30');

-- neutralise the real rows (rolled back with the suite)
update public.calendar_events set status = 'cancelled' where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
update public.cleaning_sessions set cleaning_type = 'mid_stay' where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
update public.staff_pay_requests set status = 'cancelled', cancelled_at = now() where status <> 'cancelled';
delete from public.verifier_findings;
delete from public.llm_usage;

-- calendar: E1 confirmed (T-3), E2 blocked + named (T-4), E3 blocked unnamed (T-5), E4 manual blocked + named (T-6)
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s115-e1', 'airbnb', 'confirmed', 'Aaazz Real Stay',   public.manila_today() - 60, public.manila_today() - 3),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s115-e2', 'airbnb', 'blocked',   'Aaazz Cancelled',   public.manila_today() - 60, public.manila_today() - 4),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s115-e3', 'airbnb', 'blocked',   null,                public.manila_today() - 60, public.manila_today() - 5),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s115-e4', 'manual', 'blocked',   'Aaazz Brownout',    public.manila_today() - 60, public.manila_today() - 6);

-- 1-3. get_missed_cleanings -------------------------------------------------------------------------------------------------------------------
select is((select array_agg(checkout_date order by checkout_date) from public.get_missed_cleanings('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 14)),
  array[public.manila_today() - 3], 'only the confirmed checkout is missed; blocked rows (named, unnamed, airbnb, manual) are not');
select is((select guest_name from public.get_missed_cleanings('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 14)), 'Aaazz Real Stay', 'and it is the confirmed guest');
select is((select days_overdue from public.get_missed_cleanings('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 14)), 3, 'days_overdue is unchanged (T minus checkout)');

-- 4-9. the pay screen and create_v2 inherit it ------------------------------------------------------------------------------------------------
select pg_temp.as_user('c1150000-0000-4000-8000-0000000000a1');
insert into _t select 'cand', public.staff_pay_candidates_v1();
insert into _t select 'adv_blocked', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb, jsonb_build_array(jsonb_build_object('checkout_date', (public.manila_today() - 4)::text)), 'zz-s115-ref-0001');
insert into _t select 'adv_real',    public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[]'::jsonb, jsonb_build_array(jsonb_build_object('checkout_date', (public.manila_today() - 3)::text)), 'zz-s115-ref-0002');
reset role; select set_config('request.jwt.claims', '{}', true);
select is((select v -> 'missing_reports' from _t where k = 'cand'), jsonb_build_array((public.manila_today() - 3)::text), 'missing_reports lists the confirmed checkout only');
select is((select count(*)::int from jsonb_array_elements((select v -> 'advance' from _t where k = 'cand')) a), 1, 'the advance list holds one date');
select is((select a ->> 'checkout_date' from jsonb_array_elements((select v -> 'advance' from _t where k = 'cand')) a), (public.manila_today() - 3)::text, 'and it is the confirmed one');
select is((select v ->> 'reason' from _t where k = 'adv_blocked'), 'advance_not_owed', 'create_v2 refuses an advance on a blocked, named date');
select is((select v ->> 'ok' from _t where k = 'adv_real'), 'true', 'create_v2 still accepts the confirmed checkout');
select is((select v ->> 'total' from _t where k = 'adv_real'), '500.00', 'priced as the base turnover rate (no transport asked)');

-- ===== V20 fixtures =====
-- RA paid 5 d ago, advance for T-12 which is no confirmed checkout                      -> advance_no_stay (red)
-- RB paid 5 d ago, advance T-10 (confirmed), her report names T-9, unlinked             -> paid_no_link (red, report_date T-9) + report_no_stay for that report (T-9 has no stay)
-- RC paid 5 d ago, advance T-14 (confirmed) with its report linked                      -> nothing
-- RD paying since 30 h, clean line for session SD;  RE requested, same session SD        -> stuck_paying (RD), session_twice (SD)
-- RF paying since 2 h                                                                   -> nothing;  RH paid 1 d ago, advance T-8 with an unlinked report T-8 -> nothing (3-day rule)
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s115-c10', 'airbnb', 'confirmed', 'Aaazz Ten',    public.manila_today() - 60, public.manila_today() - 10),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s115-c14', 'airbnb', 'confirmed', 'Aaazz Fourteen', public.manila_today() - 60, public.manila_today() - 14),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s115-c20', 'airbnb', 'confirmed', 'Aaazz Twenty', public.manila_today() - 60, public.manila_today() - 20),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s115-c30', 'airbnb', 'confirmed', 'Aaazz Thirty', public.manila_today() - 60, public.manila_today() - 30),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s115-c08', 'airbnb', 'confirmed', 'Aaazz Eight',  public.manila_today() - 60, public.manila_today() - 8);
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, cleaned_at, submitted_by_user_id) values
  ('c1150000-0000-4000-8000-0000000000b1', 'zz-s115-sb', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney', public.manila_today() - 9,  'turnover', now() - interval '8 days', 'c1150000-0000-4000-8000-0000000000a1'),
  ('c1150000-0000-4000-8000-0000000000b2', 'zz-s115-sc', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney', public.manila_today() - 14, 'turnover', now() - interval '13 days', 'c1150000-0000-4000-8000-0000000000a1'),
  ('c1150000-0000-4000-8000-0000000000b3', 'zz-s115-sd', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney', public.manila_today() - 20, 'turnover', now() - interval '19 days', 'c1150000-0000-4000-8000-0000000000a1'),
  ('c1150000-0000-4000-8000-0000000000b4', 'zz-s115-sh', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney', public.manila_today() - 8,  'turnover', now() - interval '7 days', 'c1150000-0000-4000-8000-0000000000a1'),
  ('c1150000-0000-4000-8000-0000000000b5', 'zz-s115-sm', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney', public.manila_today() - 30, 'mid_stay', now() - interval '29 days', 'c1150000-0000-4000-8000-0000000000a1');
insert into public.staff_pay_requests(id, property_id, payee_user_id, payee_name, idempotency_key, status, lines, total_amount, paid_at, proof_file_unique_id, proof_sha256, proof_verdict, paid_by_name, paying_at, created_at) values
  ('c11500a1-0000-4000-8000-00000000f0a1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'c1150000-0000-4000-8000-0000000000a1', 'Zzhoney', 'zz-s115-RA-key', 'paid',
     jsonb_build_array(jsonb_build_object('kind', 'advance', 'date', (public.manila_today() - 12)::text, 'checkout_date', (public.manila_today() - 12)::text, 'amount', 650)), 650, now() - interval '5 days', 'zzf-a', 'zzs-a', 'match', 'Lloyd', null, now() - interval '5 days'),
  ('c11500b1-0000-4000-8000-00000000f0b1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'c1150000-0000-4000-8000-0000000000a1', 'Zzhoney', 'zz-s115-RB-key', 'paid',
     jsonb_build_array(jsonb_build_object('kind', 'advance', 'date', (public.manila_today() - 10)::text, 'checkout_date', (public.manila_today() - 10)::text, 'amount', 650)), 650, now() - interval '5 days', 'zzf-b', 'zzs-b', 'match', 'Lloyd', null, now() - interval '5 days'),
  ('c11500c1-0000-4000-8000-00000000f0c1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'c1150000-0000-4000-8000-0000000000a1', 'Zzhoney', 'zz-s115-RC-key', 'paid',
     jsonb_build_array(jsonb_build_object('kind', 'advance', 'date', (public.manila_today() - 14)::text, 'checkout_date', (public.manila_today() - 14)::text, 'amount', 650)), 650, now() - interval '5 days', 'zzf-c', 'zzs-c', 'match', 'Lloyd', null, now() - interval '5 days'),
  ('c11500d1-0000-4000-8000-00000000f0d1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'c1150000-0000-4000-8000-0000000000a1', 'Zzhoney', 'zz-s115-RD-key', 'paying',
     jsonb_build_array(jsonb_build_object('kind', 'clean', 'date', (public.manila_today() - 20)::text, 'session_id', 'c1150000-0000-4000-8000-0000000000b3', 'amount', 650)), 650, null, null, null, null, null, now() - interval '30 hours', now() - interval '31 hours'),
  ('c11500e1-0000-4000-8000-00000000f0e1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'c1150000-0000-4000-8000-0000000000a1', 'Zzhoney', 'zz-s115-RE-key', 'requested',
     jsonb_build_array(jsonb_build_object('kind', 'clean', 'date', (public.manila_today() - 20)::text, 'session_id', 'c1150000-0000-4000-8000-0000000000b3', 'amount', 650)), 650, null, null, null, null, null, null, now() - interval '3 hours'),
  ('c11500f1-0000-4000-8000-00000000f0f1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'c1150000-0000-4000-8000-0000000000a1', 'Zzhoney', 'zz-s115-RF-key', 'paying',
     jsonb_build_array(jsonb_build_object('kind', 'advance', 'date', (public.manila_today() - 30)::text, 'checkout_date', (public.manila_today() - 30)::text, 'amount', 650)), 650, null, null, null, null, null, now() - interval '2 hours', now() - interval '3 hours'),
  ('c11500a8-0000-4000-8000-00000000f0a8', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'c1150000-0000-4000-8000-0000000000a1', 'Zzhoney', 'zz-s115-RH-key', 'paid',
     jsonb_build_array(jsonb_build_object('kind', 'advance', 'date', (public.manila_today() - 8)::text, 'checkout_date', (public.manila_today() - 8)::text, 'amount', 650)), 650, now() - interval '1 day', 'zzf-h', 'zzs-h', 'match', 'Lloyd', null, now() - interval '1 day');
update public.cleaning_sessions set pay_request_id = 'c11500c1-0000-4000-8000-00000000f0c1', fee_paid_at = now() - interval '5 days' where id = 'c1150000-0000-4000-8000-0000000000b2';
update public.cleaning_sessions set pay_request_id = 'c11500d1-0000-4000-8000-00000000f0d1' where id = 'c1150000-0000-4000-8000-0000000000b3';

insert into _t select 'h', public.run_system_verifier_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'hourly', now());
insert into _t select 'd', public.run_system_verifier_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'daily', now());

-- 10-24. V20 ---------------------------------------------------------------------------------------------------------------------------------------
select is(jsonb_array_length(pg_temp.f('h', 'V20:advance_no_stay:%')), 1, 'advance_no_stay: exactly one line is for a date with no confirmed checkout (hourly)');
select is(pg_temp.f('h', 'V20:advance_no_stay:%') -> 0 ->> 'key', 'V20:advance_no_stay:C11500A1:' || (public.manila_today() - 12), 'its key is ref then date');
select is(pg_temp.f('h', 'V20:advance_no_stay:%') -> 0 ->> 'severity', 'red', 'red');
select is(pg_temp.f('h', 'V20:advance_no_stay:%') -> 0 -> 'detail', jsonb_build_object('ref', 'C11500A1', 'date', (public.manila_today() - 12)::text, 'payee', 'Zzhoney'), 'detail is ref, date, payee');
select is(jsonb_array_length(pg_temp.f('h', 'V20:paid_no_link:%')), 1, 'paid_no_link: one paid advance has no linked report but a report beside it');
select is(pg_temp.f('h', 'V20:paid_no_link:%') -> 0 -> 'detail', jsonb_build_object('ref', 'C11500B1', 'date', (public.manila_today() - 10)::text, 'payee', 'Zzhoney',
  'session', 'c1150000-0000-4000-8000-0000000000b1', 'report_date', (public.manila_today() - 9)::text), 'detail carries session and report_date (contract amendment 1)');
select is(pg_temp.f('h', 'V20:paid_no_link:%') -> 0 ->> 'severity', 'red', 'paid_no_link is red');
select is(jsonb_array_length(pg_temp.f('h', 'V20:stuck_paying:%')), 1, 'stuck_paying: only the request paying for 30 h (not the one paying for 2 h)');
select is(pg_temp.f('h', 'V20:stuck_paying:%') -> 0 ->> 'severity', 'yellow', 'stuck_paying is yellow');
select is(jsonb_array_length(pg_temp.f('h', 'V20:session_twice:%')), 1, 'session_twice: one session sits on two live requests');
select is(pg_temp.f('h', 'V20:session_twice:%') -> 0 ->> 'key', 'V20:session_twice:c1150000-0000-4000-8000-0000000000b3', 'keyed by the session id');
select is(pg_temp.f('h', 'V20:session_twice:%') -> 0 ->> 'severity', 'red', 'session_twice is red');
select is(jsonb_array_length(pg_temp.f('h', 'V20:report_no_stay:%')), 1, 'report_no_stay: one report matches no confirmed stay (the T-9 one); linked, mid-stay and matched reports are quiet');
select is(pg_temp.f('h', 'V20:report_no_stay:%') -> 0 ->> 'key', 'V20:report_no_stay:c1150000-0000-4000-8000-0000000000b1', 'and it is the T-9 report');
select is(pg_temp.f('h', 'V20:report_no_stay:%') -> 0 ->> 'severity', 'yellow', 'report_no_stay is yellow');

-- the same fixtures without the defect: nothing fires
update public.staff_pay_requests set status = 'cancelled', cancelled_at = now() where id in ('c11500a1-0000-4000-8000-00000000f0a1', 'c11500d1-0000-4000-8000-00000000f0d1', 'c11500e1-0000-4000-8000-00000000f0e1');
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s115-c09', 'airbnb', 'confirmed', 'Aaazz Nine', public.manila_today() - 60, public.manila_today() - 9);
update public.cleaning_sessions set pay_request_id = 'c11500b1-0000-4000-8000-00000000f0b1', fee_paid_at = now() - interval '5 days' where id = 'c1150000-0000-4000-8000-0000000000b1';
update public.staff_pay_requests set status = 'cancelled', cancelled_at = now() where id = 'c11500f1-0000-4000-8000-00000000f0f1';
insert into _t select 'h2', public.run_system_verifier_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'hourly', now());
select is(jsonb_array_length(pg_temp.f('h2', 'V20:%')), 0, 'repaired data raises no V20 finding at all (the 6FF96A06 shape: relabel + link clears advance_no_stay)');

-- ===== V21 fixtures (daily only) =====
insert into public.airbnb_reservations(id, property_id, confirmation_code, status, guest_name, checkin_date, checkout_date) values
  ('c1150000-0000-4000-8000-0000000000d1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'ZZ115CANC1', 'cancelled', 'Zzjasmin Sarmiento', public.manila_today() + 5, public.manila_today() + 6),
  ('c1150000-0000-4000-8000-0000000000d2', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'ZZ115CANC2', 'cancelled', 'Zzmarco Reyes',      public.manila_today() + 9, public.manila_today() + 11);
insert into public.calendar_events(id, property_id, uid, source, status, guest_name, checkin_date, checkout_date, linked_reservation_id) values
  ('c1150000-0000-4000-8000-0000000000e1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s115-v21a', 'airbnb', 'blocked',   'Zzjasmin', public.manila_today() + 5, public.manila_today() + 6, null),
  ('c1150000-0000-4000-8000-0000000000e2', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s115-v21b', 'airbnb', 'confirmed', 'Zzmarco Reyes', public.manila_today() + 9, public.manila_today() + 11, 'c1150000-0000-4000-8000-0000000000d2'),
  ('c1150000-0000-4000-8000-0000000000e3', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s115-v21c', 'airbnb', 'blocked',   'Zznobody', public.manila_today() + 5, public.manila_today() + 6, null),
  ('c1150000-0000-4000-8000-0000000000e4', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-s115-v21d', 'airbnb', 'blocked',   null,       public.manila_today() + 5, public.manila_today() + 6, null);
insert into _t select 'h3', public.run_system_verifier_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'hourly', now());
insert into _t select 'd3', public.run_system_verifier_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'daily', now());
select is(jsonb_array_length(pg_temp.f('h3', 'V21:%')), 0, 'V21 does not run hourly');
select is(jsonb_array_length(pg_temp.f('d3', 'V21:block_named:%')), 1, 'block_named: one blocked row carries a cancelled guest''s name (first name only matches; unknown and unnamed blocks do not)');
select is(pg_temp.f('d3', 'V21:block_named:%') -> 0 ->> 'key', 'V21:block_named:c1150000-0000-4000-8000-0000000000e1', 'keyed by the event');
select is(pg_temp.f('d3', 'V21:block_named:%') -> 0 ->> 'severity', 'yellow', 'block_named is yellow');
select is(pg_temp.f('d3', 'V21:block_named:%') -> 0 -> 'detail', jsonb_build_object('event', 'c1150000-0000-4000-8000-0000000000e1', 'guest', 'Zzjasmin',
  'from', (public.manila_today() + 5)::text, 'to', (public.manila_today() + 6)::text, 'code', 'ZZ115CANC1'), 'detail is event, guest, from, to, code');
select is(jsonb_array_length(pg_temp.f('d3', 'V21:confirmed_cancelled:%')), 1, 'confirmed_cancelled: one confirmed row is linked to a cancelled reservation');
select is(pg_temp.f('d3', 'V21:confirmed_cancelled:%') -> 0 ->> 'severity', 'red', 'confirmed_cancelled is red');
select is(pg_temp.f('d3', 'V21:confirmed_cancelled:%') -> 0 -> 'detail' ->> 'code', 'ZZ115CANC2', 'and names the reservation code');

-- ===== V22 =====
insert into public.llm_usage(at, title, provider, model, ok, error, probe) values
  (now() - interval '3 hours', 'Cascade Meter',        'gemini', 'g', false, 'gemini_402', false),
  (now() - interval '2 hours', 'Cascade Power Watch',  'gemini', 'g', false, 'gemini_402', false),
  (now() - interval '90 minutes', 'Cascade ID face box', 'gemini', 'g', false, 'gemini_402', false),
  (now() - interval '80 minutes', 'Cascade Guest Details', 'gemini', 'g', false, 'gemini_402', false),
  (now() - interval '70 minutes', 'Cascade Odd Thing', 'gemini', 'g', false, 'gemini_402', false),
  (now() - interval '60 minutes', 'Cascade Meter',     'gemini', 'g', false, 'gemini_500', false),           -- another error: not a credit signal, not in features
  (now() - interval '30 hours', 'Cascade Meter',       'gemini', 'g', true,  null, false),                   -- an old good call: before the refusals
  (now() - interval '5 hours', 'Cascade Meter',        'openrouter', 'o', false, 'openrouter_402', true),    -- a probe: ignored
  (now() - interval '5 hours', 'Cascade Concierge',    'omniroute', 'x', false, 'omniroute_402', false),
  (now() - interval '1 hour', 'Cascade Concierge',     'omniroute', 'x', true, null, false);                 -- answered since the refusal: not gone
insert into _t select 'h4', public.run_system_verifier_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'hourly', now());
select is(jsonb_array_length(pg_temp.f('h4', 'V22:%')), 1, 'V22: one provider has lost its credit (the probe-only and the answered-since providers are quiet)');
select is(pg_temp.f('h4', 'V22:%') -> 0 ->> 'key', 'V22:credit_gone:gemini', 'keyed by provider');
select is(pg_temp.f('h4', 'V22:%') -> 0 ->> 'severity', 'red', 'V22 is red');
select is(pg_temp.f('h4', 'V22:%') -> 0 -> 'detail' ->> 'provider', 'gemini', 'detail.provider');
select ok((pg_temp.f('h4', 'V22:%') -> 0 -> 'detail' -> 'features') @> '["the ID face box", "guest details", "meter readings", "odd Thing", "Power Watch"]'::jsonb
      and '["the ID face box", "guest details", "meter readings", "odd Thing", "Power Watch"]'::jsonb @> (pg_temp.f('h4', 'V22:%') -> 0 -> 'detail' -> 'features'),
  'features are exactly the human strings: the four mapped titles and any other title without "Cascade " and with a lower-case first letter');
select ok((pg_temp.f('h4', 'V22:%') -> 0 -> 'detail' ->> 'since')::timestamptz between now() - interval '3 hours 1 minute' and now() - interval '2 hours 59 minutes',
  'since is the first refusal after the last good call');
insert into public.llm_usage(at, title, provider, model, ok, error, probe) values (now() - interval '10 minutes', 'Cascade Meter', 'gemini', 'g', true, null, false);
insert into _t select 'h5', public.run_system_verifier_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'hourly', now());
select is(jsonb_array_length(pg_temp.f('h5', 'V22:%')), 0, 'one good call since clears V22');

-- amendment 2: a single non-probe *_402 with no good call since is enough; a failed or empty read never fabricates or resolves anything but its own absence
delete from public.llm_usage;
insert into _t select 'h6', public.run_system_verifier_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'hourly', now());
select is(jsonb_array_length(pg_temp.f('h6', 'V22:%')), 0, 'no llm_usage rows at all: no V22 finding');
insert into public.llm_usage(at, title, provider, model, ok, error, probe) values (now() - interval '20 minutes', 'Cascade Meter', 'openrouter', 'o', false, 'openrouter_402', false);
insert into _t select 'h7', public.run_system_verifier_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'hourly', now());
select is(pg_temp.f('h7', 'V22:%') -> 0 -> 'detail', jsonb_build_object('provider', 'openrouter', 'since', (select at from public.llm_usage where provider = 'openrouter'), 'features', jsonb_build_array('meter readings')),
  'one single non-probe 402 row with no good call since raises V22 with that one feature');

-- ===== apply_verifier_run_v1: scopes and the 7-day expiry of an acknowledged red finding =====
delete from public.verifier_findings;
insert into public.verifier_findings(key, check_id, severity, title, detail, status, first_seen, last_seen, acknowledged_at, acknowledged_by) values
  ('V20:zz115:red-old',    'V20', 'red',    'zz red acknowledged 4 d ago',    '{}', 'acknowledged', now() - interval '20 days', now() - interval '1 hour', now() - interval '4 days', 'Lloyd'),
  ('V20:zz115:red-new',    'V20', 'red',    'zz red acknowledged 2 d ago',    '{}', 'acknowledged', now() - interval '20 days', now() - interval '1 hour', now() - interval '2 days', 'Lloyd'),
  ('V20:zz115:yellow-old', 'V20', 'yellow', 'zz yellow acknowledged 4 d ago', '{}', 'acknowledged', now() - interval '20 days', now() - interval '1 hour', now() - interval '4 days', 'Lloyd'),
  ('V22:zz115:gone',       'V22', 'red',    'zz hourly V22',                  '{}', 'open',         now() - interval '2 days',  now() - interval '1 hour', null, null),
  ('V21:zz115:daily',      'V21', 'yellow', 'zz V21',                         '{}', 'open',         now() - interval '2 days',  now() - interval '1 hour', null, null);
select public.apply_verifier_run_v1('hourly', '[
  {"key":"V20:zz115:red-old","check_id":"V20","severity":"red","title":"zz red acknowledged 4 d ago","detail":{}},
  {"key":"V20:zz115:red-new","check_id":"V20","severity":"red","title":"zz red acknowledged 2 d ago","detail":{}},
  {"key":"V20:zz115:yellow-old","check_id":"V20","severity":"yellow","title":"zz yellow acknowledged 4 d ago","detail":{}}]'::jsonb, now());
select is((select status from public.verifier_findings where key = 'V20:zz115:red-old'), 'open', 'an acknowledged RED finding still seen after 3 days re-opens');
select is((select status from public.verifier_findings where key = 'V20:zz115:red-new'), 'acknowledged', 'one acknowledged 2 days ago stays acknowledged');
select is((select status from public.verifier_findings where key = 'V20:zz115:yellow-old'), 'acknowledged', 'a yellow one stays acknowledged');
select is((select status from public.verifier_findings where key = 'V22:zz115:gone'), 'resolved', 'V22 is in the hourly scope: a finding no longer seen resolves');
select is((select status from public.verifier_findings where key = 'V21:zz115:daily'), 'open', 'V21 is not in the hourly scope: left alone');
select ok((select last_alerted_at is not null from public.verifier_findings where key = 'V20:zz115:red-old'), 'and the re-opened red finding is announced again');
select public.apply_verifier_run_v1('daily', '[]'::jsonb, now() + interval '1 minute');
select is((select status from public.verifier_findings where key = 'V21:zz115:daily'), 'resolved', 'V21 is in the daily scope: it resolves');
select is((select status from public.verifier_findings where key = 'V20:zz115:red-new'), 'resolved', 'V20 is in the daily scope too');

-- ===== turnover_issue_text_v1, staff_guest_card_v1, get_guest_timeline_v1 (synthetic property) =====
select is(public.turnover_issue_text_v1(E'[Stay Dates]: Check-in: 2026-11-07 · Check-out: 2026-11-08\n[Pre-Clean Condition]: [URGENT] Ga leak ang faucet sa my cr banda .'), 'Ga leak ang faucet sa my cr banda .', 'extractor: one line, [URGENT] stripped');
select is(public.turnover_issue_text_v1(E'[Pre-Clean Condition]: [URGENT] Blood stain SA beddings and towels\n[Checklist]: Strip bed and towels: Blood stains'), 'Blood stain SA beddings and towels', 'extractor: stops at the next [Section]');
select is(public.turnover_issue_text_v1(E'[Pre-Clean Condition]: [URGENT] 1.bedside table damage\n2. kitchen faucet\n[Confirm & Leave]: x'), '1.bedside table damage 2. kitchen faucet', 'extractor: a multi-line segment becomes one line');
select is(public.turnover_issue_text_v1(E'[Pre-Clean Condition]: [URGENT] natanggal sabitanan | Backfill 2026-09-14: duplicate submission of the same clean, no fee'), 'natanggal sabitanan', 'extractor: drops the backfill remark');
select is(public.turnover_issue_text_v1('[Checklist]: nothing here'), null, 'extractor: no segment is null, not an empty string');

insert into public.properties(id, name, is_active) values ('e1150000-0000-4000-8000-000000000001', 'Synthetic s115 card', true);
insert into public.guests(id, property_id, name) values
  ('e1150000-0000-4000-8000-0000000000c1', 'e1150000-0000-4000-8000-000000000001', 'Zzguest One'),
  ('e1150000-0000-4000-8000-0000000000c2', 'e1150000-0000-4000-8000-000000000001', 'Zzguest Two');
insert into public.airbnb_reservations(property_id, confirmation_code, status, guest_id, guest_name, checkin_date, checkout_date) values
  ('e1150000-0000-4000-8000-000000000001', 'ZZ115A', 'completed', 'e1150000-0000-4000-8000-0000000000c1', 'Zzguest One', date '2026-10-20', date '2026-10-22'),
  ('e1150000-0000-4000-8000-000000000001', 'ZZ115B', 'completed', 'e1150000-0000-4000-8000-0000000000c1', 'Zzguest One', date '2026-11-03', date '2026-11-05'),
  ('e1150000-0000-4000-8000-000000000001', 'ZZ115C', 'completed', 'e1150000-0000-4000-8000-0000000000c1', 'Zzguest One', date '2026-11-07', date '2026-11-08'),
  ('e1150000-0000-4000-8000-000000000001', 'ZZ115D', 'confirmed', 'e1150000-0000-4000-8000-0000000000c2', 'Zzguest Two', date '2026-11-09', date '2026-11-10');
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, cleaned_at, issue_count, notes) values
  ('e1150000-0000-4000-8000-0000000000b1', 'zz-s115-k1', 'e1150000-0000-4000-8000-000000000001', 'Zzhoney', date '2026-10-22', 'turnover', timestamptz '2026-10-22 08:00+08', 1,
     E'[Stay Dates]: x\n[Pre-Clean Condition]: [URGENT] Broken glass sa 0917 123 4567 gamit\n[Checklist]: ok'),
  ('e1150000-0000-4000-8000-0000000000b2', 'zz-s115-k2', 'e1150000-0000-4000-8000-000000000001', 'Zzhoney', date '2026-10-22', 'turnover', timestamptz '2026-10-22 09:00+08', 1,
     E'[Pre-Clean Condition]: [URGENT] Broken glass sa 0917 123 4567 gamit | Backfill 2026-09-14: duplicate submission of the same clean, no fee'),
  ('e1150000-0000-4000-8000-0000000000b3', 'zz-s115-k3', 'e1150000-0000-4000-8000-000000000001', 'Zzhoney', date '2026-11-05', 'turnover', timestamptz '2026-11-05 08:00+08', 0,
     E'[Pre-Clean Condition]: wala problema'),
  ('e1150000-0000-4000-8000-0000000000b4', 'zz-s115-k4', 'e1150000-0000-4000-8000-000000000001', 'Zzhoney', date '2026-11-08', 'turnover', timestamptz '2026-11-08 08:00+08', 1,
     E'[Pre-Clean Condition]: [URGENT] Ga leak ang faucet'),
  ('e1150000-0000-4000-8000-0000000000b5', 'zz-s115-k5', 'e1150000-0000-4000-8000-000000000001', 'Zzhoney', date '2026-11-05', 'mid_stay', timestamptz '2026-11-05 10:00+08', 1,
     E'[Pre-Clean Condition]: [URGENT] mid stay note');
select is(public.staff_guest_card_v1('e1150000-0000-4000-8000-000000000001', 'e1150000-0000-4000-8000-0000000000c1', date '2026-11-09') ->> 'notes',
  '2026-11-08: Turnover report: Ga leak ang faucet || 2026-10-22: Turnover report: Broken glass sa [hidden] gamit',
  'card notes: the issue turnovers of the earlier stays, newest first; duplicate reports merge, issue_count 0 and mid_stay are left out; the phone number is redacted');
select is(public.staff_guest_card_v1('e1150000-0000-4000-8000-000000000001', 'e1150000-0000-4000-8000-0000000000c1', date '2026-11-04') ->> 'notes',
  '2026-10-22: Turnover report: Broken glass sa [hidden] gamit', 'only stays that ended before the check-in being prepared');
select is(public.staff_guest_card_v1('e1150000-0000-4000-8000-000000000001', 'e1150000-0000-4000-8000-0000000000c2', date '2026-11-09') ->> 'notes', null, 'a guest with no earlier stay has no turnover note');
update public.guests set notes = 'Likes quiet rooms' where id = 'e1150000-0000-4000-8000-0000000000c1';
select is(public.staff_guest_card_v1('e1150000-0000-4000-8000-000000000001', 'e1150000-0000-4000-8000-0000000000c1', date '2026-11-04') ->> 'notes',
  'Likes quiet rooms || 2026-10-22: Turnover report: Broken glass sa [hidden] gamit', 'the chunk joins the existing notes with the usual separator');
select ok((select c ?& array['repeat', 'stay_count', 'earlier_stays', 'notes', 'id_photo_path', 'id_face_box', 'tier', 'tier_line', 'notable'] and (select count(*) from jsonb_object_keys(c)) = 9
             from (select public.staff_guest_card_v1('e1150000-0000-4000-8000-000000000001', 'e1150000-0000-4000-8000-0000000000c1', date '2026-11-09') c) x), 'the card keeps its nine keys');

insert into auth.users(id) values ('e1150000-0000-4000-8000-0000000000a1') on conflict do nothing;
insert into public.staff_access_profiles(user_id, role) values ('e1150000-0000-4000-8000-0000000000a1', 'owner') on conflict do nothing;
select pg_temp.as_user('e1150000-0000-4000-8000-0000000000a1');
insert into _t select 'tl', public.get_guest_timeline_v1('e1150000-0000-4000-8000-0000000000c1');
reset role; select set_config('request.jwt.claims', '{}', true);
select is((select count(*)::int from jsonb_array_elements((select v -> 'events' from _t where k = 'tl')) e where e ->> 'kind' = 'turnover_report'), 2, 'timeline: one turnover_report per distinct issue turnover (the duplicate report and the issue-free one are not events)');
select is((select e -> 'body' ->> 'text' from jsonb_array_elements((select v -> 'events' from _t where k = 'tl')) e where e ->> 'kind' = 'turnover_report' and e -> 'body' ->> 'checkout' = '2026-11-08'), 'Ga leak ang faucet', 'body.text');
select ok((select e -> 'body' ?& array['sessionId', 'checkout', 'text', 'issueCount'] and (e -> 'body' ->> 'issueCount') = '1' and e ->> 'source' = 'cleaning_sessions'
            from jsonb_array_elements((select v -> 'events' from _t where k = 'tl')) e where e ->> 'kind' = 'turnover_report' and e -> 'body' ->> 'checkout' = '2026-11-08'), 'body keys sessionId, checkout, text, issueCount; source cleaning_sessions');
select is((select count(*)::int from jsonb_array_elements((select v -> 'events' from _t where k = 'tl')) e where e ->> 'kind' = 'stay'), 3, 'the stay events are unchanged');

-- ===== kpi_tab_v1 utility block (amendment 3): days between CHECKOUT dates, meter chain, checkout months =====
-- Chain (electric, kWh): R1 1000>1020 co 10-27 | R2 1020>1060 co 10-29 filed 10-31 12:16 | R3 1060>1102 co 10-31 filed 10-31 12:21 (late filing: the old days ran report to report = 1, so 42/day)
--   R4 1102>1120 co 11-01 | R5 1102>1150 co 11-03 (starts where R4 starts: an overlap) | R6 1150>1170 co 11-05.
insert into public.properties(id, name, is_active) values ('e1150000-0000-4000-8000-000000000003', 'Synthetic s115 kpi', true);
insert into auth.users(id, email) values ('e1150000-0000-4000-8000-0000000000a4', 'zz-s115-cleaner@example.com') on conflict do nothing;
insert into public.staff_access_profiles(user_id, role) values ('e1150000-0000-4000-8000-0000000000a4', 'cleaner') on conflict do nothing;
insert into public.staff_property_access(user_id, property_id) values ('e1150000-0000-4000-8000-0000000000a4', 'e1150000-0000-4000-8000-000000000003');
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaned_at, nights_stayed, checkout_date, cleaning_type) values
  ('e1150000-0000-4000-8000-0000000000f1', 'zz-s115-m1', 'Zz', 'e1150000-0000-4000-8000-000000000003', timestamptz '2026-10-27 10:00+08', 1, date '2026-10-27', 'turnover'),
  ('e1150000-0000-4000-8000-0000000000f2', 'zz-s115-m2', 'Zz', 'e1150000-0000-4000-8000-000000000003', timestamptz '2026-10-31 20:16+08', 1, date '2026-10-29', 'turnover'),
  ('e1150000-0000-4000-8000-0000000000f3', 'zz-s115-m3', 'Zz', 'e1150000-0000-4000-8000-000000000003', timestamptz '2026-10-31 20:21+08', 2, date '2026-10-31', 'turnover'),
  ('e1150000-0000-4000-8000-0000000000f4', 'zz-s115-m4', 'Zz', 'e1150000-0000-4000-8000-000000000003', timestamptz '2026-11-01 10:00+08', 1, date '2026-11-01', 'turnover'),
  ('e1150000-0000-4000-8000-0000000000f5', 'zz-s115-m5', 'Zz', 'e1150000-0000-4000-8000-000000000003', timestamptz '2026-11-03 10:00+08', 2, date '2026-11-03', 'turnover'),
  ('e1150000-0000-4000-8000-0000000000f6', 'zz-s115-m6', 'Zz', 'e1150000-0000-4000-8000-000000000003', timestamptz '2026-11-05 10:00+08', 2, date '2026-11-05', 'turnover');
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, water_curr, electric_delta, water_delta, meter_flag) values
  ('e1150000-0000-4000-8000-0000000000c1', 'e1150000-0000-4000-8000-0000000000f1', 'e1150000-0000-4000-8000-000000000003', timestamptz '2026-10-27 10:00+08', 1000, 1020, 10, 10.5, 20, 0.5, null),
  ('e1150000-0000-4000-8000-0000000000c2', 'e1150000-0000-4000-8000-0000000000f2', 'e1150000-0000-4000-8000-000000000003', timestamptz '2026-10-31 20:16+08', 1020, 1060, 10.5, 11, 40, 0.5, null),
  ('e1150000-0000-4000-8000-0000000000c3', 'e1150000-0000-4000-8000-0000000000f3', 'e1150000-0000-4000-8000-000000000003', timestamptz '2026-10-31 20:21+08', 1060, 1102, 11, 12, 42, 1, null),
  ('e1150000-0000-4000-8000-0000000000c4', 'e1150000-0000-4000-8000-0000000000f4', 'e1150000-0000-4000-8000-000000000003', timestamptz '2026-11-01 10:00+08', 1102, 1120, 12, 12.5, 18, 0.5, null),
  ('e1150000-0000-4000-8000-0000000000c5', 'e1150000-0000-4000-8000-0000000000f5', 'e1150000-0000-4000-8000-000000000003', timestamptz '2026-11-03 10:00+08', 1102, 1150, 12, 13, 48, 1, null),
  ('e1150000-0000-4000-8000-0000000000c6', 'e1150000-0000-4000-8000-0000000000f6', 'e1150000-0000-4000-8000-000000000003', timestamptz '2026-11-05 10:00+08', 1150, 1170, 13, 13.5, 20, 0.5, null);
select pg_temp.as_user('e1150000-0000-4000-8000-0000000000a4');
insert into _t select 'k10', public.kpi_tab_v1('e1150000-0000-4000-8000-000000000003', date '2026-10-01');
insert into _t select 'k11', public.kpi_tab_v1('e1150000-0000-4000-8000-000000000003', date '2026-11-01');
reset role; select set_config('request.jwt.claims', '{}', true);
select is((select e ->> 'kwh_per_day' from jsonb_array_elements((select v -> 'utility' -> 'per_stay' from _t where k = 'k10')) e where e ->> 'to' = '2026-10-31'), '21.00',
  'late filing: the reading for the 31 Oct checkout is 42 kWh over the 2 days since the 29 Oct checkout = 21/day (not 42)');
select is((select e - 'recorded_at' - 'checkout_date' - 'kwh_per_day' - 'm3_per_day' - 'm3' from jsonb_array_elements((select v -> 'utility' -> 'per_stay' from _t where k = 'k10')) e where e ->> 'to' = '2026-10-31'),
  '{"from": "2026-10-29", "to": "2026-10-31", "days": 2, "kwh": 42.00}'::jsonb, 'the point carries from (previous checkout), to (its checkout) and days');
select ok((select e ?& array['checkout_date', 'recorded_at', 'days', 'kwh', 'kwh_per_day', 'm3', 'm3_per_day', 'from', 'to'] and (select count(*) from jsonb_object_keys(e)) = 9
             from jsonb_array_elements((select v -> 'utility' -> 'per_stay' from _t where k = 'k10')) e where e ->> 'to' = '2026-10-31'), 'the series point keeps its seven keys and adds from and to');
select is((select v -> 'utility' ->> 'kwh_month' from _t where k = 'k10'), '102.00', 'October kWh counts the three readings by checkout month: 20 + 40 + 42');
select is((select v -> 'utility' ->> 'kwh_per_day' from _t where k = 'k10'), '20.50', 'October per day = (40 + 42) / (2 + 2); the first reading has no days');
select is((select v -> 'utility' ->> 'kwh_month' from _t where k = 'k11'), '38.00', 'November leaves the overlapping reading out: 18 + 20 (not + 48)');
select is((select e ->> 'kwh_per_day' from jsonb_array_elements((select v -> 'utility' -> 'per_month' from _t where k = 'k11')) e where e ->> 'month' = '2026-11'), '12.67',
  'per_month kwh_per_day = sum(kWh) / sum(days) = 38 / 3');
select is((select e ->> 'stays' from jsonb_array_elements((select v -> 'utility' -> 'per_month' from _t where k = 'k11')) e where e ->> 'month' = '2026-11'), '2', 'and the overlapping reading is not a stay in the month');
select ok(not exists (select 1 from jsonb_array_elements((select v -> 'utility' -> 'per_stay' from _t where k = 'k11')) e where e ->> 'to' = '2026-11-03'), 'the overlapping reading is not in the series');
select is((select e ->> 'days' from jsonb_array_elements((select v -> 'utility' -> 'per_stay' from _t where k = 'k11')) e where e ->> 'to' = '2026-11-05'), '2', 'the next reading measures from the checkout of the one before it (11-03 to 11-05)');
insert into _t select 'v23a', public.run_system_verifier_v1('e1150000-0000-4000-8000-000000000003', 'hourly', timestamptz '2026-11-10 00:00+08');
select is(pg_temp.f('v23a', 'V23:%') -> 0 -> 'detail', jsonb_build_object('reading', 'e1150000-0000-4000-8000-0000000000c5', 'checkout', '2026-11-03', 'prev', 1102.00, 'expected_prev', 1120.00),
  'V23 fires on the overlapping reading: detail reading, checkout, prev, expected_prev');
select is(jsonb_array_length(pg_temp.f('v23a', 'V23:%')), 1, 'and only on that one');
update public.meter_readings set electric_prev = 1120, electric_delta = 30 where id = 'e1150000-0000-4000-8000-0000000000c5';
insert into _t select 'v23b', public.run_system_verifier_v1('e1150000-0000-4000-8000-000000000003', 'hourly', timestamptz '2026-11-10 00:00+08');
select is(jsonb_array_length(pg_temp.f('v23b', 'V23:%')), 0, 'a continuous chain raises no V23');
insert into public.verifier_findings(key, check_id, severity, title, detail, status, first_seen, last_seen) values ('V23:meter_chain:zz115', 'V23', 'yellow', 'zz V23', '{}', 'open', now() - interval '2 days', now() - interval '1 hour');
select public.apply_verifier_run_v1('hourly', '[]'::jsonb, now());
select is((select status from public.verifier_findings where key = 'V23:meter_chain:zz115'), 'resolved', 'V23 is in the scope arrays: a finding no longer seen resolves');

-- ===== definitions: signature, security, grants, bodies =====
select is((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.get_missed_cleanings(uuid,integer)'::regprocedure), '825eceefccf49f1dcca58fee4eda5664', 'get_missed_cleanings is the s115 body');
select ok((select position('ce.status = ''confirmed''' in prosrc) > 0 and position('ce.status <> ''cancelled''' in prosrc) = 0 and position('stay_same_guest_v1' in prosrc) > 0 from pg_proc where oid = 'public.get_missed_cleanings(uuid,integer)'::regprocedure),
  'it filters on confirmed and keeps the D-290 same-guest clause');
select ok(has_function_privilege('authenticated', 'public.get_missed_cleanings(uuid,integer)', 'execute') and has_function_privilege('service_role', 'public.get_missed_cleanings(uuid,integer)', 'execute')
      and not has_function_privilege('anon', 'public.get_missed_cleanings(uuid,integer)', 'execute')
      and not (select prosecdef from pg_proc where oid = 'public.get_missed_cleanings(uuid,integer)'::regprocedure), 'get_missed_cleanings: authenticated and service_role may execute, anon may not, still SECURITY INVOKER');
select ok(not has_function_privilege('anon', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute') and not has_function_privilege('authenticated', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute')
      and has_function_privilege('service_role', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute'), 'staff_guest_card_v1: service_role only');
select ok(not has_function_privilege('anon', 'public.get_guest_timeline_v1(uuid)', 'execute') and has_function_privilege('authenticated', 'public.get_guest_timeline_v1(uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.get_guest_timeline_v1(uuid)', 'execute'), 'get_guest_timeline_v1: authenticated only');
select ok(not has_function_privilege('anon', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute') and not has_function_privilege('authenticated', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute')
      and has_function_privilege('service_role', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute')
      and not has_function_privilege('anon', 'public.apply_verifier_run_v1(text,jsonb,timestamptz)', 'execute') and not has_function_privilege('authenticated', 'public.apply_verifier_run_v1(text,jsonb,timestamptz)', 'execute')
      and has_function_privilege('service_role', 'public.apply_verifier_run_v1(text,jsonb,timestamptz)', 'execute'), 'the two verifier functions: service_role only');
select ok(not has_function_privilege('anon', 'public.turnover_issue_text_v1(text)', 'execute') and not has_function_privilege('authenticated', 'public.turnover_issue_text_v1(text)', 'execute')
      and not has_function_privilege('service_role', 'public.turnover_issue_text_v1(text)', 'execute'), 'turnover_issue_text_v1 is internal: no client role may execute it');
select ok((select bool_and(proconfig = array['search_path=""']) from pg_proc where oid in ('public.turnover_issue_text_v1(text)'::regprocedure, 'public.get_missed_cleanings(uuid,integer)'::regprocedure,
   'public.staff_guest_card_v1(uuid,uuid,date)'::regprocedure, 'public.get_guest_timeline_v1(uuid)'::regprocedure, 'public.run_system_verifier_v1(uuid,text,timestamptz)'::regprocedure,
   'public.apply_verifier_run_v1(text,jsonb,timestamptz)'::regprocedure)), 'every function keeps search_path pinned to empty');

select * from finish();
rollback;
