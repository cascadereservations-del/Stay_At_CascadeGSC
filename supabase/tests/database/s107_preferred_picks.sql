-- Session 107, lane SQL: release s107_preferred_picks_20261110. The is_preferred column, the Shopee image host, the RPC (preferred key and order: usual > preferred > rest),
-- the shared make-usual function, and the data step on the restored production copy (rehearsal only, before any fixture is added).
-- Fixtures use uuids d1070000-... on properties of their own; everything rolls back.
begin;
select plan(44);

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

-- the 11 order-1 picks (the expected Usual option per item) and all 19 picks, from docs/s107/preferred-picks.json via gen-preferred-picks.mjs
create temp table _exp as
select i.id as item_id, v.item_name, v.url, v.store, v.price
  from (values
    -- BEGIN GENERATED usual (node docs/s107/gen-preferred-picks.mjs)
    ('66c7ec14-b20c-450d-9576-492c56e6d1c1'::uuid, 'Natural Air', 'https://shopsuki.ph/products/ambi-pur-gel-room-fresh-downy-180g', 'shopsuki', 184.25::numeric),
    ('513ffc56-3f9d-4e58-a061-3747d7c31189'::uuid, 'Baygon Spray', 'https://shopsuki.ph/products/ars-jet-gold-multi-insect-killer-600ml', 'shopsuki', 329.65::numeric),
    ('e79e4de3-7bfa-4d9d-845c-58f5e038ce03'::uuid, 'Breeze Fabric Conditioner Liquid', 'https://shopsuki.ph/products/breeze-liquid-detergent-frontload-60ml', 'shopsuki', 15.55::numeric),
    ('0bdd783a-77f8-4211-bf53-e1cbebcc284b'::uuid, 'Liquid Hand Soap (Safeguard)', 'https://shopsuki.ph/products/green-cross-antibacterial-hand-soap-450ml', 'shopsuki', 112.90::numeric),
    ('3179e10e-105f-47eb-8955-c2c2111948f8'::uuid, 'Liquid Body Soap (Dove)', 'https://shopee.ph/product/238345847/8627214070', 'shopee', 163.00::numeric),
    ('2137c758-5b95-46d6-8810-2364100b2dda'::uuid, 'Mr Muscle Mold & Mildew (Orange)', 'https://shopsuki.ph/products/mr-muscle-mold-mildew-killer-primary-500ml', 'shopsuki', 194.05::numeric),
    (null::uuid, 'All-Purpose Cleaner (Mr Muscle)', 'https://shopsuki.ph/products/mr-muscle-all-purpose-cleaner-lavender-3-7l', 'shopsuki', 420.35::numeric),
    ('2ec811c2-4ccc-4885-a8a5-3a8002e791b0'::uuid, 'Toiletries (toothbrush, toothpaste, soap)', 'https://shopee.ph/product/814013609/28130171038', 'shopee', 1329.00::numeric),
    ('da50acdc-1107-4574-ac9e-f2ecd951ed5a'::uuid, 'Coffee (3-in-1)', 'https://shopsuki.ph/products/nescafe-classic-sticks-1-9g-by-48s', 'shopsuki', 157.20::numeric),
    ('dfb24285-06a5-4e6d-9e6c-a24b23e73bc8'::uuid, 'Shampoo (Palmolive)', 'https://shopsuki.ph/products/palmolive-natural-shampoo-and-conditioner-intensive-moisture-coconut-cream-refill-pack-600ml', 'shopsuki', 305.40::numeric),
    ('4f139d96-f1fa-4be6-bbf2-a593a5383202'::uuid, 'Tissues / Paper Towels', 'https://shopee.ph/product/972814538/29003586262', 'shopee', 399.00::numeric)
    -- END GENERATED usual
  ) as v(item_id, item_name, url, store, price)
  join public.inventory_items i on i.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and (i.id = v.item_id or (v.item_id is null and i.name = v.item_name));
create temp table _all as
select i.id as item_id, v.item_name, v.url
  from (values
    -- BEGIN GENERATED all (node docs/s107/gen-preferred-picks.mjs)
    ('66c7ec14-b20c-450d-9576-492c56e6d1c1'::uuid, 'Natural Air', 'https://shopsuki.ph/products/ambi-pur-gel-room-fresh-downy-180g'),
    ('513ffc56-3f9d-4e58-a061-3747d7c31189'::uuid, 'Baygon Spray', 'https://shopsuki.ph/products/ars-jet-gold-multi-insect-killer-600ml'),
    ('e79e4de3-7bfa-4d9d-845c-58f5e038ce03'::uuid, 'Breeze Fabric Conditioner Liquid', 'https://shopsuki.ph/products/breeze-liquid-detergent-frontload-60ml'),
    ('e79e4de3-7bfa-4d9d-845c-58f5e038ce03'::uuid, 'Breeze Fabric Conditioner Liquid', 'https://shopsuki.ph/products/breeze-power-machine-liquid-detergent-ultraclean-concentrate-60ml'),
    ('0bdd783a-77f8-4211-bf53-e1cbebcc284b'::uuid, 'Liquid Hand Soap (Safeguard)', 'https://shopsuki.ph/products/green-cross-antibacterial-hand-soap-450ml'),
    ('3179e10e-105f-47eb-8955-c2c2111948f8'::uuid, 'Liquid Body Soap (Dove)', 'https://shopee.ph/product/238345847/8627214070'),
    ('3179e10e-105f-47eb-8955-c2c2111948f8'::uuid, 'Liquid Body Soap (Dove)', 'https://shopsuki.ph/products/safeguard-body-wash-pure-white-sup'),
    ('2137c758-5b95-46d6-8810-2364100b2dda'::uuid, 'Mr Muscle Mold & Mildew (Orange)', 'https://shopsuki.ph/products/mr-muscle-mold-mildew-killer-primary-500ml'),
    (null::uuid, 'All-Purpose Cleaner (Mr Muscle)', 'https://shopsuki.ph/products/mr-muscle-all-purpose-cleaner-lavender-3-7l'),
    (null::uuid, 'All-Purpose Cleaner (Mr Muscle)', 'https://shopee.ph/product/238345847/7078169120'),
    ('2ec811c2-4ccc-4885-a8a5-3a8002e791b0'::uuid, 'Toiletries (toothbrush, toothpaste, soap)', 'https://shopee.ph/product/814013609/28130171038'),
    ('2ec811c2-4ccc-4885-a8a5-3a8002e791b0'::uuid, 'Toiletries (toothbrush, toothpaste, soap)', 'https://shopee.ph/product/569141117/45906538836'),
    ('da50acdc-1107-4574-ac9e-f2ecd951ed5a'::uuid, 'Coffee (3-in-1)', 'https://shopsuki.ph/products/nescafe-classic-sticks-1-9g-by-48s'),
    ('da50acdc-1107-4574-ac9e-f2ecd951ed5a'::uuid, 'Coffee (3-in-1)', 'https://shopsuki.ph/products/nescafe-3-in-1-coffee-mix-creamy-latte-20g-x-20s'),
    ('dfb24285-06a5-4e6d-9e6c-a24b23e73bc8'::uuid, 'Shampoo (Palmolive)', 'https://shopsuki.ph/products/palmolive-natural-shampoo-and-conditioner-intensive-moisture-coconut-cream-refill-pack-600ml'),
    ('dfb24285-06a5-4e6d-9e6c-a24b23e73bc8'::uuid, 'Shampoo (Palmolive)', 'https://shopee.ph/product/238345847/53319103966'),
    ('4f139d96-f1fa-4be6-bbf2-a593a5383202'::uuid, 'Tissues / Paper Towels', 'https://shopee.ph/product/972814538/29003586262'),
    ('4f139d96-f1fa-4be6-bbf2-a593a5383202'::uuid, 'Tissues / Paper Towels', 'https://shopee.ph/product/1668619042/55355724148'),
    ('4f139d96-f1fa-4be6-bbf2-a593a5383202'::uuid, 'Tissues / Paper Towels', 'https://shopee.ph/product/972814538/44204658417')
    -- END GENERATED all
  ) as v(item_id, item_name, url)
  join public.inventory_items i on i.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and (i.id = v.item_id or (v.item_id is null and i.name = v.item_name));

-- =============================================================================================================================================
-- Part 1: the data step on the restored production copy (26)
-- =============================================================================================================================================
select is((select column_default from information_schema.columns where table_schema = 'public' and table_name = 'inventory_item_options' and column_name = 'is_preferred'), 'false', 'is_preferred defaults to false');
select is((select is_nullable from information_schema.columns where table_schema = 'public' and table_name = 'inventory_item_options' and column_name = 'is_preferred'), 'NO', 'is_preferred is not null');
select is((select count(*)::int from _exp), 11, 'the 11 order-1 pick items all resolve (10 by id, the new cleaner by name)');
select is((select count(*)::int from _all), 19, 'all 19 picks resolve to an item');
select is((select count(*)::int from public.inventory_item_options where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and is_preferred), 19, 'exactly 19 options are preferred');
select is((select count(distinct o.source_url)::int from public.inventory_item_options o join _all a on a.item_id = o.item_id and a.url = o.source_url where o.is_preferred), 19, 'the 19 preferred options are the 19 pick urls');
select is((select count(*)::int from public.inventory_item_options where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'), 76, 'options on the property: 64 from s106 - 4 Colgate + 16 new picks = 76');
select is((select count(*)::int from (select e.item_id from _exp e join public.inventory_item_options o on o.item_id = e.item_id group by e.item_id having count(*) filter (where o.is_usual) = 1) q), 11, 'each of the 11 pick items has exactly one usual option');
select is((select count(*)::int from _exp e join public.inventory_item_options o on o.item_id = e.item_id and o.source_url = e.url and o.is_usual), 11, 'and it is the order-1 pick');
select is((select count(*)::int from _exp e join public.inventory_item_options o on o.item_id = e.item_id and o.source_url = e.url and o.price = e.price), 11, 'the order-1 picks carry the read prices');
select is((select count(*)::int from public.inventory_item_options where item_id = '2ec811c2-4ccc-4885-a8a5-3a8002e791b0'), 2, 'Toiletries holds exactly 2 options');
select is((select count(*)::int from public.inventory_item_options o join _all a on a.item_id = o.item_id and a.url = o.source_url where o.item_id = '2ec811c2-4ccc-4885-a8a5-3a8002e791b0' and o.is_preferred), 2, 'both Toiletries options are the preferred picks');
select is((select count(*)::int from public.inventory_items where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and name = 'All-Purpose Cleaner (Mr Muscle)'), 1, 'the new cleaner item exists once');
select ok((select category = 'Cleaning Supplies' and unit = 'pc' and is_consumable and is_active and reorder_below = 1 and qty_on_hand = 0
             from public.inventory_items where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and name = 'All-Purpose Cleaner (Mr Muscle)'), 'the new item is a Cleaning Supplies consumable in pc, reorder at 1, active');
select is((select count(*)::int from public.inventory_item_options o join public.inventory_items i on i.id = o.item_id where i.name = 'All-Purpose Cleaner (Mr Muscle)' and i.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'), 2, 'the new item has 2 options');
select is((select count(*)::int from public.inventory_suppliers where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and lower(btrim(name)) = 'shopee' and payment_method = 'online'), 1, 'the Shopee supplier exists once, online');
select is((select count(*)::int from public.inventory_suppliers where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and lower(btrim(name)) = 'shopsuki'), 1, 'the Shopsuki supplier still exists once');
select is((select count(*)::int from (select e.item_id from _exp e join public.inventory_item_suppliers k on k.item_id = e.item_id group by e.item_id having count(*) filter (where k.is_preferred) = 1) q), 11, 'each of the 11 pick items has exactly one preferred supplier link');
select is((select count(*)::int from _exp e join public.inventory_item_options o on o.item_id = e.item_id and o.source_url = e.url and o.is_usual
             join public.inventory_item_suppliers k on k.item_id = o.item_id and k.supplier_id = o.supplier_id and k.is_preferred and k.quoted_pack_price = o.price and char_length(k.pack_label) between 1 and 40), 11,
          'that link is the usual option supplier at the usual option price, with a pack label of at most 40 characters');
select ok((select s.name = 'Shopsuki' and k.quoted_pack_price = 329.65 from public.inventory_item_suppliers k join public.inventory_suppliers s on s.id = k.supplier_id
            where k.item_id = '513ffc56-3f9d-4e58-a061-3747d7c31189' and k.is_preferred), 'Baygon: the preferred link is Shopsuki at 329.65');
select ok((select s.name = 'Shopee' and k.quoted_pack_price = 1329.00 and k.pack_size = 100 from public.inventory_item_suppliers k join public.inventory_suppliers s on s.id = k.supplier_id
            where k.item_id = '2ec811c2-4ccc-4885-a8a5-3a8002e791b0' and k.is_preferred), 'Toiletries: the preferred link is Shopee, 1329.00 for a pack of 100');
select is((select count(*)::int from public.inventory_item_suppliers k join public.inventory_suppliers s on s.id = k.supplier_id
            where k.item_id = '2ec811c2-4ccc-4885-a8a5-3a8002e791b0' and lower(s.name) = 'shopsuki'), 0, 'Toiletries: the orphaned Shopsuki link is gone');
select is((select count(*)::int from public.inventory_item_options where image_url like 'https://down-ph.img.susercontent.com/%' and property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'), 8, 'the 8 Shopee picks keep their susercontent images');
select ok(not has_function_privilege('anon', 'public.s_inventory_preferred_picks_v1()', 'execute') and not has_function_privilege('authenticated', 'public.s_inventory_preferred_picks_v1()', 'execute')
          and not has_function_privilege('service_role', 'public.s_inventory_preferred_picks_v1()', 'execute')
          and not has_function_privilege('anon', 'public.s_inventory_option_make_usual_v1(uuid)', 'execute') and not has_function_privilege('authenticated', 'public.s_inventory_option_make_usual_v1(uuid)', 'execute')
          and not has_function_privilege('service_role', 'public.s_inventory_option_make_usual_v1(uuid)', 'execute'), 'both internal functions have no grants');

insert into _t select 'h_o', to_jsonb(md5((select string_agg(o::text, '|' order by o.id) from public.inventory_item_options o where o.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd')));
insert into _t select 'h_l', to_jsonb(md5((select string_agg(k::text, '|' order by k.item_id, k.supplier_id) from public.inventory_item_suppliers k join public.inventory_items i on i.id = k.item_id where i.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd')));
select is(public.s_inventory_preferred_picks_v1(), '{"suppliers": 0, "items": 0, "options": 0, "removed": 0, "usual": 11, "links_removed": 0}'::jsonb, 'data step again: inserts, changes and deletes nothing');
select ok(to_jsonb(md5((select string_agg(o::text, '|' order by o.id) from public.inventory_item_options o where o.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'))) = (select v from _t where k = 'h_o')
          and to_jsonb(md5((select string_agg(k::text, '|' order by k.item_id, k.supplier_id) from public.inventory_item_suppliers k join public.inventory_items i on i.id = k.item_id where i.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'))) = (select v from _t where k = 'h_l'),
          'data step again: every option and link row is byte-identical (updated_at untouched)');

-- =============================================================================================================================================
-- Fixtures
-- =============================================================================================================================================
insert into auth.users(id, email) values
  ('d1070000-0000-4000-8000-0000000000a1', 'zz107-honey@example.com'), ('d1070000-0000-4000-8000-0000000000a4', 'zz107-finance@example.com'), ('d1070000-0000-4000-8000-0000000000a5', 'zz107-owner@example.com');
insert into public.staff_access_profiles(user_id, role) values
  ('d1070000-0000-4000-8000-0000000000a1', 'cleaner'), ('d1070000-0000-4000-8000-0000000000a4', 'finance'), ('d1070000-0000-4000-8000-0000000000a5', 'owner');
insert into public.properties(id, name, is_active) values ('d1070000-0000-4000-8000-0000000000b0', 'Zz S107 fixture property', true);
insert into public.staff_property_access(user_id, property_id) select u, 'd1070000-0000-4000-8000-0000000000b0'
  from unnest(array['d1070000-0000-4000-8000-0000000000a1', 'd1070000-0000-4000-8000-0000000000a4', 'd1070000-0000-4000-8000-0000000000a5']::uuid[]) u;
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, reorder_below, is_consumable, unit_cost, units_per_purchase, purchase_unit) values
  ('d1070000-0000-4000-8000-0000000000c1', 'd1070000-0000-4000-8000-0000000000b0', 'Zz107 Soap', 'Toiletries', 'pc', 5, 2, true, null, 1, null);
insert into public.inventory_suppliers(id, property_id, name, payment_method) values
  ('d1070000-0000-4000-8000-0000000000e1', 'd1070000-0000-4000-8000-0000000000b0', 'Zz107 Shop A', 'online');
-- p1 usual 100; p2 preferred 110 'Zeta'; p3 preferred 130 'Alpha'; p4 rest 90 'Plain'; p5 rest 80 'Beta'
insert into public.inventory_item_options(id, property_id, item_id, supplier_id, title, brand, price, source_url, is_usual, is_preferred) values
  ('d1070000-0000-4000-8000-0000000000f1', 'd1070000-0000-4000-8000-0000000000b0', 'd1070000-0000-4000-8000-0000000000c1', 'd1070000-0000-4000-8000-0000000000e1', 'Mid Usual', 'Zz', 100.00, 'https://shopsuki.ph/products/zz107-p1', true, false),
  ('d1070000-0000-4000-8000-0000000000f2', 'd1070000-0000-4000-8000-0000000000b0', 'd1070000-0000-4000-8000-0000000000c1', 'd1070000-0000-4000-8000-0000000000e1', 'Zeta Preferred', 'Zz', 110.00, 'https://shopsuki.ph/products/zz107-p2', false, true),
  ('d1070000-0000-4000-8000-0000000000f3', 'd1070000-0000-4000-8000-0000000000b0', 'd1070000-0000-4000-8000-0000000000c1', 'd1070000-0000-4000-8000-0000000000e1', 'Alpha Preferred', 'Zz', 130.00, 'https://shopsuki.ph/products/zz107-p3', false, true),
  ('d1070000-0000-4000-8000-0000000000f4', 'd1070000-0000-4000-8000-0000000000b0', 'd1070000-0000-4000-8000-0000000000c1', 'd1070000-0000-4000-8000-0000000000e1', 'Plain Rest', 'Zz', 90.00, 'https://shopsuki.ph/products/zz107-p4', false, false),
  ('d1070000-0000-4000-8000-0000000000f5', 'd1070000-0000-4000-8000-0000000000b0', 'd1070000-0000-4000-8000-0000000000c1', 'd1070000-0000-4000-8000-0000000000e1', 'Beta Rest', 'Zz', 80.00, 'https://shopsuki.ph/products/zz107-p5', false, false);

-- =============================================================================================================================================
-- Part 2: image host check (5)
-- =============================================================================================================================================
select is(pg_temp.try($$insert into public.inventory_item_options(property_id, item_id, supplier_id, title, image_url, source_url) values ('d1070000-0000-4000-8000-0000000000b0', 'd1070000-0000-4000-8000-0000000000c1', 'd1070000-0000-4000-8000-0000000000e1', 'Shopee image', 'https://down-ph.img.susercontent.com/file/ph-11134207-abc', 'https://shopee.ph/product/1/2') returning to_jsonb(id)$$) ->> 'err', null, 'a susercontent image on a shopee.ph source is accepted');
select is(pg_temp.try($$insert into public.inventory_item_options(property_id, item_id, supplier_id, title, image_url) values ('d1070000-0000-4000-8000-0000000000b0', 'd1070000-0000-4000-8000-0000000000c1', 'd1070000-0000-4000-8000-0000000000e1', 'x', 'http://down-ph.img.susercontent.com/file/a') returning to_jsonb(id)$$) ->> 'err', '23514', 'an http image is refused');
select is(pg_temp.try($$insert into public.inventory_item_options(property_id, item_id, supplier_id, title, image_url) values ('d1070000-0000-4000-8000-0000000000b0', 'd1070000-0000-4000-8000-0000000000c1', 'd1070000-0000-4000-8000-0000000000e1', 'x', 'https://down-ph.img.susercontent.com.evil.example/a.jpg') returning to_jsonb(id)$$) ->> 'err', '23514', 'a look-alike host is refused');
select is(pg_temp.try($$insert into public.inventory_item_options(property_id, item_id, supplier_id, title, image_url) values ('d1070000-0000-4000-8000-0000000000b0', 'd1070000-0000-4000-8000-0000000000c1', 'd1070000-0000-4000-8000-0000000000e1', 'x', 'https://evil.example/a.jpg') returning to_jsonb(id)$$) ->> 'err', '23514', 'another host is still refused');
select is(pg_temp.try($$insert into public.inventory_item_options(property_id, item_id, supplier_id, title, image_url) values ('d1070000-0000-4000-8000-0000000000b0', 'd1070000-0000-4000-8000-0000000000c1', 'd1070000-0000-4000-8000-0000000000e1', 'Shopify image', 'https://cdn.shopify.com/s/files/1/a.jpg') returning to_jsonb(id)$$) ->> 'err', null, 'the Shopify host is still accepted');

delete from public.inventory_item_options where title in ('Shopee image', 'Shopify image') and item_id = 'd1070000-0000-4000-8000-0000000000c1';

-- =============================================================================================================================================
-- Part 3: the RPC (9)
-- =============================================================================================================================================
select pg_temp.as_user('d1070000-0000-4000-8000-0000000000a5');
insert into _t select 'ow', pg_temp.try($$select public.inventory_item_options_v1('d1070000-0000-4000-8000-0000000000c1')$$);
reset role;
select pg_temp.as_user('d1070000-0000-4000-8000-0000000000a1');
insert into _t select 'cl', pg_temp.try($$select public.inventory_item_options_v1('d1070000-0000-4000-8000-0000000000c1')$$);
insert into _t select 'cl_set', pg_temp.try($$select public.inventory_item_option_set_usual_v1('d1070000-0000-4000-8000-0000000000f2')$$);
reset role;
select pg_temp.as_user('d1070000-0000-4000-8000-0000000000a4');
insert into _t select 'fi', pg_temp.try($$select public.inventory_item_options_v1('d1070000-0000-4000-8000-0000000000c1')$$);
reset role;

select is((select array(select e ->> 'id' from _t, jsonb_array_elements(v -> 'options') with ordinality x(e, n) where k = 'ow' order by n)),
  array['d1070000-0000-4000-8000-0000000000f1', 'd1070000-0000-4000-8000-0000000000f2', 'd1070000-0000-4000-8000-0000000000f3', 'd1070000-0000-4000-8000-0000000000f5', 'd1070000-0000-4000-8000-0000000000f4'],
  'owner: usual (100), then preferred by price (110, 130), then the rest by price (80, 90)');
select is((select array(select e ->> 'id' from _t, jsonb_array_elements(v -> 'options') with ordinality x(e, n) where k = 'fi' order by n)),
  array['d1070000-0000-4000-8000-0000000000f1', 'd1070000-0000-4000-8000-0000000000f2', 'd1070000-0000-4000-8000-0000000000f3', 'd1070000-0000-4000-8000-0000000000f5', 'd1070000-0000-4000-8000-0000000000f4'],
  'finance: same order as the owner');
select is((select array(select e ->> 'id' from _t, jsonb_array_elements(v -> 'options') with ordinality x(e, n) where k = 'cl' order by n)),
  array['d1070000-0000-4000-8000-0000000000f1', 'd1070000-0000-4000-8000-0000000000f3', 'd1070000-0000-4000-8000-0000000000f2', 'd1070000-0000-4000-8000-0000000000f5', 'd1070000-0000-4000-8000-0000000000f4'],
  'cleaner: usual, then preferred by title (Alpha, Zeta), then the rest by title (Beta, Plain)');
select is((select array(select e ->> 'id' from _t, jsonb_array_elements(v -> 'options') e where k = 'ow' and (e ->> 'preferred')::boolean order by e ->> 'id')),
  array['d1070000-0000-4000-8000-0000000000f2', 'd1070000-0000-4000-8000-0000000000f3'], 'owner: preferred is true for exactly the two preferred options');
select ok((select bool_and(e ? 'preferred' and jsonb_typeof(e -> 'preferred') = 'boolean') from _t, jsonb_array_elements(v -> 'options') e where k in ('ow', 'cl', 'fi')), 'every option of every role carries a boolean preferred key');
select ok((select (e ->> 'usual')::boolean and not (e ->> 'preferred')::boolean from _t, jsonb_array_elements(v -> 'options') e where k = 'ow' and e ->> 'id' = 'd1070000-0000-4000-8000-0000000000f1'), 'usual and preferred are independent flags');
select ok((select v::text !~ '"price"' and jsonb_array_length(v -> 'options') = 5 from _t where k = 'cl'), 'cleaner: five options and no price key anywhere');
select ok((select bool_and(e ? 'price') from _t, jsonb_array_elements(v -> 'options') e where k = 'fi'), 'finance: every option carries its price');
select is((select v ->> 'err' from _t where k = 'cl_set'), '42501', 'cleaner: still cannot set the usual option');

-- =============================================================================================================================================
-- Part 4: set usual still behaves through the shared function (4)
-- =============================================================================================================================================
select pg_temp.as_user('d1070000-0000-4000-8000-0000000000a5');
insert into _t select 's1', pg_temp.try($$select public.inventory_item_option_set_usual_v1('d1070000-0000-4000-8000-0000000000f2')$$);
reset role;
select is((select array(select id from public.inventory_item_options where item_id = 'd1070000-0000-4000-8000-0000000000c1' and is_usual)), array['d1070000-0000-4000-8000-0000000000f2']::uuid[], 'set usual: only the chosen preferred option is usual, its preferred flag is kept');
select ok((select v -> 'options' -> 0 ->> 'id' = 'd1070000-0000-4000-8000-0000000000f2' and (v -> 'options' -> 0 ->> 'preferred')::boolean and v -> 'options' -> 1 ->> 'id' = 'd1070000-0000-4000-8000-0000000000f3' from _t where k = 's1'),
  'set usual: the returned list has the new usual first and the other preferred option next');
select ok((select is_preferred and quoted_pack_price = 110.00 and pack_label = 'Zz Zeta Preferred' from public.inventory_item_suppliers
            where item_id = 'd1070000-0000-4000-8000-0000000000c1' and supplier_id = 'd1070000-0000-4000-8000-0000000000e1'), 'set usual: the supplier link is preferred at 110.00 with brand + title as label');
select is((select count(*)::int from public.inventory_item_options where item_id = 'd1070000-0000-4000-8000-0000000000c1' and is_preferred), 2, 'set usual: the preferred flags are untouched');

select * from finish();
rollback;
