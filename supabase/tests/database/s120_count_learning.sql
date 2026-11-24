-- Session 120 (lane S10): release s120_count_learning_20261120. A count keeps a consumable in the usage learning (reconcile_inventory_baseline_v1), undoing it takes its interval out
-- (inventory_undo_v1), record_missed_refill_v1 records a refill nobody entered without touching stock, and an ordinary purchase no longer clears the KPI prompt.
-- Synthetic fixtures only (uuids e1200010-..., property ...b0, items "Zz S120L ...", users ...01 admin, ...02 cleaner, ...03 no staff profile); every lookup is scoped to them because a real backup holds real rows.
-- Sessions (days ago): turnover 85 75 65 55 45 35 25 20 15, mid_stay 12 (never counted), deep_clean 8 (counted). A first anchor 30 days ago meets 25, 20, 15 and 8 = 4 stays;
-- a first anchor 10 days ago meets only 8 = 1 stay. Every count made through the RPCs anchors at now() of this transaction (the movement's created_at).
-- Hand-computed: baseline 1.0, consumed 40 over 4 stays learns (1.0*10 + 40) / (10 + 4) = 3.5714; the worked example 10 before, 34 counted, 30 refilled: consumed 10 + 0 + 30 - 34 = 6, rate (10 + 6) / 14 = 1.1429.
-- Everything rolls back.
begin;
select plan(95);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
do $sr$ begin if not (select rolbypassrls from pg_roles where rolname = 'service_role') then alter role service_role bypassrls; end if; end $sr$;
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
insert into public.properties(id, name, is_active) values ('e1200010-0000-4000-8000-0000000000b1', 'Synthetic S120L short stays', true);
insert into public.staff_property_access(user_id, property_id) values
  ('e1200010-0000-4000-8000-000000000001', 'e1200010-0000-4000-8000-0000000000b0'),
  ('e1200010-0000-4000-8000-000000000001', 'e1200010-0000-4000-8000-0000000000b1'),
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
  ('e1200010-0000-4000-8000-0000000000ae', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L N inactive', 'Other', 'pc', 5, true, false, 2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000c1', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L P', 'Other', 'pc', 10, true, true, 2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000c2', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L Q', 'Other', 'pc', 10, true, true, 2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000c3', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L R', 'Other', 'pc', 10, true, true, 2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000c4', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L S', 'Other', 'pc', 10, true, true, 2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000c5', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L T', 'Other', 'pc', 10, true, true, 2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000c6', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L U', 'Other', 'pc', 10, true, true, 2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000c7', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L W', 'Other', 'pc', 20, true, true, 2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000c8', 'e1200010-0000-4000-8000-0000000000b1', 'Zz S120L X', 'Other', 'pc', 10, true, true, 2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000c9', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L Y', 'Other', 'pc', 10, true, true, 2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000ca', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L Z', 'Other', 'pc', 10, true, true, 2.00, 1.0),
  ('e1200010-0000-4000-8000-0000000000cb', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L V', 'Other', 'pc', 10, true, true, 2.00, 1.0);
-- C is already movement controlled
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, units_per_purchase, movement_controlled_at, baseline_reviewed_by, usage_baseline_per_turnover) values
  ('e1200010-0000-4000-8000-0000000000a3', 'e1200010-0000-4000-8000-0000000000b0', 'Zz S120L C controlled', 'Other', 'pc', 10, true, 1, timestamptz '2026-11-01 08:00+08', 'e1200010-0000-4000-8000-000000000001', 1.0);
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type)
select 'e1200010-0000-4000-8000-0000000000b0', 'zz-s120l-' || d, 'Fixture', now() - make_interval(days => d), t
  from (values (85, 'turnover'), (75, 'turnover'), (65, 'turnover'), (55, 'turnover'), (45, 'turnover'), (35, 'turnover'),
               (25, 'turnover'), (20, 'turnover'), (15, 'turnover'), (12, 'mid_stay'), (8, 'deep_clean')) v(d, t);
-- the second property has three stays inside one week (for the too-short reason); X's first anchor is 6 days ago
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type)
select 'e1200010-0000-4000-8000-0000000000b1', 'zz-s120l-b1-' || d, 'Fixture', now() - make_interval(days => d), 'turnover' from (values (5), (4), (3)) v(d);

-- first anchors (physical counts before the ones made below)
select pg_temp.anc(a, q, g) from (values
  ('e1200010-0000-4000-8000-0000000000a5'::uuid, 100, interval '30 days'), ('e1200010-0000-4000-8000-0000000000a6', 100, interval '30 days'),
  ('e1200010-0000-4000-8000-0000000000a7', 100, interval '30 days'), ('e1200010-0000-4000-8000-0000000000a8', 10, interval '30 days'),
  ('e1200010-0000-4000-8000-0000000000a9', 10, interval '30 days'), ('e1200010-0000-4000-8000-0000000000aa', 100, interval '30 days'),
  ('e1200010-0000-4000-8000-0000000000ab', 10, interval '10 days'), ('e1200010-0000-4000-8000-0000000000ac', 10, interval '30 days'),
  ('e1200010-0000-4000-8000-0000000000ad', 10, interval '30 days'),
  ('e1200010-0000-4000-8000-0000000000c3', 10, interval '30 days'), ('e1200010-0000-4000-8000-0000000000c4', 10, interval '30 days'),
  ('e1200010-0000-4000-8000-0000000000c5', 10, interval '30 days'), ('e1200010-0000-4000-8000-0000000000c6', 10, interval '30 days'),
  ('e1200010-0000-4000-8000-0000000000c8', 10, interval '6 days')) v(a, q, g);
-- S and T: a purchase received 21 days ago, entered 20 days ago (between their two counts); the received date is not the UTC date of the entry, so it is kept
insert into public.inventory_purchases(item_id, qty, purchased_at, created_at) values
  ('e1200010-0000-4000-8000-0000000000c4', 5, (now() at time zone 'UTC')::date - 21, now() - interval '20 days'),
  ('e1200010-0000-4000-8000-0000000000c5', 3, (now() at time zone 'UTC')::date - 21, now() - interval '20 days');
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
select is((select count(*)::int from public.inventory_audit_log where entity_id = 'e1200010-0000-4000-8000-0000000000a1' and action = 'app_count'), 1,
  'A: the count wrote one app_count audit row and neither replay (same key, or an older movement) wrote another');

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
-- since is the PREVIOUS count (H: first anchor 30 days ago, then the count that found the jump), not the newest count
select ok((select (e ->> 'since')::timestamptz from jsonb_array_elements((select v -> 'waitingForRefill' -> 'items' from _r where k = 'kpi1')) e where e ->> 'name' = 'Zz S120L H')
      = (select prev_anchor_at from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a8' order by anchor_at desc limit 1), 'KPI: since of a waiting item is the previous count (prev_anchor_at)');
select ok((select (e ->> 'since')::timestamptz from jsonb_array_elements((select v -> 'waitingForRefill' -> 'items' from _r where k = 'kpi1')) e where e ->> 'name' = 'Zz S120L H')
      < (select anchor_at from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a8' order by anchor_at desc limit 1), 'KPI: and it is not the newest count (the refill happened before that count)');
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

-- S11 (fixes from the Opus review) ==========================================================================================================================
-- Item 1: an app count is an audited stock change, so a Telegram count "as of" an earlier time rebuilds the past stock right (inventory_qty_at_v1 reads before/after qty_on_hand of audit rows).
-- P: stock 10, app count 34, then a Telegram count of 12 as of yesterday = 12 + (34 - 10) = 36 (the same as when the first count came through Telegram).
-- Q: the same, but the app count is undone first: stock 10 again, the as-of count is 12 + 0 = 12.
-- X: first anchor 6 days ago, three stays since: a refill makes consumed 6 but the interval is shorter than 7 days (too short).
create function public.zz_s120l_boom() returns trigger language plpgsql as $$ begin raise exception 'zz boom %', new.action; end $$;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000001"}';
insert into _r select 'cP',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000c1', 34, 'zz count P', 'zzs120l-count-p-00000001');
insert into _r select 'cQ',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000c2', 34, 'zz count Q', 'zzs120l-count-q-00000001');
insert into _r select 'uQ',  public.inventory_undo_v1((select (v ->> 'movementId')::uuid from _r where k = 'cQ'), null);
insert into _r select 'cV',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000cb', 34, 'zz count V', 'zzs120l-count-v-00000001');
insert into _r select 'cZ',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000ca', 34, 'zz count Z', 'zzs120l-count-z-00000001');
insert into _r select 'cW',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000c7', 40, 'zz count W', 'zzs120l-count-w-00000001');
insert into _r select 'cR',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000c3', 34, 'zz count R', 'zzs120l-count-r-00000001');
insert into _r select 'cS',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000c4', 34, 'zz count S', 'zzs120l-count-s-00000001');
insert into _r select 'cT',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000c5', 34, 'zz count T', 'zzs120l-count-t-00000001');
insert into _r select 'cU',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000c6', 34, 'zz count U', 'zzs120l-count-u-00000001');
insert into _r select 'cX',  public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000c8', 34, 'zz count X', 'zzs120l-count-x-00000001');
insert into _r select 'mvW', to_jsonb(public.record_inventory_movement('e1200010-0000-4000-8000-0000000000c7', 'receipt', 5, 'zz receipt W', 'zzs120l-receipt-w-00000001'));
insert into _r select 'uW',  public.inventory_undo_v1((select (v #>> '{}')::uuid from _r where k = 'mvW'), null);
reset role;
-- Z: counted while active (so it is learning), then deactivated; a replay of that count (the key is answered before the active check) now meets an inactive consumable
select ok((select movement_controlled_at is null from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000ca'), 'Z: counted while active it is not controlled');
update public.inventory_items set is_active = false where id = 'e1200010-0000-4000-8000-0000000000ca';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000001"}';
select public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000ca', 34, 'zz count Z', 'zzs120l-count-z-00000001');
reset role;

select ok((select count(*) = 1 and bool_and(jsonb_typeof(a.before -> 'qty_on_hand') = 'number' and jsonb_typeof(a.after -> 'qty_on_hand') = 'number')
                  and bool_and((a.before ->> 'qty_on_hand')::numeric = 10 and (a.after ->> 'qty_on_hand')::numeric = 34 and a.after ->> 'movement_id' = (select v ->> 'movementId' from _r where k = 'cP'))
             from public.inventory_audit_log a where a.entity_type = 'inventory_items' and a.entity_id = 'e1200010-0000-4000-8000-0000000000c1' and a.action = 'app_count'),
  'P: the app count wrote one app_count audit row, before 10 and after 34 as numbers, with the movement id');
insert into _r select 'tP', public.s_apply_inventory_count_core_v1('zz:s120l', jsonb_build_array(jsonb_build_object('item_id', 'e1200010-0000-4000-8000-0000000000c1', 'counted', 12, 'expected_before', 34)), 'zz as of', now() - interval '1 day', null);
select is((select (v ->> 'ok') || '/' || (v #>> '{rows,0,after}') from _r where k = 'tP'), 'true/36.00', 'P: stock 10, app count 34, Telegram count 12 as of yesterday gives 36 (12 + 24 since)');
select is((select qty_on_hand from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000c1'), 36.00::numeric, 'P: and the stock is 36');

select ok((select count(*) = 1 and bool_and((a.before ->> 'qty_on_hand')::numeric = 34 and (a.after ->> 'qty_on_hand')::numeric = 10 and jsonb_typeof(a.before -> 'qty_on_hand') = 'number' and jsonb_typeof(a.after -> 'qty_on_hand') = 'number')
             from public.inventory_audit_log a where a.entity_type = 'inventory_items' and a.entity_id = 'e1200010-0000-4000-8000-0000000000c2' and a.action = 'app_count_undo'),
  'Q: undoing the count wrote one app_count_undo row, before 34 (counted) and after 10 (restored)');
insert into _r select 'tQ', public.s_apply_inventory_count_core_v1('zz:s120l', jsonb_build_array(jsonb_build_object('item_id', 'e1200010-0000-4000-8000-0000000000c2', 'counted', 12, 'expected_before', 10)), 'zz as of', now() - interval '1 day', null);
select is((select (v ->> 'ok') || '/' || (v #>> '{rows,0,after}') from _r where k = 'tQ'), 'true/12.00', 'Q: after undoing the app count the as-of count of 12 gives 12 (nothing happened since)');

select is((select count(*)::int from public.inventory_audit_log where action in ('app_count', 'app_count_undo')
              and entity_id in ('e1200010-0000-4000-8000-0000000000a3', 'e1200010-0000-4000-8000-0000000000a4')), 0,
  'a controlled item (C) and a non-consumable (D) write no app_count row');
select ok((select movement_controlled_at is not null from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000ca')
      and (select count(*) from public.inventory_audit_log where entity_id = 'e1200010-0000-4000-8000-0000000000ca' and action = 'app_count') = 1,
  'Z: the replay on the now inactive consumable takes the old route (the flag is set; is_active in the count branch) and wrote no second audit row');
select ok((select count(*) = 1 from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000c7' and source = 'count')
      and (select qty_on_hand = 40 from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000c7')
      and (select count(*) from public.inventory_audit_log where entity_id = 'e1200010-0000-4000-8000-0000000000c7' and action = 'app_count') = 1
      and not exists (select 1 from public.inventory_audit_log where entity_id = 'e1200010-0000-4000-8000-0000000000c7' and action = 'app_count_undo'),
  'W: undoing a receipt movement (not a count) takes no interval out and writes no app_count_undo row (m.kind = reconcile)');
select is((select v ->> 'ok' from _r where k = 'uW'), 'true', 'W: that undo succeeded');

-- the audit row is part of the stock change: if it cannot be written the count / the undo fails as a whole
create trigger zz_s120l_boom_count before insert on public.inventory_audit_log for each row when (new.action = 'app_count') execute function public.zz_s120l_boom();
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000001"}';
select throws_ok($$select public.reconcile_inventory_baseline_v1('e1200010-0000-4000-8000-0000000000c9', 34, 'zz count Y', 'zzs120l-count-y-00000001')$$, 'P0001', 'zz boom app_count',
  'Y: when the app_count audit row cannot be written the count fails');
reset role;
drop trigger zz_s120l_boom_count on public.inventory_audit_log;
select ok((select qty_on_hand = 10 and movement_controlled_at is null and baseline_note is null from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000c9')
      and not exists (select 1 from public.inventory_stock_movements where item_id = 'e1200010-0000-4000-8000-0000000000c9')
      and not exists (select 1 from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000c9'),
  'Y: and nothing was kept: stock 10, no movement, no interval, no note');
create trigger zz_s120l_boom_undo before insert on public.inventory_audit_log for each row when (new.action = 'app_count_undo') execute function public.zz_s120l_boom();
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000001"}';
select throws_ok($$select public.inventory_undo_v1((select (v ->> 'movementId')::uuid from _r where k = 'cV'), null)$$, 'P0001', 'zz boom app_count_undo',
  'V: when the app_count_undo audit row cannot be written the undo fails');
reset role;
drop trigger zz_s120l_boom_undo on public.inventory_audit_log;
select ok((select qty_on_hand = 34 from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000cb')
      and (select count(*) from public.inventory_stock_movements where item_id = 'e1200010-0000-4000-8000-0000000000cb') = 1
      and (select count(*) from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000cb') = 1
      and (select count(*) from public.inventory_audit_log where entity_id = 'e1200010-0000-4000-8000-0000000000cb' and action = 'app_count') = 1,
  'V: and the failed undo kept everything: stock 34, one movement, the interval and the app_count row still there');

-- Item 2: the refill mark. R: a receipt undone after a recorded refill; S: the count with its recorded refill undone; T: a newer purchase beats the recorded refill; U: a newer mark is not moved back.
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000001"}';
insert into _r select 'rR',  public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000c3', 30);
insert into _r select 'sS1', public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000c4', 10);
reset role;
select is((select (v ->> 'ok') || '/' || (v ->> 'reason') || '/' || (v ->> 'minimum') from _r where k = 'sS1'), 'false/too_small/19.00', 'S: 5 were received between the counts, so the smallest refill is 34 - 10 - 5 = 19 (received_between in the minimum)');
select ok((select received_between = 5 and refill_recorded_qty is null and consumed = -19 and reject_reason = 'unrecorded restock'
             from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000c4' order by anchor_at desc limit 1),
  'S: the refused 10 wrote nothing');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000001"}';
insert into _r select 'sS2', public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000c4', 30);
insert into _r select 'sT',  public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000c5', 30);
reset role;
select is((select (v ->> 'accepted') || '/' || (v ->> 'consumed') || '/' || (v ->> 'received') from _r where k = 'sS2'), 'true/11.00/35.00', 'S: 10 + 5 received + 30 refilled - 34 counted = 11 used');

-- R: the mark is the recorded refill; an ordinary purchase entered after it is undone (deleted) and the recorded refill stays the mark
select ok((select last_refill_qty = 30 and last_refill_at = (select anchor_at from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000c3' order by anchor_at desc limit 1)
             from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000c3'), 'R: the recorded refill is the mark (the count time, 30)');
insert into public.inventory_purchases(item_id, qty, purchased_at, created_at) values ('e1200010-0000-4000-8000-0000000000c3', 5, (now() at time zone 'UTC')::date + 3, now() + interval '1 minute');
delete from public.inventory_purchases where item_id = 'e1200010-0000-4000-8000-0000000000c3';
select ok((select last_refill_qty = 30 and last_refill_at = (select anchor_at from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000c3' order by anchor_at desc limit 1)
             from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000c3'),
  'R: a receipt undone later does not wipe the recorded refill (the mark stays the count time and 30)');

-- T: a purchase dated after the recorded refill is the newest; deleting an older purchase leaves it the mark
select ok((select last_refill_qty = 30 from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000c5'), 'T: the recorded refill is the mark before the purchases change');
insert into public.inventory_purchases(item_id, qty, purchased_at, created_at) values ('e1200010-0000-4000-8000-0000000000c5', 8, (now() at time zone 'UTC')::date + 3, now() + interval '1 minute');
delete from public.inventory_purchases where item_id = 'e1200010-0000-4000-8000-0000000000c5' and qty = 3;
select ok((select last_refill_qty = 8 and last_refill_at = ((now() at time zone 'UTC')::date + 3)::timestamp at time zone 'Asia/Manila' from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000c5'),
  'T: the newest of the remaining purchase (8, dated 3 days ahead) and the recorded refill is the mark');

-- Z: an item that never had a refill mark does not get one from a purchase delete (the helper's last_refill_at guard); Z has no mark and no recorded refill
insert into public.inventory_purchases(item_id, qty, purchased_at, created_at) values
  ('e1200010-0000-4000-8000-0000000000ca', 4, (now() at time zone 'UTC')::date - 9, now() - interval '9 days'),
  ('e1200010-0000-4000-8000-0000000000ca', 6, (now() at time zone 'UTC')::date - 8, now() - interval '8 days');
delete from public.inventory_purchases where item_id = 'e1200010-0000-4000-8000-0000000000ca' and qty = 6;
select ok((select last_refill_at is null and last_refill_qty is null from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000ca'),
  'Z: deleting a purchase of an item with no refill mark leaves it without one');

-- S: the count is undone, its recorded refill leaves the mark and the remaining purchase (5, received 21 days ago) takes over
select ok((select last_refill_qty = 30 from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000c4'), 'S: before the undo the recorded refill is the mark');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000001"}';
insert into _r select 'uS', public.inventory_undo_v1((select (v ->> 'movementId')::uuid from _r where k = 'cS'), null);
reset role;
select is((select v ->> 'ok' from _r where k = 'uS'), 'true', 'S: the undo of the count succeeds');
select ok((select last_refill_qty = 5 and last_refill_at = ((now() at time zone 'UTC')::date - 21)::timestamp at time zone 'Asia/Manila' from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000c4')
      and (select count(*) from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000c4') = 1,
  'S: an undone count removes its recorded refill from the mark: the purchase of 5 received 21 days ago is the mark again');

-- U: a mark newer than the count (a purchase dated ahead) is not moved back by the recorded refill
update public.inventory_items set last_refill_at = now() + interval '2 days', last_refill_qty = 99 where id = 'e1200010-0000-4000-8000-0000000000c6';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000001"}';
insert into _r select 'sU', public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000c6', 30);
reset role;
select ok((select (v ->> 'accepted') = 'true' from _r where k = 'sU')
      and (select last_refill_qty = 99 and last_refill_at > now() + interval '1 day' from public.inventory_items where id = 'e1200010-0000-4000-8000-0000000000c6'),
  'U: a refill mark newer than the count is not moved back (the last_refill guard)');

-- reasons and the prediction: H was accepted at 4 stays with the baseline rate 1.0 in force, so it predicted 1.0 * 4
select is((select predicted from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a8' order by anchor_at desc limit 1), 4::numeric, 'H: an accepted interval stores what the rate in force (the baseline 1.0) predicted for its 4 stays');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200010-0000-4000-8000-000000000001"}';
insert into _r select 'sX', public.record_missed_refill_v1('e1200010-0000-4000-8000-0000000000c8', 30);
reset role;
select is((select (v ->> 'accepted') || '/' || (v ->> 'reason') || '/' || (v ->> 'consumed') from _r where k = 'sX'), 'false/too short/6', 'X: 3 stays but 6 days is under 7: stays rejected, with the reason too short');
select ok((select predicted is null and not accepted and turnovers = 3 and days = 6.00 from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000c8' order by anchor_at desc limit 1),
  'X: a rejected interval has no prediction');

-- the readers of inventory_audit_log read only their own actions: app_count / app_count_undo are in the qty_at sum and nowhere else
select ok(not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosrc like '%app_count%' and p.proname not in ('reconcile_inventory_baseline_v1', 'inventory_undo_v1')),
  'no other function mentions the new audit actions (the count history, the counted-at date and the usage backfill read telegram_count and movements only)');

-- The rollback script below patches the s120 release bodies back to the pre-release ones, so it can only be rehearsed while the count route and the undo are still the s120
-- release bodies (md5 18bea3e7... and b1c19525...). s132 (20261202000000_s132_inventory_update.sql) later replaced both (md5 fdeaf212... and 5125463a...), in production as in CI,
-- and carries its own rollback; from then on this section is skipped for those two functions (the rest of the rollback is still exercised).
select set_config('s120.rb',
  case when (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)'::regprocedure) in ('18bea3e74b205dc7526a9614b83521cc', '7cbb2ea861268b3fbe848c974e32b2f2')
        and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.inventory_undo_v1(uuid,uuid)'::regprocedure) in ('b1c19525aa43a0a529c511932d97a2fa', 'b3923b0bae57e812bb8375eea81f93e9')
       then 'on' else 'off' end, true);

-- ROLLBACK: the script's own statements (without its begin and commit), then the bodies are what they were
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)');
  if v_src is null then raise exception 's120 rollback: public.reconcile_inventory_baseline_v1 is missing' using errcode = '55000'; end if;
  if md5(v_src) = '7cbb2ea861268b3fbe848c974e32b2f2' or current_setting('s120.rb') = 'off' then raise notice 'reconcile_inventory_baseline_v1 already original or no longer the s120 body (s132): skipped';
  else
    v_new := replace(v_src,
      replace($r$-- S120: a count of an active consumable that is not movement controlled keeps it in the usage learning: movement_controlled_at stays null and the count is an anchor
  if coalesce(i.is_consumable, false) and coalesce(i.is_active, false) and i.movement_controlled_at is null then
    update public.inventory_items set baseline_reviewed_by = auth.uid(), baseline_note = btrim(p_note) where id = p_item_id;
    -- only the call that wrote the movement audits and anchors it (a replay returns the older movement)
    declare v_at timestamptz;
    begin
      select m.created_at into v_at from public.inventory_stock_movements m where m.id = v_mid;
      if v_at = now() then
        -- the count is a stock change that leaves no trace but its movement, and inventory_qty_at_v1 rebuilds past stock from audit rows: write the row it reads. NOT inside the guard below:
        -- when the row cannot be written the count fails as a whole
        if not exists (select 1 from public.inventory_audit_log a where a.entity_type = 'inventory_items' and a.entity_id = p_item_id and a.action = 'app_count' and a.after ->> 'movement_id' = v_mid::text) then
          insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor)
          values ('inventory_items', p_item_id, 'app_count', jsonb_build_object('qty_on_hand', v_before),
                  jsonb_build_object('qty_on_hand', p_counted_qty, 'movement_id', v_mid), coalesce(auth.uid()::text, 'app'));
        end if;
        -- a problem in the learning must never block a count
        begin
          perform public.record_inventory_anchor_v1(p_item_id, p_counted_qty, v_at, 'count');
        exception when others then
          raise warning 's120 usage anchor (reconcile): % (%)', sqlerrm, sqlstate;
        end;
      end if;
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
  if md5(v_src) = 'b3923b0bae57e812bb8375eea81f93e9' or current_setting('s120.rb') = 'off' then raise notice 'inventory_undo_v1 already original or no longer the s120 body (s132): skipped';
  else
    v_new := replace(v_src,
      replace($r$-- S120: undoing an app count (one that wrote an app_count audit row) writes the matching app_count_undo row, so inventory_qty_at_v1 sees the stock come back. NOT inside the guard below:
  -- when the row cannot be written the undo fails as a whole
  if v_have_m and exists (select 1 from public.inventory_audit_log a where a.entity_type = 'inventory_items' and a.entity_id = i.id and a.action = 'app_count' and a.after ->> 'movement_id' = m.id::text) then
    insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor)
    values ('inventory_items', i.id, 'app_count_undo', jsonb_build_object('qty_on_hand', m.quantity_after, 'movement_id', m.id),
            jsonb_build_object('qty_on_hand', m.quantity_before), coalesce(auth.uid()::text, 'app'));
  end if;
  -- S120: undoing a count that anchored the usage learning takes its interval out again (only the newest one, else the history stays); a problem here must never fail an undo
  if v_have_m and m.kind = 'reconcile' and i.movement_controlled_at is null then
    begin
      delete from public.inventory_usage_intervals x
       where x.item_id = i.id and x.anchor_at = m.created_at
         and not exists (select 1 from public.inventory_usage_intervals y where y.item_id = i.id and y.anchor_at > x.anchor_at);
      if found then
        perform public.s_inventory_usage_recompute_v1(i.id, now());
        perform public.s_inventory_refill_mark_sync_v1(i.id);
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
    v_new := replace(v_new, $r$'since', coalesce(w.prev_anchor_at, w.anchor_at),$r$, $f$'since', w.anchor_at,$f$);
    v_new := replace(v_new, $r$select i.id, i.name, x.anchor_at, x.prev_anchor_at, x.qty_prev, x.qty_now$r$, $f$select i.id, i.name, x.anchor_at, x.qty_prev, x.qty_now$f$);
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

create or replace function public.s_inventory_refill_mark_after_delete_v1()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.inventory_items i
     set last_refill_at = (select (public.s_inventory_received_date_v1(p.purchased_at, p.created_at)::timestamp at time zone 'Asia/Manila') from public.inventory_purchases p
                            where p.item_id = old.item_id order by public.s_inventory_received_date_v1(p.purchased_at, p.created_at) desc, p.created_at desc limit 1),
         last_refill_qty = (select p.qty from public.inventory_purchases p
                             where p.item_id = old.item_id order by public.s_inventory_received_date_v1(p.purchased_at, p.created_at) desc, p.created_at desc limit 1)
   where i.id = old.item_id and i.last_refill_at is not null;
  return null;
end $$;
revoke all on function public.s_inventory_refill_mark_after_delete_v1() from public, anon, authenticated, service_role;
drop function if exists public.s_inventory_refill_mark_sync_v1(uuid);
drop function if exists public.record_missed_refill_v1(uuid, numeric);
alter table public.inventory_usage_intervals drop column if exists refill_recorded_qty;

do $v$
begin
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)'::regprocedure) is distinct from (case when current_setting('s120.rb') = 'on' then '7cbb2ea861268b3fbe848c974e32b2f2' else (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)'::regprocedure) end)
     or (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.inventory_undo_v1(uuid,uuid)'::regprocedure) is distinct from (case when current_setting('s120.rb') = 'on' then 'b3923b0bae57e812bb8375eea81f93e9' else (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.inventory_undo_v1(uuid,uuid)'::regprocedure) end)
     or (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.get_inventory_usage_kpi_v1(uuid)'::regprocedure) is distinct from 'f0a2052c3ccc56673808d000ba21d189'
     or position('s_inventory_refill_mark_sync_v1' in (select prosrc from pg_proc where oid = 'public.s_inventory_refill_mark_after_delete_v1()'::regprocedure)) > 0
     or to_regprocedure('public.s_inventory_refill_mark_sync_v1(uuid)') is not null then
    raise exception 's120 rollback: a function is not back to its pre-release body' using errcode = '55000';
  end if;
end $v$;
select ok(current_setting('s120.rb') = 'off' or ((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)'::regprocedure) = '7cbb2ea861268b3fbe848c974e32b2f2'
      and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.inventory_undo_v1(uuid,uuid)'::regprocedure) = 'b3923b0bae57e812bb8375eea81f93e9'),
  'rollback: the count route and the undo are the md5 they were before the release (skipped once s132 replaced them)');
select ok((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.get_inventory_usage_kpi_v1(uuid)'::regprocedure) = 'f0a2052c3ccc56673808d000ba21d189'
      and position('inventory_purchases' in (select prosrc from pg_proc where oid = 'public.get_inventory_usage_kpi_v1(uuid)'::regprocedure)) > 0,
  'rollback: the KPI has its purchase condition back (md5 f0a2052c)');
select ok(to_regprocedure('public.record_missed_refill_v1(uuid,numeric)') is null
      and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'inventory_usage_intervals' and column_name = 'refill_recorded_qty'),
  'rollback: record_missed_refill_v1 and the column are gone');
select ok(position('s_inventory_refill_mark_sync_v1' in (select prosrc from pg_proc where oid = 'public.s_inventory_refill_mark_after_delete_v1()'::regprocedure)) = 0
      and to_regprocedure('public.s_inventory_refill_mark_sync_v1(uuid)') is null
      and (current_setting('s120.rb') = 'off' or position('app_count' in (select prosrc from pg_proc where oid = 'public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)'::regprocedure)) = 0)
      and (current_setting('s120.rb') = 'off' or position('app_count' in (select prosrc from pg_proc where oid = 'public.inventory_undo_v1(uuid,uuid)'::regprocedure)) = 0),
  'rollback: the purchase delete trigger function has its own body back, the helper is gone and the count route and undo no longer mention app_count');
select ok(exists (select 1 from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a8' and accepted and consumed = 6)
      and (select count(*) from public.inventory_usage_intervals where item_id = 'e1200010-0000-4000-8000-0000000000a5') = 2,
  'rollback: the intervals are not otherwise touched');

select * from finish();
rollback;
