-- Session 77 (L8): release verifier_direct_uid_20261008. run_system_verifier_v1 reads both direct uid forms (V2, V3),
-- skips our own Airbnb mirror block of a direct stay (V1, TASKS #24) and raises V1m when that block runs past the stay.
-- Synthetic rows only: uuids e8770000-..., everything rolls back.
begin;
select plan(10);

select ok((select prosecdef and proconfig = array['search_path=""'] from pg_proc where oid = 'public.run_system_verifier_v1(uuid,text,timestamptz)'::regprocedure),
  'the checks stay security definer with an empty search_path');
select ok(has_function_privilege('service_role', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute')
      and not has_function_privilege('authenticated', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute')
      and not has_function_privilege('anon', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute'),
  'service_role only');

insert into public.properties(id, name, is_active) values ('e8770000-0000-4000-8000-0000000000a1', 'Synthetic Verifier Direct Uid', true);
insert into public.guests(id, property_id, name) values ('e8770000-0000-4000-8000-0000000000d1', 'e8770000-0000-4000-8000-0000000000a1', 'Angela V.');

create function pg_temp.keys(p_check text) returns text[] language sql as $$
  select coalesce(array_agg(e->>'key' order by e->>'key'), '{}')
    from jsonb_array_elements(public.run_system_verifier_v1('e8770000-0000-4000-8000-0000000000a1', 'hourly', '2030-01-01 02:00+00')->'found') e
   where e->>'check_id' = p_check
$$;

-- A confirmed direct stay Jan 5-8 whose calendar row carries the confirmed form of the uid.
insert into public.booking_inquiries(id, property_id, guest_id, guest_name, guest_email, checkin_date, checkout_date, status)
values ('ab296460-0000-4000-8000-000000000001', 'e8770000-0000-4000-8000-0000000000a1', 'e8770000-0000-4000-8000-0000000000d1',
        'Angela V.', 'angela@example.com', '2030-01-05', '2030-01-08', 'confirmed');
insert into public.calendar_events(id, property_id, uid, source, status, guest_name, checkin_date, checkout_date)
values ('e8770000-0000-4000-8000-0000000000c1', 'e8770000-0000-4000-8000-0000000000a1', 'cascade-direct-ab296460-0000-4000-8000-000000000001',
        'direct', 'confirmed', 'Angela V.', '2030-01-05', '2030-01-08');

select is(pg_temp.keys('V2'), '{}'::text[], 'V2: a cascade-direct-<id> row is the confirmed booking''s calendar block');
select is(pg_temp.keys('V3'), '{}'::text[], 'V3: a cascade-direct-<id> row has its confirmed booking behind it');

-- Our own Airbnb mirror block, same nights, labelled by calendar-sync.
insert into public.calendar_events(id, property_id, uid, source, status, checkin_date, checkout_date, block_reason, block_reason_source, block_note)
values ('e8770000-0000-4000-8000-0000000000c2', 'e8770000-0000-4000-8000-0000000000a1', 'zz-mirror@airbnb.com',
        'airbnb', 'blocked', '2030-01-05', '2030-01-08', 'direct', 'auto', 'DIR AB296460 confirmed');
select is(pg_temp.keys('V1'), '{}'::text[], 'V1: the mirror block of the same stay is not a second stay, and it ends with the stay');

-- The mirror runs one night past the stay: V1m, yellow, and still no overlap alarm.
update public.calendar_events set checkout_date = '2030-01-09' where id = 'e8770000-0000-4000-8000-0000000000c2';
select is(pg_temp.keys('V1'), array['V1m:e8770000-0000-4000-8000-0000000000c2'], 'V1m: the mirror block runs past the stay');
select is((select e->>'severity' || '|' || (e->'detail'->>'block_to') from jsonb_array_elements(public.run_system_verifier_v1('e8770000-0000-4000-8000-0000000000a1', 'hourly', '2030-01-01 02:00+00')->'found') e where e->>'key' like 'V1m:%'),
  'yellow|2030-01-09', 'V1m is yellow and carries the block dates');

-- A direct-labelled block whose note names ANOTHER booking is not this stay's mirror: the overlap still raises V1.
update public.calendar_events set checkout_date = '2030-01-08', block_note = 'DIR FFFFFFFF confirmed' where id = 'e8770000-0000-4000-8000-0000000000c2';
select is(pg_temp.keys('V1'), array['V1:e8770000-0000-4000-8000-0000000000c1:e8770000-0000-4000-8000-0000000000c2'],
  'V1: a block whose note names a different booking still overlaps');

-- A real second stay still raises V1.
update public.calendar_events set block_note = 'DIR AB296460 confirmed' where id = 'e8770000-0000-4000-8000-0000000000c2';
insert into public.calendar_events(id, property_id, uid, source, status, guest_name, checkin_date, checkout_date)
values ('e8770000-0000-4000-8000-0000000000c3', 'e8770000-0000-4000-8000-0000000000a1', 'zz-stay@airbnb.com', 'airbnb', 'confirmed', 'Ben C.', '2030-01-07', '2030-01-09');
select ok('V1:e8770000-0000-4000-8000-0000000000c1:e8770000-0000-4000-8000-0000000000c3' = any(pg_temp.keys('V1')),
  'V1: an Airbnb stay over the direct stay is still an overlap');

-- A hold with the pre-confirmation form whose inquiry expired is still a V3 (and auto_safe).
insert into public.booking_inquiries(id, property_id, guest_name, guest_email, checkin_date, checkout_date, status)
values ('ab296460-0000-4000-8000-000000000002', 'e8770000-0000-4000-8000-0000000000a1', 'Dead Hold', 'dead@example.com', '2030-02-01', '2030-02-03', 'expired');
insert into public.calendar_events(id, property_id, uid, source, status, guest_name, checkin_date, checkout_date)
values ('e8770000-0000-4000-8000-0000000000c4', 'e8770000-0000-4000-8000-0000000000a1', 'direct:ab296460-0000-4000-8000-000000000002',
        'direct', 'blocked', 'Dead Hold', '2030-02-01', '2030-02-03');
select is((select (e->'detail'->>'inquiry_status') || '|' || (e->'detail'->>'auto_safe') from jsonb_array_elements(public.run_system_verifier_v1('e8770000-0000-4000-8000-0000000000a1', 'hourly', '2030-01-01 02:00+00')->'found') e where e->>'key' = 'V3:e8770000-0000-4000-8000-0000000000c4'),
  'expired|true', 'V3: a direct:<id> hold of an expired inquiry is still found and auto_safe');

select * from finish();
rollback;
