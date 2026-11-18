-- Session 120 (lane S): release s120_usage_learning_20261120. record_inventory_anchor_v1 (count and receipt anchors), s_inventory_usage_recompute_v1,
-- the hooks in s_apply_inventory_count_core_v1, get_inventory_usage_kpi_v1 and the closed intervals table.
-- Synthetic fixtures only (uuids e1200000-..., property ...b0, items "Zz S120 ..."); every lookup is scoped to them because a real backup holds real rows.
-- Sessions (days ago): turnover 85 75 65 55 45 35 25 20 15, mid_stay 12 (never counted), deep_clean 8 (counted). Windows below are counted from that list.
-- Everything rolls back.
begin;
select plan(107);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid), public.current_staff_active(text[]) to authenticated, service_role;
grant execute on function public.admin_require(text, uuid) to authenticated;

create function pg_temp.anc(p_item uuid, p_q numeric, p_ago interval, p_src text default 'count') returns jsonb language sql as
$$ select public.record_inventory_anchor_v1($1, $2, now() - $3, $4) $$;

-- fixtures -------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values ('e1200000-0000-4000-8000-0000000000b0', 'Synthetic S120', true);
insert into auth.users(id) values ('e1200000-0000-4000-8000-000000000001'), ('e1200000-0000-4000-8000-000000000002');
insert into public.staff_access_profiles(user_id, role) values ('e1200000-0000-4000-8000-000000000001', 'admin');
insert into public.staff_property_access(user_id, property_id) values ('e1200000-0000-4000-8000-000000000001', 'e1200000-0000-4000-8000-0000000000b0');

insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, consumption_per_booking, usage_baseline_per_turnover) values
  ('e1200000-0000-4000-8000-0000000000a1', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 A', 'Other', 'pc', 500, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000000a2', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 B', 'Other', 'pc', 500, true, true, 1.00, 1.0),
  ('e1200000-0000-4000-8000-0000000000a3', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 C', 'Other', 'pc', 500, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000000a4', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 D', 'Other', 'pc', 500, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000000a5', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 E', 'Other', 'pc', 500, true, true, 2.00, null),
  ('e1200000-0000-4000-8000-0000000000a6', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 F', 'Other', 'pc', 500, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000000a7', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 G', 'Other', 'pc', 500, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000000a9', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 I', 'Other', 'pc', 100, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000000aa', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 U', 'Other', 'pc', 1,   true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000000ab', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 J', 'Other', 'pc', 20,  true, true, 2.00, 1.0);
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, units_per_purchase, movement_controlled_at, baseline_reviewed_by) values
  ('e1200000-0000-4000-8000-0000000000a8', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 H', 'Other', 'pc', 10, true, 1, now(), 'e1200000-0000-4000-8000-000000000001');
insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key) values
  ('e1200000-0000-4000-8000-0000000000a8', 'e1200000-0000-4000-8000-0000000000b0', 'reconcile', 0, 10, 'Baseline count: zz120', 'e1200000-0000-4000-8000-000000000001', 'zz120-s120-baseline-a8');

insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type)
select 'e1200000-0000-4000-8000-0000000000b0', 'zz-s120-' || d, 'Fixture', now() - make_interval(days => d), t
  from (values (85, 'turnover'), (75, 'turnover'), (65, 'turnover'), (55, 'turnover'), (45, 'turnover'), (35, 'turnover'),
               (25, 'turnover'), (20, 'turnover'), (15, 'turnover'), (12, 'mid_stay'), (8, 'deep_clean')) v(d, t);

-- 1-7. shape and grants --------------------------------------------------------------------------------------------------------------------
select ok((select relrowsecurity from pg_class where oid = 'public.inventory_usage_intervals'::regclass), 'RLS is on for the intervals table');
select ok(not has_table_privilege('anon', 'public.inventory_usage_intervals', 'select, insert, update, delete')
      and not has_table_privilege('authenticated', 'public.inventory_usage_intervals', 'select, insert, update, delete')
      and not has_table_privilege('service_role', 'public.inventory_usage_intervals', 'select, insert, update, delete'), 'the intervals table has no direct grant for any API role');
select is((select count(*)::int from information_schema.columns where table_schema = 'public' and table_name = 'inventory_items'
            and column_name in ('usage_baseline_per_turnover', 'usage_baseline_note', 'usage_state', 'last_refill_at', 'last_refill_qty', 'usage_updated_at')), 6, 'the six usage columns exist');
select ok(not has_function_privilege('anon', 'public.record_inventory_anchor_v1(uuid,numeric,timestamptz,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.record_inventory_anchor_v1(uuid,numeric,timestamptz,text)', 'execute')
      and not has_function_privilege('service_role', 'public.record_inventory_anchor_v1(uuid,numeric,timestamptz,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.s_inventory_usage_recompute_v1(uuid,timestamptz)', 'execute'), 'the anchor and the recompute are internal: no API role can call them');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'public'::regnamespace and position('record_inventory_anchor_v1' in p.prosrc) > 0
            and p.proname in ('s_apply_inventory_count_core_v1', 'record_inventory_receipt_v1', 'apply_inventory_purchase', 's_inventory_receipt_apply_v1')), 4,
  'the count core and the three receive paths carry the anchor hook');
select ok(position('usageState' in (select prosrc from pg_proc where oid = 'public.get_inventory_catalogue_v1(uuid)'::regprocedure)) > 0
      and position('usageCounts' in (select prosrc from pg_proc where oid = 'public.get_inventory_catalogue_v1(uuid)'::regprocedure)) > 0
      and position('baselineNote' in (select prosrc from pg_proc where oid = 'public.get_inventory_catalogue_v1(uuid)'::regprocedure)) > 0, 'the catalogue gained the usage keys (usageCounts included) and kept the old ones');
select ok(not has_function_privilege('anon', 'public.get_inventory_usage_kpi_v1(uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.get_inventory_usage_kpi_v1(uuid)', 'execute'), 'the KPI read is for signed-in users only (the function gate does the rest)');

-- 8-14. A: first anchor, accepted interval, baseline prior ------------------------------------------------------------------------------------
create temp table _r(k text primary key, v jsonb);
insert into _r select 'a1', pg_temp.anc('e1200000-0000-4000-8000-0000000000a1', 100, interval '30 days');
insert into _r select 'a2', pg_temp.anc('e1200000-0000-4000-8000-0000000000a1', 60, interval '5 days');
select is((select v ->> 'first_anchor' from _r where k = 'a1'), 'true', 'A: the first count is a first anchor');
select is((select reject_reason from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000a1' order by anchor_at limit 1), 'first anchor', 'A: the first anchor is stored, never learned');
select is((select v ->> 'accepted' from _r where k = 'a2'), 'true', 'A: 25 days, 4 turnovers, 40 used: accepted');
select is((select consumed || '/' || days || '/' || turnovers from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000a1' and accepted), '40/25.00/4', 'A: consumed 40 over 25.00 days and 4 turnovers (the mid-stay clean is not a turnover, the deep clean is)');
select is((select consumption_per_booking from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000a1'), 3.5714::numeric, 'A: the baseline prior pulls the rate: (1.0*10 + 40) / (10 + 4), not the raw 10');
select is((select usage_state from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000a1'), 'learning', 'A: one accepted interval under 60 days is learning');
select is((select predicted from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000a1' and accepted), 8::numeric, 'A: the forecast is the rate in force before the count (2.00) times the 4 turnovers');

-- 15-16. B: too short -------------------------------------------------------------------------------------------------------------------------
insert into _r select 'b1', pg_temp.anc('e1200000-0000-4000-8000-0000000000a2', 100, interval '9 days');
insert into _r select 'b2', pg_temp.anc('e1200000-0000-4000-8000-0000000000a2', 90, interval '3 days');
select is((select v ->> 'reason' from _r where k = 'b2'), 'too short', 'B: 6 days is too short');
select is((select consumption_per_booking || '/' || usage_state from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000a2'), '1.0000/baseline', 'B: a rejected interval moves nothing (the rate stays at the baseline it already held: the recompute after a rejected interval writes the baseline)');

-- 17-18. C: negative consumed -----------------------------------------------------------------------------------------------------------------
insert into _r select 'c1', pg_temp.anc('e1200000-0000-4000-8000-0000000000a3', 10, interval '30 days');
insert into _r select 'c2', pg_temp.anc('e1200000-0000-4000-8000-0000000000a3', 50, interval '5 days');
select is((select v ->> 'reason' from _r where k = 'c2'), 'unrecorded restock', 'C: the count went up with no recorded purchase: unrecorded restock');
select ok(not exists (select 1 from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000a3' and accepted), 'C: nothing is learned from it');

-- 19-20. D: purchases between the counts ------------------------------------------------------------------------------------------------------
insert into public.inventory_purchases(id, item_id, qty, created_at) values ('e1200000-0000-4000-8000-0000000000e2', 'e1200000-0000-4000-8000-0000000000a4', 50, now() - interval '20 days');
insert into public.inventory_purchases(id, item_id, qty, notes, created_at) values ('e1200000-0000-4000-8000-0000000000e1', 'e1200000-0000-4000-8000-0000000000a4', 99, 'Auto-restock from receipt OCR zz120', now() - interval '20 days');
insert into public.inventory_audit_log(entity_type, entity_id, action, after, actor, created_at)
  values ('inventory_items', 'e1200000-0000-4000-8000-0000000000a4', 'ocr_restock', '{"qty_added": 7, "purchase_id": "e1200000-0000-4000-8000-0000000000e1"}', 'zz120', now() - interval '20 days');
insert into _r select 'd1', pg_temp.anc('e1200000-0000-4000-8000-0000000000a4', 100, interval '30 days');
insert into _r select 'd2', pg_temp.anc('e1200000-0000-4000-8000-0000000000a4', 120, interval '5 days');
select ok((select received_between = 57 and consumed = 37 from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000a4' and accepted),
  'D: received 57 (the 50 purchase plus the 7 of the OCR audit row, not the OCR purchase row itself): 100 + 57 - 120 = 37');
select is((select consumption_per_booking from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000a4'), 3.3571::numeric, 'D: (10 + 37) / 14');

-- 21. E: no baseline, pure average ------------------------------------------------------------------------------------------------------------
insert into _r select 'e1', pg_temp.anc('e1200000-0000-4000-8000-0000000000a5', 100, interval '30 days');
insert into _r select 'e2', pg_temp.anc('e1200000-0000-4000-8000-0000000000a5', 80, interval '5 days');
select is((select consumption_per_booking from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000a5'), 5::numeric, 'E: no baseline, so the pure average 20 / 4');

-- 22-23. F: measured (70 days), prior drops out ---------------------------------------------------------------------------------------------------
insert into _r select 'f1', pg_temp.anc('e1200000-0000-4000-8000-0000000000a6', 200, interval '80 days');
insert into _r select 'f2', pg_temp.anc('e1200000-0000-4000-8000-0000000000a6', 100, interval '10 days');
select is((select consumption_per_booking from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000a6'), 12.5::numeric, 'F: measured is the pure average 100 / 8, the 1.0 baseline no longer counts (the prior would give 6.11)');
select is((select usage_state from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000a6'), 'measured', 'F: 70 accepted days is measured');

-- 24. G: too few turnovers --------------------------------------------------------------------------------------------------------------------
insert into _r select 'g1', pg_temp.anc('e1200000-0000-4000-8000-0000000000a7', 50, interval '60 days');
insert into _r select 'g2', pg_temp.anc('e1200000-0000-4000-8000-0000000000a7', 40, interval '50 days');
select is((select v ->> 'reason' from _r where k = 'g2'), 'too few turnovers', 'G: 10 days but one turnover is not enough');

-- 25-26. H: movement-controlled is skipped -----------------------------------------------------------------------------------------------------
insert into _r select 'h1', pg_temp.anc('e1200000-0000-4000-8000-0000000000a8', 10, interval '30 days');
select is((select v ->> 'skipped' from _r where k = 'h1'), 'movement_controlled', 'H: a movement-controlled item is skipped');
select is((select count(*)::int from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000a8'), 0, 'H: and leaves no row');

-- 27-29. idempotence: the same count again ------------------------------------------------------------------------------------------------------
insert into _r select 'a2again', pg_temp.anc('e1200000-0000-4000-8000-0000000000a1', 60, interval '5 days');
select is((select v ->> 'duplicate' from _r where k = 'a2again'), 'true', 'replay: the same anchor is reported as a duplicate');
select is((select count(*)::int from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000a1'), 2, 'replay: no second row');
select is((select consumption_per_booking from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000a1'), 3.5714::numeric, 'replay: the learned rate is unchanged');

-- back-dated count (review finding 5): anchors exist at 30 and 5 days ago, so a count dated 15 days ago would be counted twice and is skipped
insert into _r select 'a2old', pg_temp.anc('e1200000-0000-4000-8000-0000000000a1', 80, interval '15 days');
select ok((select v ->> 'skipped' from _r where k = 'a2old') = 'older_than_latest' and (select (v ->> 'ok')::boolean from _r where k = 'a2old')
          and (select count(*) from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000a1') = 2, 'back-dated: a count older than the newest anchor is skipped and writes no row');

-- 30-32. a receipt marks the refill and starts no interval ------------------------------------------------------------------------------------------
insert into _r select 'a3', pg_temp.anc('e1200000-0000-4000-8000-0000000000a1', 12, interval '1 day', 'receipt');
select is((select v ->> 'refill' from _r where k = 'a3'), 'true', 'receipt: reported as a refill');
select is((select last_refill_qty from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000a1'), 12::numeric, 'receipt: last_refill_qty is the units received');
select is((select count(*)::int from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000a1'), 2, 'receipt: no interval is created');

-- 33-37. a count through the real core (regression: it still counts, and now anchors) -------------------------------------------------------------------
insert into _r select 'i1', pg_temp.anc('e1200000-0000-4000-8000-0000000000a9', 100, interval '30 days');
insert into _r select 'i2', public.s_apply_inventory_count_core_v1('zz-s120',
  jsonb_build_array(jsonb_build_object('item_id', 'e1200000-0000-4000-8000-0000000000a9', 'counted', 60, 'expected_before', 100)), 'fixture count', null, null);
select is((select v ->> 'ok' from _r where k = 'i2'), 'true', 'core: the count is accepted');
select is((select qty_on_hand from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000a9'), 60::numeric, 'core: stock is the counted figure');
select is((select consumed || '/' || days || '/' || turnovers from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000a9' and accepted), '40/30.00/4', 'core: the count closed an accepted interval');
select is((select consumption_per_booking from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000a9'), 3.5714::numeric, 'core: and the rate learned');
select is((select count(*)::int from public.inventory_audit_log where entity_id = 'e1200000-0000-4000-8000-0000000000a9' and action = 'telegram_count'), 1, 'core: the audit row is still written');

-- 38-44. the KPI read -----------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200000-0000-4000-8000-000000000001"}';
select is((select (v ->> 'itemsTotal') || '/' || (v ->> 'itemsMeasured') || '/' || (v ->> 'itemsLearning') from (select public.get_inventory_usage_kpi_v1('e1200000-0000-4000-8000-0000000000b0') v) q),
  '10/1/4', 'KPI: 10 tracked items (the controlled one is out), 1 measured, 4 learning (A, D, E, I)');
select is((select (v ->> 'medianForecastError')::numeric from (select public.get_inventory_usage_kpi_v1('e1200000-0000-4000-8000-0000000000b0') v) q), 0.8::numeric,
  'KPI: median forecast error of A, D, E, F, I (0.8, 0.784, 0.6, 0.84, 0.8) is 0.8');
select is((select (v ->> 'forecastSamples')::int from (select public.get_inventory_usage_kpi_v1('e1200000-0000-4000-8000-0000000000b0') v) q), 5, 'KPI: five samples');
select is((select (v -> 'underFourteenDays' ->> 'count')::int from (select public.get_inventory_usage_kpi_v1('e1200000-0000-4000-8000-0000000000b0') v) q), 1, 'KPI: one item under 14 days (U, 1 left at the learned rate)');
select is((select (v -> 'waitingForRefill' ->> 'count')::int from (select public.get_inventory_usage_kpi_v1('e1200000-0000-4000-8000-0000000000b0') v) q), 1, 'KPI: one item waits for a recorded refill');
select is((select v -> 'waitingForRefill' -> 'items' -> 0 ->> 'name' from (select public.get_inventory_usage_kpi_v1('e1200000-0000-4000-8000-0000000000b0') v) q), 'Zz S120 C', 'KPI: and it is C');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200000-0000-4000-8000-000000000002"}';
select throws_ok($$select public.get_inventory_usage_kpi_v1('e1200000-0000-4000-8000-0000000000b0')$$, '42501', null, 'KPI: a user with no staff profile is refused');
reset role;

-- review fixes 1, 3, 4, 6, 9, 10, 13: scale, turnovers dated by the stay, back-dated purchases, zero usage, the 90-day clamp, the quarterly demotion, the refill mark on undo
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, consumption_per_booking, usage_baseline_per_turnover, usage_state) values
  ('e1200000-0000-4000-8000-0000000000ac', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 W', 'Other', 'pc', 500, true, true, 2.00, 1.0, 'baseline'),
  ('e1200000-0000-4000-8000-0000000000ad', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 Q', 'Other', 'pc', 500, true, true, 9.90, 1.0, 'measured'),
  ('e1200000-0000-4000-8000-0000000000ae', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 Z', 'Other', 'pc', 500, true, true, 2.00, 1.0, 'baseline'),
  ('e1200000-0000-4000-8000-0000000000af', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 P', 'Other', 'pc', 500, true, true, 2.00, 1.0, 'baseline'),
  ('e1200000-0000-4000-8000-0000000000c1', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 T', 'Other', 'pc', 500, true, true, 2.00, 1.0, 'baseline'),
  ('e1200000-0000-4000-8000-0000000000c2', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 N', 'Other', 'pc', 500, false, true, 2.00, null, 'baseline'),
  ('e1200000-0000-4000-8000-0000000000c3', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 X', 'Other', 'pc', 500, true, false, 2.00, null, 'baseline');

select is((select numeric_scale::int from information_schema.columns where table_schema = 'public' and table_name = 'inventory_items' and column_name = 'consumption_per_booking'), 4,
  'scale: consumption_per_booking holds four decimals');

-- non-consumable and inactive items never learn
insert into _r select 'n1', pg_temp.anc('e1200000-0000-4000-8000-0000000000c2', 10, interval '30 days');
insert into _r select 'x1', pg_temp.anc('e1200000-0000-4000-8000-0000000000c3', 10, interval '30 days');
select ok((select v ->> 'skipped' from _r where k = 'n1') = 'not_active_consumable' and (select v ->> 'skipped' from _r where k = 'x1') = 'not_active_consumable'
          and not exists (select 1 from public.inventory_usage_intervals where item_id in ('e1200000-0000-4000-8000-0000000000c2', 'e1200000-0000-4000-8000-0000000000c3')),
  'skip: a non-consumable and an inactive item are skipped and leave no row');

-- zero usage: a measured item that used nothing keeps the prior formula, never a rate of 0
insert into _r select 'z1', pg_temp.anc('e1200000-0000-4000-8000-0000000000ae', 100, interval '80 days');
insert into _r select 'z2', pg_temp.anc('e1200000-0000-4000-8000-0000000000ae', 100, interval '10 days');
select is((select consumption_per_booking || '/' || usage_state from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000ae'), '0.5556/measured',
  'zero usage: 70 accepted days with nothing used is measured at (10 + 0) / (10 + 8), not 0');

-- the 90-day clamp: two 30-day intervals ending 85 and 55 days ago hold 5 + 30 = 35 days inside the window, not 60
insert into public.inventory_usage_intervals(property_id, item_id, prev_anchor_at, anchor_at, qty_prev, qty_now, consumed, days, turnovers, accepted, source) values
  ('e1200000-0000-4000-8000-0000000000b0', 'e1200000-0000-4000-8000-0000000000ac', now() - interval '115 days', now() - interval '85 days', 100, 97, 3, 30, 3, true, 'count'),
  ('e1200000-0000-4000-8000-0000000000b0', 'e1200000-0000-4000-8000-0000000000ac', now() - interval '85 days', now() - interval '55 days', 97, 94, 3, 30, 3, true, 'count');
select public.s_inventory_usage_recompute_v1('e1200000-0000-4000-8000-0000000000ac', now());
select is((select usage_state from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000ac'), 'learning', 'clamp: 35 days inside the window is learning, not measured');

-- the quarterly job demotes an item nobody counted for 90 days
insert into public.inventory_usage_intervals(property_id, item_id, prev_anchor_at, anchor_at, qty_prev, qty_now, consumed, days, turnovers, accepted, source) values
  ('e1200000-0000-4000-8000-0000000000b0', 'e1200000-0000-4000-8000-0000000000ad', now() - interval '230 days', now() - interval '200 days', 100, 97, 3, 30, 3, true, 'count');
select public.inventory_usage_quarterly_reset_v1();
select is((select consumption_per_booking || '/' || usage_state from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000ad'), '1.0000/baseline',
  'quarterly: a stale measured item falls back to its baseline');

-- a purchase dated before the previous count was already on the shelf: it is not received between (the 34 refill dated 40 days ago, entered 2 days ago)
insert into public.inventory_purchases(id, item_id, qty, purchased_at, created_at) values
  ('e1200000-0000-4000-8000-0000000000e3', 'e1200000-0000-4000-8000-0000000000af', 34, current_date - 40, now() - interval '2 days'),
  ('e1200000-0000-4000-8000-0000000000e4', 'e1200000-0000-4000-8000-0000000000af', 10, current_date - 10, now() - interval '10 days'),
  ('e1200000-0000-4000-8000-0000000000e5', 'e1200000-0000-4000-8000-0000000000af', 7,  current_date - 3,  now() - interval '3 days');
insert into _r select 'p1', pg_temp.anc('e1200000-0000-4000-8000-0000000000af', 100, interval '30 days');
insert into _r select 'p2', pg_temp.anc('e1200000-0000-4000-8000-0000000000af', 60, interval '1 day');
select ok((select received_between = 17 and consumed = 57 from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000af' and accepted),
  'purchases: only the two purchases dated after the previous count are received between (10 + 7); the back-dated 34 is ignored: 100 + 17 - 60 = 57');

-- an undone receipt recomputes the refill mark from the purchases that remain
insert into _r select 'r1', pg_temp.anc('e1200000-0000-4000-8000-0000000000af', 7, interval '3 days', 'receipt');
delete from public.inventory_purchases where id = 'e1200000-0000-4000-8000-0000000000e5';
select is((select last_refill_qty from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000af'), 10::numeric, 'undo: the mark is recomputed from the newest remaining purchase by purchase date');
delete from public.inventory_purchases where item_id = 'e1200000-0000-4000-8000-0000000000af';
select is((select last_refill_at from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000af'), null::timestamptz, 'undo: with no purchase left the mark is cleared');

-- turnovers are dated by the stay: a report typed 2 days ago for a stay that ended 30 days ago belongs to the interval it ended in
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type, checkout_date) values
  ('e1200000-0000-4000-8000-0000000000b0', 'zz-s120-late', 'Fixture', now() - interval '2 days', 'turnover', (now() - interval '30 days')::date);
insert into _r select 't1', pg_temp.anc('e1200000-0000-4000-8000-0000000000c1', 100, interval '40 days');
insert into _r select 't2', pg_temp.anc('e1200000-0000-4000-8000-0000000000c1', 70, interval '10 days');
select is((select turnovers from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000c1' and accepted), 5,
  'stay date: sessions 35, 25, 20 and 15 days ago plus the late report of a stay that ended 30 days ago make 5 turnovers');

-- F2: a report typed after count A for a stay that ended before A is counted once, in the next interval (anchors 60, 40, 10, 5 days ago; the late report is entered after the 40-day count)
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, consumption_per_booking, usage_baseline_per_turnover) values
  ('e1200000-0000-4000-8000-0000000000c4', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 K', 'Other', 'pc', 500, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000000c5', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 L', 'Other', 'pc', 500, true, true, 2.00, 1.0);
insert into _r select 'k0', pg_temp.anc('e1200000-0000-4000-8000-0000000000c4', 100, interval '60 days');
insert into _r select 'k1', pg_temp.anc('e1200000-0000-4000-8000-0000000000c4', 90, interval '40 days');
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type, checkout_date) values
  ('e1200000-0000-4000-8000-0000000000b0', 'zz-s120-late-f2', 'Fixture', now() - interval '20 days', 'turnover', (now() - interval '45 days')::date);
insert into _r select 'k2', pg_temp.anc('e1200000-0000-4000-8000-0000000000c4', 80, interval '10 days');
insert into _r select 'k3', pg_temp.anc('e1200000-0000-4000-8000-0000000000c4', 75, interval '5 days');
select is((select turnovers from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000c4' and prev_anchor_at is not null and days = 20.00), 2,
  'late report: the interval it was missing from (sessions 55 and 45 days ago) is not rewritten');
select is((select turnovers from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000c4' and prev_anchor_at is not null and days = 30.00), 6,
  'late report: the next interval counts sessions 35, 25, 20 and 15 days ago, the stay-dated late report of 30 days ago and the report of the stay that ended 45 days ago');
select is((select turnovers from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000c4' and days = 5.00), 1,
  'late report: and it is not counted again in the interval after that (only the deep clean 8 days ago)');

-- F7: duplicate rows for one checkout count once, an undated session still counts each
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type, checkout_date) values
  ('e1200000-0000-4000-8000-0000000000b0', 'zz-s120-dup-1', 'Fixture', now() - interval '17 days', 'turnover', (now() - interval '18 days')::date),
  ('e1200000-0000-4000-8000-0000000000b0', 'zz-s120-dup-2', 'Fixture', now() - interval '16 days', 'turnover', (now() - interval '18 days')::date);
insert into _r select 'l1', pg_temp.anc('e1200000-0000-4000-8000-0000000000c5', 100, interval '40 days');
insert into _r select 'l2', pg_temp.anc('e1200000-0000-4000-8000-0000000000c5', 70, interval '10 days');
select is((select turnovers from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000c5' and accepted), 6,
  'one turnover per stay: sessions 35, 25, 20 and 15 days ago, the 30-day late report and the two rows of one checkout (counted once) make 6, not 7');

-- F4: the real receive paths and the catalogue (units_per_purchase 6: packs convert to base units, the mark is the purchase date at Manila midnight)
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, units_per_purchase, consumption_per_booking, usage_baseline_per_turnover) values
  ('e1200000-0000-4000-8000-0000000000c6', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 R', 'Other', 'pc', 10, true, true, 6, 2.00, 1.0);
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200000-0000-4000-8000-000000000001"}';
select is(((public.record_inventory_receipt_v1('e1200000-0000-4000-8000-0000000000c6', 2, null, 'Zz S120 vendor', public.manila_today() - 3, null, null, 'zz-s120-receipt-key-0001', null)) ->> 'unitsAdded')::numeric, 12::numeric,
  'admin receipt: 2 packs of 6 add 12 units');
reset role;
select ok((select last_refill_qty = 12 and last_refill_at = ((public.manila_today() - 3)::timestamp at time zone 'Asia/Manila') from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000c6'),
  'admin receipt: last_refill_at is the purchase date (Manila midnight) and last_refill_qty the 12 units');
insert into _r select 'ocr', public.apply_inventory_purchase('e1200000-0000-4000-8000-0000000000c6', 1, 60, 'Zz S120 vendor', public.manila_today() - 2, null, null);
select is((select (v ->> 'added')::numeric from _r where k = 'ocr'), 6::numeric, 'OCR restock: 1 pack adds 6 units');
select ok((select last_refill_qty = 6 and last_refill_at = ((public.manila_today() - 2)::timestamp at time zone 'Asia/Manila') from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000c6'),
  'OCR restock: the mark moved to the newer purchase date with 6 units');
select isnt(public.s_inventory_receipt_apply_v1('e1200000-0000-4000-8000-0000000000c6', 5, null, 'Zz S120 vendor', null, public.manila_today() - 1, null, 'e1200000-0000-4000-8000-0000000000d1'), null::uuid,
  'staff receipt: the purchase row is written');
select ok((select last_refill_qty = 5 and last_refill_at = ((public.manila_today() - 1)::timestamp at time zone 'Asia/Manila') from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000c6'),
  'staff receipt: the mark moved to its date with 5 units');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200000-0000-4000-8000-000000000001"}';
select ok((select e ? 'usageState' and e ? 'usagePerTurnover' and e ? 'usageBaseline' and e ? 'lastRefillAt' and e ? 'lastRefillQty' and e ? 'lastCountAt' and e ? 'usageCounts' and e ? 'baselineNote'
             from jsonb_array_elements(public.get_inventory_catalogue_v1('e1200000-0000-4000-8000-0000000000b0') -> 'items') e where e ->> 'id' = 'e1200000-0000-4000-8000-0000000000c6'),
  'catalogue: the seven new keys are present beside the old baselineNote');
select ok((select e ->> 'usageState' = 'baseline' and (e ->> 'lastRefillQty')::numeric = 5 and (e ->> 'usageCounts')::int = 0 and (e ->> 'usageBaseline')::numeric = 1.0 and e -> 'lastCountAt' = 'null'::jsonb
             from jsonb_array_elements(public.get_inventory_catalogue_v1('e1200000-0000-4000-8000-0000000000b0') -> 'items') e where e ->> 'id' = 'e1200000-0000-4000-8000-0000000000c6'),
  'catalogue: the live values (baseline state, refill 5, no accepted counts, baseline 1.0, never counted)');
reset role;

-- S3 re-plan (second failed review): each stay is claimed once per item by construction, the purchase date, same-day purchases, the as-of hook, a quiet recompute, the receive hooks, the rollback snapshot ---------
-- Absolute Manila dates in properties b2, b3, b4 so every figure is hand-computed; b1 is relative to now() because the count core only takes an as-of time within 60 days.
create function pg_temp.anca(p_item uuid, p_q numeric, p_at timestamptz) returns jsonb language sql as
$$ select public.record_inventory_anchor_v1($1, $2, $3, 'count') $$;
insert into public.properties(id, name, is_active) values
  ('e1200000-0000-4000-8000-0000000000b1', 'Synthetic S120 relative', true), ('e1200000-0000-4000-8000-0000000000b2', 'Synthetic S120 timeline', true),
  ('e1200000-0000-4000-8000-0000000000b3', 'Synthetic S120 late report', true), ('e1200000-0000-4000-8000-0000000000b4', 'Synthetic S120 duplicate row', true);
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, consumption_per_booking, usage_baseline_per_turnover) values
  ('e1200000-0000-4000-8000-0000000001a1', 'e1200000-0000-4000-8000-0000000000b1', 'Zz S120 s3 as-of', 'Other', 'pc', 100, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000001a2', 'e1200000-0000-4000-8000-0000000000b3', 'Zz S120 s3 late', 'Other', 'pc', 100, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000001a3', 'e1200000-0000-4000-8000-0000000000b4', 'Zz S120 s3 dup', 'Other', 'pc', 100, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000001b1', 'e1200000-0000-4000-8000-0000000000b2', 'Zz S120 s3 utc', 'Other', 'pc', 100, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000001b2', 'e1200000-0000-4000-8000-0000000000b2', 'Zz S120 s3 same-day', 'Other', 'pc', 100, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000001b3', 'e1200000-0000-4000-8000-0000000000b2', 'Zz S120 s3 priority', 'Other', 'pc', 100, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000001b4', 'e1200000-0000-4000-8000-0000000000b2', 'Zz S120 s3 after-anchor', 'Other', 'pc', 100, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000001b5', 'e1200000-0000-4000-8000-0000000000b2', 'Zz S120 s3 ocr', 'Other', 'pc', 100, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000001b6', 'e1200000-0000-4000-8000-0000000000b2', 'Zz S120 s3 back-dated', 'Other', 'pc', 100, true, true, 2.00, 1.0);

-- 1. the count core honours p_as_of: first count 30 days ago, a count AS OF 10 days ago (stays 28, 24 and 20 days ago are inside; the stay 3 days ago is not)
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type)
select 'e1200000-0000-4000-8000-0000000000b1', 'zz-s120-r-' || d, 'Fixture', now() - make_interval(days => d), 'turnover' from unnest(array[28, 24, 20, 3]) d;
insert into _r select 's3o1', pg_temp.anc('e1200000-0000-4000-8000-0000000001a1', 100, interval '30 days');
insert into _r select 's3o2', public.s_apply_inventory_count_core_v1('zz-s120',
  jsonb_build_array(jsonb_build_object('item_id', 'e1200000-0000-4000-8000-0000000001a1', 'counted', 60, 'expected_before', 100)), 'fixture as-of count', now() - interval '10 days', null);
select is((select anchor_at from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000001a1' and accepted), now() - interval '10 days',
  'as-of: the interval is anchored at the as-of time the count was made for, not at now');
select is((select consumed || '/' || days || '/' || turnovers from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000001a1' and accepted), '40/20.00/3',
  'as-of: 100 to 60 is 40 used over 20.00 days (not 30) and the 3 stays inside (the one 3 days ago is after the count)');

-- 2. property b3: a stay that ended on 12 Oct is typed on 2 Nov, after the counts of 18 Oct and 30 Oct. Its eff is the end of 12 Oct, before both. Counts: 1 Oct 100, 18 Oct 70, 30 Oct 40, 12 Nov 20.
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type, checkout_date)
select 'e1200000-0000-4000-8000-0000000000b3', 'zz-s120-l-' || d, 'Fixture', (d::date + time '11:00') at time zone 'Asia/Manila', 'turnover', d::date
  from unnest(array['2026-10-05', '2026-10-10', '2026-10-15', '2026-10-24', '2026-10-27', '2026-10-28']) d;
insert into _r select 's3l0', pg_temp.anca('e1200000-0000-4000-8000-0000000001a2', 100, timestamptz '2026-10-01 12:00+08');
insert into _r select 's3l1', pg_temp.anca('e1200000-0000-4000-8000-0000000001a2', 70, timestamptz '2026-10-18 12:00+08');
insert into _r select 's3l2', pg_temp.anca('e1200000-0000-4000-8000-0000000001a2', 40, timestamptz '2026-10-30 12:00+08');
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type, checkout_date) values
  ('e1200000-0000-4000-8000-0000000000b3', 'zz-s120-l-late', 'Fixture', timestamptz '2026-11-02 09:00+08', 'turnover', date '2026-10-12');
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type, checkout_date)
select 'e1200000-0000-4000-8000-0000000000b3', 'zz-s120-l-' || d, 'Fixture', (d::date + time '11:00') at time zone 'Asia/Manila', 'turnover', d::date
  from unnest(array['2026-11-03', '2026-11-06', '2026-11-09']) d;
insert into _r select 's3l3', pg_temp.anca('e1200000-0000-4000-8000-0000000001a2', 20, timestamptz '2026-11-12 12:00+08');
select ok((select x.accepted and x.turnovers = 4 and x.days = 13.00 and x.consumed = 20 and x.turnover_keys @> array['2026-10-12'] from public.inventory_usage_intervals x
            where x.item_id = 'e1200000-0000-4000-8000-0000000001a2' and x.anchor_at = timestamptz '2026-11-12 12:00+08'),
  'late report: the stay of 12 Oct typed on 2 Nov is counted by the 12 Nov count (4 stays: it plus 3, 6 and 9 Nov), although it ended before both earlier counts');
select is((select consumption_per_booking from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000001a2'), 4.5::numeric,
  'late report: the rate is (1.0 * 10 + 30 + 30 + 20) / (10 + 3 + 3 + 4) = 4.5, the late stay included (without it 90 / 19 = 4.7368)');
select is((select count(*)::int || '/' || count(distinct k.stay_key)::int from public.inventory_usage_intervals x cross join lateral unnest(x.turnover_keys) k(stay_key)
            where x.item_id = 'e1200000-0000-4000-8000-0000000001a2'), '10/10', 'late report: ten stays claimed by three intervals (3 + 3 + 4), no stay twice');

-- 3. property b4: one stay (checkout 9 Oct) has two rows, the second typed on 12 Oct after the count of 10 Oct. It is counted by the first interval only.
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type, checkout_date)
select 'e1200000-0000-4000-8000-0000000000b4', 'zz-s120-m-' || d, 'Fixture', (d::date + time '11:00') at time zone 'Asia/Manila', 'turnover', d::date
  from unnest(array['2026-10-03', '2026-10-06', '2026-10-09', '2026-10-14', '2026-10-16', '2026-10-18']) d;
insert into _r select 's3m0', pg_temp.anca('e1200000-0000-4000-8000-0000000001a3', 100, timestamptz '2026-10-01 12:00+08');
insert into _r select 's3m1', pg_temp.anca('e1200000-0000-4000-8000-0000000001a3', 85, timestamptz '2026-10-10 12:00+08');
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type, checkout_date) values
  ('e1200000-0000-4000-8000-0000000000b4', 'zz-s120-m-dup', 'Fixture', timestamptz '2026-10-12 09:00+08', 'turnover', date '2026-10-09');
insert into _r select 's3m2', pg_temp.anca('e1200000-0000-4000-8000-0000000001a3', 70, timestamptz '2026-10-20 12:00+08');
select is((select turnovers from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000001a3' and anchor_at = timestamptz '2026-10-20 12:00+08'), 3,
  'duplicate row: the 20 Oct count claims the stays of 14, 16 and 18 Oct only (the stay of 9 Oct, reported again after the 10 Oct count, is already claimed)');
select ok((select x.turnover_keys @> array['2026-10-09'] from public.inventory_usage_intervals x where x.item_id = 'e1200000-0000-4000-8000-0000000001a3' and x.anchor_at = timestamptz '2026-10-10 12:00+08')
      and not (select x.turnover_keys @> array['2026-10-09'] from public.inventory_usage_intervals x where x.item_id = 'e1200000-0000-4000-8000-0000000001a3' and x.anchor_at = timestamptz '2026-10-20 12:00+08'),
  'duplicate row: the stay of 9 Oct belongs to the 10 Oct interval and not to the 20 Oct one');
select is((select count(*)::int || '/' || count(distinct k.stay_key)::int from public.inventory_usage_intervals x cross join lateral unnest(x.turnover_keys) k(stay_key)
            where x.item_id = 'e1200000-0000-4000-8000-0000000001a3'), '6/6', 'duplicate row: six stays claimed (3 + 3), none twice (the old rule counted the stay of 9 Oct in both: 7)');

-- 4. property b2: one timeline for the purchase and back-dating tests. Stays 3, 5, 8 | 14, 16, 18 | 24, 26, 28 Oct (cleaned 11:00 on the checkout day). Counts 1 Oct, 10 Oct, 20 Oct, 30 Oct (12:00 Manila).
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type, checkout_date)
select 'e1200000-0000-4000-8000-0000000000b2', 'zz-s120-t-' || d, 'Fixture', (d::date + time '11:00') at time zone 'Asia/Manila', 'turnover', d::date
  from unnest(array['2026-10-03', '2026-10-05', '2026-10-08', '2026-10-14', '2026-10-16', '2026-10-18', '2026-10-24', '2026-10-26', '2026-10-28']) d;

-- UTC default: a purchase typed at 05:00 Manila on 11 Oct carries the UTC date 10 Oct (the column default). Its Manila date is 11 Oct, after the 10 Oct count: received between, and not a same-day purchase.
insert into _r select 's3q0', pg_temp.anca('e1200000-0000-4000-8000-0000000001b1', 100, timestamptz '2026-10-01 12:00+08');
insert into _r select 's3q1', pg_temp.anca('e1200000-0000-4000-8000-0000000001b1', 70, timestamptz '2026-10-10 12:00+08');
insert into public.inventory_purchases(id, item_id, qty, purchased_at, created_at) values ('e1200000-0000-4000-8000-0000000001e1', 'e1200000-0000-4000-8000-0000000001b1', 50, date '2026-10-10', timestamptz '2026-10-11 05:00+08');
insert into _r select 's3q2', pg_temp.anca('e1200000-0000-4000-8000-0000000001b1', 90, timestamptz '2026-10-20 12:00+08');
select ok((select x.accepted and x.received_between = 50 and x.consumed = 30 and x.turnovers = 3 from public.inventory_usage_intervals x
            where x.item_id = 'e1200000-0000-4000-8000-0000000001b1' and x.anchor_at = timestamptz '2026-10-20 12:00+08'),
  'UTC default: a purchase typed before 08:00 Manila (10 Oct by default, 11 Oct in Manila) is received and not a same-day purchase: 70 + 50 - 90 = 30, accepted');

-- same-day purchase: typed on 12 Oct and dated 10 Oct (the day of the 10 Oct count) it may already be in that count: the 20 Oct interval is rejected, the anchor moves, its 3 stays are claimed.
insert into _r select 's3r0', pg_temp.anca('e1200000-0000-4000-8000-0000000001b2', 100, timestamptz '2026-10-01 12:00+08');
insert into _r select 's3r1', pg_temp.anca('e1200000-0000-4000-8000-0000000001b2', 70, timestamptz '2026-10-10 12:00+08');
insert into public.inventory_purchases(id, item_id, qty, purchased_at, created_at) values ('e1200000-0000-4000-8000-0000000001e2', 'e1200000-0000-4000-8000-0000000001b2', 20, date '2026-10-10', timestamptz '2026-10-12 09:00+08');
insert into _r select 's3r2', pg_temp.anca('e1200000-0000-4000-8000-0000000001b2', 75, timestamptz '2026-10-20 12:00+08');
select ok((select not x.accepted and x.reject_reason = 'same-day purchase' and x.turnovers = 3 and x.consumed = 15 and x.received_between = 20 from public.inventory_usage_intervals x
            where x.item_id = 'e1200000-0000-4000-8000-0000000001b2' and x.anchor_at = timestamptz '2026-10-20 12:00+08'),
  'same-day purchase: rejected with that reason, the anchor moved to 20 Oct and its 3 stays are claimed (70 + 20 - 75 = 15)');
insert into _r select 's3r3', pg_temp.anca('e1200000-0000-4000-8000-0000000001b2', 60, timestamptz '2026-10-30 12:00+08');
select ok((select x.accepted and x.turnovers = 3 and x.consumed = 15 and x.received_between = 0 and x.prev_anchor_at = timestamptz '2026-10-20 12:00+08' from public.inventory_usage_intervals x
            where x.item_id = 'e1200000-0000-4000-8000-0000000001b2' and x.anchor_at = timestamptz '2026-10-30 12:00+08'),
  'same-day purchase: the next count measures from the moved anchor and claims only the stays of 24, 26 and 28 Oct (75 - 60 = 15, accepted)');

-- reason order: with the same purchase and a count far above what was recorded, unrecorded restock is still the reason (70 + 5 - 100 = -25 stays negative with the purchase ignored)
insert into _r select 's3s0', pg_temp.anca('e1200000-0000-4000-8000-0000000001b3', 100, timestamptz '2026-10-01 12:00+08');
insert into _r select 's3s1', pg_temp.anca('e1200000-0000-4000-8000-0000000001b3', 70, timestamptz '2026-10-10 12:00+08');
insert into public.inventory_purchases(id, item_id, qty, purchased_at, created_at) values ('e1200000-0000-4000-8000-0000000001e3', 'e1200000-0000-4000-8000-0000000001b3', 5, date '2026-10-10', timestamptz '2026-10-12 09:00+08');
insert into _r select 's3s2', pg_temp.anca('e1200000-0000-4000-8000-0000000001b3', 100, timestamptz '2026-10-20 12:00+08');
select is((select x.reject_reason from public.inventory_usage_intervals x where x.item_id = 'e1200000-0000-4000-8000-0000000001b3' and x.anchor_at = timestamptz '2026-10-20 12:00+08'), 'unrecorded restock',
  'reason order: unrecorded restock comes before same-day purchase');

-- created after the anchor: a purchase entered on 22 Oct is not in the count of 20 Oct (70 - 60 = 10 used, nothing received)
insert into _r select 's3t0', pg_temp.anca('e1200000-0000-4000-8000-0000000001b4', 100, timestamptz '2026-10-01 12:00+08');
insert into _r select 's3t1', pg_temp.anca('e1200000-0000-4000-8000-0000000001b4', 70, timestamptz '2026-10-10 12:00+08');
insert into public.inventory_purchases(id, item_id, qty, purchased_at, created_at) values ('e1200000-0000-4000-8000-0000000001e4', 'e1200000-0000-4000-8000-0000000001b4', 30, date '2026-10-22', timestamptz '2026-10-22 09:00+08');
insert into _r select 's3t2', pg_temp.anca('e1200000-0000-4000-8000-0000000001b4', 60, timestamptz '2026-10-20 12:00+08');
select ok((select x.accepted and x.received_between = 0 and x.consumed = 10 from public.inventory_usage_intervals x where x.item_id = 'e1200000-0000-4000-8000-0000000001b4' and x.anchor_at = timestamptz '2026-10-20 12:00+08'),
  'created after the anchor: a purchase entered on 22 Oct is not received by the count of 20 Oct (received 0, consumed 10, not -20)');

-- OCR branch: a restock dated 5 Oct (before the 10 Oct count) and entered on 15 Oct was already on the shelf at the count: the audit row is not received between
insert into _r select 's3p0', pg_temp.anca('e1200000-0000-4000-8000-0000000001b5', 100, timestamptz '2026-10-01 12:00+08');
insert into _r select 's3p1', pg_temp.anca('e1200000-0000-4000-8000-0000000001b5', 70, timestamptz '2026-10-10 12:00+08');
insert into public.inventory_purchases(id, item_id, qty, notes, purchased_at, created_at) values
  ('e1200000-0000-4000-8000-0000000001e5', 'e1200000-0000-4000-8000-0000000001b5', 7, 'Auto-restock from receipt OCR zz120', date '2026-10-05', timestamptz '2026-10-15 09:00+08');
insert into public.inventory_audit_log(entity_type, entity_id, action, after, actor, created_at)
  values ('inventory_items', 'e1200000-0000-4000-8000-0000000001b5', 'ocr_restock', '{"qty_added": 7, "purchase_id": "e1200000-0000-4000-8000-0000000001e5"}', 'zz120', timestamptz '2026-10-15 09:00+08');
insert into _r select 's3p2', pg_temp.anca('e1200000-0000-4000-8000-0000000001b5', 63, timestamptz '2026-10-20 12:00+08');
select ok((select x.accepted and x.received_between = 0 and x.consumed = 7 from public.inventory_usage_intervals x where x.item_id = 'e1200000-0000-4000-8000-0000000001b5' and x.anchor_at = timestamptz '2026-10-20 12:00+08'),
  'OCR branch: a restock dated before the previous count is not received between (received 0, consumed 7, not 0)');

-- OCR branch, Manila date: the previous count is 11 Oct 00:10 Manila (v_day = 11 Oct); the restock is entered at 00:30 Manila the same night = 10 Oct 16:30 UTC, so the column default purchased_at is the UTC
-- date 10 Oct, one day before v_day. Without s_inventory_received_date_v1 in the OCR branch the audit row is dropped (received 0); with it the Manila date 11 Oct counts (received 7).
-- It is also a same-day purchase (received on the day of the count), so the interval is rejected for that reason, and received_between and consumed still hold the figures.
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, consumption_per_booking, usage_baseline_per_turnover) values
  ('e1200000-0000-4000-8000-0000000001b7', 'e1200000-0000-4000-8000-0000000000b2', 'Zz S120 s3 ocr-manila', 'Other', 'pc', 100, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000001b8', 'e1200000-0000-4000-8000-0000000000b2', 'Zz S120 s3 ocr-sameday', 'Other', 'pc', 100, true, true, 2.00, 1.0),
  ('e1200000-0000-4000-8000-0000000001b9', 'e1200000-0000-4000-8000-0000000000b2', 'Zz S120 s3 ocr-bound', 'Other', 'pc', 100, true, true, 2.00, 1.0);
insert into _r select 's3w0', pg_temp.anca('e1200000-0000-4000-8000-0000000001b7', 100, timestamptz '2026-10-01 12:00+08');
insert into _r select 's3w1', pg_temp.anca('e1200000-0000-4000-8000-0000000001b7', 70, timestamptz '2026-10-11 00:10+08');
insert into public.inventory_purchases(id, item_id, qty, notes, purchased_at, created_at) values
  ('e1200000-0000-4000-8000-0000000001e6', 'e1200000-0000-4000-8000-0000000001b7', 7, 'Auto-restock from receipt OCR zz120', date '2026-10-10', timestamptz '2026-10-11 00:30+08');
insert into public.inventory_audit_log(entity_type, entity_id, action, after, actor, created_at)
  values ('inventory_items', 'e1200000-0000-4000-8000-0000000001b7', 'ocr_restock', '{"qty_added": 7, "purchase_id": "e1200000-0000-4000-8000-0000000001e6"}', 'zz120', timestamptz '2026-10-11 00:30+08');
insert into _r select 's3w2', pg_temp.anca('e1200000-0000-4000-8000-0000000001b7', 60, timestamptz '2026-10-20 12:00+08');
select ok((select x.received_between = 7 and x.consumed = 17 and x.reject_reason = 'same-day purchase' from public.inventory_usage_intervals x
            where x.item_id = 'e1200000-0000-4000-8000-0000000001b7' and x.anchor_at = timestamptz '2026-10-20 12:00+08'),
  'OCR Manila date: a 00:30 Manila restock (UTC date one day earlier) is received between: 70 + 7 - 60 = 17, not 10, and it is a same-day purchase');

-- OCR branch, same-day purchase: a restock dated 10 Oct (the day of the 10 Oct count) and entered on 12 Oct is received (7) and rejects the interval; the anchor still moves
insert into _r select 's3x0', pg_temp.anca('e1200000-0000-4000-8000-0000000001b8', 100, timestamptz '2026-10-01 12:00+08');
insert into _r select 's3x1', pg_temp.anca('e1200000-0000-4000-8000-0000000001b8', 70, timestamptz '2026-10-10 12:00+08');
insert into public.inventory_purchases(id, item_id, qty, notes, purchased_at, created_at) values
  ('e1200000-0000-4000-8000-0000000001e7', 'e1200000-0000-4000-8000-0000000001b8', 7, 'Auto-restock from receipt OCR zz120', date '2026-10-10', timestamptz '2026-10-12 09:00+08');
insert into public.inventory_audit_log(entity_type, entity_id, action, after, actor, created_at)
  values ('inventory_items', 'e1200000-0000-4000-8000-0000000001b8', 'ocr_restock', '{"qty_added": 7, "purchase_id": "e1200000-0000-4000-8000-0000000001e7"}', 'zz120', timestamptz '2026-10-12 09:00+08');
insert into _r select 's3x2', pg_temp.anca('e1200000-0000-4000-8000-0000000001b8', 55, timestamptz '2026-10-20 12:00+08');
select ok((select not x.accepted and x.reject_reason = 'same-day purchase' and x.received_between = 7 and x.consumed = 22 and x.turnovers = 3 from public.inventory_usage_intervals x
            where x.item_id = 'e1200000-0000-4000-8000-0000000001b8' and x.anchor_at = timestamptz '2026-10-20 12:00+08'),
  'OCR same-day: a restock dated on the day of the previous count is received (70 + 7 - 55 = 22) and the interval is rejected as a same-day purchase');

-- OCR branch, created_at <= anchor bound: the restock is entered on 22 Oct, after the 20 Oct count, and dated 22 Oct (after the previous count's day), so only the bound keeps it out of that count
insert into _r select 's3y0', pg_temp.anca('e1200000-0000-4000-8000-0000000001b9', 100, timestamptz '2026-10-01 12:00+08');
insert into _r select 's3y1', pg_temp.anca('e1200000-0000-4000-8000-0000000001b9', 70, timestamptz '2026-10-10 12:00+08');
insert into public.inventory_purchases(id, item_id, qty, notes, purchased_at, created_at) values
  ('e1200000-0000-4000-8000-0000000001e8', 'e1200000-0000-4000-8000-0000000001b9', 7, 'Auto-restock from receipt OCR zz120', date '2026-10-22', timestamptz '2026-10-22 09:00+08');
insert into public.inventory_audit_log(entity_type, entity_id, action, after, actor, created_at)
  values ('inventory_items', 'e1200000-0000-4000-8000-0000000001b9', 'ocr_restock', '{"qty_added": 7, "purchase_id": "e1200000-0000-4000-8000-0000000001e8"}', 'zz120', timestamptz '2026-10-22 09:00+08');
insert into _r select 's3y2', pg_temp.anca('e1200000-0000-4000-8000-0000000001b9', 60, timestamptz '2026-10-20 12:00+08');
select ok((select x.accepted and x.received_between = 0 and x.consumed = 10 from public.inventory_usage_intervals x
            where x.item_id = 'e1200000-0000-4000-8000-0000000001b9' and x.anchor_at = timestamptz '2026-10-20 12:00+08'),
  'OCR bound: a restock entered after the count (22 Oct) is not received by the 20 Oct count (received 0, consumed 10, not 3)');

-- back-dated count: a count dated 15 Oct arrives after the counts of 10 and 20 Oct: skipped, no row, and every stay stays in exactly one interval
insert into _r select 's3n0', pg_temp.anca('e1200000-0000-4000-8000-0000000001b6', 100, timestamptz '2026-10-01 12:00+08');
insert into _r select 's3n1', pg_temp.anca('e1200000-0000-4000-8000-0000000001b6', 70, timestamptz '2026-10-10 12:00+08');
insert into _r select 's3n2', pg_temp.anca('e1200000-0000-4000-8000-0000000001b6', 50, timestamptz '2026-10-20 12:00+08');
insert into _r select 's3n3', pg_temp.anca('e1200000-0000-4000-8000-0000000001b6', 60, timestamptz '2026-10-15 12:00+08');
select ok((select v ->> 'skipped' from _r where k = 's3n3') = 'older_than_latest'
          and (select count(*) from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000001b6') = 3
          and (select count(*)::int || '/' || count(distinct k.stay_key)::int from public.inventory_usage_intervals x cross join lateral unnest(x.turnover_keys) k(stay_key) where x.item_id = 'e1200000-0000-4000-8000-0000000001b6') = '6/6',
  'back-dated: the 15 Oct count is skipped and writes no row; the other counts hold six stays, each once');

-- the received date helper
select is(public.s_inventory_received_date_v1(date '2026-10-10', timestamptz '2026-10-10 21:00+00'), date '2026-10-11', 'received date: the UTC default typed at 05:00 Manila is the Manila date');
select is(public.s_inventory_received_date_v1(date '2026-10-05', timestamptz '2026-10-10 21:00+00'), date '2026-10-05', 'received date: a purchase date that is not the default is kept');
select is(public.s_inventory_received_date_v1(null, timestamptz '2026-10-10 21:00+00'), date '2026-10-11', 'received date: a null purchase date is the Manila date of entry');
select ok(not has_function_privilege('anon', 'public.s_inventory_received_date_v1(date,timestamptz)', 'execute')
      and not has_function_privilege('authenticated', 'public.s_inventory_received_date_v1(date,timestamptz)', 'execute')
      and not has_function_privilege('service_role', 'public.s_inventory_received_date_v1(date,timestamptz)', 'execute'), 'received date: the helper is internal, no API role can call it');

-- the rollback snapshot: closed, and it holds every item that existed when the release ran (items made in this suite are newer than it)
select ok((select relrowsecurity from pg_class where oid = 'public.s120_usage_item_snapshot'::regclass)
      and not has_table_privilege('anon', 'public.s120_usage_item_snapshot', 'select, insert, update, delete')
      and not has_table_privilege('authenticated', 'public.s120_usage_item_snapshot', 'select, insert, update, delete')
      and not has_table_privilege('service_role', 'public.s120_usage_item_snapshot', 'select, insert, update, delete'), 'snapshot: RLS on and no grant to any API role');
select is((select count(*)::int from public.inventory_items i where coalesce(i.created_at, '-infinity') < (select max(s.taken_at) from public.s120_usage_item_snapshot s)
            and not exists (select 1 from public.s120_usage_item_snapshot s where s.id = i.id)), 0, 'snapshot: every item that existed when the release ran is in it');
-- the snapshot was taken BEFORE the seed and the widening: a seeded item whose baseline is not the 2.00 default would hold its baseline if the snapshot were taken after the seed, and a
-- learned rate (1.5926, 0.1074, 0.0556) has four decimals, which a value from before numeric(10,4) cannot have. Aggregates only (a real backup holds real rows).
select is((select count(*)::int from public.s120_usage_item_snapshot s join public.inventory_items i on i.id = s.id
            where i.usage_baseline_per_turnover is not null and i.usage_baseline_per_turnover <> 2.00 and s.consumption_per_booking = i.usage_baseline_per_turnover
              and i.created_at < s.taken_at), 0, 'snapshot: no seeded item holds its post-seed baseline in the snapshot (it holds the value from before the seed)');
select is((select count(*)::int from public.s120_usage_item_snapshot s where s.consumption_per_booking is not null and s.consumption_per_booking <> round(s.consumption_per_booking, 2)), 0,
  'snapshot: no value has more than two decimals (nothing learned or widened was captured)');

-- a recompute that changes nothing writes nothing (usage_updated_at is moved back to 2000 so a write would show)
-- inventory_items has a BEFORE UPDATE row trigger inventory_items_updated_at (set_updated_at: updated_at = now() on every update, changed or not), so the sentinel is set with it disabled
-- and any write by the recompute would show in updated_at too (the receipt undo window reads updated_at).
alter table public.inventory_items disable trigger inventory_items_updated_at;
update public.inventory_items set usage_updated_at = timestamptz '2000-01-01 00:00+00', updated_at = timestamptz '2000-01-01 00:00+00' where id = 'e1200000-0000-4000-8000-0000000000a1';
alter table public.inventory_items enable trigger inventory_items_updated_at;
select public.s_inventory_usage_recompute_v1('e1200000-0000-4000-8000-0000000000a1', now());
select is((select usage_updated_at::text || '/' || updated_at::text from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000a1'),
  timestamptz '2000-01-01 00:00+00'::text || '/' || timestamptz '2000-01-01 00:00+00'::text, 'quiet recompute: nothing changed, so the row was not written (usage_updated_at and updated_at both untouched)');
update public.inventory_items set consumption_per_booking = 9.9 where id = 'e1200000-0000-4000-8000-0000000000a1';
select public.s_inventory_usage_recompute_v1('e1200000-0000-4000-8000-0000000000a1', now());
select is((select consumption_per_booking || '/' || (usage_updated_at = now())::text from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000a1'), '3.5714/true',
  'quiet recompute: a changed rate is put back and the row is written');

-- each receive hook keeps its receipt when the hook fails (a trigger refuses any change of the refill mark on this item)
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, units_per_purchase, consumption_per_booking, usage_baseline_per_turnover) values
  ('e1200000-0000-4000-8000-0000000001c7', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 s3 hookfail', 'Other', 'pc', 10, true, true, 1, 2.00, 1.0);
create function public.zz_s120_boom2() returns trigger language plpgsql as
$$ begin if new.id = 'e1200000-0000-4000-8000-0000000001c7' and new.last_refill_at is distinct from old.last_refill_at then raise exception 'boom2'; end if; return new; end $$;
create trigger zz_s120_boom2 before update on public.inventory_items for each row execute function public.zz_s120_boom2();
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200000-0000-4000-8000-000000000001"}';
select is(((public.record_inventory_receipt_v1('e1200000-0000-4000-8000-0000000001c7', 2, null, 'Zz S120 vendor', public.manila_today(), null, null, 'zz-s120-receipt-key-0002', null)) ->> 'unitsAdded')::numeric, 2::numeric,
  'hook failure: the admin receipt still succeeds');
reset role;
select is((select qty_on_hand || '/' || coalesce(last_refill_at::text, 'none') from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000001c7'), '12.00/none', 'hook failure: the receipt stock is kept and only the refill mark was lost');
insert into _r select 's3ocr', public.apply_inventory_purchase('e1200000-0000-4000-8000-0000000001c7', 3, 60, 'Zz S120 vendor', public.manila_today(), null, null);
select is((select qty_on_hand || '/' || coalesce(last_refill_at::text, 'none') from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000001c7'), '15.00/none', 'hook failure: the OCR restock still adds its stock');
select isnt(public.s_inventory_receipt_apply_v1('e1200000-0000-4000-8000-0000000001c7', 4, null, 'Zz S120 vendor', null, public.manila_today(), null, 'e1200000-0000-4000-8000-0000000000d2'), null::uuid, 'hook failure: the staff receipt still writes its purchase row');
select is((select qty_on_hand || '/' || coalesce(last_refill_at::text, 'none') from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000001c7'), '19.00/none', 'hook failure: and its stock');
drop trigger zz_s120_boom2 on public.inventory_items;

-- baseline 0 (Tea, Sugar and Bathroom tissue are optional "used this stay" items): no division by zero anywhere, no forecast claim, no false alert
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, consumption_per_booking, usage_baseline_per_turnover) values
  ('e1200000-0000-4000-8000-0000000001d1', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 zero-used', 'Other', 'pc', 40, true, true, 0, 0),
  ('e1200000-0000-4000-8000-0000000001d2', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 zero-unused', 'Other', 'pc', 40, true, true, 0, 0);
insert into _r select 'z1', pg_temp.anc('e1200000-0000-4000-8000-0000000001d1', 100, interval '30 days');
insert into _r select 'z2', pg_temp.anc('e1200000-0000-4000-8000-0000000001d1', 60, interval '5 days');
insert into _r select 'z3', pg_temp.anc('e1200000-0000-4000-8000-0000000001d2', 50, interval '30 days');
insert into _r select 'z4', pg_temp.anc('e1200000-0000-4000-8000-0000000001d2', 50, interval '5 days');
select is((select consumption_per_booking from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000001d1'), 2.8571::numeric,
  'baseline 0: the prior adds nothing, (0 * 10 + 40) / (10 + 4) = 2.8571 once it is used');
select is((select predicted from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000001d1' and accepted), null::numeric,
  'baseline 0: a rate of 0 forecast nothing, so the interval carries no forecast (the KPI error is not skewed to 100 percent)');
select is((select consumption_per_booking || '/' || usage_state from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000001d2'), '0.0000/learning',
  'baseline 0: nothing used stays at rate 0 (no division by zero, no error)');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200000-0000-4000-8000-000000000001"}';
select ok((select e -> 'estCoverageDays' = 'null'::jsonb and coalesce((e ->> 'estDailyUsage')::numeric, 0) = 0
             from jsonb_array_elements(public.get_inventory_catalogue_v1('e1200000-0000-4000-8000-0000000000b0') -> 'items') e where e ->> 'id' = 'e1200000-0000-4000-8000-0000000001d2'),
  'baseline 0: the catalogue makes no coverage claim for a rate of 0');
select ok(not exists (select 1 from jsonb_array_elements(public.get_inventory_usage_kpi_v1('e1200000-0000-4000-8000-0000000000b0') -> 'underFourteenDays' -> 'items') e where e ->> 'id' = 'e1200000-0000-4000-8000-0000000001d2'),
  'baseline 0: the KPI does not list a rate-0 item as running out');
reset role;

-- 56-58. a failing hook never blocks a count ---------------------------------------------------------------------------------------------------
create function public.zz_s120_boom() returns trigger language plpgsql as $$ begin raise exception 'boom'; end $$;
create trigger zz_s120_boom before insert on public.inventory_usage_intervals for each row execute function public.zz_s120_boom();
insert into _r select 'j1', public.s_apply_inventory_count_core_v1('zz-s120',
  jsonb_build_array(jsonb_build_object('item_id', 'e1200000-0000-4000-8000-0000000000ab', 'counted', 15, 'expected_before', 20)), 'fixture count', null, null);
select is((select v ->> 'ok' from _r where k = 'j1'), 'true', 'hook failure: the count still succeeds');
select is((select qty_on_hand from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000ab'), 15::numeric, 'hook failure: and the stock is updated');
select is((select count(*)::int from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000ab'), 0, 'hook failure: only the anchor was lost');

select * from finish();
rollback;
