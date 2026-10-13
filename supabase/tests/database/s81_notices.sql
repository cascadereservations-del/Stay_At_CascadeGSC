-- Session 81 (lane B): release s81_notices_20261014. notices_v1 and ops_notice_add_v1 as cleaner, finance, admin and a non-staff user,
-- the widened ops_notices checks, the house_times setting and the 60-minute weather rule.
-- Synthetic fixtures only (uuids e8100000-...); every lookup is scoped to them because a real backup holds real rows. Grants are not
-- asserted (a --no-acl rehearsal carries none); the release contract's forward checks prove them. Everything rolls back.
begin;
select plan(50);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
grant execute on function public.notices_v1(uuid), public.ops_notice_add_v1(text, text, date, time, numeric, text, uuid) to authenticated, service_role;
grant select, insert, update on public.ops_notices to authenticated;

-- fixtures -------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values
  ('e8100000-0000-4000-8000-0000000000a1', 'Synthetic S81 A', true),
  ('e8100000-0000-4000-8000-0000000000a2', 'Synthetic S81 B', true);
insert into auth.users(id) values
  ('e8100000-0000-4000-8000-0000000000e1'), ('e8100000-0000-4000-8000-0000000000e2'),
  ('e8100000-0000-4000-8000-0000000000e3'), ('e8100000-0000-4000-8000-0000000000e4');
insert into public.staff_access_profiles(user_id, role) values
  ('e8100000-0000-4000-8000-0000000000e1', 'cleaner'),
  ('e8100000-0000-4000-8000-0000000000e2', 'admin'),
  ('e8100000-0000-4000-8000-0000000000e3', 'finance');
insert into public.staff_property_access(user_id, property_id) values
  ('e8100000-0000-4000-8000-0000000000e1', 'e8100000-0000-4000-8000-0000000000a1'),
  ('e8100000-0000-4000-8000-0000000000e2', 'e8100000-0000-4000-8000-0000000000a1'),
  ('e8100000-0000-4000-8000-0000000000e3', 'e8100000-0000-4000-8000-0000000000a1');
-- e4 has no staff profile at all.

-- notices: an upcoming brownout (socoteco), a water notice whose text carries a phone number, an old one, an inactive one, one on another property
insert into public.ops_notices(id, property_id, notice_type, title, description, effective_date, effective_time, duration_hours, source, is_active) values
  ('e8100000-0000-4000-8000-0000000000b1', 'e8100000-0000-4000-8000-0000000000a1', 'brownout', 'Brownout 1:00 to 4:00 pm', null,
     (now() at time zone 'Asia/Manila')::date + 1, '13:00', 3, 'socoteco', true),
  ('e8100000-0000-4000-8000-0000000000b2', 'e8100000-0000-4000-8000-0000000000a1', 'water', 'Water off, call 0917 123 4567', 'Hotline 083-552-1234 or zz@example.com',
     (now() at time zone 'Asia/Manila')::date + 2, null, null, null, true),
  ('e8100000-0000-4000-8000-0000000000b3', 'e8100000-0000-4000-8000-0000000000a1', 'brownout', 'Zz old brownout', null,
     (now() at time zone 'Asia/Manila')::date - 3, '09:00', 2, 'socoteco', true),
  ('e8100000-0000-4000-8000-0000000000b4', 'e8100000-0000-4000-8000-0000000000a1', 'water', 'Zz inactive water', null,
     (now() at time zone 'Asia/Manila')::date + 3, null, null, 'gscwd', false),
  ('e8100000-0000-4000-8000-0000000000b5', 'e8100000-0000-4000-8000-0000000000a2', 'water', 'Zz other property water', null,
     (now() at time zone 'Asia/Manila')::date + 3, null, null, 'gscwd', true);
-- house items: one low-stock item on A, one open finding, two open handoffs
insert into public.inventory_items(id, property_id, name, qty_on_hand, reorder_below, is_active) values
  ('e8100000-0000-4000-8000-0000000000c1', 'e8100000-0000-4000-8000-0000000000a1', '0 Zz S81 soap', 2, 5, true);
insert into public.verifier_findings(key, check_id, severity, title, detail, status) values
  ('zz-s81-finding', 'V6', 'warn', '0 Zz S81 finding, guest paid P1,500', '{"guest":"Zz Guest","amount":1500}', 'open');
insert into public.concierge_handoffs(id, status) values
  ('e8100000-0000-4000-8000-0000000000d1', 'open'), ('e8100000-0000-4000-8000-0000000000d2', 'open');
-- weather cache: fresh, 14 hourly rows, google source, with a rain watch
delete from public.app_settings where key in ('weather_proxy_cache', 'house_times');
insert into public.app_settings(key, value, updated_at) values ('house_times', '{"check_out":"12:00","check_in":"14:00"}', now());
insert into public.app_settings(key, value, updated_at) values ('weather_proxy_cache', jsonb_build_object(
  'source', 'google_weather', 'fetched_at', '2026-10-13T12:00:00+08:00', 'code', 2, 'aqi', 42,
  'current', jsonb_build_object('temp', 30, 'description', 'Partly cloudy', 'rain_prob', 40, 'feels_like', 33, 'humidity', 70),
  'forecast', '[]'::jsonb,
  'hourly', (select jsonb_agg(jsonb_build_object('time', '2026-10-13T0' || (i % 10) || ':00:00.000Z', 'rain_chance_pct', 70 + i, 'mm', 1.2, 'code', 61, 'junk', 'x') order by i) from generate_series(0, 13) i),
  'rain_watch', jsonb_build_object('from', '2026-10-13T05:00:00.000Z', 'to', '2026-10-13T08:00:00.000Z', 'peak_pct', 85, 'junk', 'x')), now());

-- constraints widened, old values kept -----------------------------------------------------------------------------------------------------
select lives_ok($$insert into public.ops_notices(property_id, notice_type, title, effective_date, source) values ('e8100000-0000-4000-8000-0000000000a1', 'maintenance', 'Zz maint', current_date, 'system')$$,
  'maintenance and system are allowed now');
select lives_ok($$insert into public.ops_notices(property_id, notice_type, title, effective_date, source) values ('e8100000-0000-4000-8000-0000000000a1', 'deep_clean', 'Zz dc', current_date, 'gscwd')$$,
  'deep_clean and gscwd are allowed now');
select lives_ok($$insert into public.ops_notices(property_id, notice_type, title, effective_date, source) values ('e8100000-0000-4000-8000-0000000000a1', 'reminder', 'Zz old', current_date, 'staff')$$,
  'the old reminder / staff pair still works');
select throws_ok($$insert into public.ops_notices(property_id, notice_type, title, effective_date) values ('e8100000-0000-4000-8000-0000000000a1', 'bogus', 'Zz', current_date)$$,
  '23514', null, 'an unknown type is still refused');
select throws_ok($$insert into public.ops_notices(property_id, notice_type, title, effective_date, source) values ('e8100000-0000-4000-8000-0000000000a1', 'note', 'Zz', current_date, 'facebook')$$,
  '23514', null, 'an unknown source is still refused');

-- cleaner ----------------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e8100000-0000-4000-8000-0000000000e1"}';
select is(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->>'role', 'cleaner', 'cleaner: role is reported');
select is(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'house', '[]'::jsonb, 'cleaner: house is []');
select is(jsonb_typeof(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'inbox_open'), 'null', 'cleaner: inbox_open is null');
select ok(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')::text !~* '"[^"]*(phone|e-?mail|messenger|psid|id_photo|amount|total|payout|price)[^"]*"\s*:',
  'cleaner: no forbidden key anywhere in the payload');
select ok(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')::text !~* '(0917|552-1234|example\.com)', 'cleaner: no phone or e-mail value anywhere in the payload');
select is((select count(*)::int from jsonb_array_elements(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'notices') n where n->>'id' like 'e8100000%'), 2,
  'cleaner: the upcoming brownout and water notice show; the old, inactive and other-property ones do not');
select is((select n->>'title' from jsonb_array_elements(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'notices') n where n->>'id' = 'e8100000-0000-4000-8000-0000000000b2'),
  'Water off, call [hidden]', 'cleaner: a phone number in a notice title is redacted');
select is((select n->>'detail' from jsonb_array_elements(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'notices') n where n->>'id' = 'e8100000-0000-4000-8000-0000000000b2'),
  'Hotline [hidden] or [hidden]', 'cleaner: phone and e-mail in a notice detail are redacted');
select throws_ok($$select public.notices_v1('e8100000-0000-4000-8000-0000000000a2')$$, '42501', 'forbidden', 'cleaner: another property is forbidden');
select throws_ok($$select public.ops_notice_add_v1('note', 'Zz cleaner note', current_date + 1, null, null, null, 'e8100000-0000-4000-8000-0000000000a1')$$,
  '42501', 'forbidden', 'cleaner cannot add a notice');
reset role;

-- finance (read_operations, not manage_operations) ------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e8100000-0000-4000-8000-0000000000e3"}';
select is(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'house', '[]'::jsonb, 'finance: house is []');
select is(jsonb_typeof(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'inbox_open'), 'null', 'finance: inbox_open is null');
reset role;

-- not staff ------------------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e8100000-0000-4000-8000-0000000000e4"}';
select throws_ok($$select public.notices_v1('e8100000-0000-4000-8000-0000000000a1')$$, '42501', 'forbidden', 'a user with no staff profile is forbidden');
reset role;
set local role authenticated;
set local request.jwt.claims = '{}';
select throws_ok($$select public.notices_v1('e8100000-0000-4000-8000-0000000000a1')$$, '42501', 'forbidden', 'no session is forbidden');
reset role;

-- admin ------------------------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e8100000-0000-4000-8000-0000000000e2"}';
select is(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->>'role', 'admin', 'admin: role is reported');
select is(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'house_times', '{"check_out":"12:00","check_in":"14:00"}'::jsonb, 'admin: house_times is the shared setting');
select ok(exists(select 1 from jsonb_array_elements(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'house') h
  where h->>'kind' = 'low_stock' and h->>'id' = 'e8100000-0000-4000-8000-0000000000c1' and h->>'title' = 'Low stock: 0 Zz S81 soap' and h->>'detail' = 'Down to 2, reorder below 5'),
  'admin: the low-stock item is in house');
select ok(exists(select 1 from jsonb_array_elements(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'house') h
  where h->>'kind' = 'finding' and h->>'id' = 'zz-s81-finding' and h->>'title' = '0 Zz S81 finding, guest paid [hidden]' and h->'detail' = 'null'::jsonb),
  'admin: the open finding is in house, its money redacted and its jsonb detail not sent');
select ok((public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->>'inbox_open')::int >= 2, 'admin: inbox_open counts the open handoffs');
select ok(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')::text !~* '"[^"]*(phone|e-?mail|messenger|psid|id_photo|amount|total|payout|price)[^"]*"\s*:',
  'admin: no forbidden key anywhere either');
select is((select n->>'type' || '|' || (n->>'start_time') || '|' || (n->>'end_time') || '|' || (n->>'duration_hours') || '|' || (n->>'source')
    from jsonb_array_elements(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'notices') n where n->>'id' = 'e8100000-0000-4000-8000-0000000000b1'),
  'power|13:00|16:00|3.0|socoteco', 'admin: a brownout is a power notice with its end time');
select is((select n->>'type' || '|' || (n->>'source') || '|' || coalesce(n->>'start_time', 'null')
    from jsonb_array_elements(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'notices') n where n->>'id' = 'e8100000-0000-4000-8000-0000000000b2'),
  'water|manual|null', 'admin: a water notice with no source reads as manual');
-- weather
select is(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')#>>'{weather,source}', 'google', 'weather: google_weather reads as google');
select is((public.notices_v1('e8100000-0000-4000-8000-0000000000a1')#>>'{weather,temp_c}') || '|' || (public.notices_v1('e8100000-0000-4000-8000-0000000000a1')#>>'{weather,condition}')
  || '|' || (public.notices_v1('e8100000-0000-4000-8000-0000000000a1')#>>'{weather,code}') || '|' || (public.notices_v1('e8100000-0000-4000-8000-0000000000a1')#>>'{weather,rain_chance_pct}')
  || '|' || (public.notices_v1('e8100000-0000-4000-8000-0000000000a1')#>>'{weather,aqi}'), '30|Partly cloudy|2|40|42', 'weather: temp, condition, code, rain chance and aqi');
select is(jsonb_array_length(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')#>'{weather,hourly}'), 12, 'weather: hourly is capped at 12');
select is(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')#>'{weather,hourly,0}', '{"time":"2026-10-13T00:00:00.000Z","rain_chance_pct":70,"mm":1.2,"code":61}'::jsonb,
  'weather: an hourly row carries only time, rain_chance_pct, mm, code');
select is(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')#>'{weather,rain_watch}', '{"from":"2026-10-13T05:00:00.000Z","to":"2026-10-13T08:00:00.000Z","peak_pct":85}'::jsonb,
  'weather: rain_watch carries only from, to, peak_pct');
reset role;

-- weather age rule (under the superuser, then read as admin) ------------------------------------------------------------------------------------
update public.app_settings set updated_at = now() - interval '59 minutes' where key = 'weather_proxy_cache';
set local role authenticated; set local request.jwt.claims = '{"sub":"e8100000-0000-4000-8000-0000000000e2"}';
select is(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')#>>'{weather,temp_c}', '30', 'weather: 59 minutes old is still shown');
reset role;
update public.app_settings set updated_at = now() - interval '61 minutes' where key = 'weather_proxy_cache';
set local role authenticated; set local request.jwt.claims = '{"sub":"e8100000-0000-4000-8000-0000000000e2"}';
select is(jsonb_typeof(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'weather'), 'null', 'weather: 61 minutes old is null');
reset role;
delete from public.app_settings where key = 'weather_proxy_cache';
set local role authenticated; set local request.jwt.claims = '{"sub":"e8100000-0000-4000-8000-0000000000e2"}';
select is(jsonb_typeof(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'weather'), 'null', 'weather: a missing cache is null');
reset role;
-- an old cache written before the lane-B weather-proxy (no hourly, aqi, code, rain_watch) still reads
insert into public.app_settings(key, value, updated_at) values ('weather_proxy_cache', '{"source":"open_meteo","current":{"temp":29,"description":"Overcast","rain_prob":10}}', now());
set local role authenticated; set local request.jwt.claims = '{"sub":"e8100000-0000-4000-8000-0000000000e2"}';
select is((public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'weather') - 'fetched_at'::text,
  '{"source":"open-meteo","temp_c":29,"condition":"Overcast","code":null,"rain_chance_pct":10,"aqi":null,"hourly":[],"rain_watch":null}'::jsonb,
  'weather: an old-shape cache gives hourly [] and null code, aqi, rain_watch');
reset role;

-- house_times fallback ----------------------------------------------------------------------------------------------------------------------------
delete from public.app_settings where key = 'house_times';
set local role authenticated; set local request.jwt.claims = '{"sub":"e8100000-0000-4000-8000-0000000000e1"}';
select is(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'house_times', '{"check_out":"12:00","check_in":"14:00"}'::jsonb, 'house_times: the contract fallback when the key is missing');
reset role;
insert into public.app_settings(key, value) values ('house_times', '{"check_out":"11:30","check_in":"15:00"}');
set local role authenticated; set local request.jwt.claims = '{"sub":"e8100000-0000-4000-8000-0000000000e1"}';
select is(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'house_times', '{"check_out":"11:30","check_in":"15:00"}'::jsonb, 'house_times: a changed setting is what the app gets');
reset role;

-- ops_notice_add_v1 ------------------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e8100000-0000-4000-8000-0000000000e2"}';
select is((public.ops_notice_add_v1('water', 'Water tank cleaning', (now() at time zone 'Asia/Manila')::date + 4, '09:00', 2.5, 'Tank is flushed in the morning', 'e8100000-0000-4000-8000-0000000000a1'))->>'type',
  'water', 'admin adds a water notice');
reset role;
select is((select source || '|' || audience || '|' || is_active::text || '|' || duration_hours::text from public.ops_notices
  where property_id = 'e8100000-0000-4000-8000-0000000000a1' and title = 'Water tank cleaning'), 'manual|staff|true|2.5', 'the row is source manual, audience staff, active');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e8100000-0000-4000-8000-0000000000e2"}';
select ok(exists(select 1 from jsonb_array_elements(public.notices_v1('e8100000-0000-4000-8000-0000000000a1')->'notices') n where n->>'title' = 'Water tank cleaning' and n->>'type' = 'water'),
  'the added notice shows in notices_v1');
select throws_ok($$select public.ops_notice_add_v1('water', 'Call 0917 123 4567', current_date + 1, null, null, null, 'e8100000-0000-4000-8000-0000000000a1')$$,
  '22023', 'contact_or_amount_not_allowed', 'a phone number in the title is refused');
select throws_ok($$select public.ops_notice_add_v1('note', 'Fine title', current_date + 1, null, null, 'mail me at zz@example.com', 'e8100000-0000-4000-8000-0000000000a1')$$,
  '22023', 'contact_or_amount_not_allowed', 'an e-mail in the detail is refused');
select throws_ok($$select public.ops_notice_add_v1('note', 'Repairs cost P500', current_date + 1, null, null, null, 'e8100000-0000-4000-8000-0000000000a1')$$,
  '22023', 'contact_or_amount_not_allowed', 'an amount in the title is refused');
select throws_ok($$select public.ops_notice_add_v1('brownout', 'Zz', current_date + 1, null, null, null, 'e8100000-0000-4000-8000-0000000000a1')$$,
  '22023', 'type_not_allowed', 'a brownout cannot be added by hand');
select throws_ok($$select public.ops_notice_add_v1('note', repeat('x', 81), current_date + 1, null, null, null, 'e8100000-0000-4000-8000-0000000000a1')$$,
  '22023', 'title_length', 'an 81-character title is refused');
select throws_ok($$select public.ops_notice_add_v1('note', 'Zz', current_date + 900, null, null, null, 'e8100000-0000-4000-8000-0000000000a1')$$,
  '22023', 'date_out_of_range', 'a date over a year out is refused');
select throws_ok($$select public.ops_notice_add_v1('note', 'Zz', current_date + 1, null, 100, null, 'e8100000-0000-4000-8000-0000000000a1')$$,
  '22023', 'duration_out_of_range', 'a 100-hour duration is refused');
reset role;
-- finance cannot add either
set local role authenticated;
set local request.jwt.claims = '{"sub":"e8100000-0000-4000-8000-0000000000e3"}';
select throws_ok($$select public.ops_notice_add_v1('note', 'Zz finance note', current_date + 1, null, null, null, 'e8100000-0000-4000-8000-0000000000a1')$$,
  '42501', 'forbidden', 'finance cannot add a notice');
reset role;
select is((select count(*)::int from public.ops_notices where title in ('Zz cleaner note', 'Zz finance note')), 0, 'refused calls stored nothing');

select * from finish();
rollback;
