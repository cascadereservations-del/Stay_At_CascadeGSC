-- Session 84, lane C: release s84_calendar_20261017, part 4. calendar_events: `authenticated` can no longer read guest_phone, raw_summary or
-- raw_description; the columns the cleaning checklist selects stay readable; owner/admin read the full row and the dashboard list through
-- admin_calendar_event_v1 and admin_calendar_events_v1. Synthetic fixtures only (uuids e8500000-...). Everything rolls back.
begin;
select plan(21);

-- baseline for a --no-acl restore. NO table grant on calendar_events here: the migration's column grants are what is under test.
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
grant execute on function public.admin_calendar_event_v1(uuid), public.admin_calendar_events_v1(uuid) to authenticated;

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal2', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into public.properties(id, name, is_active) values ('e8500000-0000-4000-8000-0000000000a1', 'Synthetic S84 columns', true);
insert into auth.users(id, email) values
  ('e8500000-0000-4000-8000-0000000000b1', 'zz-s84c-cleaner@example.com'), ('e8500000-0000-4000-8000-0000000000b2', 'zz-s84c-owner@example.com'),
  ('e8500000-0000-4000-8000-0000000000b3', 'zz-s84c-admin@example.com');
insert into public.staff_access_profiles(user_id, role) values
  ('e8500000-0000-4000-8000-0000000000b1', 'cleaner'), ('e8500000-0000-4000-8000-0000000000b2', 'owner'), ('e8500000-0000-4000-8000-0000000000b3', 'admin');
insert into public.staff_property_access(user_id, property_id) values
  ('e8500000-0000-4000-8000-0000000000b1', 'e8500000-0000-4000-8000-0000000000a1'), ('e8500000-0000-4000-8000-0000000000b3', 'e8500000-0000-4000-8000-0000000000a1');
insert into public.calendar_events(id, property_id, uid, source, checkin_date, checkout_date, guest_name, guest_phone, status, raw_summary, raw_description) values
  ('e8500000-0000-4000-8000-0000000000c1', 'e8500000-0000-4000-8000-0000000000a1', 'zz-s84c-1', 'airbnb', '2026-01-10', '2026-01-12', 'Zz Guest One', '+639170000001', 'confirmed', 'Reserved ZZSUMMARY', 'Phone Number (Last 4 Digits): 0001'),
  ('e8500000-0000-4000-8000-0000000000c2', 'e8500000-0000-4000-8000-0000000000a1', 'zz-s84c-2', 'airbnb', '2026-02-10', '2026-02-12', null, null, 'blocked', 'Airbnb (Not available)', null);

-- =============================================================== catalog
select ok((select count(*) = 3 and array_agg(attname::text order by attname::text) = array['guest_phone', 'raw_description', 'raw_summary']
             from pg_attribute where attrelid = 'public.calendar_events'::regclass and attnum > 0 and not attisdropped
              and not has_column_privilege('authenticated', 'public.calendar_events', attname, 'select')),
  'exactly guest_phone, raw_description and raw_summary are not readable by authenticated; every other column is');
select ok(not has_table_privilege('authenticated', 'public.calendar_events', 'select') and not has_table_privilege('authenticated', 'public.calendar_events', 'insert')
          and not has_table_privilege('authenticated', 'public.calendar_events', 'update'), 'and authenticated has no table-wide select, insert or update');
select ok(not has_function_privilege('anon', 'public.admin_calendar_event_v1(uuid)', 'execute') and not has_function_privilege('service_role', 'public.admin_calendar_event_v1(uuid)', 'execute')
          and not has_function_privilege('anon', 'public.admin_calendar_events_v1(uuid)', 'execute') and not has_function_privilege('service_role', 'public.admin_calendar_events_v1(uuid)', 'execute')
          and has_function_privilege('authenticated', 'public.admin_calendar_event_v1(uuid)', 'execute') and has_function_privilege('authenticated', 'public.admin_calendar_events_v1(uuid)', 'execute'),
  'both RPCs are granted to authenticated only');

-- =============================================================== a cleaner
select pg_temp.as_user('e8500000-0000-4000-8000-0000000000b1');
select throws_ok($$select guest_phone from public.calendar_events$$, '42501', null, 'a cleaner cannot select guest_phone');
select throws_ok($$select raw_summary from public.calendar_events$$, '42501', null, 'nor raw_summary');
select throws_ok($$select raw_description from public.calendar_events$$, '42501', null, 'nor raw_description');
select throws_ok($$select * from public.calendar_events$$, '42501', null, 'nor select * (the dashboard must use the RPCs)');
select throws_ok($$select id from public.calendar_events where guest_phone is not null$$, '42501', null, 'nor filter on guest_phone to probe it');
insert into _t select 'ck', (select jsonb_agg(to_jsonb(x)) from (select checkin_date, checkout_date, nights, status, block_reason, block_reason_source
                                                                  from public.calendar_events where property_id = 'e8500000-0000-4000-8000-0000000000a1' and status <> 'cancelled' order by checkin_date) x);
insert into _t select 'gn', (select to_jsonb(array_agg(guest_name order by checkin_date)) from public.calendar_events where property_id = 'e8500000-0000-4000-8000-0000000000a1');
select throws_ok($$select public.admin_calendar_event_v1('e8500000-0000-4000-8000-0000000000c1')$$, '42501', 'not_authorized', 'a cleaner is refused admin_calendar_event_v1');
select throws_ok($$select public.admin_calendar_events_v1('e8500000-0000-4000-8000-0000000000a1')$$, '42501', 'not_authorized', 'and admin_calendar_events_v1');
reset role;
select is((select jsonb_array_length(v) from _t where k = 'ck'), 2, 'the checklist''s exact column list (checkin_date, checkout_date, nights, status, block_reason, block_reason_source) is still readable by a cleaner');
select is((select (v->0->>'nights')::int from _t where k = 'ck'), 2, 'including the generated nights column');
select is((select v->>0 from _t where k = 'gn'), 'Zz Guest One', 'guest_name stays readable (the stay picker shows it)');

-- =============================================================== owner and admin
select pg_temp.as_user('e8500000-0000-4000-8000-0000000000b2');
insert into _t select 'one', public.admin_calendar_event_v1('e8500000-0000-4000-8000-0000000000c1');
insert into _t select 'none', coalesce(public.admin_calendar_event_v1('e8500000-0000-4000-8000-0000000000ff'), '"absent"'::jsonb);
insert into _t select 'list', public.admin_calendar_events_v1('e8500000-0000-4000-8000-0000000000a1');
select throws_ok($$select guest_phone from public.calendar_events$$, '42501', null, 'even an owner session cannot select guest_phone directly (the RPC is the way)');
reset role;
select pg_temp.as_user('e8500000-0000-4000-8000-0000000000b3');
insert into _t select 'list_admin', public.admin_calendar_events_v1('e8500000-0000-4000-8000-0000000000a1');
reset role;
select ok((select v->>'guest_phone' = '+639170000001' and v->>'raw_summary' = 'Reserved ZZSUMMARY' and v->>'raw_description' like 'Phone Number%' and v->>'guest_name' = 'Zz Guest One' and (v->>'nights')::int = 2 from _t where k = 'one'),
  'the owner gets the full row through admin_calendar_event_v1');
select is((select v from _t where k = 'none'), '"absent"'::jsonb, 'an id that does not exist gives null to an owner');
select is((select jsonb_array_length(v) from _t where k = 'list'), 2, 'the list RPC returns the property''s events');
select is((select v->0->>'raw_summary' from _t where k = 'list'), 'Airbnb (Not available)', 'with raw_summary, newest check-in first');
select ok((select bool_and((select array_agg(k order by k) from jsonb_object_keys(e) k) = array['checkin_date', 'checkout_date', 'guest_name', 'id', 'linked_reservation_id', 'raw_summary', 'source', 'status', 'synced_at', 'uid']) from _t, jsonb_array_elements(v) e where k = 'list'),
  'each list row has exactly the ten columns fetchStays selects');
select ok((select not (v::text ~* '(guest_phone|639170000001|raw_description)') from _t where k = 'list'), 'and no phone or description');
select is((select jsonb_array_length(v) from _t where k = 'list_admin'), 2, 'an admin reads the list too');

select * from finish();
rollback;
