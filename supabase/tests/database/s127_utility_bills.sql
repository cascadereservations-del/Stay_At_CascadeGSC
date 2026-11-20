-- Session 127 (lane A, SQL): release s127_utility_bills_20261127. Contract: docs/s127/CONTRACT.md "Facts" and "Lane A".
-- utility_bill_estimate_v1 (cycle boundaries, billed-month rate and its fallback, water tiers, flagged readings), today_bills_v1 (refused as an anon caller, a signed-in user with no staff profile
-- and a cleaner of ANOTHER property; allowed for a cleaner of the property) and kpi_tab_v1 (usage_months, admin.bills / rate_history / rate_year_avg / water_rate / stays / rate.checked_at, and no peso key
-- from this release in the non-admin payload). Hand-computed numbers; see the comment above each block.
-- Synthetic fixtures only (uuids e1270000-..., properties ...b1 to ...b5, names "Zzguest ..."). The real rate table and the two app_settings keys this suite touches are cleared INSIDE this transaction
-- because a real backup holds real rows; everything rolls back. calendar_events.nights is generated and never inserted. Refusals are tested by calling as the refused role.
-- Nothing in this file can run without a Postgres that holds the Cascade schema: it is run by the rehearsal (scripts/recovery/p6/migration-rehearsal-on-host.sh <backup> <release.json> <this file>).
begin;
select plan(78);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;

create function pg_temp.id(p text) returns uuid language sql immutable as $$ select ('e1270000-0000-4000-8000-0000000000' || p)::uuid $$;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal1', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_anon() returns void language sql as $$
  select set_config('request.jwt.claims', '{}', true), set_config('role', 'anon', true);
$$;
create function pg_temp.try(p text) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  execute p into r;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
-- first day of the Manila month n months back, and 09:00 Manila on it (plus extra days)
create function pg_temp.ms(n integer) returns date language sql stable as $$ select (date_trunc('month', public.manila_today())::date - n * interval '1 month')::date $$;
create function pg_temp.mts(n integer) returns timestamptz language sql stable as $$ select (pg_temp.ms(n) + time '09:00') at time zone 'Asia/Manila' $$;
create temp table _t(k text primary key, v jsonb);
grant all on _t to public;

-- fixtures -------------------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values
  (pg_temp.id('b1'), 'Zz S127 cycles', true), (pg_temp.id('b2'), 'Zz S127 water', true), (pg_temp.id('b3'), 'Zz S127 kpi', true), (pg_temp.id('b4'), 'Zz S127 other', true), (pg_temp.id('b5'), 'Zz S127 stays', true);
insert into auth.users(id, email) values
  (pg_temp.id('a1'), 'zz127-cleaner@example.com'), (pg_temp.id('a2'), 'zz127-admin@example.com'), (pg_temp.id('a3'), 'zz127-laundry@example.com'),
  (pg_temp.id('a4'), 'zz127-nostaff@example.com'), (pg_temp.id('a5'), 'zz127-other@example.com');
insert into public.staff_access_profiles(user_id, role) values (pg_temp.id('a1'), 'cleaner'), (pg_temp.id('a2'), 'admin'), (pg_temp.id('a3'), 'laundry'), (pg_temp.id('a5'), 'cleaner');
insert into public.staff_property_access(user_id, property_id) values
  (pg_temp.id('a1'), pg_temp.id('b3')), (pg_temp.id('a2'), pg_temp.id('b3')), (pg_temp.id('a3'), pg_temp.id('b3')), (pg_temp.id('a5'), pg_temp.id('b4'));

delete from public.utility_rates;
delete from public.app_settings where key = 'power_watch_rate_day';

-- shape, grants, settings ---------------------------------------------------------------------------------------------------------------------
select ok(has_function_privilege('authenticated', 'public.today_bills_v1(uuid)', 'execute') and not has_function_privilege('anon', 'public.today_bills_v1(uuid)', 'execute')
          and not has_function_privilege('service_role', 'public.today_bills_v1(uuid)', 'execute'), 'today_bills_v1 runs for signed-in users only');
select ok((select bool_and(not has_function_privilege('anon', f, 'execute') and not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('service_role', f, 'execute'))
             from unnest(array['public.utility_billing_default_v1()', 'public.utility_billing_cfg_v1()', 'public.utility_cycle_v1(date,integer)', 'public.utility_rate_by_month_v1()',
                               'public.utility_water_php_v1(numeric,jsonb)', 'public.utility_water_next_v1(numeric,jsonb)', 'public.utility_bill_estimate_v1(uuid,date)',
                               'public.kpi_usage_months_v1(uuid,date)', 'public.kpi_admin_bills_v1(uuid,numeric)']) f),
          'the internal helpers and utility_bill_estimate_v1 run for nobody (not anon, authenticated, service_role)');
select ok((select bool_and(p.proconfig = array['search_path=""']) from pg_proc p
            where p.oid in ('public.utility_billing_default_v1()'::regprocedure, 'public.utility_billing_cfg_v1()'::regprocedure, 'public.utility_cycle_v1(date,integer)'::regprocedure,
                            'public.utility_rate_by_month_v1()'::regprocedure, 'public.utility_water_php_v1(numeric,jsonb)'::regprocedure, 'public.utility_water_next_v1(numeric,jsonb)'::regprocedure,
                            'public.utility_bill_estimate_v1(uuid,date)'::regprocedure, 'public.kpi_usage_months_v1(uuid,date)'::regprocedure, 'public.kpi_admin_bills_v1(uuid,numeric)'::regprocedure,
                            'public.today_bills_v1(uuid)'::regprocedure, 'public.kpi_tab_v1(uuid,date)'::regprocedure)),
          'every new function and kpi_tab_v1 keep search_path pinned to empty');
select ok((select bool_and(p.prosecdef) from pg_proc p where p.oid in ('public.utility_bill_estimate_v1(uuid,date)'::regprocedure, 'public.today_bills_v1(uuid)'::regprocedure, 'public.kpi_tab_v1(uuid,date)'::regprocedure))
          and has_function_privilege('authenticated', 'public.kpi_tab_v1(uuid,date)', 'execute') and not has_function_privilege('anon', 'public.kpi_tab_v1(uuid,date)', 'execute')
          and not has_function_privilege('service_role', 'public.kpi_tab_v1(uuid,date)', 'execute'), 'kpi_tab_v1 is still security definer, for signed-in users only');
select ok((select value = public.utility_billing_default_v1() from public.app_settings where key = 'utility_billing')
          and (select count(*) from public.app_settings where key = 'utility_billing') = 1, 'the utility_billing setting exists once and holds the contract defaults');
insert into public.app_settings(key, value) select 'utility_billing', '{"electric":{"cycle_day":1}}'::jsonb where not exists (select 1 from public.app_settings a where a.key = 'utility_billing');
select ok((select value = public.utility_billing_default_v1() from public.app_settings where key = 'utility_billing'), 'the migration insert is idempotent: an existing row is never replaced');

-- the setting is read with a fallback ------------------------------------------------------------------------------------------------------------
update public.app_settings set value = '{"electric":{"fixed_php":7.5}}'::jsonb where key = 'utility_billing';
select ok((public.utility_billing_cfg_v1() -> 'electric') = '{"cycle_day":21,"fixed_php":7.5}'::jsonb and (public.utility_billing_cfg_v1() -> 'water') = (public.utility_billing_default_v1() -> 'water'),
          'a stored partial setting wins key by key and the rest falls back to the defaults');
delete from public.app_settings where key = 'utility_billing';
select ok(public.utility_billing_cfg_v1() = public.utility_billing_default_v1(), 'no setting row: every function falls back to the defaults');
select ok(public.utility_billing_default_v1() = '{"electric":{"cycle_day":21,"fixed_php":5.60},"water":{"cycle_day":21,"min_php":212,"min_m3":10,"tiers":[{"upto":20,"php":23.05},{"upto":30,"php":26.65},{"upto":40,"php":30.50},{"upto":null,"php":34.50}],"source_url":"https://gensanwater.gov.ph/water-rates/"}}'::jsonb,
          'the defaults are exactly the contract values');
insert into public.app_settings(key, value) values ('utility_billing', public.utility_billing_default_v1());
select is((select count(*)::int from public.app_settings where key = 'utility_billing'), 1, 'the setting row is back to the defaults');

-- water tariff, hand-computed with the default tiers: 212 covers 0-10; 11-20 at 23.05; 21-30 at 26.65; 31-40 at 30.50; 41+ at 34.50 -------------------------------
select ok(public.utility_water_php_v1(0, public.utility_billing_cfg_v1()) = 212 and public.utility_water_php_v1(10, public.utility_billing_cfg_v1()) = 212, 'water: 0 and exactly 10 m3 cost the 212 minimum');
select ok(public.utility_water_php_v1(10.01, public.utility_billing_cfg_v1()) = 212.23, 'water: 10.01 m3 = 212 + 0.01 x 23.05 = 212.23');
select ok(public.utility_water_php_v1(20, public.utility_billing_cfg_v1()) = 442.50, 'water: 20 m3 = 212 + 10 x 23.05 = 442.50');
select ok(public.utility_water_php_v1(20.5, public.utility_billing_cfg_v1()) = 455.83, 'water: 20.5 m3 = 212 + 230.50 + 0.5 x 26.65 = 455.825 -> 455.83');
select ok(public.utility_water_php_v1(40, public.utility_billing_cfg_v1()) = 1014.00, 'water: 40 m3 = 212 + 230.50 + 266.50 + 305.00 = 1014.00');
select ok(public.utility_water_php_v1(45, public.utility_billing_cfg_v1()) = 1186.50, 'water: 45 m3 = 1014.00 + 5 x 34.50 = 1186.50');
select ok((public.utility_water_next_v1(0, public.utility_billing_cfg_v1()) = '{"php":23.05,"upto":20}'::jsonb) and (public.utility_water_next_v1(20, public.utility_billing_cfg_v1()) = '{"php":26.65,"upto":30}'::jsonb)
          and (public.utility_water_next_v1(45, public.utility_billing_cfg_v1()) -> 'php') = '34.50'::jsonb and (public.utility_water_next_v1(45, public.utility_billing_cfg_v1()) -> 'upto') = 'null'::jsonb,
          'the next tier: 23.05 up to 20 inside the minimum, 26.65 up to 30 at 20 m3, 34.50 with no ceiling at 45 m3');

-- cycles (from, to]: a reading checked out ON the 21st closes the cycle that ends that day ---------------------------------------------------------------------
select ok(public.utility_cycle_v1(date '2020-11-20', 21) = array[date '2020-10-21', date '2020-11-21'] and public.utility_cycle_v1(date '2020-11-21', 21) = array[date '2020-10-21', date '2020-11-21'],
          'cycle: the 20th and the 21st belong to the cycle that ends 21 Nov');
select ok(public.utility_cycle_v1(date '2020-11-22', 21) = array[date '2020-11-21', date '2020-12-21'], 'cycle: the 22nd starts the next cycle');
select ok(public.utility_cycle_v1(date '2020-12-25', 21) = array[date '2020-12-21', date '2021-01-21'], 'cycle: December rolls into January');
select ok(public.utility_cycle_v1(date '2021-03-05', 31) = array[date '2021-02-28', date '2021-03-28'], 'cycle: a cycle day above 28 is held at 28 (documented shortcut)');

-- rates: one per month, manual before auto, then newest; no client reads them ----------------------------------------------------------------------------
insert into public.utility_rates(provider, php_per_kwh, effective_from, source) values
  ('socoteco2', 8, date '2020-09-01', 'auto'), ('socoteco2', 10, date '2020-10-01', 'manual'),
  ('socoteco2', 11, date '2020-11-01', 'auto'), ('socoteco2', 12, date '2020-11-01', 'manual'), ('socoteco2', 13, date '2020-11-10', 'auto');
select ok((select array_agg(r.php_per_kwh order by r.rate_month) = array[8, 10, 12]::numeric[] and count(*) = 3 from public.utility_rate_by_month_v1() r),
          'rates by month: September 8 (auto), October 10, November 12 (the manual 12 beats the auto 11 and the newer auto 13)');

-- readings of the cycle scenarios (property b1). Counted: r1 10 kWh 1.0 m3 on 21 Oct, r2 20/2.0 on 25 Oct, r3 50/5.0 on 5 Nov, r4 20/2.0 on 20 Nov, r5 10/1.0 on 21 Nov, r6 15/1.5 on 22 Nov.
-- Ignored by the s115 helper: rf misread 400 kWh / 40 m3, rr re_entry 300, rq first_reading 300.
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('c1'), null, pg_temp.id('b1'), timestamptz '2020-10-21 09:00+08', 1000, 1010, 50, 10, 1.0, null),
  (pg_temp.id('c2'), null, pg_temp.id('b1'), timestamptz '2020-10-25 09:00+08', 1010, 1030, 51, 20, 2.0, null),
  (pg_temp.id('c3'), null, pg_temp.id('b1'), timestamptz '2020-11-05 09:00+08', 1030, 1080, 53, 50, 5.0, null),
  (pg_temp.id('cf'), null, pg_temp.id('b1'), timestamptz '2020-11-08 09:00+08', 1080, 1480, 58, 400, 40, 'misread'),
  (pg_temp.id('cr'), null, pg_temp.id('b1'), timestamptz '2020-11-12 09:00+08', 1080, 1380, 58, 300, 30, 're_entry'),
  (pg_temp.id('cq'), null, pg_temp.id('b1'), timestamptz '2020-11-14 09:00+08', 1080, 1380, 58, 300, 30, 'first_reading'),
  (pg_temp.id('c4'), null, pg_temp.id('b1'), timestamptz '2020-11-20 09:00+08', 1080, 1100, 58, 20, 2.0, null),
  (pg_temp.id('c5'), null, pg_temp.id('b1'), timestamptz '2020-11-21 12:00+08', 1100, 1110, 60, 10, 1.0, null),
  (pg_temp.id('c6'), null, pg_temp.id('b1'), timestamptz '2020-11-22 09:00+08', 1110, 1125, 61, 15, 1.5, null);
insert into _t select 'e1120', public.utility_bill_estimate_v1(pg_temp.id('b1'), date '2020-11-20');
insert into _t select 'e1121', public.utility_bill_estimate_v1(pg_temp.id('b1'), date '2020-11-21');
insert into _t select 'e1122', public.utility_bill_estimate_v1(pg_temp.id('b1'), date '2020-11-22');
insert into _t select 'e1015', public.utility_bill_estimate_v1(pg_temp.id('b1'), date '2020-10-15');
insert into _t select 'e1905', public.utility_bill_estimate_v1(pg_temp.id('b1'), date '2019-05-15');

-- the cycle ending 21 Nov: kwh 20 + 50 + 20 + 10 = 100 (the misread, re_entry and first_reading rows are ignored); days 21 Oct -> 21 Nov = 31; rate 12 (the manual November rate);
-- so far 100 x 12 + 5.60 = 1205.60; forecast 100 / 31 x 31 = 100 kWh = 1205.60; per day 100 / 31 = 3.23 kWh, 3.2258 x 12 = 38.71
select ok((select v -> 'electric' ->> 'cycle_from' = '2020-10-21' and v -> 'electric' ->> 'cycle_to' = '2020-11-21' and (v -> 'electric' ->> 'days')::int = 31 and (v -> 'electric' ->> 'days_in_cycle')::int = 31
             from _t where k = 'e1120'), 'the 20th: cycle 21 Oct to 21 Nov, 31 days');
select ok((select (v -> 'electric' ->> 'kwh')::numeric = 100 from _t where k = 'e1120'), 'the 20th: 100 kWh, so a misread, a re_entry and a first_reading row are not counted');
select ok((select (v -> 'electric' ->> 'rate')::numeric = 12 and (v -> 'electric' ->> 'fixed_php')::numeric = 5.6 and (v -> 'electric' ->> 'so_far_php')::numeric = 1205.60 from _t where k = 'e1120'),
          'the 20th: rate 12 (manual beats auto), so far 100 x 12 + 5.60 = 1205.60');
select ok((select (v -> 'electric' ->> 'forecast_kwh')::numeric = 100 and (v -> 'electric' ->> 'forecast_php')::numeric = 1205.60 and (v -> 'electric' ->> 'per_day_kwh')::numeric = 3.23
                  and (v -> 'electric' ->> 'per_day_php')::numeric = 38.71 from _t where k = 'e1120'), 'the 20th: forecast 100 kWh = 1205.60, per day 3.23 kWh = 38.71');
select ok((select (v -> 'electric' ->> 'last_reading_at')::timestamptz = timestamptz '2020-11-21 12:00+08' from _t where k = 'e1120'), 'last_reading_at is the latest counted reading of the cycle (the 21 Nov one)');
select ok((select a.v = b.v from _t a, _t b where a.k = 'e1121' and b.k = 'e1120'), 'the 21st: the same cycle as the 20th, so the same bill (a reading checked out on the 21st closes the cycle that ends that day)');

-- the 22nd: next cycle 21 Nov -> 21 Dec, billed in December which has no rate yet, so the latest earlier rate (November 12) is used.
-- kwh 15 over days = 22 Nov - 21 Nov = 1; so far 15 x 12 + 5.60 = 185.60; forecast 15 x 30 = 450 kWh = 450 x 12 + 5.60 = 5405.60; per day 15 kWh = 180.00
select ok((select v -> 'electric' ->> 'cycle_from' = '2020-11-21' and v -> 'electric' ->> 'cycle_to' = '2020-12-21' and (v -> 'electric' ->> 'days')::int = 1 and (v -> 'electric' ->> 'days_in_cycle')::int = 30
             and (v -> 'electric' ->> 'kwh')::numeric = 15 from _t where k = 'e1122'), 'the 22nd: the next cycle holds only the 22 Nov reading (15 kWh in 1 of 30 days)');
select ok((select (v -> 'electric' ->> 'rate')::numeric = 12 and (v -> 'electric' ->> 'so_far_php')::numeric = 185.60 from _t where k = 'e1122'), 'the 22nd: no December rate yet, November 12 is used: 185.60 so far');
select ok((select (v -> 'electric' ->> 'forecast_kwh')::numeric = 450 and (v -> 'electric' ->> 'forecast_php')::numeric = 5405.60 and (v -> 'electric' ->> 'per_day_kwh')::numeric = 15
                  and (v -> 'electric' ->> 'per_day_php')::numeric = 180 from _t where k = 'e1122'), 'the 22nd: forecast 450 kWh = 5405.60, per day 15 kWh = 180.00');
select ok((select (v -> 'electric' ->> 'kwh')::numeric = 10 and (v -> 'electric' ->> 'rate')::numeric = 10 and (v -> 'electric' ->> 'so_far_php')::numeric = 105.60 and (v -> 'electric' ->> 'days')::int = 30 from _t where k = 'e1015'),
          'the cycle ending 21 Oct is billed at the October rate 10 (not the rate of the day it is read): 10 x 10 + 5.60 = 105.60');

-- no rate at all for the billed month or before it: null, never a guess; no reading: zeros and no forecast
select ok((select v -> 'electric' -> 'rate' = 'null'::jsonb and v -> 'electric' -> 'so_far_php' = 'null'::jsonb and v -> 'electric' -> 'forecast_php' = 'null'::jsonb and v -> 'electric' -> 'per_day_php' = 'null'::jsonb
             and (v -> 'electric' ->> 'kwh')::numeric = 0 from _t where k = 'e1905'), 'no rate on or before the billed month: rate, so_far_php, forecast_php and per_day_php are null');
select ok((select (v -> 'electric' ->> 'days')::int = 0 and v -> 'electric' -> 'forecast_kwh' = 'null'::jsonb and v -> 'electric' -> 'per_day_kwh' = 'null'::jsonb and v -> 'electric' -> 'last_reading_at' = 'null'::jsonb
             and v -> 'water' -> 'forecast_m3' = 'null'::jsonb and v -> 'water' -> 'forecast_php' = 'null'::jsonb and v -> 'water' -> 'per_day_m3' = 'null'::jsonb from _t where k = 'e1905'),
          'no counted reading in the cycle: days 0, forecasts and per-day figures null');
select ok((select (v -> 'water' ->> 'so_far_php')::numeric = 212 and (v -> 'water' ->> 'm3')::numeric = 0 from _t where k = 'e1905'), 'no water used: the bill is the 212 minimum');

-- water of the cycle ending 21 Nov: 2 + 5 + 2 + 1 = 10 m3 (the misread 40 m3 is ignored) = 212; per day 10 / 31 = 0.32; the next tier is 23.05 up to 20
select ok((select (v -> 'water' ->> 'm3')::numeric = 10 and (v -> 'water' ->> 'so_far_php')::numeric = 212 and (v -> 'water' ->> 'days')::int = 31 and v -> 'water' ->> 'cycle_from' = '2020-10-21'
             and (v -> 'water' ->> 'forecast_m3')::numeric = 10 and (v -> 'water' ->> 'forecast_php')::numeric = 212 and (v -> 'water' ->> 'per_day_m3')::numeric = 0.32 from _t where k = 'e1120'),
          'water, cycle ending 21 Nov: 10 m3 = 212 (a flagged 40 m3 reading is ignored)');
select ok((select (v -> 'water' ->> 'min_php')::numeric = 212 and (v -> 'water' ->> 'min_m3')::numeric = 10 and (v -> 'water' ->> 'next_php')::numeric = 23.05 and (v -> 'water' ->> 'next_upto')::numeric = 20 from _t where k = 'e1120'),
          'water: minimum 212 for 10 m3, next 23.05 up to 20');
select ok((select (v -> 'water' ->> 'm3')::numeric = 1.5 and (v -> 'water' ->> 'forecast_m3')::numeric = 45 and (v -> 'water' ->> 'forecast_php')::numeric = 1186.50 and (v -> 'water' ->> 'so_far_php')::numeric = 212 from _t where k = 'e1122'),
          'water, the 22nd: 1.5 m3 in 1 of 30 days forecasts 45 m3 = 1186.50');

-- one reading of 45 m3 (first reading of its chain, property b2): cycle ending 21 Jun, days 21 May -> 10 Jun = 20, no rate for June 2020 yet.
-- so far 1186.50 (45 m3); forecast 45 / 20 x 31 = 69.75 m3 = 212 + 230.50 + 266.50 + 305.00 + 29.75 x 34.50 = 2040.375 -> 2040.38; per day 2.25; next 34.50 with no ceiling
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('d1'), null, pg_temp.id('b2'), timestamptz '2020-06-10 09:00+08', 100, 110, 5, 10, 45, null);
insert into _t select 'w45', public.utility_bill_estimate_v1(pg_temp.id('b2'), date '2020-06-15');
select ok((select (v -> 'water' ->> 'm3')::numeric = 45 and (v -> 'water' ->> 'days')::int = 20 and (v -> 'water' ->> 'so_far_php')::numeric = 1186.50 from _t where k = 'w45'), 'water: 45 m3 so far = 1186.50 over 20 days');
select ok((select (v -> 'water' ->> 'forecast_m3')::numeric = 69.75 and (v -> 'water' ->> 'forecast_php')::numeric = 2040.38 and (v -> 'water' ->> 'per_day_m3')::numeric = 2.25 from _t where k = 'w45'),
          'water: forecast 69.75 m3 = 2040.38, per day 2.25');
select ok((select (v -> 'water' ->> 'next_php')::numeric = 34.50 and v -> 'water' -> 'next_upto' = 'null'::jsonb and v -> 'electric' -> 'rate' = 'null'::jsonb from _t where k = 'w45'),
          'water: past 40 m3 the next tier is 34.50 with no ceiling; electricity has no June 2020 rate (null)');

-- KPI scenario (property b3): rates relative to this month; the 2020 rates are cleared so the history is only these.
-- m-2 manual 11, m-1 manual 10, m0 manual 12 and an auto 11 on the 6th (the manual one wins). history newest first: m0 12 (+20.0 vs 10), m-1 10 (-9.1 vs 11: -1/11), m-2 11 (null, no earlier month).
delete from public.utility_rates;
insert into public.utility_rates(provider, php_per_kwh, effective_from, source) values
  ('socoteco2', 11, pg_temp.ms(2), 'manual'), ('socoteco2', 10, pg_temp.ms(1), 'manual'), ('socoteco2', 12, pg_temp.ms(0), 'manual'), ('socoteco2', 11, pg_temp.ms(0) + 5, 'auto');
-- readings on the 1st of each month, 09:00 Manila: m-6 100 kWh / 4 m3, m-5 100 / 10, m-4 150 / 12, (m-3 none), m-2 120 / 6, m-1 90 / 9 (+ a misread of 999 kWh / 99 m3 that is ignored),
-- today: m0a 30 / 3.0 (a stay ends) and m0b 5 / 0.5 on a mid_stay session (counted, but it ends no stay)
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaned_at, nights_stayed, checkout_date, cleaning_type) values
  (pg_temp.id('e1'), 'zz127-sub-e1', 'Zz127 Cleaner', pg_temp.id('b3'), now(), 1, public.manila_today(), 'mid_stay');
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('f6'), null, pg_temp.id('b3'), pg_temp.mts(6), 900, 1000, 5, 100, 4, null),
  (pg_temp.id('f5'), null, pg_temp.id('b3'), pg_temp.mts(5), 1000, 1100, 10, 100, 10, null),
  (pg_temp.id('f4'), null, pg_temp.id('b3'), pg_temp.mts(4), 1100, 1250, 20, 150, 12, null),
  (pg_temp.id('f2'), null, pg_temp.id('b3'), pg_temp.mts(2), 1250, 1370, 40, 120, 6, null),
  (pg_temp.id('f1'), null, pg_temp.id('b3'), pg_temp.mts(1), 1370, 1460, 50, 90, 9, null),
  (pg_temp.id('fm'), null, pg_temp.id('b3'), pg_temp.mts(1) + interval '14 days', 1460, 2459, 60, 999, 99, 'misread'),
  (pg_temp.id('f0'), null, pg_temp.id('b3'), (public.manila_today() + time '00:10') at time zone 'Asia/Manila', 1460, 1490, 70, 30, 3.0, null);
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('fb'), pg_temp.id('e1'), pg_temp.id('b3'), (public.manila_today() + time '00:20') at time zone 'Asia/Manila', 1490, 1495, 75, 5, 0.5, null);
-- stays that end on those days: Ana (linked airbnb reservation, ID photo with a face box) on m-1, Ben (linked reservation, no ID photo) today, and four calendar-only stays (no guest record)
insert into public.guests(id, property_id, name) values (pg_temp.id('91'), pg_temp.id('b3'), 'Zzguest Ana'), (pg_temp.id('92'), pg_temp.id('b3'), 'Zzguest Ben');
insert into public.airbnb_reservations(id, property_id, confirmation_code, status, guest_id, guest_name, checkin_date, checkout_date) values
  (pg_temp.id('81'), pg_temp.id('b3'), 'ZZ127A', 'completed', pg_temp.id('91'), 'Zzguest Ana', pg_temp.ms(1) - 2, pg_temp.ms(1)),
  (pg_temp.id('82'), pg_temp.id('b3'), 'ZZ127B', 'confirmed', pg_temp.id('92'), 'Zzguest Ben', public.manila_today() - 2, public.manila_today());
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date, linked_reservation_id) values
  (pg_temp.id('b3'), 'zz127-ev-a', 'airbnb', 'confirmed', 'Zzguest Ana', pg_temp.ms(1) - 2, pg_temp.ms(1), pg_temp.id('81')),
  (pg_temp.id('b3'), 'zz127-ev-b', 'airbnb', 'confirmed', 'Zzguest Ben', public.manila_today() - 2, public.manila_today(), pg_temp.id('82')),
  (pg_temp.id('b3'), 'zz127-ev-c', 'airbnb', 'confirmed', 'Zzguest Cy',  pg_temp.ms(2) - 1, pg_temp.ms(2), null),
  (pg_temp.id('b3'), 'zz127-ev-d', 'airbnb', 'confirmed', 'Zzguest Dee', pg_temp.ms(4) - 1, pg_temp.ms(4), null),
  (pg_temp.id('b3'), 'zz127-ev-e', 'airbnb', 'confirmed', 'Zzguest Eli', pg_temp.ms(5) - 1, pg_temp.ms(5), null),
  (pg_temp.id('b3'), 'zz127-ev-f', 'airbnb', 'confirmed', 'Zzguest Fay', pg_temp.ms(6) - 1, pg_temp.ms(6), null);
insert into public.guest_companions(id, guest_id, property_id, name, id_photo_path, id_face_box) values
  (pg_temp.id('71'), pg_temp.id('91'), pg_temp.id('b3'), 'Zzguest Ana', 'zz127/photo-ana.jpg', '{"x":0.1,"y":0.1,"w":0.3,"h":0.3,"src":"vision"}'::jsonb);
insert into public.app_settings(key, value) values ('power_watch_rate_day', '{"checked_at":"2026-11-20T08:00:00+08:00","note":"zz127"}'::jsonb);

-- non-admin callers read the payload as themselves
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 'k_cleaner', pg_temp.try($$select public.kpi_tab_v1('e1270000-0000-4000-8000-0000000000b3')$$);
insert into _t select 'tb_cleaner', pg_temp.try($$select public.today_bills_v1('e1270000-0000-4000-8000-0000000000b3')$$);
select pg_temp.as_user(pg_temp.id('a3'));
insert into _t select 'k_laundry', pg_temp.try($$select public.kpi_tab_v1('e1270000-0000-4000-8000-0000000000b3')$$);
insert into _t select 'tb_laundry', pg_temp.try($$select public.today_bills_v1('e1270000-0000-4000-8000-0000000000b3')$$);
-- the refused roles: a signed-in user with no staff profile, a cleaner of ANOTHER property, a cleaner asking for a property that does not exist, anon
select pg_temp.as_user(pg_temp.id('a4'));
insert into _t select 'tb_nostaff', pg_temp.try($$select public.today_bills_v1('e1270000-0000-4000-8000-0000000000b3')$$);
select pg_temp.as_user(pg_temp.id('a5'));
insert into _t select 'tb_other', pg_temp.try($$select public.today_bills_v1('e1270000-0000-4000-8000-0000000000b3')$$);
insert into _t select 'tb_null', pg_temp.try($$select public.today_bills_v1(null)$$);
select pg_temp.as_anon();
insert into _t select 'tb_anon', pg_temp.try($$select public.today_bills_v1('e1270000-0000-4000-8000-0000000000b3')$$);
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'k_admin', pg_temp.try($$select public.kpi_tab_v1('e1270000-0000-4000-8000-0000000000b3')$$);
reset role;
-- and again without the rate-day setting
delete from public.app_settings where key = 'power_watch_rate_day';
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'k_admin2', pg_temp.try($$select public.kpi_tab_v1('e1270000-0000-4000-8000-0000000000b3')$$);
reset role;

-- today_bills_v1: refused for everyone who is not active staff of the property, allowed for a cleaner and laundry.
-- Today's cycle holds only today's two readings (30 + 5 kWh, 3.0 + 0.5 m3): electricity 35 x 12 + 5.60 = 425.60 (billed at this month's 12 or, after the 21st, next month's fallback 12), water 3.5 m3 = 212.
select ok((select v ->> 'err' = '42501' from _t where k = 'tb_nostaff'), 'today_bills_v1: a signed-in user with no staff profile is refused (42501)');
select ok((select v ->> 'err' = '42501' from _t where k = 'tb_other'), 'today_bills_v1: a cleaner of another property is refused (42501)');
select ok((select v ->> 'err' = '42501' from _t where k = 'tb_anon') and (select v ->> 'err' = '42501' from _t where k = 'tb_null'), 'today_bills_v1: anon and a null property are refused (42501)');
select ok((select (v ? 'err') is not true and (select array_agg(key order by key) from jsonb_object_keys(v) key) = array['electric', 'last_reading_at', 'since', 'water'] from _t where k = 'tb_cleaner')
          and (select (v ? 'err') is not true from _t where k = 'tb_laundry'), 'today_bills_v1: allowed for a cleaner and for laundry, with exactly the four contract keys');
select ok((select (v -> 'electric' ->> 'kwh')::numeric = 35 and (v -> 'electric' ->> 'php')::numeric = 425.60 and (v -> 'water' ->> 'm3')::numeric = 3.5 and (v -> 'water' ->> 'php')::numeric = 212
             and (select array_agg(key order by key) from jsonb_object_keys(v -> 'electric') key) = array['kwh', 'php'] and (select array_agg(key order by key) from jsonb_object_keys(v -> 'water') key) = array['m3', 'php']
             from _t where k = 'tb_cleaner'), 'today_bills_v1: 35 kWh = 425.60, 3.5 m3 = 212');
select ok((select (v ->> 'since')::date = (public.utility_cycle_v1(public.manila_today(), 21))[1] and (v ->> 'last_reading_at')::timestamptz = (public.manila_today() + time '00:20') at time zone 'Asia/Manila' from _t where k = 'tb_cleaner'),
          'today_bills_v1: since is the cycle start and last_reading_at the latest counted reading');

-- kpi_tab_v1 for a cleaner and for laundry: usage_months (no money) yes; no admin block and no peso key from this release
select ok((select v ? 'ok' and (v ->> 'ok')::boolean and not (v ? 'admin') and jsonb_array_length(v -> 'utility' -> 'usage_months') = 6 from _t where k = 'k_cleaner')
          and (select not (v ? 'admin') and jsonb_array_length(v -> 'utility' -> 'usage_months') = 6 from _t where k = 'k_laundry'), 'kpi_tab_v1: a cleaner and laundry get usage_months and no admin block');
select ok((select bool_and(not (v::text ~ '"(bills|rate_year_avg|rate_history|water_rate|so_far_php|forecast_php|per_day_php|cost_php|checked_at|fixed_php|php_per_kwh|min_php|next_php)"')) from _t where k in ('k_cleaner', 'k_laundry')),
          'kpi_tab_v1: the non-admin payload carries no peso key of this release');
select ok((select bool_and(not ((v -> 'utility' -> 'usage_months')::text ~* 'php|cost|peso')) from _t where k in ('k_cleaner', 'k_laundry', 'k_admin')), 'usage_months carries no money, for any role');

-- usage_months, oldest first, m-5 .. m0. Hand-computed from the readings above (the misread 999 / 99 is ignored; m-3 has no counted reading; m-6 is outside the window):
-- m-5 100 kWh 10 m3; m-4 150 / 12 (+50 %, +20 %); m-3 null; m-2 120 / 6 against m-4 (-20 %, -50 %); m-1 90 / 9 (-25 %, +50 %); m0 so far 35 kWh / 3.5 m3, forecast = so far / day of month x days in the month.
select ok((select jsonb_array_length(v -> 'utility' -> 'usage_months') = 6 and v -> 'utility' -> 'usage_months' -> 0 ->> 'month' = to_char(pg_temp.ms(5), 'YYYY-MM')
                  and v -> 'utility' -> 'usage_months' -> 5 ->> 'month' = to_char(pg_temp.ms(0), 'YYYY-MM') from _t where k = 'k_admin'), 'usage_months: six months, oldest first, ending with the current Manila month');
select ok((select (m -> 0 ->> 'kwh')::numeric = 100 and (m -> 0 ->> 'm3')::numeric = 10 and m -> 0 -> 'kwh_change_pct' = 'null'::jsonb and m -> 0 -> 'm3_change_pct' = 'null'::jsonb and (m -> 0 ->> 'forecast')::boolean is false
             and m -> 0 -> 'kwh_so_far' = 'null'::jsonb from (select v -> 'utility' -> 'usage_months' m from _t where k = 'k_admin') x), 'usage_months: the first month has no change value and is not a forecast');
select ok((select (m -> 1 ->> 'kwh')::numeric = 150 and (m -> 1 ->> 'm3')::numeric = 12 and (m -> 1 ->> 'kwh_change_pct')::numeric = 50 and (m -> 1 ->> 'm3_change_pct')::numeric = 20
             from (select v -> 'utility' -> 'usage_months' m from _t where k = 'k_admin') x), 'usage_months: m-4 is 150 kWh (+50 %) and 12 m3 (+20 %), whole percent');
select ok((select m -> 2 -> 'kwh' = 'null'::jsonb and m -> 2 -> 'm3' = 'null'::jsonb and m -> 2 -> 'kwh_change_pct' = 'null'::jsonb and m -> 2 -> 'm3_change_pct' = 'null'::jsonb
             from (select v -> 'utility' -> 'usage_months' m from _t where k = 'k_admin') x), 'usage_months: a month with no counted reading has null kwh and m3 and no change');
select ok((select (m -> 3 ->> 'kwh')::numeric = 120 and (m -> 3 ->> 'm3')::numeric = 6 and (m -> 3 ->> 'kwh_change_pct')::numeric = -20 and (m -> 3 ->> 'm3_change_pct')::numeric = -50
             from (select v -> 'utility' -> 'usage_months' m from _t where k = 'k_admin') x), 'usage_months: change is against the previous month that has a value (m-2 vs m-4), negative when it fell');
select ok((select (m -> 4 ->> 'kwh')::numeric = 90 and (m -> 4 ->> 'm3')::numeric = 9 and (m -> 4 ->> 'kwh_change_pct')::numeric = -25 and (m -> 4 ->> 'm3_change_pct')::numeric = 50
             from (select v -> 'utility' -> 'usage_months' m from _t where k = 'k_admin') x), 'usage_months: m-1 is 90 kWh (-25 %) and 9 m3 (+50 %); the misread 999 kWh is ignored');
select ok((select (m -> 5 ->> 'forecast')::boolean and (m -> 5 ->> 'kwh_so_far')::numeric = 35 and (m -> 5 ->> 'm3_so_far')::numeric = 3.5
                  and (m -> 5 ->> 'kwh')::numeric = round(35.0 / extract(day from public.manila_today()) * ((pg_temp.ms(0) + interval '1 month')::date - pg_temp.ms(0)), 2)
                  and (m -> 5 ->> 'm3')::numeric = round(3.5 / extract(day from public.manila_today()) * ((pg_temp.ms(0) + interval '1 month')::date - pg_temp.ms(0)), 2)
             from (select v -> 'utility' -> 'usage_months' m from _t where k = 'k_admin') x), 'usage_months: the current month is a forecast = so far / days elapsed x days in the month, with the raw sums beside it');
select ok((select (m -> 5 ->> 'kwh_change_pct')::numeric = round(((m -> 5 ->> 'kwh')::numeric - 90) / 90 * 100) and (m -> 5 ->> 'm3_change_pct')::numeric = round(((m -> 5 ->> 'm3')::numeric - 9) / 9 * 100)
             from (select v -> 'utility' -> 'usage_months' m from _t where k = 'k_admin') x), 'usage_months: the current month changes against the previous month that has a value');
select ok((select bool_and((select count(*) from jsonb_object_keys(e)) = 8 and e ?& array['month', 'kwh', 'm3', 'kwh_change_pct', 'm3_change_pct', 'forecast', 'kwh_so_far', 'm3_so_far'])
             from (select jsonb_array_elements(v -> 'utility' -> 'usage_months') e from _t where k = 'k_admin') x), 'usage_months: every row has exactly the eight contract keys');

-- the admin block (owner/admin/finance only)
select ok((select v -> 'admin' ?& array['revenue_month', 'costs_month', 'net_month', 'occupancy', 'adr', 'sold_nights', 'sellable_nights', 'direct_share', 'rate', 'last_reading_cost', 'month_kwh_cost',
                                         'supplies_month', 'supply_cost_per_turnover', 'cleaning_pay_month', 'target'] and (v ->> 'ok')::boolean and v ? 'inventory' and v ? 'month' from _t where k = 'k_admin'),
          'kpi_tab_v1: every existing admin key and top-level key is still there');
select ok((select v -> 'admin' ?& array['bills', 'rate_year_avg', 'rate_history', 'water_rate', 'stays'] from _t where k = 'k_admin'), 'kpi_tab_v1: admin gains bills, rate_year_avg, rate_history, water_rate and stays');
select ok((select (v -> 'admin' -> 'bills' -> 'electric' ->> 'kwh')::numeric = 35 and (v -> 'admin' -> 'bills' -> 'electric' ->> 'rate')::numeric = 12 and (v -> 'admin' -> 'bills' -> 'electric' ->> 'so_far_php')::numeric = 425.60
                  and (v -> 'admin' -> 'bills' -> 'water' ->> 'so_far_php')::numeric = 212
             from _t where k = 'k_admin'), 'admin.bills is the estimate for today: 35 kWh at 12 + 5.60 = 425.60, water 212');
select ok((select (v -> 'admin' -> 'rate' ->> 'checked_at') = '2026-11-20T08:00:00+08:00' and (v -> 'admin' -> 'rate' ->> 'php_per_kwh')::numeric = 12 from _t where k = 'k_admin'),
          'admin.rate.checked_at comes from the power_watch_rate_day setting and the rate is still the one in force (12)');
select ok((select jsonb_typeof(v -> 'admin' -> 'rate' -> 'checked_at') = 'null' and (v -> 'admin' -> 'rate' ->> 'php_per_kwh')::numeric = 12 from _t where k = 'k_admin2'), 'admin.rate.checked_at is null when the setting is absent');
select ok((select jsonb_array_length(v -> 'admin' -> 'rate_history') = 3 and (select array_agg((e ->> 'php_per_kwh')::numeric order by o) from jsonb_array_elements(v -> 'admin' -> 'rate_history') with ordinality t(e, o)) = array[12, 10, 11]::numeric[]
             and (select array_agg(e ->> 'month' order by o) from jsonb_array_elements(v -> 'admin' -> 'rate_history') with ordinality t(e, o)) = array[to_char(pg_temp.ms(0), 'YYYY-MM'), to_char(pg_temp.ms(1), 'YYYY-MM'), to_char(pg_temp.ms(2), 'YYYY-MM')]
             from _t where k = 'k_admin'), 'rate_history: newest first, one rate per month (the manual 12 beats the auto 11 of the same month)');
select ok((select (v -> 'admin' -> 'rate_history' -> 0 ->> 'change_pct')::numeric = 20.0 and (v -> 'admin' -> 'rate_history' -> 1 ->> 'change_pct')::numeric = -9.1 and v -> 'admin' -> 'rate_history' -> 2 -> 'change_pct' = 'null'::jsonb
             from _t where k = 'k_admin'), 'rate_history: change_pct is +20.0 (10 to 12), -9.1 (11 to 10) and null for the oldest, one decimal');
select ok((select (select count(*) from jsonb_object_keys(e)) = 3 and e ?& array['month', 'php_per_kwh', 'change_pct'] from (select v -> 'admin' -> 'rate_history' -> 0 e from _t where k = 'k_admin') x), 'rate_history: three keys per row');
select ok((select (v -> 'admin' -> 'rate_history' -> 0 ->> 'php_per_kwh')::numeric = (v -> 'admin' -> 'rate' ->> 'php_per_kwh')::numeric from _t where k = 'k_admin'),
          'the rate precedence agrees: the newest history row is the rate kpi_tab_v1 already reports as in force');
select ok((select (v -> 'admin' ->> 'rate_year_avg')::numeric = (select round(avg(r.p), 2) from (values (2, 11.0), (1, 10.0), (0, 12.0)) r(n, p) where pg_temp.ms(r.n) >= date_trunc('year', public.manila_today())::date) from _t where k = 'k_admin'),
          'rate_year_avg: the mean of this calendar year''s monthly rates, 2 decimals');
select ok((select v -> 'admin' -> 'water_rate' = jsonb_build_object('min_php', 212, 'min_m3', 10, 'next_php', 23.05, 'next_upto', 20, 'source_url', 'https://gensanwater.gov.ph/water-rates/') from _t where k = 'k_admin'),
          'admin.water_rate: minimum 212 for 10 m3, next 23.05 up to 20, source url');
-- stays: counted readings that end a stay, newest first, 5 of 6 (the m-6 one is dropped); today's mid_stay reading and the misread end none
select ok((select jsonb_array_length(v -> 'admin' -> 'stays') = 5 and (select array_agg(e ->> 'guest_name' order by o) from jsonb_array_elements(v -> 'admin' -> 'stays') with ordinality t(e, o)) = array['Zzguest Ben', 'Zzguest Ana', 'Zzguest Cy', 'Zzguest Dee', 'Zzguest Eli']
             from _t where k = 'k_admin'), 'stays: the last 5 counted readings that end a stay, newest first (a mid_stay reading, a misread and the sixth stay are left out)');
select ok((select (s -> 0 ->> 'kwh')::numeric = 30 and (s -> 0 ->> 'm3')::numeric = 3 and (s -> 0 ->> 'cost_php')::numeric = 360 and (s -> 0 ->> 'to')::date = public.manila_today() and (s -> 0 ->> 'from')::date = pg_temp.ms(1)
             and (s -> 0 ->> 'nights')::int = public.manila_today() - pg_temp.ms(1) and s -> 0 -> 'id_photo_path' = 'null'::jsonb and s -> 0 -> 'id_face_box' = 'null'::jsonb and s -> 0 -> 'tier' = 'null'::jsonb
             from (select v -> 'admin' -> 'stays' s from _t where k = 'k_admin') x), 'stays[0] (Ben): 30 kWh at 12 = 360.00, from the previous counted reading, no ID photo for this guest');
select ok((select (s -> 1 ->> 'kwh')::numeric = 90 and (s -> 1 ->> 'cost_php')::numeric = 1080 and s -> 1 ->> 'id_photo_path' = 'zz127/photo-ana.jpg' and (s -> 1 -> 'id_face_box') = '{"x":0.1,"y":0.1,"w":0.3,"h":0.3,"src":"vision"}'::jsonb
             and (s -> 1 ->> 'nights')::int = pg_temp.ms(1) - pg_temp.ms(2) from (select v -> 'admin' -> 'stays' s from _t where k = 'k_admin') x), 'stays[1] (Ana): 90 kWh = 1080.00, her ID photo path and face box come with the stay');
select ok((select bool_and((select count(*) from jsonb_object_keys(e)) = 10 and e ?& array['from', 'to', 'nights', 'kwh', 'm3', 'cost_php', 'guest_name', 'tier', 'id_photo_path', 'id_face_box'])
             from (select jsonb_array_elements(v -> 'admin' -> 'stays') e from _t where k = 'k_admin') x)
          and (select not (v::text ~* 'phone|e-?mail|id_number|contact') from _t where k = 'k_admin'), 'stays: exactly the ten contract keys per row; no phone, e-mail or ID number anywhere in the payload');
select ok((select (s -> 2 ->> 'guest_name') = 'Zzguest Cy' and s -> 2 -> 'id_photo_path' = 'null'::jsonb from (select v -> 'admin' -> 'stays' s from _t where k = 'k_admin') x), 'stays: a calendar-only stay shows the calendar name and no photo');

-- stays on a property whose readings carry sessions (property b5, called as the owner of the function): a mid_stay session ends no stay, a turnover session does, with no guest known
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaned_at, nights_stayed, checkout_date, cleaning_type) values
  (pg_temp.id('e2'), 'zz127-sub-e2', 'Zz127 Cleaner', pg_temp.id('b5'), timestamptz '2020-03-03 10:00+08', 1, date '2020-03-03', 'mid_stay'),
  (pg_temp.id('e3'), 'zz127-sub-e3', 'Zz127 Cleaner', pg_temp.id('b5'), timestamptz '2020-03-09 10:00+08', 2, date '2020-03-09', 'turnover');
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('g1'), pg_temp.id('e2'), pg_temp.id('b5'), timestamptz '2020-03-03 10:00+08', 100, 120, 5, 20, 1, null),
  (pg_temp.id('g2'), pg_temp.id('e3'), pg_temp.id('b5'), timestamptz '2020-03-09 10:00+08', 120, 150, 6, 30, 2, null);
delete from public.utility_rates;
insert into _t select 'st5', public.kpi_admin_bills_v1(pg_temp.id('b5'), null);
select ok((select jsonb_array_length(v -> 'stays') = 1 and (v -> 'stays' -> 0 ->> 'to') = '2020-03-09' and (v -> 'stays' -> 0 ->> 'kwh')::numeric = 30 and (v -> 'stays' -> 0 ->> 'nights')::int = 6
             and v -> 'stays' -> 0 -> 'guest_name' = 'null'::jsonb and v -> 'stays' -> 0 -> 'cost_php' = 'null'::jsonb from _t where k = 'st5'),
          'stays: the turnover reading ends a stay (6 nights since the previous counted reading, no guest, no cost without a rate); the mid_stay reading does not');
select ok((select v -> 'rate_history' = '[]'::jsonb and v -> 'rate_year_avg' = 'null'::jsonb and v -> 'bills' -> 'electric' -> 'so_far_php' = 'null'::jsonb from _t where k = 'st5'),
          'no rate at all: rate_history is an empty list, rate_year_avg and the bill in pesos are null');
select is((select count(*)::int from public.app_settings where key = 'utility_billing'), 1, 'the suite leaves exactly one utility_billing row');

select * from finish();
rollback;
