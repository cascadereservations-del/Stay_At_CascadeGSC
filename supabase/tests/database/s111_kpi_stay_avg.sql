-- Session 111, lane SQL: release s111_kpi_stay_avg_20261113. kpi_tab_v1 utility block: m3_month / m3_per_night, per_stay[].m3_per_night and utility.per_month
-- (12 Manila months, oldest first, one row per month, consumption rule: both prev > 0, both deltas >= 0, flag null / typed_accepted / estimated). Hand-computed numbers.
-- Fixtures use uuids d1110000-... on properties of their own; everything rolls back. Needs the s110 and s111 migrations applied.
begin;
select plan(30);

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

-- Sessions: d1 2 nights (checkout 2020-06-10), d2 1 night (2020-06-20), d3 0 nights (2020-05-12), d4 3 nights (2019-07-15), d5 1 night (2019-06-10)
insert into public.cleaning_sessions(id, submission_id, cleaner_name, property_id, cleaned_at, nights_stayed, checkout_date, cleaning_type) values
  (pg_temp.id('d1'), 'zz111-sub-d1', 'Zz111 Cleaner', pg_temp.id('b0'), timestamptz '2020-06-10 10:00+08', 2, date '2020-06-10', 'turnover'),
  (pg_temp.id('d2'), 'zz111-sub-d2', 'Zz111 Cleaner', pg_temp.id('b0'), timestamptz '2020-06-20 10:00+08', 1, date '2020-06-20', 'turnover'),
  (pg_temp.id('d3'), 'zz111-sub-d3', 'Zz111 Cleaner', pg_temp.id('b0'), timestamptz '2020-05-12 10:00+08', 0, date '2020-05-12', 'turnover'),
  (pg_temp.id('d4'), 'zz111-sub-d4', 'Zz111 Cleaner', pg_temp.id('b0'), timestamptz '2019-07-15 10:00+08', 3, date '2019-07-15', 'turnover'),
  (pg_temp.id('d5'), 'zz111-sub-d5', 'Zz111 Cleaner', pg_temp.id('b0'), timestamptz '2019-06-10 10:00+08', 1, date '2019-06-10', 'turnover');
-- June 2020: e1 and e2 are consumption (kWh 20 + 10, m3 4 + 2, nights 2 + 1); e3 misread, e4 electric_prev 0, e5 water_prev 0, e6 negative water, e7 under_review are not.
-- e4..e6 still feed kwh_month / m3_month, which keep the s110 rule (a usable flag, a non-negative delta of their own meter, nights > 0).
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, water_prev, electric_delta, water_delta, kwh_per_night, m3_per_night, meter_flag) values
  (pg_temp.id('e1'), pg_temp.id('d1'), pg_temp.id('b0'), timestamptz '2020-06-10 09:00+08', 100, 50, 20, 4, 10, 2, null),
  (pg_temp.id('e2'), pg_temp.id('d2'), pg_temp.id('b0'), timestamptz '2020-06-30 23:30+08', 120, 54, 10, 2, 10, null, 'typed_accepted'),
  (pg_temp.id('e3'), pg_temp.id('d1'), pg_temp.id('b0'), timestamptz '2020-06-11 09:00+08', 130, 56, 500, 90, null, null, 'misread'),
  (pg_temp.id('e4'), pg_temp.id('d2'), pg_temp.id('b0'), timestamptz '2020-06-12 09:00+08', 0, 5, 300, 30, null, null, null),
  (pg_temp.id('e5'), pg_temp.id('d2'), pg_temp.id('b0'), timestamptz '2020-06-13 09:00+08', 10, 0, 40, 20, null, null, null),
  (pg_temp.id('e6'), pg_temp.id('d2'), pg_temp.id('b0'), timestamptz '2020-06-14 09:00+08', 10, 10, 50, -1, null, null, null),
  (pg_temp.id('e7'), pg_temp.id('d1'), pg_temp.id('b0'), timestamptz '2020-06-15 09:00+08', 10, 10, 60, 60, null, null, 'under_review'),
-- May 2020: a stay of 0 nights (counts as a stay, no per-night figure)
  (pg_temp.id('e8'), pg_temp.id('d3'), pg_temp.id('b0'), timestamptz '2020-05-12 09:00+08', 200, 70, 7, 1.5, null, null, null),
-- July 2019 starts at 00:30 Manila = 16:30 UTC of June 30: the Manila month decides
  (pg_temp.id('e9'), pg_temp.id('d4'), pg_temp.id('b0'), timestamptz '2019-07-01 00:30+08', 300, 80, 9, 0.9, 3, 0.3, null),
-- 23:30 Manila on 2019-06-30: one month before the window of June 2020
  (pg_temp.id('ea'), pg_temp.id('d5'), pg_temp.id('b0'), timestamptz '2019-06-30 23:30+08', 400, 90, 999, 99, null, null, null);

select pg_temp.as_user(pg_temp.id('a1'));
create temp table _k_cleaner as select public.kpi_tab_v1(pg_temp.id('b0')) as j;
create temp table _k_c2020 as select public.kpi_tab_v1(pg_temp.id('b0'), date '2020-06-15') as j;
create temp table _k_empty as select public.kpi_tab_v1(pg_temp.id('b0'), date '2018-03-15') as j;
select pg_temp.as_user(pg_temp.id('a2'));
create temp table _k_laundry as select public.kpi_tab_v1(pg_temp.id('b0'), date '2020-06-15') as j;
select pg_temp.as_user(pg_temp.id('a4'));
create temp table _k_fin as select public.kpi_tab_v1(pg_temp.id('b0'), date '2020-06-15') as j;
select pg_temp.as_user(pg_temp.id('a3'));
create temp table _k_admin as select public.kpi_tab_v1(pg_temp.id('b0'), date '2020-06-15') as j;
reset role;
grant all on _k_cleaner, _k_c2020, _k_empty, _k_laundry, _k_fin, _k_admin to public;
create temp table _pm as select e ->> 'month' as month, e as row from _k_c2020, jsonb_array_elements(j -> 'utility' -> 'per_month') e;

select is((select jsonb_array_length(j -> 'utility' -> 'per_month') from _k_c2020), 12, 'per_month has 12 rows');
select is((select string_agg(e ->> 'month', ',' order by n) from _k_c2020, jsonb_array_elements(j -> 'utility' -> 'per_month') with ordinality t(e, n)),
          '2019-07,2019-08,2019-09,2019-10,2019-11,2019-12,2020-01,2020-02,2020-03,2020-04,2020-05,2020-06', 'the months run oldest first and end with the selected month');
select is((select (row ->> 'stays')::integer from _pm where month = '2020-06'), 2, 'June 2020 counts 2 consumption readings (flags misread / under_review, prev = 0 and a negative delta are out)');
select is((select (row ->> 'kwh_per_stay')::numeric from _pm where month = '2020-06'), 15.0::numeric, 'kwh_per_stay is (20 + 10) / 2');
select is((select (row ->> 'm3_per_stay')::numeric from _pm where month = '2020-06'), 3.00::numeric, 'm3_per_stay is (4 + 2) / 2');
select is((select (row ->> 'kwh_per_night')::numeric from _pm where month = '2020-06'), 10.00::numeric, 'kwh_per_night is 30 kWh over 3 nights');
select is((select (row ->> 'm3_per_night')::numeric from _pm where month = '2020-06'), 2.00::numeric, 'm3_per_night is 6 m3 over 3 nights');
select is((select (row ->> 'stays')::integer || '/' || (row ->> 'kwh_per_stay') || '/' || (row ->> 'm3_per_stay') from _pm where month = '2020-05'), '1/7.0/1.50', 'May 2020: one reading, 7 kWh and 1.5 m3 per stay');
select ok((select jsonb_typeof(row -> 'kwh_per_night') = 'null' and jsonb_typeof(row -> 'm3_per_night') = 'null' from _pm where month = '2020-05'), 'a stay of 0 nights has no per-night figure');
select is((select (row ->> 'stays')::integer || '/' || (row ->> 'kwh_per_stay') || '/' || (row ->> 'm3_per_stay') || '/' || (row ->> 'kwh_per_night') || '/' || (row ->> 'm3_per_night') from _pm where month = '2019-07'),
          '1/9.0/0.90/3.00/0.30', 'July 2019 (00:30 Manila) belongs to July: 9 kWh and 0.9 m3 over 3 nights');
select is((select sum((row ->> 'stays')::integer) from _pm), 4::bigint, 'the 23:30 Manila reading of 2019-06-30 is outside the 12 months');
select ok((select jsonb_typeof(row -> 'kwh_per_stay') = 'null' and jsonb_typeof(row -> 'm3_per_stay') = 'null' and jsonb_typeof(row -> 'kwh_per_night') = 'null'
                  and jsonb_typeof(row -> 'm3_per_night') = 'null' and (row ->> 'stays')::integer = 0 from _pm where month = '2019-08'), 'an empty month has stays 0 and null figures');
select ok((select bool_and(row ?& array['month', 'stays', 'kwh_per_stay', 'm3_per_stay', 'kwh_per_night', 'm3_per_night'] and (select count(*) from jsonb_object_keys(row)) = 6) from _pm), 'every row has exactly the six contract keys');
select is((select jsonb_array_length(j -> 'utility' -> 'per_month') || '/' || (select sum((e ->> 'stays')::integer) from jsonb_array_elements(j -> 'utility' -> 'per_month') e) from _k_empty), '12/0', 'a month with no readings still returns 12 empty rows');
select is((select (j -> 'utility' -> 'per_month' -> 0 ->> 'month') || '..' || (j -> 'utility' -> 'per_month' -> 11 ->> 'month') from _k_empty), '2017-04..2018-03', 'the window crosses the year start correctly');
select is((select (j -> 'utility' -> 'per_month' -> 11 ->> 'month') from _k_cleaner), to_char(public.manila_today(), 'YYYY-MM'), 'without p_month the last row is the current Manila month');

-- water in the month block
select is((select (j -> 'utility' ->> 'kwh_month')::numeric from _k_c2020), 420.00::numeric, 'kwh_month keeps the s110 rule (20 + 10 + 300 + 40 + 50)');
select is((select (j -> 'utility' ->> 'm3_month')::numeric from _k_c2020), 56.00::numeric, 'm3_month: usable flag, non-negative water delta, nights > 0 (4 + 2 + 30 + 20)');
select is((select (j -> 'utility' ->> 'm3_per_night')::numeric from _k_c2020), 11.20::numeric, 'm3_per_night is 56 m3 over the 5 nights of those readings');
select is((select (j -> 'utility' ->> 'kwh_per_night')::numeric from _k_c2020), 70.00::numeric, 'kwh_per_night is unchanged: 420 over 6 nights');
select ok((select jsonb_typeof(j -> 'utility' -> 'm3_month') = 'number' and jsonb_typeof(j -> 'utility' -> 'm3_per_night') = 'null' from _k_empty), 'an empty month: m3_month 0 and m3_per_night null');

-- per_stay
select is((select jsonb_array_length(j -> 'utility' -> 'per_stay') from _k_c2020), 3, 'per_stay holds the 3 stays with a kwh_per_night');
select is((select (j -> 'utility' -> 'per_stay' -> 0 ->> 'kwh_per_night') || '/' || (j -> 'utility' -> 'per_stay' -> 0 ->> 'm3_per_night') from _k_c2020), '3.0000/0.3000', 'per_stay is oldest first and the first item carries m3_per_night');
select is((select (j -> 'utility' -> 'per_stay' -> 1 ->> 'm3_per_night')::numeric from _k_c2020), 2::numeric, 'per_stay[1].m3_per_night is 2');
select is((select jsonb_typeof(j -> 'utility' -> 'per_stay' -> 2 -> 'm3_per_night') from _k_c2020), 'null', 'a stay with no m3_per_night shows null, the key is there');

-- roles
select ok((select jsonb_array_length(j -> 'utility' -> 'per_month') = 12 from _k_cleaner) and (select jsonb_array_length(j -> 'utility' -> 'per_month') = 12 from _k_laundry), 'cleaner and laundry both see per_month');
select ok(not ((select j from _k_cleaner) ? 'admin') and not ((select j from _k_laundry) ? 'admin'), 'the admin key stays absent for cleaner and laundry');
select ok((select j from _k_fin) ? 'admin' and (select j from _k_admin) ? 'admin' and (select jsonb_array_length(j -> 'utility' -> 'per_month') = 12 from _k_admin), 'finance and admin still get the admin key, and per_month');
select ok(position('php' in (select (j -> 'utility')::text from _k_admin)) = 0 and position('cost' in (select (j -> 'utility')::text from _k_admin)) = 0, 'no money in the utility block');
select pg_temp.as_user(pg_temp.id('a8'));
select is((select public.kpi_tab_v1(pg_temp.id('b0')) ->> 'error'), 'forbidden', 'a person of another property is refused');
reset role;

select * from finish();
rollback;
