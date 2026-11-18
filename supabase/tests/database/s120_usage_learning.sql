-- Session 120 (lane S): release s120_usage_learning_20261120. record_inventory_anchor_v1 (count and receipt anchors), s_inventory_usage_recompute_v1,
-- the hooks in s_apply_inventory_count_core_v1, get_inventory_usage_kpi_v1 and the closed intervals table.
-- Synthetic fixtures only (uuids e1200000-..., property ...b0, items "Zz S120 ..."); every lookup is scoped to them because a real backup holds real rows.
-- Sessions (days ago): turnover 85 75 65 55 45 35 25 20 15, mid_stay 12 (never counted), deep_clean 8 (counted). Windows below are counted from that list.
-- Everything rolls back.
begin;
select plan(47);

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
  ('e1200000-0000-4000-8000-0000000000a2', 'e1200000-0000-4000-8000-0000000000b0', 'Zz S120 B', 'Other', 'pc', 500, true, true, 2.00, 1.0),
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
      and position('baselineNote' in (select prosrc from pg_proc where oid = 'public.get_inventory_catalogue_v1(uuid)'::regprocedure)) > 0, 'the catalogue gained the usage keys and kept the old ones');
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
select is((select consumption_per_booking || '/' || usage_state from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000a2'), '2.00/baseline', 'B: a rejected interval moves nothing');

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
select is((select received_between || '/' || consumed from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000a4' and accepted), '57/37',
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

-- 45-47. a failing hook never blocks a count ---------------------------------------------------------------------------------------------------
create function public.zz_s120_boom() returns trigger language plpgsql as $$ begin raise exception 'boom'; end $$;
create trigger zz_s120_boom before insert on public.inventory_usage_intervals for each row execute function public.zz_s120_boom();
insert into _r select 'j1', public.s_apply_inventory_count_core_v1('zz-s120',
  jsonb_build_array(jsonb_build_object('item_id', 'e1200000-0000-4000-8000-0000000000ab', 'counted', 15, 'expected_before', 20)), 'fixture count', null, null);
select is((select v ->> 'ok' from _r where k = 'j1'), 'true', 'hook failure: the count still succeeds');
select is((select qty_on_hand from public.inventory_items where id = 'e1200000-0000-4000-8000-0000000000ab'), 15::numeric, 'hook failure: and the stock is updated');
select is((select count(*)::int from public.inventory_usage_intervals where item_id = 'e1200000-0000-4000-8000-0000000000ab'), 0, 'hook failure: only the anchor was lost');

select * from finish();
rollback;
