-- Session 122 (lane L1 SQL): release s122_item_moves_20261122. move_inventory_stock_v1, move_inventory_usage_v1, undo_inventory_move_v1, get_inventory_item_moves_v1, the closed table
-- inventory_item_moves, inventory_usage_intervals.moved_between and the replay patches (record_inventory_usage, record_restock_v1) and learning patches (record_inventory_anchor_v1,
-- record_missed_refill_v1).
-- Synthetic fixtures only (uuids e1220010-..., property ...01, items "Zz S122 ...", users ...11 admin, ...12 cleaner, ...13 no staff profile); every lookup is scoped to them because a real backup holds real rows.
-- Refusals are tested by calling as the refused role. Hand-computed worked numbers (spec 4.2): Kitchen towel (KT) 14 and Bathroom tissue (BT) 5 counted 14 days ago, 7 moved KT -> BT,
-- KT 6 and BT 9 counted now with 4 stays between: KT consumed 14 + 0 - 7 - 6 = 1, moved_between -7, rate (0.06*10 + 1) / (10 + 4) = 0.1143; BT consumed 5 + 0 + 7 - 9 = 3, moved_between +7, rate (0*10 + 3) / 14 = 0.2143.
-- Without the flow KT would read 14 - 6 = 8 (rate 0.6143) and BT 5 - 9 = -4 (rejected "unrecorded restock"). Test 11 of the spec (lock order with dblink) is not run here.
-- Everything rolls back.
begin;
select plan(58);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
do $sr$ begin if not (select rolbypassrls from pg_roles where rolname = 'service_role') then alter role service_role bypassrls; end if; end $sr$;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid), public.current_staff_active(text[]) to authenticated, service_role;
grant execute on function public.admin_require(text, uuid) to authenticated;
grant execute on function public.manila_today() to authenticated, anon;

create function pg_temp.anc(p_item uuid, p_q numeric, p_ago interval) returns jsonb language sql as
$$ select public.record_inventory_anchor_v1($1, $2, now() - $3, 'count') $$;

create temp table _r(k text primary key, v jsonb);
grant all on _r to authenticated, service_role;

-- fixtures -------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values ('e1220010-0000-4000-8000-000000000001', 'Synthetic S122', true), ('e1220010-0000-4000-8000-000000000002', 'Synthetic S122 other', true);
insert into auth.users(id) values ('e1220010-0000-4000-8000-000000000011'), ('e1220010-0000-4000-8000-000000000012'), ('e1220010-0000-4000-8000-000000000013');
update auth.users set raw_app_meta_data = jsonb_build_object('display_name', 'Zz S122 Admin') where id = 'e1220010-0000-4000-8000-000000000011';
insert into public.staff_access_profiles(user_id, role) values ('e1220010-0000-4000-8000-000000000011', 'admin'), ('e1220010-0000-4000-8000-000000000012', 'cleaner');
insert into public.staff_property_access(user_id, property_id) values ('e1220010-0000-4000-8000-000000000011', 'e1220010-0000-4000-8000-000000000001'), ('e1220010-0000-4000-8000-000000000011', 'e1220010-0000-4000-8000-000000000002'), ('e1220010-0000-4000-8000-000000000012', 'e1220010-0000-4000-8000-000000000001');
-- 101 KT 14 and 102 BT 5 (the worked example); 103/104 replay pair; 105 inactive, 106 not consumable, 107 controlled, 108 roll, 109 other property, 110 spare source
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, consumption_per_booking, usage_baseline_per_turnover) values
  ('e1220010-0000-4000-8000-000000000101', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 Kitchen towel',   'Other', 'pc',   14, true,  true,  0.06, 0.06),
  ('e1220010-0000-4000-8000-000000000102', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 Bathroom tissue', 'Other', 'pc',   5,  true,  true,  0.10, 0),
  ('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 K1',              'Other', 'pc',   10, true,  true,  1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000104', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 K2',              'Other', 'pc',   4,  true,  true,  1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000105', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 inactive',        'Other', 'pc',   5,  true,  false, 1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000106', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 not consumable',  'Other', 'pc',   5,  false, true,  1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000108', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 roll',            'Other', 'roll', 5,  true,  true,  1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000109', 'e1220010-0000-4000-8000-000000000002', 'Zz S122 other property',  'Other', 'pc',   5,  true,  true,  1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000110', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 spare',           'Other', 'pc',   5,  true,  true,  1.00, 1.0),
  -- undo nets to 0: 111 / 112
  ('e1220010-0000-4000-8000-000000000111', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 U1', 'Other', 'pc', 10, true, true, 1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000112', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 U2', 'Other', 'pc', 10, true, true, 1.00, 1.0),
  -- undo refused: 113 / 114
  ('e1220010-0000-4000-8000-000000000113', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 N1', 'Other', 'pc', 10, true, true, 1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000114', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 N2', 'Other', 'pc', 3,  true, true, 1.00, 1.0),
  -- missed refill: 115 (counted 10 then 20), 116 gives 2
  ('e1220010-0000-4000-8000-000000000115', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 R1', 'Other', 'pc', 10, true, true, 1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000116', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 R2', 'Other', 'pc', 8,  true, true, 1.00, 1.0),
  -- usage moves: 117 F1 (5), 118 F2 (12), 119 F3 (1), 120 F4 (9)
  ('e1220010-0000-4000-8000-000000000117', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 F1', 'Other', 'pc', 5,  true, true, 1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000118', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 F2', 'Other', 'pc', 12, true, true, 1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000119', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 F3', 'Other', 'pc', 1,  true, true, 1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000120', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 F4', 'Other', 'pc', 9,  true, true, 1.00, 1.0),
  -- restock and direct replay: 121 / 122 and 123 / 124
  ('e1220010-0000-4000-8000-000000000121', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 G1', 'Other', 'pc', 10, true, true, 1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000122', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 G2', 'Other', 'pc', 10, true, true, 1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000123', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 H1', 'Other', 'pc', 10, true, true, 1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000124', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 H2', 'Other', 'pc', 10, true, true, 1.00, 1.0),
  -- chain: 125 J1, 126 J2, 127 J3
  ('e1220010-0000-4000-8000-000000000125', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 J1', 'Other', 'pc', 10, true, true, 1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000126', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 J2', 'Other', 'pc', 10, true, true, 1.00, 1.0),
  ('e1220010-0000-4000-8000-000000000127', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 J3', 'Other', 'pc', 10, true, true, 1.00, 1.0),
  -- item-less usage row target
  ('e1220010-0000-4000-8000-000000000128', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 L1', 'Other', 'pc', 10, true, true, 1.00, 1.0);
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, units_per_purchase, movement_controlled_at, baseline_reviewed_by, usage_baseline_per_turnover) values
  ('e1220010-0000-4000-8000-000000000107', 'e1220010-0000-4000-8000-000000000001', 'Zz S122 controlled', 'Other', 'pc', 5, true, 1, timestamptz '2026-11-01 08:00+08', 'e1220010-0000-4000-8000-000000000011', 1.0);
-- four stays inside every 14-day interval (the first anchors are 14 days ago): turnovers 12, 9, 6 and 3 days ago
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type)
select 'e1220010-0000-4000-8000-000000000001', 'zz-s122-' || d, 'Fixture', now() - make_interval(days => d), 'turnover' from (values (12), (9), (6), (3)) v(d);

-- first anchors: physical counts 14 days ago
select pg_temp.anc(a, q, interval '14 days') from (values
  ('e1220010-0000-4000-8000-000000000101'::uuid, 14), ('e1220010-0000-4000-8000-000000000102', 5), ('e1220010-0000-4000-8000-000000000111', 10), ('e1220010-0000-4000-8000-000000000112', 10), ('e1220010-0000-4000-8000-000000000115', 10), ('e1220010-0000-4000-8000-000000000117', 10)) v(a, q);

-- 1-6. shape and grants --------------------------------------------------------------------------------------------------------------------
select ok(to_regclass('public.inventory_item_moves') is not null and (select relrowsecurity from pg_class where oid = 'public.inventory_item_moves'::regclass)
      and not has_table_privilege('anon', 'public.inventory_item_moves', 'select, insert, update, delete')
      and not has_table_privilege('authenticated', 'public.inventory_item_moves', 'select, insert, update, delete')
      and not has_table_privilege('service_role', 'public.inventory_item_moves', 'select, insert, update, delete'),
  'inventory_item_moves exists, row level security is on and no API role has a grant');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000011"}';
select throws_ok($$select count(*) from public.inventory_item_moves$$, '42501', null, 'a signed-in admin cannot read inventory_item_moves directly');
reset role;
select ok(has_function_privilege('authenticated', 'public.move_inventory_stock_v1(uuid,uuid,numeric,text,text)', 'execute')
      and has_function_privilege('authenticated', 'public.move_inventory_usage_v1(uuid,uuid,text)', 'execute')
      and has_function_privilege('authenticated', 'public.undo_inventory_move_v1(uuid,text)', 'execute')
      and has_function_privilege('authenticated', 'public.get_inventory_item_moves_v1(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.move_inventory_stock_v1(uuid,uuid,numeric,text,text)', 'execute')
      and not has_function_privilege('anon', 'public.move_inventory_usage_v1(uuid,uuid,text)', 'execute')
      and not has_function_privilege('anon', 'public.undo_inventory_move_v1(uuid,text)', 'execute')
      and not has_function_privilege('anon', 'public.get_inventory_item_moves_v1(uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.move_inventory_stock_v1(uuid,uuid,numeric,text,text)', 'execute')
      and not has_function_privilege('service_role', 'public.move_inventory_usage_v1(uuid,uuid,text)', 'execute')
      and not has_function_privilege('service_role', 'public.undo_inventory_move_v1(uuid,text)', 'execute')
      and not has_function_privilege('service_role', 'public.get_inventory_item_moves_v1(uuid)', 'execute'),
  'the four functions: execute for signed-in users only (not anon, not service_role)');
select ok((select count(*) = 4 and bool_and(prosecdef and proconfig = array['search_path=""']) from pg_proc
            where oid in ('public.move_inventory_stock_v1(uuid,uuid,numeric,text,text)'::regprocedure, 'public.move_inventory_usage_v1(uuid,uuid,text)'::regprocedure,
                          'public.undo_inventory_move_v1(uuid,text)'::regprocedure, 'public.get_inventory_item_moves_v1(uuid)'::regprocedure)),
  'the four functions are security definer with an empty search_path');
select ok(not has_function_privilege('authenticated', 'public.s_inventory_move_check_v1(public.inventory_items,public.inventory_items)', 'execute')
      and not has_function_privilege('authenticated', 'public.s_inventory_move_json_v1(uuid,boolean)', 'execute')
      and not has_function_privilege('anon', 'public.s_inventory_move_json_v1(uuid,boolean)', 'execute'), 'the two internal helpers have no client grant');
select ok(exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'inventory_usage_intervals' and column_name = 'moved_between' and data_type = 'numeric' and is_nullable = 'NO' and column_default = '0')
      and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'inventory_usage' and column_name = 'moved_from_item_id' and data_type = 'uuid' and is_nullable = 'YES')
      and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'inventory_usage' and column_name = 'moved_at' and data_type = 'timestamp with time zone' and is_nullable = 'YES'),
  'the three new columns have the contract types and defaults');
select ok(position('moved_between' in (select prosrc from pg_proc where oid = 'public.record_inventory_anchor_v1(uuid,numeric,timestamptz,text)'::regprocedure)) > 0
      and position('moved_between' in (select prosrc from pg_proc where oid = 'public.record_missed_refill_v1(uuid,numeric)'::regprocedure)) > 0
      and position('moved_from_item_id' in (select prosrc from pg_proc where oid = 'public.record_inventory_usage(uuid,date,text,text,jsonb)'::regprocedure)) > 0
      and position('moved_from_item_id' in (select prosrc from pg_proc where oid = 'public.record_restock_v1(uuid,date,text,text,jsonb,jsonb,jsonb)'::regprocedure)) > 0
      and not has_function_privilege('authenticated', 'public.record_inventory_anchor_v1(uuid,numeric,timestamptz,text)', 'execute')
      and has_function_privilege('authenticated', 'public.record_missed_refill_v1(uuid,numeric)', 'execute') and not has_function_privilege('service_role', 'public.record_missed_refill_v1(uuid,numeric)', 'execute')
      and has_function_privilege('authenticated', 'public.record_inventory_usage(uuid,date,text,text,jsonb)', 'execute') and not has_function_privilege('anon', 'public.record_inventory_usage(uuid,date,text,text,jsonb)', 'execute')
      and has_function_privilege('authenticated', 'public.record_restock_v1(uuid,date,text,text,jsonb,jsonb,jsonb)', 'execute') and not has_function_privilege('anon', 'public.record_restock_v1(uuid,date,text,text,jsonb,jsonb,jsonb)', 'execute'),
  'the four patched bodies carry their blocks and their grants are as before');

-- 7-10. the gate: refused callers get 42501 and nothing is written ------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000012"}';
select throws_ok($$select public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', 1, null, 'zz-s122-gate-0001')$$, '42501', null, 'a cleaner (no manage_inventory) cannot move stock');
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000013"}';
select throws_ok($$select public.get_inventory_item_moves_v1('e1220010-0000-4000-8000-000000000103')$$, '42501', null, 'a user with no staff profile cannot read the moves of an item through the admin read');
select throws_ok($$select public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', 1, null, 'zz-s122-gate-0002')$$, '42501', null, 'a user with no staff profile cannot move stock');
reset role;
select is((select count(*)::int from public.inventory_item_moves where property_id = 'e1220010-0000-4000-8000-000000000001'), 0, 'the refused calls wrote no move row');

-- 11-20. stock move 7 KT -> BT, as the admin -----------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000011"}';
insert into _r select 'mv', public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000101', 'e1220010-0000-4000-8000-000000000102', 7, 'zz mix-up', 'zz-s122-key-0001');
reset role;
select ok((select (v ->> 'ok')::boolean and v ->> 'moveId' is not null and (v #>> '{from,before}')::numeric = 14 and (v #>> '{from,after}')::numeric = 7
                  and (v #>> '{to,before}')::numeric = 5 and (v #>> '{to,after}')::numeric = 12 and (v ->> 'qty')::numeric = 7 and v ->> 'replayed' is null from _r where k = 'mv'),
  'move 7 Kitchen towel -> Bathroom tissue: the result carries both names and the shelves 14 -> 7 and 5 -> 12');
select is((select array[qty_on_hand]::numeric[] from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000101') || (select array[qty_on_hand]::numeric[] from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000102'),
  array[7, 12]::numeric[], 'the shelves are 7 and 12');
select is((select count(*)::int from public.inventory_item_moves where from_item_id = 'e1220010-0000-4000-8000-000000000101' and to_item_id = 'e1220010-0000-4000-8000-000000000102' and kind = 'stock' and qty = 7 and usage_id is null and undo_of is null and note = 'zz mix-up'
             and before_from = 14 and after_from = 7 and before_to = 5 and after_to = 12 and actor_user_id = 'e1220010-0000-4000-8000-000000000011'), 1, 'one move row with the four shelf figures, the note and the actor');
select ok((select count(*) = 2 and bool_and(jsonb_typeof(a.before -> 'qty_on_hand') = 'number' and jsonb_typeof(a.after -> 'qty_on_hand') = 'number' and a.actor = 'e1220010-0000-4000-8000-000000000011' and a.after ->> 'move_id' is not null)
             from public.inventory_audit_log a where a.action in ('stock_moved_out', 'stock_moved_in') and a.entity_id in ('e1220010-0000-4000-8000-000000000101', 'e1220010-0000-4000-8000-000000000102'))
      and (select (a.before ->> 'qty_on_hand')::numeric = 14 and (a.after ->> 'qty_on_hand')::numeric = 7 and a.after ->> 'other_item_name' = 'Zz S122 Bathroom tissue'
             from public.inventory_audit_log a where a.action = 'stock_moved_out' and a.entity_id = 'e1220010-0000-4000-8000-000000000101')
      and (select (a.before ->> 'qty_on_hand')::numeric = 5 and (a.after ->> 'qty_on_hand')::numeric = 12 from public.inventory_audit_log a where a.action = 'stock_moved_in' and a.entity_id = 'e1220010-0000-4000-8000-000000000102'),
  'two audit rows with numeric before / after qty_on_hand, the actor, the move id and the other item name');
select is(public.inventory_qty_at_v1('e1220010-0000-4000-8000-000000000101', now() - interval '1 day')::int::text || public.inventory_qty_at_v1('e1220010-0000-4000-8000-000000000102', now() - interval '1 day')::int::text, '145',
  'inventory_qty_at_v1 one day ago reads the physical figures 14 and 5 after a stock move (the audit rows are subtracted)');

-- refusals, each writing nothing --------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000011"}';
insert into _r select 'r1',  public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', 11, null, 'zz-s122-ref-0001');         -- 10 on hand
insert into _r select 'r2',  public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000103', 1, null, 'zz-s122-ref-0002');
insert into _r select 'r3',  public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000108', 1, null, 'zz-s122-ref-0003');         -- pc -> roll
insert into _r select 'r4',  public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000105', 1, null, 'zz-s122-ref-0004');         -- to inactive
insert into _r select 'r5',  public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000106', 'e1220010-0000-4000-8000-000000000103', 1, null, 'zz-s122-ref-0005');         -- from not consumable
insert into _r select 'r6',  public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000107', 1, null, 'zz-s122-ref-0006');         -- to movement controlled
insert into _r select 'r7',  public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', 0, null, 'zz-s122-ref-0007');
insert into _r select 'r8',  public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', -1, null, 'zz-s122-ref-0008');
insert into _r select 'r9',  public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', 1.234, null, 'zz-s122-ref-0009');
insert into _r select 'r10', public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', 'NaN'::numeric, null, 'zz-s122-ref-0010');
insert into _r select 'r11', public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000109', 1, null, 'zz-s122-ref-0011');         -- other property
insert into _r select 'r12', public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', 1, null, 'short');
insert into _r select 'r13', public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-00000000ffff', 1, null, 'zz-s122-ref-0013');
insert into _r select 'r14', public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', null, null, 'zz-s122-ref-0014');
reset role;
select is((select string_agg(v ->> 'reason', ',' order by substr(k, 2)::int) from _r where k ~ '^r[0-9]+$'),
  'not_enough,same_item,unit_mismatch,inactive,not_consumable,movement_controlled,bad_qty,bad_qty,bad_qty,bad_qty,other_property,bad_key,item_not_found,bad_qty',
  'every refusal answers its reason: not_enough, same_item, unit_mismatch, inactive, not_consumable, movement_controlled, bad_qty (0, -1, 1.234, NaN), other_property, bad_key, item_not_found, null qty');
select ok((select (v ->> 'on_hand')::numeric = 10 from _r where k = 'r1') and (select v ->> 'item' = 'to' from _r where k = 'r4') and (select v ->> 'item' = 'from' from _r where k = 'r5')
      and (select v ->> 'item' = 'to' from _r where k = 'r6') and (select v ->> 'fromUnit' = 'pc' and v ->> 'toUnit' = 'roll' from _r where k = 'r3'),
  'not_enough carries on_hand, the item checks name the side, unit_mismatch carries both units');
select ok((select count(*) = 0 from public.inventory_item_moves where from_item_id in ('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', 'e1220010-0000-4000-8000-000000000105', 'e1220010-0000-4000-8000-000000000106', 'e1220010-0000-4000-8000-000000000107', 'e1220010-0000-4000-8000-000000000108', 'e1220010-0000-4000-8000-000000000109') or to_item_id in ('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', 'e1220010-0000-4000-8000-000000000105', 'e1220010-0000-4000-8000-000000000106', 'e1220010-0000-4000-8000-000000000107', 'e1220010-0000-4000-8000-000000000108', 'e1220010-0000-4000-8000-000000000109'))
      and (select sum(qty_on_hand) = 10 + 4 + 5 + 5 + 5 + 5 + 5 from public.inventory_items where id in ('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', 'e1220010-0000-4000-8000-000000000105', 'e1220010-0000-4000-8000-000000000106', 'e1220010-0000-4000-8000-000000000107', 'e1220010-0000-4000-8000-000000000108', 'e1220010-0000-4000-8000-000000000109'))
      and (select count(*) = 0 from public.inventory_audit_log where entity_id in ('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', 'e1220010-0000-4000-8000-000000000105', 'e1220010-0000-4000-8000-000000000106', 'e1220010-0000-4000-8000-000000000107', 'e1220010-0000-4000-8000-000000000108', 'e1220010-0000-4000-8000-000000000109')),
  'the refusals wrote no move row, no audit row and changed no shelf');

-- replay and key conflict (pair 103 / 104) ---------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000011"}';
insert into _r select 'k1', public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', 4, null, 'zz-s122-key-0002');
insert into _r select 'k2', public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', 4, 'another note', 'zz-s122-key-0002');
reset role;
update public.inventory_items set qty_on_hand = 0 where id = 'e1220010-0000-4000-8000-000000000103';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000011"}';
insert into _r select 'k3', public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', 4, null, 'zz-s122-key-0002');
insert into _r select 'k4', public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000103', 'e1220010-0000-4000-8000-000000000104', 3, null, 'zz-s122-key-0002');
insert into _r select 'k5', public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000104', 'e1220010-0000-4000-8000-000000000103', 4, null, 'zz-s122-key-0002');
reset role;
select ok((select (v ->> 'ok')::boolean and v ->> 'replayed' is null from _r where k = 'k1')
      and (select (v ->> 'ok')::boolean and (v ->> 'replayed')::boolean and v ->> 'moveId' = (select v ->> 'moveId' from _r where k = 'k1') from _r where k = 'k2')
      and (select (v ->> 'replayed')::boolean and v ->> 'moveId' = (select v ->> 'moveId' from _r where k = 'k1') from _r where k = 'k3')
      and (select count(*) = 1 from public.inventory_item_moves where idempotency_key = 'zz-s122-key-0002'),
  'the same key with the same arguments twice: one row, the second answer is replayed with the first move id (a changed note is ignored, a replay after the shelf changed still replays)');
select ok((select v ->> 'reason' = 'key_conflict' and (v ->> 'ok')::boolean is false from _r where k = 'k4') and (select v ->> 'reason' = 'key_conflict' from _r where k = 'k5')
      and (select count(*) = 1 from public.inventory_item_moves where idempotency_key = 'zz-s122-key-0002'),
  'the same key with another quantity, or another direction, answers key_conflict and writes nothing');
update public.inventory_items set qty_on_hand = 6 where id = 'e1220010-0000-4000-8000-000000000103';
select is((select (qty_on_hand = 6)::text from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000103') || (select qty_on_hand::int::text from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000104'), 'true8', 'the replays moved nothing: 104 holds 4 + 4');

-- 21-30. the interval maths of the worked example ------------------------------------------------------------------------------------------------
select pg_temp.anc('e1220010-0000-4000-8000-000000000101', 6, interval '0 days');
select pg_temp.anc('e1220010-0000-4000-8000-000000000102', 9, interval '0 days');
select is((select consumed || '|' || moved_between || '|' || received_between || '|' || accepted::text || '|' || turnovers from public.inventory_usage_intervals where item_id = 'e1220010-0000-4000-8000-000000000101' and prev_anchor_at is not null),
  '1|-7|0|true|4', 'Kitchen towel: consumed 14 + 0 - 7 - 6 = 1, moved_between -7, accepted over 4 stays');
select is((select consumed || '|' || moved_between || '|' || received_between || '|' || accepted::text || '|' || turnovers from public.inventory_usage_intervals where item_id = 'e1220010-0000-4000-8000-000000000102' and prev_anchor_at is not null),
  '3|7|0|true|4', 'Bathroom tissue: consumed 5 + 0 + 7 - 9 = 3, moved_between +7, accepted (not rejected as an unrecorded restock)');
select is((select consumption_per_booking::text from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000101') || '|' || (select consumption_per_booking::text from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000102'),
  '0.1143|0.2143', 'the learned rates are 0.1143 (KT) and 0.2143 (BT)');

-- 31-36. undo: a moved-and-undone pair nets to 0 in the interval; the undo is its own row -------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000011"}';
insert into _r select 'u1', public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000111', 'e1220010-0000-4000-8000-000000000112', 3, null, 'zz-s122-key-0011');
insert into _r select 'u2', public.undo_inventory_move_v1((select (v ->> 'moveId')::uuid from _r where k = 'u1'), 'zz-s122-undo-0011');
insert into _r select 'u3', public.undo_inventory_move_v1((select (v ->> 'moveId')::uuid from _r where k = 'u1'), 'zz-s122-undo-0012');   -- a second undo with another key
insert into _r select 'u4', public.undo_inventory_move_v1((select (v ->> 'moveId')::uuid from _r where k = 'u1'), 'zz-s122-undo-0011');   -- the same key again
insert into _r select 'u5', public.undo_inventory_move_v1((select (v ->> 'moveId')::uuid from _r where k = 'u2'), 'zz-s122-undo-0013');   -- an undo cannot be undone
insert into _r select 'u6', public.undo_inventory_move_v1((select (v ->> 'moveId')::uuid from _r where k = 'u1'), 'zz-s122-key-0011');    -- a key of another move
reset role;
select ok((select (v ->> 'ok')::boolean and (v ->> 'undoOf') = (select v ->> 'moveId' from _r where k = 'u1') and (v #>> '{from,id}') = 'e1220010-0000-4000-8000-000000000112' and (v #>> '{to,id}') = 'e1220010-0000-4000-8000-000000000111' and (v ->> 'qty')::numeric = 3 from _r where k = 'u2')
      and (select qty_on_hand = 10 from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000111') and (select qty_on_hand = 10 from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000112'),
  'undo: a new move row from -> to swapped with undo_of, and both shelves are back at 10');
select ok((select (v ->> 'ok')::boolean and (v ->> 'replayed')::boolean and v ->> 'reason' = 'already_undone' from _r where k = 'u3')
      and (select (v ->> 'replayed')::boolean and v ->> 'moveId' = (select v ->> 'moveId' from _r where k = 'u2') from _r where k = 'u4')
      and (select v ->> 'reason' = 'not_undoable' from _r where k = 'u5') and (select v ->> 'reason' = 'key_conflict' from _r where k = 'u6')
      and (select count(*) = 2 from public.inventory_item_moves where from_item_id in ('e1220010-0000-4000-8000-000000000111', 'e1220010-0000-4000-8000-000000000112')),
  'a double undo answers already_undone, the same key replays, an undo is not undoable, a key of another move is key_conflict; two rows only');
select pg_temp.anc('e1220010-0000-4000-8000-000000000111', 6, interval '0 days');
select pg_temp.anc('e1220010-0000-4000-8000-000000000112', 8, interval '0 days');
select is((select moved_between::text || '|' || consumed::text || '|' || accepted::text from public.inventory_usage_intervals where item_id = 'e1220010-0000-4000-8000-000000000111' and prev_anchor_at is not null)
       || ',' || (select moved_between::text || '|' || consumed::text || '|' || accepted::text from public.inventory_usage_intervals where item_id = 'e1220010-0000-4000-8000-000000000112' and prev_anchor_at is not null),
  '0|4|true,0|2|true', 'a moved-and-undone pair gives moved_between 0 on both sides: consumed 10 - 6 = 4 and 10 - 8 = 2');

-- 37-38. undo refused when the destination has used the units ---------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000011"}';
insert into _r select 'n1', public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000113', 'e1220010-0000-4000-8000-000000000114', 7, null, 'zz-s122-key-0013');
reset role;
update public.inventory_items set qty_on_hand = 4 where id = 'e1220010-0000-4000-8000-000000000114';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000011"}';
insert into _r select 'n2', public.undo_inventory_move_v1((select (v ->> 'moveId')::uuid from _r where k = 'n1'), 'zz-s122-undo-0021');
reset role;
select ok((select v ->> 'reason' = 'not_enough' and (v ->> 'on_hand')::numeric = 4 from _r where k = 'n2')
      and (select count(*) = 1 from public.inventory_item_moves where from_item_id in ('e1220010-0000-4000-8000-000000000113', 'e1220010-0000-4000-8000-000000000114') or to_item_id in ('e1220010-0000-4000-8000-000000000113', 'e1220010-0000-4000-8000-000000000114'))
      and (select qty_on_hand = 3 and (select qty_on_hand from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000114') = 4 from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000113'),
  'undo of the 7 after the destination dropped to 4 answers not_enough (on_hand 4) and writes nothing');

-- 39-43. record_missed_refill_v1 includes moved_between ------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000011"}';
insert into _r select 'e1', public.move_inventory_stock_v1('e1220010-0000-4000-8000-000000000116', 'e1220010-0000-4000-8000-000000000115', 2, null, 'zz-s122-key-0015');
reset role;
select pg_temp.anc('e1220010-0000-4000-8000-000000000115', 20, interval '0 days');
select is((select moved_between::text || '|' || consumed::text || '|' || accepted::text || '|' || reject_reason from public.inventory_usage_intervals where item_id = 'e1220010-0000-4000-8000-000000000115' and prev_anchor_at is not null),
  '2|-8|false|unrecorded restock', 'R1: counted 10, 2 moved in, counted 20: consumed 10 + 0 + 2 - 20 = -8, rejected as an unrecorded restock with moved_between 2');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000011"}';
insert into _r select 'e2', public.record_missed_refill_v1('e1220010-0000-4000-8000-000000000115', 7);
insert into _r select 'e3', public.record_missed_refill_v1('e1220010-0000-4000-8000-000000000115', 9);
reset role;
select ok((select v ->> 'reason' = 'too_small' and (v ->> 'minimum')::numeric = 8 from _r where k = 'e2'),
  'a refill of 7 is too small and the minimum is 20 - 10 - 0 - 2 = 8 (the minimum includes moved_between)');
select ok((select (v ->> 'ok')::boolean and (v ->> 'accepted')::boolean and (v ->> 'consumed')::numeric = 1 and (v ->> 'received')::numeric = 9 from _r where k = 'e3')
      and (select consumed = 1 and moved_between = 2 and received_between = 9 and accepted and refill_recorded_qty = 9 from public.inventory_usage_intervals where item_id = 'e1220010-0000-4000-8000-000000000115' and prev_anchor_at is not null),
  'a refill of 9: consumed 10 + 0 + 2 + 9 - 20 = 1, accepted, moved_between stays 2');

-- 44-56. usage moves ------------------------------------------------------------------------------------------------------------------------------
insert into public.inventory_usage(id, item_id, used_qty, session_date, logged_by, notes, property_id, created_at) values
  ('e1220010-0000-4000-8000-000000000201', 'e1220010-0000-4000-8000-000000000117', 2, current_date, 'zz', 'Restock zz-s122', 'e1220010-0000-4000-8000-000000000001', now() - interval '2 hours'),
  ('e1220010-0000-4000-8000-000000000202', 'e1220010-0000-4000-8000-000000000119', 2, current_date, 'zz', 'Restock zz-s122', 'e1220010-0000-4000-8000-000000000001', now() - interval '2 hours'),
  ('e1220010-0000-4000-8000-000000000203', 'e1220010-0000-4000-8000-000000000120', 3, current_date, 'zz', 'Restock zz-s122', 'e1220010-0000-4000-8000-000000000001', now()),
  ('e1220010-0000-4000-8000-0000000002f0', 'e1220010-0000-4000-8000-000000000128', 0, current_date, 'zz', 'Restock zz-s122', 'e1220010-0000-4000-8000-000000000001', now());
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000011"}';
insert into _r select 'f1', public.move_inventory_usage_v1('e1220010-0000-4000-8000-000000000201', 'e1220010-0000-4000-8000-000000000118', 'zz-s122-key-0021');
insert into _r select 'f2', public.move_inventory_usage_v1('e1220010-0000-4000-8000-000000000201', 'e1220010-0000-4000-8000-000000000118', 'zz-s122-key-0021');                -- replay (the row already sits under 118)
insert into _r select 'f3', public.move_inventory_usage_v1('e1220010-0000-4000-8000-000000000201', 'e1220010-0000-4000-8000-000000000118', 'zz-s122-key-0022');                -- same item now
insert into _r select 'f4', public.move_inventory_usage_v1('e1220010-0000-4000-8000-00000000fffe', 'e1220010-0000-4000-8000-000000000118', 'zz-s122-key-0023');
insert into _r select 'f6', public.move_inventory_usage_v1('e1220010-0000-4000-8000-000000000202', 'e1220010-0000-4000-8000-000000000119', 'zz-s122-key-0025');                -- same item (202 sits under 119)
insert into _r select 'f7', public.move_inventory_usage_v1('e1220010-0000-4000-8000-000000000203', 'e1220010-0000-4000-8000-000000000119', 'zz-s122-key-0026');                -- 3 units from a shelf of 1: not_enough
insert into _r select 'f8', public.move_inventory_usage_v1('e1220010-0000-4000-8000-000000000203', 'e1220010-0000-4000-8000-000000000118', 'zz-s122-key-0021');                -- the key of another move
insert into _r select 'f9', public.move_inventory_usage_v1('e1220010-0000-4000-8000-000000000203', 'e1220010-0000-4000-8000-000000000118', 'zz-s122-key-0027');                -- a row made just now is movable (no too_recent)
insert into _r select 'f10', public.move_inventory_usage_v1('e1220010-0000-4000-8000-0000000002f0', 'e1220010-0000-4000-8000-000000000124', 'zz-s122-key-0028');                -- used_qty 0: bad_qty, not a 23514
reset role;
select is((select v ->> 'reason' from _r where k = 'f10'), 'bad_qty', 'usage move of a row with used_qty 0 is refused as bad_qty');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000012"}';
select throws_ok($$select public.move_inventory_usage_v1('e1220010-0000-4000-8000-000000000202', 'e1220010-0000-4000-8000-000000000118', 'zz-s122-gate-0003')$$, '42501', null, 'a cleaner cannot move a usage row');
select throws_ok($$select public.undo_inventory_move_v1((select (v ->> 'moveId')::uuid from pg_temp._r where k = 'mv'), 'zz-s122-gate-0004')$$, '42501', null, 'a cleaner cannot undo a move');
reset role;
select ok((select (v ->> 'ok')::boolean and v ->> 'kind' = 'usage' and v ->> 'usageId' = 'e1220010-0000-4000-8000-000000000201' and (v #>> '{from,before}')::numeric = 5 and (v #>> '{from,after}')::numeric = 7
                  and (v #>> '{to,before}')::numeric = 12 and (v #>> '{to,after}')::numeric = 10 from _r where k = 'f1')
      and (select item_id = 'e1220010-0000-4000-8000-000000000118' and moved_from_item_id = 'e1220010-0000-4000-8000-000000000117' and moved_at is not null from public.inventory_usage where id = 'e1220010-0000-4000-8000-000000000201')
      and (select qty_on_hand = 7 from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000117'),
  'usage move: the row is under F2 with moved_from F1 and moved_at, the shelves go F1 5 -> 7 and F2 12 -> 10 (the result carries both figures)');
select ok((select count(*) = 1 from public.inventory_item_moves where usage_id = 'e1220010-0000-4000-8000-000000000201' and kind = 'usage' and from_item_id = 'e1220010-0000-4000-8000-000000000117' and to_item_id = 'e1220010-0000-4000-8000-000000000118' and qty = 2 and before_from = 5 and after_from = 7 and before_to = 12 and after_to = 10 and undo_of is null),
  'one usage move row with the shelf figures');
select ok((select (v ->> 'replayed')::boolean and v ->> 'moveId' = (select v ->> 'moveId' from _r where k = 'f1') from _r where k = 'f2')
      and (select v ->> 'reason' = 'same_item' from _r where k = 'f3') and (select v ->> 'reason' = 'usage_not_found' from _r where k = 'f4')
      and (select v ->> 'reason' = 'same_item' from _r where k = 'f6') and (select v ->> 'reason' = 'key_conflict' from _r where k = 'f8'),
  'usage move: a replay returns the first result, then same_item, usage_not_found, same_item and key_conflict');
select ok((select v ->> 'reason' = 'not_enough' and (v ->> 'on_hand')::numeric = 1 from _r where k = 'f7') and (select qty_on_hand = 1 from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000119'),
  'a destination that cannot give the units up answers not_enough (on_hand 1) and nothing moved');
select ok((select (v ->> 'ok')::boolean from _r where k = 'f9') and (select item_id = 'e1220010-0000-4000-8000-000000000118' and created_at >= now() from public.inventory_usage where id = 'e1220010-0000-4000-8000-000000000203')
      and (select qty_on_hand = 12 and (select qty_on_hand from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000118') = 7 from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000120'),
  'a usage row made in this very transaction can be moved (the 15-minute rule is gone): F4 9 -> 12, F2 10 -> 7');
select ok((select count(*) = 4 from public.inventory_audit_log where action = 'usage_moved' and entity_id in ('e1220010-0000-4000-8000-000000000117', 'e1220010-0000-4000-8000-000000000118', 'e1220010-0000-4000-8000-000000000120') and entity_id <> 'e1220010-0000-4000-8000-000000000119')
      and (select bool_and(not (a.before ? 'qty_on_hand') and not (a.after ? 'qty_on_hand') and a.before ? 'shelf_before' and a.after ? 'shelf_after' and a.after ->> 'move_id' is not null)
             from public.inventory_audit_log a where a.action = 'usage_moved' and a.entity_id in ('e1220010-0000-4000-8000-000000000117', 'e1220010-0000-4000-8000-000000000118', 'e1220010-0000-4000-8000-000000000120')),
  'usage_moved audit rows carry shelf_before / shelf_after and never qty_on_hand');
-- the past stock of both items is exact with no double count (T = 3 hours ago, before the row was logged)
select is(public.inventory_qty_at_v1('e1220010-0000-4000-8000-000000000117', now() - interval '3 hours')::int::text || '|' || public.inventory_qty_at_v1('e1220010-0000-4000-8000-000000000118', now() - interval '3 hours')::int::text, '7|12',
  'inventory_qty_at_v1 before the mis-logged row reads 7 (F1) and 12 (F2): the re-pointed row counts once, under F2, and the usage_moved rows add nothing');
-- the next interval does not change: usage rows are not read
select pg_temp.anc('e1220010-0000-4000-8000-000000000117', 6, interval '0 days');
select is((select moved_between::text || '|' || consumed::text || '|' || received_between::text from public.inventory_usage_intervals where item_id = 'e1220010-0000-4000-8000-000000000117' and prev_anchor_at is not null), '0|4|0',
  'a usage move never enters moved_between: counted 10 then 6 gives consumed 4, moved_between 0');

-- 57-62. the replay patches: a retry after a re-point writes no new usage row ---------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000012"}';
insert into _r select 'g1', public.record_restock_v1('e1220010-0000-4000-8000-000000000001', current_date, 'Zz cleaner', null, '[{"item_id":"e1220010-0000-4000-8000-000000000121","used_qty":1,"usage_key":"zz-s122-rk-0001"}]'::jsonb, '{}'::jsonb, '[]'::jsonb);
insert into _r select 'h1', public.record_inventory_usage('e1220010-0000-4000-8000-000000000001', current_date, 'Zz cleaner', null, '[{"item_id":"e1220010-0000-4000-8000-000000000123","used_qty":1,"usage_key":"zz-s122-uk-0001"}]'::jsonb);
reset role;
select ok((select (v ->> 'ok')::boolean and (v ->> 'rows')::int = 1 and (v ->> 'replayed')::int = 0 from _r where k = 'g1') and (select (v ->> 'ok')::boolean and (v ->> 'rows')::int = 1 from _r where k = 'h1')
      and (select count(*) = 1 from public.inventory_usage where item_id = 'e1220010-0000-4000-8000-000000000121' and notes like '%[key:zz-s122-rk-0001]%')
      and (select count(*) = 1 from public.inventory_usage where item_id = 'e1220010-0000-4000-8000-000000000123' and notes like '%[key:zz-s122-uk-0001]%')
      and (select qty_on_hand = 9 from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000121') and (select qty_on_hand = 9 from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000123'),
  'fixture: the cleaner logged one usage row through Restock and one directly, each with a key');
insert into _r select 'gid', jsonb_build_object('id', id) from public.inventory_usage where item_id = 'e1220010-0000-4000-8000-000000000121' and notes like '%[key:zz-s122-rk-0001]%';
insert into _r select 'hid', jsonb_build_object('id', id) from public.inventory_usage where item_id = 'e1220010-0000-4000-8000-000000000123' and notes like '%[key:zz-s122-uk-0001]%';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000011"}';
insert into _r select 'g2', public.move_inventory_usage_v1((select (v ->> 'id')::uuid from _r where k = 'gid'), 'e1220010-0000-4000-8000-000000000122', 'zz-s122-key-0031');
insert into _r select 'h2', public.move_inventory_usage_v1((select (v ->> 'id')::uuid from _r where k = 'hid'), 'e1220010-0000-4000-8000-000000000124', 'zz-s122-key-0032');
reset role;
select ok((select (v ->> 'ok')::boolean from _r where k = 'g2') and (select (v ->> 'ok')::boolean from _r where k = 'h2')
      and (select count(*) = 1 from public.inventory_usage where item_id = 'e1220010-0000-4000-8000-000000000122' and moved_from_item_id = 'e1220010-0000-4000-8000-000000000121') and (select count(*) = 1 from public.inventory_usage where item_id = 'e1220010-0000-4000-8000-000000000124' and moved_from_item_id = 'e1220010-0000-4000-8000-000000000123'),
  'both rows were re-pointed by the admin (shelves: 121 back to 10, 122 down to 9)');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000012"}';
insert into _r select 'g3', public.record_restock_v1('e1220010-0000-4000-8000-000000000001', current_date, 'Zz cleaner', null, '[{"item_id":"e1220010-0000-4000-8000-000000000121","used_qty":1,"usage_key":"zz-s122-rk-0001"}]'::jsonb, '{}'::jsonb, '[]'::jsonb);
insert into _r select 'h3', public.record_inventory_usage('e1220010-0000-4000-8000-000000000001', current_date, 'Zz cleaner', null, '[{"item_id":"e1220010-0000-4000-8000-000000000123","used_qty":1,"usage_key":"zz-s122-uk-0001"}]'::jsonb);
reset role;
select ok((select (v ->> 'ok')::boolean and (v ->> 'rows')::int = 0 and (v ->> 'replayed')::int = 1 from _r where k = 'g3'),
  'record_restock_v1: the retry after the re-point is a replay (replayed 1, rows 0)');
select ok((select (v ->> 'ok')::boolean and (v ->> 'rows')::int = 1 from _r where k = 'h3')
      and (select count(*) = 0 from public.inventory_usage where item_id in ('e1220010-0000-4000-8000-000000000121', 'e1220010-0000-4000-8000-000000000123'))
      and (select count(*) = 1 from public.inventory_usage where notes like '%[key:zz-s122-rk-0001]%') and (select count(*) = 1 from public.inventory_usage where notes like '%[key:zz-s122-uk-0001]%'),
  'record_inventory_usage and record_restock_v1: no new usage row under either item, one row per key in all');
select ok((select qty_on_hand = 10 from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000121') and (select qty_on_hand = 9 from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000122')
      and (select qty_on_hand = 10 from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000123') and (select qty_on_hand = 9 from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000124'),
  'the replays left the shelves alone');

-- 63-70. undo of usage moves: moved_since, newest first, the first owner comes back ------------------------------------------------------------------
insert into public.inventory_usage(id, item_id, used_qty, session_date, logged_by, notes, property_id, created_at) values
  ('e1220010-0000-4000-8000-000000000204', 'e1220010-0000-4000-8000-000000000125', 1, current_date, 'zz', 'chain', 'e1220010-0000-4000-8000-000000000001', now() - interval '2 hours');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000011"}';
insert into _r select 'j1', public.move_inventory_usage_v1('e1220010-0000-4000-8000-000000000204', 'e1220010-0000-4000-8000-000000000126', 'zz-s122-key-0041');
insert into _r select 'j2', public.move_inventory_usage_v1('e1220010-0000-4000-8000-000000000204', 'e1220010-0000-4000-8000-000000000127', 'zz-s122-key-0042');
reset role;
select ok((select item_id = 'e1220010-0000-4000-8000-000000000127' and moved_from_item_id = 'e1220010-0000-4000-8000-000000000125' from public.inventory_usage where id = 'e1220010-0000-4000-8000-000000000204')
      and (select qty_on_hand = 11 and (select qty_on_hand from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000126') = 10 and (select qty_on_hand from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000127') = 9 from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000125'),
  'a second move keeps the first owner: the row is under J3, moved_from J1; shelves J1 11 (gave the unit back), J2 10, J3 9');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000011"}';
insert into _r select 'j3', public.undo_inventory_move_v1((select (v ->> 'moveId')::uuid from _r where k = 'j1'), 'zz-s122-undo-0041');   -- the row is under J3, the older move
insert into _r select 'j4', public.undo_inventory_move_v1((select (v ->> 'moveId')::uuid from _r where k = 'j2'), 'zz-s122-undo-0042');   -- the newest
insert into _r select 'j5', public.undo_inventory_move_v1((select (v ->> 'moveId')::uuid from _r where k = 'j2'), 'zz-s122-undo-0043');   -- twice
insert into _r select 'j6', public.undo_inventory_move_v1((select (v ->> 'moveId')::uuid from _r where k = 'j1'), 'zz-s122-undo-0044');   -- now the older one is the newest live move
reset role;
select ok((select v ->> 'reason' = 'moved_since' from _r where k = 'j3'), 'undo of the older move while a newer live move exists answers moved_since');
select ok((select (v ->> 'ok')::boolean and v ->> 'undoOf' = (select v ->> 'moveId' from _r where k = 'j2') from _r where k = 'j4')
      and (select (v ->> 'ok')::boolean and (v ->> 'replayed')::boolean and v ->> 'reason' = 'already_undone' from _r where k = 'j5'),
  'undo of the newest usage move works; a second undo answers already_undone');
select ok((select (v ->> 'ok')::boolean from _r where k = 'j6')
      and (select item_id = 'e1220010-0000-4000-8000-000000000125' and moved_from_item_id is null and moved_at is null from public.inventory_usage where id = 'e1220010-0000-4000-8000-000000000204')
      and (select qty_on_hand from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000125') = 10 and (select qty_on_hand from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000126') = 10 and (select qty_on_hand from public.inventory_items where id = 'e1220010-0000-4000-8000-000000000127') = 10,
  'then the older move undoes too: the row is back under J1 with no moved_from, shelves all 10 again');

-- 71-72. a usage row with no item ---------------------------------------------------------------------------------------------------------------
alter table public.inventory_usage alter column item_id drop not null;
insert into public.inventory_usage(id, item_id, used_qty, session_date, logged_by, notes, property_id, created_at) values ('e1220010-0000-4000-8000-000000000205', null, 1, current_date, 'zz', 'no item', 'e1220010-0000-4000-8000-000000000001', now() - interval '2 hours');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000011"}';
insert into _r select 'l1', public.move_inventory_usage_v1('e1220010-0000-4000-8000-000000000205', 'e1220010-0000-4000-8000-000000000128', 'zz-s122-key-0051');
reset role;
select ok((select v ->> 'reason' = 'usage_not_found' from _r where k = 'l1') and (select count(*) = 0 from public.inventory_item_moves where usage_id = 'e1220010-0000-4000-8000-000000000205'), 'a usage row with item_id null answers usage_not_found and writes nothing');

-- 73-80. the read -----------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1220010-0000-4000-8000-000000000011"}';
insert into _r select 'q1', public.get_inventory_item_moves_v1('e1220010-0000-4000-8000-000000000101');
insert into _r select 'q2', public.get_inventory_item_moves_v1('e1220010-0000-4000-8000-000000000118');
insert into _r select 'q3', public.get_inventory_item_moves_v1('e1220010-0000-4000-8000-00000000fffd');
insert into _r select 'q4', public.get_inventory_item_moves_v1('e1220010-0000-4000-8000-000000000111');
reset role;
select ok((select (v ->> 'ok')::boolean and jsonb_array_length(v -> 'moves') = 1 and v #>> '{moves,0,direction}' = 'out' and v #>> '{moves,0,otherItem}' = 'Zz S122 Bathroom tissue'
                  and (v #>> '{moves,0,qty}')::numeric = 7 and (v #>> '{moves,0,canUndo}')::boolean and not (v #>> '{moves,0,undone}')::boolean and v #>> '{moves,0,actor}' = 'Zz S122 Admin'
                  and v #>> '{moves,0,kind}' = 'stock' from _r where k = 'q1'),
  'the read: Kitchen towel has one move, out, 7 to Bathroom tissue, undoable, with the actor display name');
select ok((select jsonb_array_length(v -> 'counts') = 2 and (v #>> '{counts,0,qty}')::numeric = 6 and (v #>> '{counts,1,qty}')::numeric = 14 from _r where k = 'q1'),
  'the read carries the last counts newest first (6, then 14)');
select ok((select (select count(*) from jsonb_array_elements(v -> 'usage') e where e ->> 'id' = 'e1220010-0000-4000-8000-000000000201' and e ->> 'movedFrom' = 'Zz S122 F1' and (e ->> 'qty')::numeric = 2 and e ->> 'loggedBy' = 'zz' and e ? 'at' and not e ? 'movableAt') = 1
                  and (v #>> '{moves,0,direction}') in ('in', 'out') from _r where k = 'q2'),
  'the read of F2 lists the re-pointed usage row with movedFrom F1 and no movableAt');
select is((select v ->> 'reason' from _r where k = 'q3'), 'item_not_found', 'the read of an unknown item answers item_not_found');
select ok((select jsonb_array_length(v -> 'moves') = 2 and (select count(*) from jsonb_array_elements(v -> 'moves') e where (e ->> 'undone')::boolean) = 1 and (select count(*) from jsonb_array_elements(v -> 'moves') e where not (e ->> 'canUndo')::boolean) = 2
                  and (select count(*) from jsonb_array_elements(v -> 'moves') e where e ->> 'undoOf' is not null) = 1 from _r where k = 'q4'),
  'the read of an item whose move was undone: two lines, one undone, neither undoable, one is the undo');

select diag(k || ' ' || v::text) from _r order by k;
select * from finish();
rollback;
