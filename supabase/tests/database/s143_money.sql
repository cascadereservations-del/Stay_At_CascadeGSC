-- Session 143: release s143_money_20261210 (lane S). Boundary model (real reading_date else assumed anchor + n months, month end clamped), bill_reading_set_v1, paid_on + method on settle, additive today_bills_v1 keys,
-- expense method / by / covers / title, transactions.payment_method.
-- Synthetic fixtures only (uuids e1430000-..., names "Zz S143 ..."); everything rolls back. Today is faked INSIDE this transaction by replacing public.manila_today() (setting s143.today).
-- The ledger keeps one row per bill ref across properties and a restored production copy already holds 2026 refs: every bill this suite settles has a 2027 period, and utility_billing.open_from is set to 2027-04-21 for the whole suite.
-- Rows are written and read as the owner role (a --no-acl restore gives authenticated no table grants); only the RPC calls run as the staff roles. Hand-computed values are quoted next to each assertion.
begin;
select plan(44);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
do $sr$ begin if not (select rolbypassrls from pg_roles where rolname = 'service_role') then alter role service_role bypassrls; end if; end $sr$;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt(), auth.role() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
grant execute on function public.kpi_tab_v1(uuid, date) to authenticated;
grant select on public.app_settings to anon, authenticated;
grant select on storage.objects to authenticated;
insert into storage.buckets(id, name) values ('cleaning-photos', 'cleaning-photos') on conflict (id) do nothing;

create function pg_temp.id(p text) returns uuid language sql immutable as $$ select ('e1430000-0000-4000-8000-0000000000' || p)::uuid $$;
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
grant execute on function pg_temp.as_user(uuid), pg_temp.as_anon(), pg_temp.try(text) to public;
-- Manila today, faked for the whole transaction
create or replace function public.manila_today() returns date language sql stable set search_path = '' as $$
  select coalesce(nullif(current_setting('s143.today', true), '')::date, (now() at time zone 'Asia/Manila')::date)
$$;
create function pg_temp.today(d text) returns void language sql as $$ select set_config('s143.today', d, true) $$;
-- a bill row's id by property, kind and period
create function pg_temp.bid(k text, prop text, per text) returns uuid language sql stable as $$
  select id from public.utility_bills where property_id = pg_temp.id(prop) and kind = k and period = per
$$;
create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
-- bill_reading_set_v1 as user u (a2 admin, a1 cleaner, a5 other-property cleaner), then back to the owner role
create function pg_temp.rs(u text, prop uuid, k text, d date, v numeric default null, pv boolean default false) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform pg_temp.as_user(pg_temp.id(u));
  r := pg_temp.try(format('select public.bill_reading_set_v1(%L, %L, %L, %L, %L)', prop, k, d, v, pv));
  reset role;
  return r;
end $f$;
-- a stored screenshot: the object in the private bucket and the sha256 upload-photo recorded for it (md5(sha) || md5(sha || 'x')); returns the path (the admin a2 uploads it)
create function pg_temp.ph(prop text, nm text, sha text) returns text language plpgsql security definer as $f$
declare p text := pg_temp.id(prop)::text || '/' || pg_temp.id('a2')::text || '/' || nm;
begin
  insert into storage.objects(bucket_id, name) values ('cleaning-photos', p);
  insert into public.staff_upload_hashes(path, sha256) values (p, md5(sha) || md5(sha || 'x'));
  return p;
end $f$;
-- settle bill k/period of property prop as the admin a2 with amount amt (confirmed: the amount band is not under test here) plus the extra proof keys; the result is stored in _t under key n
create function pg_temp.settle(n text, k text, prop text, per text, amt numeric, extra jsonb default '{}'::jsonb) returns void language plpgsql as $f$
declare v_id uuid := pg_temp.bid(k, prop, per); v_proof jsonb := jsonb_build_object('path', pg_temp.ph(prop, 'zz143-' || n || '-proof-0000000000.jpg', n), 'amount', amt, 'confirmed', true) || extra; r jsonb;
begin
  perform pg_temp.as_user(pg_temp.id('a2'));
  r := pg_temp.try(format('select public.bill_pay_settle_v1(%L, %L::jsonb)', v_id, v_proof));
  reset role;
  insert into _t values (n, r);
end $f$;
-- the previous estimate body (s131, utility_bill_estimate_v1) kept here to prove the s143 estimate gives the same answer where a bill is paid
create or replace function pg_temp.old_estimate(p_property_id uuid, p_on date)
returns jsonb language plpgsql stable as $$
declare
  v_cfg jsonb := public.utility_billing_cfg_v1();
  v_ef date := public.utility_meter_from_v1(p_property_id, 'electric', p_on, v_cfg);
  v_wf date := public.utility_meter_from_v1(p_property_id, 'water', p_on, v_cfg);
  v_et date := (v_ef + interval '1 month')::date;
  v_wt date := (v_wf + interval '1 month')::date;
  v_fixed numeric := (v_cfg -> 'electric' ->> 'fixed_php')::numeric;
  v_kwh numeric; v_elast date; v_eat timestamptz; v_ed integer; v_edc integer := greatest(v_et, p_on) - v_ef; v_rate numeric;
  v_fk numeric; v_pdk numeric;
  v_m3 numeric; v_wlast date; v_wd integer; v_wdc integer := greatest(v_wt, p_on) - v_wf; v_fm numeric; v_pdm numeric; v_next jsonb;
begin
  -- s131: every counted reading after the cycle start up to p_on counts (no cut at the 21st); the forecast runs to the expected reading day, or to p_on once that day has passed
  select coalesce(sum(u.kwh), 0), max(u.d) into v_kwh, v_elast from public.utility_daily_use_v1(p_property_id, v_ef + 1, p_on) u;
  select m.recorded_at into v_eat
    from public.meter_chain_v1(p_property_id) m where m.chain_ok and m.cd > v_ef and m.cd <= p_on
   order by m.cd desc, m.recorded_at desc, m.id desc limit 1;
  v_ed := coalesce(v_elast - v_ef, 0);
  -- the billed month is the month the cycle is expected to end in (from + 1 month); no rate for it yet = the latest earlier rate, null only while no rate exists at all (rates dated after today are never read)
  select r.php_per_kwh into v_rate from public.utility_rate_by_month_v1() r where r.rate_month <= date_trunc('month', v_et)::date order by r.rate_month desc limit 1;
  if v_ed > 0 then v_pdk := v_kwh / v_ed; v_fk := v_pdk * v_edc; end if;

  select coalesce(sum(u.m3), 0), max(u.d) into v_m3, v_wlast from public.utility_daily_use_v1(p_property_id, v_wf + 1, p_on) u;
  v_wd := coalesce(v_wlast - v_wf, 0);
  if v_wd > 0 then v_pdm := v_m3 / v_wd; v_fm := v_pdm * v_wdc; end if;
  v_next := public.utility_water_next_v1(v_m3, v_cfg);

  return jsonb_build_object(
    'electric', jsonb_build_object(
      'cycle_from', v_ef, 'cycle_to', v_et, 'days', v_ed, 'days_in_cycle', v_edc, 'kwh', round(v_kwh, 2), 'rate', v_rate, 'fixed_php', v_fixed,
      'so_far_php', case when v_rate is not null then round(v_kwh * v_rate + v_fixed, 2) end,
      'forecast_kwh', case when v_ed > 0 then round(v_fk, 2) end,
      'forecast_php', case when v_ed > 0 and v_rate is not null then round(v_fk * v_rate + v_fixed, 2) end,
      'per_day_kwh', case when v_ed > 0 then round(v_pdk, 2) end,
      'per_day_php', case when v_ed > 0 and v_rate is not null then round(v_pdk * v_rate, 2) end,
      'last_reading_at', v_eat,
      'billed_month', to_char(v_et, 'YYYY-MM'), 'overdue', p_on > v_et),
    'water', jsonb_build_object(
      'cycle_from', v_wf, 'cycle_to', v_wt, 'days', v_wd, 'm3', round(v_m3, 2),
      'so_far_php', public.utility_water_php_v1(v_m3, v_cfg),
      'forecast_m3', case when v_wd > 0 then round(v_fm, 2) end,
      'forecast_php', case when v_wd > 0 then public.utility_water_php_v1(v_fm, v_cfg) end,
      'per_day_m3', case when v_wd > 0 then round(v_pdm, 2) end,
      'min_php', (v_cfg -> 'water' ->> 'min_php')::numeric, 'min_m3', (v_cfg -> 'water' ->> 'min_m3')::numeric,
      'next_php', v_next -> 'php', 'next_upto', v_next -> 'upto',
      'billed_month', to_char(v_wt, 'YYYY-MM'), 'overdue', p_on > v_wt));
end;
$$;

-- settings: the default utility_billing with open_from 2027-04-21 for both meters, the default bill_schedule, one electricity rate (10 per kWh, from October 2026)
delete from public.app_settings where key in ('utility_billing', 'bill_schedule');
insert into public.app_settings(key, value) values
  ('utility_billing', jsonb_set(jsonb_set(public.utility_billing_default_v1(), '{electric,open_from}', '"2027-04-21"'), '{water,open_from}', '"2027-04-21"'));
delete from public.utility_rates;
insert into public.utility_rates(provider, php_per_kwh, effective_from, source) values ('socoteco2', 10, date '2026-10-01', 'manual');
select pg_temp.today('2027-05-26');
-- moves the open_from anchor of each meter (the suite default is 2027-04-21 for both)
create function pg_temp.set_open(e text, w text) returns void language sql as $$
  update public.app_settings set value = jsonb_set(jsonb_set(value, '{electric,open_from}', to_jsonb(e)), '{water,open_from}', to_jsonb(w)) where key = 'utility_billing'
$$;

-- fixtures -------------------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active)
select pg_temp.id(x), 'Zz S143 ' || x, true from unnest(array['b1', 'b2', 'b3', 'b4', 'b5', 'b6', 'b7', 'b8', 'b9', 'ba', 'bb', 'bc', 'bd', 'be', 'c1', 'c2', 'c3', 'c4', 'c5']) x;
insert into auth.users(id, email, raw_user_meta_data) values
  (pg_temp.id('a1'), 'zz143-cleaner@example.com', '{"display_name":"Zz Cleaner"}'::jsonb), (pg_temp.id('a2'), 'zz143-admin@example.com', '{"display_name":"Zz Admin"}'::jsonb),
  (pg_temp.id('a5'), 'zz143-other@example.com', '{"display_name":"Zz Other"}'::jsonb), (pg_temp.id('a6'), 'zz143-owner@example.com', '{"display_name":"Zz Owner"}'::jsonb);
insert into public.staff_access_profiles(user_id, role, disabled_at) values
  (pg_temp.id('a1'), 'cleaner', null), (pg_temp.id('a2'), 'admin', null), (pg_temp.id('a5'), 'cleaner', null), (pg_temp.id('a6'), 'owner', null);
insert into public.staff_property_access(user_id, property_id)
select pg_temp.id('a2'), pg_temp.id(x) from unnest(array['b1', 'b2', 'b3', 'b4', 'b5', 'b6', 'b7', 'b8', 'b9', 'ba', 'bb', 'bc', 'bd', 'be', 'c1', 'c2', 'c3', 'c4', 'c5']) x;
insert into public.staff_property_access(user_id, property_id) values
  (pg_temp.id('a1'), pg_temp.id('b8')), (pg_temp.id('a1'), pg_temp.id('ba')), (pg_temp.id('a5'), pg_temp.id('b1')), (pg_temp.id('a6'), pg_temp.id('b6'));
insert into public.expense_categories(property_id, slug, label, sort_order) values (pg_temp.id('b6'), 'supplies', 'Supplies', 1), (pg_temp.id('b6'), 'utilities', 'Utilities', 2) on conflict do nothing;

-- 1. month-end anchors (31 Jan -> 28 Feb -> 31 Mar) ----------------------------------------------------------------------------------------------------------------------------------------
-- add_months keeps the ANCHOR day: 31 Jan + 1 = 28 Feb, + 2 = 31 Mar (not 28 Mar), + 3 = 30 Apr; leap year 31 Jan 2028 + 1 = 29 Feb.
select ok(public.utility_add_months_v1(date '2027-01-31', 1) = date '2027-02-28' and public.utility_add_months_v1(date '2027-01-31', 2) = date '2027-03-31'
          and public.utility_add_months_v1(date '2027-01-31', 3) = date '2027-04-30' and public.utility_add_months_v1(date '2028-01-31', 1) = date '2028-02-29'
          and public.utility_add_months_v1(date '2027-05-21', 1) = date '2027-06-21' and public.utility_add_months_v1(date '2027-11-30', 3) = date '2028-02-29',
          'add_months: 31 Jan -> 28 Feb -> 31 Mar -> 30 Apr, leap year 29 Feb, the anchor day is kept');
-- p1 electric: 2027-01 is paid with the REAL reading 31 Jan; 2027-02 and 2027-03 are due with no date. The two assumed dates are 28 Feb (from 31 Jan) and 31 Mar (from 28 Feb: the 31st is kept, not the clamped 28th).
insert into public.utility_bills(property_id, kind, period, estimate_php, status, paid_php, paid_at, paid_by_name, proof_verdict, reading_date)
values (pg_temp.id('b1'), 'electric', '2027-01', 1000, 'paid', 1000, now(), 'Zz Admin', 'typed', date '2027-01-31');
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('b1'), 'electric', '2027-02', 1000, 'due'), (pg_temp.id('b1'), 'electric', '2027-03', 1000, 'due');
select is((select string_agg(r.period || ' ' || r.row_from || '>' || r.row_to || ' ' || case when r.to_assumed then 'assumed' else 'real' end, '; ' order by r.period) from public.utility_meter_rows_v1(pg_temp.id('b1'), 'electric') r),
          '2027-01 2027-04-21>2027-01-31 real; 2027-02 2027-01-31>2027-02-28 assumed; 2027-03 2027-02-28>2027-03-31 assumed',
          'row spans: 2027-02 ends 28 Feb and 2027-03 ends 31 Mar, each starting where the row before ends (the first row starts at open_from)');
select ok((select c.cycle_from = date '2027-02-28' and c.from_assumed and c.cycle_to = date '2027-03-31' from public.utility_meter_cycle_v1(pg_temp.id('b1'), 'electric', date '2027-03-05', public.utility_billing_cfg_v1()) c)
          and (select c.cycle_from = date '2027-03-31' and c.from_assumed and c.cycle_to = date '2027-04-30' from public.utility_meter_cycle_v1(pg_temp.id('b1'), 'electric', date '2027-03-31', public.utility_billing_cfg_v1()) c)
          and (select c.cycle_from = date '2027-01-31' and not c.from_assumed and c.cycle_to = date '2027-02-28' from public.utility_meter_cycle_v1(pg_temp.id('b1'), 'electric', date '2027-02-10', public.utility_billing_cfg_v1()) c),
          'open cycle: on 5 Mar it runs 28 Feb (assumed) to 31 Mar; on 31 Mar it has moved to 31 Mar (assumed) to 30 Apr; on 10 Feb it is the real 31 Jan to 28 Feb');

-- 2. assumed -> real date recompute ------------------------------------------------------------------------------------------------------------------------------------------------------------
-- p2 water, no bill, today 26 May 2027, open_from 21 Apr: the cycle is 21 May (assumed) to 21 Jun. A water bill with the REAL reading 24 May (any status: it is only due) moves it to 24 May (real) to 24 Jun.
select ok((select e #>> '{water,cycle_from}' = '2027-05-21' and e #>> '{water,cycle_to}' = '2027-06-21' from (select public.utility_bill_estimate_v1(pg_temp.id('b2'), date '2027-05-26') e) x)
          and (select c.from_assumed from public.utility_meter_cycle_v1(pg_temp.id('b2'), 'water', date '2027-05-26', public.utility_billing_cfg_v1()) c),
          'no bill yet: the water cycle is the assumed 21 May to 21 Jun');
insert into public.utility_bills(property_id, kind, period, estimate_php, status, reading_date) values (pg_temp.id('b2'), 'water', '2027-05', 300, 'due', date '2027-05-24');
select ok((select e #>> '{water,cycle_from}' = '2027-05-24' and e #>> '{water,cycle_to}' = '2027-06-24' from (select public.utility_bill_estimate_v1(pg_temp.id('b2'), date '2027-05-26') e) x)
          and (select not c.from_assumed from public.utility_meter_cycle_v1(pg_temp.id('b2'), 'water', date '2027-05-26', public.utility_billing_cfg_v1()) c),
          'a real reading date on a DUE bill (24 May) replaces the assumed one: the cycle is the real 24 May to 24 Jun');
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'tb2', pg_temp.try($$select public.today_bills_v1('e1430000-0000-4000-8000-0000000000b2')$$);
reset role;
select ok((select v #>> '{water,cycle_from}' = '2027-05-24' and (v #>> '{water,cycle_from_assumed}')::boolean = false and v #>> '{water,next_reading}' = '2027-06-24'
                  and v ->> 'water_since' = '2027-05-24' from _t where k = 'tb2'),
          'today_bills_v1: water.cycle_from 24 May, cycle_from_assumed false, next_reading 24 Jun (water_since follows)');

-- 3. a reading that slips over a month end does not create a second row -------------------------------------------------------------------------------------------------------------------------
-- p3 electric: 2027-01 paid with 31 Jan, nothing open. Today 2 Mar 2027. The reading is taken on 1 Mar (the cycle that should have closed on 28 Feb): the new row is 2027-02, not 2027-03.
select pg_temp.today('2027-03-02');
insert into public.utility_bills(property_id, kind, period, estimate_php, status, paid_php, paid_at, paid_by_name, proof_verdict, reading_date)
values (pg_temp.id('b3'), 'electric', '2027-01', 1000, 'paid', 1000, now(), 'Zz Admin', 'typed', date '2027-01-31');
insert into _t select 's3a', pg_temp.rs('a2', pg_temp.id('b3'), 'electric', date '2027-03-01');
select ok((select (v ->> 'ok')::boolean and v ->> 'period' = '2027-02' and v ->> 'from' = '2027-01-31' and v ->> 'to' = '2027-03-01' and v ->> 'next_reading' = '2027-04-01' and not (v ->> 'preview')::boolean from _t where k = 's3a')
          and (select count(*) = 2 and bool_or(period = '2027-02' and reading_date = date '2027-03-01' and status = 'due') from public.utility_bills where property_id = pg_temp.id('b3') and kind = 'electric'),
          'a 1 Mar reading with nothing open creates 2027-02 (the month of the assumed 28 Feb), from 31 Jan to 1 Mar, next reading 1 Apr: two rows in all');
insert into _t select 's3b', pg_temp.rs('a2', pg_temp.id('b3'), 'electric', date '2027-03-02');
select public.bill_due_open_v1(pg_temp.id('b3'), date '2027-02-25', '2027-01');
select ok((select (v ->> 'ok')::boolean and v ->> 'period' = '2027-02' and v ->> 'bill_id' = (select id::text from public.utility_bills where property_id = pg_temp.id('b3') and kind = 'electric' and period = '2027-02') from _t where k = 's3b')
          and (select count(*) = 2 from public.utility_bills where property_id = pg_temp.id('b3') and kind = 'electric')
          and (select reading_date = date '2027-03-02' from public.utility_bills where property_id = pg_temp.id('b3') and kind = 'electric' and period = '2027-02'),
          'a second call (2 Mar) and the daily opener (bill_due_open_v1 on 25 Feb) both keep one 2027-02 row: still two rows, the date moved to 2 Mar');
select ok((select c.cycle_from = date '2027-03-02' and not c.from_assumed and c.cycle_to = date '2027-04-02' from public.utility_meter_cycle_v1(pg_temp.id('b3'), 'electric', date '2027-03-02', public.utility_billing_cfg_v1()) c),
          'after the reading the next cycle starts on the real 2 Mar and ends 2 Apr');
select pg_temp.today('2027-05-26');

-- 4. preview writes nothing -------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- p4 electric: a first reading on 10 May of 30 kWh (it lands on its own day). Preview 22 May with no bill: ok, preview true, no bill_id, period 2027-05; so far for 22 Apr .. 22 May = 30 kWh x 10 + the fixed charge.
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('e1'), null, pg_temp.id('b4'), timestamptz '2027-05-10 09:00+08', 1000, 1030, 50, 30, 3.0, null);
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('b4'), 'water', '2027-05', 300, 'due');
insert into _t select 's4a', pg_temp.rs('a2', pg_temp.id('b4'), 'electric', date '2027-05-22', 1234.5, true);
insert into _t select 's4b', pg_temp.rs('a2', pg_temp.id('b4'), 'water', date '2027-05-22', null, true);
select ok((select (v ->> 'ok')::boolean and (v ->> 'preview')::boolean and v ->> 'bill_id' is null and v ->> 'period' = '2027-05' and v ->> 'from' = '2027-04-21' and v ->> 'to' = '2027-05-22'
                  and (v ->> 'estimate_php')::numeric = 300 + (public.utility_billing_cfg_v1() #>> '{electric,fixed_php}')::numeric from _t where k = 's4a')
          and (select count(*) = 0 from public.utility_bills where property_id = pg_temp.id('b4') and kind = 'electric'),
          'preview with no open bill: estimate = 30 kWh x 10 + fixed, period 2027-05, from 21 Apr to 22 May, bill_id null, and no row is written');
select ok((select (v ->> 'ok')::boolean and (v ->> 'preview')::boolean and v ->> 'bill_id' = pg_temp.bid('water', 'b4', '2027-05')::text from _t where k = 's4b')
          and (select reading_date is null and reading_value is null and estimate_php = 300 from public.utility_bills where id = pg_temp.bid('water', 'b4', '2027-05')),
          'preview on an open bill returns its id and leaves date, value and estimate untouched');
insert into _t select 's4c', pg_temp.rs('a2', pg_temp.id('b4'), 'water', date '2027-05-22', 88.5, false);
select ok((select (v ->> 'ok')::boolean and not (v ->> 'preview')::boolean from _t where k = 's4c')
          and (select reading_date = date '2027-05-22' and reading_value = 88.5 and estimate_php is not null from public.utility_bills where id = pg_temp.bid('water', 'b4', '2027-05')),
          'the same call without preview stores the date, the value (88.5) and a new estimate');

-- 5. settle keeps a pre-set reading ---------------------------------------------------------------------------------------------------------------------------------------------------------------
-- p5 water 2027-05: the date 22 May and the value 123.45 are set first; the settle proof carries neither: both stay. paid_on and method are absent: the ledger row is dated today (26 May), method null, category utilities.
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('b5'), 'water', '2027-05', 300, 'due');
insert into _t select 's5a', pg_temp.rs('a2', pg_temp.id('b5'), 'water', date '2027-05-22', 123.45);
select pg_temp.settle('s5b', 'water', 'b5', '2027-05', 310);
select ok((select (v ->> 'ok')::boolean and v ->> 'reading_date' = '2027-05-22' from _t where k = 's5b')
          and (select status = 'paid' and reading_date = date '2027-05-22' and reading_value = 123.45 from public.utility_bills where id = pg_temp.bid('water', 'b5', '2027-05'))
          and (select t.transaction_date = date '2027-05-26' and t.payment_method is null and t.category = 'utilities' and t.gross_amount = 310
                 from public.utility_bills b join public.transactions t on t.id = b.txn_id where b.id = pg_temp.bid('water', 'b5', '2027-05')),
          'settle with no reading_date / reading_value in the proof keeps the pre-set 22 May and 123.45; the ledger row is dated today, no method, category utilities');
select ok((select v #>> '{bill,from}' = '2027-04-21' and v #>> '{bill,to}' = '2027-05-22' and v #>> '{bill,to_assumed}' = 'false' and v #>> '{bill,paid_on}' = '2027-05-26' from _t where k = 's5b'),
          'the paid bill in the settle answer carries from 21 Apr, to 22 May (real), paid_on 26 May');

-- 6. paid_on bounds, method, category by kind ---------------------------------------------------------------------------------------------------------------------------------------------------
-- p6 electric 2027-05 (reading date 22 May in the proof): paid_on 21 May is before the reading date, 27 May is after today (26 May), "garbage" is no date: paid_on_invalid, nothing stored.
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('b6'), 'electric', '2027-05', 1000, 'due');
select pg_temp.settle('s6a', 'electric', 'b6', '2027-05', 1000, '{"reading_date": "2027-05-22", "paid_on": "2027-05-21"}');
select pg_temp.settle('s6b', 'electric', 'b6', '2027-05', 1000, '{"reading_date": "2027-05-22", "paid_on": "2027-05-27"}');
select pg_temp.settle('s6c', 'electric', 'b6', '2027-05', 1000, '{"reading_date": "2027-05-22", "paid_on": "garbage"}');
select ok((select bool_and(v = '{"ok":false,"reason":"paid_on_invalid"}'::jsonb) from _t where k in ('s6a', 's6b', 's6c'))
          and (select status = 'due' and reading_date is null and txn_id is null from public.utility_bills where id = pg_temp.bid('electric', 'b6', '2027-05'))
          and (select count(*) = 0 from public.transactions where external_ref = 'bill:electric:2027-05'),
          'paid_on before the reading date (21 May), after today (27 May) or not a date: paid_on_invalid, the bill stays due, no ledger row');
-- on or after the reading date and up to today is fine: 22 May (= the reading date) is the lower edge. A method in capitals is stored lower case.
select pg_temp.settle('s6d', 'electric', 'b6', '2027-05', 1000, '{"reading_date": "2027-05-22", "paid_on": "2027-05-22", "method": "GCash"}');
select ok((select (v ->> 'ok')::boolean and v #>> '{bill,paid_on}' = '2027-05-22' from _t where k = 's6d')
          and (select t.transaction_date = date '2027-05-22' and t.payment_method = 'gcash' and t.category = 'utilities' from public.utility_bills b join public.transactions t on t.id = b.txn_id where b.id = pg_temp.bid('electric', 'b6', '2027-05')),
          'paid_on = the reading date (22 May) and method GCash: the ledger row is dated 22 May, method gcash, category utilities');
-- internet and Netflix take their own category; method cash / bank; paid_on absent = today
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('b6'), 'internet', '2027-05', 1500, 'due'), (pg_temp.id('b6'), 'netflix', '2027-05', 449, 'due');
select pg_temp.settle('s6e', 'internet', 'b6', '2027-05', 1500, '{"method": "cash"}');
select pg_temp.settle('s6f', 'netflix', 'b6', '2027-05', 449, '{"method": "bank", "paid_on": "2027-05-25"}');
select ok((select (v ->> 'ok')::boolean from _t where k = 's6e') and (select (v ->> 'ok')::boolean from _t where k = 's6f')
          and (select t.category = 'internet' and t.payment_method = 'cash' and t.transaction_date = date '2027-05-26' from public.transactions t where t.external_ref = 'bill:internet:2027-05')
          and (select t.category = 'subscription' and t.payment_method = 'bank' and t.transaction_date = date '2027-05-25' from public.transactions t where t.external_ref = 'bill:netflix:2027-05'),
          'category by kind: internet -> internet (cash, today), netflix -> subscription (bank, 25 May)');
-- p7: a method outside the list is refused, nothing stored
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('b7'), 'netflix', '2027-04', 449, 'due');
select pg_temp.settle('s7a', 'netflix', 'b7', '2027-04', 449, '{"method": "paypal"}');
select pg_temp.settle('s7b', 'netflix', 'b7', '2027-04', 449, '{"method": 5}');
select ok((select bool_and(v = '{"ok":false,"reason":"bad_method"}'::jsonb) from _t where k in ('s7a', 's7b'))
          and (select status = 'due' and txn_id is null from public.utility_bills where id = pg_temp.bid('netflix', 'b7', '2027-04'))
          and (select count(*) = 0 from public.transactions where external_ref = 'bill:netflix:2027-04'),
          'bad_method: "paypal" and a number are refused, the bill stays due, no ledger row');

-- 7. refusals by role and by input -------------------------------------------------------------------------------------------------------------------------------------------------------------
-- p8 water: 2027-05 open. A cleaner of the property (no approve_payment), a cleaner of ANOTHER property and a null property are refused not_authorized; anon cannot run the function at all.
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('b8'), 'water', '2027-05', 300, 'due');
insert into _t select 'r1', pg_temp.rs('a1', pg_temp.id('b8'), 'water', date '2027-05-22');
insert into _t select 'r2', pg_temp.rs('a5', pg_temp.id('b8'), 'water', date '2027-05-22');
insert into _t select 'r3', pg_temp.rs('a2', null, 'water', date '2027-05-22');
select pg_temp.as_anon();
insert into _t select 'r4', pg_temp.try($$select public.bill_reading_set_v1('e1430000-0000-4000-8000-0000000000b8', 'water', date '2027-05-22')$$);
reset role;
select ok((select bool_and(v = '{"ok":false,"reason":"not_authorized"}'::jsonb) from _t where k in ('r1', 'r2', 'r3'))
          and (select v ->> 'err' = '42501' from _t where k = 'r4')
          and (select reading_date is null from public.utility_bills where id = pg_temp.bid('water', 'b8', '2027-05')),
          'refusals by role: a cleaner, a cleaner of another property and a null property get not_authorized; anon gets 42501; nothing is written');
-- input refusals as the admin (all leave the bill untouched): internet is no meter; a negative value; a date at open_from (21 Apr) is not after it; a date after today (27 May)
insert into _t select 'i1', pg_temp.rs('a2', pg_temp.id('b8'), 'internet', date '2027-05-22');
insert into _t select 'i2', pg_temp.rs('a2', pg_temp.id('b8'), 'water', date '2027-05-22', -1);
insert into _t select 'i3', pg_temp.rs('a2', pg_temp.id('b8'), 'water', date '2027-04-21');
insert into _t select 'i4', pg_temp.rs('a2', pg_temp.id('b8'), 'water', date '2027-05-27');
select ok((select v = '{"ok":false,"reason":"bad_kind"}'::jsonb from _t where k = 'i1') and (select v = '{"ok":false,"reason":"reading_value_invalid"}'::jsonb from _t where k = 'i2')
          and (select v = '{"ok":false,"reason":"reading_date_invalid","after":"2027-04-21"}'::jsonb from _t where k = 'i3')
          and (select v = '{"ok":false,"reason":"reading_date_invalid","before":"2027-05-27"}'::jsonb from _t where k = 'i4')
          and (select reading_date is null from public.utility_bills where id = pg_temp.bid('water', 'b8', '2027-05')),
          'bad_kind; reading_value_invalid; reading_date_invalid with after = 2027-04-21 (not after open_from) and before = 2027-05-27 (after today); the bill is untouched');
-- upper bound from a later bill of ANY status: p8 gets 2027-06 with the real date 1 Jun (only due), today moves to 1 Jul: a date on or after 1 Jun for the older 2027-05 bill is refused with before = 2027-06-01
select pg_temp.today('2027-07-01');
insert into public.utility_bills(property_id, kind, period, estimate_php, status, reading_date) values (pg_temp.id('b8'), 'water', '2027-06', 300, 'due', date '2027-06-01');
insert into _t select 'u1', pg_temp.rs('a2', pg_temp.id('b8'), 'water', date '2027-06-01');
insert into _t select 'u2', pg_temp.rs('a2', pg_temp.id('b8'), 'water', date '2027-05-31');
select ok((select v = '{"ok":false,"reason":"reading_date_invalid","before":"2027-06-01"}'::jsonb from _t where k = 'u1')
          and (select (v ->> 'ok')::boolean and v ->> 'period' = '2027-05' from _t where k = 'u2'),
          'a later DUE bill with a real date (1 Jun) bounds the older bill: 1 Jun is refused with before = 2027-06-01, 31 May is saved');
-- p9b water 2027-05 is open with no date (assumed 21 May); on 1 Jul a reading of 25 Jun belongs to the next cycle (21 May + 1 month = 21 Jun)
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('bc'), 'water', '2027-05', 300, 'due');
insert into _t select 'o1', pg_temp.rs('a2', pg_temp.id('bc'), 'water', date '2027-06-25');
insert into _t select 'o2', pg_temp.rs('a2', pg_temp.id('bc'), 'water', date '2027-06-20');
-- s143: the open 2027-05 bill is the oldest open one, so a reading past its next cycle is a DATE problem (reading_date_invalid with before = 21 Jun), never older_bill_open (there is no older bill to settle)
select ok((select v = '{"ok":false,"reason":"reading_date_invalid","before":"2027-06-21"}'::jsonb from _t where k = 'o1') and (select (v ->> 'ok')::boolean from _t where k = 'o2'),
          's143: a reading of 25 Jun on the oldest undated 2027-05 bill is reading_date_invalid with before = 2027-06-21 (not older_bill_open); 20 Jun is still its cycle and is saved');
-- already_paid: the date of a paid bill is closed
insert into public.utility_bills(property_id, kind, period, estimate_php, status, paid_php, paid_at, paid_by_name, proof_verdict, reading_date)
values (pg_temp.id('bd'), 'water', '2027-05', 300, 'paid', 300, now(), 'Zz Admin', 'typed', date '2027-05-10');
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('bd'), 'water', '2027-06', 300, 'due');
insert into _t select 'p1', pg_temp.rs('a2', pg_temp.id('bd'), 'water', date '2027-05-10');
select ok((select v = '{"ok":false,"reason":"already_paid"}'::jsonb from _t where k = 'p1')
          and (select reading_date is null from public.utility_bills where id = pg_temp.bid('water', 'bd', '2027-06')),
          'already_paid: the reading date of a paid bill (10 May) cannot be set again');
select pg_temp.today('2027-05-26');

-- 8. a skipped bill keeps its boundary ------------------------------------------------------------------------------------------------------------------------------------------------------------
-- p9 water 2027-05 is SKIPPED with the real reading 23 May: the boundary stays (cycle from 23 May real). p9 electric: two skipped / due rows with no date use one slot each: 21 May and 21 Jun, the second starting 21 May.
insert into public.utility_bills(property_id, kind, period, estimate_php, status, reading_date) values (pg_temp.id('b9'), 'water', '2027-05', 300, 'skipped', date '2027-05-23');
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('b9'), 'electric', '2027-05', 1000, 'skipped'), (pg_temp.id('b9'), 'electric', '2027-06', 1000, 'due');
select ok((select r.row_to = date '2027-05-23' and not r.to_assumed from public.utility_meter_rows_v1(pg_temp.id('b9'), 'water') r where r.period = '2027-05')
          and (select e #>> '{water,cycle_from}' = '2027-05-23' and e #>> '{water,cycle_to}' = '2027-06-23' from (select public.utility_bill_estimate_v1(pg_temp.id('b9'), date '2027-05-26') e) x)
          and (select string_agg(r.period || ' ' || r.row_from || '>' || r.row_to, '; ' order by r.period) = '2027-05 2027-04-21>2027-05-21; 2027-06 2027-05-21>2027-06-21' from public.utility_meter_rows_v1(pg_temp.id('b9'), 'electric') r),
          'a skipped bill with a real reading date keeps its boundary (water cycle from 23 May); skipped and due rows with no date still use one slot each (21 May, 21 Jun)');

-- 9. an old client calling today_bills_v1 sees every existing key ------------------------------------------------------------------------------------------------------------------------------------
-- p10: water 2027-04 is paid on 25 May (reading 21 May, method gcash); electric 2027-04 is due. The s131 shape is { since, water_since, waiting_for, water_waiting_for, last_reading_at, electric {php,kwh}, water {php,m3}, can_pay_list, check_bills, due }.
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('ba'), 'water', '2027-04', 300, 'due'), (pg_temp.id('ba'), 'electric', '2027-04', 1000, 'due');
select pg_temp.settle('s10a', 'water', 'ba', '2027-04', 300, '{"reading_date": "2027-05-21", "paid_on": "2027-05-25", "method": "gcash"}');
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'tb_admin', pg_temp.try($$select public.today_bills_v1('e1430000-0000-4000-8000-0000000000ba')$$);
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 'tb_clean', pg_temp.try($$select public.today_bills_v1('e1430000-0000-4000-8000-0000000000ba')$$);
reset role;
select ok((select v ?& array['since', 'water_since', 'waiting_for', 'water_waiting_for', 'last_reading_at', 'electric', 'water', 'can_pay_list', 'check_bills', 'due']
                  and v -> 'electric' ?& array['php', 'kwh'] and v -> 'water' ?& array['php', 'm3'] from _t where k = 'tb_admin')
          and (select v ?& array['since', 'water_since', 'waiting_for', 'water_waiting_for', 'last_reading_at', 'electric', 'water', 'can_pay_list', 'check_bills', 'due']
                  and v -> 'electric' ?& array['php', 'kwh'] and v -> 'water' ?& array['php', 'm3'] from _t where k = 'tb_clean'),
          'old client: every key of the s131 payload is still there (top level, electric {php,kwh}, water {php,m3}) for an admin and for a cleaner');
select ok((select v ->> 'since' = '2027-05-21' and v ->> 'water_since' = '2027-05-21' and v ->> 'waiting_for' is null and v ->> 'water_waiting_for' is null and (v ->> 'can_pay_list')::boolean
                  and (v #>> '{electric,cycle_from_assumed}')::boolean and not (v #>> '{water,cycle_from_assumed}')::boolean
                  and v #>> '{electric,next_reading}' = '2027-06-21' and v #>> '{water,next_reading}' = '2027-06-21' from _t where k = 'tb_admin'),
          'since / water_since 21 May; waiting_for stays a key and is null; electric is assumed (21 Apr + 1 month), water real (21 May); next_reading 21 Jun for both');
select ok((select jsonb_array_length(v -> 'due') = 1 and v #>> '{due,0,kind}' = 'electric' and v #>> '{due,0,from}' = '2027-04-21' and v #>> '{due,0,to}' = '2027-05-21' and (v #>> '{due,0,to_assumed}')::boolean
                  and v #> '{due,0,paid_on}' = 'null'::jsonb from _t where k = 'tb_admin'),
          'due[] holds the open electric bill only (the paid water bill left it), with from 21 Apr, to 21 May (assumed), paid_on null');
select ok((select v #>> '{water,last_bill,paid_on}' = '2027-05-25' and v #>> '{water,last_bill,status}' = 'paid' and v #>> '{water,last_bill,from}' = '2027-04-21' and v #>> '{water,last_bill,to}' = '2027-05-21'
                  and not (v #>> '{water,last_bill,to_assumed}')::boolean and (v #>> '{water,last_bill,has_proof}')::boolean and v #>> '{water,last_bill,paid_by_name}' = 'Zz Admin'
                  and v #>> '{electric,last_bill,status}' = 'due' and (v #>> '{electric,last_bill,to_assumed}')::boolean
                  and jsonb_array_length(v -> 'last_paid') = 1 and v #>> '{last_paid,0,kind}' = 'water' and v #>> '{last_paid,0,paid_on}' = '2027-05-25' and (v #>> '{last_paid,0,paid_php}')::numeric = 300 from _t where k = 'tb_admin'),
          'last_bill: water paid on 25 May for 21 Apr to 21 May (real, with proof, by Zz Admin), electric still due and assumed; last_paid lists water only');
select ok((select not (v ? 'last_paid') and not (v -> 'electric' ? 'last_bill') and not (v -> 'water' ? 'last_bill') and v -> 'due' = '[]'::jsonb and not (v ->> 'can_pay_list')::boolean
                  and v #>> '{water,cycle_from}' = '2027-05-21' and v #>> '{electric,next_reading}' = '2027-06-21' from _t where k = 'tb_clean'),
          'a cleaner gets no last_bill, no last_paid and due [], but the cycle keys');

-- 10. kpi_tab_v1 unchanged for a month with paid bills ------------------------------------------------------------------------------------------------------------------------------------------------
-- p11: electric and water 2027-04 are paid with the real reading 21 May; 40 kWh / 2 m3 are counted on 23 May. The s143 estimate equals the s131 body (kept above) for today (26 May) and kpi_tab_v1 carries it as admin.bills.
insert into public.utility_bills(property_id, kind, period, estimate_php, status, paid_php, paid_at, paid_by_name, proof_verdict, reading_date) values
  (pg_temp.id('bb'), 'electric', '2027-04', 1000, 'paid', 1000, now(), 'Zz Admin', 'typed', date '2027-05-21'), (pg_temp.id('bb'), 'water', '2027-04', 300, 'paid', 300, now(), 'Zz Admin', 'typed', date '2027-05-21');
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('e2'), null, pg_temp.id('bb'), timestamptz '2027-05-23 09:00+08', 1000, 1040, 50, 40, 2.0, null);
insert into public.staff_property_access(user_id, property_id) values (pg_temp.id('a6'), pg_temp.id('bb')) on conflict do nothing;
select pg_temp.as_user(pg_temp.id('a6'));
insert into _t select 'kpi2', pg_temp.try($$select public.kpi_tab_v1('e1430000-0000-4000-8000-0000000000bb')$$);
reset role;
select ok(public.utility_bill_estimate_v1(pg_temp.id('bb'), date '2027-05-26') = pg_temp.old_estimate(pg_temp.id('bb'), date '2027-05-26')
          and (public.utility_bill_estimate_v1(pg_temp.id('bb'), date '2027-05-26') #>> '{electric,kwh}')::numeric = 40,
          'for paid bills the s143 estimate is identical to the s131 one (40 kWh counted since the real 21 May)');
select ok((select v -> 'admin' -> 'bills' = public.utility_bill_estimate_v1(pg_temp.id('bb'), date '2027-05-26') from _t where k = 'kpi2'),
          'kpi_tab_v1 (owner) carries the unchanged estimate as admin.bills');

-- 11. expenses: method, by, covers, title; admin_save_transaction_v2 payment_method --------------------------------------------------------------------------------------------------------------------
-- p6 holds the paid electricity bill (22 May, gcash, by Zz Admin), the internet bill (cash) and the Netflix bill (bank).
select pg_temp.as_user(pg_temp.id('a6'));
insert into _t select 'x1', pg_temp.try($$select public.expenses_screen_v1('e1430000-0000-4000-8000-0000000000b6', date '2027-05-01')$$);
insert into _t select 'x2', pg_temp.try($$select public.admin_save_transaction_v2('e1430000-0000-4000-8000-0000000000b6', '{"txn_type":"expense","category":"supplies","gross_amount":55,"transaction_date":"2027-05-24","payee_name":"Zz Shop","payment_method":"Cash"}'::jsonb, 'zz143-save-key-00000001')$$);
insert into _t select 'x3', pg_temp.try($$select public.admin_save_transaction_v2('e1430000-0000-4000-8000-0000000000b6', '{"txn_type":"expense","category":"supplies","gross_amount":56,"transaction_date":"2027-05-24","payment_method":"paypal"}'::jsonb, 'zz143-save-key-00000002')$$);
reset role;
select ok((select r ->> 'title' = 'Electricity bill' and r ->> 'method' = 'gcash' and r ->> 'by' = 'Zz Admin' and r #>> '{covers,from}' = '2027-04-21' and r #>> '{covers,to}' = '2027-05-22'
             from _t, jsonb_array_elements(v -> 'rows') r where k = 'x1' and r ->> 'source' = 'bill' and r ->> 'title' = 'Electricity bill'),
          'expenses_screen_v1: the electricity bill row has title "Electricity bill", method gcash, by Zz Admin and covers 21 Apr to 22 May');
select ok((select r ->> 'title' = 'Internet bill' and r ->> 'method' = 'cash' and r ->> 'covers' is null and r ->> 'by' = 'Zz Admin' from _t, jsonb_array_elements(v -> 'rows') r where k = 'x1' and r ->> 'title' = 'Internet bill')
          and (select r ->> 'title' = 'Netflix bill' and r ->> 'method' = 'bank' from _t, jsonb_array_elements(v -> 'rows') r where k = 'x1' and r ->> 'title' = 'Netflix bill'),
          'internet and Netflix rows: title by kind, method, no covers');
select ok((select (v ->> 'ok')::boolean from _t where k = 'x2') and (select v = '{"ok":false,"error":"bad_method"}'::jsonb from _t where k = 'x3')
          and (select t.payment_method = 'cash' from public.transactions t where t.id = (select (v ->> 'id')::uuid from _t where k = 'x2'))
          and (select count(*) = 0 from public.transactions where property_id = pg_temp.id('b6') and gross_amount = 56),
          'admin_save_transaction_v2: create with payment_method "Cash" stores cash; "paypal" is refused with bad_method and writes nothing');
select pg_temp.as_user(pg_temp.id('a6'));
insert into _t select 'x4', pg_temp.try(format($q$select public.admin_save_transaction_v2('e1430000-0000-4000-8000-0000000000b6', jsonb_build_object('id', %L, 'payment_method', 'bank', 'reason', 'zz143 method'), null)$q$, (select v ->> 'id' from _t where k = 'x2')));
insert into _t select 'x5', pg_temp.try($$select public.expenses_screen_v1('e1430000-0000-4000-8000-0000000000b6', date '2027-05-01')$$);
insert into _t select 'x6', pg_temp.try(format($q$select public.admin_save_transaction_v2('e1430000-0000-4000-8000-0000000000b6', jsonb_build_object('id', %L, 'payment_method', '', 'reason', 'zz143 clear'), null)$q$, (select v ->> 'id' from _t where k = 'x2')));
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'x4') and (select (v ->> 'ok')::boolean from _t where k = 'x6')
          and (select r ->> 'method' = 'bank' and r ->> 'title' = 'Zz Shop' and r ->> 'by' is null from _t, jsonb_array_elements(v -> 'rows') r where k = 'x5' and r ->> 'id' = (select v ->> 'id' from _t where k = 'x2'))
          and (select t.payment_method is null from public.transactions t where t.id = (select (v ->> 'id')::uuid from _t where k = 'x2')),
          'edit sets the method (bank, shown in the screen with title = payee and by null for an admin-logged row); an empty payment_method clears it');

-- 13. fix round 1: calendar slots, orphan notices, edges ------------------------------------------------------------------------------------------------------------------------------------------
-- c1 water: 2027-05 has the REAL reading 21 May (due), 2027-06 was never opened, 2027-07 is due with no date. The slot is the calendar distance to the anchor row (07 - 05 = 2 months), not the one undated row:
-- 2027-07 ends 21 Jul (not 21 Jun, which would put the whole cycle a month early) and starts where 2027-05 ends.
insert into public.utility_bills(property_id, kind, period, estimate_php, status, reading_date) values (pg_temp.id('c1'), 'water', '2027-05', 300, 'due', date '2027-05-21');
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('c1'), 'water', '2027-07', 300, 'due');
select is((select string_agg(r.period || ' ' || r.row_from || '>' || r.row_to || ' ' || case when r.to_assumed then 'assumed' else 'real' end, '; ' order by r.period) from public.utility_meter_rows_v1(pg_temp.id('c1'), 'water') r),
          '2027-05 2027-04-21>2027-05-21 real; 2027-07 2027-05-21>2027-07-21 assumed',
          'a missing middle period (2027-06) keeps its calendar slot: 2027-07 ends 21 Jul, starting at the real 21 May');

-- c2: bill_daily_v1 writes the one notice of every open bill that has none (a row bill_reading_set_v1 created has notice_id null and is never opened again by bill_due_open_v1).
-- 24 May is before the remind day 25, so the opener looks at 2027-04 (all four rows exist, three skipped): nothing opens. Orphans: electric 2027-04 (a month back: "is overdue.") and water 2027-05 ("bill: due by the 27th.").
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values
  (pg_temp.id('c2'), 'electric', '2027-04', 1000, 'due'), (pg_temp.id('c2'), 'water', '2027-04', 300, 'skipped'), (pg_temp.id('c2'), 'internet', '2027-04', 1500, 'skipped'), (pg_temp.id('c2'), 'netflix', '2027-04', 449, 'skipped'),
  (pg_temp.id('c2'), 'water', '2027-05', 300, 'due');
insert into _t select 'd1', public.bill_daily_v1(date '2027-05-24', pg_temp.id('c2'));
insert into _t select 'd2', public.bill_daily_v1(date '2027-05-24', pg_temp.id('c2'));
select ok((select (v ->> 'bills_opened')::integer = 0 and (v ->> 'notices_written')::integer = 2 from _t where k = 'd1')
          and (select array_agg(n.title order by n.title) = array['Electricity (SOCOTECO II) is overdue.', 'Water (Gensan Water District) bill: due by the 27th.'] from public.ops_notices n where n.property_id = pg_temp.id('c2') and n.source = 'system')
          and (select count(*) = 2 and bool_and(notice_id is not null) from public.utility_bills where property_id = pg_temp.id('c2') and status = 'due'),
          'bill_daily_v1 writes the missing notice of each open bill with notice_id null: "Electricity ... is overdue." (2027-04) and "Water ... bill: due by the 27th." (2027-05); notice_id is set');
select ok((select (v ->> 'bills_opened')::integer = 0 and (v ->> 'notices_written')::integer = 0 from _t where k = 'd2')
          and (select count(*) = 2 from public.ops_notices n where n.property_id = pg_temp.id('c2') and n.source = 'system'),
          'a second run writes no notice again: once only');

-- paid_on is bounded below for EVERY kind (the 1st of the month before the billed period): b7 Netflix 2027-04 may not be paid on 28 Feb (a year typo), 1 Mar is the lower edge
select pg_temp.settle('s13a', 'netflix', 'b7', '2027-04', 449, '{"paid_on": "2027-02-28"}');
select pg_temp.settle('s13b', 'netflix', 'b7', '2027-04', 449, '{"paid_on": "2027-03-01"}');
select ok((select v = '{"ok":false,"reason":"paid_on_invalid"}'::jsonb from _t where k = 's13a')
          and (select (v ->> 'ok')::boolean and v #>> '{bill,paid_on}' = '2027-03-01' from _t where k = 's13b')
          and (select t.transaction_date = date '2027-03-01' from public.transactions t where t.external_ref = 'bill:netflix:2027-04'),
          'paid_on 28 Feb on a 2027-04 Netflix bill is paid_on_invalid (not before 1 Mar); 1 Mar is accepted and dates the ledger row');

-- c4: a bill another person is paying keeps its date and estimate: bill_reading_set_v1 refuses with paying_by_other and the payer''s name; the payer themself can still set it
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('c4'), 'water', '2027-05', 300, 'due');
update public.utility_bills set status = 'paying', paying_by = pg_temp.id('a6'), paying_by_name = 'Zz Owner', paying_at = now() where property_id = pg_temp.id('c4') and kind = 'water';
insert into _t select 'y1', pg_temp.rs('a2', pg_temp.id('c4'), 'water', date '2027-05-22');
update public.utility_bills set paying_by = pg_temp.id('a2'), paying_by_name = 'Zz Admin' where property_id = pg_temp.id('c4') and kind = 'water';
insert into _t select 'y2', pg_temp.rs('a2', pg_temp.id('c4'), 'water', date '2027-05-22');
select ok((select v = '{"ok":false,"reason":"paying_by_other","name":"Zz Owner"}'::jsonb from _t where k = 'y1')
          and (select (v ->> 'ok')::boolean from _t where k = 'y2')
          and (select reading_date = date '2027-05-22' and status = 'paying' from public.utility_bills where property_id = pg_temp.id('c4') and kind = 'water'),
          'bill_reading_set_v1 on a bill another user is paying: paying_by_other with the payer''s name and nothing written; the payer themself can set the date');

-- c3: a bill that opens before the assumed end of its own span is estimated with the FORECAST to that end. Anchor 28 Apr: the 2027-05 row spans 28 Apr .. 28 May and opens on 26 May (>= the remind day 25, before 28 May).
-- 30 kWh counted on 10 May: 12 covered days (29 Apr .. 10 May), 30 / 12 = 2.5 kWh a day, the span has 30 days: forecast 75 kWh x 10 + 5.60 = 755.60 (the use counted so far would be 305.60).
select pg_temp.set_open('2027-04-28', '2027-04-28');
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('f1'), null, pg_temp.id('c3'), timestamptz '2027-05-10 09:00+08', 1000, 1030, 50, 30, 3.0, null);
insert into _t select 'f1', public.bill_due_open_v1(pg_temp.id('c3'), date '2027-05-26', '2027-05');
select pg_temp.set_open('2027-04-21', '2027-04-21');
select ok((select jsonb_array_length(v -> 'new') = 4 from _t where k = 'f1')
          and (select estimate_php = 755.60 from public.utility_bills where property_id = pg_temp.id('c3') and kind = 'electric' and period = '2027-05'),
          'a bill opened before its span ends carries the forecast to the end of the span (28 May): 75 kWh x 10 + 5.60 = 755.60, not the 305.60 counted so far');

-- c5: the reading-day notice names only the meter(s) due that day. Electric anchored on 21 Apr, water on 22 Apr: on 21 May only the electricity meter is due; on 21 Jun both are (both anchors reach the 21st).
select pg_temp.set_open('2027-04-21', '2027-04-22');
insert into _t select 'n1', public.bill_daily_v1(date '2027-05-21', pg_temp.id('c5'));
select pg_temp.set_open('2027-04-21', '2027-04-21');
insert into _t select 'n2', public.bill_daily_v1(date '2027-06-21', pg_temp.id('c5'));
select ok((select count(*) = 1 and bool_and(n.title = 'Meter reading due today (21st)' and n.description = 'Read the electricity meter.') from public.ops_notices n
            where n.property_id = pg_temp.id('c5') and n.title like 'Meter reading%' and n.effective_date = date '2027-05-21')
          and (select count(*) = 1 and bool_and(n.title = 'Meter reading due today (21st)' and n.description = 'Read the electricity and water meters.') from public.ops_notices n
            where n.property_id = pg_temp.id('c5') and n.title like 'Meter reading%' and n.effective_date = date '2027-06-21'),
          'the reading-day notice names the meter(s) due: electricity only on 21 May (water is anchored on the 22nd), both meters on 21 Jun');

-- 12. shape: grants, the check constraint and the ledger column ---------------------------------------------------------------------------------------------------------------------------------------
select ok(has_function_privilege('authenticated', 'public.bill_reading_set_v1(uuid,text,date,numeric,boolean)', 'execute')
          and not has_function_privilege('anon', 'public.bill_reading_set_v1(uuid,text,date,numeric,boolean)', 'execute')
          and not has_function_privilege('service_role', 'public.bill_reading_set_v1(uuid,text,date,numeric,boolean)', 'execute')
          and (select bool_and(p.prosecdef and p.proconfig @> array['search_path=""']) from pg_proc p where p.oid = 'public.bill_reading_set_v1(uuid,text,date,numeric,boolean)'::regprocedure)
          and not exists (select 1 from unnest(array['public.utility_add_months_v1(date,integer)', 'public.utility_meter_rows_v1(uuid,text,text)', 'public.utility_meter_cycle_v1(uuid,text,date,jsonb)',
                                                     'public.utility_cycle_php_v1(uuid,text,date,date,jsonb)', 'public.utility_bill_span_v1(uuid,text,uuid)', 'public.utility_last_bill_v1(uuid,text)']) f
                           where has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute') or has_function_privilege('service_role', f, 'execute')),
          'bill_reading_set_v1 is security definer with an empty search_path, for signed-in users only; the six helpers are granted to nobody');
select ok((select count(*) = 1 from pg_constraint where conrelid = 'public.transactions'::regclass and conname = 'transactions_payment_method_check')
          and (select pg_temp.try($$insert into public.transactions(property_id, txn_type, category, status, source, transaction_date, gross_amount, payment_method) values ('e1430000-0000-4000-8000-0000000000b6', 'expense', 'supplies', 'confirmed', 'manual', date '2027-05-24', 1, 'cheque')$$) ->> 'err' = '23514'),
          'transactions.payment_method has its check constraint: a value outside the list is refused (23514)');

select * from finish();
rollback;
