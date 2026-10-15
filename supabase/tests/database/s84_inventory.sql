-- Session 84, lane I-sql: release s84_inventory_20261017 (phase 1 + phase 1b: undo, history, countedAt, weekly low-stock task). The unit_cost leak (column grant, realtime), par_qty, barcode links, the catalogue's new par and
-- codes keys, item create / update / price RPCs. Hermetic: its own property and users (uuids d8400000-...), nothing else is touched. Everything rolls back.
-- The md5 guard at the head of the migration cannot run inside pgTAP; the rehearsal proves it by applying the migration to a database whose
-- get_inventory_catalogue_v1 body was changed first (expect SQLSTATE 55000 and nothing changed).
begin;
select plan(119);

-- baseline grants for a --no-acl rehearsal restore (idempotent, rolled back with the suite)
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal1', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
-- runs one statement that returns a single jsonb value; an error comes back as {"err": sqlstate} so the assertions can run as the test owner
create function pg_temp.try(p text) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  execute p into r;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;

-- fixtures: a cleaner, an admin, a finance user and an owner on a property of their own, two items (one priced, with a par) and a code on the second
insert into auth.users(id, email) values
  ('d8400000-0000-4000-8000-0000000000a1', 'zz84-honey@example.com'), ('d8400000-0000-4000-8000-0000000000a3', 'zz84-admin@example.com'),
  ('d8400000-0000-4000-8000-0000000000a4', 'zz84-finance@example.com'), ('d8400000-0000-4000-8000-0000000000a5', 'zz84-owner@example.com');
insert into public.staff_access_profiles(user_id, role) values
  ('d8400000-0000-4000-8000-0000000000a1', 'cleaner'), ('d8400000-0000-4000-8000-0000000000a3', 'admin'),
  ('d8400000-0000-4000-8000-0000000000a4', 'finance'), ('d8400000-0000-4000-8000-0000000000a5', 'owner');
insert into public.properties(id, name, is_active) values ('d8400000-0000-4000-8000-0000000000b0', 'Zz S84 fixture property', true);
insert into public.staff_property_access(user_id, property_id) select u, 'd8400000-0000-4000-8000-0000000000b0'
  from unnest(array['d8400000-0000-4000-8000-0000000000a1', 'd8400000-0000-4000-8000-0000000000a3', 'd8400000-0000-4000-8000-0000000000a4', 'd8400000-0000-4000-8000-0000000000a5']::uuid[]) u;
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, reorder_below, par_qty, is_consumable, unit_cost) values
  ('d8400000-0000-4000-8000-0000000000c1', 'd8400000-0000-4000-8000-0000000000b0', 'Zz84 Hand soap', 'Toiletries', 'pc', 5, 2, 10, true, 95.00),
  ('d8400000-0000-4000-8000-0000000000c2', 'd8400000-0000-4000-8000-0000000000b0', 'Zz84 Towel', 'Bedroom', 'pc', 8, null, null, false, null);
insert into public.inventory_item_codes(property_id, item_id, code, format, created_by) values
  ('d8400000-0000-4000-8000-0000000000b0', 'd8400000-0000-4000-8000-0000000000c2', '4800000000001', 'ean_13', 'd8400000-0000-4000-8000-0000000000a5');

-- =============================================================================================================================================
-- Part 1: the unit_cost leak
-- =============================================================================================================================================
select ok(not has_column_privilege('authenticated', 'public.inventory_items', 'unit_cost', 'select'), 'authenticated cannot select unit_cost');
select ok(has_column_privilege('authenticated', 'public.inventory_items', 'name', 'select') and has_column_privilege('authenticated', 'public.inventory_items', 'qty_on_hand', 'select')
  and has_column_privilege('authenticated', 'public.inventory_items', 'par_qty', 'select') and has_column_privilege('authenticated', 'public.inventory_items', 'property_id', 'select'),
  'but can still select name, qty_on_hand, par_qty and property_id');
select is((select count(*)::int from pg_attribute a where a.attrelid = 'public.inventory_items'::regclass and a.attnum > 0 and not a.attisdropped and a.attname <> 'unit_cost'
  and not has_column_privilege('authenticated', a.attrelid, a.attname, 'select')), 0, 'every column except unit_cost is granted (none dropped by mistake)');
select ok(not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'inventory_items'),
  'inventory_items is not in the realtime publication (vacuously true where the publication does not exist)');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a1');
insert into _t select 'l_cl', pg_temp.try($$select to_jsonb(count(*)) from (select unit_cost from public.inventory_items) x$$);
insert into _t select 'l_cl_ok', pg_temp.try($$select to_jsonb(count(*)) from (select name, qty_on_hand from public.inventory_items) x$$);
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'l_ow', pg_temp.try($$select to_jsonb(count(*)) from (select unit_cost from public.inventory_items) x$$);
reset role;
select is((select v->>'err' from _t where k = 'l_cl'), '42501', 'a cleaner reading unit_cost over the table is refused');
select is((select v->>'err' from _t where k = 'l_ow'), '42501', 'so is an owner (the column is read through the finance-gated RPC only)');
select ok((select not (v ? 'err') from _t where k = 'l_cl_ok'), 'a cleaner can still read name and qty_on_hand');

-- =============================================================================================================================================
-- Part 2: the catalogue carries par and codes, and unitCost only for finance-capable roles
-- =============================================================================================================================================
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a1');
insert into _t select 'c_cl', pg_temp.try($$select public.get_inventory_catalogue_v1('d8400000-0000-4000-8000-0000000000b0')$$);
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a4');
insert into _t select 'c_fi', pg_temp.try($$select public.get_inventory_catalogue_v1('d8400000-0000-4000-8000-0000000000b0')$$);
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'c_ow', pg_temp.try($$select public.get_inventory_catalogue_v1('d8400000-0000-4000-8000-0000000000b0')$$);
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a3');
insert into _t select 'c_ad', pg_temp.try($$select public.get_inventory_catalogue_v1('d8400000-0000-4000-8000-0000000000b0')$$);
reset role;
select is((select e->>'par' from _t, jsonb_array_elements(v->'items') e where k = 'c_cl' and e->>'id' = 'd8400000-0000-4000-8000-0000000000c1'), '10.00', 'a cleaner sees the par level');
select is((select e->'codes' from _t, jsonb_array_elements(v->'items') e where k = 'c_cl' and e->>'id' = 'd8400000-0000-4000-8000-0000000000c2'), '["4800000000001"]'::jsonb, 'and the linked codes');
select is((select e->'codes' from _t, jsonb_array_elements(v->'items') e where k = 'c_cl' and e->>'id' = 'd8400000-0000-4000-8000-0000000000c1'), '[]'::jsonb, 'an item with no code has an empty list');
select is((select e->'unitCost' from _t, jsonb_array_elements(v->'items') e where k = 'c_cl' and e->>'id' = 'd8400000-0000-4000-8000-0000000000c1'), 'null'::jsonb, 'a cleaner gets no price');
select is((select (e->>'unitCost')::numeric from _t, jsonb_array_elements(v->'items') e where k = 'c_fi' and e->>'id' = 'd8400000-0000-4000-8000-0000000000c1'), 95.00, 'finance gets the price');
select is((select (e->>'unitCost')::numeric from _t, jsonb_array_elements(v->'items') e where k = 'c_ow' and e->>'id' = 'd8400000-0000-4000-8000-0000000000c1'), 95.00, 'the owner gets the price');
select is((select (e->>'unitCost')::numeric from _t, jsonb_array_elements(v->'items') e where k = 'c_ad' and e->>'id' = 'd8400000-0000-4000-8000-0000000000c1'), 95.00, 'the admin gets the price');

-- =============================================================================================================================================
-- Part 3: inventory_code_attach_v1 / inventory_code_detach_v1
-- =============================================================================================================================================
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'a1', pg_temp.try($$select public.inventory_code_attach_v1('d8400000-0000-4000-8000-0000000000b0', ' ZZ84-A ', 'code_128', 'd8400000-0000-4000-8000-0000000000c1')$$);
insert into _t select 'a2', pg_temp.try($$select public.inventory_code_attach_v1('d8400000-0000-4000-8000-0000000000b0', 'ZZ84-A', 'code_128', 'd8400000-0000-4000-8000-0000000000c1')$$);
insert into _t select 'a3', pg_temp.try($$select public.inventory_code_attach_v1('d8400000-0000-4000-8000-0000000000b0', '4800000000001', null, 'd8400000-0000-4000-8000-0000000000c1')$$);
insert into _t select 'a6', pg_temp.try($$select public.inventory_code_attach_v1('d8400000-0000-4000-8000-0000000000b0', 'ab cd', null, 'd8400000-0000-4000-8000-0000000000c1')$$);
insert into _t select 'a7', pg_temp.try(format($q$select public.inventory_code_attach_v1('d8400000-0000-4000-8000-0000000000b0', %L, null, 'd8400000-0000-4000-8000-0000000000c1')$q$, repeat('9', 129)));
insert into _t select 'a8', pg_temp.try($$select public.inventory_code_attach_v1('d8400000-0000-4000-8000-0000000000b0', 'ZZ84-F', 'BAD FORMAT!', 'd8400000-0000-4000-8000-0000000000c1')$$);
insert into _t select 'a10', pg_temp.try($$select public.inventory_code_attach_v1('d8400000-0000-4000-8000-0000000000b0', 'ZZ84-G', null, 'd8400000-0000-4000-8000-0000000000ff')$$);
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a3');
insert into _t select 'a9', pg_temp.try($$select public.inventory_code_attach_v1('d8400000-0000-4000-8000-0000000000b0', 'ZZ84-ADMIN', 'qr_code', 'd8400000-0000-4000-8000-0000000000c2')$$);
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a1');
insert into _t select 'a4', pg_temp.try($$select public.inventory_code_attach_v1('d8400000-0000-4000-8000-0000000000b0', 'ZZ84-CL', null, 'd8400000-0000-4000-8000-0000000000c1')$$);
insert into _t select 'd3', pg_temp.try($$select public.inventory_code_detach_v1('d8400000-0000-4000-8000-0000000000b0', 'ZZ84-A')$$);
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a4');
insert into _t select 'a5', pg_temp.try($$select public.inventory_code_attach_v1('d8400000-0000-4000-8000-0000000000b0', 'ZZ84-FI', null, 'd8400000-0000-4000-8000-0000000000c1')$$);
reset role;
select is((select v from _t where k = 'a1'), '{"ok": true, "code": "ZZ84-A", "item_id": "d8400000-0000-4000-8000-0000000000c1", "replayed": false}'::jsonb, 'an owner links a code (trimmed) to an item');
select is((select v->>'replayed' from _t where k = 'a2'), 'true', 'linking the same code to the same item again is answered, not duplicated');
select is((select v from _t where k = 'a3'), '{"ok": false, "reason": "code_taken", "item_id": "d8400000-0000-4000-8000-0000000000c2", "item_name": "Zz84 Towel"}'::jsonb, 'a code already on another item is refused and names that item');
select is((select v->>'err' from _t where k = 'a4'), '42501', 'a cleaner cannot link a code');
select is((select v->>'err' from _t where k = 'a5'), '42501', 'finance cannot link a code');
select is((select v->>'reason' from _t where k = 'a6'), 'bad_code', 'a code with a space is bad_code');
select is((select v->>'reason' from _t where k = 'a7'), 'bad_code', 'a code of 129 characters is bad_code');
select is((select v->>'reason' from _t where k = 'a8'), 'bad_code', 'a format that is not lower-case letters, digits and underscore is bad_code');
select is((select v->>'ok' from _t where k = 'a9'), 'true', 'an admin can link a code');
select is((select v->>'err' from _t where k = 'a10'), 'P0002', 'an item that is not in the property is not found');
select is((select count(*)::int from public.inventory_item_codes where property_id = 'd8400000-0000-4000-8000-0000000000b0' and code = 'ZZ84-A'), 1, 'the replayed link made one row');
select is((select format from public.inventory_item_codes where property_id = 'd8400000-0000-4000-8000-0000000000b0' and code = 'ZZ84-A'), 'code_128', 'the format is stored');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'd1', pg_temp.try($$select public.inventory_code_detach_v1('d8400000-0000-4000-8000-0000000000b0', 'ZZ84-ADMIN')$$);
insert into _t select 'd2', pg_temp.try($$select public.inventory_code_detach_v1('d8400000-0000-4000-8000-0000000000b0', 'ZZ84-ADMIN')$$);
reset role;
select is((select v from _t where k = 'd1'), '{"ok": true, "removed": true}'::jsonb, 'an owner unlinks a code');
select is((select v from _t where k = 'd2'), '{"ok": true, "removed": false}'::jsonb, 'unlinking it again says nothing was removed');
select is((select v->>'err' from _t where k = 'd3'), '42501', 'a cleaner cannot unlink a code');

-- =============================================================================================================================================
-- Part 4: inventory_item_create_v1
-- =============================================================================================================================================
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'n1', pg_temp.try($$select public.inventory_item_create_v1('d8400000-0000-4000-8000-0000000000b0', '{"name": " Zz84 Mop ", "category": "Miscellaneous", "unit": "pc", "qty": 5, "par_qty": 8}'::jsonb, 'ZZ84-MOP', 'qr_code', null)$$);
insert into _t select 'n2', pg_temp.try($$select public.inventory_item_create_v1('d8400000-0000-4000-8000-0000000000b0', '{"name": "zz84 MOP", "category": "Miscellaneous"}'::jsonb, null, null, null)$$);
insert into _t select 'n3', pg_temp.try($$select public.inventory_item_create_v1('d8400000-0000-4000-8000-0000000000b0', '{"name": "Zz84 Broom", "category": "Miscellaneous"}'::jsonb, '4800000000001', null, null)$$);
insert into _t select 'n6', pg_temp.try($$select public.inventory_item_create_v1('d8400000-0000-4000-8000-0000000000b0', '{"name": "x", "category": "Miscellaneous"}'::jsonb, null, null, null)$$);
insert into _t select 'n7', pg_temp.try($$select public.inventory_item_create_v1('d8400000-0000-4000-8000-0000000000b0', '{"name": "Zz84 Priced", "category": "Miscellaneous", "unit_cost": 5}'::jsonb, null, null, null)$$);
insert into _t select 'n8', pg_temp.try($$select public.inventory_item_create_v1('d8400000-0000-4000-8000-0000000000b0', '{"name": "Zz84 Plain", "category": "Miscellaneous", "consumable": true, "reorder_below": 2}'::jsonb, null, null, null)$$);
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a1');
insert into _t select 'n4', pg_temp.try($$select public.inventory_item_create_v1('d8400000-0000-4000-8000-0000000000b0', '{"name": "Zz84 Cl item", "category": "Miscellaneous"}'::jsonb, null, null, null)$$);
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a4');
insert into _t select 'n5', pg_temp.try($$select public.inventory_item_create_v1('d8400000-0000-4000-8000-0000000000b0', '{"name": "Zz84 Fi item", "category": "Miscellaneous"}'::jsonb, null, null, null)$$);
reset role;
select is((select v->>'ok' from _t where k = 'n1'), 'true', 'an owner adds an item with a first count and a code');
select is((select qty_on_hand from public.inventory_items where id = (select (v->>'item_id')::uuid from _t where k = 'n1')), 5.00, 'the first count is on hand');
select is((select name from public.inventory_items where id = (select (v->>'item_id')::uuid from _t where k = 'n1')), 'Zz84 Mop', 'the name is trimmed');
select is((select count(*)::int from public.inventory_stock_movements where item_id = (select (v->>'item_id')::uuid from _t where k = 'n1') and kind = 'reconcile' and quantity_after = 5), 1, 'the count is one reconcile movement');
select ok((select movement_controlled_at is not null and par_qty = 8 from public.inventory_items where id = (select (v->>'item_id')::uuid from _t where k = 'n1')), 'the item is movement-controlled and keeps its par');
select is((select count(*)::int from public.inventory_item_codes where item_id = (select (v->>'item_id')::uuid from _t where k = 'n1') and code = 'ZZ84-MOP' and format = 'qr_code'), 1, 'and the code is linked');
select is((select v->>'reason' from _t where k = 'n2'), 'name_exists', 'the same name again (any case) is name_exists');
select is((select (v->>'item_id')::uuid from _t where k = 'n2'), (select (v->>'item_id')::uuid from _t where k = 'n1'), 'and names the existing item');
select is((select v->>'reason' from _t where k = 'n3'), 'code_taken', 'a code that is already linked refuses the create');
select is((select count(*)::int from public.inventory_items where property_id = 'd8400000-0000-4000-8000-0000000000b0' and name = 'Zz84 Broom'), 0, 'and nothing is created');
select is((select v->>'err' from _t where k = 'n4'), '42501', 'a cleaner cannot add an item');
select is((select v->>'err' from _t where k = 'n5'), '42501', 'finance cannot add an item');
select is((select v->>'err' from _t where k = 'n6'), '22023', 'a one-letter name is refused');
select is((select v->>'err' from _t where k = 'n7'), '22023', 'a cost in the new-item form is refused (price has its own RPC)');
select ok((select i.qty_on_hand = 0 and i.movement_controlled_at is null and i.is_consumable and i.reorder_below = 2 and i.sort_order > 0 and i.unit = 'pc' and i.unit_cost is null
  from public.inventory_items i where i.id = (select (v->>'item_id')::uuid from _t where k = 'n8')), 'an item with no first count starts at 0, uncontrolled, unit pc, no price');

-- =============================================================================================================================================
-- Part 5: inventory_item_update_v1
-- =============================================================================================================================================
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'u1', pg_temp.try($$select public.inventory_item_update_v1('d8400000-0000-4000-8000-0000000000c1', '{"par_qty": 12, "reorder_below": 3}'::jsonb)$$);
insert into _t select 'u3', pg_temp.try($$select public.inventory_item_update_v1('d8400000-0000-4000-8000-0000000000c1', '{"unit_cost": 1}'::jsonb)$$);
insert into _t select 'u4', pg_temp.try($$select public.inventory_item_update_v1('d8400000-0000-4000-8000-0000000000c1', '{"qty_on_hand": 99}'::jsonb)$$);
insert into _t select 'u8', pg_temp.try($$select public.inventory_item_update_v1('d8400000-0000-4000-8000-0000000000c1', '{"par_qty": -1}'::jsonb)$$);
insert into _t select 'u10', pg_temp.try($$select public.inventory_item_update_v1('d8400000-0000-4000-8000-0000000000c2', '{"name": "zz84 hand soap"}'::jsonb)$$);
insert into _t select 'u11', pg_temp.try($$select public.inventory_item_update_v1('d8400000-0000-4000-8000-0000000000c1', '{}'::jsonb)$$);
reset role;
select is((select v->>'ok' from _t where k = 'u1'), 'true', 'an owner changes the levels');
select ok((select par_qty = 12 and reorder_below = 3 from public.inventory_items where id = 'd8400000-0000-4000-8000-0000000000c1'), 'and they are saved');
select is((select v->>'err' from _t where k = 'u3'), '22023', 'unit_cost in a patch is refused');
select is((select v->>'err' from _t where k = 'u4'), '22023', 'qty_on_hand in a patch is refused (counting has its own RPC)');
select is((select unit_cost from public.inventory_items where id = 'd8400000-0000-4000-8000-0000000000c1'), 95.00, 'the price and quantity were not touched');
select is((select v->>'err' from _t where k = 'u8'), '22023', 'a negative par is refused');
select is((select v->>'reason' from _t where k = 'u10'), 'name_exists', 'renaming onto another active item is name_exists');
select is((select v->>'err' from _t where k = 'u11'), '22023', 'an empty patch is refused');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a1');
insert into _t select 'u5', pg_temp.try($$select public.inventory_item_update_v1('d8400000-0000-4000-8000-0000000000c1', '{"par_qty": 20}'::jsonb)$$);
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a4');
insert into _t select 'u6', pg_temp.try($$select public.inventory_item_update_v1('d8400000-0000-4000-8000-0000000000c1', '{"par_qty": 20}'::jsonb)$$);
reset role;
select is((select v->>'err' from _t where k = 'u5'), '42501', 'a cleaner cannot change levels');
select is((select v->>'err' from _t where k = 'u6'), '42501', 'finance cannot change levels');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a3');
insert into _t select 'u9', pg_temp.try($$select public.inventory_item_update_v1('d8400000-0000-4000-8000-0000000000c1', '{"par_qty": null}'::jsonb)$$);
reset role;
select ok((select v->>'ok' = 'true' and (select par_qty is null from public.inventory_items where id = 'd8400000-0000-4000-8000-0000000000c1') from _t where k = 'u9'), 'an admin can clear the par (null = twice the reorder level)');

-- =============================================================================================================================================
-- Part 6: inventory_item_price_set_v1
-- =============================================================================================================================================
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a4');
insert into _t select 'p1', pg_temp.try($$select public.inventory_item_price_set_v1('d8400000-0000-4000-8000-0000000000c1', 120.50)$$);
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'p3', pg_temp.try($$select public.inventory_item_price_set_v1('d8400000-0000-4000-8000-0000000000c1', 99)$$);
insert into _t select 'p5', pg_temp.try($$select public.inventory_item_price_set_v1('d8400000-0000-4000-8000-0000000000c1', 0)$$);
insert into _t select 'p6', pg_temp.try($$select public.inventory_item_price_set_v1('d8400000-0000-4000-8000-0000000000c1', 1000000)$$);
insert into _t select 'p7', pg_temp.try($$select public.inventory_item_price_set_v1('d8400000-0000-4000-8000-0000000000c1', 12.345)$$);
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a1');
insert into _t select 'p4', pg_temp.try($$select public.inventory_item_price_set_v1('d8400000-0000-4000-8000-0000000000c1', 1)$$);
reset role;
select is((select v from _t where k = 'p1'), '{"ok": true, "after": 120.50, "before": 95.00, "item_id": "d8400000-0000-4000-8000-0000000000c1"}'::jsonb, 'finance sets a price and gets the before and after');
select is((select (v->>'before')::numeric from _t where k = 'p3'), 120.50, 'an owner sets a price (before is finance''s 120.50)');
select is((select unit_cost from public.inventory_items where id = 'd8400000-0000-4000-8000-0000000000c1'), 99.00, 'and it is saved');
select is((select v->>'err' from _t where k = 'p4'), '42501', 'a cleaner cannot set a price');
select is((select v->>'err' from _t where k = 'p5'), '22023', 'a price of 0 is refused');
select is((select v->>'err' from _t where k = 'p6'), '22023', 'a price of 1,000,000 is refused');
select is((select v->>'err' from _t where k = 'p7'), '22023', 'a price with three decimals is refused');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a3');
insert into _t select 'p8', pg_temp.try($$select public.inventory_item_price_set_v1('d8400000-0000-4000-8000-0000000000c1', null)$$);
reset role;
select ok((select v->'after' = 'null'::jsonb and (select unit_cost is null from public.inventory_items where id = 'd8400000-0000-4000-8000-0000000000c1') from _t where k = 'p8'), 'an admin can clear a price');

-- =============================================================================================================================================
-- Part 7: grants and shape
-- =============================================================================================================================================
select ok(not (has_function_privilege('anon', 'public.inventory_code_attach_v1(uuid,text,text,uuid)', 'execute') or has_function_privilege('anon', 'public.inventory_code_detach_v1(uuid,text)', 'execute')
  or has_function_privilege('anon', 'public.inventory_item_create_v1(uuid,jsonb,text,text,text)', 'execute') or has_function_privilege('anon', 'public.inventory_item_update_v1(uuid,jsonb)', 'execute')
  or has_function_privilege('anon', 'public.inventory_item_price_set_v1(uuid,numeric)', 'execute')), 'anon executes none of the five new functions');
select ok(has_function_privilege('authenticated', 'public.inventory_code_attach_v1(uuid,text,text,uuid)', 'execute') and has_function_privilege('authenticated', 'public.inventory_code_detach_v1(uuid,text)', 'execute')
  and has_function_privilege('authenticated', 'public.inventory_item_create_v1(uuid,jsonb,text,text,text)', 'execute') and has_function_privilege('authenticated', 'public.inventory_item_update_v1(uuid,jsonb)', 'execute')
  and has_function_privilege('authenticated', 'public.inventory_item_price_set_v1(uuid,numeric)', 'execute'), 'signed-in users execute all five (each gates itself)');
select ok(not has_table_privilege('anon', 'public.inventory_item_codes', 'select,insert,update,delete') and not has_table_privilege('authenticated', 'public.inventory_item_codes', 'select,insert,update,delete'),
  'the codes table has no client grant');
select ok((select relrowsecurity from pg_class where oid = 'public.inventory_item_codes'::regclass), 'and row level security is on');
select throws_ok($$insert into public.inventory_items(property_id, name, category, par_qty) values ('d8400000-0000-4000-8000-0000000000b0', 'Zz84 bad par', 'Bedroom', -1)$$, '23514', null, 'par_qty cannot be negative');
select ok((select bool_and(prosecdef and proconfig @> array['search_path=""']) from pg_proc where pronamespace = 'public'::regnamespace
  and proname in ('inventory_code_attach_v1', 'inventory_code_detach_v1', 'inventory_item_create_v1', 'inventory_item_update_v1', 'inventory_item_price_set_v1')), 'the five functions are definer with an empty search_path');

-- =============================================================================================================================================
-- Part 8 (phase 1b): inventory_undo_v1
-- =============================================================================================================================================
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'ua', pg_temp.try($$select public.inventory_item_create_v1('d8400000-0000-4000-8000-0000000000b0', '{"name": "Zz84 Undo A", "category": "Bedroom", "qty": 12}'::jsonb, null, null, null)$$);
insert into _t select 'ub', pg_temp.try($$select public.inventory_item_create_v1('d8400000-0000-4000-8000-0000000000b0', '{"name": "Zz84 Undo B", "category": "Bedroom", "units_per_purchase": 6, "purchase_unit": "pack"}'::jsonb, null, null, null)$$);
insert into _t select 'k1', pg_temp.try(format($q$select public.reconcile_inventory_baseline_v1(%L, 21, 'typo test', 'zz84-count-key-0001')$q$, (select v->>'item_id' from _t where k = 'ua')));
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a3');
insert into _t select 'x_admin', pg_temp.try(format($q$select public.inventory_undo_v1(%L)$q$, (select v->>'movementId' from _t where k = 'k1')));
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'x_own', pg_temp.try(format($q$select public.inventory_undo_v1(%L)$q$, (select v->>'movementId' from _t where k = 'k1')));
insert into _t select 'x_rep', pg_temp.try(format($q$select public.inventory_undo_v1(%L)$q$, (select v->>'movementId' from _t where k = 'k1')));
reset role;
select is((select v->>'reason' from _t where k = 'x_admin'), 'not_yours', 'undo: another person''s count is not_yours');
select is((select v from _t where k = 'x_own'), jsonb_build_object('ok', true, 'item_id', (select v->>'item_id' from _t where k = 'ua'), 'qty', 12.00), 'undo: your own count within 15 minutes puts the quantity back');
select is((select qty_on_hand from public.inventory_items where id = (select (v->>'item_id')::uuid from _t where k = 'ua')), 12.00, 'and the item holds it');
select is((select v->>'replayed' from _t where k = 'x_rep'), 'true', 'undo: a repeat is answered, not applied twice');
select is((select count(*)::int from public.inventory_stock_movements where item_id = (select (v->>'item_id')::uuid from _t where k = 'ua') and kind = 'adjustment'
  and idempotency_key = 'stk-undo-' || replace((select v->>'movementId' from _t where k = 'k1'), '-', '') and reason like 'Undo in the staff app of reconcile%'), 1, 'undo: the ledger gets one adjustment row, nothing is deleted');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'k2', pg_temp.try(format($q$select public.reconcile_inventory_baseline_v1(%L, 22, 'typo test', 'zz84-count-key-0002')$q$, (select v->>'item_id' from _t where k = 'ua')));
insert into _t select 'k3', pg_temp.try(format($q$select public.reconcile_inventory_baseline_v1(%L, 23, 'typo test', 'zz84-count-key-0003')$q$, (select v->>'item_id' from _t where k = 'ua')));
insert into _t select 'x_moved', pg_temp.try(format($q$select public.inventory_undo_v1(%L)$q$, (select v->>'movementId' from _t where k = 'k2')));
insert into _t select 'k4', pg_temp.try(format($q$select public.reconcile_inventory_baseline_v1(%L, 30, 'typo test', 'zz84-count-key-0004')$q$, (select v->>'item_id' from _t where k = 'ua')));
reset role;
update public.inventory_stock_movements set created_at = now() - interval '16 minutes' where id = (select (v->>'movementId')::uuid from _t where k = 'k4');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'x_late', pg_temp.try(format($q$select public.inventory_undo_v1(%L)$q$, (select v->>'movementId' from _t where k = 'k4')));
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a1');
insert into _t select 'x_cl', pg_temp.try(format($q$select public.inventory_undo_v1(%L)$q$, (select v->>'movementId' from _t where k = 'k3')));
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a4');
insert into _t select 'x_fi', pg_temp.try(format($q$select public.inventory_undo_v1(%L)$q$, (select v->>'movementId' from _t where k = 'k3')));
reset role;
select is((select v->>'reason' from _t where k = 'x_moved'), 'stock_moved', 'undo: refused when a later change exists');
select is((select v->>'reason' from _t where k = 'x_late'), 'too_late', 'undo: refused after 15 minutes');
select is((select v->>'reason' from _t where k = 'x_cl'), 'not_yours', 'undo: a cleaner cannot undo someone else''s count (s85: refused as not_yours, was 42501)');
select is((select v->>'err' from _t where k = 'x_fi'), '42501', 'undo: finance is refused');

-- a receipt on a movement-controlled item: undo by purchase + movement deletes the app purchase
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'r1', pg_temp.try(format($q$select public.record_inventory_receipt_v1(%L, 1, null, null, null, null, null, 'zz84-recv-key-000001')$q$, (select v->>'item_id' from _t where k = 'ua')));
insert into _t select 'x_r1', pg_temp.try(format($q$select public.inventory_undo_v1(%L, %L)$q$, (select v->>'movementId' from _t where k = 'r1'), (select v->>'purchaseId' from _t where k = 'r1')));
insert into _t select 'x_r1b', pg_temp.try(format($q$select public.inventory_undo_v1(%L, %L)$q$, (select v->>'movementId' from _t where k = 'r1'), (select v->>'purchaseId' from _t where k = 'r1')));
reset role;
select is((select (v->>'qty')::numeric from _t where k = 'x_r1'), 30.00, 'undo receipt (controlled): the quantity is back');
select is((select count(*)::int from public.inventory_purchases where id = (select (v->>'purchaseId')::uuid from _t where k = 'r1')), 0, 'and that purchase row is gone');
select is((select v->>'replayed' from _t where k = 'x_r1b'), 'true', 'a repeat is answered even though the purchase is gone');

-- a receipt on an item that is not movement-controlled, linked to a shopping row
insert into public.inventory_shopping_list(id, property_id, item_id, item_name, quantity, status, idempotency_key) values
  ('d8400000-0000-4000-8000-0000000000e1', 'd8400000-0000-4000-8000-0000000000b0', (select (v->>'item_id')::uuid from _t where k = 'ub'), 'Zz84 Undo B', 2, 'approved', 'zz84-shop-key-000001');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'r2', pg_temp.try(format($q$select public.record_inventory_receipt_v1(%L, 2, null, null, null, null, 'd8400000-0000-4000-8000-0000000000e1', 'zz84-recv-key-000002')$q$, (select v->>'item_id' from _t where k = 'ub')));
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a3');
insert into _t select 'x_r2a', pg_temp.try(format($q$select public.inventory_undo_v1(p_purchase_id => %L)$q$, (select v->>'purchaseId' from _t where k = 'r2')));
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'x_r2', pg_temp.try(format($q$select public.inventory_undo_v1(p_purchase_id => %L)$q$, (select v->>'purchaseId' from _t where k = 'r2')));
reset role;
select is((select qty_on_hand from public.inventory_items where id = (select (v->>'item_id')::uuid from _t where k = 'ub')), 0.00, 'undo receipt (uncontrolled): after the receive and the undo the quantity is 0 again');
select is((select v->>'reason' from _t where k = 'x_r2a'), 'not_yours', 'undo receipt: refused for someone who did not receive that shopping row');
select ok((select v->>'ok' = 'true' from _t where k = 'x_r2'), 'undo receipt: the person who received it can undo it');
select ok((select s.status = 'approved' and s.purchase_id is null and s.received_by is null and s.received_quantity is null from public.inventory_shopping_list s where s.id = 'd8400000-0000-4000-8000-0000000000e1'),
  'and the shopping row is back to approved with its received fields cleared');
insert into public.inventory_purchases(id, item_id, qty, unit_cost, notes) values
  ('d8400000-0000-4000-8000-0000000000e2', (select (v->>'item_id')::uuid from _t where k = 'ub'), 3, 10, 'Auto-restock from receipt OCR (txn zz84)');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'x_ocr', pg_temp.try($$select public.inventory_undo_v1(p_purchase_id => 'd8400000-0000-4000-8000-0000000000e2')$$);
reset role;
select is((select v->>'reason' from _t where k = 'x_ocr'), 'not_undoable', 'undo: a Telegram OCR purchase is never undone here');
select is((select count(*)::int from public.inventory_purchases where id = 'd8400000-0000-4000-8000-0000000000e2'), 1, 'and it is still there');

-- =============================================================================================================================================
-- Part 9 (phase 1b): catalogue countedAt
-- =============================================================================================================================================
insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor)
values ('inventory_items', (select (v->>'item_id')::uuid from _t where k = 'ub'), 'telegram_count', '{"qty_on_hand": 0}'::jsonb, '{"qty_on_hand": 2}'::jsonb, 'telegram:1:owner');
update public.inventory_audit_log set created_at = now() - interval '1 day' where entity_id = (select (v->>'item_id')::uuid from _t where k = 'ub') and action = 'telegram_count';
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a1');
insert into _t select 'c2_cl', pg_temp.try($$select public.get_inventory_catalogue_v1('d8400000-0000-4000-8000-0000000000b0')$$);
reset role;
select is((select (e->>'countedAt')::timestamptz from _t, jsonb_array_elements(v->'items') e where k = 'c2_cl' and e->>'id' = (select v->>'item_id' from _t where k = 'ua')),
  (select max(created_at) from public.inventory_stock_movements where item_id = (select (v->>'item_id')::uuid from _t where k = 'ua') and kind = 'reconcile'), 'countedAt is the latest app count (any role sees it)');
select is((select (e->>'countedAt')::timestamptz from _t, jsonb_array_elements(v->'items') e where k = 'c2_cl' and e->>'id' = (select v->>'item_id' from _t where k = 'ub')),
  (select max(created_at) from public.inventory_audit_log where entity_id = (select (v->>'item_id')::uuid from _t where k = 'ub') and action = 'telegram_count'), 'and a Telegram count counts');
select is((select e->'countedAt' from _t, jsonb_array_elements(v->'items') e where k = 'c2_cl' and e->>'id' = 'd8400000-0000-4000-8000-0000000000c1'), 'null'::jsonb, 'an item never counted has countedAt null');

-- =============================================================================================================================================
-- Part 10 (phase 1b): inventory_item_history_v1
-- =============================================================================================================================================
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'h0', pg_temp.try(format($q$select public.inventory_item_history_v1(%L)$q$, (select v->>'item_id' from _t where k = 'ua')));
reset role;
select ok((select v->'usage'->'per_clean' = 'null'::jsonb and (v->'usage'->>'cleans_30d')::int = 0 from _t where k = 'h0'), 'history: per_clean is null with no cleans');
insert into public.cleaning_sessions(submission_id, cleaner_name, property_id, cleaning_type, submitted_by_user_id) values
  ('zz84-h-1', 'Zzhoney', 'd8400000-0000-4000-8000-0000000000b0', 'turnover', 'd8400000-0000-4000-8000-0000000000a1'),
  ('zz84-h-2', 'Zzhoney', 'd8400000-0000-4000-8000-0000000000b0', 'deep_clean', 'd8400000-0000-4000-8000-0000000000a1');
insert into public.inventory_usage(property_id, item_id, used_qty, session_date) select 'd8400000-0000-4000-8000-0000000000b0'::uuid, (select (v->>'item_id')::uuid from _t where k = 'ua'), q, public.manila_today() from unnest(array[3, 1]) q;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a1');
insert into _t select 'h1', pg_temp.try(format($q$select public.inventory_item_history_v1(%L)$q$, (select v->>'item_id' from _t where k = 'ua')));
insert into _t select 'h_cl_b', pg_temp.try(format($q$select public.inventory_item_history_v1(%L)$q$, (select v->>'item_id' from _t where k = 'ub')));
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a4');
insert into _t select 'h_fi_b', pg_temp.try(format($q$select public.inventory_item_history_v1(%L)$q$, (select v->>'item_id' from _t where k = 'ub')));
reset role;
select ok((select (v->'usage'->>'cleans_30d')::int = 2 and (v->'usage'->>'cleans_14d')::int = 2 and (v->'usage'->>'used_30d')::numeric = 4 and (v->'usage'->>'per_clean')::numeric = 2.00 from _t where k = 'h1'),
  'history: a cleaner sees use per clean (4 used over 2 cleans = 2.00)');
select ok((select (v->'changes') @> '[{"kind": "counted"}]'::jsonb and (v->'changes') @> '[{"kind": "undo"}]'::jsonb and (v->'changes') @> '[{"kind": "received"}]'::jsonb from _t where k = 'h1'),
  'history: the changes name counted, undo and received');
select is((select v->'changes'->0->>'who' from _t where k = 'h1'), 'Zz84-Owner', 'history: who is a first name only');
select ok((select v ? 'last_bought' and not (v->'last_bought' ? 'unit_cost') and (v->'last_bought'->>'qty')::numeric = 3 from _t where k = 'h_cl_b'), 'history: a cleaner sees the last purchase without its price');
select is((select (v->'last_bought'->>'unit_cost')::numeric from _t where k = 'h_fi_b'), 10.00, 'history: finance sees the price');
select ok((select v->'changes'->0->>'kind' = 'telegram_count' and v->'changes'->0->'who' = 'null'::jsonb and jsonb_array_length(v->'changes') = 1 from _t where k = 'h_cl_b'), 'history: a Telegram count is listed with no name');
insert into public.inventory_items(id, property_id, name, category, qty_on_hand, movement_controlled_at) values
  ('d8400000-0000-4000-8000-0000000000c9', 'd8400000-0000-4000-8000-0000000000b0', 'Zz84 Filler', 'Bedroom', 1, now());
insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key, created_at)
select 'd8400000-0000-4000-8000-0000000000c9', 'd8400000-0000-4000-8000-0000000000b0', 'reconcile', 1, 1, 'zz84 filler', 'd8400000-0000-4000-8000-0000000000a5', 'zz84-fill-key-' || lpad(n::text, 4, '0'), now() - (n || ' minutes')::interval
from generate_series(1, 12) n;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a1');
insert into _t select 'h_f', pg_temp.try($$select public.inventory_item_history_v1('d8400000-0000-4000-8000-0000000000c9')$$);
insert into _t select 'h_bad', pg_temp.try($$select public.inventory_item_history_v1('d8400000-0000-4000-8000-0000000000ff')$$);
reset role;
select ok((select jsonb_array_length(v->'changes') = 10 and (v->'changes'->0->>'at')::timestamptz > (v->'changes'->9->>'at')::timestamptz from _t where k = 'h_f'), 'history: at most 10 changes, newest first');
select is((select v->>'err' from _t where k = 'h_bad'), 'P0002', 'history: an unknown item is not found');

-- =============================================================================================================================================
-- Part 11 (phase 1b): the weekly low-stock task
-- =============================================================================================================================================
create function pg_temp.low(p_status text default null) returns integer language sql as $$
  select count(*)::int from public.follow_up_tasks where property_id = 'd8400000-0000-4000-8000-0000000000b0' and source_kind = 'low_stock' and (p_status is null or status = p_status);
$$;
-- "Zz84 Plain" (reorder 2, quantity 0) was added in Part 4, so the property is already low by one item
select is(pg_temp.low('open'), 1, 'low-stock task: one open task for the week while something is low');
select is((select title from public.follow_up_tasks where property_id = 'd8400000-0000-4000-8000-0000000000b0' and source_kind = 'low_stock' and status = 'open'), 'Restock: 1 item is low', 'with the count in its title');
insert into public.inventory_items(id, property_id, name, category, qty_on_hand, reorder_below, is_consumable) values
  ('d8400000-0000-4000-8000-0000000000d9', 'd8400000-0000-4000-8000-0000000000b0', 'Zz84 Second low', 'Cleaning', 1, 2, true);
select is(pg_temp.low(), 1, 'low-stock task: a second low item does not add a second row');
select is((select title from public.follow_up_tasks where property_id = 'd8400000-0000-4000-8000-0000000000b0' and source_kind = 'low_stock' and status = 'open'), 'Restock: 2 items are low', 'but the title is refreshed');
select ok((select t.detail like '%Zz84 Second low%' and t.detail !~* '(php|cost|price|peso)' and t.title !~* '(php|cost|price|peso)' and t.assignee_user_id is null and t.priority = 'normal'
  from public.follow_up_tasks t where t.property_id = 'd8400000-0000-4000-8000-0000000000b0' and t.source_kind = 'low_stock'), 'low-stock task: names the items, no money text, unassigned');
update public.inventory_items set qty_on_hand = 50 where property_id = 'd8400000-0000-4000-8000-0000000000b0' and name in ('Zz84 Plain', 'Zz84 Second low');
select ok((select t.status = 'done' and t.completion_note = 'Closed automatically: nothing is low now.' from public.follow_up_tasks t where t.property_id = 'd8400000-0000-4000-8000-0000000000b0' and t.source_kind = 'low_stock'),
  'low-stock task: restocking closes it by itself');
update public.inventory_items set qty_on_hand = 0 where id = 'd8400000-0000-4000-8000-0000000000d9';
select ok(pg_temp.low() = 1 and pg_temp.low('open') = 1, 'low-stock task: going low again the same week reopens the same row');
update public.follow_up_tasks set source_ref = '2020-W01:d8400000-0000-4000-8000-0000000000b0', idempotency_key = 'system:low_stock:2020-W01:d8400000-0000-4000-8000-0000000000b0' where property_id = 'd8400000-0000-4000-8000-0000000000b0' and source_kind = 'low_stock';
update public.inventory_items set qty_on_hand = 0 where id = 'd8400000-0000-4000-8000-0000000000d9';
select ok(pg_temp.low() = 2 and pg_temp.low('open') = 1 and exists (select 1 from public.follow_up_tasks where property_id = 'd8400000-0000-4000-8000-0000000000b0' and source_ref like '2020-W01%' and status = 'done' and completion_note like 'Closed automatically: this week%'),
  'low-stock task: a new week gets a new row and the old week''s row is closed');
create or replace function public.system_task_open_v1(p_property_id uuid, p_source_kind text, p_source_ref text, p_title text, p_detail text default null, p_priority text default 'normal')
returns uuid language plpgsql as $$ begin raise exception 'zz84 task function is down'; end $$;
select lives_ok($$update public.inventory_items set qty_on_hand = 1 where id = 'd8400000-0000-4000-8000-0000000000d9'$$, 'low-stock task: a failing task function never blocks an inventory update (warning only)');
select is((select qty_on_hand from public.inventory_items where id = 'd8400000-0000-4000-8000-0000000000d9'), 1.00, 'and the update went through');

-- grants of the new functions
select ok(not (has_function_privilege('anon', 'public.inventory_undo_v1(uuid,uuid)', 'execute') or has_function_privilege('anon', 'public.inventory_item_history_v1(uuid)', 'execute'))
  and has_function_privilege('authenticated', 'public.inventory_undo_v1(uuid,uuid)', 'execute') and has_function_privilege('authenticated', 'public.inventory_item_history_v1(uuid)', 'execute'),
  'anon executes neither new RPC; signed-in users execute both (each gates itself)');
select ok(not (has_function_privilege('authenticated', 'public.s_inventory_low_task_v1()', 'execute') or has_function_privilege('anon', 'public.s_inventory_low_task_v1()', 'execute') or has_function_privilege('service_role', 'public.s_inventory_low_task_v1()', 'execute'))
  and (select bool_and(prosecdef and proconfig @> array['search_path=""']) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('inventory_undo_v1', 'inventory_item_history_v1', 's_inventory_low_task_v1')),
  'the trigger function has no grant to anyone; all three are definer with an empty search_path');
select ok(exists (select 1 from pg_trigger where tgrelid = 'public.inventory_items'::regclass and tgname = 's_inventory_low_task' and not tgisinternal and (tgtype & 1) = 0), 'the trigger is a statement-level trigger on inventory_items');

-- =============================================================================================================================================
-- Part 12: record_inventory_receipt_v1 refuses a shopping row that is no longer approved
-- =============================================================================================================================================
insert into public.inventory_shopping_list(id, property_id, item_id, item_name, quantity, status, idempotency_key) values
  ('d8400000-0000-4000-8000-0000000000e3', 'd8400000-0000-4000-8000-0000000000b0', (select (v->>'item_id')::uuid from _t where k = 'ub'), 'Zz84 Undo B', 1, 'approved', 'zz84-shop-key-000003'),
  ('d8400000-0000-4000-8000-0000000000e4', 'd8400000-0000-4000-8000-0000000000b0', (select (v->>'item_id')::uuid from _t where k = 'ub'), 'Zz84 Undo B', 1, 'cancelled', 'zz84-shop-key-000004');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a5');
insert into _t select 'q1', pg_temp.try(format($q$select public.record_inventory_receipt_v1(%L, 1, null, null, null, null, 'd8400000-0000-4000-8000-0000000000e3', 'zz84-recv-key-000011')$q$, (select v->>'item_id' from _t where k = 'ub')));
insert into _t select 'q2', pg_temp.try(format($q$select public.record_inventory_receipt_v1(%L, 1, null, null, null, null, 'd8400000-0000-4000-8000-0000000000e3', 'zz84-recv-key-000011')$q$, (select v->>'item_id' from _t where k = 'ub')));
insert into _t select 'q3', pg_temp.try(format($q$select public.record_inventory_receipt_v1(%L, 1, null, null, null, null, 'd8400000-0000-4000-8000-0000000000e3', 'zz84-recv-key-000012')$q$, (select v->>'item_id' from _t where k = 'ub')));
insert into _t select 'q4', pg_temp.try(format($q$select public.record_inventory_receipt_v1(%L, 1, null, null, null, null, 'd8400000-0000-4000-8000-0000000000e4', 'zz84-recv-key-000013')$q$, (select v->>'item_id' from _t where k = 'ub')));
insert into _t select 'q5', pg_temp.try(format($q$select public.record_inventory_receipt_v1(%L, 1, null, null, null, null, 'd8400000-0000-4000-8000-0000000000ee', 'zz84-recv-key-000014')$q$, (select v->>'item_id' from _t where k = 'ub')));
reset role;
select ok((select v->>'ok' = 'true' and v ? 'purchaseId' from _t where k = 'q1'), 'receipt: the first receipt on an approved shopping row is accepted');
select ok((select v->>'replayed' = 'true' and v->>'purchaseId' = (select v->>'purchaseId' from _t where k = 'q1') from _t where k = 'q2'), 'receipt: the same idempotency key still replays the original result');
select is((select v from _t where k = 'q3'), '{"ok": false, "reason": "already_received"}'::jsonb, 'receipt: a second receipt on the same row is refused');
select is((select v->>'reason' from _t where k = 'q4'), 'not_open', 'receipt: a cancelled row is refused (not_open)');
select is((select v->>'reason' from _t where k = 'q5'), 'not_open', 'receipt: a shopping row that does not exist is refused (not_open)');
select is((select qty_on_hand from public.inventory_items where id = (select (v->>'item_id')::uuid from _t where k = 'ub')), 6.00, 'receipt: only the first receipt added stock (1 pack of 6)');
select is((select count(*)::int from public.inventory_purchases where notes like '%zz84-recv-key-00001%' and item_id = (select (v->>'item_id')::uuid from _t where k = 'ub')), 1, 'and only one purchase row was written');

select * from finish();
rollback;
