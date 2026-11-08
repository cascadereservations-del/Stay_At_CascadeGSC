-- Session 111, lane SQL: release s111_kpi_stay_avg_20261113, contract revision 2. kpi_tab_v1 utility block per day between meter readings, nights_booked,
-- per_stay, per_month; admin.target; kpi_target_set_v1. Hand-computed numbers. Counted reading: both prev > 0, both deltas >= 0, flag null / typed_accepted / estimated.
-- days = Manila days since the property's previous reading of any flag (min 1, null for the first). Fixtures use uuids d1110000-...; everything rolls back.
begin;
select plan(57);

grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt(), auth.role() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
alter role service_role bypassrls;

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal1', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.id(p text) returns uuid language sql immutable as $$ select ('d1110000-0000-4000-8000-0000000000' || p)::uuid $$;

-- a1 cleaner, a2 laundry, a3 admin, a4 finance, a8 cleaner of the other property; properties b0 and b1
insert into auth.users(id, email) values
  (pg_temp.id('a1'), 'zz111-cleaner@example.com'), (pg_temp.id('a2'), 'zz111-laundry@example.com'), (pg_temp.id('a3'), 'zz111-admin@example.com'),
  (pg_temp.id('a4'), 'zz111-finance@example.com'), (pg_temp.id('a8'), 'zz111-other@example.com');
insert into public.properties(id, name, is_active) values (pg_temp.id('b0'), 'Zz S111 fixture property', true), (pg_temp.id('b1'), 'Zz S111 other property', true);
insert into public.staff_access_profiles(user_id, role) values
  (pg_temp.id('a1'), 'cleaner'), (pg_temp.id('a2'), 'laundry'), (pg_temp.id('a3'), 'admin'), (pg_temp.id('a4'), 'finance'), (pg_temp.id('a8'), 'cleaner');
insert into public.staff_property_access(user_id, property_id) select u, pg_temp.id('b0') from unnest(array[pg_temp.id('a1'), pg_temp.id('a2'), pg_temp.id('a3'), pg_temp.id('a4')]) u;
insert into public.staff_property_access(user_id, property_id) values (pg_temp.id('a8'), pg_temp.id('b1'));

insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaned_at, nights_stayed, checkout_date, cleaning_type) values
  (pg_temp.id('d1'), 'zz111-sub-d1', 'Zz111 Cleaner', pg_temp.id('b0'), timestamptz '2020-06-04 10:00+08', 2, date '2020-06-04', 'turnover'),
  (pg_temp.id('d2'), 'zz111-sub-d2', 'Zz111 Cleaner', pg_temp.id('b0'), timestamptz '2020-06-10 10:00+08', 1, date '2020-06-10', 'turnover'),
  (pg_temp.id('d3'), 'zz111-sub-d3', 'Zz111 Cleaner', pg_temp.id('b0'), timestamptz '2020-06-05 10:00+08', 1, date '2020-06-05', 'turnover');
-- Chronological. Counted: ea (first ever, days null), e9 (1 day), e8 (316), e1 (3), e2 (2), eb (same day: 1), e7 (20), f1 (32), f2 (4).
-- Not counted but still the previous reading for days: e0 misread, e3 electric_prev 0, e4 water_prev 0, e5 negative water, e6 under_review.
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('ea'), null,           pg_temp.id('b0'), timestamptz '2019-06-30 23:30+08', 400, 90, 999, 99, null),
  (pg_temp.id('e9'), null,           pg_temp.id('b0'), timestamptz '2019-07-01 00:30+08', 300, 80, 9, 0.9, null),
  (pg_temp.id('e8'), null,           pg_temp.id('b0'), timestamptz '2020-05-12 09:00+08', 200, 70, 7, 1.5, null),
  (pg_temp.id('e0'), null,           pg_temp.id('b0'), timestamptz '2020-06-01 09:00+08', 130, 56, 500, 90, 'misread'),
  (pg_temp.id('e1'), pg_temp.id('d1'), pg_temp.id('b0'), timestamptz '2020-06-04 09:00+08', 100, 50, 30, 6, null),
  (pg_temp.id('e3'), pg_temp.id('d3'), pg_temp.id('b0'), timestamptz '2020-06-05 09:00+08', 0, 5, 300, 30, null),
  (pg_temp.id('e4'), null,           pg_temp.id('b0'), timestamptz '2020-06-06 09:00+08', 10, 0, 40, 20, null),
  (pg_temp.id('e5'), null,           pg_temp.id('b0'), timestamptz '2020-06-07 09:00+08', 10, 10, 50, -1, null),
  (pg_temp.id('e6'), null,           pg_temp.id('b0'), timestamptz '2020-06-08 09:00+08', 10, 10, 60, 60, 'under_review'),
  (pg_temp.id('e2'), pg_temp.id('d2'), pg_temp.id('b0'), timestamptz '2020-06-10 09:00+08', 120, 54, 10, 2, 'typed_accepted'),
  (pg_temp.id('eb'), null,           pg_temp.id('b0'), timestamptz '2020-06-10 18:00+08', 130, 56, 3, 0.3, null),
  (pg_temp.id('e7'), null,           pg_temp.id('b0'), timestamptz '2020-06-30 23:30+08', 133, 56, 40, 2, 'estimated'),
  (pg_temp.id('f1'), null,           pg_temp.id('b0'), timestamptz '2020-08-01 09:00+08', 150, 60, 8, 0.8, null),
  (pg_temp.id('f2'), null,           pg_temp.id('b0'), timestamptz '2020-08-05 09:00+08', 158, 61, 12, 0.6, null);

-- Rates for month_kwh_cost (M1): 10/kWh from 2020-05-01, 12/kWh from 2020-06-08. Counted June readings: e1 06-04 30 x 10, e2 06-10 10 x 12, eb 3 x 12, e7 40 x 12
-- = 936.00. e3 (electric_prev 0, on a 1-night session) must not be costed: the s110 rule would have added 300 x 10 and dropped eb and e7 (no session).
insert into public.utility_rates(provider, php_per_kwh, effective_from, source) values ('socoteco2', 10, date '2020-05-01', 'manual'), ('socoteco2', 12, date '2020-06-08', 'manual');
-- Stays of June 2020: R1 confirmed 5..7, R2 completed 7..8 (night 7 counted once), R3 cancelled, I1 direct confirmed 28..30 in June -> 7 sold nights.
-- Revenue per night: R1 3000/3, R2 1000/2, I1 3000/5 -> June 3000 + 1000 + 1800 over 8 revenue nights = ADR 725.
insert into public.airbnb_reservations(id, property_id, confirmation_code, status, guest_name, checkin_date, checkout_date, host_service_fee, host_payout) values
  (pg_temp.id('c1'), pg_temp.id('b0'), 'ZZ111R1', 'confirmed', 'Zz Ana', date '2020-06-05', date '2020-06-08', 0, 3000),
  (pg_temp.id('c2'), pg_temp.id('b0'), 'ZZ111R2', 'completed', 'Zz Ben', date '2020-06-07', date '2020-06-09', 0, 1000),
  (pg_temp.id('c3'), pg_temp.id('b0'), 'ZZ111R3', 'cancelled', 'Zz Cy', date '2020-06-15', date '2020-06-20', 0, 2000);
insert into public.booking_inquiries(id, property_id, guest_name, guest_phone, checkin_date, checkout_date, source, status, total_amount) values
  (pg_temp.id('c4'), pg_temp.id('b0'), 'Zz Dee', '000', date '2020-06-28', date '2020-07-03', 'direct', 'confirmed', 3000);
-- Expenses for the costs basis of June 2020: March 9000, April none, May 6000 -> 7500 (months without expenses are left out)
insert into public.transactions(id, property_id, txn_type, category, gross_amount, source, status, transaction_date) values
  (pg_temp.id('fa'), pg_temp.id('b0'), 'expense', 'supplies', 9000, 'manual', 'confirmed', date '2020-03-10'),
  (pg_temp.id('fb'), pg_temp.id('b0'), 'expense', 'supplies', 6000, 'manual', 'confirmed', date '2020-05-10');

select pg_temp.as_user(pg_temp.id('a1'));
create temp table _k_cleaner as select public.kpi_tab_v1(pg_temp.id('b0')) as j;
create temp table _k_c2020 as select public.kpi_tab_v1(pg_temp.id('b0'), date '2020-06-15') as j;
create temp table _k_c2019 as select public.kpi_tab_v1(pg_temp.id('b0'), date '2019-06-15') as j;
create temp table _k_empty as select public.kpi_tab_v1(pg_temp.id('b0'), date '2018-03-15') as j;
create temp table _t_cleaner as select public.kpi_target_set_v1(pg_temp.id('b0'), 1000) as j;
select pg_temp.as_user(pg_temp.id('a2'));
create temp table _k_laundry as select public.kpi_tab_v1(pg_temp.id('b0'), date '2020-06-15') as j;
select pg_temp.as_user(pg_temp.id('a4'));
create temp table _k_fin as select public.kpi_tab_v1(pg_temp.id('b0'), date '2020-06-15') as j;
create temp table _t_fin as select public.kpi_target_set_v1(pg_temp.id('b0'), 1000) as j;
select pg_temp.as_user(pg_temp.id('a3'));
create temp table _t_bad as select v, public.kpi_target_set_v1(pg_temp.id('b0'), v) as j from (values (-1::numeric), (10000000.01), (1.005), (null)) x(v);
create temp table _t_max as select public.kpi_target_set_v1(pg_temp.id('b0'), 10000000) as j;
create temp table _t_ok as select public.kpi_target_set_v1(pg_temp.id('b0'), 1500) as j;
create temp table _k_admin as select public.kpi_tab_v1(pg_temp.id('b0'), date '2020-06-15') as j;
create temp table _k_a2018 as select public.kpi_tab_v1(pg_temp.id('b0'), date '2018-03-15') as j;
reset role;
-- L4: a setter whose profile has no access to this property must not lend the target a role
update public.kpi_targets set set_by = pg_temp.id('a8') where property_id = pg_temp.id('b0');
select pg_temp.as_user(pg_temp.id('a3'));
create temp table _k_l4 as select public.kpi_tab_v1(pg_temp.id('b0'), date '2020-06-15') as j;
reset role;
grant all on _k_cleaner, _k_c2020, _k_c2019, _k_empty, _t_cleaner, _k_laundry, _k_fin, _t_fin, _t_bad, _t_max, _t_ok, _k_admin, _k_a2018, _k_l4 to public;
create temp table _pm as select e ->> 'month' as month, e as row from _k_c2020, jsonb_array_elements(j -> 'utility' -> 'per_month') e;
create temp table _u as select j -> 'utility' as u from _k_c2020;
create temp table _tg as select j -> 'admin' -> 'target' as t from _k_admin;

-- month block (June 2020: e1 30/6 over 3 days, e2 10/2 over 2, eb 3/0.3 over 1, e7 40/2 over 20)
select is((select (u ->> 'kwh_month')::numeric from _u), 83.00::numeric, 'kwh_month sums the counted readings of the month: 30 + 10 + 3 + 40');
select is((select (u ->> 'm3_month')::numeric from _u), 10.30::numeric, 'm3_month: 6 + 2 + 0.3 + 2');
select is((select (u ->> 'kwh_per_day')::numeric from _u), 3.19::numeric, 'kwh_per_day is 83 kWh over 26 days (3 + 2 + 1 + 20)');
select is((select (u ->> 'm3_per_day')::numeric from _u), 0.40::numeric, 'm3_per_day is 10.3 m3 over 26 days');
select ok((select not (u ?| array['kwh_per_night', 'm3_per_night', 'nights_month']) from _u), 'kwh_per_night, m3_per_night and nights_month are gone');
select is((select (u ->> 'nights_booked')::integer || '/' || (u ->> 'nights_in_month') from _u), '7/30', 'nights_booked: 7 distinct sold nights of 30 (overlap once, cancelled out, July nights out)');
select is((select (u ->> 'nights_booked')::integer from _u),
          (public.hospitality_metrics_core_v1(pg_temp.id('b0'), date '2020-06-01', date '2020-07-01', false) -> 'metrics' -> 'sold_nights' ->> 'value')::integer,
          'nights_booked equals get_hospitality_metrics_v1 sold_nights for the month');
select is((select (u ->> 'nights_booked')::numeric from _u), (select (j -> 'admin' ->> 'sold_nights')::numeric from _k_admin), 'nights_booked equals the admin occupancy nights');
select ok((select jsonb_typeof(j -> 'utility' -> 'kwh_month') = 'number' and jsonb_typeof(j -> 'utility' -> 'kwh_per_day') = 'null' and jsonb_typeof(j -> 'utility' -> 'm3_per_day') = 'null'
                  and (j -> 'utility' ->> 'nights_booked')::integer = 0 and (j -> 'utility' ->> 'nights_in_month')::integer = 31 from _k_empty), 'an empty month: 0 kWh, null per day, 0 of 31 nights');

-- last_reading = the latest counted reading (f2: 12 kWh, 0.6 m3, 4 days after f1)
select is((select (u -> 'last_reading' ->> 'days')::integer || '/' || (u -> 'last_reading' ->> 'delta_kwh') || '/' || (u -> 'last_reading' ->> 'kwh_per_day') || '/'
                  || (u -> 'last_reading' ->> 'delta_m3') || '/' || (u -> 'last_reading' ->> 'm3_per_day') from _u), '4/12.00/3.00/0.6000/0.15', 'last_reading: 12 kWh and 0.6 m3 over 4 days');
select ok((select (u -> 'last_reading') ?& array['recorded_at', 'delta_kwh', 'days', 'kwh_per_day', 'delta_m3', 'm3_per_day', 'flag']
                  and (select count(*) from jsonb_object_keys(u -> 'last_reading')) = 7 from _u), 'last_reading has exactly the seven contract keys');

-- per_stay = the last 8 counted readings, oldest first (ea drops out)
select is((select jsonb_array_length(u -> 'per_stay') from _u), 8, 'per_stay holds the last 8 counted readings');
select is((select (u -> 'per_stay' -> 0 ->> 'days') || '/' || (u -> 'per_stay' -> 0 ->> 'kwh_per_day') || '/' || (u -> 'per_stay' -> 0 ->> 'm3_per_day') from _u), '1/9.00/0.90',
          'per_stay[0] is e9: 00:30 Manila the day after the previous reading counts 1 day');
select is((select (u -> 'per_stay' -> 2 ->> 'checkout_date') || '/' || (u -> 'per_stay' -> 2 ->> 'days') || '/' || (u -> 'per_stay' -> 2 ->> 'kwh') || '/' || (u -> 'per_stay' -> 2 ->> 'kwh_per_day')
                  || '/' || (u -> 'per_stay' -> 2 ->> 'm3_per_day') from _u), '2020-06-04/3/30.00/10.00/2.00', 'e1: readings 3 days apart, 30 kWh -> 10 a day, 6 m3 -> 2 a day (a misread reading still starts the count)');
select is((select (u -> 'per_stay' -> 3 ->> 'days') || '/' || (u -> 'per_stay' -> 3 ->> 'kwh_per_day') from _u), '2/5.00', 'e2 counts from the under_review reading 2 days before it');
select is((select (u -> 'per_stay' -> 4 ->> 'days') || '/' || (u -> 'per_stay' -> 4 ->> 'kwh_per_day') from _u), '1/3.00', 'a second reading on the same Manila day counts 1 day (minimum)');
select is((select (u -> 'per_stay' -> 7 ->> 'recorded_at')::timestamptz from _u), timestamptz '2020-08-05 09:00+08', 'per_stay ends with the latest counted reading');
select ok((select bool_and(e ?& array['checkout_date', 'recorded_at', 'days', 'kwh', 'kwh_per_day', 'm3', 'm3_per_day'] and (select count(*) from jsonb_object_keys(e)) = 7)
             from _u, jsonb_array_elements(u -> 'per_stay') e), 'every per_stay item has exactly the seven contract keys');

-- per_month
select is((select jsonb_array_length(j -> 'utility' -> 'per_month') from _k_c2020), 12, 'per_month has 12 rows');
select is((select string_agg(e ->> 'month', ',' order by n) from _k_c2020, jsonb_array_elements(j -> 'utility' -> 'per_month') with ordinality t(e, n)),
          '2019-07,2019-08,2019-09,2019-10,2019-11,2019-12,2020-01,2020-02,2020-03,2020-04,2020-05,2020-06', 'the months run oldest first and end with the selected month');
select is((select (row ->> 'stays') || '/' || (row ->> 'kwh') || '/' || (row ->> 'm3') || '/' || (row ->> 'kwh_per_stay') || '/' || (row ->> 'm3_per_stay') || '/'
                  || (row ->> 'kwh_per_day') || '/' || (row ->> 'm3_per_day') from _pm where month = '2020-06'), '4/83.00/10.30/20.8/2.58/3.19/0.40',
          'June 2020: 4 counted readings, 83 kWh and 10.3 m3, per stay 20.8 / 2.58, per day 3.19 / 0.40');
select is((select (row ->> 'stays') || '/' || (row ->> 'kwh') || '/' || (row ->> 'kwh_per_day') from _pm where month = '2020-05'), '1/7.00/0.02', 'May 2020: 7 kWh over 316 days');
select is((select (row ->> 'stays') || '/' || (row ->> 'kwh_per_stay') || '/' || (row ->> 'm3_per_stay') || '/' || (row ->> 'kwh_per_day') || '/' || (row ->> 'm3_per_day') from _pm where month = '2019-07'),
          '1/9.0/0.90/9.00/0.90', 'July 2019 (00:30 Manila) belongs to July: 9 kWh and 0.9 m3 over 1 day');
select is((select sum((row ->> 'stays')::integer) from _pm), 6::bigint, 'the window holds 6 counted readings: the 2019-06-30 23:30 and August readings are outside');
select ok((select jsonb_typeof(row -> 'kwh') = 'null' and jsonb_typeof(row -> 'm3') = 'null' and jsonb_typeof(row -> 'kwh_per_stay') = 'null' and jsonb_typeof(row -> 'm3_per_stay') = 'null'
                  and jsonb_typeof(row -> 'kwh_per_day') = 'null' and jsonb_typeof(row -> 'm3_per_day') = 'null' and (row ->> 'stays')::integer = 0 from _pm where month = '2019-08'),
          'an empty month has stays 0 and null figures');
select ok((select bool_and(row ?& array['month', 'stays', 'kwh', 'm3', 'kwh_per_stay', 'm3_per_stay', 'kwh_per_day', 'm3_per_day'] and (select count(*) from jsonb_object_keys(row)) = 8) from _pm),
          'every per_month row has exactly the eight contract keys');
select is((select (e ->> 'stays') || '/' || (e ->> 'kwh') || '/' || coalesce(e ->> 'kwh_per_day', 'null') from _k_c2019, jsonb_array_elements(j -> 'utility' -> 'per_month') e where e ->> 'month' = '2019-06'),
          '1/999.00/null', 'the first reading ever has no days: its month shows kWh but no per-day figure');
select is((select (j -> 'utility' -> 'per_month' -> 0 ->> 'month') || '..' || (j -> 'utility' -> 'per_month' -> 11 ->> 'month') || '/' || (select sum((e ->> 'stays')::integer) from jsonb_array_elements(j -> 'utility' -> 'per_month') e) from _k_empty),
          '2017-04..2018-03/0', 'a month with no readings returns 12 empty rows and crosses the year start');
select is((select (j -> 'utility' -> 'per_month' -> 11 ->> 'month') from _k_cleaner), to_char(public.manila_today(), 'YYYY-MM'), 'without p_month the last row is the current Manila month');

-- admin.target
select is((select (j -> 'admin' -> 'target' ->> 'net_target')::numeric || '/' || (j -> 'admin' -> 'target' ->> 'costs_basis') || '/' || (j -> 'admin' -> 'target' ->> 'revenue_needed') || '/'
                  || coalesce(j -> 'admin' -> 'target' ->> 'set_by', 'null') from _k_fin), '0/7500.00/7500.00/null', 'no target set: break-even, costs basis = (9000 + 6000) / 2 months with expenses');
select is((select (t ->> 'net_target')::numeric || '/' || (t ->> 'revenue_needed') || '/' || (t ->> 'adr') || '/' || (t ->> 'nights_in_month') || '/' || (t ->> 'nights_on_books') from _tg),
          '1500.00/9000.00/725.00/30/7', 'target 1500: revenue needed 7500 + 1500, ADR 725, 7 nights on the books of 30');
select is((select (t ->> 'needed_occupancy')::numeric from _tg), 0.4138::numeric, 'needed_occupancy = 9000 / (725 x 30)');
select is((select (t ->> 'needed_adr')::numeric from _tg), 1285.71::numeric, 'needed_adr = 9000 / 7 nights on the books');
select ok((select t ->> 'set_by' = 'admin' and (t ->> 'set_at') is not null from _tg), 'set_by is the role of the person who set it, with set_at');
select ok((select t ?& array['net_target', 'costs_basis', 'revenue_needed', 'adr', 'nights_in_month', 'nights_on_books', 'needed_occupancy', 'needed_adr', 'set_by', 'set_at']
                  and (select count(*) from jsonb_object_keys(t)) = 10 from _tg), 'admin.target has exactly the ten contract keys');
select is((select (t ->> 'adr')::numeric from _tg), (select (j -> 'admin' ->> 'adr')::numeric from _k_admin), 'target.adr is the admin ADR');
select ok((select jsonb_typeof(j -> 'admin' -> 'target' -> 'costs_basis') = 'null' and jsonb_typeof(j -> 'admin' -> 'target' -> 'revenue_needed') = 'null'
                  and jsonb_typeof(j -> 'admin' -> 'target' -> 'needed_occupancy') = 'null' and jsonb_typeof(j -> 'admin' -> 'target' -> 'needed_adr') = 'null' from _k_a2018),
          'no expenses in the 3 months before: costs basis, revenue needed and both needed figures are null');

select ok((select jsonb_typeof(j -> 'admin' -> 'target' -> 'set_by') = 'null' and (j -> 'admin' -> 'target' ->> 'net_target')::numeric = 1500 from _k_l4),
          'set_by stays null when the setter has no access to the property (L4)');

-- month_kwh_cost (M1)
select is((select (j -> 'admin' ->> 'month_kwh_cost')::numeric from _k_admin), 936.00::numeric,
          'month_kwh_cost costs the counted readings at the rate of their own day: 300 + 120 + 36 + 480 (the prev 0 reading is left out)');
select is((select (j -> 'admin' ->> 'month_kwh_cost')::numeric from _k_fin), 936.00::numeric, 'finance sees the same month_kwh_cost');

-- kpi_target_set_v1
select is((select j ->> 'error' from _t_cleaner) || '/' || (select j ->> 'error' from _t_fin), 'forbidden/forbidden', 'cleaner and finance cannot set the target (manage_operations)');
select is((select string_agg(j ->> 'error', ',' order by v nulls last) from _t_bad), 'invalid_target,invalid_target,invalid_target,invalid_target', 'below 0, above 10,000,000, more than 2 dp and null are refused');
select ok((select (j ->> 'ok')::boolean from _t_max) and (select (j ->> 'ok')::boolean from _t_ok), 'admin sets 10,000,000 (the bound) and then 1500');
select is((select count(*)::integer || '/' || max(monthly_net_target) from public.kpi_targets where property_id = pg_temp.id('b0')), '1/1500.00', 'one row per property, the latest value wins');

-- roles
select ok(not ((select j from _k_cleaner) ? 'admin') and not ((select j from _k_laundry) ? 'admin'), 'the admin key (and target) stays absent for cleaner and laundry');
select is((select (j -> 'utility' ->> 'nights_booked')::integer from _k_laundry), 7, 'laundry sees nights_booked too (no admin_stays gate in the way)');
select ok((select j -> 'admin' ? 'target' from _k_fin) and (select j -> 'admin' ? 'target' from _k_admin), 'finance and admin get admin.target');
select ok(position('php' in (select (j -> 'utility')::text from _k_admin)) = 0 and position('cost' in (select (j -> 'utility')::text from _k_admin)) = 0, 'no money in the utility block');
select pg_temp.as_user(pg_temp.id('a8'));
select is((select public.kpi_tab_v1(pg_temp.id('b0')) ->> 'error') || '/' || (select public.kpi_target_set_v1(pg_temp.id('b0'), 1) ->> 'error'), 'forbidden/forbidden', 'a person of another property is refused by both');
reset role;

-- weather_here_take_v1 (H1): atomic per-user per-Manila-day count, limit, day roll, 7-day trim, service_role only
insert into public.weather_here_usage(user_id, day, count) values
  (pg_temp.id('a2'), public.manila_today() - 1, 99), (pg_temp.id('a3'), public.manila_today() - 8, 5), (pg_temp.id('a3'), public.manila_today() - 7, 5);
select is((select array_agg(public.weather_here_take_v1(pg_temp.id('a1'), 2) order by g) from generate_series(1, 3) g), array[true, true, false],
          'limit 2: the first two calls pass, the third is refused');
select is((select count from public.weather_here_usage where user_id = pg_temp.id('a1') and day = public.manila_today()), 3, 'every call is counted, the refused one too');
select ok(public.weather_here_take_v1(pg_temp.id('a2')), 'yesterday at 99 does not count against today (default limit 60)');
-- separate statement: a subquery in the same statement as the call reads the snapshot taken before the insert
select is((select string_agg(count::text, '/' order by day desc) from public.weather_here_usage where user_id = pg_temp.id('a2')), '1/99',
          'a new Manila day starts at 1 and the previous day keeps its own count');
select is((select string_agg((public.manila_today() - day)::text, ',' order by day) from public.weather_here_usage where user_id = pg_temp.id('a3')), '7',
          'rows older than 7 days are trimmed, the 7-day-old row stays');
select ok(not public.weather_here_take_v1(null), 'a null user is refused');
select ok((select relrowsecurity from pg_class where oid = 'public.weather_here_usage'::regclass)
          and not has_table_privilege('anon', 'public.weather_here_usage', 'select') and not has_table_privilege('authenticated', 'public.weather_here_usage', 'select')
          and not has_table_privilege('anon', 'public.weather_here_usage', 'insert') and not has_table_privilege('authenticated', 'public.weather_here_usage', 'update')
          and has_table_privilege('service_role', 'public.weather_here_usage', 'select') and not has_table_privilege('service_role', 'public.weather_here_usage', 'delete'),
          'weather_here_usage: RLS on, no anon/authenticated grants, service_role select/insert/update only');
select ok(has_function_privilege('service_role', 'public.weather_here_take_v1(uuid,integer)', 'execute')
          and not has_function_privilege('anon', 'public.weather_here_take_v1(uuid,integer)', 'execute')
          and not has_function_privilege('authenticated', 'public.weather_here_take_v1(uuid,integer)', 'execute')
          and (select prosecdef and proconfig = array['search_path=""'] from pg_proc where oid = 'public.weather_here_take_v1(uuid,integer)'::regprocedure),
          'weather_here_take_v1: security definer, empty search_path, service_role execute only');

select * from finish();
rollback;
