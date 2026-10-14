-- Session 84, lane I-sql: release s84_inventory_20261017. The unit_cost leak (column grant, realtime), par_qty, barcode links, the catalogue's new par and
-- codes keys, item create / update / price RPCs. Hermetic: its own property and users (uuids d8400000-...), nothing else is touched. Everything rolls back.
-- The md5 guard at the head of the migration cannot run inside pgTAP; the rehearsal proves it by applying the migration to a database whose
-- get_inventory_catalogue_v1 body was changed first (expect SQLSTATE 55000 and nothing changed).
begin;
select plan(69);

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

select * from finish();
rollback;
