-- Session 84, lane C: release s84_calendar_20261017. (1) admin_stays_v1 refuses a session that is not owner/admin or finance and keeps working for
-- owner/admin/finance and for a caller with no JWT; (2) staff_calendar_history_v1 is owner/admin only and returns no money and no contact.
-- Synthetic fixtures only (uuids e8400000-...) on their own property and users. Fixed past dates, so the clock does not matter. Everything rolls back.
begin;
select plan(30);

-- the baseline grants a --no-acl restore lacks (production has them; rolled back with the suite)
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
grant execute on function public.admin_stays_v1(uuid) to authenticated;
grant execute on function public.get_hospitality_metrics_v1(uuid, date, date) to authenticated;
grant execute on function public.staff_calendar_history_v1(date, date, uuid) to authenticated;

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal2', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into public.properties(id, name, is_active) values ('e8400000-0000-4000-8000-0000000000a1', 'Synthetic S84 C', true);
insert into auth.users(id, email) values
  ('e8400000-0000-4000-8000-0000000000b1', 'zz-s84-cleaner@example.com'), ('e8400000-0000-4000-8000-0000000000b2', 'zz-s84-owner@example.com'),
  ('e8400000-0000-4000-8000-0000000000b3', 'zz-s84-admin@example.com'), ('e8400000-0000-4000-8000-0000000000b4', 'zz-s84-finance@example.com'),
  ('e8400000-0000-4000-8000-0000000000b5', 'zz-s84-inspector@example.com');
insert into public.staff_access_profiles(user_id, role) values
  ('e8400000-0000-4000-8000-0000000000b1', 'cleaner'), ('e8400000-0000-4000-8000-0000000000b2', 'owner'),
  ('e8400000-0000-4000-8000-0000000000b3', 'admin'), ('e8400000-0000-4000-8000-0000000000b4', 'finance'),
  ('e8400000-0000-4000-8000-0000000000b5', 'inspector');
insert into public.staff_property_access(user_id, property_id) select u, 'e8400000-0000-4000-8000-0000000000a1'
  from unnest(array['e8400000-0000-4000-8000-0000000000b1', 'e8400000-0000-4000-8000-0000000000b3', 'e8400000-0000-4000-8000-0000000000b4', 'e8400000-0000-4000-8000-0000000000b5']::uuid[]) u;

-- Airbnb: A1 crosses the new year (completed, "Ana Maria"), A2 cancelled, A3 completed. Direct: D1 confirmed, D2 still an inquiry.
insert into public.airbnb_reservations(id, property_id, confirmation_code, status, guest_name, checkin_date, checkout_date, guest_paid, host_service_fee, host_payout) values
  ('e8400000-0000-4000-8000-0000000000c1', 'e8400000-0000-4000-8000-0000000000a1', 'ZZS84A1', 'completed', 'Ana Maria Santos', '2025-12-28', '2026-01-02', 9000, 270, 8730),
  ('e8400000-0000-4000-8000-0000000000c2', 'e8400000-0000-4000-8000-0000000000a1', 'ZZS84A2', 'cancelled', 'Ben Cancelled', '2026-01-05', '2026-01-07', 4000, 120, 3880),
  ('e8400000-0000-4000-8000-0000000000c3', 'e8400000-0000-4000-8000-0000000000a1', 'ZZS84A3', 'completed', 'Cy', '2026-01-10', '2026-01-12', 4000, 120, 3880);
insert into public.booking_inquiries(id, property_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, pax, total_amount, deposit_amount, source, status) values
  ('e8400001-0000-4000-8000-0000000000d1', 'e8400000-0000-4000-8000-0000000000a1', 'Dee Cruz', 'zz-dee@example.invalid', '0000000011', '2026-01-20', '2026-01-22', 2, 4000, 2000, 'direct', 'confirmed'),
  ('e8400002-0000-4000-8000-0000000000d2', 'e8400000-0000-4000-8000-0000000000a1', 'Eve Pending', 'zz-eve@example.invalid', '0000000012', '2026-01-25', '2026-01-26', 1, 2000, 1000, 'direct', 'pending');

-- =============================================================== objects and grants
select has_function('public', 'staff_calendar_history_v1', array['date', 'date', 'uuid'], 'the history RPC exists');
select ok(has_function_privilege('authenticated', 'public.staff_calendar_history_v1(date, date, uuid)', 'execute')
      and not has_function_privilege('anon', 'public.staff_calendar_history_v1(date, date, uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.staff_calendar_history_v1(date, date, uuid)', 'execute'), 'history: authenticated only');
select ok(has_function_privilege('authenticated', 'public.admin_stays_v1(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.admin_stays_v1(uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.admin_stays_v1(uuid)', 'execute'), 'admin_stays_v1 grants unchanged: authenticated only');
select ok(not has_function_privilege('authenticated', 'public.admin_stays_gate_v1(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.admin_stays_gate_v1(uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.admin_stays_gate_v1(uuid)', 'execute'), 'the gate is not callable by any API role');
select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'public.admin_stays_v1(uuid)'::regprocedure), 'admin_stays_v1 is still SECURITY DEFINER with an empty search_path');

-- =============================================================== cleaner and inspector: refused by both
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000b1');
select throws_ok($$select * from public.admin_stays_v1('e8400000-0000-4000-8000-0000000000a1')$$, '42501', 'not_authorized', 'a cleaner cannot read admin_stays_v1 (names and payouts)');
select throws_ok($$select public.staff_calendar_history_v1('2025-12-01', '2026-01-31', 'e8400000-0000-4000-8000-0000000000a1')$$, '42501', 'not_authorized', 'a cleaner cannot read the calendar history');
select throws_ok($$select public.get_hospitality_metrics_v1('e8400000-0000-4000-8000-0000000000a1', '2026-01-01', '2026-02-01')$$, '42501', null, 'nor the metrics that read the same stays (the stay set is no longer reachable by her)');
reset role;
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000b5');
select throws_ok($$select * from public.admin_stays_v1('e8400000-0000-4000-8000-0000000000a1')$$, '42501', 'not_authorized', 'an inspector cannot read admin_stays_v1');
select throws_ok($$select public.staff_calendar_history_v1('2025-12-01', '2026-01-31', 'e8400000-0000-4000-8000-0000000000a1')$$, '42501', 'not_authorized', 'nor the history');
reset role;

-- =============================================================== owner: rows, and the old readers still work
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000b2');
insert into _t select 'hist', public.staff_calendar_history_v1('2025-12-01', '2026-01-31', 'e8400000-0000-4000-8000-0000000000a1');
insert into _t select 'edge_out', public.staff_calendar_history_v1('2026-01-02', '2026-01-02', 'e8400000-0000-4000-8000-0000000000a1');
insert into _t select 'edge_in', public.staff_calendar_history_v1('2026-01-01', '2026-01-01', 'e8400000-0000-4000-8000-0000000000a1');
select is((select count(*)::int from public.admin_stays_v1('e8400000-0000-4000-8000-0000000000a1')), 5, 'the owner still reads all five stays from admin_stays_v1');
select ok((select bool_or(guest_name = 'Ana Maria Santos' and host_payout = 8730) from public.admin_stays_v1('e8400000-0000-4000-8000-0000000000a1')), 'admin_stays_v1 still returns the full row (name and payout) to the owner');
select lives_ok($$select public.get_hospitality_metrics_v1('e8400000-0000-4000-8000-0000000000a1', '2026-01-01', '2026-02-01')$$, 'the metrics RPC still works for the owner');
reset role;
select is((select jsonb_array_length(v->'stays') from _t where k = 'hist'), 3, 'history returns the three confirmed or completed stays (cancelled and inquiry left out)');
select is((select jsonb_agg(e->>'source' order by e->>'checkin') from _t, jsonb_array_elements(v->'stays') e where k = 'hist'), '["airbnb", "airbnb", "direct"]'::jsonb, 'with their sources');
select is((select e->>'first_name' from _t, jsonb_array_elements(v->'stays') e where k = 'hist' and e->>'checkin' = '2025-12-28'), 'Ana', 'the guest first name only');
select is((select (e->>'nights')::int from _t, jsonb_array_elements(v->'stays') e where k = 'hist' and e->>'checkin' = '2025-12-28'), 5, 'nights are computed');
select is((select e->>'status' from _t, jsonb_array_elements(v->'stays') e where k = 'hist' and e->>'checkin' = '2026-01-20'), 'confirmed', 'the status is returned');
select ok((select bool_and((select array_agg(k order by k) from jsonb_object_keys(e) k) = array['checkin', 'checkout', 'first_name', 'id', 'nights', 'source', 'status']) from _t, jsonb_array_elements(v->'stays') e where k = 'hist'),
  'each stay carries exactly source, id, checkin, checkout, nights, status and first_name');
select ok((select not (v::text ~* '(payout|total|amount|gross|price|phone|email|santos|cruz|deposit)') from _t where k = 'hist'), 'no money key, no contact, no surname anywhere in the payload');
select is((select jsonb_array_length(v->'stays') from _t where k = 'edge_out'), 0, 'a stay checking out on the first day of the range is not in it (check-out day is free)');
select is((select jsonb_array_length(v->'stays') from _t where k = 'edge_in'), 1, 'the day before check-out still overlaps');

-- =============================================================== admin, finance, range cap
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000b3');
select is((select jsonb_array_length(public.staff_calendar_history_v1('2025-12-01', '2026-01-31', 'e8400000-0000-4000-8000-0000000000a1')->'stays')), 3, 'an admin reads the history');
select throws_ok($$select public.staff_calendar_history_v1('2025-01-01', '2026-02-06', 'e8400000-0000-4000-8000-0000000000a1')$$, '22023', 'range_too_large', 'a range over 400 days is refused');
select throws_ok($$select public.staff_calendar_history_v1('2026-01-31', '2026-01-01', 'e8400000-0000-4000-8000-0000000000a1')$$, '22023', 'bad_range', 'a reversed range is refused');
reset role;
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000b4');
select is((select count(*)::int from public.admin_stays_v1('e8400000-0000-4000-8000-0000000000a1')), 5, 'a finance session (aal2) still reads admin_stays_v1');
select throws_ok($$select public.staff_calendar_history_v1('2025-12-01', '2026-01-31', 'e8400000-0000-4000-8000-0000000000a1')$$, '42501', 'not_authorized', 'but the staff-app history is owner/admin only');
reset role;

-- =============================================================== no-JWT path (the owner role, a cron job, a definer function run by it)
select set_config('request.jwt.claims', '', true);
select is((select count(*)::int from public.admin_stays_v1('e8400000-0000-4000-8000-0000000000a1')), 5, 'a caller with no JWT still reads admin_stays_v1');
select throws_ok($$select public.staff_calendar_history_v1('2025-12-01', '2026-01-31', 'e8400000-0000-4000-8000-0000000000a1')$$, '42501', 'not_authorized', 'but the new history RPC has no no-JWT path');
select is((select count(*)::int from public.admin_stays_v1('e8400000-0000-4000-8000-0000000000a2')), 0, 'and a property with no stays gives no rows, no error');

select * from finish();
rollback;
