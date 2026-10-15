-- Session 86, lane D-sql: release s86_inventory_db_20261020. Suppliers, supplier links, price basis (qty and unit_cost per base unit on both write paths), price history
-- and the price-jump rule, photo path RPC, recategorise, QR code mint, the service_role writers, the catalogue's new keys, the cleaner's read of where to buy
-- (never a price, a phone or a note). Hermetic apart from Part 1, which reads the migration's own backfill on the restored production copy (rehearsal only).
-- Fixtures: uuids d8600000-... on a property of their own. Everything rolls back.
-- The md5 guard at the head of the migration cannot run inside pgTAP; the rehearsal proves it separately (a tampered body stops the apply with SQLSTATE 55000).
begin;
select plan(170);

-- baseline grants for a --no-acl rehearsal restore (idempotent, rolled back with the suite)
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt(), auth.role() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal1', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_service() returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true), set_config('role', 'service_role', true);
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

-- =============================================================================================================================================
-- Part 1: the migration's own data work on the restored production copy (read before any fixture is added)
-- =============================================================================================================================================
select is((select array_agg(name order by name) from public.inventory_suppliers where created_by is null), array['KCC', 'Robinsons', 'SM']::text[], 'backfill: exactly the three shops SM, KCC and Robinsons were created from purchases');
select ok(not exists (select 1 from public.inventory_purchases where supplier is not null and btrim(supplier) <> '' and supplier_id is null), 'backfill: every purchase with a supplier name is linked');
select ok(not exists (select 1 from public.inventory_purchases where lower(btrim(supplier)) = 'test'), 'the test purchase is deleted');
select ok(not exists (select 1 from public.inventory_items where category in ('Cleaning', 'Utility / Cleaning / Bathroom', 'Guest Supplies')), 'category tidy: none of the three old names remain');
select is((select count(distinct category)::int from public.inventory_items), 7, 'category tidy: seven categories');
select ok((select count(*) from public.inventory_audit_log where action = 'category_tidy_s86' and actor = 'migration') > 0, 'category tidy: every moved item has an audit row');

-- =============================================================================================================================================
-- Part 2: grants, shapes and the storage limits (static)
-- =============================================================================================================================================
select ok(not (has_function_privilege('anon', 'public.inventory_supplier_list_v1(uuid)', 'execute') or has_function_privilege('anon', 'public.inventory_supplier_save_v1(uuid,jsonb,text)', 'execute')
  or has_function_privilege('anon', 'public.inventory_supplier_detail_v1(uuid)', 'execute') or has_function_privilege('anon', 'public.inventory_item_supplier_link_v1(uuid,uuid,jsonb)', 'execute')
  or has_function_privilege('anon', 'public.inventory_item_supplier_unlink_v1(uuid,uuid)', 'execute') or has_function_privilege('anon', 'public.inventory_price_history_v1(uuid)', 'execute')
  or has_function_privilege('anon', 'public.inventory_item_photo_set_v1(uuid,text)', 'execute') or has_function_privilege('anon', 'public.inventory_items_recategorize_v1(uuid,uuid[],text)', 'execute')
  or has_function_privilege('anon', 'public.inventory_code_mint_v1(uuid,uuid[])', 'execute') or has_function_privilege('anon', 'public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid)', 'execute')),
  'anon executes none of R1-R9 or the 9-argument receipt');
select ok(has_function_privilege('authenticated', 'public.inventory_supplier_list_v1(uuid)', 'execute') and has_function_privilege('authenticated', 'public.inventory_supplier_save_v1(uuid,jsonb,text)', 'execute')
  and has_function_privilege('authenticated', 'public.inventory_supplier_detail_v1(uuid)', 'execute') and has_function_privilege('authenticated', 'public.inventory_item_supplier_link_v1(uuid,uuid,jsonb)', 'execute')
  and has_function_privilege('authenticated', 'public.inventory_item_supplier_unlink_v1(uuid,uuid)', 'execute') and has_function_privilege('authenticated', 'public.inventory_price_history_v1(uuid)', 'execute')
  and has_function_privilege('authenticated', 'public.inventory_item_photo_set_v1(uuid,text)', 'execute') and has_function_privilege('authenticated', 'public.inventory_items_recategorize_v1(uuid,uuid[],text)', 'execute')
  and has_function_privilege('authenticated', 'public.inventory_code_mint_v1(uuid,uuid[])', 'execute') and has_function_privilege('authenticated', 'public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid)', 'execute'),
  'signed-in users execute R1-R9 and the receipt (each gates itself)');
select ok(not (has_function_privilege('service_role', 'public.inventory_supplier_list_v1(uuid)', 'execute') or has_function_privilege('service_role', 'public.inventory_price_history_v1(uuid)', 'execute')
  or has_function_privilege('service_role', 'public.inventory_code_mint_v1(uuid,uuid[])', 'execute') or has_function_privilege('service_role', 'public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid)', 'execute')),
  'the signed-in RPCs are not executable by service_role');
select ok(has_function_privilege('service_role', 'public.apply_inventory_purchase(uuid,numeric,numeric,text,date,uuid,uuid)', 'execute') and has_function_privilege('service_role', 'public.s_inventory_supplier_create_v1(uuid,text,text)', 'execute')
  and has_function_privilege('service_role', 'public.s_inventory_supplier_alias_v1(uuid,text)', 'execute') and has_function_privilege('service_role', 'public.s_inventory_purchase_supplier_set_v1(uuid[],uuid)', 'execute')
  and has_function_privilege('service_role', 'public.s_inventory_item_category_auto_v1(uuid,text,numeric)', 'execute') and has_function_privilege('service_role', 'public.s_inventory_supplier_resolve_v1(uuid,text)', 'execute'),
  'service_role executes the OCR restock, R10-R12, the categoriser write and the resolver');
select ok(not (has_function_privilege('authenticated', 'public.apply_inventory_purchase(uuid,numeric,numeric,text,date,uuid,uuid)', 'execute') or has_function_privilege('anon', 'public.apply_inventory_purchase(uuid,numeric,numeric,text,date,uuid,uuid)', 'execute')
  or has_function_privilege('authenticated', 'public.s_inventory_supplier_create_v1(uuid,text,text)', 'execute') or has_function_privilege('authenticated', 'public.s_inventory_supplier_alias_v1(uuid,text)', 'execute')
  or has_function_privilege('authenticated', 'public.s_inventory_purchase_supplier_set_v1(uuid[],uuid)', 'execute') or has_function_privilege('authenticated', 'public.s_inventory_item_category_auto_v1(uuid,text,numeric)', 'execute')
  or has_function_privilege('anon', 'public.s_inventory_supplier_resolve_v1(uuid,text)', 'execute') or has_function_privilege('authenticated', 'public.s_inventory_supplier_resolve_v1(uuid,text)', 'execute')),
  'no signed-in or anon role executes the OCR restock, R10-R12, the categoriser write or the resolver');
select ok(not (has_function_privilege('authenticated', 'public.s_inventory_price_jump_v1(uuid)', 'execute') or has_function_privilege('anon', 'public.s_inventory_price_jump_v1(uuid)', 'execute') or has_function_privilege('service_role', 'public.s_inventory_price_jump_v1(uuid)', 'execute')),
  'the price-jump helper has no grant to anyone');
select ok((select bool_and(prosecdef and proconfig @> array['search_path=""']) from pg_proc where pronamespace = 'public'::regnamespace
  and proname in ('apply_inventory_purchase', 'record_inventory_receipt_v1', 'inventory_supplier_list_v1', 'inventory_supplier_save_v1', 'inventory_supplier_detail_v1', 'inventory_item_supplier_link_v1',
    'inventory_item_supplier_unlink_v1', 'inventory_price_history_v1', 'inventory_item_photo_set_v1', 'inventory_items_recategorize_v1', 'inventory_code_mint_v1', 's_inventory_supplier_create_v1',
    's_inventory_supplier_alias_v1', 's_inventory_purchase_supplier_set_v1', 's_inventory_item_category_auto_v1', 's_inventory_supplier_resolve_v1', 's_inventory_price_jump_v1', 'get_inventory_catalogue_v1')),
  'all new and redefined functions are definer with an empty search_path (apply_inventory_purchase was invoker rights)');
select ok(to_regprocedure('public.apply_inventory_purchase(uuid,numeric,numeric,text,date,uuid)') is null and to_regprocedure('public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text)') is null,
  'the 6- and 8-argument signatures are dropped (no PGRST203 overload)');
select ok(not (has_table_privilege('anon', 'public.inventory_suppliers', 'select') or has_table_privilege('authenticated', 'public.inventory_suppliers', 'select')
  or has_table_privilege('anon', 'public.inventory_item_suppliers', 'select') or has_table_privilege('authenticated', 'public.inventory_item_suppliers', 'select')
  or has_table_privilege('authenticated', 'public.inventory_suppliers', 'insert') or has_table_privilege('authenticated', 'public.inventory_item_suppliers', 'update'))
  and (select bool_and(relrowsecurity) from pg_class where oid in ('public.inventory_suppliers'::regclass, 'public.inventory_item_suppliers'::regclass)),
  'both new tables: RLS on, no client grants');
select ok(not has_table_privilege('anon', 'public.price_history_by_item', 'select') and has_table_privilege('authenticated', 'public.price_history_by_item', 'select')
  and not has_table_privilege('authenticated', 'public.price_history_by_item', 'insert') and not has_table_privilege('authenticated', 'public.price_history_by_item', 'update')
  and not has_table_privilege('authenticated', 'public.price_history_by_item', 'delete'), 'price_history_by_item: anon has nothing, authenticated reads only');
select ok(has_column_privilege('authenticated', 'public.inventory_items', 'location', 'select') and not has_column_privilege('authenticated', 'public.inventory_items', 'unit_cost', 'select'), 'location is readable by signed-in users, unit_cost still is not');
select ok(not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'inventory_purchases'), 'inventory_purchases is not in the realtime publication (vacuously true where the publication does not exist)');
select ok(not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'inv photos anon%'), 'no inv photos anon policy remains (vacuously true where storage does not exist)');
insert into _t select 'bucket', pg_temp.try($$select to_jsonb(b) from storage.buckets b where b.id = 'inventory-photos'$$);
select ok((select v ->> 'err' = '42P01' from _t where k = 'bucket') or (select coalesce((v ->> 'file_size_limit')::bigint = 1048576 and v -> 'allowed_mime_types' = '["image/jpeg", "image/webp"]'::jsonb and (v ->> 'public')::boolean is not true, false) from _t where k = 'bucket'),
  'the photos bucket: 1 MB limit, jpeg and webp only, not public (skipped where the storage schema does not exist)');

-- storage stand-in for a rehearsal copy (rolled back with the suite)
do $$
begin
  if to_regclass('storage.objects') is null then
    create schema if not exists storage;
    create table storage.buckets(id text primary key, name text, public boolean default false, file_size_limit bigint, allowed_mime_types text[]);
    create table storage.objects(id uuid default gen_random_uuid(), bucket_id text, name text);
  end if;
  insert into storage.buckets(id, name) values ('inventory-photos', 'inventory-photos') on conflict (id) do nothing;
end $$;

-- =============================================================================================================================================
-- Fixtures
-- =============================================================================================================================================
insert into auth.users(id, email) values
  ('d8600000-0000-4000-8000-0000000000a1', 'zz86-honey@example.com'), ('d8600000-0000-4000-8000-0000000000a3', 'zz86-admin@example.com'),
  ('d8600000-0000-4000-8000-0000000000a4', 'zz86-finance@example.com'), ('d8600000-0000-4000-8000-0000000000a5', 'zz86-owner@example.com');
insert into public.staff_access_profiles(user_id, role) values
  ('d8600000-0000-4000-8000-0000000000a1', 'cleaner'), ('d8600000-0000-4000-8000-0000000000a3', 'admin'),
  ('d8600000-0000-4000-8000-0000000000a4', 'finance'), ('d8600000-0000-4000-8000-0000000000a5', 'owner');
insert into public.properties(id, name, is_active) values ('d8600000-0000-4000-8000-0000000000b0', 'Zz S86 fixture property', true), ('d8600000-0000-4000-8000-0000000000b1', 'Zz S86 other property', true);
insert into public.staff_property_access(user_id, property_id) select u, 'd8600000-0000-4000-8000-0000000000b0'
  from unnest(array['d8600000-0000-4000-8000-0000000000a1', 'd8600000-0000-4000-8000-0000000000a3', 'd8600000-0000-4000-8000-0000000000a4', 'd8600000-0000-4000-8000-0000000000a5']::uuid[]) u;
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, reorder_below, is_consumable, unit_cost, units_per_purchase, purchase_unit) values
  ('d8600000-0000-4000-8000-0000000000c1', 'd8600000-0000-4000-8000-0000000000b0', 'Zz86 Soap', 'Toiletries', 'pc', 5, 2, true, 95.00, 1, null),
  ('d8600000-0000-4000-8000-0000000000c2', 'd8600000-0000-4000-8000-0000000000b0', 'Zz86 Towel', 'Bedroom', 'pc', 8, null, false, null, 1, null),
  ('d8600000-0000-4000-8000-0000000000c3', 'd8600000-0000-4000-8000-0000000000b0', 'Zz86 Rice', 'Pantry', 'pc', 0, null, true, null, 12, 'pack'),
  ('d8600000-0000-4000-8000-0000000000c4', 'd8600000-0000-4000-8000-0000000000b0', 'Zz86 Mop', 'Uncategorised', 'pc', 1, null, false, null, 1, null),
  ('d8600000-0000-4000-8000-0000000000c5', 'd8600000-0000-4000-8000-0000000000b0', 'Zz86 Scanned', 'Cleaning Supplies', 'pc', 3, null, true, null, 1, null),
  ('d8600000-0000-4000-8000-0000000000c0', 'd8600000-0000-4000-8000-0000000000b1', 'Zz86 Elsewhere', 'Other', 'pc', 1, null, true, null, 1, null),
  ('d8600000-0000-4000-8000-0000000000d1', 'd8600000-0000-4000-8000-0000000000b0', 'Zz86 Jump A', 'Zz86J', 'pc', 1, null, true, null, 1, null),
  ('d8600000-0000-4000-8000-0000000000d2', 'd8600000-0000-4000-8000-0000000000b0', 'Zz86 Jump B', 'Zz86J', 'pc', 1, null, true, null, 1, null),
  ('d8600000-0000-4000-8000-0000000000d3', 'd8600000-0000-4000-8000-0000000000b0', 'Zz86 Jump C', 'Zz86J', 'pc', 1, null, true, null, 1, null),
  ('d8600000-0000-4000-8000-0000000000d4', 'd8600000-0000-4000-8000-0000000000b0', 'Zz86 Jump D', 'Zz86J', 'pc', 1, null, true, null, 1, null);
insert into public.inventory_item_codes(property_id, item_id, code, format, created_by) values
  ('d8600000-0000-4000-8000-0000000000b0', 'd8600000-0000-4000-8000-0000000000c5', '4800000000086', 'ean_13', 'd8600000-0000-4000-8000-0000000000a5');
insert into public.inventory_suppliers(id, property_id, name, aliases, phone, location, maps_url, payment_method, notes, is_active) values
  ('d8600000-0000-4000-8000-0000000000e1', 'd8600000-0000-4000-8000-0000000000b0', 'Zz86 Alpha Mart', array['zz alpha', 'zz86 alpha mart'], '0917 000 0001', 'Mall A, ground floor', 'https://maps.example.com/alpha', 'cash', 'soap 90 a bottle', true),
  ('d8600000-0000-4000-8000-0000000000e2', 'd8600000-0000-4000-8000-0000000000b0', 'Zz86 Beta Shop', array['zz beta'], null, 'Market lane', null, 'gcash', null, true),
  ('d8600000-0000-4000-8000-0000000000e3', 'd8600000-0000-4000-8000-0000000000b0', 'Zz86 Gone Store', array['zz gone'], null, null, null, null, null, false),
  ('d8600000-0000-4000-8000-0000000000e4', 'd8600000-0000-4000-8000-0000000000b1', 'Zz86 Far Away', array['zz far'], null, null, null, null, null, true);
insert into public.inventory_item_suppliers(item_id, supplier_id, pack_label, quoted_pack_price, is_preferred) values
  ('d8600000-0000-4000-8000-0000000000c1', 'd8600000-0000-4000-8000-0000000000e1', 'bottle', 90.00, true);

-- price history fixtures (inserted as the test owner). Days are relative to the Manila date the functions use.
insert into public.inventory_purchases(item_id, purchased_at, qty, unit_cost, supplier, supplier_id, notes, created_at, units_per_purchase)
select v.item, public.manila_today() - v.days, v.qty, v.cost, v.sname, v.sid, v.note, now() - make_interval(days => v.days), 1
from (values
  ('d8600000-0000-4000-8000-0000000000d1'::uuid, 40, 1::numeric, 10.00::numeric, 'Zz86 Alpha Mart', 'd8600000-0000-4000-8000-0000000000e1'::uuid, null::text),
  ('d8600000-0000-4000-8000-0000000000d1'::uuid, 30, 1, 10.00, 'Zz86 Alpha Mart', 'd8600000-0000-4000-8000-0000000000e1'::uuid, null),
  ('d8600000-0000-4000-8000-0000000000d1'::uuid, 5, 1, 12.00, 'Zz86 Alpha Mart', 'd8600000-0000-4000-8000-0000000000e1'::uuid, 'Admin receipt [key:zz86-jump-a-key-0001]'),
  ('d8600000-0000-4000-8000-0000000000d2'::uuid, 30, 1, 10.00, 'Zz86 Alpha Mart', 'd8600000-0000-4000-8000-0000000000e1'::uuid, null),
  ('d8600000-0000-4000-8000-0000000000d2'::uuid, 5, 1, 12.00, 'Zz86 Alpha Mart', 'd8600000-0000-4000-8000-0000000000e1'::uuid, null),
  ('d8600000-0000-4000-8000-0000000000d3'::uuid, 40, 1, 10.00, null, null, null),
  ('d8600000-0000-4000-8000-0000000000d3'::uuid, 30, 1, 10.00, null, null, null),
  ('d8600000-0000-4000-8000-0000000000d3'::uuid, 5, 1, 11.90, null, null, null),
  ('d8600000-0000-4000-8000-0000000000d4'::uuid, 200, 100, 5.00, 'Zz86 Alpha Mart', 'd8600000-0000-4000-8000-0000000000e1'::uuid, null),
  ('d8600000-0000-4000-8000-0000000000d4'::uuid, 100, 10, 10.00, 'Zz86 Alpha Mart', 'd8600000-0000-4000-8000-0000000000e1'::uuid, null),
  ('d8600000-0000-4000-8000-0000000000d4'::uuid, 20, 30, 20.00, 'Zz86 Beta Shop', 'd8600000-0000-4000-8000-0000000000e2'::uuid, 'Auto-restock from receipt OCR (txn zz86)')
) v(item, days, qty, cost, sname, sid, note);

-- =============================================================================================================================================
-- Part 3: the cleaner (Honey): where to buy, never a price, a phone or a note
-- =============================================================================================================================================
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a1');
insert into _t select 'cl_r1', pg_temp.try($$select public.inventory_supplier_list_v1('d8600000-0000-4000-8000-0000000000b0')$$);
insert into _t select 'cl_r2', pg_temp.try($$select public.inventory_supplier_save_v1('d8600000-0000-4000-8000-0000000000b0', '{"name": "Zz86 Cleaner Shop"}'::jsonb)$$);
insert into _t select 'cl_r3', pg_temp.try($$select public.inventory_supplier_detail_v1('d8600000-0000-4000-8000-0000000000e1')$$);
insert into _t select 'cl_r4', pg_temp.try($$select public.inventory_item_supplier_link_v1('d8600000-0000-4000-8000-0000000000c2', 'd8600000-0000-4000-8000-0000000000e1', '{"preferred": true}'::jsonb)$$);
insert into _t select 'cl_r5', pg_temp.try($$select public.inventory_item_supplier_unlink_v1('d8600000-0000-4000-8000-0000000000c1', 'd8600000-0000-4000-8000-0000000000e1')$$);
insert into _t select 'cl_r6', pg_temp.try($$select public.inventory_price_history_v1('d8600000-0000-4000-8000-0000000000d1')$$);
insert into _t select 'cl_r8', pg_temp.try($$select public.inventory_items_recategorize_v1('d8600000-0000-4000-8000-0000000000b0', array['d8600000-0000-4000-8000-0000000000c2']::uuid[], 'Zz86 Nope')$$);
insert into _t select 'cl_r9', pg_temp.try($$select public.inventory_code_mint_v1('d8600000-0000-4000-8000-0000000000b0', array['d8600000-0000-4000-8000-0000000000c2']::uuid[])$$);
insert into _t select 'cl_tab', pg_temp.try($$select to_jsonb(count(*)) from (select 1 from public.inventory_suppliers) x$$);
insert into _t select 'cl_tab2', pg_temp.try($$select to_jsonb(count(*)) from (select 1 from public.inventory_item_suppliers) x$$);
insert into _t select 'cl_loc', pg_temp.try($$select to_jsonb(count(*)) from (select location from public.inventory_items) x$$);
insert into _t select 'cl_cost', pg_temp.try($$select to_jsonb(count(*)) from (select unit_cost from public.inventory_items) x$$);
insert into _t select 'cl_cat', pg_temp.try($$select public.get_inventory_catalogue_v1('d8600000-0000-4000-8000-0000000000b0')$$);
reset role;
select is((select array(select k from (select distinct jsonb_object_keys(e) k from _t, jsonb_array_elements(v -> 'suppliers') e where _t.k = 'cl_r1') q order by k)), array['active', 'id', 'location', 'maps_url', 'name']::text[],
  'R1 as the cleaner returns exactly id, name, location, maps_url, active');
select is((select jsonb_array_length(v -> 'suppliers') from _t where k = 'cl_r1'), 3, 'R1 lists the three shops of the property (the other property''s shop is not shown)');
select ok((select v::text !~* '(phone|payment|notes|0917|soap 90|last_bought|items)' from _t where k = 'cl_r1'), 'R1 as the cleaner holds no phone, payment, notes (they may hold prices), item counts or dates');
select is((select v ->> 'err' from _t where k = 'cl_r2'), '42501', 'R2 as the cleaner is refused');
select is((select v ->> 'err' from _t where k = 'cl_r3'), '42501', 'R3 as the cleaner is refused');
select is((select v ->> 'err' from _t where k = 'cl_r4'), '42501', 'R4 as the cleaner is refused');
select is((select v ->> 'err' from _t where k = 'cl_r5'), '42501', 'R5 as the cleaner is refused');
select is((select v ->> 'err' from _t where k = 'cl_r6'), '42501', 'R6 as the cleaner is refused');
select is((select v ->> 'err' from _t where k = 'cl_r8'), '42501', 'R8 as the cleaner is refused');
select is((select v ->> 'err' from _t where k = 'cl_r9'), '42501', 'R9 as the cleaner is refused');
select is((select v ->> 'err' from _t where k = 'cl_tab'), '42501', 'the cleaner cannot select inventory_suppliers directly');
select is((select v ->> 'err' from _t where k = 'cl_tab2'), '42501', 'nor inventory_item_suppliers');
select ok((select not (v ? 'err') from _t where k = 'cl_loc'), 'the cleaner can select location from inventory_items');
select is((select v ->> 'err' from _t where k = 'cl_cost'), '42501', 'but unit_cost is still refused');
select is((select e -> 'supplier' from _t, jsonb_array_elements(v -> 'items') e where k = 'cl_cat' and e ->> 'id' = 'd8600000-0000-4000-8000-0000000000c1'),
  jsonb_build_object('id', 'd8600000-0000-4000-8000-0000000000e1', 'name', 'Zz86 Alpha Mart', 'location', 'Mall A, ground floor'), 'the cleaner''s catalogue names the preferred shop with its place and nothing else');
select ok((select bool_and(not (e ? 'lastPrice') and not (e ? 'priceUp')) from _t, jsonb_array_elements(v -> 'items') e where k = 'cl_cat'), 'the cleaner''s catalogue has no lastPrice or priceUp key on any item');
select ok((select bool_and(e -> 'unitCost' = 'null'::jsonb) from _t, jsonb_array_elements(v -> 'items') e where k = 'cl_cat'), 'and still no unitCost value');
select ok((select e -> 'supplier' is null and e ? 'location' from _t, jsonb_array_elements(v -> 'items') e where k = 'cl_cat' and e ->> 'id' = 'd8600000-0000-4000-8000-0000000000c2'), 'an item with no shop has no supplier key; every item carries location');
select ok((select e::text !~* '(phone|0917|soap 90)' from _t, jsonb_array_elements(v -> 'items') e where k = 'cl_cat' and e ->> 'id' = 'd8600000-0000-4000-8000-0000000000c1'), 'the cleaner''s item holds no phone or note');
select is((select e -> 'supplier' ->> 'name' from _t, jsonb_array_elements(v -> 'items') e where k = 'cl_cat' and e ->> 'id' = 'd8600000-0000-4000-8000-0000000000d4'), 'Zz86 Beta Shop', 'with no preferred link the shop of the newest purchase is shown');

-- =============================================================================================================================================
-- Part 4: finance sees prices and shops; edits shops; cannot link, recategorise or mint
-- =============================================================================================================================================
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a4');
insert into _t select 'fi_r1', pg_temp.try($$select public.inventory_supplier_list_v1('d8600000-0000-4000-8000-0000000000b0')$$);
insert into _t select 'fi_r2', pg_temp.try($$select public.inventory_supplier_save_v1('d8600000-0000-4000-8000-0000000000b0', '{"name": "Zz86 Finance Shop", "phone": "0917 555 0100", "payment": "cash"}'::jsonb)$$);
insert into _t select 'fi_r3', pg_temp.try($$select public.inventory_supplier_detail_v1('d8600000-0000-4000-8000-0000000000e1')$$);
insert into _t select 'fi_r4', pg_temp.try($$select public.inventory_item_supplier_link_v1('d8600000-0000-4000-8000-0000000000c2', 'd8600000-0000-4000-8000-0000000000e1', '{"preferred": true}'::jsonb)$$);
insert into _t select 'fi_r6', pg_temp.try($$select public.inventory_price_history_v1('d8600000-0000-4000-8000-0000000000d1')$$);
insert into _t select 'fi_r8', pg_temp.try($$select public.inventory_items_recategorize_v1('d8600000-0000-4000-8000-0000000000b0', array['d8600000-0000-4000-8000-0000000000c2']::uuid[], 'Zz86 Nope')$$);
insert into _t select 'fi_r9', pg_temp.try($$select public.inventory_code_mint_v1('d8600000-0000-4000-8000-0000000000b0', array['d8600000-0000-4000-8000-0000000000c2']::uuid[])$$);
insert into _t select 'fi_cat', pg_temp.try($$select public.get_inventory_catalogue_v1('d8600000-0000-4000-8000-0000000000b0')$$);
reset role;
select ok((select v -> 'suppliers' -> 0 ? 'phone' and v -> 'suppliers' -> 0 ? 'payment' and v -> 'suppliers' -> 0 ? 'notes' and v -> 'suppliers' -> 0 ? 'items' and v -> 'suppliers' -> 0 ? 'last_bought_at' from _t where k = 'fi_r1'), 'R1 as finance returns the full detail');
select is((select (e ->> 'items')::int from _t, jsonb_array_elements(v -> 'suppliers') e where k = 'fi_r1' and e ->> 'id' = 'd8600000-0000-4000-8000-0000000000e1'), 4, 'R1 counts the distinct items linked or bought at Alpha Mart (c1 linked; d1, d2, d4 bought)');
select ok((select v ->> 'ok' = 'true' and v ? 'supplier_id' and v -> 'before' = 'null'::jsonb from _t where k = 'fi_r2'), 'R2 as finance creates a shop (before is null)');
select ok((select v ->> 'ok' = 'true' and jsonb_array_length(v -> 'items') > 0 from _t where k = 'fi_r3'), 'R3 as finance reads a shop with its items');
select is((select v ->> 'err' from _t where k = 'fi_r4'), '42501', 'R4 as finance is refused (no manage_inventory)');
select is((select (v -> 'jump' ->> 'pct')::int from _t where k = 'fi_r6'), 20, 'R6 as finance: item A is flagged at +20 percent');
select is((select v ->> 'err' from _t where k = 'fi_r8'), '42501', 'R8 as finance is refused');
select is((select v ->> 'err' from _t where k = 'fi_r9'), '42501', 'R9 as finance is refused');
select is((select (e ->> 'lastPrice')::numeric from _t, jsonb_array_elements(v -> 'items') e where k = 'fi_cat' and e ->> 'id' = 'd8600000-0000-4000-8000-0000000000d1'), 12.00, 'finance''s catalogue carries lastPrice');
select is((select (e ->> 'priceUp')::int from _t, jsonb_array_elements(v -> 'items') e where k = 'fi_cat' and e ->> 'id' = 'd8600000-0000-4000-8000-0000000000d1'), 20, 'and priceUp for a flagged item');
select ok((select not (e ? 'priceUp') from _t, jsonb_array_elements(v -> 'items') e where k = 'fi_cat' and e ->> 'id' = 'd8600000-0000-4000-8000-0000000000d2'), 'priceUp is absent when not flagged');
select is((select (e ->> 'unitCost')::numeric from _t, jsonb_array_elements(v -> 'items') e where k = 'fi_cat' and e ->> 'id' = 'd8600000-0000-4000-8000-0000000000c1'), 95.00, 'finance still gets unitCost');

-- =============================================================================================================================================
-- Part 5: owner, R2 / R4 / R5
-- =============================================================================================================================================
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a5');
insert into _t select 'ow_c1', pg_temp.try($$select public.inventory_supplier_save_v1('d8600000-0000-4000-8000-0000000000b0', '{"name": " Zz86 Gamma Hub ", "location": "Pier", "maps_url": "https://maps.example.com/gamma", "aliases_add": ["ZZ Gamma", " zz gamma ", "Gamma Hub"]}'::jsonb, 'zz86-save-key-000001')$$);
insert into _t select 'ow_c2', pg_temp.try($$select public.inventory_supplier_save_v1('d8600000-0000-4000-8000-0000000000b0', '{"name": "zz86 GAMMA hub"}'::jsonb)$$);
insert into _t select 'ow_c3', pg_temp.try($$select public.inventory_supplier_save_v1('d8600000-0000-4000-8000-0000000000b0', '{"name": "zz86 gone store"}'::jsonb)$$);
insert into _t select 'ow_bad1', pg_temp.try($$select public.inventory_supplier_save_v1('d8600000-0000-4000-8000-0000000000b0', '{"id": "d8600000-0000-4000-8000-0000000000e2", "unit_cost": 5}'::jsonb)$$);
insert into _t select 'ow_bad2', pg_temp.try($$select public.inventory_supplier_save_v1('d8600000-0000-4000-8000-0000000000b0', '{"name": "Zz86 Bad Link", "maps_url": "http://insecure.example.com"}'::jsonb)$$);
insert into _t select 'ow_bad3', pg_temp.try($$select public.inventory_supplier_save_v1('d8600000-0000-4000-8000-0000000000b0', '{"name": "Zz86 Bad Pay", "payment": "bitcoin"}'::jsonb)$$);
insert into _t select 'ow_bad4', pg_temp.try($$select public.inventory_supplier_save_v1('d8600000-0000-4000-8000-0000000000b0', '{"id": "d8600000-0000-4000-8000-0000000000e4", "notes": "x"}'::jsonb)$$);
insert into _t select 'ow_p1', pg_temp.try($$select public.inventory_supplier_save_v1('d8600000-0000-4000-8000-0000000000b0', '{"id": "d8600000-0000-4000-8000-0000000000e2", "phone": "0918 111 2222", "active": false, "aliases_add": "BETA  "}'::jsonb)$$);
insert into _t select 'ow_p2', pg_temp.try($$select public.inventory_supplier_save_v1('d8600000-0000-4000-8000-0000000000b0', '{"id": "d8600000-0000-4000-8000-0000000000e2", "active": true}'::jsonb)$$);
reset role;
select ok((select v ->> 'ok' = 'true' from _t where k = 'ow_c1'), 'R2 as owner creates a shop');
select is((select name from public.inventory_suppliers where id = (select (v ->> 'supplier_id')::uuid from _t where k = 'ow_c1')), 'Zz86 Gamma Hub', 'the name is trimmed');
select is((select aliases from public.inventory_suppliers where id = (select (v ->> 'supplier_id')::uuid from _t where k = 'ow_c1')), array['gamma hub', 'zz gamma']::text[], 'aliases_add lower-cases, trims and de-duplicates');
select is((select v ->> 'reason' from _t where k = 'ow_c2'), 'name_exists', 'the same name again (any case) is name_exists');
select is((select v ->> 'supplier_id' from _t where k = 'ow_c2'), (select v ->> 'supplier_id' from _t where k = 'ow_c1'), 'and names the existing shop');
select ok((select v ->> 'reason' = 'name_exists' and (v ->> 'active')::boolean is false from _t where k = 'ow_c3'), 'an inactive shop of that name answers name_exists with active false');
select is((select v ->> 'err' from _t where k = 'ow_bad1'), '22023', 'a patch with a key outside the list (unit_cost) is 22023');
select is((select v ->> 'err' from _t where k = 'ow_bad2'), '22023', 'a map link that is not https is 22023');
select is((select v ->> 'err' from _t where k = 'ow_bad3'), '22023', 'a payment method outside the list is 22023');
select is((select v ->> 'err' from _t where k = 'ow_bad4'), 'P0002', 'patching a shop of another property is not found');
select is((select v -> 'before' from _t where k = 'ow_p1'), jsonb_build_object('phone', null, 'active', true), 'a patch returns the old values of the patched keys');
select ok((select is_active and phone = '0918 111 2222' and 'beta' = any (aliases) from public.inventory_suppliers where id = 'd8600000-0000-4000-8000-0000000000e2'), 'and applies them (phone, alias, and active again after the second patch)');
select is((select v -> 'before' from _t where k = 'ow_p2'), jsonb_build_object('active', false), 'undo path: the before of the second patch restores active');

select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a5');
insert into _t select 'ln1', pg_temp.try($$select public.inventory_item_supplier_link_v1('d8600000-0000-4000-8000-0000000000c2', 'd8600000-0000-4000-8000-0000000000e1', '{"pack_label": "pack of 6", "pack_size": 6, "quoted_pack_price": 300, "preferred": true}'::jsonb)$$);
insert into _t select 'ln2', pg_temp.try($$select public.inventory_item_supplier_link_v1('d8600000-0000-4000-8000-0000000000c2', 'd8600000-0000-4000-8000-0000000000e2', '{"preferred": true}'::jsonb)$$);
insert into _t select 'ln3', pg_temp.try($$select public.inventory_item_supplier_link_v1('d8600000-0000-4000-8000-0000000000c2', 'd8600000-0000-4000-8000-0000000000e2', '{"unit_cost": 1}'::jsonb)$$);
insert into _t select 'ln4', pg_temp.try($$select public.inventory_item_supplier_link_v1('d8600000-0000-4000-8000-0000000000c2', 'd8600000-0000-4000-8000-0000000000e4', '{"preferred": true}'::jsonb)$$);
reset role;
select ok((select v ->> 'ok' = 'true' and v -> 'before' = 'null'::jsonb from _t where k = 'ln1'), 'R4 as owner links a shop (before is null for a new link)');
select is((select count(*)::int from public.inventory_item_suppliers where item_id = 'd8600000-0000-4000-8000-0000000000c2' and is_preferred), 1, 'exactly one preferred shop per item');
select is((select supplier_id::text from public.inventory_item_suppliers where item_id = 'd8600000-0000-4000-8000-0000000000c2' and is_preferred), 'd8600000-0000-4000-8000-0000000000e2', 'making another shop preferred moves the flag');
select is((select v -> 'before' ->> 'preferred' from _t where k = 'ln2'), null::text, 'a new link by R4 returns a null before (undo = R5)');
select is((select v ->> 'err' from _t where k = 'ln3'), '22023', 'R4 refuses a key outside the list');
select is((select v ->> 'err' from _t where k = 'ln4'), 'P0002', 'R4 refuses a shop of another property');
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a5');
insert into _t select 'un1', pg_temp.try($$select public.inventory_item_supplier_unlink_v1('d8600000-0000-4000-8000-0000000000c2', 'd8600000-0000-4000-8000-0000000000e2')$$);
insert into _t select 'un2', pg_temp.try($$select public.inventory_item_supplier_unlink_v1('d8600000-0000-4000-8000-0000000000c2', 'd8600000-0000-4000-8000-0000000000e2')$$);
reset role;
select ok((select (v ->> 'removed')::boolean and v -> 'before' ->> 'preferred' = 'true' from _t where k = 'un1'), 'R5 removes the link and returns the old values');
select ok((select not (v ->> 'removed')::boolean from _t where k = 'un2'), 'R5 on an absent link says removed false');
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a5');
insert into _t select 'ln5', pg_temp.try($$select public.inventory_item_supplier_link_v1('d8600000-0000-4000-8000-0000000000c2', 'd8600000-0000-4000-8000-0000000000e2', '{"pack_label": "x", "preferred": true}'::jsonb)$$);
reset role;
select ok((select v ->> 'ok' = 'true' from _t where k = 'ln5') and (select pack_label = 'x' and is_preferred from public.inventory_item_suppliers where item_id = 'd8600000-0000-4000-8000-0000000000c2' and supplier_id = 'd8600000-0000-4000-8000-0000000000e2'), 'R4 with the old values of R5 puts the link back');
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a5');
insert into _t select 'ln6', pg_temp.try($$select public.inventory_item_supplier_link_v1('d8600000-0000-4000-8000-0000000000c2', 'd8600000-0000-4000-8000-0000000000e2', '{"preferred": false}'::jsonb)$$);
insert into _t select 'ln7', pg_temp.try($$select public.inventory_item_supplier_link_v1('d8600000-0000-4000-8000-0000000000c2', 'd8600000-0000-4000-8000-0000000000e1', '{"pack_size": 6, "quoted_pack_price": 310}'::jsonb)$$);
reset role;
select ok((select v -> 'before' = '{"pack_label": "x", "pack_size": null, "preferred": true, "quoted_pack_price": null}'::jsonb from _t where k = 'ln6'), 'R4 returns the before for an existing link (owner also sees the quote)');
select ok((select quoted_pack_price = 310.00 and pack_size = 6 and pack_label = 'pack of 6' from public.inventory_item_suppliers where item_id = 'd8600000-0000-4000-8000-0000000000c2' and supplier_id = 'd8600000-0000-4000-8000-0000000000e1'), 'a partial patch keeps the other values of the link');

-- =============================================================================================================================================
-- Part 6: price basis on both write paths, the resolver, and the undo that reopens the shopping row
-- =============================================================================================================================================
insert into public.inventory_shopping_list(id, property_id, item_id, item_name, quantity, status, idempotency_key) values
  ('d8600000-0000-4000-8000-0000000000f1', 'd8600000-0000-4000-8000-0000000000b0', 'd8600000-0000-4000-8000-0000000000c3', 'Zz86 Rice', 1, 'approved', 'zz86-shop-key-000001');
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a5');
insert into _t select 'r1', pg_temp.try($$select public.record_inventory_receipt_v1('d8600000-0000-4000-8000-0000000000c3', 1, 120, 'Zz printed name', null, null, 'd8600000-0000-4000-8000-0000000000f1', 'zz86-recv-key-000001', 'd8600000-0000-4000-8000-0000000000e1')$$);
reset role;
select ok((select v ->> 'ok' = 'true' from _t where k = 'r1'), 'receipt: the 9-argument call with a supplier id works');
select is((select qty from public.inventory_purchases where id = (select (v ->> 'purchaseId')::uuid from _t where k = 'r1')), 12.00, 'receipt: 1 pack of 12 stores qty 12 base units');
select is((select unit_cost from public.inventory_purchases where id = (select (v ->> 'purchaseId')::uuid from _t where k = 'r1')), 10.00, 'receipt: pack price 120 stores unit_cost 10 per base unit');
select is((select supplier_id::text || '|' || supplier from public.inventory_purchases where id = (select (v ->> 'purchaseId')::uuid from _t where k = 'r1')), 'd8600000-0000-4000-8000-0000000000e1|Zz86 Alpha Mart', 'receipt: supplier_id set and the text column holds the supplier''s name');
select is((select supplier_id::text || '|' || supplier from public.inventory_shopping_list where id = 'd8600000-0000-4000-8000-0000000000f1'), 'd8600000-0000-4000-8000-0000000000e1|Zz86 Alpha Mart', 'receipt: the shopping row carries the supplier too');
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a5');
insert into _t select 'u1', pg_temp.try(format($q$select public.inventory_undo_v1(p_purchase_id => %L)$q$, (select v ->> 'purchaseId' from _t where k = 'r1')));
reset role;
select ok((select v ->> 'ok' = 'true' from _t where k = 'u1'), 'undo of the app receipt works');
select ok((select status = 'approved' and supplier is null and supplier_id is null from public.inventory_shopping_list where id = 'd8600000-0000-4000-8000-0000000000f1'), 'undo reopens the shopping row with supplier and supplier_id cleared');
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a5');
insert into _t select 'r2', pg_temp.try($$select public.record_inventory_receipt_v1('d8600000-0000-4000-8000-0000000000c3', 1, 120, 'ZZ Alpha', null, null, null, 'zz86-recv-key-000002')$$);
insert into _t select 'r3', pg_temp.try($$select public.record_inventory_receipt_v1('d8600000-0000-4000-8000-0000000000c3', 1, 120, 'Zz Unknown Mart', null, null, null, 'zz86-recv-key-000003')$$);
insert into _t select 'r4', pg_temp.try($$select public.record_inventory_receipt_v1('d8600000-0000-4000-8000-0000000000c3', 1, 120, 'Zz Gone', null, null, null, 'zz86-recv-key-000004', 'd8600000-0000-4000-8000-0000000000e4')$$);
reset role;
select is((select supplier_id::text from public.inventory_purchases where id = (select (v ->> 'purchaseId')::uuid from _t where k = 'r2')), 'd8600000-0000-4000-8000-0000000000e1', 'resolver: a printed alias (any case) is linked without an id');
select is((select supplier from public.inventory_purchases where id = (select (v ->> 'purchaseId')::uuid from _t where k = 'r2')), 'Zz86 Alpha Mart', 'and the text column becomes the canonical name');
select ok((select supplier_id is null and supplier = 'Zz Unknown Mart' from public.inventory_purchases where id = (select (v ->> 'purchaseId')::uuid from _t where k = 'r3')), 'resolver: an unknown name is not guessed; the text is kept, supplier_id is null');
select ok((select supplier_id is null and supplier = 'Zz Gone' from public.inventory_purchases where id = (select (v ->> 'purchaseId')::uuid from _t where k = 'r4')), 'a supplier id of another property is ignored, the printed name is kept');
select is(public.s_inventory_supplier_resolve_v1('d8600000-0000-4000-8000-0000000000b0', ' ZZ86 alpha MART '), 'd8600000-0000-4000-8000-0000000000e1'::uuid, 'resolver: exact name, any case, trimmed');
select is(public.s_inventory_supplier_resolve_v1('d8600000-0000-4000-8000-0000000000b0', 'zz beta'), 'd8600000-0000-4000-8000-0000000000e2'::uuid, 'resolver: alias');
select is(public.s_inventory_supplier_resolve_v1('d8600000-0000-4000-8000-0000000000b0', 'zz gone'), null::uuid, 'resolver: an inactive shop never matches');
select is(public.s_inventory_supplier_resolve_v1('d8600000-0000-4000-8000-0000000000b0', 'zz alph'), null::uuid, 'resolver: no fuzzy match');
select is(public.s_inventory_supplier_resolve_v1('d8600000-0000-4000-8000-0000000000b0', 'zz far'), null::uuid, 'resolver: another property''s alias does not match');

select pg_temp.as_service();
insert into _t select 'o1', pg_temp.try($$select public.apply_inventory_purchase('d8600000-0000-4000-8000-0000000000c3', 1, 120, 'ZZ ALPHA', current_date, null)$$);
insert into _t select 'o2', pg_temp.try($$select public.apply_inventory_purchase('d8600000-0000-4000-8000-0000000000c3', 1, 120, 'Zz Unknown Mart', current_date, null, 'd8600000-0000-4000-8000-0000000000e2')$$);
insert into _t select 'o3', pg_temp.try($$select public.apply_inventory_purchase(p_item_id => 'd8600000-0000-4000-8000-0000000000c3', p_qty => 2, p_unit_cost => 60, p_supplier => 'Zz Unknown Mart', p_purchased_at => current_date, p_txn_id => null)$$);
insert into _t select 'o4', pg_temp.try($$select public.apply_inventory_purchase('d8600000-0000-4000-8000-0000000000ff', 1, 120, 'x', current_date, null)$$);
reset role;
select ok((select v ->> 'ok' = 'true' and (v ->> 'added')::numeric = 12 from _t where k = 'o1'), 'OCR restock: 1 pack of 12 adds 12 units');
select is((select qty from public.inventory_purchases where id = (select (v ->> 'purchase_id')::uuid from _t where k = 'o1')), 12.00, 'OCR restock: the row stores qty 12 (base units), not 1 pack');
select is((select unit_cost from public.inventory_purchases where id = (select (v ->> 'purchase_id')::uuid from _t where k = 'o1')), 10.00, 'OCR restock: pack price 120 stores unit_cost 10 per base unit');
select is((select supplier_id::text || '|' || supplier from public.inventory_purchases where id = (select (v ->> 'purchase_id')::uuid from _t where k = 'o1')), 'd8600000-0000-4000-8000-0000000000e1|Zz86 Alpha Mart', 'OCR restock: the printed alias resolves to the shop');
select is((select supplier_id::text from public.inventory_purchases where id = (select (v ->> 'purchase_id')::uuid from _t where k = 'o2')), 'd8600000-0000-4000-8000-0000000000e2', 'OCR restock: an explicit supplier id wins over the printed name');
select ok((select supplier_id is null and supplier = 'Zz Unknown Mart' and qty = 24 and unit_cost = 5 from public.inventory_purchases where id = (select (v ->> 'purchase_id')::uuid from _t where k = 'o3')), 'OCR restock by named arguments (the bot''s call) works without the new argument: 2 packs of 12 at 60 a pack = qty 24, unit_cost 5');
select is((select v ->> 'error' from _t where k = 'o4'), 'item_not_found', 'OCR restock of an unknown item answers item_not_found as before');
select is((select qty_on_hand from public.inventory_items where id = 'd8600000-0000-4000-8000-0000000000c3'), 84.00, 'stock on hand matches the units added by every path (3 app receipts of 12, one undone, then 12 + 12 + 24 by OCR = 84)');
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a5');
insert into _t select 'oa_ow', pg_temp.try($$select public.apply_inventory_purchase('d8600000-0000-4000-8000-0000000000c3', 1, 120, 'x', current_date, null)$$);
reset role;
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a1');
insert into _t select 'oa_cl', pg_temp.try($$select public.apply_inventory_purchase('d8600000-0000-4000-8000-0000000000c3', 1, 120, 'x', current_date, null)$$);
insert into _t select 'res_cl', pg_temp.try($$select to_jsonb(public.s_inventory_supplier_resolve_v1('d8600000-0000-4000-8000-0000000000b0', 'zz alpha'))$$);
reset role;
select is((select v ->> 'err' from _t where k = 'oa_ow'), '42501', 'OCR restock as an owner session: permission denied (service_role only)');
select is((select v ->> 'err' from _t where k = 'oa_cl'), '42501', 'OCR restock as a cleaner session: permission denied');
select is((select v ->> 'err' from _t where k = 'res_cl'), '42501', 'the resolver as a signed-in user: permission denied');

-- R6 on the rice: both paths show per base unit 10 and per pack 120
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a4');
insert into _t select 'ph', pg_temp.try($$select public.inventory_price_history_v1('d8600000-0000-4000-8000-0000000000c3')$$);
reset role;
select ok((select bool_and((e ->> 'unit_price')::numeric = 10 and (e ->> 'pack_price')::numeric = 120) from _t, jsonb_array_elements(v -> 'rows') e where k = 'ph' and e ->> 'supplier_id' = 'd8600000-0000-4000-8000-0000000000e1'), 'R6: app and Telegram rows both show unit price 10 and pack price 120');
select ok((select array_agg(distinct e ->> 'source' order by e ->> 'source') = array['app', 'telegram'] from _t, jsonb_array_elements(v -> 'rows') e where k = 'ph'), 'R6: the source words are app and telegram');
select is((select v ->> 'units_per_purchase' from _t where k = 'ph'), '12.0000', 'R6 carries the item''s pack size and unit');

-- =============================================================================================================================================
-- Part 7: R6 rules (jump, weighted average, cheapest supplier first)
-- =============================================================================================================================================
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a5');
insert into _t select 'j1', pg_temp.try($$select public.inventory_price_history_v1('d8600000-0000-4000-8000-0000000000d1')$$);
insert into _t select 'j2', pg_temp.try($$select public.inventory_price_history_v1('d8600000-0000-4000-8000-0000000000d2')$$);
insert into _t select 'j3', pg_temp.try($$select public.inventory_price_history_v1('d8600000-0000-4000-8000-0000000000d3')$$);
insert into _t select 'j4', pg_temp.try($$select public.inventory_price_history_v1('d8600000-0000-4000-8000-0000000000d4')$$);
insert into _t select 'j5', pg_temp.try($$select public.inventory_price_history_v1('d8600000-0000-4000-8000-0000000000ff')$$);
reset role;
select is((select v -> 'jump' from _t where k = 'j1'), '{"pct": 20, "base": 10.0000}'::jsonb, 'jump: +20 percent over a median of 10 with two earlier purchases is flagged');
select is((select v -> 'jump' from _t where k = 'j2'), 'null'::jsonb, 'jump: one earlier purchase is not enough');
select is((select v -> 'jump' from _t where k = 'j3'), 'null'::jsonb, 'jump: +19 percent is not flagged');
select is((select (v -> 'jump' ->> 'pct')::int from _t where k = 'j4'), 167, 'jump: the base is the median of the earlier purchases inside 365 days (5 and 10 give 7.5)');
select is((select (v -> 'stats' ->> 'avg_180d')::numeric from _t where k = 'j4'), 17.5, 'stats: the 180-day average is weighted by quantity and leaves out the 200-day-old row');
select is((select (v -> 'stats' ->> 'min_365d')::numeric from _t where k = 'j4'), 5.00, 'stats: lowest in 365 days includes the 200-day-old row');
select is((select (v -> 'stats' ->> 'last')::numeric from _t where k = 'j4'), 20.00, 'stats: last is the newest price');
select is((select (v -> 'stats' ->> 'n')::int from _t where k = 'j4'), 3, 'stats: n counts the priced purchases');
select is((select array(select e ->> 'name' from _t, jsonb_array_elements(v -> 'by_supplier') e where k = 'j4')), array['Zz86 Alpha Mart', 'Zz86 Beta Shop']::text[], 'by_supplier: cheapest last price first');
select is((select (e ->> 'times')::int from _t, jsonb_array_elements(v -> 'by_supplier') e where k = 'j4' and e ->> 'name' = 'Zz86 Alpha Mart'), 2, 'by_supplier: times bought at that shop');
select is((select e ->> 'source' from _t, jsonb_array_elements(v -> 'rows') e where k = 'j1' and e ->> 'at' = (public.manila_today() - 5)::text), 'app', 'rows: a key-noted receipt is an app row');
select is((select e ->> 'source' from _t, jsonb_array_elements(v -> 'rows') e where k = 'j4' and (e ->> 'unit_price')::numeric = 20), 'telegram', 'rows: an OCR note is a telegram row');
select is((select e ->> 'source' from _t, jsonb_array_elements(v -> 'rows') e where k = 'j2' and (e ->> 'unit_price')::numeric = 10), 'old', 'rows: anything else is old');
select is((select jsonb_array_length(v -> 'rows') from _t where k = 'j4'), 3, 'rows: all priced purchases, newest first');
select is((select v ->> 'err' from _t where k = 'j5'), 'P0002', 'R6 on an unknown item is not found');

-- =============================================================================================================================================
-- Part 8: R7 photo path (every staff role), R8 recategorise, R9 mint, location through the update RPC
-- =============================================================================================================================================
insert into storage.objects(bucket_id, name) values ('inventory-photos', 'items/d8600000-0000-4000-8000-0000000000c1/d8600000-0000-4000-8000-000000000a01.webp');
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a1');
insert into _t select 'p_ok', pg_temp.try($$select public.inventory_item_photo_set_v1('d8600000-0000-4000-8000-0000000000c1', 'items/d8600000-0000-4000-8000-0000000000c1/d8600000-0000-4000-8000-000000000a01.webp')$$);
insert into _t select 'p_other', pg_temp.try($$select public.inventory_item_photo_set_v1('d8600000-0000-4000-8000-0000000000c2', 'items/d8600000-0000-4000-8000-0000000000c1/d8600000-0000-4000-8000-000000000a01.webp')$$);
insert into _t select 'p_missing', pg_temp.try($$select public.inventory_item_photo_set_v1('d8600000-0000-4000-8000-0000000000c1', 'items/d8600000-0000-4000-8000-0000000000c1/d8600000-0000-4000-8000-000000000a02.webp')$$);
insert into _t select 'p_shape', pg_temp.try($$select public.inventory_item_photo_set_v1('d8600000-0000-4000-8000-0000000000c1', 'items/d8600000-0000-4000-8000-0000000000c1/d8600000-0000-4000-8000-000000000a01.png')$$);
insert into _t select 'p_clear', pg_temp.try($$select public.inventory_item_photo_set_v1('d8600000-0000-4000-8000-0000000000c1', null)$$);
reset role;
select ok((select v ->> 'ok' = 'true' and v -> 'before' = 'null'::jsonb from _t where k = 'p_ok'), 'R7 as the cleaner sets a photo path (every staff role may) and returns the old path');
select is((select v ->> 'reason' from _t where k = 'p_other'), 'bad_path', 'R7: a path belonging to another item is bad_path');
select is((select v ->> 'reason' from _t where k = 'p_missing'), 'bad_path', 'R7: a path with no object in the bucket is bad_path');
select is((select v ->> 'reason' from _t where k = 'p_shape'), 'bad_path', 'R7: a wrong extension is bad_path');
select ok((select v ->> 'ok' = 'true' and v ->> 'before' like 'items/%' from _t where k = 'p_clear'), 'R7: null clears the path and returns the old one for Undo');
select is((select photo_path from public.inventory_items where id = 'd8600000-0000-4000-8000-0000000000c1'), null::text, 'and the item has no photo now');
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a1');
insert into _t select 'p_undo2', pg_temp.try($$select public.inventory_item_photo_set_v1('d8600000-0000-4000-8000-0000000000c1', 'items/d8600000-0000-4000-8000-0000000000c1/d8600000-0000-4000-8000-000000000a01.webp')$$);
reset role;
select ok((select v ->> 'ok' = 'true' from _t where k = 'p_undo2') and (select photo_path like 'items/%' from public.inventory_items where id = 'd8600000-0000-4000-8000-0000000000c1'), 'the cleaner''s Undo (R7 with the before) restores the photo');

select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a3');
insert into _t select 'rc1', pg_temp.try($$select public.inventory_items_recategorize_v1('d8600000-0000-4000-8000-0000000000b0', array['d8600000-0000-4000-8000-0000000000c1', 'd8600000-0000-4000-8000-0000000000c2', 'd8600000-0000-4000-8000-0000000000c1']::uuid[], '  Zz86 Merged ')$$);
insert into _t select 'rc_far', pg_temp.try($$select public.inventory_items_recategorize_v1('d8600000-0000-4000-8000-0000000000b0', array['d8600000-0000-4000-8000-0000000000c0']::uuid[], 'Zz86 Merged')$$);
insert into _t select 'rc_empty', pg_temp.try($$select public.inventory_items_recategorize_v1('d8600000-0000-4000-8000-0000000000b0', '{}'::uuid[], 'Zz86 Merged')$$);
insert into _t select 'rc_long', pg_temp.try($$select public.inventory_items_recategorize_v1('d8600000-0000-4000-8000-0000000000b0', array['d8600000-0000-4000-8000-0000000000c1']::uuid[], repeat('x', 61))$$);
reset role;
select is((select jsonb_array_length(v -> 'moved') from _t where k = 'rc1'), 2, 'R8: the admin merges two items (a repeated id counts once)');
select is((select array(select category from public.inventory_items where id in ('d8600000-0000-4000-8000-0000000000c1', 'd8600000-0000-4000-8000-0000000000c2'))), array['Zz86 Merged', 'Zz86 Merged']::text[], 'R8: both items are in the trimmed category');
select is((select e ->> 'before' from _t, jsonb_array_elements(v -> 'moved') e where k = 'rc1' and e ->> 'id' = 'd8600000-0000-4000-8000-0000000000c2'), 'Bedroom', 'R8 returns the old category per item');
select is((select v ->> 'err' from _t where k = 'rc_far'), '22023', 'R8: an item of another property is 22023');
select is((select v ->> 'err' from _t where k = 'rc_empty'), '22023', 'R8: an empty list is 22023');
select is((select v ->> 'err' from _t where k = 'rc_long'), '22023', 'R8: a category over 60 characters is 22023');
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a3');
insert into _t select 'rc_u1', pg_temp.try($$select public.inventory_items_recategorize_v1('d8600000-0000-4000-8000-0000000000b0', array['d8600000-0000-4000-8000-0000000000c1']::uuid[], 'Toiletries')$$);
insert into _t select 'rc_u2', pg_temp.try($$select public.inventory_items_recategorize_v1('d8600000-0000-4000-8000-0000000000b0', array['d8600000-0000-4000-8000-0000000000c2']::uuid[], 'Bedroom')$$);
reset role;
select is((select array(select category from public.inventory_items where id in ('d8600000-0000-4000-8000-0000000000c1', 'd8600000-0000-4000-8000-0000000000c2') order by name)), array['Toiletries', 'Bedroom']::text[], 'R8 undo: one call per distinct before category restores both groups');

select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a3');
insert into _t select 'm1', pg_temp.try($$select public.inventory_code_mint_v1('d8600000-0000-4000-8000-0000000000b0', array['d8600000-0000-4000-8000-0000000000c2', 'd8600000-0000-4000-8000-0000000000c5']::uuid[])$$);
insert into _t select 'm2', pg_temp.try($$select public.inventory_code_mint_v1('d8600000-0000-4000-8000-0000000000b0', array['d8600000-0000-4000-8000-0000000000c2', 'd8600000-0000-4000-8000-0000000000c5']::uuid[])$$);
reset role;
select is((select v -> 'minted' -> 0 ->> 'code' from _t where k = 'm1'), 'CH-' || upper(left(replace('d8600000-0000-4000-8000-0000000000c2', '-', ''), 10)), 'R9: the code is CH- plus the first ten hex characters of the item id');
select is((select jsonb_array_length(v -> 'minted') || '/' || (v ->> 'skipped') from _t where k = 'm1'), '1/1', 'R9: the item with a barcode is skipped');
select is((select format from public.inventory_item_codes where item_id = 'd8600000-0000-4000-8000-0000000000c2'), 'qr_code', 'R9: the format is qr_code');
select is((select jsonb_array_length(v -> 'minted') || '/' || (v ->> 'skipped') from _t where k = 'm2'), '0/2', 'R9: a second call mints nothing');
select is((select count(*)::int from public.inventory_item_codes where item_id = 'd8600000-0000-4000-8000-0000000000c5'), 1, 'R9: the barcode item still has only its barcode');

select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a5');
insert into _t select 'lo1', pg_temp.try($$select public.inventory_item_update_v1('d8600000-0000-4000-8000-0000000000c1', '{"location": "  Closet 2 "}'::jsonb)$$);
insert into _t select 'lo2', pg_temp.try($$select public.inventory_item_update_v1('d8600000-0000-4000-8000-0000000000c2', '{"location": "Closet 3", "par_qty": 4}'::jsonb)$$);
insert into _t select 'lo3', pg_temp.try($$select public.inventory_item_update_v1('d8600000-0000-4000-8000-0000000000c2', jsonb_build_object('location', repeat('x', 61)))$$);
insert into _t select 'lo4', pg_temp.try($$select public.inventory_item_update_v1('d8600000-0000-4000-8000-0000000000c2', '{"location": ""}'::jsonb)$$);
insert into _t select 'lo5', pg_temp.try($$select public.inventory_item_update_v1('d8600000-0000-4000-8000-0000000000c2', '{"unit_cost": 3}'::jsonb)$$);
reset role;
select is((select location from public.inventory_items where id = 'd8600000-0000-4000-8000-0000000000c1'), 'Closet 2', 'update: location is trimmed and saved');
select ok((select v ->> 'ok' = 'true' from _t where k = 'lo2') and (select par_qty = 4 from public.inventory_items where id = 'd8600000-0000-4000-8000-0000000000c2'), 'update: location and another key in one patch');
select is((select v ->> 'err' from _t where k = 'lo3'), '22023', 'update: a location over 60 characters is 22023');
select is((select location from public.inventory_items where id = 'd8600000-0000-4000-8000-0000000000c2'), null::text, 'update: an empty string clears the location');
select is((select v ->> 'err' from _t where k = 'lo5'), '22023', 'update: unit_cost is still not an allowed key');
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a1');
insert into _t select 'lo_cl', pg_temp.try($$select public.inventory_item_update_v1('d8600000-0000-4000-8000-0000000000c1', '{"location": "Nope"}'::jsonb)$$);
insert into _t select 'cat2', pg_temp.try($$select public.get_inventory_catalogue_v1('d8600000-0000-4000-8000-0000000000b0')$$);
reset role;
select is((select v ->> 'err' from _t where k = 'lo_cl'), '42501', 'update: a cleaner still cannot edit an item');
select is((select e ->> 'location' from _t, jsonb_array_elements(v -> 'items') e where k = 'cat2' and e ->> 'id' = 'd8600000-0000-4000-8000-0000000000c1'), 'Closet 2', 'the catalogue shows the location to the cleaner');
select is((select e ->> 'photo' from _t, jsonb_array_elements(v -> 'items') e where k = 'cat2' and e ->> 'id' = 'd8600000-0000-4000-8000-0000000000c1'), 'items/d8600000-0000-4000-8000-0000000000c1/d8600000-0000-4000-8000-000000000a01.webp', 'and the photo path (already in the catalogue since phase 1)');

-- the shop of the newest purchase is shown only while the shop is active
update public.inventory_suppliers set is_active = false where id = 'd8600000-0000-4000-8000-0000000000e2';
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a1');
insert into _t select 'cat3', pg_temp.try($$select public.get_inventory_catalogue_v1('d8600000-0000-4000-8000-0000000000b0')$$);
reset role;
select ok((select e -> 'supplier' ->> 'name' = 'Zz86 Alpha Mart' from _t, jsonb_array_elements(v -> 'items') e where k = 'cat3' and e ->> 'id' = 'd8600000-0000-4000-8000-0000000000d4'), 'a stopped shop is no longer shown: the newest purchase at a shop still in use is');

-- =============================================================================================================================================
-- Part 9: R10-R12 and the categoriser write (service_role only)
-- =============================================================================================================================================
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a5');
insert into _t select 's10', pg_temp.try($$select public.s_inventory_supplier_create_v1('d8600000-0000-4000-8000-0000000000b0', 'Zz86 Delta', 'ZZ DELTA STORE')$$);
insert into _t select 's11', pg_temp.try($$select public.s_inventory_supplier_alias_v1('d8600000-0000-4000-8000-0000000000e1', 'x alias')$$);
insert into _t select 's12', pg_temp.try($$select public.s_inventory_purchase_supplier_set_v1(array['d8600000-0000-4000-8000-0000000000ff']::uuid[], null)$$);
insert into _t select 's13', pg_temp.try($$select public.s_inventory_item_category_auto_v1('d8600000-0000-4000-8000-0000000000c4', 'Pantry', 0.9)$$);
reset role;
select is((select v ->> 'err' from _t where k = 's10'), '42501', 'R10 as an owner session: permission denied');
select is((select v ->> 'err' from _t where k = 's11'), '42501', 'R11 as an owner session: permission denied');
select is((select v ->> 'err' from _t where k = 's12'), '42501', 'R12 as an owner session: permission denied');
select is((select v ->> 'err' from _t where k = 's13'), '42501', 'the categoriser write as an owner session: permission denied');

select pg_temp.as_service();
insert into _t select 'sv1', pg_temp.try($$select public.s_inventory_supplier_create_v1('d8600000-0000-4000-8000-0000000000b0', 'Zz86 Delta', 'ZZ DELTA STORE')$$);
insert into _t select 'sv2', pg_temp.try($$select public.s_inventory_supplier_create_v1('d8600000-0000-4000-8000-0000000000b0', 'zz86 delta', 'zz delta 2')$$);
insert into _t select 'sv3', pg_temp.try($$select public.s_inventory_supplier_alias_v1((select (v ->> 'supplier_id')::uuid from _t where k = 'sv1'), '  Delta Three ')$$);
insert into _t select 'sv4', pg_temp.try($$select public.s_inventory_supplier_alias_v1((select (v ->> 'supplier_id')::uuid from _t where k = 'sv1'), 'delta three')$$);
insert into _t select 'sv5', pg_temp.try($$select public.s_inventory_supplier_alias_v1('d8600000-0000-4000-8000-0000000000ff', 'nobody')$$);
insert into _t select 'sv6', pg_temp.try(format($q$select public.s_inventory_purchase_supplier_set_v1(array[%L]::uuid[], %L)$q$, (select v ->> 'purchase_id' from _t where k = 'o3'), (select v ->> 'supplier_id' from _t where k = 'sv1')));
insert into _t select 'sv7', pg_temp.try(format($q$select public.s_inventory_purchase_supplier_set_v1(array[%L]::uuid[], null)$q$, (select v ->> 'purchase_id' from _t where k = 'o3')));
insert into _t select 'sv8', pg_temp.try(format($q$select public.s_inventory_purchase_supplier_set_v1(array[%L]::uuid[], null)$q$, (select v ->> 'purchaseId' from _t where k = 'r2')));
insert into _t select 'sv9', pg_temp.try(format($q$select public.s_inventory_purchase_supplier_set_v1(array[%L]::uuid[], 'd8600000-0000-4000-8000-0000000000e4')$q$, (select v ->> 'purchase_id' from _t where k = 'o3')));
reset role;
select ok((select (v ->> 'created')::boolean from _t where k = 'sv1'), 'R10: creates the shop');
select ok((select not (v ->> 'created')::boolean and v ->> 'supplier_id' = (select v ->> 'supplier_id' from _t where k = 'sv1') from _t where k = 'sv2'), 'R10: the same name again returns the existing shop');
select is((select aliases from public.inventory_suppliers where id = (select (v ->> 'supplier_id')::uuid from _t where k = 'sv1')), array['delta three', 'zz delta 2', 'zz delta store']::text[], 'R10 and R11 add lower-case aliases, de-duplicated');
select ok((select (v ->> 'ok')::boolean from _t where k = 'sv3') and (select (v ->> 'ok')::boolean from _t where k = 'sv4'), 'R11 is idempotent');
select is((select v ->> 'reason' from _t where k = 'sv5'), 'not_found', 'R11 on an unknown shop is not_found');
select ok((select (v ->> 'ok')::boolean and (v ->> 'changed')::int = 1 and v -> 'before' -> 0 ->> 'supplier' = 'Zz Unknown Mart' from _t where k = 'sv6'), 'R12: re-points an OCR purchase and returns the old supplier for Undo');
select is((select supplier from public.inventory_purchases where id = (select (v ->> 'purchase_id')::uuid from _t where k = 'o3')), null::text, 'R12 with null clears supplier_id and the text');
select is((select v ->> 'reason' from _t where k = 'sv8'), 'not_ocr', 'R12 refuses an app purchase');
select is((select v ->> 'reason' from _t where k = 'sv9'), 'supplier_not_found', 'R12 refuses a shop of another property');

select pg_temp.as_service();
insert into _t select 'ca1', pg_temp.try($$select public.s_inventory_item_category_auto_v1('d8600000-0000-4000-8000-0000000000c4', 'Pantry', 0.8)$$);
insert into _t select 'ca2', pg_temp.try($$select public.s_inventory_item_category_auto_v1('d8600000-0000-4000-8000-0000000000c4', 'Pantry', 0.8)$$);
insert into _t select 'ca3', pg_temp.try($$select public.s_inventory_item_category_auto_v1('d8600000-0000-4000-8000-0000000000c1', 'Pantry', 0.9)$$);
insert into _t select 'ca5', pg_temp.try($$select public.s_inventory_item_category_auto_v1('d8600000-0000-4000-8000-0000000000c4', 'Pantry', 1.5)$$);
reset role;
update public.inventory_items set category = 'Uncategorised' where id = 'd8600000-0000-4000-8000-0000000000c4';
select pg_temp.as_service();
insert into _t select 'ca4', pg_temp.try($$select public.s_inventory_item_category_auto_v1('d8600000-0000-4000-8000-0000000000c4', 'Made Up Category', 0.9)$$);
reset role;
select is((select v from _t where k = 'ca1'), jsonb_build_object('ok', true, 'item_id', 'd8600000-0000-4000-8000-0000000000c4', 'before', 'Uncategorised', 'after', 'Pantry'), 'categoriser write: an Uncategorised item moves into an existing category');
select is((select v ->> 'reason' from _t where k = 'ca2'), 'not_uncategorised', 'categoriser write: a second call finds it already sorted');
select is((select v ->> 'reason' from _t where k = 'ca3'), 'not_uncategorised', 'categoriser write: an item with a real category is never moved');
select is((select v ->> 'reason' from _t where k = 'ca4'), 'unknown_category', 'categoriser write: a category that does not exist is refused (it never creates one)');
select is((select v ->> 'err' from _t where k = 'ca5'), '22023', 'categoriser write: confidence above 1 is 22023');
select is((select count(*)::int from public.inventory_audit_log where entity_id = 'd8600000-0000-4000-8000-0000000000c4' and action = 'category_auto' and actor = 'jev' and (after ->> 'confidence')::numeric = 0.8 and before ->> 'category' = 'Uncategorised' and after ->> 'category' = 'Pantry'), 1, 'categoriser write: one audit row with before, after, confidence and actor jev');

-- =============================================================================================================================================
-- Part 10: anon, and the migration''s views
-- =============================================================================================================================================
select pg_temp.as_user('d8600000-0000-4000-8000-0000000000a5');
insert into _t select 'ov_view', pg_temp.try($$select to_jsonb(count(*)) from (select 1 from public.price_history_by_item limit 1) x$$);
reset role;
select ok((select not (v ? 'err') or v ->> 'err' = '42501' from _t where k = 'ov_view'), 'the price history view still answers signed-in users (or is refused only where a --no-acl restore lacks table grants)');
select is((select count(*)::int from pg_proc where pronamespace = 'public'::regnamespace and proname in ('apply_inventory_purchase', 'record_inventory_receipt_v1')), 2, 'exactly one overload of each redefined writer remains');

select * from finish();
rollback;
