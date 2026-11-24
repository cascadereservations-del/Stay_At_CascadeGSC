-- Session 127 (lane A, SQL): release s127_utility_bills_20261127. Contract: docs/s127/CONTRACT.md "Facts", "Lane A", Addendum 1 (per guest night) and Addendum 2 (fix round 1).
-- utility_bill_estimate_v1 (cycle boundaries, billed-month rate and its fallback, water tiers, flagged and chain-broken readings, use spread by days), utility_daily_use_v1 (THE per-day rule),
-- the settings fallback (a key of the wrong JSON type never raises), today_bills_v1 (refused as anon, a user with no staff profile, a cleaner of ANOTHER property and a disabled cleaner; allowed for a cleaner
-- and laundry) and kpi_tab_v1 (usage_months with guest nights and per-night figures, admin.bills / rate_history / rate_year_avg / water_rate / stays / rate.checked_at, no peso key in the non-admin payload).
-- Every expected value is hand-computed in the comment above its block. Synthetic fixtures only (uuids e1270000-..., properties ...b1 to ...b7, names "Zzguest ..."). The real rate table and the two
-- app_settings keys this suite touches are cleared INSIDE this transaction because a real backup holds real rows; everything rolls back. calendar_events.nights is generated and never inserted.
-- Refusals are tested by calling as the refused role. Nothing in this file can run without a Postgres that holds the Cascade schema: it is run by the rehearsal
-- (scripts/recovery/p6/migration-rehearsal-on-host.sh <backup> <release.json> <this file>).
begin;
select plan(102);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
do $sr$ begin if not (select rolbypassrls from pg_roles where rolname = 'service_role') then alter role service_role bypassrls; end if; end $sr$;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
-- s131: the production grants of the functions and the table this suite asserts on (a --no-acl restore has none of them; idempotent, rolled back with the suite)
revoke all on function public.utility_billing_default_v1(), public.utility_cfg_num_v1(jsonb,jsonb), public.utility_billing_cfg_v1(), public.utility_cycle_day_v1(date,integer), public.utility_cycle_v1(date,integer), public.utility_rate_by_month_v1(), public.utility_daily_use_v1(uuid,date,date), public.utility_water_php_v1(numeric,jsonb), public.utility_water_next_v1(numeric,jsonb), public.utility_bill_estimate_v1(uuid,date), public.kpi_usage_months_v1(uuid,date), public.kpi_admin_bills_v1(uuid,numeric), public.bill_step_v1(uuid,text,uuid,text,jsonb), public.bill_due_open_v1(uuid,date,text), public.bill_daily_v1(date,uuid), public.bill_reply_v1(jsonb,uuid), public.bill_entry_v1(public.utility_bills,jsonb,boolean,uuid), public.bill_pay_info_v1(jsonb,text,text), public.bill_can_v1(uuid), public.bill_actor_name_v1(uuid), public.bill_json_v1(public.utility_bills), public.bill_schedule_cfg_v1(), public.bill_cfg_one_v1(jsonb,text,jsonb,integer), public.bill_cfg_day_v1(jsonb,integer), public.bill_cfg_text_v1(jsonb,text) from public, anon, authenticated, service_role;
revoke all on function public.today_bills_v1(uuid), public.kpi_tab_v1(uuid,date), public.bill_pay_open_v1(uuid), public.bill_pay_settle_v1(uuid,jsonb), public.bill_pay_cancel_v1(uuid), public.bill_pay_skip_v1(uuid), public.bill_proof_v1(uuid), public.bill_schedule_get_v1(uuid,text), public.bill_schedule_set_v1(uuid,text,jsonb), public.staff_pay_admin_settle_v1(uuid,jsonb) from public, anon, service_role;
grant execute on function public.today_bills_v1(uuid), public.kpi_tab_v1(uuid,date), public.bill_pay_open_v1(uuid), public.bill_pay_settle_v1(uuid,jsonb), public.bill_pay_cancel_v1(uuid), public.bill_pay_skip_v1(uuid), public.bill_proof_v1(uuid), public.bill_schedule_get_v1(uuid,text), public.bill_schedule_set_v1(uuid,text,jsonb), public.staff_pay_admin_settle_v1(uuid,jsonb) to authenticated;
revoke all on public.utility_bills from public, anon, authenticated;
grant select, insert, update on public.utility_bills to service_role;

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
-- store p as the utility_billing setting and return what the functions read from it
create function pg_temp.cfg_of(p jsonb) returns jsonb language plpgsql as $f$
begin
  update public.app_settings set value = p where key = 'utility_billing';
  return public.utility_billing_cfg_v1();
end $f$;
-- first day of the Manila month n months back (negative n = ahead); the last day of the month n months back; 09:00 Manila on that last day
-- s131: the default utility_billing setting with electric.open_from and water.open_from set to p (the 2020 fixtures start their cycle there; production's open_from is 2026-10-21)
create function pg_temp.ub_open(p date) returns jsonb language sql as $$
  select jsonb_set(jsonb_set(public.utility_billing_default_v1(), '{electric,open_from}', to_jsonb(p::text)), '{water,open_from}', to_jsonb(p::text))
$$;
create function pg_temp.set_ub(p jsonb) returns void language sql as $$
  update public.app_settings set value = p where key = 'utility_billing'
$$;
create function pg_temp.ms(n integer) returns date language sql stable as $$ select (date_trunc('month', public.manila_today())::date - n * interval '1 month')::date $$;
create function pg_temp.me(n integer) returns date language sql stable as $$ select (pg_temp.ms(n - 1) - 1) $$;
create function pg_temp.mes(n integer) returns timestamptz language sql stable as $$ select (pg_temp.me(n) + time '09:00') at time zone 'Asia/Manila' $$;
create temp table _t(k text primary key, v jsonb);
grant all on _t to public;

-- fixtures -------------------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values
  (pg_temp.id('b1'), 'Zz S127 cycles', true), (pg_temp.id('b2'), 'Zz S127 water', true), (pg_temp.id('b3'), 'Zz S127 kpi', true), (pg_temp.id('b4'), 'Zz S127 other', true),
  (pg_temp.id('b5'), 'Zz S127 stays', true), (pg_temp.id('b6'), 'Zz S127 prorate', true), (pg_temp.id('b7'), 'Zz S127 today', true), (pg_temp.id('b8'), 'Zz S127 covered days', true);
insert into auth.users(id, email) values
  (pg_temp.id('a1'), 'zz127-cleaner@example.com'), (pg_temp.id('a2'), 'zz127-admin@example.com'), (pg_temp.id('a3'), 'zz127-laundry@example.com'),
  (pg_temp.id('a4'), 'zz127-nostaff@example.com'), (pg_temp.id('a5'), 'zz127-other@example.com'), (pg_temp.id('a6'), 'zz127-disabled@example.com');
insert into public.staff_access_profiles(user_id, role, disabled_at) values
  (pg_temp.id('a1'), 'cleaner', null), (pg_temp.id('a2'), 'admin', null), (pg_temp.id('a3'), 'laundry', null), (pg_temp.id('a5'), 'cleaner', null), (pg_temp.id('a6'), 'cleaner', now());
insert into public.staff_property_access(user_id, property_id) values
  (pg_temp.id('a1'), pg_temp.id('b3')), (pg_temp.id('a2'), pg_temp.id('b3')), (pg_temp.id('a3'), pg_temp.id('b3')), (pg_temp.id('a5'), pg_temp.id('b4')),
  (pg_temp.id('a1'), pg_temp.id('b7')), (pg_temp.id('a3'), pg_temp.id('b7')), (pg_temp.id('a6'), pg_temp.id('b7'));

delete from public.utility_rates;
delete from public.app_settings where key = 'power_watch_rate_day';

-- shape, grants, settings ---------------------------------------------------------------------------------------------------------------------
select ok(has_function_privilege('authenticated', 'public.today_bills_v1(uuid)', 'execute') and not has_function_privilege('anon', 'public.today_bills_v1(uuid)', 'execute')
          and not has_function_privilege('service_role', 'public.today_bills_v1(uuid)', 'execute'), 'today_bills_v1 runs for signed-in users only');
select ok((select bool_and(not has_function_privilege('anon', f, 'execute') and not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('service_role', f, 'execute'))
             from unnest(array['public.utility_billing_default_v1()', 'public.utility_cfg_num_v1(jsonb,jsonb)', 'public.utility_billing_cfg_v1()', 'public.utility_cycle_day_v1(date,integer)',
                               'public.utility_cycle_v1(date,integer)', 'public.utility_rate_by_month_v1()', 'public.utility_daily_use_v1(uuid,date,date)',
                               'public.utility_water_php_v1(numeric,jsonb)', 'public.utility_water_next_v1(numeric,jsonb)', 'public.utility_bill_estimate_v1(uuid,date)',
                               'public.kpi_usage_months_v1(uuid,date)', 'public.kpi_admin_bills_v1(uuid,numeric)']) f),
          'the twelve internal functions run for nobody (not anon, authenticated, service_role)');
select ok((select count(*) = 14 and bool_and(p.proconfig = array['search_path=""']) from pg_proc p
            where p.oid in ('public.utility_billing_default_v1()'::regprocedure, 'public.utility_cfg_num_v1(jsonb,jsonb)'::regprocedure, 'public.utility_billing_cfg_v1()'::regprocedure,
                            'public.utility_cycle_day_v1(date,integer)'::regprocedure, 'public.utility_cycle_v1(date,integer)'::regprocedure, 'public.utility_rate_by_month_v1()'::regprocedure,
                            'public.utility_daily_use_v1(uuid,date,date)'::regprocedure, 'public.utility_water_php_v1(numeric,jsonb)'::regprocedure, 'public.utility_water_next_v1(numeric,jsonb)'::regprocedure,
                            'public.utility_bill_estimate_v1(uuid,date)'::regprocedure, 'public.kpi_usage_months_v1(uuid,date)'::regprocedure, 'public.kpi_admin_bills_v1(uuid,numeric)'::regprocedure,
                            'public.today_bills_v1(uuid)'::regprocedure, 'public.kpi_tab_v1(uuid,date)'::regprocedure)),
          'all fourteen new or replaced functions (twelve internal, today_bills_v1, kpi_tab_v1) keep search_path pinned to empty');
select ok((select bool_and(p.prosecdef) from pg_proc p where p.oid in ('public.utility_bill_estimate_v1(uuid,date)'::regprocedure, 'public.today_bills_v1(uuid)'::regprocedure, 'public.kpi_tab_v1(uuid,date)'::regprocedure))
          and has_function_privilege('authenticated', 'public.kpi_tab_v1(uuid,date)', 'execute') and not has_function_privilege('anon', 'public.kpi_tab_v1(uuid,date)', 'execute')
          and not has_function_privilege('service_role', 'public.kpi_tab_v1(uuid,date)', 'execute'), 'kpi_tab_v1 is still security definer, for signed-in users only');
select ok(md5(replace((select p.prosrc from pg_proc p where p.oid = 'public.kpi_tab_v1(uuid,date)'::regprocedure), chr(13), '')) in ('80efd89e916bcd6107c681baf86f143f', '7c6d5a22d09ad96916804630f31df602'),
          'kpi_tab_v1 is exactly the body this release pins (the s115 body 229c75a3... plus the inserted statements only)');

-- settings: the migration insert, the key-by-key fallback, and a setting of the wrong type never raises ------------------------------------------------------------
select ok((select value = public.utility_billing_default_v1() from public.app_settings where key = 'utility_billing') and (select count(*) from public.app_settings where key = 'utility_billing') = 1,
          'the migration left exactly one utility_billing row and it holds the contract defaults');
delete from public.app_settings where key = 'utility_billing';
insert into public.app_settings(key, value) select 'utility_billing', public.utility_billing_default_v1() where not exists (select 1 from public.app_settings a where a.key = 'utility_billing');
update public.app_settings set value = '{"electric":{"cycle_day":1}}'::jsonb where key = 'utility_billing';
select ok(pg_temp.cfg_of('{"electric":{"fixed_php":7.5}}'::jsonb) = jsonb_set(public.utility_billing_default_v1(), '{electric,fixed_php}', '7.5'::jsonb),
          'a stored partial setting wins key by key and every other key falls back to its default');
delete from public.app_settings where key = 'utility_billing';
select ok(public.utility_billing_cfg_v1() = public.utility_billing_default_v1(), 'no setting row: every function falls back to the defaults');
select ok(public.utility_billing_default_v1() = '{"electric":{"cycle_day":21,"fixed_php":5.60,"open_from":"2026-10-21"},"water":{"cycle_day":21,"open_from":"2026-10-21","min_php":212,"min_m3":10,"tiers":[{"upto":20,"php":23.05},{"upto":30,"php":26.65},{"upto":40,"php":30.50},{"upto":null,"php":34.50}],"source_url":"https://gensanwater.gov.ph/water-rates/"}}'::jsonb,
          'the defaults are exactly the contract values plus the s131 open_from 2026-10-21 of electric and water');
insert into public.app_settings(key, value) values ('utility_billing', public.utility_billing_default_v1());
select ok(pg_temp.cfg_of('{"electric":"x","water":{"min_php":"abc","min_m3":-1,"cycle_day":[1],"tiers":"none","source_url":5}}'::jsonb) = public.utility_billing_default_v1(),
          'settings of the wrong JSON type (a string for an object, text or a negative for a number, an array for a day, a string for the tiers, a number for the url) fall back key by key and never raise');
select ok(pg_temp.cfg_of('"just a string"'::jsonb) = public.utility_billing_default_v1() and pg_temp.cfg_of('[1,2]'::jsonb) = public.utility_billing_default_v1(),
          'a setting row that is not an object at all falls back to the defaults');
select ok(pg_temp.cfg_of('{"water":{"tiers":[{"upto":"x","php":1}]}}'::jsonb) = public.utility_billing_default_v1() and pg_temp.cfg_of('{"water":{"tiers":[]}}'::jsonb) = public.utility_billing_default_v1()
          and pg_temp.cfg_of('{"water":{"tiers":[1,2]}}'::jsonb) = public.utility_billing_default_v1() and pg_temp.cfg_of('{"water":{"tiers":[{"upto":20,"php":"9"}]}}'::jsonb) = public.utility_billing_default_v1(),
          'a tiers list that is empty, not objects, or has a non-number php or upto falls back to the default tiers');
select ok(pg_temp.cfg_of('{"electric":{"cycle_day":45,"fixed_php":0},"water":{"cycle_day":21.9,"min_php":300,"tiers":[{"upto":null,"php":40}]}}'::jsonb)
          = '{"electric":{"cycle_day":31,"fixed_php":0,"open_from":"2026-10-21"},"water":{"cycle_day":21,"open_from":"2026-10-21","min_php":300,"min_m3":10,"tiers":[{"upto":null,"php":40}],"source_url":"https://gensanwater.gov.ph/water-rates/"}}'::jsonb,
          'valid custom values win (a cycle day is cut to a whole number and held to 1..31; zero is a valid fixed charge)');
update public.app_settings set value = public.utility_billing_default_v1() where key = 'utility_billing';

-- water tariff, hand-computed with the default tiers: 212 covers 0-10; 11-20 at 23.05; 21-30 at 26.65; 31-40 at 30.50; 41+ at 34.50 -------------------------------
select ok(public.utility_water_php_v1(0, public.utility_billing_cfg_v1()) = 212 and public.utility_water_php_v1(10, public.utility_billing_cfg_v1()) = 212, 'water: 0 and exactly 10 m3 cost the 212 minimum');
select ok(public.utility_water_php_v1(10.01, public.utility_billing_cfg_v1()) = 212.23, 'water: 10.01 m3 = 212 + 0.01 x 23.05 = 212.23');
select ok(public.utility_water_php_v1(20, public.utility_billing_cfg_v1()) = 442.50, 'water: 20 m3 = 212 + 10 x 23.05 = 442.50');
select ok(public.utility_water_php_v1(20.5, public.utility_billing_cfg_v1()) = 455.83, 'water: 20.5 m3 = 212 + 230.50 + 0.5 x 26.65 = 455.825 -> 455.83');
select ok(public.utility_water_php_v1(30, public.utility_billing_cfg_v1()) = 709.00, 'water: 30 m3 = 212 + 230.50 + 10 x 26.65 = 709.00');
select ok(public.utility_water_php_v1(40, public.utility_billing_cfg_v1()) = 1014.00, 'water: 40 m3 = 212 + 230.50 + 266.50 + 305.00 = 1014.00');
select ok(public.utility_water_php_v1(45, public.utility_billing_cfg_v1()) = 1186.50, 'water: 45 m3 = 1014.00 + 5 x 34.50 = 1186.50');
select ok((public.utility_water_next_v1(0, public.utility_billing_cfg_v1()) = '{"php":23.05,"upto":20}'::jsonb) and (public.utility_water_next_v1(20, public.utility_billing_cfg_v1()) = '{"php":26.65,"upto":30}'::jsonb)
          and (public.utility_water_next_v1(45, public.utility_billing_cfg_v1()) -> 'php') = '34.50'::jsonb and (public.utility_water_next_v1(45, public.utility_billing_cfg_v1()) -> 'upto') = 'null'::jsonb,
          'the next tier: 23.05 up to 20 inside the minimum, 26.65 up to 30 at 20 m3, 34.50 with no ceiling at 45 m3');

-- cycles (from, to]: a reading checked out ON the 21st closes the cycle that ends that day; the cycle day is clamped per month to that month's last day -------------------
select ok(public.utility_cycle_v1(date '2020-11-20', 21) = array[date '2020-10-21', date '2020-11-21'] and public.utility_cycle_v1(date '2020-11-21', 21) = array[date '2020-10-21', date '2020-11-21'],
          'cycle: the 20th and the 21st belong to the cycle that ends 21 Nov');
select ok(public.utility_cycle_v1(date '2020-11-22', 21) = array[date '2020-11-21', date '2020-12-21'], 'cycle: the 22nd starts the next cycle');
select ok(public.utility_cycle_v1(date '2020-12-25', 21) = array[date '2020-12-21', date '2021-01-21'], 'cycle: December rolls into January');
-- day 31: February 2021 has 28 days, March 31, April 30; February 2020 has 29 days
select ok(public.utility_cycle_v1(date '2021-03-05', 31) = array[date '2021-02-28', date '2021-03-31'] and public.utility_cycle_v1(date '2021-04-01', 31) = array[date '2021-03-31', date '2021-04-30']
          and public.utility_cycle_v1(date '2020-02-10', 31) = array[date '2020-01-31', date '2020-02-29'] and public.utility_cycle_v1(date '2021-02-28', 31) = array[date '2021-01-31', date '2021-02-28'],
          'cycle: day 31 is clamped per month (28 Feb 2021, 31 Mar, 30 Apr, 29 Feb 2020), each end of the cycle by its own month');

-- rates: one per month, manual before auto, then newest; no client reads them ----------------------------------------------------------------------------
insert into public.utility_rates(provider, php_per_kwh, effective_from, source) values
  ('socoteco2', 8, date '2020-09-01', 'auto'), ('socoteco2', 10, date '2020-10-01', 'manual'),
  ('socoteco2', 11, date '2020-11-01', 'auto'), ('socoteco2', 12, date '2020-11-01', 'manual'), ('socoteco2', 13, date '2020-11-10', 'auto');
select ok((select array_agg(r.php_per_kwh order by r.rate_month) = array[8, 10, 12]::numeric[] and count(*) = 3 from public.utility_rate_by_month_v1() r),
          'rates by month: September 8 (auto), October 10, November 12 (the manual 12 beats the auto 11 and the newer auto 13)');

-- readings of the cycle scenarios (property b1). Counted: c1 21 Oct 10 kWh 1.0 m3 (first reading), c2 25 Oct 20/2.0, c3 5 Nov 55/5.5, c4 20 Nov 30/4.5, c5 24 Nov 40/4.0.
-- Ignored by the s115 helper: cf misread 400 kWh / 40 m3, c7 re_entry 300, c6 first_reading 300.
-- Per day (the delta spread over the days after the previous counted reading up to its own day): c1 has no previous reading so it lands on 21 Oct (10 kWh, 1.0 m3);
-- c2 22-25 Oct = 4 days = 5 kWh and 0.5 m3 a day; c3 26 Oct-5 Nov = 6 + 5 = 11 days = 5 kWh and 0.5 m3 a day; c4 6-20 Nov = 15 days = 2 kWh and 0.3 m3 a day; c5 21-24 Nov = 4 days = 10 kWh and 1.0 m3 a day.
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('c1'), null, pg_temp.id('b1'), timestamptz '2020-10-21 09:00+08', 1000, 1010, 50, 10, 1.0, null),
  (pg_temp.id('c2'), null, pg_temp.id('b1'), timestamptz '2020-10-25 09:00+08', 1010, 1030, 51, 20, 2.0, null),
  (pg_temp.id('c3'), null, pg_temp.id('b1'), timestamptz '2020-11-05 09:00+08', 1030, 1085, 53, 55, 5.5, null),
  (pg_temp.id('cf'), null, pg_temp.id('b1'), timestamptz '2020-11-08 09:00+08', 1085, 1485, 58, 400, 40, 'misread'),
  (pg_temp.id('c7'), null, pg_temp.id('b1'), timestamptz '2020-11-12 09:00+08', 1085, 1385, 58, 300, 30, 're_entry'),
  (pg_temp.id('c6'), null, pg_temp.id('b1'), timestamptz '2020-11-14 09:00+08', 1085, 1385, 58, 300, 30, 'first_reading'),
  (pg_temp.id('c4'), null, pg_temp.id('b1'), timestamptz '2020-11-20 09:00+08', 1085, 1115, 58, 30, 4.5, null),
  (pg_temp.id('c5'), null, pg_temp.id('b1'), timestamptz '2020-11-24 09:00+08', 1115, 1155, 63, 40, 4.0, null);
-- s131: the cycle follows the bill. No bill of b1 is paid, so the cycle of these scenarios starts at open_from = 2020-10-21 (the 2020 fixtures predate the production open_from 2026-10-21).
select pg_temp.set_ub(pg_temp.ub_open(date '2020-10-21'));
insert into _t select 'e1120', public.utility_bill_estimate_v1(pg_temp.id('b1'), date '2020-11-20');
insert into _t select 'e1121', public.utility_bill_estimate_v1(pg_temp.id('b1'), date '2020-11-21');
insert into _t select 'e1122', public.utility_bill_estimate_v1(pg_temp.id('b1'), date '2020-11-22');
-- the cycle ending 21 Oct needs the cycle to start 21 Sep, and the 2019 scenario one that starts 21 Apr 2019 (billed in May 2019, which no rate precedes)
select pg_temp.set_ub(pg_temp.ub_open(date '2020-09-21'));
insert into _t select 'e1015', public.utility_bill_estimate_v1(pg_temp.id('b1'), date '2020-10-21');
select pg_temp.set_ub(pg_temp.ub_open(date '2019-04-21'));
insert into _t select 'e1905', public.utility_bill_estimate_v1(pg_temp.id('b1'), date '2019-05-15');
select pg_temp.set_ub(pg_temp.ub_open(date '2020-10-21'));

-- the per-day rule itself: no day holds a reading's whole delta; 21 Oct..24 Nov is 35 days, 10 + 20 + 55 + 30 + 40 = 155 kWh and 1.0 + 2.0 + 5.5 + 4.5 + 4.0 = 17.0 m3 in total
select ok((select count(*) = 35 and sum(kwh) = 155 and sum(m3) = 17.0 from public.utility_daily_use_v1(pg_temp.id('b1'), date '2020-10-21', date '2020-11-24')), 'per day: 35 days, 155 kWh and 17.0 m3 in all (flagged readings ignored)');
select ok((select (select kwh from public.utility_daily_use_v1(pg_temp.id('b1'), date '2020-10-21', date '2020-10-21')) = 10
             and (select kwh from public.utility_daily_use_v1(pg_temp.id('b1'), date '2020-10-25', date '2020-10-25')) = 5
             and (select kwh from public.utility_daily_use_v1(pg_temp.id('b1'), date '2020-11-05', date '2020-11-05')) = 5
             and (select kwh from public.utility_daily_use_v1(pg_temp.id('b1'), date '2020-11-20', date '2020-11-20')) = 2
             and (select kwh from public.utility_daily_use_v1(pg_temp.id('b1'), date '2020-11-24', date '2020-11-24')) = 10
             and (select m3 from public.utility_daily_use_v1(pg_temp.id('b1'), date '2020-11-20', date '2020-11-20')) = 0.3),
          'per day: the 25 Oct reading (20 kWh over 4 days) puts 5 kWh on 25 Oct, not 20; the first reading lands on its own day; 20 Nov is 2 kWh and 0.3 m3');

-- s131 (replaces the s127 cycle cut at the 21st): the cycle starts at open_from (21 Oct) and counts every counted day after it up to p_on, with no cut at the 21st. c1 lands on 21 Oct (the start itself), so it is not in it.
-- The 20th: days 22 Oct..20 Nov = c2 4 x 5 = 20, c3 11 x 5 = 55, c4 15 x 2 = 30 = 105 kWh (c5's days begin on the 21st); covered days 21 Oct -> 20 Nov = 30, days in the cycle 21 Oct -> 21 Nov = 31;
-- billed month November = rate 12 (the manual 12); so far 105 x 12 + 5.60 = 1265.60; per day 105 / 30 = 3.5 kWh x 12 = 42.00; forecast 3.5 x 31 = 108.5 kWh = 108.5 x 12 + 5.60 = 1307.60
select ok((select v -> 'electric' ->> 'cycle_from' = '2020-10-21' and v -> 'electric' ->> 'cycle_to' = '2020-11-21' and (v -> 'electric' ->> 'days')::int = 30 and (v -> 'electric' ->> 'days_in_cycle')::int = 31
             and v -> 'electric' ->> 'billed_month' = '2020-11' and (v -> 'electric' ->> 'overdue')::boolean is false from _t where k = 'e1120'), 'the 20th: cycle from 21 Oct (open_from) to the expected reading day 21 Nov, 30 days covered of 31, billed in November, not overdue');
select ok((select (v -> 'electric' ->> 'kwh')::numeric = 105 from _t where k = 'e1120'), 'the 20th: 105 kWh = 20 + 55 + 30, spread by days (a misread, a re_entry and a first_reading row are not counted)');
select ok((select (v -> 'electric' ->> 'rate')::numeric = 12 and (v -> 'electric' ->> 'fixed_php')::numeric = 5.6 and (v -> 'electric' ->> 'so_far_php')::numeric = 1265.60 from _t where k = 'e1120'),
          'the 20th: rate 12 (manual beats auto), so far 105 x 12 + 5.60 = 1265.60');
select ok((select (v -> 'electric' ->> 'forecast_kwh')::numeric = 108.5 and (v -> 'electric' ->> 'forecast_php')::numeric = 1307.60 and (v -> 'electric' ->> 'per_day_kwh')::numeric = 3.5
                  and (v -> 'electric' ->> 'per_day_php')::numeric = 42 from _t where k = 'e1120'), 'the 20th: forecast 108.5 kWh = 1307.60, per day 3.5 kWh = 42.00');
select ok((select (v -> 'electric' ->> 'last_reading_at')::timestamptz = timestamptz '2020-11-20 09:00+08' from _t where k = 'e1120'), 'last_reading_at is the latest counted reading inside the cycle (c4, 20 Nov)');
-- the 21st (the expected reading day itself) takes c5's 21 Nov day: 20 + 55 + 30 + 10 = 115 kWh over 31 days; so far 115 x 12 + 5.60 = 1385.60; per day 115 / 31 = 3.7097 -> 3.71 kWh x 12 = 44.516 -> 44.52; forecast 3.7097 x 31 = 115 kWh = 1385.60
select ok((select v -> 'electric' ->> 'cycle_to' = '2020-11-21' and (v -> 'electric' ->> 'days')::int = 31 and (v -> 'electric' ->> 'days_in_cycle')::int = 31 and (v -> 'electric' ->> 'kwh')::numeric = 115
             and (v -> 'electric' ->> 'so_far_php')::numeric = 1385.60 and (v -> 'electric' ->> 'forecast_kwh')::numeric = 115 and (v -> 'electric' ->> 'forecast_php')::numeric = 1385.60
             and (v -> 'electric' ->> 'per_day_kwh')::numeric = 3.71 and (v -> 'electric' ->> 'per_day_php')::numeric = 44.52 and (v -> 'electric' ->> 'overdue')::boolean is false from _t where k = 'e1121'),
          'the 21st: the expected reading day takes c5''s 21 Nov day (115 kWh over 31 days = 1385.60 so far and forecast), not overdue');

-- the 22nd: the expected reading day 21 Nov has passed and the same bill is still open (no cut at the 21st): it counts to p_on, overdue, still billed in November (rate 12).
-- c5 gives 21 and 22 Nov (2 x 10): 20 + 55 + 30 + 20 = 125 kWh; covered days 21 Oct -> 22 Nov = 32 and the cycle runs to p_on (32 days); so far 125 x 12 + 5.60 = 1505.60; per day 125 / 32 = 3.90625 -> 3.91 kWh x 12 = 46.875 -> 46.88;
-- forecast 3.90625 x 32 = 125 kWh = 1505.60
select ok((select v -> 'electric' ->> 'cycle_from' = '2020-10-21' and v -> 'electric' ->> 'cycle_to' = '2020-11-21' and (v -> 'electric' ->> 'days')::int = 32 and (v -> 'electric' ->> 'days_in_cycle')::int = 32
             and (v -> 'electric' ->> 'kwh')::numeric = 125 and v -> 'electric' ->> 'billed_month' = '2020-11' and (v -> 'electric' ->> 'overdue')::boolean from _t where k = 'e1122'),
          'the 22nd: still the same open bill, overdue, billed in November: 125 kWh over 32 days (c5 gives 2 of its 4 days)');
select ok((select (v -> 'electric' ->> 'rate')::numeric = 12 and (v -> 'electric' ->> 'so_far_php')::numeric = 1505.60 from _t where k = 'e1122'), 'the 22nd: November rate 12: 125 x 12 + 5.60 = 1505.60 so far');
select ok((select (v -> 'electric' ->> 'forecast_kwh')::numeric = 125 and (v -> 'electric' ->> 'forecast_php')::numeric = 1505.60 and (v -> 'electric' ->> 'per_day_kwh')::numeric = 3.91
                  and (v -> 'electric' ->> 'per_day_php')::numeric = 46.88 from _t where k = 'e1122'), 'the 22nd: forecast 125 kWh = 1505.60, per day 3.91 kWh = 46.88');
-- c1 alone in a cycle that starts 21 Sep and ends 21 Oct (p_on 21 Oct; it has no previous reading, so it lands on 21 Oct): 10 kWh, billed in October at the October rate 10 -> 10 x 10 + 5.60 = 105.60; covered days 21 Sep -> 21 Oct = 30
select ok((select (v -> 'electric' ->> 'kwh')::numeric = 10 and (v -> 'electric' ->> 'rate')::numeric = 10 and (v -> 'electric' ->> 'so_far_php')::numeric = 105.60 and (v -> 'electric' ->> 'days')::int = 30
             and v -> 'electric' ->> 'billed_month' = '2020-10' from _t where k = 'e1015'),
          'a cycle that ends 21 Oct is billed at the October rate 10 (the month the cycle ends in, not the rate of the day it is read): 10 x 10 + 5.60 = 105.60');

-- no rate at all for the billed month or before it: null, never a guess; no reading: zeros and no forecast
select ok((select v -> 'electric' -> 'rate' = 'null'::jsonb and v -> 'electric' -> 'so_far_php' = 'null'::jsonb and v -> 'electric' -> 'forecast_php' = 'null'::jsonb and v -> 'electric' -> 'per_day_php' = 'null'::jsonb
             and (v -> 'electric' ->> 'kwh')::numeric = 0 from _t where k = 'e1905'), 'no rate on or before the billed month: rate, so_far_php, forecast_php and per_day_php are null');
select ok((select (v -> 'electric' ->> 'days')::int = 0 and v -> 'electric' -> 'forecast_kwh' = 'null'::jsonb and v -> 'electric' -> 'per_day_kwh' = 'null'::jsonb and v -> 'electric' -> 'last_reading_at' = 'null'::jsonb
             and v -> 'water' -> 'forecast_m3' = 'null'::jsonb and v -> 'water' -> 'forecast_php' = 'null'::jsonb and v -> 'water' -> 'per_day_m3' = 'null'::jsonb from _t where k = 'e1905'),
          'no counted reading in the cycle: days 0, forecasts and per-day figures null');
select ok((select (v -> 'water' ->> 'so_far_php')::numeric = 212 and (v -> 'water' ->> 'm3')::numeric = 0 from _t where k = 'e1905'), 'no water used: the bill is the 212 minimum');

-- water of the 20th (cycle from 21 Oct): c2 4 x 0.5 = 2.0, c3 11 x 0.5 = 5.5, c4 15 x 0.3 = 4.5 = 12.0 m3 (the misread 40 m3 is ignored) = 212 + 2 x 23.05 = 258.10; per day 12 / 30 = 0.4;
-- forecast 0.4 x 31 = 12.4 m3 = 212 + 2.4 x 23.05 = 267.32; the next tier is 23.05 up to 20
select ok((select (v -> 'water' ->> 'm3')::numeric = 12 and (v -> 'water' ->> 'so_far_php')::numeric = 258.10 and (v -> 'water' ->> 'days')::int = 30 and v -> 'water' ->> 'cycle_from' = '2020-10-21'
             and (v -> 'water' ->> 'forecast_m3')::numeric = 12.4 and (v -> 'water' ->> 'forecast_php')::numeric = 267.32 and (v -> 'water' ->> 'per_day_m3')::numeric = 0.4 from _t where k = 'e1120'),
          'water, the 20th: 12 m3 = 258.10, forecast 12.4 m3 = 267.32 (a flagged 40 m3 reading is ignored)');
select ok((select (v -> 'water' ->> 'min_php')::numeric = 212 and (v -> 'water' ->> 'min_m3')::numeric = 10 and (v -> 'water' ->> 'next_php')::numeric = 23.05 and (v -> 'water' ->> 'next_upto')::numeric = 20 from _t where k = 'e1120'),
          'water: minimum 212 for 10 m3, next 23.05 up to 20');
-- the 22nd (the same open bill, overdue): c5 gives 2 x 1.0 = 2.0 m3 more: 14.0 m3 in 32 days = 212 + 4 x 23.05 = 304.20; per day 14 / 32 = 0.4375 -> 0.44; forecast 0.4375 x 32 = 14 m3 = 304.20
select ok((select (v -> 'water' ->> 'm3')::numeric = 14 and (v -> 'water' ->> 'days')::int = 32 and (v -> 'water' ->> 'forecast_m3')::numeric = 14 and (v -> 'water' ->> 'forecast_php')::numeric = 304.20
             and (v -> 'water' ->> 'so_far_php')::numeric = 304.20 and (v -> 'water' ->> 'per_day_m3')::numeric = 0.44 and (v -> 'water' ->> 'overdue')::boolean from _t where k = 'e1122'),
          'water, the 22nd: the same open bill, overdue: 14.0 m3 in 32 days = 304.20');

-- bad settings never raise and the bill is the one the settings they fall back to give (open_from stays valid so the 2020 cycle is the same)
select pg_temp.set_ub('{"electric":{"cycle_day":"x","fixed_php":"abc","open_from":"2020-10-21"},"water":{"min_php":"abc","cycle_day":[1],"tiers":"none","open_from":"2020-10-21"}}'::jsonb);
insert into _t select 'e1120bad', public.utility_bill_estimate_v1(pg_temp.id('b1'), date '2020-11-20');
select pg_temp.set_ub(pg_temp.ub_open(date '2020-10-21'));
select ok((select a.v = b.v from _t a, _t b where a.k = 'e1120bad' and b.k = 'e1120'), 'a utility_billing setting of the wrong type does not raise and gives the same bill as the defaults');

-- one reading of 45 m3 (first reading of its chain, property b2, lands on its own day): s131 cycle from open_from 21 May (billed in June), days 21 May -> 10 Jun = 20 covered of 31, no rate for June 2020 yet.
-- so far 1186.50 (45 m3); forecast 45 / 20 x 31 = 69.75 m3 = 212 + 230.50 + 266.50 + 305.00 + 29.75 x 34.50 = 2040.375 -> 2040.38; per day 2.25; next 34.50 with no ceiling
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('d1'), null, pg_temp.id('b2'), timestamptz '2020-06-10 09:00+08', 100, 110, 5, 10, 45, null);
select pg_temp.set_ub(pg_temp.ub_open(date '2020-05-21'));
insert into _t select 'w45', public.utility_bill_estimate_v1(pg_temp.id('b2'), date '2020-06-15');
select pg_temp.set_ub(pg_temp.ub_open(date '2020-10-21'));
select ok((select (v -> 'water' ->> 'm3')::numeric = 45 and (v -> 'water' ->> 'days')::int = 20 and (v -> 'water' ->> 'so_far_php')::numeric = 1186.50 from _t where k = 'w45'), 'water: 45 m3 so far = 1186.50 over 20 days');
select ok((select (v -> 'water' ->> 'forecast_m3')::numeric = 69.75 and (v -> 'water' ->> 'forecast_php')::numeric = 2040.38 and (v -> 'water' ->> 'per_day_m3')::numeric = 2.25 from _t where k = 'w45'),
          'water: forecast 69.75 m3 = 2040.38, per day 2.25');
select ok((select (v -> 'water' ->> 'next_php')::numeric = 34.50 and v -> 'water' -> 'next_upto' = 'null'::jsonb and v -> 'electric' -> 'rate' = 'null'::jsonb from _t where k = 'w45'),
          'water: past 40 m3 the next tier is 34.50 with no ceiling; electricity has no June 2020 rate (null)');
-- no guest nights: the single June reading lands on 10 Jun (10 kWh, 45 m3), the last covered day, so 10 days are covered (not the 15 elapsed); 30 days in June: forecast 10 / 10 x 30 = 30.00 kWh and 45 / 10 x 30 = 135.00 m3; zero guest nights = no per-night figure
insert into _t select 'u_b2', public.kpi_usage_months_v1(pg_temp.id('b2'), date '2020-06-15');
select ok((select (m -> 5 ->> 'kwh_so_far')::numeric = 10 and (m -> 5 ->> 'm3_so_far')::numeric = 45 and (m -> 5 ->> 'kwh')::numeric = 30 and (m -> 5 ->> 'm3')::numeric = 135 and (m -> 5 ->> 'guest_nights')::int = 0
             and m -> 5 -> 'kwh_per_night' = 'null'::jsonb and m -> 5 -> 'm3_per_night' = 'null'::jsonb and m -> 5 -> 'kwh_night_change_pct' = 'null'::jsonb and m -> 5 -> 'm3_night_change_pct' = 'null'::jsonb
             from (select v m from _t where k = 'u_b2') x), 'zero guest nights: guest_nights 0 and the per-night figures and their changes are null although the month has use');

-- PRORATING (property b6, fixed 2020 dates), the contract examples. Counted readings: h1 15 Oct 10 kWh / 1.0 m3 (first: its own day); h2 25 Oct 100 / 10.0; h3 28 Oct 30 / 6.0; h4 3 Nov 60 / 6.0.
-- Chain-broken: 15 (5 Nov), electric_prev 1300 where the chain ends at 1200 (a gap), 50 kWh / 5.0 m3: left out of every figure. Per day: h2 = 16-25 Oct = 10 days = 10 kWh and 1.0 m3 a day;
-- h3 = 26-28 Oct = 3 days = 10 kWh and 2.0 m3 a day; h4 = 29 Oct-3 Nov = 6 days = 10 kWh and 1.0 m3 a day.
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('11'), null, pg_temp.id('b6'), timestamptz '2020-10-15 09:00+08', 1000, 1010, 5, 10, 1.0, null),
  (pg_temp.id('12'), null, pg_temp.id('b6'), timestamptz '2020-10-25 09:00+08', 1010, 1110, 6, 100, 10.0, null),
  (pg_temp.id('13'), null, pg_temp.id('b6'), timestamptz '2020-10-28 09:00+08', 1110, 1140, 16, 30, 6.0, null),
  (pg_temp.id('14'), null, pg_temp.id('b6'), timestamptz '2020-11-03 09:00+08', 1140, 1200, 22, 60, 6.0, null),
  (pg_temp.id('15'), null, pg_temp.id('b6'), timestamptz '2020-11-05 09:00+08', 1300, 1350, 28, 50, 5.0, null);
-- guests of Oct/Nov 2020: confirmed 10-14 Oct (nights 10, 11, 12, 13 = 4) and 31 Oct-4 Nov (nights 31 Oct, 1, 2, 3 Nov); a BLOCKED 20-25 Oct (5 nights) and a CANCELLED 26-28 Oct (2 nights) that must not count.
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  (pg_temp.id('b6'), 'zz127-p-1', 'airbnb', 'confirmed', 'Zzguest Pia', date '2020-10-10', date '2020-10-14'),
  (pg_temp.id('b6'), 'zz127-p-2', 'airbnb', 'confirmed', 'Zzguest Quin', date '2020-10-31', date '2020-11-04'),
  (pg_temp.id('b6'), 'zz127-p-3', 'airbnb', 'blocked', null, date '2020-10-20', date '2020-10-25'),
  (pg_temp.id('b6'), 'zz127-p-4', 'airbnb', 'cancelled', 'Zzguest Rae', date '2020-10-26', date '2020-10-28');
select ok((select sum(kwh) = 40 and sum(m3) = 4.0 and count(*) = 4 from public.utility_daily_use_v1(pg_temp.id('b6'), date '2020-10-22', date '2020-10-25')),
          'prorate: 25 Oct reading (100 kWh over 15 Oct-25 Oct, 10 days), the cycle that starts 21 Oct takes 4 of 10 days = 40 kWh and 4.0 m3');
select ok((select sum(kwh) = 100 and sum(m3) = 10.0 and count(*) = 10 from public.utility_daily_use_v1(pg_temp.id('b6'), date '2020-10-16', date '2020-10-25')), 'prorate: the month of that reading takes all of it: 10 days = 100 kWh');
select ok((select sum(kwh) = 30 from public.utility_daily_use_v1(pg_temp.id('b6'), date '2020-10-29', date '2020-10-31')) and (select sum(kwh) = 30 from public.utility_daily_use_v1(pg_temp.id('b6'), date '2020-11-01', date '2020-11-03')),
          'prorate: the 3 Nov reading (60 kWh, 29 Oct-3 Nov = 6 days) gives October 3 of 6 days = 30 kWh and November the other 30');
select ok((select count(*) = 0 from public.utility_daily_use_v1(pg_temp.id('b6'), date '2020-11-04', date '2020-11-30')), 'a chain-broken reading (electric_prev 1300 after a chain that ends at 1200) covers no day at all');
insert into _t select 'e6', public.utility_bill_estimate_v1(pg_temp.id('b6'), date '2020-11-10');
select pg_temp.set_ub(public.utility_billing_default_v1());
-- cycle ending 21 Nov (p_on 10 Nov): days 22 Oct..3 Nov = h2 22-25 Oct 4 x 10 = 40, h3 30, h4 60 = 130 kWh; water 4 x 1.0 + 6.0 + 6.0 = 16.0 m3; days 21 Oct -> 3 Nov = 13 (the broken reading adds neither days nor use);
-- rate 12 (November manual): so far 130 x 12 + 5.60 = 1565.60; per day 130 / 13 = 10 kWh = 120.00; forecast 10 x 31 = 310 kWh = 310 x 12 + 5.60 = 3725.60
select ok((select (v -> 'electric' ->> 'kwh')::numeric = 130 and (v -> 'electric' ->> 'days')::int = 13 and (v -> 'electric' ->> 'so_far_php')::numeric = 1565.60 and (v -> 'electric' ->> 'per_day_kwh')::numeric = 10
             and (v -> 'electric' ->> 'per_day_php')::numeric = 120 and (v -> 'electric' ->> 'forecast_kwh')::numeric = 310 and (v -> 'electric' ->> 'forecast_php')::numeric = 3725.60 from _t where k = 'e6'),
          'prorate, the cycle: 130 kWh over 13 days = 1565.60 so far, per day 10 kWh = 120.00, forecast 310 kWh = 3725.60; the chain-broken reading is excluded');
-- water 16.0 m3 = 212 + 6 x 23.05 = 350.30; per day 16 / 13 = 1.2308 -> 1.23; forecast 1.2308 x 31 = 38.1538 m3 -> 38.15 = 212 + 230.50 + 266.50 + 8.1538 x 30.50 = 957.69
select ok((select (v -> 'water' ->> 'm3')::numeric = 16 and (v -> 'water' ->> 'so_far_php')::numeric = 350.30 and (v -> 'water' ->> 'per_day_m3')::numeric = 1.23 and (v -> 'water' ->> 'forecast_m3')::numeric = 38.15
             and (v -> 'water' ->> 'forecast_php')::numeric = 957.69 and (v -> 'water' ->> 'days')::int = 13 from _t where k = 'e6'), 'prorate, water: 16.0 m3 = 350.30 so far; forecast 38.15 m3 = 957.69');

-- usage_months for b6 as of 10 Nov 2020 (6 months Jun-Nov, oldest first). October: h1 10 (15 Oct) + h2 100 + h3 30 + h4 3 of 6 days 30 = 170 kWh; m3 1.0 + 10.0 + 6.0 + 3.0 = 20.0.
-- November so far (1-10 Nov): h4 3 of 6 days = 30 kWh and 3.0 m3 (the broken reading adds nothing). Use reaches 3 Nov only (the last covered day), so 3 days are covered, not the 10 elapsed: forecast 30 / 3 x 30 = 300.00 kWh and 3.0 / 3 x 30 = 30.00 m3.
-- Guest nights: October = 4 (10-13 Oct) + 1 (31 Oct) = 5 (the blocked 5 and the cancelled 2 are not counted); November 1-10 = nights 1, 2, 3 Nov = 3.
-- Per night: October 170 / 5 = 34.0 kWh, 20.0 / 5 = 4.00 m3; November so far 30 / 3 = 10.0, 3.0 / 3 = 1.00. Month change (forecast vs October) (300 - 170) / 170 = +76.47 -> +76 and (30 - 20) / 20 = +50;
-- per-night change (10 - 34) / 34 = -70.59 -> -71 and (1 - 4) / 4 = -75 (the current month changes by the so-far per-night figure, not the forecast).
insert into _t select 'u_b6', public.kpi_usage_months_v1(pg_temp.id('b6'), date '2020-11-10');
select ok((select jsonb_array_length(v) = 6 and v -> 0 ->> 'month' = '2020-06' and v -> 5 ->> 'month' = '2020-11' and (select bool_and((select count(*) from jsonb_object_keys(e)) = 13) from jsonb_array_elements(v) e)
             and (select bool_and(e ?& array['guest_nights', 'kwh_per_night', 'm3_per_night', 'kwh_night_change_pct', 'm3_night_change_pct']) from jsonb_array_elements(v) e) from _t where k = 'u_b6'),
          'usage_months: six months oldest first, every row has the thirteen keys (the eight of the contract and the five per-night keys)');
select ok((select (v -> 4 ->> 'kwh')::numeric = 170 and (v -> 4 ->> 'm3')::numeric = 20 and (v -> 4 ->> 'guest_nights')::int = 5 and (v -> 4 ->> 'kwh_per_night')::numeric = 34 and (v -> 4 ->> 'm3_per_night')::numeric = 4
             and v -> 4 -> 'kwh_change_pct' = 'null'::jsonb and v -> 4 -> 'kwh_night_change_pct' = 'null'::jsonb and (v -> 4 ->> 'forecast')::boolean is false from _t where k = 'u_b6'),
          'usage_months October: 170 kWh and 20.0 m3 by days; 5 guest nights (a blocked and a cancelled row never count); 34.0 kWh and 4.00 m3 a night; nothing before it to change against');
select ok((select (v -> 5 ->> 'forecast')::boolean and (v -> 5 ->> 'kwh_so_far')::numeric = 30 and (v -> 5 ->> 'm3_so_far')::numeric = 3 and (v -> 5 ->> 'kwh')::numeric = 300 and (v -> 5 ->> 'm3')::numeric = 30
             and (v -> 5 ->> 'kwh_change_pct')::numeric = 76 and (v -> 5 ->> 'm3_change_pct')::numeric = 50 from _t where k = 'u_b6'),
          'usage_months November: the share so far is 30 kWh and 3.0 m3, the forecast 300.00 and 30.00 (3 covered days, not 10 elapsed), changing +76 % and +50 % against October');
select ok((select (v -> 5 ->> 'guest_nights')::int = 3 and (v -> 5 ->> 'kwh_per_night')::numeric = 10 and (v -> 5 ->> 'm3_per_night')::numeric = 1 and (v -> 5 ->> 'kwh_night_change_pct')::numeric = -71
             and (v -> 5 ->> 'm3_night_change_pct')::numeric = -75 from _t where k = 'u_b6'),
          'usage_months November per night: 3 guest nights so far, 10.0 kWh and 1.00 m3 a night (so far, not the forecast), changing -71 % and -75 % against October');
select ok((select bool_and(v -> i -> 'kwh' = 'null'::jsonb and v -> i -> 'm3' = 'null'::jsonb and (v -> i ->> 'guest_nights')::int = 0 and v -> i -> 'kwh_per_night' = 'null'::jsonb and (v -> i ->> 'forecast')::boolean is false)
             from _t, generate_series(0, 3) i where k = 'u_b6'), 'usage_months June to September: no counted reading covers them (null use) and no guest nights (null per night)');

-- COVERED DAYS (property b8, fixed 2020 dates; p_today is a parameter so the suite does not depend on the day it runs). Counted readings: 21 = 31 Oct 300 kWh / 30.0 m3 (the first reading lands on its own day, so October = 300 / 30.0);
-- 22 = 12 Nov 120 kWh / 12.0 m3, previous counted reading 31 Oct, so it covers 1-12 Nov = 12 days = 10 kWh and 1.0 m3 a day. Read on 20 Nov: use reaches 12 Nov only.
-- Forecast = 120 / 12 x 30 = 300.00 kWh and 12.0 / 12 x 30 = 30.00 m3 (the old rule gave 120 / 20 x 30 = 180); change vs October (300 - 300) / 300 = 0 and (30 - 30) / 30 = 0.
-- Guests (confirmed): 10-14 Oct = 4 nights (10, 11, 12, 13 Oct); 1-5 Nov = 4 nights (1-4 Nov); 10-16 Nov = nights 10, 11, 12 Nov counted only up to the last covered day 12 Nov = 3 (13-15 Nov and the days to the 20th never count): 7 in November.
-- October per night 300 / 4 = 75.0 kWh and 30.0 / 4 = 7.50 m3; November so far 120 / 7 = 17.142857 -> 17.1 kWh and 12.0 / 7 = 1.714 -> 1.71 m3 (so far, not the forecast); change (17.142857 - 75) / 75 = -77.14 -> -77 and (1.714286 - 7.5) / 7.5 = -77.14 -> -77.
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('21'), null, pg_temp.id('b8'), timestamptz '2020-10-31 09:00+08', 1000, 1300, 50, 300, 30.0, null),
  (pg_temp.id('22'), null, pg_temp.id('b8'), timestamptz '2020-11-12 09:00+08', 1300, 1420, 80, 120, 12.0, null);
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  (pg_temp.id('b8'), 'zz127-q-1', 'airbnb', 'confirmed', 'Zzguest Sol', date '2020-10-10', date '2020-10-14'),
  (pg_temp.id('b8'), 'zz127-q-2', 'airbnb', 'confirmed', 'Zzguest Tess', date '2020-11-01', date '2020-11-05'),
  (pg_temp.id('b8'), 'zz127-q-3', 'airbnb', 'confirmed', 'Zzguest Uma', date '2020-11-10', date '2020-11-16'),
  (pg_temp.id('b8'), 'zz127-q-4', 'airbnb', 'confirmed', 'Zzguest Val', date '2020-12-01', date '2020-12-04');
insert into _t select 'u_b8', public.kpi_usage_months_v1(pg_temp.id('b8'), date '2020-11-20');
select ok((select (v -> 5 ->> 'forecast')::boolean and (v -> 5 ->> 'kwh_so_far')::numeric = 120 and (v -> 5 ->> 'm3_so_far')::numeric = 12 and (v -> 5 ->> 'kwh')::numeric = 300 and (v -> 5 ->> 'm3')::numeric = 30
             and (v -> 4 ->> 'kwh')::numeric = 300 and (v -> 4 ->> 'm3')::numeric = 30 and (v -> 5 ->> 'kwh_change_pct')::numeric = 0 and (v -> 5 ->> 'm3_change_pct')::numeric = 0 from _t where k = 'u_b8'),
          'usage_months, covered days: read on the 20th with use up to the 12th, the forecast is 120 / 12 x 30 = 300 kWh and 30 m3 (not 180), 0 % against October');
select ok((select (v -> 4 ->> 'guest_nights')::int = 4 and (v -> 4 ->> 'kwh_per_night')::numeric = 75 and (v -> 4 ->> 'm3_per_night')::numeric = 7.5
             and (v -> 5 ->> 'guest_nights')::int = 7 and (v -> 5 ->> 'kwh_per_night')::numeric = 17.1 and (v -> 5 ->> 'm3_per_night')::numeric = 1.71
             and (v -> 5 ->> 'kwh_night_change_pct')::numeric = -77 and (v -> 5 ->> 'm3_night_change_pct')::numeric = -77 from _t where k = 'u_b8'),
          'usage_months, covered days: guest nights stop at the last covered day (7 in November, not 10), 17.1 kWh and 1.71 m3 a night, -77 % against October');
-- read on 5 Dec: no counted reading covers a December day yet (the 12 Nov one ends in November), though a confirmed stay 1-4 Dec exists: null forecast, per night and changes, and no guest night is counted before a covered day
insert into _t select 'u_b8d', public.kpi_usage_months_v1(pg_temp.id('b8'), date '2020-12-05');
select ok((select v -> 5 ->> 'month' = '2020-12' and (v -> 5 ->> 'forecast')::boolean and v -> 5 -> 'kwh' = 'null'::jsonb and v -> 5 -> 'm3' = 'null'::jsonb and v -> 5 -> 'kwh_so_far' = 'null'::jsonb
             and v -> 5 -> 'kwh_change_pct' = 'null'::jsonb and v -> 5 -> 'm3_change_pct' = 'null'::jsonb and v -> 5 -> 'kwh_per_night' = 'null'::jsonb and v -> 5 -> 'm3_per_night' = 'null'::jsonb
             and v -> 5 -> 'kwh_night_change_pct' = 'null'::jsonb and v -> 5 -> 'm3_night_change_pct' = 'null'::jsonb and (v -> 5 ->> 'guest_nights')::int = 0 from _t where k = 'u_b8d'),
          'usage_months, no covered day in the current month: null forecast, per night and changes, and no guest night');

-- KPI scenario (property b3): rates relative to this month; the 2020 rates are cleared so the history is only these.
-- m-2 manual 11, m-1 manual 10, m0 manual 12 and an auto 11 on the 6th (the manual one wins), and a FUTURE manual 99 on the first day of next month that no function may read.
-- history newest first: m0 12 (+20.0 vs 10), m-1 10 (-9.1 vs 11: -1/11), m-2 11 (null, no earlier month).
delete from public.utility_rates;
insert into public.utility_rates(provider, php_per_kwh, effective_from, source) values
  ('socoteco2', 11, pg_temp.ms(2), 'manual'), ('socoteco2', 10, pg_temp.ms(1), 'manual'), ('socoteco2', 12, pg_temp.ms(0), 'manual'), ('socoteco2', 11, pg_temp.ms(0) + 5, 'auto'),
  ('socoteco2', 99, pg_temp.ms(-1), 'manual');
-- readings on the LAST day of each month, 09:00 Manila, each ending the month it is named for (the previous reading is the previous month's last day, so the delta is exactly that month's use):
-- fa m-4 100 kWh / 10.0 m3 (the first reading: lands on its own day, so m-5 has no use at all), fb m-3 150 / 12.0, fc m-2 120 / 6.0, fd m-1 90 / 9.0 (+ a misread of 999 kWh / 99 m3 that is ignored),
-- today: f0 30 / 3.0 (days 1st..today of this month) and f2 5 / 0.5 on a mid_stay session (counted, lands on today, ends no stay).
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaned_at, nights_stayed, checkout_date, cleaning_type) values
  (pg_temp.id('e1'), 'zz127-sub-e1', 'Zz127 Cleaner', pg_temp.id('b3'), now(), 1, public.manila_today(), 'mid_stay');
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('fa'), null, pg_temp.id('b3'), pg_temp.mes(4), 900, 1000, 5, 100, 10.0, null),
  (pg_temp.id('fb'), null, pg_temp.id('b3'), pg_temp.mes(3), 1000, 1150, 15, 150, 12.0, null),
  (pg_temp.id('fc'), null, pg_temp.id('b3'), pg_temp.mes(2), 1150, 1270, 27, 120, 6.0, null),
  (pg_temp.id('fd'), null, pg_temp.id('b3'), pg_temp.mes(1), 1270, 1360, 33, 90, 9.0, null),
  (pg_temp.id('f1'), null, pg_temp.id('b3'), pg_temp.mes(1) - interval '10 days', 1360, 2359, 42, 999, 99, 'misread'),
  (pg_temp.id('f0'), null, pg_temp.id('b3'), (public.manila_today() + time '00:10') at time zone 'Asia/Manila', 1360, 1390, 70, 30, 3.0, null);
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('f2'), pg_temp.id('e1'), pg_temp.id('b3'), (public.manila_today() + time '00:20') at time zone 'Asia/Manila', 1390, 1395, 73, 5, 0.5, null);
-- stays that end on those days: Ana (m-1, linked airbnb reservation, ID photo with a face box, 1 night) and three calendar-only stays (no guest record): Cy (m-2, 3 nights), Dee (m-3, 3 nights), Eli (m-4, 2 nights).
-- Not counted anywhere: a BLOCKED row on Ana's night (it sorts first by uid, so a missing status filter would pick it as her guest), a second blocked row (2 nights) and a cancelled row (2 nights) inside m-1.
insert into public.guests(id, property_id, name) values (pg_temp.id('91'), pg_temp.id('b3'), 'Zzguest Ana');
insert into public.airbnb_reservations(id, property_id, confirmation_code, status, guest_id, guest_name, checkin_date, checkout_date) values
  (pg_temp.id('81'), pg_temp.id('b3'), 'ZZ127A', 'completed', pg_temp.id('91'), 'Zzguest Ana', pg_temp.me(1) - 1, pg_temp.me(1));
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date, linked_reservation_id) values
  (pg_temp.id('b3'), 'zz127-ev-a', 'airbnb', 'confirmed', 'Zzguest Ana', pg_temp.me(1) - 1, pg_temp.me(1), pg_temp.id('81')),
  (pg_temp.id('b3'), 'zz127-ev-0blk', 'airbnb', 'blocked', 'Zzguest Blocked', pg_temp.me(1) - 1, pg_temp.me(1), null),
  (pg_temp.id('b3'), 'zz127-ev-blk2', 'airbnb', 'blocked', null, pg_temp.me(1) - 6, pg_temp.me(1) - 4, null),
  (pg_temp.id('b3'), 'zz127-ev-can', 'airbnb', 'cancelled', 'Zzguest Cancelled', pg_temp.me(1) - 9, pg_temp.me(1) - 7, null),
  (pg_temp.id('b3'), 'zz127-ev-c', 'airbnb', 'confirmed', 'Zzguest Cy',  pg_temp.me(2) - 3, pg_temp.me(2), null),
  (pg_temp.id('b3'), 'zz127-ev-d', 'airbnb', 'confirmed', 'Zzguest Dee', pg_temp.me(3) - 3, pg_temp.me(3), null),
  (pg_temp.id('b3'), 'zz127-ev-e', 'airbnb', 'confirmed', 'Zzguest Eli', pg_temp.me(4) - 2, pg_temp.me(4), null);
insert into public.guest_companions(id, guest_id, property_id, name, id_photo_path, id_face_box) values
  (pg_temp.id('71'), pg_temp.id('91'), pg_temp.id('b3'), 'Zzguest Ana', 'zz127/photo-ana.jpg', '{"x":0.1,"y":0.1,"w":0.3,"h":0.3,"src":"vision"}'::jsonb);
insert into public.app_settings(key, value) values ('power_watch_rate_day', '{"checked_at":"2026-11-20T08:00:00+08:00","note":"zz127"}'::jsonb);
-- today's reading of its own property (b7): the first reading of its chain lands on today only, so today's cycle holds exactly 35 kWh and 3.5 m3 whatever day of the month it is
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('17'), null, pg_temp.id('b7'), (public.manila_today() + time '00:10') at time zone 'Asia/Manila', 2000, 2035, 3, 35, 3.5, null);

-- non-admin callers read the payload as themselves
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 'k_cleaner', pg_temp.try($$select public.kpi_tab_v1('e1270000-0000-4000-8000-0000000000b3')$$);
insert into _t select 'tb_cleaner', pg_temp.try($$select public.today_bills_v1('e1270000-0000-4000-8000-0000000000b7')$$);
select pg_temp.as_user(pg_temp.id('a3'));
insert into _t select 'k_laundry', pg_temp.try($$select public.kpi_tab_v1('e1270000-0000-4000-8000-0000000000b3')$$);
insert into _t select 'tb_laundry', pg_temp.try($$select public.today_bills_v1('e1270000-0000-4000-8000-0000000000b7')$$);
-- the refused roles: a signed-in user with no staff profile, a cleaner of ANOTHER property, a DISABLED cleaner of the property, a null property, anon
select pg_temp.as_user(pg_temp.id('a4'));
insert into _t select 'tb_nostaff', pg_temp.try($$select public.today_bills_v1('e1270000-0000-4000-8000-0000000000b7')$$);
select pg_temp.as_user(pg_temp.id('a5'));
insert into _t select 'tb_other', pg_temp.try($$select public.today_bills_v1('e1270000-0000-4000-8000-0000000000b7')$$);
insert into _t select 'tb_null', pg_temp.try($$select public.today_bills_v1(null)$$);
select pg_temp.as_user(pg_temp.id('a6'));
insert into _t select 'tb_disabled', pg_temp.try($$select public.today_bills_v1('e1270000-0000-4000-8000-0000000000b7')$$);
select pg_temp.as_anon();
insert into _t select 'tb_anon', pg_temp.try($$select public.today_bills_v1('e1270000-0000-4000-8000-0000000000b7')$$);
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'k_admin', pg_temp.try($$select public.kpi_tab_v1('e1270000-0000-4000-8000-0000000000b3')$$);
reset role;
-- and again without the rate-day setting
delete from public.app_settings where key = 'power_watch_rate_day';
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'k_admin2', pg_temp.try($$select public.kpi_tab_v1('e1270000-0000-4000-8000-0000000000b3')$$);
reset role;

-- today_bills_v1: refused for everyone who is not active staff of the property, allowed for a cleaner and laundry.
-- Today's cycle holds only today's reading (35 kWh, 3.5 m3, landing on today): electricity 35 x 12 + 5.60 = 425.60 (billed at this month's 12, or after the 21st next month's fallback to 12 because the
-- future-dated 99 is never read), water 3.5 m3 = 212.
select ok((select v ->> 'err' = '42501' from _t where k = 'tb_nostaff'), 'today_bills_v1: a signed-in user with no staff profile is refused (42501)');
select ok((select v ->> 'err' = '42501' from _t where k = 'tb_other'), 'today_bills_v1: a cleaner of another property is refused (42501)');
select ok((select v ->> 'err' = '42501' from _t where k = 'tb_disabled'), 'today_bills_v1: a disabled cleaner of the property is refused (42501)');
select ok((select v ->> 'err' = '42501' from _t where k = 'tb_anon') and (select v ->> 'err' = '42501' from _t where k = 'tb_null'), 'today_bills_v1: anon and a null property are refused (42501)');
select ok((select (v ? 'err') is not true and v ?& array['since', 'water_since', 'waiting_for', 'water_waiting_for', 'last_reading_at', 'electric', 'water', 'can_pay_list', 'check_bills', 'due'] and (select count(*) = 10 from jsonb_object_keys(v)) from _t where k = 'tb_cleaner')
          and (select (v ? 'err') is not true from _t where k = 'tb_laundry'), 'today_bills_v1: allowed for a cleaner and for laundry, with exactly the ten keys of the s131 body (the four contract keys, due from s127, and water_since, waiting_for, water_waiting_for, can_pay_list, check_bills)');
select ok((select (v -> 'electric' ->> 'kwh')::numeric = 35 and (v -> 'electric' ->> 'php')::numeric = 425.60 and (v -> 'water' ->> 'm3')::numeric = 3.5 and (v -> 'water' ->> 'php')::numeric = 212
             and (select array_agg(key order by key) from jsonb_object_keys(v -> 'electric') key) = array['kwh', 'php'] and (select array_agg(key order by key) from jsonb_object_keys(v -> 'water') key) = array['m3', 'php']
             from _t where k = 'tb_cleaner'), 'today_bills_v1: 35 kWh = 425.60, 3.5 m3 = 212');
select ok((select (v ->> 'since')::date = date '2026-10-21' and (v ->> 'water_since')::date = date '2026-10-21' and (v ->> 'last_reading_at')::timestamptz = (public.manila_today() + time '00:10') at time zone 'Asia/Manila' from _t where k = 'tb_cleaner'),
          'today_bills_v1: since and water_since are the open_from 2026-10-21 (no paid bill of b7 yet) and last_reading_at the latest counted reading');

-- the rate rule reads nothing dated after today: the 99 on the first day of next month is absent from the by-month list, and a cycle that ends next month (p_on = the 3rd of next month) falls back to this month's 12
select ok((select count(*) = 3 and not bool_or(r.php_per_kwh = 99) from public.utility_rate_by_month_v1() r)
          and (public.utility_bill_estimate_v1(pg_temp.id('b3'), pg_temp.ms(-1) + 2) -> 'electric' ->> 'rate')::numeric = 12,
          'a rate dated after today is never read: 3 monthly rates, no 99, and the billed month next month falls back to 12');

-- kpi_tab_v1 for a cleaner and for laundry: usage_months (no money) yes; no admin block and no peso key from this release; every pre-existing utility key still there
select ok((select v ? 'ok' and (v ->> 'ok')::boolean and not (v ? 'admin') and jsonb_array_length(v -> 'utility' -> 'usage_months') = 6 from _t where k = 'k_cleaner')
          and (select not (v ? 'admin') and jsonb_array_length(v -> 'utility' -> 'usage_months') = 6 from _t where k = 'k_laundry'), 'kpi_tab_v1: a cleaner and laundry get usage_months and no admin block');
select ok((select bool_and(not (v::text ~ '"(bills|rate_year_avg|rate_history|water_rate|so_far_php|forecast_php|per_day_php|cost_php|checked_at|fixed_php|php_per_kwh|min_php|next_php)"')) from _t where k in ('k_cleaner', 'k_laundry')),
          'kpi_tab_v1: the non-admin payload carries no peso key of this release');
select ok((select bool_and(not ((v -> 'utility' -> 'usage_months')::text ~* 'php|cost|peso')) from _t where k in ('k_cleaner', 'k_laundry', 'k_admin')), 'usage_months carries no money, for any role');
-- this month's counted readings: f0 30 + f2 5 = 35 kWh (fd is last month's), 3.0 + 0.5 = 3.5 m3
select ok((select v -> 'utility' ?& array['kwh_month', 'kwh_per_day', 'm3_month', 'm3_per_day', 'nights_booked', 'nights_in_month', 'last_reading', 'per_stay', 'per_month', 'brownouts', 'water_cuts', 'internet_cuts']
                  and (v -> 'utility' ->> 'kwh_month')::numeric = 35 and (v -> 'utility' ->> 'm3_month')::numeric = 3.5 and v ? 'inventory' and v ? 'month' and jsonb_array_length(v -> 'utility' -> 'per_month') = 12
             from _t where k = 'k_cleaner'), 'kpi_tab_v1: every pre-existing non-admin utility key is still present, with this month 35 kWh and 3.5 m3');

-- usage_months for b3, oldest first, m-5 .. m0. Hand-computed from the month-end readings above (the misread 999 / 99 is ignored): m-5 has no counted reading before the first one so no use (null);
-- m-4 100 kWh / 10.0 m3 (the first reading lands on its own day, the last of m-4); m-3 150 / 12.0 (+50 %, +20 %); m-2 120 / 6.0 (-20 %, -50 %); m-1 90 / 9.0 (-25 %, +50 %);
-- m0 so far 35 kWh / 3.5 m3 (30 spread over the 1st..today, 5 on today), forecast = so far / day of the month x days in the month.
-- Guest nights (confirmed only): m-4 Eli 2, m-3 Dee 3, m-2 Cy 3, m-1 Ana 1 (the blocked and cancelled rows would add 1 + 2 + 2), m0 none.
-- Per night kWh: m-4 100 / 2 = 50.0; m-3 150 / 3 = 50.0 (0 %); m-2 120 / 3 = 40.0 (-20 %); m-1 90 / 1 = 90.0 ((90 - 40) / 40 = +125 %); m3: 10 / 2 = 5.00; 12 / 3 = 4.00 (-20 %); 6 / 3 = 2.00 (-50 %); 9 / 1 = 9.00 (+350 %).
select ok((select jsonb_array_length(v -> 'utility' -> 'usage_months') = 6 and v -> 'utility' -> 'usage_months' -> 0 ->> 'month' = to_char(pg_temp.ms(5), 'YYYY-MM')
                  and v -> 'utility' -> 'usage_months' -> 5 ->> 'month' = to_char(pg_temp.ms(0), 'YYYY-MM') from _t where k = 'k_admin'), 'usage_months: six months, oldest first, ending with the current Manila month');
select ok((select m -> 0 -> 'kwh' = 'null'::jsonb and m -> 0 -> 'm3' = 'null'::jsonb and m -> 0 -> 'kwh_change_pct' = 'null'::jsonb and (m -> 0 ->> 'forecast')::boolean is false and m -> 0 -> 'kwh_so_far' = 'null'::jsonb
             and (m -> 0 ->> 'guest_nights')::int = 0 and m -> 0 -> 'kwh_per_night' = 'null'::jsonb and m -> 0 -> 'kwh_night_change_pct' = 'null'::jsonb
             from (select v -> 'utility' -> 'usage_months' m from _t where k = 'k_admin') x), 'usage_months: m-5 comes before the first counted reading: null use, no change, no per-night figure');
select ok((select (m -> 1 ->> 'kwh')::numeric = 100 and (m -> 1 ->> 'm3')::numeric = 10 and m -> 1 -> 'kwh_change_pct' = 'null'::jsonb and m -> 1 -> 'm3_change_pct' = 'null'::jsonb
             and (m -> 1 ->> 'guest_nights')::int = 2 and (m -> 1 ->> 'kwh_per_night')::numeric = 50 and (m -> 1 ->> 'm3_per_night')::numeric = 5 and m -> 1 -> 'kwh_night_change_pct' = 'null'::jsonb
             from (select v -> 'utility' -> 'usage_months' m from _t where k = 'k_admin') x), 'usage_months: m-4 is 100 kWh and 10 m3 over 2 guest nights = 50.0 kWh and 5.00 m3 a night, with nothing before it to change against');
select ok((select (m -> 2 ->> 'kwh')::numeric = 150 and (m -> 2 ->> 'm3')::numeric = 12 and (m -> 2 ->> 'kwh_change_pct')::numeric = 50 and (m -> 2 ->> 'm3_change_pct')::numeric = 20
             and (m -> 2 ->> 'guest_nights')::int = 3 and (m -> 2 ->> 'kwh_per_night')::numeric = 50 and (m -> 2 ->> 'm3_per_night')::numeric = 4
             and (m -> 2 ->> 'kwh_night_change_pct')::numeric = 0 and (m -> 2 ->> 'm3_night_change_pct')::numeric = -20
             from (select v -> 'utility' -> 'usage_months' m from _t where k = 'k_admin') x), 'usage_months: m-3 is 150 kWh (+50 %) and 12 m3 (+20 %), but per night 50.0 kWh (0 %) and 4.00 m3 (-20 %)');
select ok((select (m -> 3 ->> 'kwh')::numeric = 120 and (m -> 3 ->> 'm3')::numeric = 6 and (m -> 3 ->> 'kwh_change_pct')::numeric = -20 and (m -> 3 ->> 'm3_change_pct')::numeric = -50
             and (m -> 3 ->> 'guest_nights')::int = 3 and (m -> 3 ->> 'kwh_per_night')::numeric = 40 and (m -> 3 ->> 'm3_per_night')::numeric = 2
             and (m -> 3 ->> 'kwh_night_change_pct')::numeric = -20 and (m -> 3 ->> 'm3_night_change_pct')::numeric = -50
             from (select v -> 'utility' -> 'usage_months' m from _t where k = 'k_admin') x), 'usage_months: m-2 is 120 kWh (-20 %) and 6 m3 (-50 %); per night 40.0 kWh (-20 %) and 2.00 m3 (-50 %), negative when it fell');
select ok((select (m -> 4 ->> 'kwh')::numeric = 90 and (m -> 4 ->> 'm3')::numeric = 9 and (m -> 4 ->> 'kwh_change_pct')::numeric = -25 and (m -> 4 ->> 'm3_change_pct')::numeric = 50
             and (m -> 4 ->> 'guest_nights')::int = 1 and (m -> 4 ->> 'kwh_per_night')::numeric = 90 and (m -> 4 ->> 'm3_per_night')::numeric = 9
             and (m -> 4 ->> 'kwh_night_change_pct')::numeric = 125 and (m -> 4 ->> 'm3_night_change_pct')::numeric = 350
             from (select v -> 'utility' -> 'usage_months' m from _t where k = 'k_admin') x),
          'usage_months: m-1 is 90 kWh (-25 %) and 9 m3 (+50 %) but 1 guest night (a blocked and a cancelled row are not counted), so 90.0 kWh a night is +125 % and 9.00 m3 is +350 %; the misread is ignored');
select ok((select (m -> 5 ->> 'forecast')::boolean and (m -> 5 ->> 'kwh_so_far')::numeric = 35 and (m -> 5 ->> 'm3_so_far')::numeric = 3.5
                  and (m -> 5 ->> 'kwh')::numeric = round(35.0 / extract(day from public.manila_today()) * ((pg_temp.ms(0) + interval '1 month')::date - pg_temp.ms(0)), 2)
                  and (m -> 5 ->> 'm3')::numeric = round(3.5 / extract(day from public.manila_today()) * ((pg_temp.ms(0) + interval '1 month')::date - pg_temp.ms(0)), 2)
                  and (m -> 5 ->> 'guest_nights')::int = 0 and m -> 5 -> 'kwh_per_night' = 'null'::jsonb and m -> 5 -> 'm3_night_change_pct' = 'null'::jsonb
             from (select v -> 'utility' -> 'usage_months' m from _t where k = 'k_admin') x), 'usage_months: the current month is a forecast = so far / days covered x days in the month (the last reading is today here, so covered = elapsed), with the raw sums beside it; no guest nights so no per-night figure');
select ok((select (m -> 5 ->> 'kwh_change_pct')::numeric = round(((m -> 5 ->> 'kwh')::numeric - 90) / 90 * 100) and (m -> 5 ->> 'm3_change_pct')::numeric = round(((m -> 5 ->> 'm3')::numeric - 9) / 9 * 100)
             from (select v -> 'utility' -> 'usage_months' m from _t where k = 'k_admin') x), 'usage_months: the current month changes against the previous month that has a value');
select ok((select bool_and((select count(*) from jsonb_object_keys(e)) = 13) from (select jsonb_array_elements(v -> 'utility' -> 'usage_months') e from _t where k = 'k_admin') x), 'usage_months: every row has exactly thirteen keys');

-- the admin block (owner/admin/finance only)
select ok((select v -> 'admin' ?& array['revenue_month', 'costs_month', 'net_month', 'occupancy', 'adr', 'sold_nights', 'sellable_nights', 'direct_share', 'rate', 'last_reading_cost', 'month_kwh_cost',
                                         'supplies_month', 'supply_cost_per_turnover', 'cleaning_pay_month', 'target'] and (v ->> 'ok')::boolean and v ? 'inventory' and v ? 'month' from _t where k = 'k_admin'),
          'kpi_tab_v1: every existing admin key and top-level key is still there');
select ok((select v -> 'admin' ?& array['bills', 'rate_year_avg', 'rate_history', 'water_rate', 'stays'] from _t where k = 'k_admin'), 'kpi_tab_v1: admin gains bills, rate_year_avg, rate_history, water_rate and stays');
-- admin.bills is utility_bill_estimate_v1 for b3 on today's date; the billed-month rate is 12 whatever day it is (the future 99 is not read)
select ok((select v -> 'admin' -> 'bills' = public.utility_bill_estimate_v1(pg_temp.id('b3'), public.manila_today()) and (v -> 'admin' -> 'bills' -> 'electric' ->> 'rate')::numeric = 12
             and (v -> 'admin' -> 'bills' -> 'electric' ->> 'fixed_php')::numeric = 5.6 and v -> 'admin' -> 'bills' -> 'water' ? 'so_far_php' from _t where k = 'k_admin'), 'admin.bills is the estimate for today, billed at 12 plus the 5.60 fixed charge');
select ok((select (v -> 'admin' -> 'rate' ->> 'checked_at') = '2026-11-20T08:00:00+08:00' and (v -> 'admin' -> 'rate' ->> 'php_per_kwh')::numeric = 12 from _t where k = 'k_admin'),
          'admin.rate.checked_at comes from the power_watch_rate_day setting and the rate is still the one in force (12, not the future 99)');
select ok((select jsonb_typeof(v -> 'admin' -> 'rate' -> 'checked_at') = 'null' and (v -> 'admin' -> 'rate' ->> 'php_per_kwh')::numeric = 12 from _t where k = 'k_admin2'), 'admin.rate.checked_at is null when the setting is absent');
select ok((select jsonb_array_length(v -> 'admin' -> 'rate_history') = 3 and (select array_agg((e ->> 'php_per_kwh')::numeric order by o) from jsonb_array_elements(v -> 'admin' -> 'rate_history') with ordinality t(e, o)) = array[12, 10, 11]::numeric[]
             and (select array_agg(e ->> 'month' order by o) from jsonb_array_elements(v -> 'admin' -> 'rate_history') with ordinality t(e, o)) = array[to_char(pg_temp.ms(0), 'YYYY-MM'), to_char(pg_temp.ms(1), 'YYYY-MM'), to_char(pg_temp.ms(2), 'YYYY-MM')]
             from _t where k = 'k_admin'), 'rate_history: newest first, one rate per month (the manual 12 beats the auto 11 of the same month), the future-dated 99 is absent');
select ok((select (v -> 'admin' -> 'rate_history' -> 0 ->> 'change_pct')::numeric = 20.0 and (v -> 'admin' -> 'rate_history' -> 1 ->> 'change_pct')::numeric = -9.1 and v -> 'admin' -> 'rate_history' -> 2 -> 'change_pct' = 'null'::jsonb
             from _t where k = 'k_admin'), 'rate_history: change_pct is +20.0 (10 to 12), -9.1 (11 to 10) and null for the oldest, one decimal');
select ok((select (select count(*) from jsonb_object_keys(e)) = 3 and e ?& array['month', 'php_per_kwh', 'change_pct'] from (select v -> 'admin' -> 'rate_history' -> 0 e from _t where k = 'k_admin') x), 'rate_history: three keys per row');
select ok((select (v -> 'admin' -> 'rate_history' -> 0 ->> 'php_per_kwh')::numeric = (v -> 'admin' -> 'rate' ->> 'php_per_kwh')::numeric from _t where k = 'k_admin'),
          'the rate precedence agrees: the newest history row is the rate kpi_tab_v1 already reports as in force');
select ok((select (v -> 'admin' ->> 'rate_year_avg')::numeric = (select round(avg(r.p), 2) from (values (2, 11.0), (1, 10.0), (0, 12.0)) r(n, p) where pg_temp.ms(r.n) >= date_trunc('year', public.manila_today())::date) from _t where k = 'k_admin'),
          'rate_year_avg: the mean of this calendar year''s monthly rates, 2 decimals');
select ok((select v -> 'admin' -> 'water_rate' = jsonb_build_object('min_php', 212, 'min_m3', 10, 'next_php', 23.05, 'next_upto', 20, 'source_url', 'https://gensanwater.gov.ph/water-rates/') from _t where k = 'k_admin'),
          'admin.water_rate: minimum 212 for 10 m3, next 23.05 up to 20, source url');
-- stays: counted readings that end a stay, newest first. Today's f0 (no session, no event that checks out today) and f2 (mid_stay) are no stay, the misread neither: Ana, Cy, Dee, Eli.
select ok((select jsonb_array_length(v -> 'admin' -> 'stays') = 4 and (select array_agg(e ->> 'guest_name' order by o) from jsonb_array_elements(v -> 'admin' -> 'stays') with ordinality t(e, o)) = array['Zzguest Ana', 'Zzguest Cy', 'Zzguest Dee', 'Zzguest Eli']
             from _t where k = 'k_admin'), 'stays: four readings end a stay, newest first (a reading with no session and no event that checks out that day, a mid_stay reading and a misread are left out; the blocked row is not Ana''s guest)');
-- Ana: the reading is 90 kWh / 9 m3 at the rate 12 = 1080.00; from / to / nights are the EVENT'S (check-in me(1) - 1, check-out me(1), 1 night), not the days between meter readings (which would be a month)
select ok((select (s -> 0 ->> 'kwh')::numeric = 90 and (s -> 0 ->> 'm3')::numeric = 9 and (s -> 0 ->> 'cost_php')::numeric = 1080 and (s -> 0 ->> 'from')::date = pg_temp.me(1) - 1 and (s -> 0 ->> 'to')::date = pg_temp.me(1)
             and (s -> 0 ->> 'nights')::int = 1 and s -> 0 ->> 'id_photo_path' = 'zz127/photo-ana.jpg' and (s -> 0 -> 'id_face_box') = '{"x":0.1,"y":0.1,"w":0.3,"h":0.3,"src":"vision"}'::jsonb
             from (select v -> 'admin' -> 'stays' s from _t where k = 'k_admin') x), 'stays[0] (Ana): 90 kWh = 1080.00; from, to and nights come from her calendar event (1 night); her ID photo path and face box come with the stay');
select ok((select (s -> 1 ->> 'kwh')::numeric = 120 and (s -> 1 ->> 'cost_php')::numeric = 1440 and (s -> 1 ->> 'from')::date = pg_temp.me(2) - 3 and (s -> 1 ->> 'to')::date = pg_temp.me(2) and (s -> 1 ->> 'nights')::int = 3
             and s -> 1 -> 'id_photo_path' = 'null'::jsonb and s -> 1 -> 'id_face_box' = 'null'::jsonb and s -> 1 -> 'tier' = 'null'::jsonb
             from (select v -> 'admin' -> 'stays' s from _t where k = 'k_admin') x), 'stays[1] (Cy, a calendar-only stay): 120 kWh = 1440.00, the event''s 3 nights, no photo');
select ok((select bool_and((select count(*) from jsonb_object_keys(e)) = 10 and e ?& array['from', 'to', 'nights', 'kwh', 'm3', 'cost_php', 'guest_name', 'tier', 'id_photo_path', 'id_face_box'])
             from (select jsonb_array_elements(v -> 'admin' -> 'stays') e from _t where k = 'k_admin') x)
          and (select not (v::text ~* 'phone|e-?mail|id_number|contact') from _t where k = 'k_admin'), 'stays: exactly the ten contract keys per row; no phone, e-mail or ID number anywhere in the payload');

-- stays on a property whose readings carry sessions (property b5, called as the owner of the function):
-- 01 3 Mar mid_stay session: no stay. 02 9 Mar turnover session WITH a confirmed event 4-9 Mar (5 nights): from, to and nights are the event's (the previous reading would say 6 nights from 3 Mar).
-- 03 20 Mar turnover session with NO event: falls back to the previous counted reading (9 Mar -> 20 Mar), nights null because the reading gap counts empty days, no guest, no cost without a rate. 04 25 Mar has no session and no event: no stay row.
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaned_at, nights_stayed, checkout_date, cleaning_type) values
  (pg_temp.id('e2'), 'zz127-sub-e2', 'Zz127 Cleaner', pg_temp.id('b5'), timestamptz '2020-03-03 10:00+08', 1, date '2020-03-03', 'mid_stay'),
  (pg_temp.id('e3'), 'zz127-sub-e3', 'Zz127 Cleaner', pg_temp.id('b5'), timestamptz '2020-03-09 10:00+08', 2, date '2020-03-09', 'turnover'),
  (pg_temp.id('e4'), 'zz127-sub-e4', 'Zz127 Cleaner', pg_temp.id('b5'), timestamptz '2020-03-20 10:00+08', 2, date '2020-03-20', 'turnover');
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('01'), pg_temp.id('e2'), pg_temp.id('b5'), timestamptz '2020-03-03 10:00+08', 100, 120, 5, 20, 1, null),
  (pg_temp.id('02'), pg_temp.id('e3'), pg_temp.id('b5'), timestamptz '2020-03-09 10:00+08', 120, 150, 6, 30, 2, null),
  (pg_temp.id('03'), pg_temp.id('e4'), pg_temp.id('b5'), timestamptz '2020-03-20 10:00+08', 150, 170, 8, 20, 1, null),
  (pg_temp.id('04'), null, pg_temp.id('b5'), timestamptz '2020-03-25 10:00+08', 170, 180, 9, 10, 1, null);
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  (pg_temp.id('b5'), 'zz127-ev-g', 'airbnb', 'confirmed', 'Zzguest Gus', date '2020-03-04', date '2020-03-09');
delete from public.utility_rates;
insert into _t select 'st5', public.kpi_admin_bills_v1(pg_temp.id('b5'), null);
select ok((select jsonb_array_length(v -> 'stays') = 2 and v -> 'stays' -> 1 ->> 'from' = '2020-03-04' and v -> 'stays' -> 1 ->> 'to' = '2020-03-09' and (v -> 'stays' -> 1 ->> 'nights')::int = 5
             and v -> 'stays' -> 1 ->> 'guest_name' = 'Zzguest Gus' and (v -> 'stays' -> 1 ->> 'kwh')::numeric = 30 and v -> 'stays' -> 1 -> 'cost_php' = 'null'::jsonb from _t where k = 'st5'),
          'stays: the turnover reading with an event uses the event''s check-in, check-out and 5 nights (not the 6 between meter readings) and its guest; the mid_stay reading ends no stay; no cost without a rate');
select ok((select v -> 'stays' -> 0 ->> 'from' = '2020-03-09' and v -> 'stays' -> 0 ->> 'to' = '2020-03-20' and v -> 'stays' -> 0 -> 'nights' = 'null'::jsonb and v -> 'stays' -> 0 -> 'guest_name' = 'null'::jsonb
             and (v -> 'stays' -> 0 ->> 'kwh')::numeric = 20 from _t where k = 'st5'),
          'stays: a session reading with no event falls back to the previous counted reading for from and to, with nights null (the 11-day reading gap counts empty days) and no guest; the 25 Mar reading with no session and no event is no stay row');
select ok((select v -> 'rate_history' = '[]'::jsonb and v -> 'rate_year_avg' = 'null'::jsonb and v -> 'bills' -> 'electric' -> 'so_far_php' = 'null'::jsonb from _t where k = 'st5'),
          'no rate at all: rate_history is an empty list, rate_year_avg and the bill in pesos are null');

select * from finish();
rollback;
