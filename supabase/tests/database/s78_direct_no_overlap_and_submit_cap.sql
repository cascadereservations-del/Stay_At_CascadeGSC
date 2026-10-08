-- Session 78 (lane E): release s78_guards_20261008.
-- TASKS #20b: calendar_events_direct_no_overlap - two live direct rows never cover the same night.
-- TASKS #21: booking_submit_allowed_v1 - the per-caller hourly cap behind submit-booking.
-- Synthetic rows only: properties e8790000-...-a1/a2, everything rolls back.
begin;
select plan(22);

select ok(exists (select 1 from pg_constraint where conname = 'calendar_events_direct_no_overlap'
                    and conrelid = 'public.calendar_events'::regclass and contype = 'x'),
  'the exclusion constraint is on calendar_events');

insert into public.properties(id, name, is_active) values
  ('e8790000-0000-4000-8000-0000000000a1', 'Synthetic Direct Overlap', true),
  ('e8790000-0000-4000-8000-0000000000a2', 'Synthetic Direct Overlap Two', true);

create function pg_temp.cal(p_prop text, p_uid text, p_source text, p_status text, p_from date, p_to date) returns void language sql as $$
  insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date, guest_name)
  values (('e8790000-0000-4000-8000-0000000000' || p_prop)::uuid, p_uid, p_source, p_status, p_from, p_to, 'Synthetic')
$$;

select lives_ok($$ select pg_temp.cal('a1', 'direct:e8790000-0000-4000-8000-000000000001', 'direct', 'blocked', '2030-03-01', '2030-03-04') $$,
  'a direct hold goes in');
select throws_ok($$ select pg_temp.cal('a1', 'direct:e8790000-0000-4000-8000-000000000002', 'direct', 'blocked', '2030-03-03', '2030-03-05') $$,
  '23P01', null, 'a second direct hold over one of its nights is refused (23P01)');
select throws_ok($$ select pg_temp.cal('a1', 'cascade-direct-e8790000-0000-4000-8000-000000000003', 'direct', 'confirmed', '2030-02-27', '2030-03-10') $$,
  '23P01', null, 'a confirmed direct stay that covers the hold is refused');
select lives_ok($$ select pg_temp.cal('a1', 'direct:e8790000-0000-4000-8000-000000000004', 'direct', 'blocked', '2030-03-04', '2030-03-06') $$,
  'back to back (checkout day = next check-in) is allowed');
select lives_ok($$ select pg_temp.cal('a1', 'zz-airbnb-overlap@airbnb.com', 'airbnb', 'confirmed', '2030-03-02', '2030-03-03') $$,
  'an Airbnb row over a direct hold is not constrained (V1 reports it)');
select lives_ok($$ select pg_temp.cal('a1', 'manual-overlap', 'manual', 'blocked', '2030-03-02', '2030-03-03') $$,
  'a manual block over a direct hold is not constrained');
select lives_ok($$ select pg_temp.cal('a1', 'direct:e8790000-0000-4000-8000-000000000005', 'direct', 'cancelled', '2030-03-02', '2030-03-03') $$,
  'a cancelled direct row over a live one is allowed');
select throws_ok($$ update public.calendar_events set status = 'blocked' where uid = 'direct:e8790000-0000-4000-8000-000000000005' $$,
  '23P01', null, 'reviving the cancelled row over the live one is refused');
select lives_ok($$ select pg_temp.cal('a2', 'direct:e8790000-0000-4000-8000-000000000006', 'direct', 'blocked', '2030-03-01', '2030-03-04') $$,
  'the same nights at another property are allowed');
select throws_ok($$ update public.calendar_events set checkout_date = '2030-03-05' where uid = 'direct:e8790000-0000-4000-8000-000000000001' $$,
  '23P01', null, 'moving a hold onto the next hold''s nights is refused');
-- Confirming renames the same row (inquiry_one_tap / apply_direct_booking_transition): never a conflict with itself.
select lives_ok($$ update public.calendar_events set uid = 'cascade-direct-e8790000-0000-4000-8000-000000000001', status = 'confirmed'
                    where uid = 'direct:e8790000-0000-4000-8000-000000000001' $$,
  'confirming a hold in place (uid rename, status confirmed) is allowed');
select lives_ok($$ update public.calendar_events set status = 'cancelled' where uid = 'direct:e8790000-0000-4000-8000-000000000004';
                   select pg_temp.cal('a1', 'direct:e8790000-0000-4000-8000-000000000007', 'direct', 'blocked', '2030-03-04', '2030-03-07') $$,
  'once a hold is cancelled its nights can be held again');

-- TASKS #21: the hourly cap.
select ok((select prosecdef and proconfig = array['search_path=""'] from pg_proc where oid = 'public.booking_submit_allowed_v1(text,integer)'::regprocedure)
      and has_function_privilege('service_role', 'public.booking_submit_allowed_v1(text,integer)', 'execute')
      and not has_function_privilege('authenticated', 'public.booking_submit_allowed_v1(text,integer)', 'execute')
      and not has_function_privilege('anon', 'public.booking_submit_allowed_v1(text,integer)', 'execute'),
  'the cap is security definer, empty search_path, service_role only');
select ok((select relrowsecurity from pg_class where oid = 'public.booking_submit_attempts'::regclass),
  'booking_submit_attempts has row level security on');
select throws_ok($$ select public.booking_submit_allowed_v1('203.0.113.7') $$, '22023', null,
  'a raw address is refused: only a 64-hex hash is accepted');

select is((select count(*)::int from generate_series(1, 10) g where public.booking_submit_allowed_v1(repeat('a', 64))), 10,
  'ten requests in an hour are allowed');
select is(public.booking_submit_allowed_v1(repeat('a', 64)), false, 'the eleventh in the hour is refused');
select is(public.booking_submit_allowed_v1(repeat('b', 64)), true, 'another caller is not affected');

insert into public.booking_submit_attempts(ip_hash, attempted_at)
select repeat('c', 64), now() - interval '2 hours' from generate_series(1, 10);
select is(public.booking_submit_allowed_v1(repeat('c', 64)), true, 'requests older than an hour do not count');

insert into public.booking_submit_attempts(ip_hash, attempted_at) values (repeat('d', 64), now() - interval '2 days');
select public.booking_submit_allowed_v1(repeat('e', 64));
select is((select count(*)::int from public.booking_submit_attempts where ip_hash = repeat('d', 64)), 0,
  'attempts older than a day are deleted');

select is(array[public.booking_submit_allowed_v1(repeat('f', 64), 2), public.booking_submit_allowed_v1(repeat('f', 64), 2),
                public.booking_submit_allowed_v1(repeat('f', 64), 2)], array[true, true, false],
  'p_max sets the cap');

select * from finish();
rollback;
