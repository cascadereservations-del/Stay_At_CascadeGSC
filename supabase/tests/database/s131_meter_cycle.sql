-- Session 131 (lane S, SQL): release s131_meter_cycle_20261130. Contract: docs/s131/CONTRACT.md "Lane S" over docs/s131/PLAN.md. The meter cycle follows the bill.
-- utility_bill_estimate_v1 (from = the reading date of the newest PAID bill of that meter, else open_from; counted use up to p_on with no cut at the 21st; cycle_to = from + 1 month; billed month and its rate; overdue; a bill that
-- is not paid or whose reading date is after p_on is ignored; electric and water independent; the open_from setting and its fallback), today_bills_v1 (since / water_since, waiting_for, can_pay_list, check_bills, due [] for a role that
-- cannot pay), bill_schedule_cfg_v1 / bill_due_open_v1 (the 25th), bill_pay_settle_v1 (reading_date required / invalid, reading_value, nothing stored on a refusal, stored with the paid status, reading_warn, fixed bills untouched),
-- utility_reading_warn_v1 (30 kWh / 3 m3 edges, interpolation and run-on), the table checks, grants and the md5 guard of the migration (run against the migration file itself).
-- Every expected value is hand-computed in the comment above its block. Synthetic fixtures only (uuids e1310000-..., properties ...b1 to ...b9, names "Zz S131 ..."). Today is faked INSIDE this transaction by replacing public.manila_today()
-- (rolled back with everything else) so the Today card is checked on 22 and 26 November 2026. The rate table is cleared inside the transaction (a real backup holds real rows). calendar_events and generated columns are never inserted.
-- Nothing in this file can run without a Postgres that holds the Cascade schema: it is run by the rehearsal (scripts/recovery/p6/migration-rehearsal-on-host.sh <backup> <release.json> <this file>).
begin;
select plan(61);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
grant select on public.app_settings to anon, authenticated;
grant select on storage.objects to authenticated;

create function pg_temp.id(p text) returns uuid language sql immutable as $$ select ('e1310000-0000-4000-8000-0000000000' || p)::uuid $$;
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
create function pg_temp.c1(f text, a uuid) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  execute format('select public.%I(%L)', f, a) into r;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
create function pg_temp.c2(f text, a uuid, b jsonb) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  execute format('select public.%I(%L, %L::jsonb)', f, a, b) into r;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
-- Manila today, faked for the whole transaction
create or replace function public.manila_today() returns date language sql stable set search_path = '' as $$
  select coalesce(nullif(current_setting('s131.today', true), '')::date, (now() at time zone 'Asia/Manila')::date)
$$;
create function pg_temp.td(p date) returns void language sql as $$ select set_config('s131.today', p::text, true) $$;
-- the estimate of a property on a day, as the owner
create function pg_temp.est(p_prop text, p_on date) returns jsonb language sql as $$ select public.utility_bill_estimate_v1(pg_temp.id(p_prop), p_on) $$;
-- a bill row and its id
create function pg_temp.bid(k text, prop text, per text) returns uuid language sql stable as $$
  select id from public.utility_bills where property_id = pg_temp.id(prop) and kind = k and period = per
$$;
create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.reg(n text, k text, prop text, per text) returns void language sql as $$
  insert into _t select 'id_' || n, to_jsonb(pg_temp.bid(k, prop, per)::text)
$$;
create function pg_temp.bi(n text) returns uuid language sql stable as $$ select (v #>> '{}')::uuid from _t where k = 'id_' || n $$;
-- a stored screenshot: the object in the private bucket and the sha256 upload-photo recorded for it (md5(sha) || md5(sha || 'x')); returns the path
create function pg_temp.ph(prop text, usr text, nm text, sha text) returns text language plpgsql security definer as $f$
declare p text := pg_temp.id(prop)::text || '/' || pg_temp.id(usr)::text || '/' || nm;
begin
  insert into storage.objects(bucket_id, name) values ('cleaning-photos', p);
  insert into public.staff_upload_hashes(path, sha256) values (p, md5(sha) || md5(sha || 'x'));
  return p;
end $f$;
-- a settle proof for the bill's property and the admin a2: amount amt, plus any extra keys (reading_date, reading_value, confirmed)
create function pg_temp.pf(prop text, nm text, sha text, amt numeric, extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('path', pg_temp.ph(prop, 'a2', nm, sha), 'amount', amt) || extra
$$;
-- the utility_billing setting the migration documents as the default, and the contract default of bill_schedule without remind_day (the pre-s131 shape)
create function pg_temp.set_ub(p jsonb) returns void language plpgsql as $f$
begin
  delete from public.app_settings where key = 'utility_billing';
  if p is not null then insert into public.app_settings(key, value) values ('utility_billing', p); end if;
end $f$;
create function pg_temp.set_bs(p jsonb) returns void language plpgsql as $f$
begin
  delete from public.app_settings where key = 'bill_schedule';
  if p is not null then insert into public.app_settings(key, value) values ('bill_schedule', p); end if;
end $f$;

-- fixtures -------------------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values
  (pg_temp.id('b1'), 'Zz S131 cycle', true), (pg_temp.id('b2'), 'Zz S131 paid 31 Oct', true), (pg_temp.id('b3'), 'Zz S131 paid 31 Jan', true), (pg_temp.id('b4'), 'Zz S131 setting', true),
  (pg_temp.id('b5'), 'Zz S131 today', true), (pg_temp.id('b6'), 'Zz S131 skipped', true), (pg_temp.id('b7'), 'Zz S131 settle', true), (pg_temp.id('b8'), 'Zz S131 amount', true),
  (pg_temp.id('b9'), 'Zz S131 open', true);
insert into auth.users(id, email, raw_user_meta_data) values
  (pg_temp.id('a1'), 'zz131-cleaner@example.com', '{"display_name":"Zz Cleaner"}'::jsonb), (pg_temp.id('a2'), 'zz131-admin@example.com', '{"display_name":"Zz Admin"}'::jsonb),
  (pg_temp.id('a3'), 'zz131-laundry@example.com', '{"display_name":"Zz Laundry"}'::jsonb), (pg_temp.id('a4'), 'zz131-nostaff@example.com', '{"display_name":"Zz Nostaff"}'::jsonb);
insert into public.staff_access_profiles(user_id, role, disabled_at) values
  (pg_temp.id('a1'), 'cleaner', null), (pg_temp.id('a2'), 'admin', null), (pg_temp.id('a3'), 'laundry', null);
insert into public.staff_property_access(user_id, property_id)
select pg_temp.id(u), pg_temp.id(b) from unnest(array['a1', 'a2', 'a3']) u, unnest(array['b1', 'b5', 'b6', 'b7', 'b8']) b;
-- the stand-in property the bill_pay_settle_v1 family does not use (it takes the bill's own property); no extra fixtures needed

delete from public.utility_rates;
insert into public.utility_rates(provider, php_per_kwh, effective_from, source) values ('socoteco2', 10, date '2026-10-01', 'manual'), ('socoteco2', 12, date '2026-11-01', 'manual');
select pg_temp.set_ub(public.utility_billing_default_v1());
select pg_temp.set_bs(null);
select pg_temp.td(date '2026-11-22');

-- the same three counted readings on every meter property that needs them (no cleaning session: the checkout day is the recorded Manila day).
--   c1 21 Oct 2026  4000 -> 4010 kWh (10),  100 -> 101 m3 (1.0)   first reading: lands on its own day 21 Oct = the cycle start, outside (21 Oct, ...]
--   c2 31 Oct 2026  4010 -> 4070 kWh (60),  101 -> 104 m3 (3.0)   spread over 22 Oct .. 31 Oct = 10 days: 6 kWh and 0.3 m3 a day
--   c3 19 Nov 2026  4070 -> 4130 kWh (60),  104 -> 108 m3 (4.0)   spread over 1 Nov .. 19 Nov = 19 days: 3.157895 kWh and 0.210526 m3 a day
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, water_curr, electric_delta, water_delta, meter_flag)
select gen_random_uuid(), null, pg_temp.id(b), r.at, r.ep, r.ec, r.wp, r.wc, r.ec - r.ep, r.wc - r.wp, null
  from unnest(array['b1', 'b2', 'b3', 'b4', 'b5', 'b6', 'b7', 'b8', 'b9']) b,
       (values (timestamptz '2026-10-21 09:00+08', 4000, 4010, 100, 101), (timestamptz '2026-10-31 09:00+08', 4010, 4070, 101, 104), (timestamptz '2026-11-19 09:00+08', 4070, 4130, 104, 108)) r(at, ep, ec, wp, wc);

-- 1. open_from and the estimate on 22 Nov 2026 with no paid bill --------------------------------------------------------------------------------------------------------------------
-- from = open_from 2026-10-21 for both meters. Counted days 22 Oct .. 22 Nov: electric 60 (c2) + 60 (c3) = 120 kWh, water 3.0 + 4.0 = 7.0 m3. The last covered day is 19 Nov, so days = 29.
-- cycle_to = 21 Nov (from + 1 month), already past on 22 Nov: overdue true, days_in_cycle = max(21 Nov, 22 Nov) - 21 Oct = 32, billed month 2026-11, rate 12 (the November rate).
-- so far = 120 x 12 + 5.60 = 1445.60. per day 120 / 29 = 4.137931 kWh (4.14), x 12 = 49.655 (49.66). forecast 4.137931 x 32 = 132.413793 kWh (132.41), x 12 + 5.60 = 1594.565517 (1594.57).
-- water: 7.0 m3 is inside the 10 m3 minimum = 212.00; per day 7 / 29 = 0.241379 (0.24), forecast 0.241379 x 32 = 7.724138 (7.72), still the minimum 212.00.
insert into _t select 'e1', pg_temp.est('b1', date '2026-11-22');
select ok((select v -> 'electric' = jsonb_build_object('cycle_from', '2026-10-21', 'cycle_to', '2026-11-21', 'days', 29, 'days_in_cycle', 32, 'kwh', 120.00, 'rate', 12, 'fixed_php', 5.60,
                   'so_far_php', 1445.60, 'forecast_kwh', 132.41, 'forecast_php', 1594.57, 'per_day_kwh', 4.14, 'per_day_php', 49.66,
                   'last_reading_at', (timestamptz '2026-11-19 09:00+08')::text, 'billed_month', '2026-11', 'overdue', true) from _t where k = 'e1')
          or (select (v -> 'electric') - 'last_reading_at' = jsonb_build_object('cycle_from', '2026-10-21', 'cycle_to', '2026-11-21', 'days', 29, 'days_in_cycle', 32, 'kwh', 120.00, 'rate', 12, 'fixed_php', 5.60,
                   'so_far_php', 1445.60, 'forecast_kwh', 132.41, 'forecast_php', 1594.57, 'per_day_kwh', 4.14, 'per_day_php', 49.66, 'billed_month', '2026-11', 'overdue', true) from _t where k = 'e1'),
          'electric on 22 Nov with no paid bill: counts from the 21 Oct start, everything counted (120 kWh), expected end 21 Nov already passed (overdue), 32 days in the cycle, PHP 1445.60 so far, forecast 1594.57');
select ok((select v -> 'water' = jsonb_build_object('cycle_from', '2026-10-21', 'cycle_to', '2026-11-21', 'days', 29, 'm3', 7.00, 'so_far_php', 212.00, 'forecast_m3', 7.72, 'forecast_php', 212.00, 'per_day_m3', 0.24,
                   'min_php', 212, 'min_m3', 10, 'next_php', 23.05, 'next_upto', 20, 'billed_month', '2026-11', 'overdue', true) from _t where k = 'e1'),
          'water on 22 Nov with no paid bill: from 21 Oct, 7.00 m3 (inside the minimum) = PHP 212.00, overdue, billed month 2026-11');
select ok((select v -> 'electric' ->> 'last_reading_at' is not null and (v -> 'electric' ->> 'last_reading_at')::timestamptz = timestamptz '2026-11-19 09:00+08' from _t where k = 'e1'),
          'last_reading_at is the newest counted reading inside the open cycle (19 Nov 09:00 Manila)');
-- the same property on 5 Nov: still from 21 Oct; counted 22 Oct .. 5 Nov = 60 + 5 x 3.157895 = 75.789474 kWh (75.79), last covered day 5 Nov (days 15); cycle_to 21 Nov not passed (overdue false);
-- days_in_cycle = 21 Nov - 21 Oct = 31; so far = 75.789474 x 12 + 5.60 = 915.073684 (915.07). Water 3.0 + 5 x 0.210526 = 4.052632 (4.05) = 212.00.
insert into _t select 'e2', pg_temp.est('b1', date '2026-11-05');
select ok((select (v -> 'electric' ->> 'kwh')::numeric = 75.79 and (v -> 'electric' ->> 'days')::integer = 15 and (v -> 'electric' ->> 'days_in_cycle')::integer = 31 and (v -> 'electric' ->> 'so_far_php')::numeric = 915.07
                  and (v -> 'electric' ->> 'overdue')::boolean = false and (v -> 'water' ->> 'm3')::numeric = 4.05 and (v -> 'water' ->> 'overdue')::boolean = false from _t where k = 'e2'),
          'on 5 Nov the cycle is not overdue: 75.79 kWh over 15 days, 31 days in the cycle, PHP 915.07 so far, water 4.05 m3');

-- 2. the cycle follows the PAID bill ------------------------------------------------------------------------------------------------------------------------------------------------
-- b1: a paid electric bill with reading date 21 Nov. On 22 Nov electric starts 21 Nov: nothing counted yet (0 kWh, 0 days), so far = the fixed charge 5.60 at the December rate (latest earlier = November 12), cycle_to 21 Dec,
-- 30 days in the cycle, billed month 2026-12, not overdue, no forecast (no covered day). Water is independent: still from 21 Oct, overdue, November. Seen from 5 Nov the 21 Nov reading date is in the future and is ignored.
insert into public.utility_bills(property_id, kind, period, estimate_php, status, paid_php, paid_at, paid_by_name, proof_verdict, reading_date)
values (pg_temp.id('b1'), 'electric', '2026-11', 1000, 'paid', 1000, now(), 'Zz Admin', 'typed', date '2026-11-21');
insert into _t select 'p1', pg_temp.est('b1', date '2026-11-22');
select ok((select (v -> 'electric' ->> 'cycle_from') = '2026-11-21' and (v -> 'electric' ->> 'cycle_to') = '2026-12-21' and (v -> 'electric' ->> 'days')::integer = 0 and (v -> 'electric' ->> 'days_in_cycle')::integer = 30
                  and (v -> 'electric' ->> 'kwh')::numeric = 0 and (v -> 'electric' ->> 'so_far_php')::numeric = 5.60 and (v -> 'electric' ->> 'billed_month') = '2026-12' and (v -> 'electric' ->> 'overdue')::boolean = false
                  and (v -> 'electric' -> 'forecast_kwh') = 'null'::jsonb and (v -> 'electric' -> 'forecast_php') = 'null'::jsonb and (v -> 'electric' ->> 'rate')::numeric = 12 from _t where k = 'p1'),
          'after a paid electric bill with reading date 21 Nov the electric cycle starts 21 Nov: 0 kWh, the fixed charge only, billed month 2026-12, not overdue, no forecast');
select ok((select (v -> 'water' ->> 'cycle_from') = '2026-10-21' and (v -> 'water' ->> 'overdue')::boolean and (v -> 'water' ->> 'm3')::numeric = 7.00 from _t where k = 'p1'),
          'water is independent of the electric bill: still from 21 Oct, overdue, 7.00 m3');
select ok((select (v -> 'electric' ->> 'cycle_from') = '2026-10-21' and (v -> 'electric' ->> 'so_far_php')::numeric = 915.07 from _t where k = 'e2')
          and (pg_temp.est('b1', date '2026-11-05') -> 'electric' ->> 'cycle_from') = '2026-10-21' and (pg_temp.est('b1', date '2026-11-05') -> 'electric' ->> 'so_far_php')::numeric = 915.07,
          'a reading date after p_on is ignored: the 5 Nov estimate is the same with the 21 Nov bill present');
-- b2: a paid electric bill with reading date 31 Oct. From 31 Oct, expected end 31 Oct + 1 month = 30 Nov. On 22 Nov: counted 1 .. 22 Nov = c3's 60 kWh, last covered day 19 Nov (days 19), billed month November (month of 30 Nov),
-- not overdue, days_in_cycle = 30 Nov - 31 Oct = 30. so far = 60 x 12 + 5.60 = 725.60. per day 60 / 19 = 3.157895 (3.16); forecast 3.157895 x 30 = 94.736842 (94.74), x 12 + 5.60 = 1142.442105 (1142.44).
-- A DUE bill with a reading date on the water side does not count (only paid bills move the cycle): water stays from 21 Oct.
insert into public.utility_bills(property_id, kind, period, estimate_php, status, paid_php, paid_at, paid_by_name, proof_verdict, reading_date)
values (pg_temp.id('b2'), 'electric', '2026-10', 1000, 'paid', 1000, now(), 'Zz Admin', 'typed', date '2026-10-31');
insert into public.utility_bills(property_id, kind, period, estimate_php, status, reading_date) values (pg_temp.id('b2'), 'water', '2026-11', 300, 'due', date '2026-11-10');
insert into _t select 'p2', pg_temp.est('b2', date '2026-11-22');
select ok((select (v -> 'electric') - 'last_reading_at' = jsonb_build_object('cycle_from', '2026-10-31', 'cycle_to', '2026-11-30', 'days', 19, 'days_in_cycle', 30, 'kwh', 60.00, 'rate', 12, 'fixed_php', 5.60,
                   'so_far_php', 725.60, 'forecast_kwh', 94.74, 'forecast_php', 1142.44, 'per_day_kwh', 3.16, 'per_day_php', 37.89, 'billed_month', '2026-11', 'overdue', false) from _t where k = 'p2'),
          'paid electric bill with reading date 31 Oct: the cycle runs 31 Oct to 30 Nov, 60 kWh, PHP 725.60 so far, forecast 1142.44, not overdue');
select ok((select (v -> 'water' ->> 'cycle_from') = '2026-10-21' and (v -> 'water' ->> 'm3')::numeric = 7.00 from _t where k = 'p2'),
          'a bill that is not paid never moves the cycle, even with a reading date: water stays from 21 Oct');
-- b3: a paid bill with reading date 31 Jan 2026: the expected end is 28 Feb (the month is clamped), billed month 2026-02. No rate exists for February or earlier: so far is null, never 0.
insert into public.utility_bills(property_id, kind, period, estimate_php, status, paid_php, paid_at, paid_by_name, proof_verdict, reading_date)
values (pg_temp.id('b3'), 'electric', '2026-01', 1000, 'paid', 1000, now(), 'Zz Admin', 'typed', date '2026-01-31');
select ok((pg_temp.est('b3', date '2026-02-10') -> 'electric' ->> 'cycle_to') = '2026-02-28' and (pg_temp.est('b3', date '2026-02-10') -> 'electric' ->> 'billed_month') = '2026-02'
          and (pg_temp.est('b3', date '2026-02-10') -> 'electric' ->> 'overdue')::boolean = false and (pg_temp.est('b3', date '2026-03-01') -> 'electric' ->> 'overdue')::boolean = true
          and (pg_temp.est('b3', date '2026-02-10') -> 'electric' -> 'so_far_php') = 'null'::jsonb and (pg_temp.est('b3', date '2026-02-10') -> 'electric' -> 'rate') = 'null'::jsonb,
          'from 31 Jan the expected end is 28 Feb (clamped), billed month 2026-02, overdue only after it, and no rate means a null amount, never 0');
-- the open_from setting: b4 has no bill. open_from 2026-10-31 for electric only: electric counts from 31 Oct (60 kWh, c3), water still from the default 21 Oct. A wrong type or an impossible date falls back to 21 Oct.
select pg_temp.set_ub('{"electric":{"open_from":"2026-10-31"}}'::jsonb);
select ok((pg_temp.est('b4', date '2026-11-22') -> 'electric' ->> 'cycle_from') = '2026-10-31' and (pg_temp.est('b4', date '2026-11-22') -> 'electric' ->> 'kwh')::numeric = 60.00
          and (pg_temp.est('b4', date '2026-11-22') -> 'water' ->> 'cycle_from') = '2026-10-21',
          'the open_from setting starts the first cycle: electric from 31 Oct, water (no setting) from the 21 Oct default');
select ok((select public.utility_billing_cfg_v1() #>> '{electric,open_from}' = '2026-10-31' and public.utility_billing_cfg_v1() #>> '{water,open_from}' = '2026-10-21'), 'the cfg returns the stored open_from key by key');
select pg_temp.set_ub('{"electric":{"open_from":"2026-02-31"},"water":{"open_from":20261031}}'::jsonb);
select ok((select public.utility_billing_cfg_v1() #>> '{electric,open_from}' = '2026-10-21' and public.utility_billing_cfg_v1() #>> '{water,open_from}' = '2026-10-21'),
          'an open_from that is not a real date (2026-02-31) or not a string falls back to 2026-10-21 and never raises');
select pg_temp.set_ub('{"electric":{"open_from":"21/10/2026"},"water":{"open_from":null}}'::jsonb);
select ok((select public.utility_billing_cfg_v1() #>> '{electric,open_from}' = '2026-10-21' and public.utility_billing_cfg_v1() #>> '{water,open_from}' = '2026-10-21'), 'a text that is not YYYY-MM-DD or a JSON null falls back to 2026-10-21');
select pg_temp.set_ub('"just a string"'::jsonb);
select ok((select public.utility_billing_cfg_v1() = public.utility_billing_default_v1() and public.utility_billing_default_v1() #>> '{electric,open_from}' = '2026-10-21' and public.utility_billing_default_v1() #>> '{water,open_from}' = '2026-10-21'),
          'a setting that is not an object gives the default, which carries open_from 2026-10-21 for both meters');
select pg_temp.set_ub(null);
select ok((select public.utility_billing_cfg_v1() = public.utility_billing_default_v1()), 'no setting row: the cfg is the default');
select pg_temp.set_ub(public.utility_billing_default_v1());
-- the helper reads real dates only
select ok(public.utility_safe_date_v1('2026-11-21') = date '2026-11-21' and public.utility_safe_date_v1('2026-02-31') is null and public.utility_safe_date_v1('2026-2-1') is null and public.utility_safe_date_v1(null) is null
          and public.utility_safe_date_v1('21 Nov 2026') is null and public.utility_safe_date_v1('2026-13-01') is null, 'utility_safe_date_v1: real dates only, null for anything else (never raises)');
-- the callers keep every old key (kpi_admin_bills_v1 returns the estimate of today as admin.bills): the keys the Staff app and the KPI tab read are all still there, plus billed_month and overdue
select ok((select (select array_agg(k) from unnest(array['cycle_from','cycle_to','days','days_in_cycle','kwh','rate','fixed_php','so_far_php','forecast_kwh','forecast_php','per_day_kwh','per_day_php','last_reading_at','billed_month','overdue']) k
                    where not (public.kpi_admin_bills_v1(pg_temp.id('b1'), 12) -> 'bills' -> 'electric' ? k)) is null)
          and (select (select array_agg(k) from unnest(array['cycle_from','cycle_to','days','m3','so_far_php','forecast_m3','forecast_php','per_day_m3','min_php','min_m3','next_php','next_upto','billed_month','overdue']) k
                    where not (public.kpi_admin_bills_v1(pg_temp.id('b1'), 12) -> 'bills' -> 'water' ? k)) is null),
          'kpi_admin_bills_v1 (admin.bills) still has every old key of the estimate, plus billed_month and overdue');

-- 3. bill_schedule: bills open on the 25th ------------------------------------------------------------------------------------------------------------------------------------------
-- No stored remind_day: every bill reports 25 (was the pay day 27); pay_day stays 27, reading_day 21. A stored remind_day (water 10) wins for that bill only.
select ok((select (c -> 'bills' -> 'electric' ->> 'remind_day') = '25' and (c -> 'bills' -> 'water' ->> 'remind_day') = '25' and (c -> 'bills' -> 'internet' ->> 'remind_day') = '25' and (c -> 'bills' -> 'netflix' ->> 'remind_day') = '25'
                  and (c ->> 'pay_day') = '27' and (c ->> 'reading_day') = '21' from (select public.bill_schedule_cfg_v1() c) x),
          'with no setting every bill opens on the 25th while pay_day stays 27 and reading_day 21');
select pg_temp.set_bs('{"pay_day":27,"bills":{"water":{"remind_day":10},"electric":{"account":"Zz acct 1"}}}'::jsonb);
select ok((select (c -> 'bills' -> 'water' ->> 'remind_day') = '10' and (c -> 'bills' -> 'electric' ->> 'remind_day') = '25' and (c -> 'bills' -> 'electric' ->> 'account') = 'Zz acct 1'
                  and (c -> 'bills' -> 'internet' ->> 'remind_day') = '25' from (select public.bill_schedule_cfg_v1() c) x),
          'a stored remind_day wins for its bill only; a bill with none opens on the 25th; stored account values are read as before');
select pg_temp.set_bs(null);
-- bill_due_open_v1 on b9: the 24th is before the remind day 25, so it opens the PREVIOUS month 2026-10 (catch-up); the 25th opens 2026-11. Estimates of the 25th: electric = forecast of the cycle that closes in November
-- (21 Oct .. 21 Nov, p_on 21 Nov): 120 kWh over 29 days, forecast days = 31: 120 / 29 x 31 = 128.275862 kWh x 12 + 5.60 = 1544.910345 (1544.91); water 7 / 29 x 31 = 7.48 m3 = 212.00; internet 1500; netflix 449.
insert into _t select 'o24', public.bill_due_open_v1(pg_temp.id('b9'), date '2026-11-24');
insert into _t select 'o25', public.bill_due_open_v1(pg_temp.id('b9'), date '2026-11-25');
select ok((select (select bool_and(e ->> 'period' = '2026-10') and count(*) = 4 from jsonb_array_elements(v -> 'new') e) from _t where k = 'o24'),
          'on the 24th (before the remind day 25) the previous month 2026-10 opens its four rows');
select ok((select (select jsonb_agg(e ->> 'period') from jsonb_array_elements(v -> 'new') e) = '["2026-11","2026-11","2026-11","2026-11"]'::jsonb
                  and (select jsonb_agg(e ->> 'kind') from jsonb_array_elements(v -> 'new') e) = '["electric","water","internet","netflix"]'::jsonb from _t where k = 'o25')
          and (select estimate_php from public.utility_bills where property_id = pg_temp.id('b9') and kind = 'electric' and period = '2026-11') = 1544.91
          and (select estimate_php from public.utility_bills where property_id = pg_temp.id('b9') and kind = 'water' and period = '2026-11') = 212.00
          and (select estimate_php from public.utility_bills where property_id = pg_temp.id('b9') and kind = 'internet' and period = '2026-11') = 1500
          and (select estimate_php from public.utility_bills where property_id = pg_temp.id('b9') and kind = 'netflix' and period = '2026-11') = 449,
          'on the 25th the November rows open with the estimates of the cycle that closes in November: electric 1544.91, water 212.00, internet 1500, netflix 449');

-- 4. Today card ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- b5 on 22 Nov, no bills: a cleaner (a1) and an admin (a2). The meters start 21 Oct and both are overdue for November. Every old key is still there.
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 't1c', pg_temp.c1('today_bills_v1', pg_temp.id('b5'));
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 't1a', pg_temp.c1('today_bills_v1', pg_temp.id('b5'));
select pg_temp.as_user(pg_temp.id('a3'));
insert into _t select 't1l', pg_temp.c1('today_bills_v1', pg_temp.id('b5'));
select pg_temp.as_user(pg_temp.id('a4'));
insert into _t select 't1n', pg_temp.c1('today_bills_v1', pg_temp.id('b5'));
select pg_temp.as_anon();
insert into _t select 't1x', pg_temp.c1('today_bills_v1', pg_temp.id('b5'));
reset role;
select ok((select v - 'last_reading_at' = jsonb_build_object('since', '2026-10-21', 'water_since', '2026-10-21', 'waiting_for', 'November', 'water_waiting_for', 'November',
                   'electric', jsonb_build_object('php', 1445.60, 'kwh', 120.00), 'water', jsonb_build_object('php', 212.00, 'm3', 7.00), 'can_pay_list', false, 'check_bills', false, 'due', '[]'::jsonb) from _t where k = 't1c')
          and (select (v ->> 'last_reading_at')::timestamptz = timestamptz '2026-11-19 09:00+08' from _t where k = 't1c'),
          'cleaner on 22 Nov: every old key plus since / water_since 21 Oct, waiting for the November bill (both meters), can_pay_list false, check_bills false before the 25th, due []');
select ok((select (v ->> 'can_pay_list')::boolean and (v ->> 'check_bills')::boolean = false and v -> 'due' = '[]'::jsonb and (v ->> 'waiting_for') = 'November' and (v ->> 'since') = '2026-10-21' from _t where k = 't1a'),
          'admin on 22 Nov: can_pay_list true, nothing to pay yet (no rows), check_bills false');
select ok((select (v ->> 'can_pay_list')::boolean = false and v -> 'due' = '[]'::jsonb from _t where k = 't1l'), 'laundry cannot pay: can_pay_list false, due []');
select ok((select v ->> 'err' = '42501' from _t where k = 't1n') and (select v ->> 'err' = '42501' from _t where k = 't1x'), 'a user with no staff profile and anon are still refused (42501)');
-- 26 Nov, b5: rows open (electric 2026-11 est 1000, water 2026-11 est 300). The cleaner gets due [] and check_bills true (the 26th is after the 25th and neither bill is paid); the admin gets the list and check_bills false.
select pg_temp.td(date '2026-11-26');
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('b5'), 'electric', '2026-11', 1000, 'due'), (pg_temp.id('b5'), 'water', '2026-11', 300, 'due');
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 't2c', pg_temp.c1('today_bills_v1', pg_temp.id('b5'));
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 't2a', pg_temp.c1('today_bills_v1', pg_temp.id('b5'));
reset role;
select ok((select (v ->> 'can_pay_list')::boolean = false and v -> 'due' = '[]'::jsonb and (v ->> 'check_bills')::boolean from _t where k = 't2c'),
          'cleaner on 26 Nov with both meter bills unpaid: due [] and check_bills true');
select ok((select (v ->> 'can_pay_list')::boolean and (v ->> 'check_bills')::boolean = false and jsonb_array_length(v -> 'due') = 2
                  and (select jsonb_agg(e ->> 'kind') from jsonb_array_elements(v -> 'due') e) = '["electric","water"]'::jsonb and (select bool_and((e ->> 'can_pay')::boolean) from jsonb_array_elements(v -> 'due') e) from _t where k = 't2a'),
          'admin on 26 Nov: the To pay list as before (electric, water, both payable), check_bills false');
-- the electric bill is paid with reading date 21 Nov, the water bill is still unpaid: the cleaner is still asked to check (water). Electric now starts 21 Nov: since 2026-11-21, no waiting_for; water still since 21 Oct, waiting for November.
update public.utility_bills set status = 'paid', paid_php = 1000, paid_at = now(), paid_by_name = 'Zz Admin', proof_verdict = 'typed', reading_date = date '2026-11-21' where property_id = pg_temp.id('b5') and kind = 'electric';
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 't3c', pg_temp.c1('today_bills_v1', pg_temp.id('b5'));
reset role;
select ok((select (v ->> 'check_bills')::boolean and (v ->> 'since') = '2026-11-21' and v -> 'waiting_for' = 'null'::jsonb and (v ->> 'water_since') = '2026-10-21' and (v ->> 'water_waiting_for') = 'November' from _t where k = 't3c'),
          'electric paid with reading date 21 Nov: the card counts from 21 Nov and waits for nothing, water still since 21 Oct and waiting for November, the cleaner is still asked to check the water bill');
-- the water bill is paid with reading date 20 Nov: water now starts 20 Nov and nothing is left to check.
update public.utility_bills set status = 'paid', paid_php = 300, paid_at = now(), paid_by_name = 'Zz Admin', proof_verdict = 'typed', reading_date = date '2026-11-20' where property_id = pg_temp.id('b5') and kind = 'water';
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 't4c', pg_temp.c1('today_bills_v1', pg_temp.id('b5'));
reset role;
select ok((select (v ->> 'check_bills')::boolean = false and (v ->> 'water_since') = '2026-11-20' and v -> 'water_waiting_for' = 'null'::jsonb and v -> 'due' = '[]'::jsonb from _t where k = 't4c'),
          'both meter bills paid: check_bills false, water counts from its own reading date 20 Nov');
-- a skipped bill needs no looking for (b6: electric paid, water skipped on 26 Nov)
insert into public.utility_bills(property_id, kind, period, estimate_php, status, paid_php, paid_at, paid_by_name, proof_verdict, reading_date)
values (pg_temp.id('b6'), 'electric', '2026-11', 1000, 'paid', 1000, now(), 'Zz Admin', 'typed', date '2026-11-21');
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('b6'), 'water', '2026-11', 300, 'skipped');
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 't5c', pg_temp.c1('today_bills_v1', pg_temp.id('b6'));
reset role;
select ok((select (v ->> 'check_bills')::boolean = false from _t where k = 't5c'), 'a skipped water bill needs no check: check_bills false');
-- 24 Nov (before the remind day): nothing to check yet even with no paid bill (b7 has no rows)
select pg_temp.td(date '2026-11-24');
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 't6c', pg_temp.c1('today_bills_v1', pg_temp.id('b7'));
reset role;
select ok((select (v ->> 'check_bills')::boolean = false from _t where k = 't6c'), 'on the 24th (before the remind day 25) check_bills is false');
select pg_temp.td(date '2026-11-22');

-- 5. bill_pay_settle_v1 -------------------------------------------------------------------------------------------------------------------------------------------------------------
-- b7, 22 Nov, admin a2. Bills: electric 2026-11 (est 1000, band 500 .. 2000), water 2026-11 (est 300, band 150 .. 600), internet 2026-11 (est 1500, band 1500 .. 1550), later electric 2026-12 and water 2026-12.
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values
  (pg_temp.id('b7'), 'electric', '2026-11', 1000, 'due'), (pg_temp.id('b7'), 'water', '2026-11', 300, 'due'), (pg_temp.id('b7'), 'internet', '2026-11', 1500, 'due'),
  (pg_temp.id('b7'), 'electric', '2026-12', 1000, 'due'), (pg_temp.id('b7'), 'water', '2026-12', 300, 'due');
select pg_temp.reg('el11', 'electric', 'b7', '2026-11'); select pg_temp.reg('wa11', 'water', 'b7', '2026-11'); select pg_temp.reg('in11', 'internet', 'b7', '2026-11');
select pg_temp.reg('el12', 'electric', 'b7', '2026-12'); select pg_temp.reg('wa12', 'water', 'b7', '2026-12');
select pg_temp.as_user(pg_temp.id('a2'));
-- refusals on the electric bill: no date, an empty date, a number, not a real date, a wrong format, after today (23 Nov), the open_from day itself and earlier (nothing paid yet), then a bad reading value
insert into _t select 's1', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el11'), pg_temp.pf('b7', 'zz131-proof-0001-a.jpg', '1', 1000));
insert into _t select 's2a', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el11'), pg_temp.pf('b7', 'zz131-proof-0002-a.jpg', '2', 1000, '{"reading_date":""}'));
insert into _t select 's2b', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el11'), pg_temp.pf('b7', 'zz131-proof-0003-a.jpg', '3', 1000, '{"reading_date":20261121}'));
insert into _t select 's3a', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el11'), pg_temp.pf('b7', 'zz131-proof-0004-a.jpg', '4', 1000, '{"reading_date":"2026-11-31"}'));
insert into _t select 's3b', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el11'), pg_temp.pf('b7', 'zz131-proof-0005-a.jpg', '5', 1000, '{"reading_date":"21-11-2026"}'));
insert into _t select 's4a', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el11'), pg_temp.pf('b7', 'zz131-proof-0006-a.jpg', '6', 1000, '{"reading_date":"2026-11-23"}'));
insert into _t select 's4b', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el11'), pg_temp.pf('b7', 'zz131-proof-0007-a.jpg', '7', 1000, '{"reading_date":"2026-10-21"}'));
insert into _t select 's4c', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el11'), pg_temp.pf('b7', 'zz131-proof-0008-a.jpg', '8', 1000, '{"reading_date":"2026-10-20"}'));
insert into _t select 's5a', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el11'), pg_temp.pf('b7', 'zz131-proof-0009-a.jpg', '9', 1000, '{"reading_date":"2026-11-21","reading_value":-1}'));
insert into _t select 's5b', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el11'), pg_temp.pf('b7', 'zz131-proof-0010-a.jpg', 'a', 1000, '{"reading_date":"2026-11-21","reading_value":"abc"}'));
insert into _t select 's5c', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el11'), pg_temp.pf('b7', 'zz131-proof-0011-a.jpg', 'b', 1000, '{"reading_date":"2026-11-21","reading_value":true}'));
reset role;
select ok((select v = '{"ok":false,"reason":"reading_date_required"}'::jsonb from _t where k = 's1') and (select v = '{"ok":false,"reason":"reading_date_required"}'::jsonb from _t where k = 's2a')
          and (select v = '{"ok":false,"reason":"reading_date_required"}'::jsonb from _t where k = 's2b'),
          'an electric bill with no reading date, an empty one or a number is refused: reading_date_required');
select ok((select v = '{"ok":false,"reason":"reading_date_invalid","after":"2026-10-21"}'::jsonb from _t where k = 's3a') and (select v = '{"ok":false,"reason":"reading_date_invalid","after":"2026-10-21"}'::jsonb from _t where k = 's3b')
          and (select v = '{"ok":false,"reason":"reading_date_invalid","after":"2026-10-21"}'::jsonb from _t where k = 's4a') and (select v = '{"ok":false,"reason":"reading_date_invalid","after":"2026-10-21"}'::jsonb from _t where k = 's4b')
          and (select v = '{"ok":false,"reason":"reading_date_invalid","after":"2026-10-21"}'::jsonb from _t where k = 's4c'),
          'an impossible date (31 Nov), a wrong format, a date after today (23 Nov) and the open_from day or earlier are refused: reading_date_invalid, with the date it must be after');
select ok((select v = '{"ok":false,"reason":"reading_value_invalid"}'::jsonb from _t where k = 's5a') and (select v = '{"ok":false,"reason":"reading_value_invalid"}'::jsonb from _t where k = 's5b')
          and (select v = '{"ok":false,"reason":"reading_value_invalid"}'::jsonb from _t where k = 's5c'),
          'a negative, a non-numeric or a boolean present reading is refused: reading_value_invalid');
select ok((select status = 'due' and reading_date is null and reading_value is null and paid_php is null and paying_by is null from public.utility_bills where id = pg_temp.bi('el11'))
          and (select count(*) = 0 from public.transactions where source = 'bill' and property_id = pg_temp.id('b7')),
          'every refusal stored nothing: the bill is still due with no reading, no paying person and no ledger row');
-- success: reading date 21 Nov, present reading 4150. The meter log at 21 Nov: last counted reading c3 (19 Nov, 4130, 60 kWh over 19 days = 3.157895 a day) runs on 2 days to 4136.315789; 4150 is 13.68 away: no warning.
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 's6', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el11'), pg_temp.pf('b7', 'zz131-proof-0012-a.jpg', 'c', 1000, '{"reading_date":"2026-11-21","reading_value":4150}'));
reset role;
select ok((select (v ->> 'ok')::boolean and v ->> 'reading_date' = '2026-11-21' and (v ->> 'reading_warn')::boolean = false and v #>> '{bill,status}' = 'paid' from _t where k = 's6')
          and (select status = 'paid' and reading_date = date '2026-11-21' and reading_value = 4150.00 and paid_php = 1000 from public.utility_bills where id = pg_temp.bi('el11'))
          and (select count(*) = 1 from public.transactions where source = 'bill' and property_id = pg_temp.id('b7') and external_ref = 'bill:electric:2026-11'),
          'a valid electric settle pays the bill, stores reading_date 2026-11-21 and reading_value 4150.00 on the row, writes the one ledger row and reports no warning');
-- the electric card now counts from 21 Nov (the stored reading date drives the cycle)
select ok((pg_temp.est('b7', date '2026-11-22') -> 'electric' ->> 'cycle_from') = '2026-11-21', 'after the settle the electric cycle of b7 starts on the stored reading date');
-- the next electric bill (2026-12): the date must be later than 21 Nov. The same day and the day before are refused (after = 2026-11-21); today, 22 Nov, is accepted.
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 's7a', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el12'), pg_temp.pf('b7', 'zz131-proof-0013-a.jpg', 'd', 1000, '{"reading_date":"2026-11-21"}'));
insert into _t select 's7b', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el12'), pg_temp.pf('b7', 'zz131-proof-0014-a.jpg', 'e', 1000, '{"reading_date":"2026-11-20"}'));
insert into _t select 's7c', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el12'), pg_temp.pf('b7', 'zz131-proof-0015-a.jpg', 'f', 1000, '{"reading_date":"2026-11-22"}'));
reset role;
select ok((select v = '{"ok":false,"reason":"reading_date_invalid","after":"2026-11-21"}'::jsonb from _t where k = 's7a') and (select v = '{"ok":false,"reason":"reading_date_invalid","after":"2026-11-21"}'::jsonb from _t where k = 's7b'),
          'a reading date equal to or older than the previous paid reading date is refused: reading_date_invalid after 2026-11-21');
select ok((select (v ->> 'ok')::boolean and v ->> 'reading_date' = '2026-11-22' from _t where k = 's7c') and (select reading_date = date '2026-11-22' and reading_value is null from public.utility_bills where id = pg_temp.bi('el12')),
          'the day after the previous one, which is today, is accepted; no present reading stays null (unknown is not 0)');
-- water: its own rule. Date required. Value 120 at 21 Nov: the water log runs on from c3 (19 Nov, 108 m3, 4 m3 over 19 days = 0.210526 a day): 108 + 2 x 0.210526 = 108.421053; 120 is 11.58 away (> 3): warning true.
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'w1', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('wa11'), pg_temp.pf('b7', 'zz131-proof-0016-a.jpg', '11', 300));
insert into _t select 'w2', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('wa11'), pg_temp.pf('b7', 'zz131-proof-0017-a.jpg', '12', 300, '{"reading_date":"2026-11-21","reading_value":"120"}'));
reset role;
select ok((select v = '{"ok":false,"reason":"reading_date_required"}'::jsonb from _t where k = 'w1'), 'a water bill needs its reading date too');
select ok((select (v ->> 'ok')::boolean and (v ->> 'reading_warn')::boolean and v ->> 'reading_date' = '2026-11-21' from _t where k = 'w2')
          and (select status = 'paid' and reading_date = date '2026-11-21' and reading_value = 120.00 from public.utility_bills where id = pg_temp.bi('wa11')),
          'a water bill with a present reading 11.6 m3 away from the meter log is paid and stored, and reading_warn is true (the warning never blocks)');
-- a fixed bill is untouched: internet pays with no reading date, and a reading date sent with it is not stored
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'i1', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('in11'), pg_temp.pf('b7', 'zz131-proof-0018-a.jpg', '13', 1500, '{"reading_date":"2026-11-21","reading_value":5}'));
reset role;
select ok((select (v ->> 'ok')::boolean and not (v ? 'reading_warn') and not (v ? 'reading_date') from _t where k = 'i1')
          and (select status = 'paid' and reading_date is null and reading_value is null from public.utility_bills where id = pg_temp.bi('in11')),
          'internet pays as before: no reading date needed, none stored, no reading_warn in the answer');
-- the amount question comes first and stores nothing: b8, water 2026-12 est 300, amount 5000 is outside the band -> confirm_amount, no reading stored; confirmed, it pays and stores the reading
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('b8'), 'water', '2026-12', 300, 'due');
select pg_temp.reg('wa8', 'water', 'b8', '2026-12');
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'c1', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('wa8'), pg_temp.pf('b8', 'zz131-proof-0019-a.jpg', '14', 5000, '{"reading_date":"2026-11-22"}'));
insert into _t select 'c2', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('wa8'), pg_temp.pf('b8', 'zz131-proof-0020-a.jpg', '15', 5000, '{"reading_date":"2026-11-22","confirmed":true}'));
reset role;
select ok((select v ->> 'reason' = 'confirm_amount' from _t where k = 'c1') and (select (v ->> 'ok')::boolean from _t where k = 'c2')
          and (select status = 'paid' and reading_date = date '2026-11-22' from public.utility_bills where id = pg_temp.bi('wa8')),
          'confirm_amount stores no reading; the confirmed second call pays and stores it');
-- a cleaner cannot settle at all (unchanged)
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('b8'), 'electric', '2026-12', 1000, 'due');
select pg_temp.reg('el8', 'electric', 'b8', '2026-12');
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 'n1', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el8'), pg_temp.pf('b8', 'zz131-proof-0021-a.jpg', '16', 1000, '{"reading_date":"2026-11-22"}'));
reset role;
select ok((select v = '{"ok":false,"reason":"not_authorized"}'::jsonb from _t where k = 'n1') and (select status = 'due' and reading_date is null from public.utility_bills where id = pg_temp.bi('el8')),
          'a cleaner is still not_authorized to settle; nothing is stored');

-- 6. the reading warning helper -----------------------------------------------------------------------------------------------------------------------------------------------------------
-- b1 meter log: c2 31 Oct 4070 kWh / 104 m3; c3 19 Nov 4130 / 108. On the day of a counted reading the log is that reading: 4070. 4100 is exactly 30 kWh away: no warning (more than 30 warns); 4100.01 warns; 4040 is 30 below: no; 4039.99 warns.
select ok(not public.utility_reading_warn_v1(pg_temp.id('b1'), 'electric', date '2026-10-31', 4100) and public.utility_reading_warn_v1(pg_temp.id('b1'), 'electric', date '2026-10-31', 4100.01)
          and not public.utility_reading_warn_v1(pg_temp.id('b1'), 'electric', date '2026-10-31', 4040) and public.utility_reading_warn_v1(pg_temp.id('b1'), 'electric', date '2026-10-31', 4039.99),
          'electric: exactly 30 kWh from the log is no warning, more than 30 is (both directions)');
-- between c2 and c3 the log is interpolated: on 9 Nov (9 of 19 days) 4070 + 60 x 9 / 19 = 4098.421053. 4128 is 29.58 away: no; 4129 is 30.58 away: warns.
select ok(not public.utility_reading_warn_v1(pg_temp.id('b1'), 'electric', date '2026-11-09', 4128) and public.utility_reading_warn_v1(pg_temp.id('b1'), 'electric', date '2026-11-09', 4129),
          'electric: the log is interpolated between two counted readings (4098.42 on 9 Nov)');
-- after the last counted reading it runs on at that reading's own pace: 21 Nov = 4130 + 2 x 3.157895 = 4136.315789. 4160 is 23.68 away: no; 4170 is 33.68 away: warns.
select ok(not public.utility_reading_warn_v1(pg_temp.id('b1'), 'electric', date '2026-11-21', 4160) and public.utility_reading_warn_v1(pg_temp.id('b1'), 'electric', date '2026-11-21', 4170),
          'electric: after the last counted reading the log runs on at that reading''s own daily use (4136.32 on 21 Nov)');
-- water on 31 Oct = 104 m3: 107 is exactly 3 away (no), 107.01 warns, 101 is 3 below (no), 100.99 warns
select ok(not public.utility_reading_warn_v1(pg_temp.id('b1'), 'water', date '2026-10-31', 107) and public.utility_reading_warn_v1(pg_temp.id('b1'), 'water', date '2026-10-31', 107.01)
          and not public.utility_reading_warn_v1(pg_temp.id('b1'), 'water', date '2026-10-31', 101) and public.utility_reading_warn_v1(pg_temp.id('b1'), 'water', date '2026-10-31', 100.99),
          'water: exactly 3 m3 from the log is no warning, more than 3 is');
-- unknown is never a warning: no value, a date before the first counted reading, a property with no readings
select ok(not public.utility_reading_warn_v1(pg_temp.id('b1'), 'electric', date '2026-10-31', null) and not public.utility_reading_warn_v1(pg_temp.id('b1'), 'electric', date '2026-10-01', 9999)
          and not public.utility_reading_warn_v1('e1310000-0000-4000-8000-0000000000ee', 'electric', date '2026-11-21', 9999),
          'no value, a date before the first counted reading and a property with no readings never warn (unknown is not a warning)');

-- 7. the table ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
select ok((select count(*) = 2 from information_schema.columns where table_schema = 'public' and table_name = 'utility_bills' and column_name in ('reading_date', 'reading_value')
                 and ((column_name = 'reading_date' and data_type = 'date') or (column_name = 'reading_value' and data_type = 'numeric' and numeric_precision = 12 and numeric_scale = 2)) and is_nullable = 'YES'),
          'utility_bills has reading_date date null and reading_value numeric(12,2) null');
select ok(pg_temp.try($q$insert into public.utility_bills(property_id, kind, period, estimate_php, status, reading_date) values ('e1310000-0000-4000-8000-0000000000b9', 'internet', '2026-09', 1500, 'due', date '2026-09-21')$q$) ->> 'err' = '23514'
          and pg_temp.try($q$insert into public.utility_bills(property_id, kind, period, estimate_php, status, reading_value) values ('e1310000-0000-4000-8000-0000000000b9', 'netflix', '2026-09', 449, 'due', 5)$q$) ->> 'err' = '23514',
          'a fixed bill (internet, netflix) cannot carry a reading date or value (check violation)');
select ok(pg_temp.try($q$insert into public.utility_bills(property_id, kind, period, estimate_php, status, reading_value) values ('e1310000-0000-4000-8000-0000000000b9', 'electric', '2026-09', 1500, 'due', -1)$q$) ->> 'err' = '23514',
          'a negative present reading is refused by the table');
select ok(pg_temp.try($q$insert into public.utility_bills(property_id, kind, period, estimate_php, status, reading_date) values ('e1310000-0000-4000-8000-0000000000b7', 'electric', '2026-10', 1500, 'due', date '2026-11-21')$q$) ->> 'err' = '23505',
          'one bill per meter and reading day: a second electric bill with 2026-11-21 on the same property is refused (unique index)');

-- 8. grants and bodies ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
select ok((select bool_and(not has_function_privilege('anon', f, 'execute') and not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('service_role', f, 'execute'))
             from unnest(array['public.utility_safe_date_v1(text)', 'public.utility_cfg_date_v1(jsonb,jsonb)', 'public.utility_meter_from_v1(uuid,text,date,jsonb)', 'public.utility_reading_warn_v1(uuid,text,date,numeric)',
                               'public.utility_bill_estimate_v1(uuid,date)', 'public.utility_billing_default_v1()', 'public.utility_billing_cfg_v1()', 'public.bill_schedule_cfg_v1()']) f),
          'the four new helpers and the internal functions this release replaces are granted to nobody (anon, authenticated, service_role)');
select ok(has_function_privilege('authenticated', 'public.today_bills_v1(uuid)', 'execute') and has_function_privilege('authenticated', 'public.bill_pay_settle_v1(uuid,jsonb)', 'execute')
          and not has_function_privilege('anon', 'public.today_bills_v1(uuid)', 'execute') and not has_function_privilege('anon', 'public.bill_pay_settle_v1(uuid,jsonb)', 'execute')
          and not has_function_privilege('service_role', 'public.today_bills_v1(uuid)', 'execute') and not has_function_privilege('service_role', 'public.bill_pay_settle_v1(uuid,jsonb)', 'execute'),
          'today_bills_v1 and bill_pay_settle_v1 stay authenticated only (not anon, not service_role)');
select ok((select bool_and(p.prosecdef = e.secdef and p.provolatile = e.vol and p.proconfig = array['search_path=""'])
             from (values ('public.utility_bill_estimate_v1(uuid,date)'::regprocedure, true, 's'), ('public.today_bills_v1(uuid)'::regprocedure, true, 's'), ('public.bill_pay_settle_v1(uuid,jsonb)'::regprocedure, true, 'v'),
                          ('public.bill_schedule_cfg_v1()'::regprocedure, false, 's'), ('public.utility_billing_cfg_v1()'::regprocedure, false, 's'), ('public.utility_billing_default_v1()'::regprocedure, false, 'i')) e(oid, secdef, vol)
             join pg_proc p on p.oid = e.oid),
          'security definer, volatility and the empty search_path of the six replaced functions are unchanged');
select ok((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.bill_due_open_v1(uuid,date,text)'::regprocedure) = '51c1bca21bbacbba9d214f963e3806d1'
          and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.bill_daily_v1(date,uuid)'::regprocedure) = '11146bc4e4577ed2e104ac119fb0b4a0'
          and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.kpi_admin_bills_v1(uuid,numeric)'::regprocedure) = 'd732f76179ea3433dbf6c710c69bec5f'
          and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.bill_step_v1(uuid,text,uuid,text,jsonb)'::regprocedure) = '36c9347d29f4b964540ca973af8cac19'
          and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.kpi_tab_v1(uuid,date)'::regprocedure) = '80efd89e916bcd6107c681baf86f143f',
          'the callers this release does not replace (bill_due_open_v1, bill_daily_v1, kpi_admin_bills_v1, bill_step_v1, kpi_tab_v1) are byte for byte the s127 bodies');

-- 10. the md5 guard of the migration (last: it breaks one function on purpose) ---------------------------------------------------------------------------------------------------------------------------------------------------
-- The guard block below is a verbatim copy of the one at the top of 20261130000000_s131_meter_cycle.sql (the rehearsal's database role cannot read the mounted file, so it cannot be cut out of it; keep the two identical).
-- On the current bodies (the migration just ran) it passes; with bill_schedule_cfg_v1 replaced by an unknown body it stops with 55000 and the message names the function.
create function pg_temp.run_do(p text) returns jsonb language plpgsql as $f$
begin
  execute p;
  return 'null'::jsonb;
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
create function pg_temp.guard_sql() returns text language sql as $gq$
select $dq$do $g$
declare v text; r record;
begin
  for r in select * from (values
    ('public.utility_billing_default_v1()', '93765639cafb84ce5860de301a5ba0af', 'a392b40c92122706aac8074ee8f490d3'),
    ('public.utility_billing_cfg_v1()', '29c5cc443923797670a7b66f51c86781', '20acb9bbe5965c08fa9b317aa9073636'),
    ('public.utility_bill_estimate_v1(uuid,date)', 'f821ade80aafe63d00dc51f8c5700bf4', '563e61f417555730a9294df15c7eca7f'),
    ('public.today_bills_v1(uuid)', '70302291441c8493c622ae66befe6b79', '7fca3fd12b7e372010f8f20b12c491a4'),
    ('public.bill_pay_settle_v1(uuid,jsonb)', 'df687957b354441f0874fac73a53ee9d', '542aa826c034741a2886863ca069c396'),
    ('public.bill_schedule_cfg_v1()', 'c8a259b8e8be8e2dd0b129e62bb8a68a', '14293a6c2efbc387a8d97240321ca839')
  ) t(sig, m_old, m_new) loop
    select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure(r.sig);
    if v is distinct from r.m_old and v is distinct from r.m_new then
      raise exception using errcode = '55000', message = 's131: ' || r.sig || ' is neither the s127 body nor this release (md5 ' || coalesce(v, 'null') || '): re-cut it from the live body';
    end if;
  end loop;
end $g$;$dq$::text
$gq$;
select ok(pg_temp.guard_sql() like 'do $g$%' and (select count(*) = 6 from regexp_matches(pg_temp.guard_sql(), '\(''public\.', 'g')), 'the guard block lists the six replaced functions');
select ok(pg_temp.run_do(pg_temp.guard_sql()) = 'null'::jsonb, 'the guard passes on the bodies of this release');
create or replace function public.bill_schedule_cfg_v1() returns jsonb language sql stable set search_path = '' as $$ select '{"unknown":true}'::jsonb $$;
select ok(pg_temp.run_do(pg_temp.guard_sql()) ->> 'err' = '55000' and pg_temp.run_do(pg_temp.guard_sql()) ->> 'msg' like 's131: public.bill_schedule_cfg_v1()%neither the s127 body nor this release%',
          'the guard refuses with 55000 when a replaced function is an unknown body');

select * from finish();
rollback;
