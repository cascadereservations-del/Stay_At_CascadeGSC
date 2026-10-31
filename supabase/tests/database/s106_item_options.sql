-- Session 106, lane SQL: release s106_item_options_20261109. Item options (brand/size choices under one stock item): table shape, no client grants, the two RPCs
-- (price hidden from a cleaner, gates, set-usual upserting the supplier link), and the Shopsuki seed. Part 1 reads the migration's own seed on the restored
-- production copy (rehearsal only, before any fixture is added). Fixtures use uuids d1060000-... on properties of their own; everything rolls back.
begin;
select plan(50);

-- baseline grants for a --no-acl rehearsal restore (idempotent, rolled back with the suite)
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt(), auth.role() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;

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
create temp table _t(k text primary key, v jsonb);
grant all on _t to public;

-- =============================================================================================================================================
-- Part 1: the seed on the restored production copy (8)
-- =============================================================================================================================================
select is((select count(*)::int from public.inventory_item_options where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'), 60, 'seed: 60 options');
select is((select count(distinct item_id)::int from public.inventory_item_options where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'), 18, 'seed: they belong to 18 items');
select is((select count(*)::int from (select item_id from public.inventory_item_options where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
            group by item_id having count(*) filter (where is_usual) = 1) q), 18, 'seed: every one of the 18 items has exactly one usual option');
select is((select count(*)::int from public.inventory_suppliers where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and lower(name) = 'shopsuki'), 1, 'seed: the Shopsuki supplier exists once');
select is((select count(*)::int from public.inventory_item_suppliers k join public.inventory_suppliers s on s.id = k.supplier_id
            where lower(s.name) = 'shopsuki' and k.is_preferred), 18, 'seed: 18 preferred links to Shopsuki');
select ok((select bool_and(k.quoted_pack_price = o.price and char_length(k.pack_label) between 1 and 40)
             from public.inventory_item_suppliers k join public.inventory_item_options o on o.item_id = k.item_id and o.supplier_id = k.supplier_id and o.is_usual
            where k.is_preferred), 'seed: each preferred link quotes the usual option price and has a pack label of at most 40 characters');
select is(public.s_inventory_item_options_seed_v1(), '{"suppliers": 0, "options": 0, "links": 0}'::jsonb, 'seed: running it again inserts nothing');
select ok((select count(*) from public.inventory_item_options where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd') = 60
          and (select count(*) from public.inventory_item_suppliers k join public.inventory_suppliers s on s.id = k.supplier_id where lower(s.name) = 'shopsuki') = 18, 'seed: counts are unchanged after the second run');

-- =============================================================================================================================================
-- Fixtures
-- =============================================================================================================================================
insert into auth.users(id, email) values
  ('d1060000-0000-4000-8000-0000000000a1', 'zz106-honey@example.com'), ('d1060000-0000-4000-8000-0000000000a3', 'zz106-admin@example.com'), ('d1060000-0000-4000-8000-0000000000a4', 'zz106-finance@example.com'),
  ('d1060000-0000-4000-8000-0000000000a5', 'zz106-owner@example.com');
insert into public.staff_access_profiles(user_id, role) values
  ('d1060000-0000-4000-8000-0000000000a1', 'cleaner'), ('d1060000-0000-4000-8000-0000000000a3', 'admin'), ('d1060000-0000-4000-8000-0000000000a4', 'finance'), ('d1060000-0000-4000-8000-0000000000a5', 'owner');
insert into public.properties(id, name, is_active) values ('d1060000-0000-4000-8000-0000000000b0', 'Zz S106 fixture property', true), ('d1060000-0000-4000-8000-0000000000b1', 'Zz S106 other property', true);
insert into public.staff_property_access(user_id, property_id) select u, 'd1060000-0000-4000-8000-0000000000b0'
  from unnest(array['d1060000-0000-4000-8000-0000000000a1', 'd1060000-0000-4000-8000-0000000000a3', 'd1060000-0000-4000-8000-0000000000a4', 'd1060000-0000-4000-8000-0000000000a5']::uuid[]) u;
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, reorder_below, is_consumable, unit_cost, units_per_purchase, purchase_unit) values
  ('d1060000-0000-4000-8000-0000000000c1', 'd1060000-0000-4000-8000-0000000000b0', 'Zz106 Soap', 'Toiletries', 'pc', 5, 2, true, null, 1, null),
  ('d1060000-0000-4000-8000-0000000000c0', 'd1060000-0000-4000-8000-0000000000b1', 'Zz106 Elsewhere', 'Other', 'pc', 1, null, true, null, 1, null);
insert into public.inventory_suppliers(id, property_id, name, payment_method) values
  ('d1060000-0000-4000-8000-0000000000e1', 'd1060000-0000-4000-8000-0000000000b0', 'Zz106 Shop A', 'online'),
  ('d1060000-0000-4000-8000-0000000000e2', 'd1060000-0000-4000-8000-0000000000b0', 'Zz106 Shop B', 'cash'),
  ('d1060000-0000-4000-8000-0000000000e4', 'd1060000-0000-4000-8000-0000000000b1', 'Zz106 Far Away', 'cash');
-- Shop B is the preferred shop of the item before any option is made usual
insert into public.inventory_item_suppliers(item_id, supplier_id, pack_label, quoted_pack_price, is_preferred) values
  ('d1060000-0000-4000-8000-0000000000c1', 'd1060000-0000-4000-8000-0000000000e2', 'bar', 80.00, true);
-- o1 120.00, o2 100.00 (usual, own pack label and size), o3 90.00; titles sort o1 < o3 < o2 for the cleaner's order
insert into public.inventory_item_options(id, property_id, item_id, supplier_id, title, brand, pack_label, pack_size, price, source_url, is_usual) values
  ('d1060000-0000-4000-8000-0000000000f1', 'd1060000-0000-4000-8000-0000000000b0', 'd1060000-0000-4000-8000-0000000000c1', 'd1060000-0000-4000-8000-0000000000e1',
   'Alpha Gel Fresh Refreshing Lemon Value Pack 180g x 2s', 'Alpha', null, null, 120.00, 'https://shopsuki.ph/products/zz106-o1', false),
  ('d1060000-0000-4000-8000-0000000000f2', 'd1060000-0000-4000-8000-0000000000b0', 'd1060000-0000-4000-8000-0000000000c1', 'd1060000-0000-4000-8000-0000000000e1',
   'Zeta Bar Soap 6 pack', 'Zeta', '6 x 90g', 6, 100.00, 'https://shopsuki.ph/products/zz106-o2', true),
  ('d1060000-0000-4000-8000-0000000000f3', 'd1060000-0000-4000-8000-0000000000b0', 'd1060000-0000-4000-8000-0000000000c1', 'd1060000-0000-4000-8000-0000000000e1',
   'Plain Soap 90g', 'Zz', null, null, 90.00, 'https://shopsuki.ph/products/zz106-o3', false),
  ('d1060000-0000-4000-8000-0000000000f4', 'd1060000-0000-4000-8000-0000000000b1', 'd1060000-0000-4000-8000-0000000000c0', 'd1060000-0000-4000-8000-0000000000e4',
   'Elsewhere Soap', 'Else', null, null, 50.00, 'https://shopsuki.ph/products/zz106-o4', false);

-- =============================================================================================================================================
-- Part 2: shape, constraints, grants (16)
-- =============================================================================================================================================
select has_table('public', 'inventory_item_options', 'the options table exists');
select columns_are('public', 'inventory_item_options', array['id', 'property_id', 'item_id', 'supplier_id', 'title', 'brand', 'pack_label', 'pack_size', 'price', 'image_url',
  'source_url', 'is_usual', 'available', 'captured_at', 'created_by', 'updated_at'], 'the options table has exactly the agreed columns');
select ok((select relrowsecurity from pg_class where oid = 'public.inventory_item_options'::regclass), 'row level security is on');
select ok(not exists (select 1 from unnest(array['anon', 'authenticated', 'service_role', 'public']) r, unnest(array['select', 'insert', 'update', 'delete']) p
                       where r <> 'public' and has_table_privilege(r, 'public.inventory_item_options', p)), 'no client or service role has any direct table privilege');
select ok(not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'inventory_item_options'),
  'not in the realtime publication (vacuously true where the publication does not exist)');
select is((select count(*)::int from pg_proc where oid in ('public.inventory_item_options_v1(uuid)'::regprocedure, 'public.inventory_item_option_set_usual_v1(uuid)'::regprocedure)
            and prosecdef and proconfig = array['search_path=""']), 2, 'both RPCs are security definer with an empty search_path');
select ok(has_function_privilege('authenticated', 'public.inventory_item_options_v1(uuid)', 'execute') and has_function_privilege('authenticated', 'public.inventory_item_option_set_usual_v1(uuid)', 'execute'),
  'authenticated may call both RPCs');
select ok(not has_function_privilege('anon', 'public.inventory_item_options_v1(uuid)', 'execute') and not has_function_privilege('anon', 'public.inventory_item_option_set_usual_v1(uuid)', 'execute')
          and not has_function_privilege('service_role', 'public.inventory_item_options_v1(uuid)', 'execute') and not has_function_privilege('service_role', 'public.inventory_item_option_set_usual_v1(uuid)', 'execute'),
  'anon and service_role may not call them');
select ok(not has_function_privilege('anon', 'public.s_inventory_item_options_seed_v1()', 'execute') and not has_function_privilege('authenticated', 'public.s_inventory_item_options_seed_v1()', 'execute')
          and not has_function_privilege('service_role', 'public.s_inventory_item_options_seed_v1()', 'execute'), 'the internal seed function has no grants');
select is(pg_temp.try($$insert into public.inventory_item_options(property_id, item_id, supplier_id, title, image_url) values ('d1060000-0000-4000-8000-0000000000b0', 'd1060000-0000-4000-8000-0000000000c1', 'd1060000-0000-4000-8000-0000000000e1', 'x', 'https://evil.example/a.jpg') returning to_jsonb(id)$$) ->> 'err', '23514', 'image_url must be on cdn.shopify.com');
select is(pg_temp.try($$insert into public.inventory_item_options(property_id, item_id, supplier_id, title, source_url) values ('d1060000-0000-4000-8000-0000000000b0', 'd1060000-0000-4000-8000-0000000000c1', 'd1060000-0000-4000-8000-0000000000e1', 'x', 'https://evil.example/p') returning to_jsonb(id)$$) ->> 'err', '23514', 'source_url must be shopsuki.ph or shopee.ph');
select is(pg_temp.try($$insert into public.inventory_item_options(property_id, item_id, supplier_id, title, price) values ('d1060000-0000-4000-8000-0000000000b0', 'd1060000-0000-4000-8000-0000000000c1', 'd1060000-0000-4000-8000-0000000000e1', 'x', 0) returning to_jsonb(id)$$) ->> 'err', '23514', 'price must be more than 0');
select is(pg_temp.try($$insert into public.inventory_item_options(property_id, item_id, supplier_id, title, pack_size) values ('d1060000-0000-4000-8000-0000000000b0', 'd1060000-0000-4000-8000-0000000000c1', 'd1060000-0000-4000-8000-0000000000e1', 'x', 100000) returning to_jsonb(id)$$) ->> 'err', '23514', 'pack_size must be below 100000');
select is(pg_temp.try($$insert into public.inventory_item_options(property_id, item_id, supplier_id, title) values ('d1060000-0000-4000-8000-0000000000b0', 'd1060000-0000-4000-8000-0000000000c1', 'd1060000-0000-4000-8000-0000000000e1', '  ') returning to_jsonb(id)$$) ->> 'err', '23514', 'a blank title is refused');
select is(pg_temp.try($$insert into public.inventory_item_options(property_id, item_id, supplier_id, title, source_url) values ('d1060000-0000-4000-8000-0000000000b0', 'd1060000-0000-4000-8000-0000000000c1', 'd1060000-0000-4000-8000-0000000000e1', 'dupe', 'https://shopsuki.ph/products/zz106-o1') returning to_jsonb(id)$$) ->> 'err', '23505', 'the same source_url twice for one item is refused');
select is(pg_temp.try($$insert into public.inventory_item_options(property_id, item_id, supplier_id, title, is_usual) values ('d1060000-0000-4000-8000-0000000000b0', 'd1060000-0000-4000-8000-0000000000c1', 'd1060000-0000-4000-8000-0000000000e1', 'second usual', true) returning to_jsonb(id)$$) ->> 'err', '23505', 'a second usual option for one item is refused');

-- =============================================================================================================================================
-- Part 3: reads and gates (13)
-- =============================================================================================================================================
select pg_temp.as_user('d1060000-0000-4000-8000-0000000000a5');
insert into _t select 'ow_l', pg_temp.try($$select public.inventory_item_options_v1('d1060000-0000-4000-8000-0000000000c1')$$);
reset role;
select pg_temp.as_user('d1060000-0000-4000-8000-0000000000a3');
insert into _t select 'ow_x', pg_temp.try($$select public.inventory_item_options_v1('d1060000-0000-4000-8000-0000000000c0')$$);
insert into _t select 'ow_y', pg_temp.try($$select public.inventory_item_option_set_usual_v1('d1060000-0000-4000-8000-0000000000f4')$$);
insert into _t select 'ow_z', pg_temp.try($$select public.inventory_item_option_set_usual_v1('d1060000-0000-4000-8000-0000000000ff')$$);
reset role;
select pg_temp.as_user('d1060000-0000-4000-8000-0000000000a1');
insert into _t select 'cl_l', pg_temp.try($$select public.inventory_item_options_v1('d1060000-0000-4000-8000-0000000000c1')$$);
insert into _t select 'cl_set', pg_temp.try($$select public.inventory_item_option_set_usual_v1('d1060000-0000-4000-8000-0000000000f1')$$);
insert into _t select 'cl_tab', pg_temp.try($$select to_jsonb(count(*)) from public.inventory_item_options$$);
reset role;
select pg_temp.as_user('d1060000-0000-4000-8000-0000000000a4');
insert into _t select 'fi_l', pg_temp.try($$select public.inventory_item_options_v1('d1060000-0000-4000-8000-0000000000c1')$$);
insert into _t select 'fi_set', pg_temp.try($$select public.inventory_item_option_set_usual_v1('d1060000-0000-4000-8000-0000000000f1')$$);
reset role;

select is((select array(select e ->> 'id' from _t, jsonb_array_elements(v -> 'options') with ordinality x(e, n) where k = 'ow_l' order by n)),
  array['d1060000-0000-4000-8000-0000000000f2', 'd1060000-0000-4000-8000-0000000000f3', 'd1060000-0000-4000-8000-0000000000f1'], 'owner: usual first, then cheapest first (100, 90, 120 -> usual, 90, 120)');
select ok((select bool_and(e ? 'price') from _t, jsonb_array_elements(v -> 'options') e where k = 'ow_l'), 'owner: every option carries its price');
select is((select (e ->> 'price')::numeric from _t, jsonb_array_elements(v -> 'options') e where k = 'ow_l' and e ->> 'id' = 'd1060000-0000-4000-8000-0000000000f3'), 90.00, 'owner: the price is the stored one (90.00)');
select is((select array(select e ->> 'id' from _t, jsonb_array_elements(v -> 'options') with ordinality x(e, n) where k = 'cl_l' order by n)),
  array['d1060000-0000-4000-8000-0000000000f2', 'd1060000-0000-4000-8000-0000000000f1', 'd1060000-0000-4000-8000-0000000000f3'], 'cleaner: usual first, then by title (no price order)');
select ok((select v::text !~ '"price"' and jsonb_array_length(v -> 'options') = 3 from _t where k = 'cl_l'), 'cleaner: three options and no price key anywhere');
select is((select v ->> 'err' from _t where k = 'cl_tab'), '42501', 'cleaner: cannot read the table directly');
select is((select v ->> 'err' from _t where k = 'cl_set'), '42501', 'cleaner: cannot set the usual option');
select ok((select bool_and(e ? 'price') from _t, jsonb_array_elements(v -> 'options') e where k = 'fi_l') and (select jsonb_array_length(v -> 'options') = 3 from _t where k = 'fi_l'), 'finance: reads all three options with price');
select is((select array(select e ->> 'id' from _t, jsonb_array_elements(v -> 'options') with ordinality x(e, n) where k = 'fi_l' order by n)),
  array['d1060000-0000-4000-8000-0000000000f2', 'd1060000-0000-4000-8000-0000000000f3', 'd1060000-0000-4000-8000-0000000000f1'], 'finance: same order as the owner');
select is((select v ->> 'err' from _t where k = 'fi_set'), '42501', 'finance: cannot set the usual option (no manage_inventory)');
select is((select v ->> 'err' from _t where k = 'ow_x'), '42501', 'admin scoped to one property: the options of another property item are refused');
select is((select v ->> 'err' from _t where k = 'ow_y'), '42501', 'admin scoped to one property: setting the usual option of another property is refused');
select is((select v ->> 'err' from _t where k = 'ow_z'), 'P0002', 'an unknown option id is not found');

-- =============================================================================================================================================
-- Part 4: set usual (13)
-- =============================================================================================================================================
select pg_temp.as_user('d1060000-0000-4000-8000-0000000000a5');
insert into _t select 's1', pg_temp.try($$select public.inventory_item_option_set_usual_v1('d1060000-0000-4000-8000-0000000000f3')$$);
reset role;
select is((select array(select id from public.inventory_item_options where item_id = 'd1060000-0000-4000-8000-0000000000c1' and is_usual)), array['d1060000-0000-4000-8000-0000000000f3']::uuid[], 'set usual: only the chosen option is usual');
select ok((select v -> 'options' -> 0 ->> 'id' = 'd1060000-0000-4000-8000-0000000000f3' and v -> 'options' -> 0 ? 'price' from _t where k = 's1'), 'set usual: returns the updated list, new usual first, with price for the owner');
select is((select quoted_pack_price from public.inventory_item_suppliers where item_id = 'd1060000-0000-4000-8000-0000000000c1' and supplier_id = 'd1060000-0000-4000-8000-0000000000e1'), 90.00, 'set usual: the supplier link is created with the option price');
select is((select pack_label from public.inventory_item_suppliers where item_id = 'd1060000-0000-4000-8000-0000000000c1' and supplier_id = 'd1060000-0000-4000-8000-0000000000e1'), 'Zz Plain Soap 90g', 'set usual: pack label is brand + title when the option has no pack label');
select ok((select is_preferred from public.inventory_item_suppliers where item_id = 'd1060000-0000-4000-8000-0000000000c1' and supplier_id = 'd1060000-0000-4000-8000-0000000000e1'), 'set usual: the link is preferred');
select is((select array(select supplier_id from public.inventory_item_suppliers where item_id = 'd1060000-0000-4000-8000-0000000000c1' and is_preferred)), array['d1060000-0000-4000-8000-0000000000e1']::uuid[], 'set usual: the earlier preferred link (Shop B) is cleared, one preferred link remains');

select pg_temp.as_user('d1060000-0000-4000-8000-0000000000a5');
insert into _t select 's2', pg_temp.try($$select public.inventory_item_option_set_usual_v1('d1060000-0000-4000-8000-0000000000f3')$$);
insert into _t select 's3', pg_temp.try($$select public.inventory_item_option_set_usual_v1('d1060000-0000-4000-8000-0000000000f1')$$);
reset role;
select ok((select v ->> 'ok' = 'true' from _t where k = 's2') and (select count(*) from public.inventory_item_suppliers where item_id = 'd1060000-0000-4000-8000-0000000000c1' and supplier_id = 'd1060000-0000-4000-8000-0000000000e1') = 1
          and (select count(*) from public.inventory_item_options where item_id = 'd1060000-0000-4000-8000-0000000000c1' and is_usual) = 1, 'set usual again: idempotent, still one link and one usual');
select is((select array(select id from public.inventory_item_options where item_id = 'd1060000-0000-4000-8000-0000000000c1' and is_usual)), array['d1060000-0000-4000-8000-0000000000f1']::uuid[], 'second option: usual moves to it and stays unique');
select is((select pack_label from public.inventory_item_suppliers where item_id = 'd1060000-0000-4000-8000-0000000000c1' and supplier_id = 'd1060000-0000-4000-8000-0000000000e1'),
  'Alpha Gel Fresh Refreshing Lemon Value P', 'second option: a title that already starts with the brand is not doubled, cut to 40 characters');
select is((select quoted_pack_price from public.inventory_item_suppliers where item_id = 'd1060000-0000-4000-8000-0000000000c1' and supplier_id = 'd1060000-0000-4000-8000-0000000000e1'), 120.00, 'second option: the same supplier link now quotes 120.00');
select is((select count(*)::int from public.inventory_item_suppliers where item_id = 'd1060000-0000-4000-8000-0000000000c1' and supplier_id = 'd1060000-0000-4000-8000-0000000000e1'), 1, 'second option: still one link row for the item and supplier');

select pg_temp.as_user('d1060000-0000-4000-8000-0000000000a5');
insert into _t select 's4', pg_temp.try($$select public.inventory_item_option_set_usual_v1('d1060000-0000-4000-8000-0000000000f2')$$);
reset role;
select is((select pack_label from public.inventory_item_suppliers where item_id = 'd1060000-0000-4000-8000-0000000000c1' and supplier_id = 'd1060000-0000-4000-8000-0000000000e1'), '6 x 90g', 'third option: its own pack label wins');
select ok((select pack_size = 6 and quoted_pack_price = 100.00 from public.inventory_item_suppliers where item_id = 'd1060000-0000-4000-8000-0000000000c1' and supplier_id = 'd1060000-0000-4000-8000-0000000000e1'), 'third option: pack size 6 and price 100.00 are carried to the link');

select * from finish();
rollback;
