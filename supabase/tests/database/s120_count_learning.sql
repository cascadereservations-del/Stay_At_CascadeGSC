-- Session 120 (lane S10): release s120_count_learning_20261120. A count keeps a consumable in the usage learning (reconcile_inventory_baseline_v1), undoing it takes its interval out
-- (inventory_undo_v1), record_missed_refill_v1 records a refill nobody entered without touching stock, and an ordinary purchase no longer clears the KPI prompt.
-- Synthetic fixtures only (uuids e1200010-..., property ...b0, items "Zz S120L ...", users ...01 admin, ...02 cleaner, ...03 no staff profile); every lookup is scoped to them because a real backup holds real rows.
-- Sessions (days ago): turnover 85 75 65 55 45 35 25 20 15, mid_stay 12 (never counted), deep_clean 8 (counted). A first anchor 30 days ago meets 25, 20, 15 and 8 = 4 stays;
-- a first anchor 10 days ago meets only 8 = 1 stay. Every count made through the RPCs anchors at now() of this transaction (the movement's created_at).
-- Hand-computed: baseline 1.0, consumed 40 over 4 stays learns (1.0*10 + 40) / (10 + 4) = 3.5714; the worked example 10 before, 34 counted, 30 refilled: consumed 10 + 0 + 30 - 34 = 6, rate (10 + 6) / 14 = 1.1429.
-- Everything rolls back.
begin;
select plan(61);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid), public.current_staff_active(text[]) to authenticated, service_role;
grant execute on function public.admin_require(text, uuid) to authenticated;

create function pg_temp.anc(p_item uuid, p_q numeric, p_ago interval) returns jsonb language sql as
$$ select public.record_inventory_anchor_v1($1, $2, now() - $3, 'count') $$;

create temp table _r(k text primary key, v jsonb);
grant all on _r to authenticated, service_role;

-- fixtures -------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values ('e1200010-0000-4000-8000-0000000000b0', 'Synthetic S120L', true);
insert into auth.users(id) values ('e1200010-0000-4000-8000-000000000001'), ('e1200010-0000-4000-8000-000000000002'), ('e1200010-0000-4000-8000-000000000003');
insert into public.staff_access_profiles(user_id, role) values ('e1200010-0000-4000-8000-000000000001', 'admin'), ('e1200010-0000-4000-8000-000000000002', 'cleaner');
insert into public.staff_property_access(user_id, property_id) values
  ('e1200010-0000-4000-8000-000000000001', 'e1200010-0000-4000-8000-0000000000b0'),
  ('e1200010-0000-4000-8000-000000000002', 'e1200010-0000-4000-8000-0000000000b0');
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, consumption_per_booking, usage_baseline_per_turnover) values
  ('e1200010-0000-4000-8000-0000000000a1', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L A', 'Other', 'pc', 50,  true,  true,  2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000a2', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L B', 'Other', 'pc', 30,  true,  true,  2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000a4', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L D', 'Other', 'pc', 10,  false, true,  2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000a5', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L E', 'Other', 'pc', 100, true,  true,  2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000a6', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L F', 'Other', 'pc', 100, true,  true,  1.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000a7', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L G', 'Other', 'pc', 100, true,  true,  2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000a8', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L H', 'Other', 'pc', 10,  true,  true,  2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000a9', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L I', 'Other', 'pc', 10,  true,  true,  2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000aa', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L J', 'Other', 'pc', 100, true,  true,  2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000ab', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L K', 'Other', 'pc', 10,  true,  true,  2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000ac', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L L', 'Other', 'pc', 10,  true,  true,  2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000ad', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L M', 'Other', 'pc', 10,  true,  true,  2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000ae', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L N inactive', 'Other', 'pc', 5, true, false, 2.00, 1.0);
-- C is already movement controlled
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, units_per_purchase, movement_controlled_at, baseline_reviewed_by, usage_baseline_per_turnover) values
  ('e1200010-0000-4000-8000-0000000000a3', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L C controlled', 'Other', 'pc', 10, true, 1, timestamptz '2026-11-01 08:00+08', 'e1200010-0000-4000-8000-000000000001', 1.0);
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type)
select 'e1200010-0000-4000-8000-0000000000b0', 'zz-s120l-' || d, 'Fixture', now() - make_interval(days => d), t
  from (values (85, 'turnover'), (75, 'turnover'), (65, 'turnover'), (55, 'turnover'), (45, 'turnover'), (35, 'turnover'),
               (25, 'turnover'), (20, 'turnover'), (15, 'turnover'), (12, 'mid_stay'), (8, 'deep_clean')) v(d, t);

-- first anchors (physical counts before the ones made below)
select pg_temp.anc(a, q, g) from (values
  ('e1200010-0000-4000-8000-0000000000a5'::uuid, 100, interval '30 days'), ('e1200010-0000-4000-8000-0000000000a6', 100, interval '30 days'),
  ('e1200010-0000-4000-8000-0000000000a7', 100, interval '30 days'), ('e1200010-0000-4000-8000-0000000000a8', 10, interval '30 days'),
  ('e1200010-0000-4000-8000-0000000000a9', 10, interval '30 days'), ('e1200010-0000-4000-8000-0000000000aa', 100, interval '30 days'),
  ('e1200010-0000-4000-8000-0000000000ab', 10, interval '10 days'), ('e1200010-0000-4000-8000-0000000000ac', 10, interval '30 days'),
  ('e1200010-0000-4000-8000-0000000000ad', 10, interval '30 days')) v(a, q, g);
-- M: a purchase entered 20 days ago but received on the day of its previous count (it may already be in that count)
insert into public.inventory_purchases(item_id, qty, purchased_at, created_at)
values ('e1200010-0000-4000-8000-0000000000ad', 5, ((now() - interval '30 days') at time zone 'Asia/Manila')::date, now() - interval '20 days');

-- 1-6. shape and grants --------------------------------------------------------------------------------------------------------------------
select ok(exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'inventory_usage_intervals' and column_name = 'refill_recorded_qty'
                   and data_type = 'numeric' and is_nullable = 'YES'), 'the intervals table has a nullable numeric refill_recorded_qty');
select throws_ok($$update public.inventory_usage_intervals set refill_recorded_qty = 0 where item_id = 'e1200010-0000-4000-8000-0000000000a5'$$, '23514', null, 'refill_recorded_qty must be above 0');
select ok(not has_table_privilege('anon', 'public.inventory_usage_intervals', 'select, insert, update, delete')
      and not has_table_privilege('authenticated', 'public.inventory_usage_intervals', 'select, insert, update, delete')
      and not has_table_privilege('service_role', 'public.inventory_usage_intervals', 'select, insert, update, delete'), 'the intervals table still has no direct grant for any API role');
select ok(not has_function_privilege('anon', 'public.record_missed_refill_v1(uuid,numeric)', 'execute') and has_function_privilege('authenticated', 'public.record_missed_refill_v1(uuid,numeric)', 'execute')
      and not has_function_privilege('service_role', 'public.record_missed_refill_v1(uuid,numeric)', 'execute'), 'record_missed_refill_v1: signed-in users only');
select ok((select prosecdef and proconfig = array['search_path=""'] and provolatile = 'v' from pg_proc where oid = 'public.record_missed_refill_v1(uuid,numeric)'::regprocedure),
  'record_missed_refill_v1 is security definer with an empty search_path and volatile');
select ok(position('record_inventory_anchor_v1' in (select prosrc from pg_proc where oid = 'public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)'::regprocedure)) > 0
      and position('s_inventory_usage_recompute_v1' in (select prosrc from pg_proc where oid = 'public.inventory_undo_v1(uuid,uuid)'::regprocedure)) > 0
      and position('inventory_purchases' in (select prosrc from pg_proc where oid = 'public.get_inventory_usage_kpi_v1(uuid)'::regprocedure)) = 0
      and has_function_privilege('authenticated', 'public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)', 'execute') and has_function_privilege('authenticated', 'public.inventory_undo_v1(uuid,uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.get_inventory_usage_kpi_v1(uuid)', 'execute') and not has_function_privilege('anon', 'public.inventory_undo_v1(uuid,uuid)', 'execute'),
  'count route and undo carry their blocks, the KPI no longer reads purchases, and the grants are as before');

-- 7-. the counts, all through the real RPC as the admin or the cleaner ----------------------------------------------------------------------------
select ok((select movement_controlled_at is not null from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000a3'), 'fixture: C is movement controlled');
insert into _r select 'c0', to_jsonb(movement_controlled_at) from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000a3';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000001"}';
insert into _r select 'cA',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000a1', 40, 'zz count A',   'zzs120l-count-a-00000001');
insert into _r select 'cA2', public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000a1', 40, 'zz count A',   'zzs120l-count-a-00000001');
insert into _r select 'cC',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000a3', 12, 'zz count C',   'zzs120l-count-c-00000001');
insert into _r select 'cD',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000a4', 12, 'zz count D',   'zzs120l-count-d-00000001');
insert into _r select 'cE',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000a5', 60, 'zz count E',   'zzs120l-count-e-00000001');
insert into _r select 'cF',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000a6', 60, 'zz count F',   'zzs120l-count-f-00000001');
insert into _r select 'cG',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000a7', 60, 'zz count G',   'zzs120l-count-g-00000001');
insert into _r select 'cH',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000a8', 34, 'zz count H',   'zzs120l-count-h-00000001');
insert into _r select 'cI',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000a9', 34, 'zz count I',   'zzs120l-count-i-00000001');
insert into _r select 'cJ',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000aa', 60, 'zz count J',   'zzs120l-count-j-00000001');
insert into _r select 'cK',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000ab', 34, 'zz count K',   'zzs120l-count-k-00000001');
insert into _r select 'cL',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000ac', 34, 'zz count L',   'zzs120l-count-l-00000001');
insert into _r select 'cM',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000ad', 34, 'zz count M',   'zzs120l-count-m-00000001');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000002"}';
insert into _r select 'cB',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000a2', 25, 'zz count B',   'zzs120l-count-b-00000001');
reset role;

-- A: the admin count
select ok((select movement_controlled_at is null and qty_on_hand = 40 and baseline_note = 'zz count A' and baseline_reviewed_by = 'e1200010-0000-4000-8000-000000000001'
             from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000a1'),
  'A: an admin count of a consumable leaves it not controlled, sets the stock to the count and still writes the reviewer and the note');
select is((select count(*)::int from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a1'), 1, 'A: the count is the one (first anchor) interval');
select is((select v ->> 'movementId' from _r where k = 'cA2'), (select v ->> 'movementId' from _r where k = 'cA'), 'A: a replay with the same key returns the same movement');
select is((select count(*)::int from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a1'), 1, 'A: and adds no interval');
-- the replay of an OLD count (its movement is older than this call) must not anchor: wipe the interval, age the movement, replay
delete from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a1';
update public.inventory_stock_movements set created_at = created_at - interval '1 hour' where id = (select (v ->> 'movementId')::uuid from _r where k = 'cA');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000001"}';
select public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000a1', 40, 'zz count A', 'zzs120l-count-a-00000001');
reset role;
select is((select count(*)::int from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a1'), 0, 'A: a replay of an older count writes no anchor (only the call that wrote the movement does)');

-- B: the cleaner count
select ok((select movement_controlled_at is null and qty_on_hand = 25 from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000a2')
      and (select count(*) from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a2' and reject_reason = 'first anchor') = 1
      and (select actor_user_id from public.inventory_stock_movements where id = (select (v ->> 'movementId')::uuid from _r where k = 'cB')) = 'e1200010-0000-4000-8000-000000000002',
  'B: a cleaner count (staff movement path) is the same: not controlled, stock 25, one first anchor');

-- C and D: unchanged behaviour
select ok((select movement_controlled_at is not distinct from (select (v #>> '{}')::timestamptz from _r where k = 'c0') and qty_on_hand = 12 from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000a3')
      and not exists (select 1 from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a3'),
  'C: a controlled item keeps its original flag time, takes the count and gets no interval');
select ok((select movement_controlled_at is not null and qty_on_hand = 12 from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000a4')
      and not exists (select 1 from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a4'),
  'D: a non-consumable still gets the flag, takes the count and gets no interval');
select is((select v ->> 'ok' from _r where k = 'cC') || (select v ->> 'ok' from _r where k = 'cD'), 'truetrue', 'C and D: the result is ok as before');

-- E: two counts, 4 stays, 30 days
select is((select consumed || '/' || days || '/' || turnovers || '/' || accepted from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a5' and reject_reason is null),
  '40/30.00/4/true', 'E: the second count is accepted (40 used over 30.00 days and 4 stays)');
select is((select consumption_per_booking from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000a5'), 3.5714::numeric, 'E: the rate moved: (1.0*10 + 40) / (10 + 4)');
select ok((select movement_controlled_at is null and usage_state = 'learning' from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000a5'), 'E: and the item is still learning, not controlled');

-- F: undo the newest count
select ok((select consumption_per_booking = 3.5714 from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000a6')
      and (select count(*) from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a6') = 2, 'F: before the undo there are two intervals and the learned rate');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000001"}';
insert into _r select 'uF', public.inventory_undo_v1((select (v ->> 'movementId')::uuid from _r where k = 'cF'), null);
reset role;
select is((select v ->> 'ok' from _r where k = 'uF'), 'true', 'F: the undo of the count succeeds');
select is((select count(*)::int from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a6'), 1, 'F: the undo took the newest interval out');
select ok((select consumption_per_booking = 1.0 and usage_state = 'baseline' and qty_on_hand = 100 from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000a6'), 'F: and the rate is back to the baseline, the stock to 100');
insert into _r select 'nF', pg_temp.anc('e1200010-0000-4000-8000-0000000000a6', 55, interval '0');
select is((select (v ->> 'accepted') || '/' || (v ->> 'turnovers') || '/' || (v ->> 'consumed') from _r where k = 'nF'), 'true/4/45', 'F: the next count claims the four stays again (their keys left with the row) and is accepted');

-- G: a newer interval exists, the undo leaves the history alone
insert into _r select 'nG', pg_temp.anc('e1200010-0000-4000-8000-0000000000a7', 20, interval '-1 hour');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000001"}';
insert into _r select 'uG', public.inventory_undo_v1((select (v ->> 'movementId')::uuid from _r where k = 'cG'), null);
reset role;
select is((select v ->> 'ok' from _r where k = 'uG'), 'true', 'G: the undo succeeds');
select is((select count(*)::int from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a7'), 3, 'G: with a newer interval the three intervals stay (history is not rewritten)');

-- an ordinary receipt after an unrecorded-restock count (L); a prior-day purchase is already in M
insert into public.inventory_purchases(item_id, qty, created_at) values ('e1200010-0000-4000-8000-0000000000ac', 5, now() + interval '1 minute');

-- KPI before the refills are recorded
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000001"}';
insert into _r select 'kpi1', public.get_inventory_usage_kpi_v1('e1200010-0000-4000-8000-0000000000b0');
reset role;
select is((select array_to_string(array_agg(e ->> 'name' order by e ->> 'name'), ',') from jsonb_array_elements((select v -> 'waitingForRefill' -> 'items' from _r where k = 'kpi1')) e),
  'Zz S120L H,Zz S120L I,Zz S120L K,Zz S120L L,Zz S120L M', 'KPI: H, I, K, L and M wait for a recorded refill (their newest count was an unrecorded restock)');
select ok((select v -> 'waitingForRefill' -> 'items' from _r where k = 'kpi1') @> '[{"name": "Zz S120L L"}]', 'KPI: an ordinary purchase entered after the count (L) does not clear the prompt');
select is((select array_to_string(array_agg(k order by k), ',') from jsonb_object_keys((select v from _r where k = 'kpi1')) k),
  'asOf,forecastSamples,itemsLearning,itemsMeasured,itemsTotal,medianForecastError,ok,underFourteenDays,waitingForRefill', 'KPI: the result keys are unchanged');

-- H: the worked example
select is((select qty_prev || '/' || qty_now || '/' || received_between || '/' || reject_reason from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a8' order by anchor_at desc limit 1),
  '10/34/0/unrecorded restock', 'H: the count of 34 after 10 was rejected as an unrecorded restock');
-- gate, validation and answers that write nothing
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000002"}';
select throws_ok($$select public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000a8', 30)$$, '42501', null, 'a cleaner may not record a missed refill');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000003"}';
select throws_ok($$select public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000a8', 30)$$, '42501', null, 'a user with no staff profile may not record a missed refill');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000001"}';
select throws_ok($$select public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000ff', 30)$$, 'P0002', null, 'an unknown item is P0002');
select throws_ok($$select public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000a8', null)$$, '22023', null, 'a null quantity is 22023');
select throws_ok($$select public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000a8', 0)$$, '22023', null, 'zero is 22023');
select throws_ok($$select public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000a8', -3)$$, '22023', null, 'a negative quantity is 22023');
select throws_ok($$select public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000a8', 1.234)$$, '22023', null, 'more than 2 decimals is 22023');
select throws_ok($$select public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000a8', 'NaN'::numeric)$$, '22023', null, 'NaN is 22023');
insert into _r select 'nl1', public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000a3', 30);
insert into _r select 'nl2', public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000a4', 30);
insert into _r select 'nl3', public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000ae', 30);
insert into _r select 'nw1', public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000aa', 5);
insert into _r select 'nw2', public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000a2', 5);
insert into _r select 'ts1', public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000a9', 20);
reset role;
select is((select (v ->> 'ok') || '/' || (v ->> 'reason') from _r where k = 'nl1'), 'false/not_learning', 'a controlled item is not_learning');
select is((select (v ->> 'ok') || '/' || (v ->> 'reason') from _r where k = 'nl2'), 'false/not_learning', 'a non-consumable is not_learning');
select is((select (v ->> 'ok') || '/' || (v ->> 'reason') from _r where k = 'nl3'), 'false/not_learning', 'an inactive item is not_learning');
select is((select (v ->> 'ok') || '/' || (v ->> 'reason') from _r where k = 'nw1'), 'false/not_waiting', 'J: a newest count that was accepted is not_waiting');
select is((select (v ->> 'ok') || '/' || (v ->> 'reason') from _r where k = 'nw2'), 'false/not_waiting', 'B: an item whose newest interval is its first anchor is not_waiting');
select is((select (v ->> 'ok') || '/' || (v ->> 'reason') || '/' || (v ->> 'minimum') from _r where k = 'ts1'), 'false/too_small/24', 'I: 20 is too small and the smallest quantity is 24 (34 - 10 - 0)');
select ok((select received_between = 0 and refill_recorded_qty is null and consumed = -24 and reject_reason = 'unrecorded restock' and not accepted
             from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a9' order by anchor_at desc limit 1)
      and (select last_refill_at is null and last_refill_qty is null from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000a9')
      and not exists (select 1 from public.inventory_audit_log where entity_id in ('e1200010-0000-4000-8000-0000000000a9', 'e1200010-0000-4000-8000-0000000000aa', 'e1200010-0000-4000-8000-0000000000a3') and action = 'missed_refill'),
  'a refused call writes nothing: the interval, the refill mark and the audit log are as they were');
select is((select received_between from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000aa' order by anchor_at desc limit 1), 0::numeric, 'J: not_waiting left the interval alone');

-- H succeeds
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000001"}';
insert into _r select 'mH',  public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000a8', 30);
insert into _r select 'mH2', public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000a8', 30);
insert into _r select 'mH3', public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000a8', 31);
insert into _r select 'mI',  public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000a9', 24);
insert into _r select 'mK',  public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000ab', 30);
insert into _r select 'mM',  public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000ad', 30);
insert into _r select 'kpi2', public.get_inventory_usage_kpi_v1('e1200010-0000-4000-8000-0000000000b0');
reset role;
select is((select (v ->> 'ok') || '/' || (v ->> 'accepted') || '/' || (v ->> 'consumed') || '/' || (v ->> 'received') || '/' || coalesce(v ->> 'reason', 'none') from _r where k = 'mH'),
  'true/true/6/30/none', 'H: 10 before + 30 refilled - 34 counted = 6 used: accepted, received 30, no reason');
select ok((select qty_on_hand = 34 and last_refill_qty = 30 and last_refill_at = (select anchor_at from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a8' order by anchor_at desc limit 1)
             from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000a8')
      and not exists (select 1 from public.inventory_purchases where item_id = 'e1200010-0000-4000-8000-0000000000a8'),
  'H: the stock is still 34, no purchase was written, the refill mark is the count time and 30');
select is((select received_between || '/' || refill_recorded_qty || '/' || consumed || '/' || accepted || '/' || coalesce(reject_reason, 'none') || '/' || turnovers
             from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a8' order by anchor_at desc limit 1), '30/30/6/true/none/4', 'H: the interval holds the refill and the new figures');
select is((select consumption_per_booking from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000a8'), 1.1429::numeric, 'H: the rate learned from it: (1.0*10 + 6) / (10 + 4)');
select is((select count(*)::int from public.inventory_audit_log where entity_id = 'e1200010-0000-4000-8000-0000000000a8' and action = 'missed_refill'), 1, 'H: one audit row');
select ok((select v ->> 'replayed' = 'true' and v ->> 'ok' = 'true' from _r where k = 'mH2')
      and (select count(*) from public.inventory_audit_log where entity_id = 'e1200010-0000-4000-8000-0000000000a8' and action = 'missed_refill') = 1
      and (select received_between from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a8' order by anchor_at desc limit 1) = 30,
  'H: the same quantity again is replayed and writes nothing');
select is((select (v ->> 'ok') || '/' || (v ->> 'reason') from _r where k = 'mH3'), 'false/not_waiting', 'H: another quantity afterwards is not_waiting');
select is((select (v ->> 'accepted') || '/' || (v ->> 'consumed') from _r where k = 'mI'), 'true/0', 'I: the minimum (24) makes consumed exactly 0 and the interval is accepted');
select is((select (v ->> 'accepted') || '/' || (v ->> 'reason') || '/' || (v ->> 'consumed') from _r where k = 'mK'), 'false/too few turnovers/6', 'K: 1 stay in 10 days stays rejected, with that reason (not unrecorded restock)');
select is((select (v ->> 'accepted') || '/' || (v ->> 'reason') || '/' || (v ->> 'consumed') || '/' || (v ->> 'received') from _r where k = 'mM'), 'false/same-day purchase/11.00/35.00',
  'M: a purchase received on the previous count day rejects it (same-day purchase); received is 5 + 30');
select is((select array_to_string(array_agg(e ->> 'name' order by e ->> 'name'), ',') from jsonb_array_elements((select v -> 'waitingForRefill' -> 'items' from _r where k = 'kpi2')) e),
  'Zz S120L L', 'KPI: once the refills are recorded the prompt is gone (H, I, K, M); L still waits because nothing was recorded for it');

-- ROLLBACK: the script's own statements (without its begin and commit), then the bodies are what they were
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)');
  if v_src is null then raise exception 's120 rollback: public.reconcile_inventory_baseline_v1 is missing' using errcode = '55000'; end if;
  if md5(v_src) = '7cbb2ea861268b3fbe848c974e32b2f2' then raise notice 'reconcile_inventory_baseline_v1 already original';
  else
    v_new := replace(v_src,
      replace($r$-- S120: a count of an active consumable that is not movement controlled keeps it in the usage learning: movement_controlled_at stays null and the count is an anchor
  if coalesce(i.is_consumable, false) and coalesce(i.is_active, false) and i.movement_controlled_at is null then
    update public.inventory_items set baseline_reviewed_by = auth.uid(), baseline_note = btrim(p_note) where id = p_item_id;
    -- only the call that wrote the movement anchors it (a replay returns the older movement); a problem here must never block a count
    declare v_at timestamptz;
    begin
      select m.created_at into v_at from public.inventory_stock_movements m where m.id = v_mid;
      if v_at = now() then
        perform public.record_inventory_anchor_v1(p_item_id, p_counted_qty, v_at, 'count');
      end if;
    exception when others then
      raise warning 's120 usage anchor (reconcile): % (%)', sqlerrm, sqlstate;
    end;
  else
    update public.inventory_items set movement_controlled_at = coalesce(movement_controlled_at, now()), baseline_reviewed_by = auth.uid(), baseline_note = btrim(p_note) where id = p_item_id;
  end if;$r$, chr(13), ''),
      replace($f$update public.inventory_items set movement_controlled_at = coalesce(movement_controlled_at, now()), baseline_reviewed_by = auth.uid(), baseline_note = btrim(p_note) where id = p_item_id;$f$, chr(13), ''));
    if md5(v_new) is distinct from '7cbb2ea861268b3fbe848c974e32b2f2' then
      raise exception 's120 rollback: reconcile_inventory_baseline_v1 is not the release body (md5 %)', md5(v_src) using errcode = '55000';
    end if;
    execute format($e$create or replace function public.reconcile_inventory_baseline_v1(p_item_id uuid, p_counted_qty numeric, p_note text, p_idempotency_key text)
      returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
  end if;
end $g$;
revoke all on function public.reconcile_inventory_baseline_v1(uuid, numeric, text, text) from public, anon, service_role;
grant execute on function public.reconcile_inventory_baseline_v1(uuid, numeric, text, text) to authenticated;

do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.inventory_undo_v1(uuid,uuid)');
  if v_src is null then raise exception 's120 rollback: public.inventory_undo_v1 is missing' using errcode = '55000'; end if;
  if md5(v_src) = 'b3923b0bae57e812bb8375eea81f93e9' then raise notice 'inventory_undo_v1 already original';
  else
    v_new := replace(v_src,
      replace($r$-- S120: undoing a count that anchored the usage learning takes its interval out again (only the newest one, else the history stays); a problem here must never fail an undo
  if v_have_m and m.kind = 'reconcile' and i.movement_controlled_at is null then
    begin
      delete from public.inventory_usage_intervals x
       where x.item_id = i.id and x.anchor_at = m.created_at
         and not exists (select 1 from public.inventory_usage_intervals y where y.item_id = i.id and y.anchor_at > x.anchor_at);
      if found then
        perform public.s_inventory_usage_recompute_v1(i.id, now());
      end if;
    exception when others then
      raise warning 's120 usage anchor (undo): % (%)', sqlerrm, sqlstate;
    end;
  end if;
  select it.qty_on_hand into v_after from public.inventory_items it where it.id = i.id;$r$, chr(13), ''),
      replace($f$select it.qty_on_hand into v_after from public.inventory_items it where it.id = i.id;$f$, chr(13), ''));
    if md5(v_new) is distinct from 'b3923b0bae57e812bb8375eea81f93e9' then
      raise exception 's120 rollback: inventory_undo_v1 is not the release body (md5 %)', md5(v_src) using errcode = '55000';
    end if;
    execute format($e$create or replace function public.inventory_undo_v1(p_movement_id uuid default null, p_purchase_id uuid default null)
      returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
  end if;
end $g$;
revoke all on function public.inventory_undo_v1(uuid, uuid) from public, anon, service_role;
grant execute on function public.inventory_undo_v1(uuid, uuid) to authenticated;

do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.get_inventory_usage_kpi_v1(uuid)');
  if v_src is null then raise exception 's120 rollback: public.get_inventory_usage_kpi_v1 is missing' using errcode = '55000'; end if;
  if md5(v_src) = 'f0a2052c3ccc56673808d000ba21d189' then raise notice 'get_inventory_usage_kpi_v1 already original';
  else
    v_new := replace(v_src,
      replace($r$-- the newest interval of the item was rejected as an unrecorded restock and the refill is not recorded yet: only a missed refill (record_missed_refill_v1) or a newer count ends the prompt, an ordinary purchase does not (the count already holds its stock)$r$, chr(13), ''),
      replace($f$-- the newest interval of the item was rejected as an unrecorded restock and nothing has been recorded since that count$f$, chr(13), ''));
    v_new := replace(v_new, $r$'unrecorded restock') w;$r$,
      replace($f$'unrecorded restock'
             and not exists (select 1 from public.inventory_purchases p where p.item_id = i.id and p.created_at > x.anchor_at)) w;$f$, chr(13), ''));
    if md5(v_new) is distinct from 'f0a2052c3ccc56673808d000ba21d189' then
      raise exception 's120 rollback: get_inventory_usage_kpi_v1 is not the release body (md5 %)', md5(v_src) using errcode = '55000';
    end if;
    execute format($e$create or replace function public.get_inventory_usage_kpi_v1(p_property_id uuid)
      returns jsonb language plpgsql stable security definer set search_path = '' as %L$e$, v_new);
  end if;
end $g$;
comment on function public.get_inventory_usage_kpi_v1(uuid) is
  'S120: usage-learning KPI (read_operations). itemsMeasured of itemsTotal, medianForecastError (null with no sample), items under 14 days of stock at the learned rate, items waiting for a recorded refill.';
revoke all on function public.get_inventory_usage_kpi_v1(uuid) from public, anon, service_role;
grant execute on function public.get_inventory_usage_kpi_v1(uuid) to authenticated;

drop function if exists public.record_missed_refill_v1(uuid, numeric);
alter table public.inventory_usage_intervals drop column if exists refill_recorded_qty;

do $v$
begin
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)'::regprocedure) is distinct from '7cbb2ea861268b3fbe848c974e32b2f2'
     or (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.inventory_undo_v1(uuid,uuid)'::regprocedure) is distinct from 'b3923b0bae57e812bb8375eea81f93e9'
     or (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.get_inventory_usage_kpi_v1(uuid)'::regprocedure) is distinct from 'f0a2052c3ccc56673808d000ba21d189' then
    raise exception 's120 rollback: a function is not back to its pre-release body' using errcode = '55000';
  end if;
end $v$;
select ok((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)'::regprocedure) = '7cbb2ea861268b3fbe848c974e32b2f2'
      and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.inventory_undo_v1(uuid,uuid)'::regprocedure) = 'b3923b0bae57e812bb8375eea81f93e9',
  'rollback: the count route and the undo are the md5 they were before the release');
select ok((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.get_inventory_usage_kpi_v1(uuid)'::regprocedure) = 'f0a2052c3ccc56673808d000ba21d189'
      and position('inventory_purchases' in (select prosrc from pg_proc where oid = 'public.get_inventory_usage_kpi_v1(uuid)'::regprocedure)) > 0,
  'rollback: the KPI has its purchase condition back (md5 f0a2052c)');
select ok(to_regprocedure('public.record_missed_refill_v1(uuid,numeric)') is null
      and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'inventory_usage_intervals' and column_name = 'refill_recorded_qty'),
  'rollback: record_missed_refill_v1 and the column are gone');
select ok(exists (select 1 from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a8' and accepted and consumed = 6)
      and (select count(*) from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a5') = 2,
  'rollback: the intervals are not otherwise touched');

select * from finish();
rollback;
