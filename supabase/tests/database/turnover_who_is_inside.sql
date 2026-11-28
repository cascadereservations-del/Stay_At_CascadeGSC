-- Release turnover_who_is_inside_20261213: who is in the house is decided by the clock (house_times 14:00 in, 12:00 out), not by the
-- date. Synthetic fixtures only, on a property private to this suite, in 2030 so no real stay overlaps; all goes with the rollback.
--   A  2030-01-01 -> 01-03 (departs on the turnover day)     B  2030-01-03 -> 01-04 (arrives on the turnover day)
--   K  2030-01-04 -> 01-06 blocked (never a stay)            C  2030-01-10 -> 01-12 (next after B)
--   L  2030-02-01 -> 02-03 with its own late check-out 15:00
begin;
select plan(26);

-- shape and access
select ok(not has_function_privilege('anon', 'public.stay_phase_v1(date, date, time, time, timestamp)', 'execute')
      and not has_function_privilege('authenticated', 'public.stay_phase_v1(date, date, time, time, timestamp)', 'execute')
      and not has_function_privilege('service_role', 'public.stay_phase_v1(date, date, time, time, timestamp)', 'execute'),
  'stay_phase_v1: no client role may execute');
select ok(not has_function_privilege('anon', 'public.staff_current_next_stays_at_v1(uuid, timestamp)', 'execute')
      and not has_function_privilege('authenticated', 'public.staff_current_next_stays_at_v1(uuid, timestamp)', 'execute')
      and not has_function_privilege('service_role', 'public.staff_current_next_stays_at_v1(uuid, timestamp)', 'execute'),
  'staff_current_next_stays_at_v1: no client role may execute');
select ok(has_function_privilege('service_role', 'public.staff_current_next_stays_v1(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.staff_current_next_stays_v1(uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.staff_current_next_stays_v1(uuid)', 'execute'),
  'staff_current_next_stays_v1: grants unchanged (service_role only)');
select ok(has_function_privilege('authenticated', 'public.get_admin_overview_v1(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.get_admin_overview_v1(uuid)', 'execute'),
  'get_admin_overview_v1: grants unchanged (authenticated, not anon)');
select ok((select bool_and(p.prosecdef and p.proconfig = array['search_path=""']) from pg_proc p
            where p.oid in ('public.staff_current_next_stays_v1(uuid)'::regprocedure, 'public.staff_current_next_stays_at_v1(uuid, timestamp)'::regprocedure,
                            'public.get_admin_overview_v1(uuid)'::regprocedure)),
  'read models: security definer with an empty search_path');
select is((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.get_admin_overview_v1(uuid)'::regprocedure),
  '382132f2b8fc01ac4a3dbf3f79b11ae4', 'get_admin_overview_v1: the one-clause body is live');

-- the rule itself (house_times 14:00 / 12:00)
select is(public.stay_phase_v1('2030-01-03', '2030-01-04', null, null, '2030-01-03 13:59'), 'upcoming', 'phase: 13:59 on arrival day = upcoming');
select is(public.stay_phase_v1('2030-01-03', '2030-01-04', null, null, '2030-01-03 14:00'), 'inside', 'phase: 14:00 on arrival day = inside');
select is(public.stay_phase_v1('2030-01-01', '2030-01-03', null, null, '2030-01-03 11:59'), 'inside', 'phase: 11:59 on check-out day = inside');
select is(public.stay_phase_v1('2030-01-01', '2030-01-03', null, null, '2030-01-03 12:00'), 'departed', 'phase: 12:00 on check-out day = departed');
select is(public.stay_phase_v1('2030-02-01', '2030-02-03', null, '15:00', '2030-02-03 14:30'), 'inside', 'phase: the stay''s own late check-out wins');
select is(public.stay_phase_v1(null, '2030-02-03', null, null, '2030-02-03 10:00'), null, 'phase: missing dates give null');

-- a bad house_times value falls back to 14:00 / 12:00 instead of breaking the Today card
update public.app_settings set value = '{"check_in":"2pm","check_out":"noon"}'::jsonb where key = 'house_times';
select is((select value->>'check_out' from public.app_settings where key = 'house_times'), 'noon', 'fallback fixture: house_times row exists and holds the unreadable value');
select is(public.stay_phase_v1('2030-01-01', '2030-01-03', null, null, '2030-01-03 11:59'), 'inside', 'phase: unreadable house_times falls back to 12:00 out');
update public.app_settings set value = '{"check_in":"14:00","check_out":"12:00"}'::jsonb where key = 'house_times';

-- fixtures
insert into public.properties(id, name, is_active) values ('e2121300-0000-4000-8000-000000000013', 'Synthetic Turnover', true);
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date, guest_name, checkout_time)
values ('e2121300-0000-4000-8000-000000000013', 'synthetic-turnover-A', 'airbnb', 'confirmed', '2030-01-01', '2030-01-03', 'Synthetic Departing', null),
       ('e2121300-0000-4000-8000-000000000013', 'synthetic-turnover-B', 'airbnb', 'confirmed', '2030-01-03', '2030-01-04', 'Synthetic Arriving', null),
       ('e2121300-0000-4000-8000-000000000013', 'synthetic-turnover-K', 'airbnb', 'blocked',   '2030-01-04', '2030-01-06', null, null),
       ('e2121300-0000-4000-8000-000000000013', 'synthetic-turnover-C', 'direct', 'confirmed', '2030-01-10', '2030-01-12', 'Synthetic Later', null),
       ('e2121300-0000-4000-8000-000000000013', 'synthetic-turnover-L', 'direct', 'confirmed', '2030-02-01', '2030-02-03', 'Synthetic Late Out', '15:00');

create temp table tw(at timestamp, cur text, nxt text) on commit drop;
insert into tw
select a.at,
       (select s.uid from public.staff_current_next_stays_at_v1('e2121300-0000-4000-8000-000000000013', a.at) s where s.slot = 'current'),
       (select s.uid from public.staff_current_next_stays_at_v1('e2121300-0000-4000-8000-000000000013', a.at) s where s.slot = 'next')
  from unnest(array['2030-01-02 10:00', '2030-01-03 00:41', '2030-01-03 11:59', '2030-01-03 12:30', '2030-01-03 13:59', '2030-01-03 14:01',
                    '2030-01-04 12:00', '2030-02-03 14:30', '2030-02-03 15:00']::timestamp[]) a(at);

select is((select cur from tw where at = '2030-01-02 10:00'), 'synthetic-turnover-A', 'mid-stay: current = the guest staying');
select is((select cur from tw where at = '2030-01-03 00:41'), 'synthetic-turnover-A', 'turnover 00:41: the departing guest is still inside (the reported bug)');
select is((select nxt from tw where at = '2030-01-03 00:41'), 'synthetic-turnover-B', 'turnover 00:41: next = the arriving guest');
select is((select cur from tw where at = '2030-01-03 11:59'), 'synthetic-turnover-A', 'turnover 11:59: the departing guest is still inside');
select is((select cur from tw where at = '2030-01-03 12:30'), null, 'turnover 12:30: nobody inside (cleaning window)');
select is((select nxt from tw where at = '2030-01-03 12:30'), 'synthetic-turnover-B', 'turnover 12:30: next = the arriving guest, so the card says arriving');
select is((select cur from tw where at = '2030-01-03 14:01'), 'synthetic-turnover-B', 'turnover 14:01: the arriving guest is inside');
select is((select nxt from tw where at = '2030-01-03 14:01'), 'synthetic-turnover-C', 'turnover 14:01: next skips the blocked row');
select ok((select cur is null and nxt = 'synthetic-turnover-B' from tw where at = '2030-01-03 13:59'), 'turnover 13:59: still nobody inside, next = the arriving guest');
select ok((select cur is null and nxt = 'synthetic-turnover-C' from tw where at = '2030-01-04 12:00'), 'B checked out at 12:00: empty, next = C');
select ok((select (select cur from tw where at = '2030-02-03 14:30') = 'synthetic-turnover-L' and (select cur from tw where at = '2030-02-03 15:00') is null),
  'a late check-out keeps the guest inside until their own time');

-- through the definer chain, as the app's caller: the definer must be able to run the revoked helper
set local role service_role;
select is((select string_agg(slot || ':' || uid, ',') from public.staff_current_next_stays_v1('e2121300-0000-4000-8000-000000000013')),
  'next:synthetic-turnover-A', 'service_role: staff_current_next_stays_v1 runs through the definer chain (today: nobody in, next = A in 2030)');
reset role;

select * from finish();
rollback;
