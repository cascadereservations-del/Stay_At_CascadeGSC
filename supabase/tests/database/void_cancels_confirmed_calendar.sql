-- Release void_cancels_confirmed_calendar_20261212: voiding a direct-booking income row cancels both calendar uid forms,
-- 'direct:<id>' (pending) and 'cascade-direct-<id>' (confirmed, renamed by the one-tap confirm). Synthetic fixtures only on a
-- property private to this suite, written as the owner; everything goes with the closing rollback.
--   staff a1 finance, a2 cleaner, a3 admin (D-440: only owner/admin may void a confirmed booking payment)
--   b01 confirmed, cascade-direct row   b02 pending, direct row   b03 confirmed, both forms   b04 confirmed, never voided
begin;
select plan(18);

select ok((select p.prosecdef and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = 'public.fn_direct_booking_cascade()'::regprocedure),
  'cascade: security definer with an empty search_path');
select ok(not has_function_privilege('anon', 'public.fn_direct_booking_cascade()', 'execute')
      and not has_function_privilege('authenticated', 'public.fn_direct_booking_cascade()', 'execute')
      and not has_function_privilege('service_role', 'public.fn_direct_booking_cascade()', 'execute'), 'cascade: no client role may execute');

insert into public.properties(id, name, is_active) values ('e2121200-0000-4000-8000-000000000012', 'Synthetic Void Cascade', true);
insert into auth.users(id) values ('e2121200-0000-4000-8000-0000000000a1'), ('e2121200-0000-4000-8000-0000000000a2'), ('e2121200-0000-4000-8000-0000000000a3');
insert into public.staff_access_profiles(user_id, role, note) values
  ('e2121200-0000-4000-8000-0000000000a1', 'finance', 'Void finance'), ('e2121200-0000-4000-8000-0000000000a2', 'cleaner', 'Void cleaner'), ('e2121200-0000-4000-8000-0000000000a3', 'admin', 'Void admin');
insert into public.staff_property_access(user_id, property_id)
select u, 'e2121200-0000-4000-8000-000000000012'::uuid from unnest(array['e2121200-0000-4000-8000-0000000000a1', 'e2121200-0000-4000-8000-0000000000a2', 'e2121200-0000-4000-8000-0000000000a3']::uuid[]) u;
insert into public.booking_inquiries(id, property_id, guest_name, guest_phone, checkin_date, checkout_date, pax, status, source, total_amount, deposit_amount)
select ('c0de2121-0000-4000-8000-00000000000' || n)::uuid, 'e2121200-0000-4000-8000-000000000012', 'Synthetic V' || n, '0917212000' || n,
       current_date + 700 + n * 5, current_date + 702 + n * 5, 2, st, 'direct', 2000, 1000
  from (values (1, 'confirmed'), (2, 'pending'), (3, 'confirmed'), (4, 'confirmed')) v(n, st);
-- b03's two rows cover different dates so the no-overlap rule cannot refuse the fixture
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date, guest_name)
select 'e2121200-0000-4000-8000-000000000012', pre || 'c0de2121-0000-4000-8000-00000000000' || n, 'direct', st,
       current_date + d, current_date + d + 2, 'Synthetic V' || n
  from (values (1, 'cascade-direct-', 'confirmed', 705), (2, 'direct:', 'blocked', 710), (3, 'cascade-direct-', 'confirmed', 715),
               (3, 'direct:', 'blocked', 740), (4, 'cascade-direct-', 'confirmed', 720)) v(n, pre, st, d);
insert into public.transactions(id, property_id, txn_type, category, source, status, transaction_date, gross_amount, currency, booking_id, external_ref)
select ('e2121200-0000-4000-8000-00000000070' || n)::uuid, 'e2121200-0000-4000-8000-000000000012', 'income', 'direct_booking', 'direct_booking', st,
       current_date + 700, 1000, 'PHP', ('c0de2121-0000-4000-8000-00000000000' || n)::uuid, 'c0de2121-0000-4000-8000-00000000000' || n
  from (values (1, 'confirmed'), (2, 'pending_review'), (3, 'confirmed'), (4, 'confirmed')) v(n, st);

-- a change that is not a void leaves everything alone
update public.transactions set status = 'pending_review' where id = 'e2121200-0000-4000-8000-000000000701';
select is((select status from public.calendar_events where uid = 'cascade-direct-c0de2121-0000-4000-8000-000000000001'), 'confirmed',
  'not a void: the calendar row stays confirmed');
select is((select status from public.booking_inquiries where id = 'c0de2121-0000-4000-8000-000000000001'), 'confirmed',
  'not a void: the booking stays confirmed');

-- the guard: no signed-in user (the bot's service role), finance and a cleaner are all refused on a confirmed booking
select throws_ok($$update public.transactions set status = 'void' where id = 'e2121200-0000-4000-8000-000000000701'$$, '42501', null, 'guard: no signed-in user cannot void a confirmed booking payment');
select set_config('request.jwt.claims', json_build_object('sub', 'e2121200-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
select throws_ok($$update public.transactions set status = 'void' where id = 'e2121200-0000-4000-8000-000000000701'$$, '42501', null, 'guard: finance cannot void a confirmed booking payment');
select set_config('request.jwt.claims', json_build_object('sub', 'e2121200-0000-4000-8000-0000000000a2', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
select throws_ok($$update public.transactions set status = 'void' where id = 'e2121200-0000-4000-8000-000000000701'$$, '42501', null, 'guard: a cleaner cannot void a confirmed booking payment');
select is((select b.status || '/' || c.status from public.booking_inquiries b join public.calendar_events c on c.uid = 'cascade-direct-' || b.id::text
            where b.id = 'c0de2121-0000-4000-8000-000000000001'), 'confirmed/confirmed', 'guard: a refused void changes nothing');
-- a pending booking payment is not guarded
select set_config('request.jwt.claims', json_build_object('sub', 'e2121200-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
select lives_ok($$update public.transactions set status = 'void' where id = 'e2121200-0000-4000-8000-000000000702'$$, 'guard: finance may void a pending booking payment');
select is((select status from public.booking_inquiries where id = 'c0de2121-0000-4000-8000-000000000002'), 'cancelled', 'guard: that pending booking is cancelled as before');
select set_config('request.jwt.claims', json_build_object('sub', 'e2121200-0000-4000-8000-0000000000a3', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
select lives_ok($$update public.transactions set status = 'void' where id = 'e2121200-0000-4000-8000-000000000701'$$, 'guard: an admin may void a confirmed booking payment');

update public.transactions set status = 'void' where id in
  ('e2121200-0000-4000-8000-000000000701', 'e2121200-0000-4000-8000-000000000702', 'e2121200-0000-4000-8000-000000000703');

select is((select status from public.calendar_events where uid = 'cascade-direct-c0de2121-0000-4000-8000-000000000001'), 'cancelled',
  'void, confirmed booking: the cascade-direct row is cancelled');
select is((select status from public.calendar_events where uid = 'direct:c0de2121-0000-4000-8000-000000000002'), 'cancelled',
  'void, pending booking: the direct: row is cancelled');
select is((select status from public.calendar_events where uid = 'cascade-direct-c0de2121-0000-4000-8000-000000000003'), 'cancelled',
  'void, both forms: the cascade-direct row is cancelled');
select is((select status from public.calendar_events where uid = 'direct:c0de2121-0000-4000-8000-000000000003'), 'cancelled',
  'void, both forms: the direct: row is cancelled');
select is((select count(*)::int from public.booking_inquiries where status = 'cancelled' and id in
  ('c0de2121-0000-4000-8000-000000000001', 'c0de2121-0000-4000-8000-000000000002', 'c0de2121-0000-4000-8000-000000000003')), 3,
  'void: the three bookings are cancelled');
select is((select status from public.calendar_events where uid = 'cascade-direct-c0de2121-0000-4000-8000-000000000004'), 'confirmed',
  'another booking keeps its calendar row');
select is((select status from public.booking_inquiries where id = 'c0de2121-0000-4000-8000-000000000004'), 'confirmed',
  'another booking stays confirmed');

select * from finish();
rollback;
