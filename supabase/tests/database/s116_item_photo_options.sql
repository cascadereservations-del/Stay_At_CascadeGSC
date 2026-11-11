-- Session 116 (lane S2): the 51 item-photo options of migration 20261115000100_s116_item_photo_options.sql.
-- Synthetic fixtures only (uuids a1160100-...). Everything rolls back. Assumes the migration is applied (its real rows exist in the live-shaped DB).
begin;
select plan(8);

-- the 51 real pairs (item name + source_url). The three data asserts pass trivially on a schema-only database (no Cascade property); on a restore of production they check the real rows.
create temp table s116_pairs(item text, source_url text) on commit drop;
insert into s116_pairs values
    ('Bath rug', 'https://mandauefoam.ph/products/graz-bath-rug-40x60-cm'),
    ('Clothes Drying Rack', 'https://mandauefoam.ph/products/bowen-winged-drying-rack'),
    ('Dipper', 'https://mandauefoam.ph/products/kley-water-dipper'),
    ('Dishwashing Container', 'https://mandauefoam.ph/products/kade-wash-basin'),
    ('Floor mat', 'https://mandauefoam.ph/products/arve-non-slip-cofee-kitchen-rug-set-of-2'),
    ('Handsoap Container', 'https://mandauefoam.ph/products/liquid-handsoap-500ml-garden-lush'),
    ('Hanger', 'https://mandauefoam.ph/products/kira-plastic-hanger-10pc-set'),
    ('Pail', 'https://mandauefoam.ph/products/kade-water-bucket'),
    ('Plastic Basin', 'https://mandauefoam.ph/products/kade-wash-basin'),
    ('Trash Bin', 'https://mandauefoam.ph/products/kio-round-trash-bin'),
    ('Bath Towel', 'https://mandauefoam.ph/products/maldi-bath-towel'),
    ('Bed (Q)', 'https://mandauefoam.ph/products/wilton-beige-bed'),
    ('Comforter (Q)', 'https://mandauefoam.ph/products/comforter-duvet-insert-gray'),
    ('Duvet Cover (Q)', 'https://mandauefoam.ph/products/super-soft-white-duvet-cover'),
    ('Fitted Sheet (Q)', 'https://mandauefoam.ph/products/super-soft-white-linen'),
    ('Fitted Sheet (S)', 'https://mandauefoam.ph/products/super-soft-white-linen'),
    ('Pillow Case (Rect)', 'https://mandauefoam.ph/products/deluxe-white-plain-pillowcases'),
    ('Pillow Case (Square)', 'https://mandauefoam.ph/products/deluxe-white-plain-pillowcases'),
    ('Pillow Protector', 'https://mandauefoam.ph/products/quilted-pillow-protector'),
    ('Quilted Mattress Protector (Q)', 'https://mandauefoam.ph/products/quilted-waterproof-mattress-protector'),
    ('Rectangular Pillow', 'https://mandauefoam.ph/products/deluxe-pillow'),
    ('Square Pillow (Big)', 'https://mandauefoam.ph/products/sofa-fiber-cushion-pillow'),
    ('Wooden Wardrobe', 'https://mandauefoam.ph/products/averie-3-door-with-2-drawer-wardrobe'),
    ('Bar / Counter Table', 'https://mandauefoam.ph/products/gerik-bar-table'),
    ('Can Opener', 'https://mandauefoam.ph/products/ian-stainless-steel-can-opener'),
    ('Casserole', 'https://mandauefoam.ph/products/noe-stainless-steel-soup-pot'),
    ('Chair (White)', 'https://mandauefoam.ph/products/lyle-plastic-chair'),
    ('Dish Rack with cover', 'https://mandauefoam.ph/products/lin-dish-drainer-with-lid'),
    ('Drainer dish cabinet without cover', 'https://mandauefoam.ph/products/nova-dish-rack'),
    ('Fork', 'https://mandauefoam.ph/products/orlo-dinner-fork-6pc-set'),
    ('Frying Pan (Ikea)', 'https://mandauefoam.ph/products/noe-stainless-steel-frying-pan'),
    ('Highball Glass', 'https://mandauefoam.ph/products/greta-drinking-glass-4pc-set-21oz'),
    ('Induction Cooker (Hanabishi)', 'https://myhanabishi.com/products/hanabishi-induction-cooker-hic60'),
    ('Knife', 'https://mandauefoam.ph/products/levi-chefs-knife'),
    ('Ladle', 'https://mandauefoam.ph/products/orlo-soup-ladle'),
    ('Mug (Colored)', 'https://mandauefoam.ph/products/daisy-mug-14oz'),
    ('Mug (White)', 'https://mandauefoam.ph/products/avie-basic-mug'),
    ('Plate', 'https://mandauefoam.ph/products/misha-dinner-plate'),
    ('Refrigerator (Fujidenzo)', 'https://shopsuki.ph/products/fujidenzo-hd-inverter-two-door-refrigerator'),
    ('Rice Cooker (Dowell)', 'https://shopsuki.ph/products/dowell-aluminum-rice-cooker'),
    ('Sauce Pan (Ikea)', 'https://mandauefoam.ph/products/noe-stainless-steel-saucepan'),
    ('Soup Bowl', 'https://mandauefoam.ph/products/deni-bowl'),
    ('Spoon', 'https://mandauefoam.ph/products/orlo-dinner-spoon-6pc-set'),
    ('Teaspoon', 'https://mandauefoam.ph/products/orlo-teaspoon-6pc-set'),
    ('Wine Glass', 'https://mandauefoam.ph/products/delvy-wine-glass-4pc-set-7oz'),
    ('Center Table', 'https://mandauefoam.ph/products/yusuf-coffee-table'),
    ('Lampshade', 'https://mandauefoam.ph/products/bernth-table-lamp'),
    ('Sofa Bed with mattress', 'https://mandauefoam.ph/products/benny-sofa-bed'),
    ('Sofa Cover', 'https://mandauefoam.ph/products/stretchable-sofa-protector-gray'),
    ('Throw Pillow', 'https://mandauefoam.ph/products/decorative-throw-pillow-16x16'),
    ('Throw Pillowcase', 'https://mandauefoam.ph/products/mede-chenile-throw-pillowcase');

select ok((select count(*) from s116_pairs) = 51, 'the pair list holds 51 rows');
select ok(exists (select 1 from pg_constraint where conname = 'inventory_item_options_source_url_check' and pg_get_constraintdef(oid) like '%mandauefoam%' and pg_get_constraintdef(oid) like '%myhanabishi%' and pg_get_constraintdef(oid) like '%shopsuki%'),
  'source_url check allows mandauefoam.ph, myhanabishi.com and the old hosts');
select ok(not exists (select 1 from public.properties where id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd') or (select count(*) from public.inventory_suppliers s where s.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and lower(btrim(s.name)) in ('mandaue foam', 'hanabishi')) = 2, 'both new suppliers exist');
select ok(not exists (select 1 from public.properties where id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd') or (select count(*) from public.inventory_item_options o join public.inventory_items i on i.id = o.item_id join s116_pairs p on p.item = i.name and p.source_url = o.source_url
           where i.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd') = 51, 'all 51 item-photo options exist');
select ok(not exists (select 1 from public.inventory_item_options o join public.inventory_items i on i.id = o.item_id join s116_pairs p on p.item = i.name and p.source_url = o.source_url
           where o.is_usual or o.is_preferred or o.price is not null or o.image_url is null), 'none of the 51 is usual, preferred or priced, all carry a photo');

-- synthetic item for the constraint probes
insert into public.properties(id, name, is_active) values ('a1160100-0000-4000-8000-0000000000b0', 'Synthetic S116 photos', true);
insert into public.inventory_suppliers(id, property_id, name) values ('a1160100-0000-4000-8000-0000000000d1', 'a1160100-0000-4000-8000-0000000000b0', 'Zz S116 supplier');
insert into public.inventory_items(id, property_id, name, category, qty_on_hand) values ('a1160100-0000-4000-8000-0000000000a1', 'a1160100-0000-4000-8000-0000000000b0', 'Zz S116 item', 'Supplies', 1);

select lives_ok($$insert into public.inventory_item_options(property_id, item_id, supplier_id, title, source_url, image_url) values ('a1160100-0000-4000-8000-0000000000b0', 'a1160100-0000-4000-8000-0000000000a1', 'a1160100-0000-4000-8000-0000000000d1', 'Zz probe', 'https://mandauefoam.ph/products/zz-probe', 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/zz.png')$$,
  'a mandauefoam.ph source is accepted');
select throws_ok($$insert into public.inventory_item_options(property_id, item_id, supplier_id, title, source_url) values ('a1160100-0000-4000-8000-0000000000b0', 'a1160100-0000-4000-8000-0000000000a1', 'a1160100-0000-4000-8000-0000000000d1', 'Zz bad host', 'https://evil.example/products/zz')$$,
  '23514', null, 'a source on another host is still refused');
select throws_ok($$insert into public.inventory_item_options(property_id, item_id, supplier_id, title, source_url) values ('a1160100-0000-4000-8000-0000000000b0', 'a1160100-0000-4000-8000-0000000000a1', 'a1160100-0000-4000-8000-0000000000d1', 'Zz look-alike', 'https://mandauefoam.ph.evil.example/products/zz')$$,
  '23514', null, 'a look-alike host is refused');

select * from finish();
rollback;
