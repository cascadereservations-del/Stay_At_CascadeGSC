-- Session 79 (lane B), TASKS #43: V1m ignores Airbnb's preparation window around a direct stay (app_settings airbnb_prep_nights, default 1).
-- Synthetic property e7b00000-...-a1 and one direct stay Jan 8-11 2030; the verifier runs with p_now 2030-01-01, so nothing else on the
-- real property is read. Everything rolls back.
begin;
select plan(17);

select ok((select prosecdef and proconfig = array['search_path=""'] from pg_proc where oid = 'public.run_system_verifier_v1(uuid,text,timestamptz)'::regprocedure),
  'the checks stay security definer with an empty search_path');
select ok(has_function_privilege('service_role', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute')
      and not has_function_privilege('authenticated', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute')
      and not has_function_privilege('anon', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute'),
  'service_role only');
select is((select value from public.app_settings where key = 'airbnb_prep_nights'), '1'::jsonb, 'airbnb_prep_nights is 1');
select ok(pg_get_functiondef('public.run_system_verifier_v1(uuid,text,timestamptz)'::regprocedure) like '%V8%'
      and pg_get_functiondef('public.run_system_verifier_v1(uuid,text,timestamptz)'::regprocedure) like '%airbnb_prep_nights%',
  'the s78 V8 check is still in the body, with the prep setting read');

insert into public.properties(id, name, is_active) values ('e7b00000-0000-4000-8000-0000000000a1', 'Synthetic S79 Prep Nights', true);
insert into public.guests(id, property_id, name) values ('e7b00000-0000-4000-8000-0000000000d1', 'e7b00000-0000-4000-8000-0000000000a1', 'Angela P.');
insert into public.booking_inquiries(id, property_id, guest_id, guest_name, guest_email, checkin_date, checkout_date, status)
values ('ab296461-0000-4000-8000-000000000001', 'e7b00000-0000-4000-8000-0000000000a1', 'e7b00000-0000-4000-8000-0000000000d1',
        'Angela P.', 'angela.p@example.com', '2030-01-08', '2030-01-11', 'confirmed');
insert into public.calendar_events(id, property_id, uid, source, status, guest_name, checkin_date, checkout_date)
values ('e7b00000-0000-4000-8000-0000000000c1', 'e7b00000-0000-4000-8000-0000000000a1', 'cascade-direct-ab296461-0000-4000-8000-000000000001',
        'direct', 'confirmed', 'Angela P.', '2030-01-08', '2030-01-11');
-- Airbnb's mirror block of that stay, labelled by calendar-sync. Dates are moved per case.
insert into public.calendar_events(id, property_id, uid, source, status, checkin_date, checkout_date, block_reason, block_reason_source, block_note)
values ('e7b00000-0000-4000-8000-0000000000c2', 'e7b00000-0000-4000-8000-0000000000a1', 'zz-s79-mirror@airbnb.com',
        'airbnb', 'blocked', '2030-01-08', '2030-01-11', 'direct', 'auto', 'DIR AB296461 confirmed');

create function pg_temp.v1m() returns text[] language sql as $$
  select coalesce(array_agg(e->>'key' order by e->>'key'), '{}')
    from jsonb_array_elements(public.run_system_verifier_v1('e7b00000-0000-4000-8000-0000000000a1', 'hourly', '2030-01-01 02:00+00')->'found') e
   where e->>'key' like 'V1m:%'
$$;
create function pg_temp.mv(p_in date, p_out date) returns void language sql as $$
  update public.calendar_events set checkin_date = p_in, checkout_date = p_out where id = 'e7b00000-0000-4000-8000-0000000000c2'
$$;

-- prep 1 (the default)
select pg_temp.mv('2030-01-08', '2030-01-11');
select is(pg_temp.v1m(), '{}'::text[], 'block equals the stay: no V1m');
select pg_temp.mv('2030-01-08', '2030-01-12');
select is(pg_temp.v1m(), '{}'::text[], 'stay Jan 8-11, block Jan 8-12, prep 1: the night of Jan 11 is the prep night, no V1m');
select pg_temp.mv('2030-01-08', '2030-01-13');
select is(pg_temp.v1m(), array['V1m:e7b00000-0000-4000-8000-0000000000c2'], 'block Jan 8-13, prep 1: V1m');
select pg_temp.mv('2030-01-07', '2030-01-11');
select is(pg_temp.v1m(), '{}'::text[], 'block starts one night before the stay (Jan 7-11), prep 1: no V1m');
select pg_temp.mv('2030-01-06', '2030-01-11');
select is(pg_temp.v1m(), array['V1m:e7b00000-0000-4000-8000-0000000000c2'], 'block starts two nights before the stay: V1m');
select pg_temp.mv('2030-01-07', '2030-01-12');
select is(pg_temp.v1m(), '{}'::text[], 'one prep night on each side (Jan 7-12): no V1m');

-- prep 0: any extra night is flagged, as before this release
update public.app_settings set value = '0'::jsonb where key = 'airbnb_prep_nights';
select pg_temp.mv('2030-01-08', '2030-01-12');
select is(pg_temp.v1m(), array['V1m:e7b00000-0000-4000-8000-0000000000c2'], 'prep 0, block Jan 8-12: V1m');
select pg_temp.mv('2030-01-08', '2030-01-11');
select is(pg_temp.v1m(), '{}'::text[], 'prep 0, block equals the stay: no V1m');

-- prep 2
update public.app_settings set value = '2'::jsonb where key = 'airbnb_prep_nights';
select pg_temp.mv('2030-01-08', '2030-01-13');
select is(pg_temp.v1m(), '{}'::text[], 'prep 2, block Jan 8-13: no V1m');
select pg_temp.mv('2030-01-08', '2030-01-14');
select is(pg_temp.v1m(), array['V1m:e7b00000-0000-4000-8000-0000000000c2'], 'prep 2, block Jan 8-14: V1m');

-- a setting that is not a number reads as 1; a missing row reads as 1
update public.app_settings set value = '"many"'::jsonb where key = 'airbnb_prep_nights';
select pg_temp.mv('2030-01-08', '2030-01-12');
select is(pg_temp.v1m(), '{}'::text[], 'a non-numeric setting reads as 1: Jan 8-12 passes');
delete from public.app_settings where key = 'airbnb_prep_nights';
select pg_temp.mv('2030-01-08', '2030-01-13');
select is(pg_temp.v1m(), array['V1m:e7b00000-0000-4000-8000-0000000000c2'], 'a missing setting reads as 1: Jan 8-13 is flagged');

-- the prep window never hides a real second stay: V1 still reports an Airbnb guest over the direct stay
insert into public.calendar_events(id, property_id, uid, source, status, guest_name, checkin_date, checkout_date)
values ('e7b00000-0000-4000-8000-0000000000c3', 'e7b00000-0000-4000-8000-0000000000a1', 'zz-s79-stay@airbnb.com', 'airbnb', 'confirmed', 'Ben C.', '2030-01-10', '2030-01-12');
select ok(exists (select 1 from jsonb_array_elements(public.run_system_verifier_v1('e7b00000-0000-4000-8000-0000000000a1', 'hourly', '2030-01-01 02:00+00')->'found') e
                   where e->>'key' = 'V1:e7b00000-0000-4000-8000-0000000000c1:e7b00000-0000-4000-8000-0000000000c3'),
  'an Airbnb stay over the direct stay is still a V1 overlap');

select * from finish();
rollback;
