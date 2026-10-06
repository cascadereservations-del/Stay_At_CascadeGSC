-- Session 74, lane G3: release money_fixes_20261007 part 3. record_inventory_usage (same signature): a movement-controlled item gets a
-- kind=usage stock movement even when a cleaner (submit_cleaning) logs it; a not-controlled item keeps the legacy clamp and gets NO movement. Synthetic rows (uuids
-- e7800000-...); everything rolls back. Fixture rows and the final reads run as the owner role (a --no-acl restore gives
-- authenticated no table grants); only the RPC calls run as the cleaner.
begin;
select plan(19);

create function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'aal', 'aal1', 'iat', extract(epoch from now())::bigint)::text, true),
         set_config('role', 'authenticated', true)
$$;
grant execute on function pg_temp.as_user(uuid) to public;
create temp table _t(k text primary key, v jsonb);
grant all on _t to public;

-- the contract the PWA and the checklist rely on -------------------------------------------------------------------------------
select is((select pg_get_function_identity_arguments('public.record_inventory_usage(uuid,date,text,text,jsonb)'::regprocedure)),
  'p_property_id uuid, p_session_date date, p_logged_by text, p_notes text, p_rows jsonb', 'the signature is unchanged');
select ok(has_function_privilege('authenticated', 'public.record_inventory_usage(uuid,date,text,text,jsonb)', 'execute')
      and has_function_privilege('service_role', 'public.record_inventory_usage(uuid,date,text,text,jsonb)', 'execute')
      and not has_function_privilege('anon', 'public.record_inventory_usage(uuid,date,text,text,jsonb)', 'execute'),
  'grants unchanged: authenticated and service_role, not anon');

-- fixtures: property, a cleaner (submit_cleaning) and a user with no staff profile ---------------------------------------------
insert into public.properties(id, name, is_active) values ('e7800000-0000-4000-8000-0000000000a1', 'Synthetic Stock G3', true);
insert into auth.users(id) values ('e7800000-0000-4000-8000-000000000001'), ('e7800000-0000-4000-8000-000000000002');
insert into public.staff_access_profiles(user_id, role) values ('e7800000-0000-4000-8000-000000000001', 'cleaner');
insert into public.staff_property_access(user_id, property_id) values ('e7800000-0000-4000-8000-000000000001', 'e7800000-0000-4000-8000-0000000000a1');
-- U1 stock 10, U2 stock 2 (clamp), U3 stock 0, C1 controlled 5 with a baseline movement, C2 controlled 5 with NO movement (ledger cannot be trusted)
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, units_per_purchase, movement_controlled_at) values
  ('e7800000-0000-4000-8000-0000000000c1', 'e7800000-0000-4000-8000-0000000000a1', 'zz U1 soap', 'bath', 'pc', 10, true, true, 1, null),
  ('e7800000-0000-4000-8000-0000000000c2', 'e7800000-0000-4000-8000-0000000000a1', 'zz U2 tissue', 'bath', 'pc', 2, true, true, 1, null),
  ('e7800000-0000-4000-8000-0000000000c3', 'e7800000-0000-4000-8000-0000000000a1', 'zz U3 empty', 'bath', 'pc', 0, true, true, 1, null),
  ('e7800000-0000-4000-8000-0000000000c4', 'e7800000-0000-4000-8000-0000000000a1', 'zz C1 controlled', 'bath', 'pc', 5, true, true, 1, now()),
  ('e7800000-0000-4000-8000-0000000000c5', 'e7800000-0000-4000-8000-0000000000a1', 'zz C2 no ledger', 'bath', 'pc', 5, true, true, 1, now());
insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key) values
  ('e7800000-0000-4000-8000-0000000000c4', 'e7800000-0000-4000-8000-0000000000a1', 'reconcile', 5, 5, 'zz baseline count', 'e7800000-0000-4000-8000-000000000001', 'zz-g3-baseline-c4-0001');

-- 1. not controlled, within stock: the legacy decrement 10 -> 7 and NO movement (Fable G3: inventory_usage is the audit row) --------
select pg_temp.as_user('e7800000-0000-4000-8000-000000000001');
insert into _t select 'u1', public.record_inventory_usage('e7800000-0000-4000-8000-0000000000a1', date '2026-10-07', 'Honey', null,
  '[{"item_id":"e7800000-0000-4000-8000-0000000000c1","used_qty":3,"usage_key":"zz-g3-usage-1"}]'::jsonb);
reset role;
select is((select v->>'ok' from _t where k = 'u1'), 'true', 'a cleaner logs usage of a not-controlled item');
select is((select qty_on_hand from public.inventory_items where id = 'e7800000-0000-4000-8000-0000000000c1'), 7::numeric, 'stock goes 10 -> 7');
select is((select count(*)::int from public.inventory_stock_movements where item_id = 'e7800000-0000-4000-8000-0000000000c1'), 0, 'no movement row is written for a not-controlled item');
select is((select jsonb_array_length(v->'movements') from _t where k = 'u1'), 0, 'and the return value lists no movement');

-- 2. replay with the same usage_key: no second usage row ----------------------------------------------------------------------------
select pg_temp.as_user('e7800000-0000-4000-8000-000000000001');
insert into _t select 'u1b', public.record_inventory_usage('e7800000-0000-4000-8000-0000000000a1', date '2026-10-07', 'Honey', null,
  '[{"item_id":"e7800000-0000-4000-8000-0000000000c1","used_qty":3,"usage_key":"zz-g3-usage-1"}]'::jsonb);
reset role;
select is((select qty_on_hand from public.inventory_items where id = 'e7800000-0000-4000-8000-0000000000c1'), 7::numeric, 'a replay leaves 7');
select is((select count(*)::int from public.inventory_usage where item_id = 'e7800000-0000-4000-8000-0000000000c1'), 1, 'and no second usage row');

-- 3. not controlled, more than the shelf holds: clamp at zero, still no movement ------------------------------------------------
select pg_temp.as_user('e7800000-0000-4000-8000-000000000001');
insert into _t select 'u2', public.record_inventory_usage('e7800000-0000-4000-8000-0000000000a1', date '2026-10-07', 'Honey', null,
  '[{"item_id":"e7800000-0000-4000-8000-0000000000c2","used_qty":5}]'::jsonb);
reset role;
select is((select qty_on_hand from public.inventory_items where id = 'e7800000-0000-4000-8000-0000000000c2'), 0::numeric, 'stock clamps at 0, the log is not refused');
select is((select used_qty from public.inventory_usage where item_id = 'e7800000-0000-4000-8000-0000000000c2'), 5::numeric, 'the usage row keeps the 5 the cleaner logged');
select is((select count(*)::int from public.inventory_stock_movements where item_id = 'e7800000-0000-4000-8000-0000000000c2'), 0, 'no movement row for the clamped item either');

-- 4. not controlled, already at zero: nothing changes, no movement ---------------------------------------------------------------
select pg_temp.as_user('e7800000-0000-4000-8000-000000000001');
insert into _t select 'u3', public.record_inventory_usage('e7800000-0000-4000-8000-0000000000a1', date '2026-10-07', 'Honey', null,
  '[{"item_id":"e7800000-0000-4000-8000-0000000000c3","used_qty":1}]'::jsonb);
reset role;
select ok((select (v->>'ok')::boolean and jsonb_array_length(v->'movements') = 0 from _t where k = 'u3')
      and not exists (select 1 from public.inventory_stock_movements where item_id = 'e7800000-0000-4000-8000-0000000000c3')
      and (select count(*) from public.inventory_usage where item_id = 'e7800000-0000-4000-8000-0000000000c3') = 1,
  'a usage against an empty shelf is logged, changes no stock and writes no movement');

-- 5. controlled: a CLEANER can log it now (v2 refused: inventory_human_authorized wants an owner/admin) -----------------------------
select pg_temp.as_user('e7800000-0000-4000-8000-000000000001');
insert into _t select 'c1', public.record_inventory_usage('e7800000-0000-4000-8000-0000000000a1', date '2026-10-07', 'Honey', null,
  '[{"item_id":"e7800000-0000-4000-8000-0000000000c4","used_qty":4}]'::jsonb);
reset role;
select ok((select (v->>'ok')::boolean from _t where k = 'c1')
      and (select qty_on_hand from public.inventory_items where id = 'e7800000-0000-4000-8000-0000000000c4') = 1
      and (select m.kind = 'usage' and m.quantity_before = 5 and m.quantity_after = 1 from public.inventory_stock_movements m
            where m.item_id = 'e7800000-0000-4000-8000-0000000000c4' order by m.sequence_no desc limit 1),
  'a cleaner logs a controlled item: 5 -> 1 with a usage movement');

-- 6. controlled: insufficient stock is rejected, not clamped; the ledger must agree with the shelf ---------------------------------
select pg_temp.as_user('e7800000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_inventory_usage('e7800000-0000-4000-8000-0000000000a1', date '2026-10-07', 'Honey', null,
  '[{"item_id":"e7800000-0000-4000-8000-0000000000c4","used_qty":2}]'::jsonb)$$, '22023', 'insufficient stock for zz C1 controlled', 'a controlled item rejects insufficient stock');
select throws_ok($$select public.record_inventory_usage('e7800000-0000-4000-8000-0000000000a1', date '2026-10-07', 'Honey', null,
  '[{"item_id":"e7800000-0000-4000-8000-0000000000c5","used_qty":1}]'::jsonb)$$, '22023', 'stock reconciliation required for zz C2 no ledger', 'a controlled item whose ledger is empty needs a count first');
reset role;
select is((select count(*)::int from public.inventory_usage where item_id in ('e7800000-0000-4000-8000-0000000000c4', 'e7800000-0000-4000-8000-0000000000c5')), 1,
  'the two refusals left no usage row behind (only the one accepted usage of C1)');

-- 7. refusals unchanged ----------------------------------------------------------------------------------------------------------
select pg_temp.as_user('e7800000-0000-4000-8000-000000000002');
select throws_ok($$select public.record_inventory_usage('e7800000-0000-4000-8000-0000000000a1', date '2026-10-07', 'x', null,
  '[{"item_id":"e7800000-0000-4000-8000-0000000000c1","used_qty":1}]'::jsonb)$$, '42501', 'staff access denied', 'a user with no staff profile is refused');
select pg_temp.as_user('e7800000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_inventory_usage('e7800000-0000-4000-8000-0000000000a1', date '2026-10-07', 'x', null,
  '[{"item_id":"e7800000-0000-4000-8000-0000000000ff","used_qty":1}]'::jsonb)$$, '22023', 'unknown item for property', 'an unknown item is refused');
reset role;

-- 8. the ledger health check's shape: every controlled item agrees with its last movement ---------------------------------------
select is((select count(*)::int from public.inventory_items i
            where i.property_id = 'e7800000-0000-4000-8000-0000000000a1' and i.movement_controlled_at is not null
              and (select quantity_after from public.inventory_stock_movements m where m.item_id = i.id order by sequence_no desc limit 1) is not null
              and (select quantity_after from public.inventory_stock_movements m where m.item_id = i.id order by sequence_no desc limit 1) <> i.qty_on_hand), 0,
  'every controlled item still agrees with its last movement (inventory_ledger_consistent)');

select * from finish();
rollback;
