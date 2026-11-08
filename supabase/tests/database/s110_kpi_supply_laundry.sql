-- Session 110, lane SQL: release s110_kpi_supply_laundry_20261112. The laundry role and report_supply, record_inventory_usage for laundry, utility rates (bounds, gates, idempotency),
-- the KPI tab (admin key absent without read_finance, hand-computed numbers), and the staff receipt flow (draft read hides prices, confirm writes stock + one pending expense + one task,
-- idempotent confirm, undo reverses stock and voids the expense, cancel, retention). Fixtures use uuids d1100000-... on properties of their own; everything rolls back.
-- Needs the s110 migration applied (and everything before it).
begin;
select plan(124);

-- baseline grants for a --no-acl rehearsal restore (idempotent, rolled back with the suite)
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt(), auth.role() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal1', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_service() returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true), set_config('role', 'service_role', true);
$$;
create function pg_temp.try(p text) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  execute p into r;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
create function pg_temp.dml(p text) returns text language plpgsql as $f$
begin
  execute p;
  return 'ok';
exception when others then
  return sqlstate;
end $f$;
create function pg_temp.id(p text) returns uuid language sql immutable as $$ select ('d1100000-0000-4000-8000-0000000000' || p)::uuid $$;

-- =============================================================================================================================================
-- Fixtures: a1 cleaner, a2 laundry, a3 admin, a4 finance, a5 owner, a6 second cleaner, a7 maintenance, a8 cleaner of the other property; properties b0 (all) and b1 (a8 only)
-- =============================================================================================================================================
insert into auth.users(id, email) values
  (pg_temp.id('a1'), 'zz110-cleaner@example.com'), (pg_temp.id('a2'), 'zz110-laundry@example.com'), (pg_temp.id('a3'), 'zz110-admin@example.com'),
  (pg_temp.id('a4'), 'zz110-finance@example.com'), (pg_temp.id('a5'), 'zz110-owner@example.com'), (pg_temp.id('a6'), 'zz110-cleaner2@example.com'),
  (pg_temp.id('a7'), 'zz110-maint@example.com'), (pg_temp.id('a8'), 'zz110-other@example.com');
insert into public.properties(id, name, is_active) values (pg_temp.id('b0'), 'Zz S110 fixture property', true), (pg_temp.id('b1'), 'Zz S110 other property', true);
select is(pg_temp.dml($q$insert into public.staff_access_profiles(user_id, role) values ('d1100000-0000-4000-8000-0000000000a2', 'laundry')$q$), 'ok', 'the role check accepts laundry');
select is(pg_temp.dml($q$insert into public.staff_access_profiles(user_id, role) values ('d1100000-0000-4000-8000-0000000000a7', 'bogus')$q$), '23514', 'the role check still refuses an unknown role');
insert into public.staff_access_profiles(user_id, role) values
  (pg_temp.id('a1'), 'cleaner'), (pg_temp.id('a3'), 'admin'), (pg_temp.id('a4'), 'finance'), (pg_temp.id('a5'), 'owner'),
  (pg_temp.id('a6'), 'cleaner'), (pg_temp.id('a7'), 'maintenance'), (pg_temp.id('a8'), 'cleaner');
insert into public.staff_property_access(user_id, property_id) select u, pg_temp.id('b0') from unnest(array[pg_temp.id('a1'), pg_temp.id('a2'), pg_temp.id('a3'), pg_temp.id('a4'), pg_temp.id('a6'), pg_temp.id('a7')]) u;
insert into public.staff_property_access(user_id, property_id) values (pg_temp.id('a8'), pg_temp.id('b1'));
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, reorder_below, is_consumable, unit_cost, units_per_purchase, purchase_unit) values
  (pg_temp.id('c1'), pg_temp.id('b0'), 'Zz110 Soap', 'Toiletries', 'pc', 5, 2, true, null, 1, null),
  (pg_temp.id('c3'), pg_temp.id('b0'), 'Zz110 Tissue', 'Toiletries', 'roll', 6, 1, true, 10, 1, null),
  (pg_temp.id('c4'), pg_temp.id('b0'), 'Zz110 Laundry Sheets', 'Laundry', 'pc', 10, 2, true, null, 1, null),
  (pg_temp.id('c5'), pg_temp.id('b1'), 'Zz110 Elsewhere', 'Other', 'pc', 1, null, true, null, 1, null);

-- =============================================================================================================================================
-- Part 1: roles and capabilities (20)
-- =============================================================================================================================================
select ok(public.staff_access_allowed('laundry', 'report_supply', null, null), 'laundry has report_supply');
select ok(public.staff_access_allowed('laundry', 'read_operations', null, null), 'laundry has read_operations');
select ok(not public.staff_access_allowed('laundry', 'submit_cleaning', null, null), 'laundry lacks submit_cleaning');
select ok(not public.staff_access_allowed('laundry', 'inspect_cleaning', null, null), 'laundry lacks inspect_cleaning');
select ok(not public.staff_access_allowed('laundry', 'manage_inventory', null, null), 'laundry lacks manage_inventory');
select ok(not public.staff_access_allowed('laundry', 'read_finance', null, null), 'laundry lacks read_finance');
select ok(not public.staff_access_allowed('laundry', 'manage_operations', null, null), 'laundry lacks manage_operations');
select ok(not public.staff_access_allowed('laundry', 'approve_payment', null, null), 'laundry lacks every money capability');
select ok(not public.staff_access_allowed('laundry', 'report_supply', now(), null), 'a disabled laundry account has nothing');
select ok(public.staff_access_allowed('cleaner', 'report_supply', null, null) and public.staff_access_allowed('inspector', 'report_supply', null, null)
          and public.staff_access_allowed('owner', 'report_supply', null, null) and public.staff_access_allowed('admin', 'report_supply', null, null), 'owner, admin, inspector and cleaner have report_supply');
select ok(not public.staff_access_allowed('finance', 'report_supply', null, null) and not public.staff_access_allowed('maintenance', 'report_supply', null, null), 'finance and maintenance do not');
select ok(public.staff_access_allowed('cleaner', 'submit_cleaning', null, null) and not public.staff_access_allowed('cleaner', 'read_finance', null, null), 'the cleaner matrix is unchanged');
select ok(public.staff_access_allowed('finance', 'read_finance', null, null) and public.staff_access_allowed('owner', 'manage_staff', null, null), 'finance and owner keep their capabilities');
select ok(pg_get_functiondef('public.manage_staff_access(uuid,text,text,uuid[],text)'::regprocedure) like '%''maintenance'',''laundry'')%', 'manage_staff_access accepts laundry in its role list');

select pg_temp.as_user(pg_temp.id('a2'));
select is((select pg_temp.try($q$select public.record_inventory_usage('d1100000-0000-4000-8000-0000000000b0', current_date, 'Laundry', null, '[{"item_id":"d1100000-0000-4000-8000-0000000000c4","used_qty":3}]'::jsonb)$q$) ->> 'ok'), 'true',
  'record_inventory_usage accepts laundry');
reset role;
select is((select qty_on_hand from public.inventory_items where id = pg_temp.id('c4')), 7.00::numeric, 'the laundry usage took 3 off the shelf');
select pg_temp.as_user(pg_temp.id('a1'));
select is((select pg_temp.try($q$select public.record_inventory_usage('d1100000-0000-4000-8000-0000000000b0', current_date, 'Cleaner', null, '[{"item_id":"d1100000-0000-4000-8000-0000000000c4","used_qty":1}]'::jsonb)$q$) ->> 'ok'), 'true',
  'record_inventory_usage still accepts a cleaner');
select pg_temp.as_user(pg_temp.id('a4'));
select is((select pg_temp.try($q$select public.record_inventory_usage('d1100000-0000-4000-8000-0000000000b0', current_date, 'Finance', null, '[{"item_id":"d1100000-0000-4000-8000-0000000000c4","used_qty":1}]'::jsonb)$q$) ->> 'err'), '42501',
  'record_inventory_usage still refuses finance');
select pg_temp.as_user(pg_temp.id('a8'));
select is((select pg_temp.try($q$select public.record_inventory_usage('d1100000-0000-4000-8000-0000000000b0', current_date, 'Other', null, '[{"item_id":"d1100000-0000-4000-8000-0000000000c4","used_qty":1}]'::jsonb)$q$) ->> 'err'), '42501',
  'record_inventory_usage refuses a person of another property');
reset role;
select is((select qty_on_hand from public.inventory_items where id = pg_temp.id('c4')), 6.00::numeric, 'only the two allowed usages were applied');

-- =============================================================================================================================================
-- Part 2: utility rates (19)
-- =============================================================================================================================================
select ok(not has_table_privilege('authenticated', 'public.utility_rates', 'select') and not has_table_privilege('anon', 'public.utility_rates', 'select')
          and not has_table_privilege('service_role', 'public.utility_rates', 'insert'), 'utility_rates has no direct grants');
select ok(not has_table_privilege('authenticated', 'public.inventory_receipt_drafts', 'select') and not has_table_privilege('authenticated', 'public.inventory_receipt_drafts', 'update'), 'inventory_receipt_drafts has no direct grants');
select ok((select relrowsecurity from pg_class where oid = 'public.utility_rates'::regclass) and (select relrowsecurity from pg_class where oid = 'public.inventory_receipt_drafts'::regclass), 'row level security is on for both new tables');
select pg_temp.as_user(pg_temp.id('a1'));
select is((select pg_temp.try($q$select public.utility_rate_set_v1(12.5, current_date, null)$q$) ->> 'error'), 'forbidden', 'a cleaner cannot set the rate');
select pg_temp.as_user(pg_temp.id('a3'));
select is((select pg_temp.try($q$select public.utility_rate_set_v1(0, current_date, null)$q$) ->> 'error'), 'invalid_rate', 'a rate of 0 is refused');
select is((select pg_temp.try($q$select public.utility_rate_set_v1(100, current_date, null)$q$) ->> 'error'), 'invalid_rate', 'a rate of 100 or more is refused');
select is((select pg_temp.try($q$select public.utility_rate_set_v1(-3, current_date, null)$q$) ->> 'error'), 'invalid_rate', 'a negative rate is refused');
select is((select pg_temp.try($q$select public.utility_rate_set_v1(12.5, null, null)$q$) ->> 'error'), 'invalid_rate', 'a rate without a date is refused');
select is((select pg_temp.try($q$select public.utility_rate_set_v1(12.5, current_date, 'Zz110 test rate')$q$) ->> 'ok'), 'true', 'owner/admin sets a rate');
create temp table _rate as select (public.utility_rate_set_v1(12.5, current_date, 'Zz110 test rate') ->> 'id')::uuid as id;
reset role;
select is((select count(*)::integer from public.utility_rates where php_per_kwh = 12.5 and effective_from = current_date), 1, 'the same rate on the same day is stored once (idempotent)');
select is((select source from public.utility_rates where id = (select id from _rate)), 'manual', 'a rate set by a person is source manual');
select pg_temp.as_user(pg_temp.id('a3'));
select is((select pg_temp.try($q$select public.utility_rate_record_auto_v1(12.9, current_date - 5, 'https://example.invalid/post/1')$q$) ->> 'err'), '42501', 'record_auto refuses a signed-in person');
select pg_temp.as_service();
select is((select public.utility_rate_record_auto_v1(12.9, current_date - 5, 'https://example.invalid/post/1') ->> 'inserted'), 'true', 'the service role records an auto rate');
select is((select public.utility_rate_record_auto_v1(12.9, current_date - 5, 'https://example.invalid/post/1') ->> 'inserted'), 'false', 'the same auto rate again is not inserted twice');
select is((select public.utility_rate_record_auto_v1(150, current_date, null) ->> 'error'), 'invalid_rate', 'an auto rate out of bounds is refused');
reset role;
select is((select count(*)::integer from public.utility_rates where source = 'auto' and effective_from = current_date - 5), 1, 'one auto row exists');
select pg_temp.as_user(pg_temp.id('a4'));
select is((select jsonb_array_length(public.utility_rate_list_v1(pg_temp.id('b0'), 20) -> 'rates')), 2, 'finance reads the rate list (manual + auto)');
select pg_temp.as_user(pg_temp.id('a1'));
select is((select public.utility_rate_list_v1(pg_temp.id('b0'), 20) ->> 'error'), 'forbidden', 'a cleaner cannot read the rate list');
reset role;

-- =============================================================================================================================================
-- Part 3: kpi_tab_v1 (22). Fixtures: one session of 2 nights with a 20 kWh reading (10 kWh a night), one misread reading that must not count, 2 brownouts (2.5 h + 1.5 h), 1 water cut (3 h),
-- tissue used 3 in one turnover (6 on the shelf, 3 / 30 a day -> 60 days left), soap used 1.
-- =============================================================================================================================================
insert into public.cleaning_sessions(id, property_id, cleaned_at, nights_stayed, checkout_date, cleaning_type) values
  (pg_temp.id('d1'), pg_temp.id('b0'), now(), 2, public.manila_today(), 'turnover');
insert into public.meter_readings(id, session_id, electric_delta, kwh_per_night, recorded_at, property_id, meter_flag) values
  (pg_temp.id('e1'), pg_temp.id('d1'), 20, 10, now(), pg_temp.id('b0'), null),
  (pg_temp.id('e2'), pg_temp.id('d1'), 999, 499.5, now() - interval '1 minute', pg_temp.id('b0'), 'misread');
insert into public.ops_notices(property_id, notice_type, title, effective_date, duration_hours, is_active) values
  (pg_temp.id('b0'), 'brownout', 'Zz110 brownout 1', public.manila_today(), 2.5, true), (pg_temp.id('b0'), 'brownout', 'Zz110 brownout 2', public.manila_today(), 1.5, true),
  (pg_temp.id('b0'), 'brownout', 'Zz110 brownout off', public.manila_today(), 9.0, false), (pg_temp.id('b0'), 'water', 'Zz110 water', public.manila_today(), 3.0, true);
insert into public.ops_notices(property_id, notice_type, title, description, effective_date, duration_hours, is_active) values
  (pg_temp.id('b0'), 'note', 'Zz110 PLDT internet down', 'Zz110 fiber line cut near the gate', public.manila_today(), 2.0, true),
  (pg_temp.id('b0'), 'note', 'Zz110 router moved', 'Zz110 the wifi router is on the shelf now', public.manila_today(), null, true),
  (pg_temp.id('b0'), 'maintenance', 'Zz110 pest control', 'Zz110 no entry to the pantry', public.manila_today(), 1.0, true);
insert into public.inventory_usage(item_id, used_qty, session_date, property_id) values (pg_temp.id('c3'), 3, public.manila_today(), pg_temp.id('b0'));
insert into public.staff_pay_requests(property_id, status, total_amount) values (pg_temp.id('b0'), 'paid', 500), (pg_temp.id('b0'), 'cancelled', 900);

select pg_temp.as_user(pg_temp.id('a1'));
create temp table _k_cleaner as select public.kpi_tab_v1(pg_temp.id('b0')) as j;
select pg_temp.as_user(pg_temp.id('a2'));
create temp table _k_laundry as select public.kpi_tab_v1(pg_temp.id('b0')) as j;
select pg_temp.as_user(pg_temp.id('a4'));
create temp table _k_fin as select public.kpi_tab_v1(pg_temp.id('b0')) as j;
select pg_temp.as_user(pg_temp.id('a3'));
create temp table _k_admin as select public.kpi_tab_v1(pg_temp.id('b0')) as j;
create temp table _k_old as select public.kpi_tab_v1(pg_temp.id('b0'), date '2020-01-15') as j;
reset role;
grant all on _k_cleaner, _k_laundry, _k_fin, _k_admin, _k_old, _rate to public;

select is((select j ->> 'ok' from _k_cleaner), 'true', 'a cleaner reads the KPI tab');
select ok(not ((select j from _k_cleaner) ? 'admin'), 'no admin key for a cleaner');
select ok(not ((select j from _k_laundry) ? 'admin') and (select j ->> 'ok' from _k_laundry) = 'true', 'no admin key for laundry, who still reads the tab');
select ok((select j from _k_fin) ? 'admin' and (select j from _k_admin) ? 'admin', 'the admin key is present for finance and for admin');
select ok(position('php_per_kwh' in (select j::text from _k_cleaner)) = 0 and position('cost' in (select j::text from _k_cleaner)) = 0 and position('pay' in (select j::text from _k_cleaner)) = 0,
  'the cleaner payload carries no rate, cost or pay');
select is((select j ->> 'month' from _k_cleaner), to_char(date_trunc('month', public.manila_today()), 'YYYY-MM-DD'), 'the month is the first day of the current Manila month');
select is((select (j -> 'utility' ->> 'kwh_month')::numeric from _k_cleaner), 20.00::numeric, 'kwh_month counts the usable reading only (the misread 999 is out)');
select is((select (j -> 'utility' ->> 'nights_month')::numeric from _k_cleaner), 2::numeric, 'nights_month is the nights of the usable reading');
select is((select (j -> 'utility' ->> 'kwh_per_night')::numeric from _k_cleaner), 10.00::numeric, 'kwh_per_night is 20 / 2');
select is((select (j -> 'utility' -> 'last_reading' ->> 'delta_kwh')::numeric from _k_cleaner), 20.00::numeric, 'last_reading is the newest usable reading');
select is((select jsonb_array_length(j -> 'utility' -> 'per_stay') from _k_cleaner), 1, 'per_stay holds the one usable stay');
select is((select (j -> 'utility' -> 'brownouts' ->> 'count')::integer || '/' || (j -> 'utility' -> 'brownouts' ->> 'hours') from _k_cleaner), '2/4.0', 'brownouts: 2 active notices, 4.0 hours (the inactive one is out)');
select is((select (j -> 'utility' -> 'water_cuts' ->> 'count')::integer || '/' || (j -> 'utility' -> 'water_cuts' ->> 'hours') from _k_cleaner), '1/3.0', 'water cuts: 1, 3.0 hours');
select is((select (j -> 'inventory' ->> 'turnovers_month')::integer from _k_cleaner), 1, 'turnovers_month is 1');
select is((select (e ->> 'used_per_turnover')::numeric from _k_cleaner, jsonb_array_elements(j -> 'inventory' -> 'per_turnover') e where e ->> 'item_id' = pg_temp.id('c3')::text), 3.00::numeric, 'tissue is used 3 per turnover');
select is((select (e ->> 'days_left')::integer from _k_cleaner, jsonb_array_elements(j -> 'inventory' -> 'runs_out') e where e ->> 'item_id' = pg_temp.id('c3')::text), 60, 'tissue runs out in 60 days (6 on the shelf, 3 in 30 days)');
select ok((select (j -> 'inventory' ->> 'low_now')::integer from _k_cleaner) >= 0 and jsonb_typeof((select j -> 'inventory' -> 'runs_out' from _k_cleaner)) = 'array', 'low_now and runs_out have the contract shape');
select is((select (j -> 'admin' ->> 'month_kwh_cost')::numeric from _k_admin), 250.00::numeric, 'month_kwh_cost is 20 kWh at the 12.5 rate');
select is((select (j -> 'admin' ->> 'last_reading_cost')::numeric from _k_admin), 250.00::numeric, 'last_reading_cost is the last 20 kWh at the 12.5 rate');
select is((select (j -> 'admin' -> 'rate' ->> 'php_per_kwh')::numeric from _k_admin), 12.5::numeric, 'the current rate is the newest effective rate (the manual one dated today)');
select is((select (j -> 'admin' ->> 'cleaning_pay_month')::numeric from _k_admin), 500.00::numeric, 'cleaning_pay_month counts the paid request and not the cancelled one');
select is((select (j -> 'admin' ->> 'supply_cost_per_turnover')::numeric from _k_admin), 30.00::numeric, 'supply_cost_per_turnover is 3 tissue x 10 / 1 turnover');
select is((select (j -> 'utility' ->> 'kwh_month')::numeric from _k_old), 0::numeric, 'another month reads its own numbers');
select is((select (j -> 'utility' -> 'internet_cuts' ->> 'count')::integer || '/' || (j -> 'utility' -> 'internet_cuts' ->> 'hours') from _k_cleaner), '1/2.0',
  'internet_cuts: only the note with an internet word AND an outage word counts (the moved router and the pest control do not)');
select ok((select (j -> 'admin') ?& array['net_month', 'revenue_month', 'costs_month', 'occupancy', 'adr', 'sold_nights', 'sellable_nights', 'direct_share'] from _k_admin)
          and (select (j -> 'admin') ?& array['net_month', 'revenue_month', 'costs_month', 'occupancy', 'adr', 'sold_nights', 'sellable_nights', 'direct_share'] from _k_fin),
  'the admin block carries net_month, revenue_month, costs_month, occupancy, adr, sold_nights, sellable_nights and direct_share for admin and finance');
select ok(position('occupancy' in (select j::text from _k_cleaner)) = 0 and position('net_month' in (select j::text from _k_laundry)) = 0 and position('revenue' in (select j::text from _k_laundry)) = 0,
  'the new finance keys are absent for cleaner and laundry');
select pg_temp.as_user(pg_temp.id('a8'));
select is((select public.kpi_tab_v1(pg_temp.id('b0')) ->> 'error'), 'forbidden', 'a person of another property is refused');
reset role;

-- =============================================================================================================================================
-- Part 4: receipt drafts (27)
-- =============================================================================================================================================
insert into public.inventory_receipt_drafts(id, property_id, created_by, receipt_path, vendor, purchased_on, total, lines) values
  (pg_temp.id('f1'), pg_temp.id('b0'), pg_temp.id('a1'), 'expense-receipts/zz110/a1/one.jpg', 'Zz110 Shop', public.manila_today(), 250.00,
   jsonb_build_array(jsonb_build_object('line_no', 1, 'description', 'Soap bar', 'qty', 5, 'unit_cost', 20, 'match_item_id', pg_temp.id('c1'), 'match_score', 0.9),
                     jsonb_build_object('line_no', 2, 'description', 'Mystery thing', 'qty', 1, 'unit_cost', 150, 'match_item_id', null, 'match_score', 0),
                     jsonb_build_object('line_no', 3, 'description', 'Bag', 'qty', 1, 'unit_cost', 0, 'match_item_id', null, 'match_score', 0)));

select pg_temp.as_user(pg_temp.id('a1'));
create temp table _d_cleaner as select public.inventory_receipt_draft_v1(pg_temp.id('f1')) as j;
select pg_temp.as_user(pg_temp.id('a3'));
create temp table _d_admin as select public.inventory_receipt_draft_v1(pg_temp.id('f1')) as j;
reset role;
grant all on _d_cleaner, _d_admin to public;
select is((select j -> 'draft' ->> 'status' from _d_cleaner), 'draft', 'the creator reads her draft');
select is((select jsonb_array_length(j -> 'draft' -> 'lines') from _d_cleaner), 3, 'the draft shows its 3 lines');
select is((select j -> 'draft' -> 'lines' -> 0 -> 'match' ->> 'name' from _d_cleaner), 'Zz110 Soap', 'line 1 shows the matched item name');
select ok(position('unit_cost' in (select j::text from _d_cleaner)) = 0 and position('"total"' in (select j::text from _d_cleaner)) = 0 and position('250' in (select j::text from _d_cleaner)) = 0,
  'the staff draft read has no unit_cost and no total');
select ok((select j -> 'draft' ? 'total' from _d_admin) and (select j -> 'draft' -> 'lines' -> 0 ? 'unit_cost' from _d_admin), 'owner/admin see the total and each unit_cost');
select pg_temp.as_user(pg_temp.id('a6'));
select is((select public.inventory_receipt_draft_v1(pg_temp.id('f1')) ->> 'error'), 'forbidden', 'another cleaner cannot read it');
select pg_temp.as_user(pg_temp.id('a4'));
select is((select public.inventory_receipt_draft_v1(pg_temp.id('f1')) ->> 'error'), 'forbidden', 'finance without report_supply cannot read it');
select pg_temp.as_user(pg_temp.id('a1'));
select is((select public.inventory_receipt_draft_v1(pg_temp.id('ff')) ->> 'error'), 'not_found', 'an unknown draft is not_found');

-- refusals write nothing
select is((select public.inventory_receipt_confirm_v1(pg_temp.id('f1'), '[{"line_no":1,"item_id":"d1100000-0000-4000-8000-0000000000c1","qty_units":0}]'::jsonb) ->> 'error'), 'bad_line', 'qty 0 is a bad line');
select is((select public.inventory_receipt_confirm_v1(pg_temp.id('f1'), '[{"line_no":9,"item_id":"d1100000-0000-4000-8000-0000000000c1","qty_units":1}]'::jsonb) ->> 'error'), 'bad_line', 'an unknown line_no is a bad line');
select is((select public.inventory_receipt_confirm_v1(pg_temp.id('f1'), '[{"line_no":1,"item_id":"d1100000-0000-4000-8000-0000000000c5","qty_units":1}]'::jsonb) ->> 'error'), 'bad_line', 'an item of another property is a bad line');
select is((select public.inventory_receipt_confirm_v1(pg_temp.id('f1'), '[{"line_no":1,"item_id":"d1100000-0000-4000-8000-0000000000c1","new_item":{"name":"Zz110 Both","category":"X"},"qty_units":1}]'::jsonb) ->> 'error'), 'bad_line', 'item_id and new_item together are a bad line');
select is((select public.inventory_receipt_confirm_v1(pg_temp.id('f1'), '[{"line_no":1,"skip":true},{"line_no":2,"skip":true}]'::jsonb) ->> 'error'), 'no_lines', 'all lines skipped records nothing');
select pg_temp.as_user(pg_temp.id('a6'));
select is((select public.inventory_receipt_confirm_v1(pg_temp.id('f1'), '[{"line_no":1,"item_id":"d1100000-0000-4000-8000-0000000000c1","qty_units":1}]'::jsonb) ->> 'error'), 'forbidden', 'another cleaner cannot confirm it');
reset role;
select ok((select count(*) from public.inventory_purchases where item_id in (pg_temp.id('c1'))) = 0 and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c1')) = 5.00
          and (select count(*) from public.transactions where ocr_raw ->> 'draft_id' = pg_temp.id('f1')::text) = 0, 'the refused confirms wrote no purchase, no stock, no expense');

-- the confirm
select pg_temp.as_user(pg_temp.id('a1'));
create temp table _c1 as select public.inventory_receipt_confirm_v1(pg_temp.id('f1'),
  jsonb_build_array(jsonb_build_object('line_no', 1, 'item_id', pg_temp.id('c1'), 'qty_units', 6),
                    jsonb_build_object('line_no', 2, 'new_item', jsonb_build_object('name', 'Zz110 Mystery Item', 'category', 'Supplies', 'unit', 'pc', 'is_consumable', true), 'qty_units', 2),
                    jsonb_build_object('line_no', 3, 'skip', true)),
  null, 'zz110-confirm-key-0001') as j;
create temp table _c2 as select public.inventory_receipt_confirm_v1(pg_temp.id('f1'), '[{"line_no":1,"item_id":"d1100000-0000-4000-8000-0000000000c1","qty_units":6}]'::jsonb, null, 'zz110-confirm-key-0001') as j;
create temp table _c3 as select public.inventory_receipt_confirm_v1(pg_temp.id('f1'), '[{"line_no":1,"item_id":"d1100000-0000-4000-8000-0000000000c1","qty_units":6}]'::jsonb, null, 'zz110-confirm-key-0002') as j;
reset role;
grant all on _c1, _c2, _c3 to public;
select ok((select j ->> 'ok' from _c1) = 'true' and (select (j ->> 'purchase_count')::integer from _c1) = 2 and (select jsonb_array_length(j -> 'new_items') from _c1) = 1 and (select j -> 'new_items' -> 0 ->> 'line_no' from _c1) = '2' and (select j ->> 'undo_token' from _c1) = pg_temp.id('f1')::text,
  'confirm answers ok, 2 purchases, 1 new item and an undo token');
select ok(position('cost' in (select j::text from _c1)) = 0 and position('total' in (select j::text from _c1)) = 0 and position('250' in (select j::text from _c1)) = 0, 'the confirm answer carries no price');
select is((select qty_on_hand from public.inventory_items where id = pg_temp.id('c1')), 11.00::numeric, 'soap went from 5 to 11');
select is((select qty_on_hand from public.inventory_items where name = 'Zz110 Mystery Item' and property_id = pg_temp.id('b0')), 2.00::numeric, 'the new item holds the 2 confirmed units');
select is((select unit_cost from public.inventory_purchases where item_id = pg_temp.id('c1')), 16.6667::numeric, 'the cost per unit is the receipt line 5 x 20 over the 6 confirmed units');
select is((select count(*)::integer from public.transactions where ocr_raw ->> 'draft_id' = pg_temp.id('f1')::text), 1, 'exactly one finance transaction');
select ok((select status = 'pending_review' and txn_type = 'expense' and gross_amount = 250.00 and receipt_image_path = 'expense-receipts/zz110/a1/one.jpg' and category = 'supplies' from public.transactions where ocr_raw ->> 'draft_id' = pg_temp.id('f1')::text),
  'it is a pending_review expense of the server-held total with the receipt path');
select is((select count(*)::integer from public.transactions where txn_type = 'income' and ocr_raw ->> 'draft_id' = pg_temp.id('f1')::text), 0, 'never income');
select ok((select count(*) = 1 and bool_and(status = 'open') and bool_and(position('250' in detail) = 0 and position('Zz110 Shop' in title) > 0) from public.follow_up_tasks where idempotency_key = 'system:receipt_review:' || pg_temp.id('f1')::text),
  'one open owner/admin task, a plain sentence with no amount');
select ok((select j ->> 'replayed' from _c2) = 'true' and (select j ->> 'purchase_count' from _c2) = '2', 'the same key again replays the first answer');
select is((select j ->> 'error' from _c3), 'not_draft', 'a new key on a confirmed draft is refused');
select is((select count(*)::integer from public.inventory_purchases where notes like '%' || pg_temp.id('f1')::text || '%'), 2, 'still 2 purchases: a receipt is never recorded twice');
select is((select status from public.inventory_receipt_drafts where id = pg_temp.id('f1')), 'confirmed', 'the draft is confirmed');

-- undo
select pg_temp.as_user(pg_temp.id('a6'));
select is((select public.inventory_receipt_undo_v1(pg_temp.id('f1')) ->> 'error'), 'forbidden', 'another cleaner cannot undo it');
select pg_temp.as_user(pg_temp.id('a1'));
select is((select public.inventory_receipt_undo_v1(pg_temp.id('f1')) ->> 'ok'), 'true', 'the creator undoes it within 24 hours');
reset role;
select ok((select qty_on_hand from public.inventory_items where id = pg_temp.id('c1')) = 5.00 and (select qty_on_hand from public.inventory_items where name = 'Zz110 Mystery Item') = 0.00
          and (select count(*) from public.inventory_purchases where notes like '%' || pg_temp.id('f1')::text || '%') = 0, 'undo reverses the stock and removes the purchases');
select ok((select status from public.transactions where ocr_raw ->> 'draft_id' = pg_temp.id('f1')::text) = 'void'
          and (select status from public.follow_up_tasks where idempotency_key = 'system:receipt_review:' || pg_temp.id('f1')::text) = 'done'
          and (select status from public.inventory_receipt_drafts where id = pg_temp.id('f1')) = 'cancelled', 'undo voids the expense, closes the task and cancels the draft');
select pg_temp.as_user(pg_temp.id('a1'));
select is((select public.inventory_receipt_undo_v1(pg_temp.id('f1')) ->> 'error'), 'not_confirmed', 'an undone receipt cannot be undone twice');
select is((select public.inventory_receipt_confirm_v1(pg_temp.id('f1'), '[{"line_no":1,"item_id":"d1100000-0000-4000-8000-0000000000c1","qty_units":1}]'::jsonb) ->> 'error'), 'not_draft', 'an undone draft cannot be confirmed again');
reset role;

-- a reviewed expense blocks the undo; the 24 hour window; cancel; retention
insert into public.inventory_receipt_drafts(id, property_id, created_by, vendor, total, lines, created_at) values
  (pg_temp.id('f2'), pg_temp.id('b0'), pg_temp.id('a1'), 'Zz110 Shop', 40, '[{"line_no":1,"description":"Soap","qty":2,"unit_cost":20,"match_item_id":null}]'::jsonb, now()),
  (pg_temp.id('f3'), pg_temp.id('b0'), pg_temp.id('a1'), 'Zz110 Shop', 40, '[{"line_no":1,"description":"Soap","qty":2,"unit_cost":20,"match_item_id":null}]'::jsonb, now()),
  (pg_temp.id('f4'), pg_temp.id('b0'), pg_temp.id('a1'), 'Zz110 Shop', 40, '[{"line_no":1,"description":"Soap","qty":2,"unit_cost":20,"match_item_id":null}]'::jsonb, now()),
  (pg_temp.id('f5'), pg_temp.id('b0'), pg_temp.id('a1'), 'Zz110 Old', 40, '[{"line_no":1,"description":"Soap","qty":2,"unit_cost":20,"match_item_id":null}]'::jsonb, now() - interval '40 days'),
  (pg_temp.id('f6'), pg_temp.id('b0'), pg_temp.id('a2'), 'Zz110 Laundry', 10, '[{"line_no":1,"description":"Sheets","qty":1,"unit_cost":10,"match_item_id":null}]'::jsonb, now());
select pg_temp.as_user(pg_temp.id('a1'));
select is((select public.inventory_receipt_confirm_v1(pg_temp.id('f2'), '[{"line_no":1,"item_id":"d1100000-0000-4000-8000-0000000000c1","qty_units":2}]'::jsonb, null, 'zz110-confirm-key-f200') ->> 'ok'), 'true', 'a second draft is confirmed');
select is((select public.inventory_receipt_confirm_v1(pg_temp.id('f3'), '[{"line_no":1,"item_id":"d1100000-0000-4000-8000-0000000000c1","qty_units":2}]'::jsonb, null, 'zz110-confirm-key-f300') ->> 'ok'), 'true', 'a third draft is confirmed');
reset role;
update public.transactions set status = 'confirmed' where ocr_raw ->> 'draft_id' = pg_temp.id('f2')::text;
update public.inventory_receipt_drafts set confirmed_at = now() - interval '25 hours' where id = pg_temp.id('f3');
select pg_temp.as_user(pg_temp.id('a3'));
select is((select public.inventory_receipt_undo_v1(pg_temp.id('f2')) ->> 'error'), 'already_reviewed', 'an expense finance already confirmed blocks the undo');
select pg_temp.as_user(pg_temp.id('a1'));
select is((select public.inventory_receipt_undo_v1(pg_temp.id('f3')) ->> 'error'), 'forbidden', 'the creator cannot undo after 24 hours');
select pg_temp.as_user(pg_temp.id('a3'));
select is((select public.inventory_receipt_undo_v1(pg_temp.id('f3')) ->> 'ok'), 'true', 'an admin undoes it at any time');
select pg_temp.as_user(pg_temp.id('a6'));
select is((select public.inventory_receipt_cancel_v1(pg_temp.id('f4')) ->> 'error'), 'forbidden', 'another cleaner cannot cancel a draft');
select pg_temp.as_user(pg_temp.id('a1'));
select is((select public.inventory_receipt_cancel_v1(pg_temp.id('f4')) ->> 'ok'), 'true', 'the creator cancels her draft');
select is((select public.inventory_receipt_cancel_v1(pg_temp.id('f4')) ->> 'ok'), 'true', 'cancel is idempotent');
select is((select public.inventory_receipt_cancel_v1(pg_temp.id('f2')) ->> 'error'), 'not_draft', 'a confirmed draft cannot be cancelled');
select pg_temp.as_user(pg_temp.id('a2'));
select is((select public.inventory_receipt_draft_v1(pg_temp.id('f6')) -> 'draft' ->> 'vendor'), 'Zz110 Laundry', 'a laundry person reads her own draft');
select is((select public.inventory_receipt_confirm_v1(pg_temp.id('f6'), '[{"line_no":1,"item_id":"d1100000-0000-4000-8000-0000000000c4","qty_units":4}]'::jsonb, null, 'zz110-confirm-key-f600') ->> 'ok'), 'true', 'a laundry person confirms her receipt');
reset role;
select is((select qty_on_hand from public.inventory_items where id = pg_temp.id('c4')), 10.00::numeric, 'laundry sheets 6 + 4 = 10');
-- manual supply entry (no photo): laundry may call it, no finance transaction, idempotent, undo works
select pg_temp.as_user(pg_temp.id('a2'));
create temp table _m1 as select public.inventory_receipt_manual_v1(
  jsonb_build_array(jsonb_build_object('item_id', pg_temp.id('c4'), 'qty_units', 2),
                    jsonb_build_object('new_item', jsonb_build_object('name', 'Zz110 Hand Item', 'category', 'Supplies', 'unit', 'pc', 'is_consumable', true), 'qty_units', 3)),
  null, 'Zz110 Corner Store', 'zz110-manual-key-0001') as j;
create temp table _m2 as select public.inventory_receipt_manual_v1('[{"item_id":"d1100000-0000-4000-8000-0000000000c4","qty_units":2}]'::jsonb, null, null, 'zz110-manual-key-0001') as j;
create temp table _m3 as select public.inventory_receipt_manual_v1('[{"item_id":"d1100000-0000-4000-8000-0000000000c4","qty_units":0}]'::jsonb, null, null, 'zz110-manual-key-0002') as j;
select pg_temp.as_user(pg_temp.id('a4'));
create temp table _m4 as select public.inventory_receipt_manual_v1('[{"item_id":"d1100000-0000-4000-8000-0000000000c4","qty_units":1}]'::jsonb, null, null, 'zz110-manual-key-0003') as j;
reset role;
grant all on _m1, _m2, _m3, _m4 to public;
select ok((select j ->> 'ok' from _m1) = 'true' and (select (j ->> 'purchase_count')::integer from _m1) = 2 and (select j -> 'new_items' -> 0 ->> 'line_no' from _m1) = '2'
          and (select j ->> 'draft_id' from _m1) is not null, 'manual: a laundry person records 2 lines; the new item comes back as {line_no 2, item_id}');
select is((select qty_on_hand from public.inventory_items where id = pg_temp.id('c4')), 12.00::numeric, 'manual: the existing item rose by 2');
select is((select qty_on_hand from public.inventory_items where name = 'Zz110 Hand Item'), 3.00::numeric, 'manual: the new item holds 3');
select ok((select count(*) from public.transactions where ocr_raw ->> 'draft_id' = (select j ->> 'draft_id' from _m1)) = 0
          and (select status = 'confirmed' and receipt_path is null and total is null and transaction_id is null from public.inventory_receipt_drafts where id = (select (j ->> 'draft_id')::uuid from _m1)),
  'manual: a confirmed draft with no receipt, no price and NO finance transaction');
select ok((select j ->> 'replayed' from _m2) = 'true' and (select j ->> 'draft_id' from _m2) = (select j ->> 'draft_id' from _m1)
          and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c4')) = 12.00, 'manual: the same key replays and adds nothing');
select is((select j ->> 'error' from _m3), 'bad_line', 'manual: qty 0 is a bad line');
select is((select j ->> 'error' from _m4), 'forbidden', 'manual: finance, without report_supply, is refused');
select is((select count(*)::integer from public.follow_up_tasks where idempotency_key = 'system:receipt_review:' || (select j ->> 'draft_id' from _m1)), 1, 'manual: one owner/admin task');
select pg_temp.as_user(pg_temp.id('a2'));
select is((select public.inventory_receipt_undo_v1((select (j ->> 'draft_id')::uuid from _m1)) ->> 'ok'), 'true', 'manual: the same person undoes it');
reset role;
select ok((select qty_on_hand from public.inventory_items where id = pg_temp.id('c4')) = 10.00 and (select qty_on_hand from public.inventory_items where name = 'Zz110 Hand Item') = 0.00,
  'manual: undo reverses the stock');
select is((select count(*)::integer from public.inventory_receipt_drafts where id = pg_temp.id('f5')), 0, 'a draft older than 30 days is trimmed by the next confirm or cancel');

select * from finish();
rollback;
