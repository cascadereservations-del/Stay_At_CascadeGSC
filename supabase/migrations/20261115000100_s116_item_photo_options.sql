-- 20261115000100_s116_item_photo_options.sql
-- Session 116, lane S2: release s116_guest_photo_name_20261115 (second migration). 51 stock items get a product option that carries a photo URL, so the Staff app
-- "Use as item photo" button (it reads option.image_url) has something to upload.
--   1. Check    source_url also accepts mandauefoam.ph and myhanabishi.com (image_url check unchanged: all 51 photos are cdn.shopify.com).
--   2. Suppliers 'Mandaue Foam' and 'Hanabishi' added (idempotent by property + lower(name)); Shopsuki and Shopee already exist.
--   3. Data     51 options (docs/s116/item-photos.json, photos read 2026-11-11), never usual, never preferred, no price. Joined on the exact item name; the migration
--               raises unless each name matches exactly one active item, so a typo fails loud. on conflict (item_id, source_url) do nothing.
begin;

-- 1. check ---------------------------------------------------------------------------------------------------------------------------------
alter table public.inventory_item_options drop constraint inventory_item_options_source_url_check;
alter table public.inventory_item_options add constraint inventory_item_options_source_url_check
  check (source_url is null or source_url ~ '^https://(shopsuki\.ph|shopee\.ph|mandauefoam\.ph|myhanabishi\.com)/');

-- 2. suppliers -----------------------------------------------------------------------------------------------------------------------------
insert into public.inventory_suppliers(property_id, name, location, maps_url, payment_method, notes)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid, v.name, v.location, null, v.payment_method, v.notes
from (values
  ('Mandaue Foam', 'Store and online (mandauefoam.ph)', 'online', 'Photos read from mandauefoam.ph on 2026-11-11'),
  ('Hanabishi', 'Online (myhanabishi.com)', 'online', 'Photo read from myhanabishi.com on 2026-11-11')
) v(name, location, payment_method, notes)
where exists (select 1 from public.properties p where p.id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd')
  and not exists (select 1 from public.inventory_suppliers s where s.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and lower(btrim(s.name)) = lower(v.name));

-- 3. options -------------------------------------------------------------------------------------------------------------------------------
do $d$
declare v_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'; v_bad text;
begin
  create temp table s116_photo_src(item text, supplier text, title text, brand text, image_url text, source_url text) on commit drop;
  insert into s116_photo_src values
    ('Bath rug', 'Mandaue Foam', 'Graz Bath Rug', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/products/mandaue-foam-graz-bath-rug-dark-gray-1151827065.png?v=1768300318', 'https://mandauefoam.ph/products/graz-bath-rug-40x60-cm'),
    ('Clothes Drying Rack', 'Mandaue Foam', 'Bowen Winged Drying Rack', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-bowen-winged-drying-rack-1151823529.png?v=1760926548', 'https://mandauefoam.ph/products/bowen-winged-drying-rack'),
    ('Dipper', 'Mandaue Foam', 'Kley Water Dipper', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/processed_140486.jpg?v=1786008819', 'https://mandauefoam.ph/products/kley-water-dipper'),
    ('Dishwashing Container', 'Mandaue Foam', 'Kade Wash Basin', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/140452.jpg?v=1788315189', 'https://mandauefoam.ph/products/kade-wash-basin'),
    ('Floor mat', 'Mandaue Foam', 'Arve Non-Slip Cofee Kitchen Rug Set of 2', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/ChatGPTImageJul20_2026_07_19_41PM.webp?v=1786672614', 'https://mandauefoam.ph/products/arve-non-slip-cofee-kitchen-rug-set-of-2'),
    ('Handsoap Container', 'Mandaue Foam', 'Liquid Handsoap 500ml - Garden Lush', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-liquid-handsoap-500ml-garden-lush-1151804695.png?v=1768301226', 'https://mandauefoam.ph/products/liquid-handsoap-500ml-garden-lush'),
    ('Hanger', 'Mandaue Foam', 'Kira Plastic Hanger 10pc Set', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/processed_140406_73e6df14-3074-41cd-82ae-407a822cb107.jpg?v=1785202675', 'https://mandauefoam.ph/products/kira-plastic-hanger-10pc-set'),
    ('Pail', 'Mandaue Foam', 'Kade Water Bucket', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/140454.jpg?v=1788315782', 'https://mandauefoam.ph/products/kade-water-bucket'),
    ('Plastic Basin', 'Mandaue Foam', 'Kade Wash Basin', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/140452.jpg?v=1788315189', 'https://mandauefoam.ph/products/kade-wash-basin'),
    ('Trash Bin', 'Mandaue Foam', 'Kio Round Trash Bin', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/processed_140459.jpg?v=1786962845', 'https://mandauefoam.ph/products/kio-round-trash-bin'),
    ('Bath Towel', 'Mandaue Foam', 'Maldi Bath Towel', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-maldi-bath-towel-white-1187125791.png?v=1768299681', 'https://mandauefoam.ph/products/maldi-bath-towel'),
    ('Bed (Q)', 'Mandaue Foam', 'Wilton Bed Beige', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/products/mandaue-foam-wilton-beige-bed-queen-bed-60x75-1151796816.png?v=1768197339', 'https://mandauefoam.ph/products/wilton-beige-bed'),
    ('Comforter (Q)', 'Mandaue Foam', 'Comforter & Duvet Insert Gray', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-comforter-duvet-insert-gray-1151801284.png?v=1760657993', 'https://mandauefoam.ph/products/comforter-duvet-insert-gray'),
    ('Duvet Cover (Q)', 'Mandaue Foam', 'Super Soft White Duvet Cover', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/sdga.png?v=1781839048', 'https://mandauefoam.ph/products/super-soft-white-duvet-cover'),
    ('Fitted Sheet (Q)', 'Mandaue Foam', 'Super Soft White Fitted Sheet', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-super-soft-white-fitted-sheet-1219416790.png?v=1770284288', 'https://mandauefoam.ph/products/super-soft-white-linen'),
    ('Fitted Sheet (S)', 'Mandaue Foam', 'Super Soft White Fitted Sheet', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-super-soft-white-fitted-sheet-1219416790.png?v=1770284288', 'https://mandauefoam.ph/products/super-soft-white-linen'),
    ('Pillow Case (Rect)', 'Mandaue Foam', 'Basic White Plain Pillowcases', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/ChatGPTImageSep10_2026_03_50_37PM.png?v=1789027410', 'https://mandauefoam.ph/products/deluxe-white-plain-pillowcases'),
    ('Pillow Case (Square)', 'Mandaue Foam', 'Basic White Plain Pillowcases', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/ChatGPTImageSep10_2026_03_50_37PM.png?v=1789027410', 'https://mandauefoam.ph/products/deluxe-white-plain-pillowcases'),
    ('Pillow Protector', 'Mandaue Foam', 'Quilted Pillow Protector', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/xcasdasd.png?v=1781834266', 'https://mandauefoam.ph/products/quilted-pillow-protector'),
    ('Quilted Mattress Protector (Q)', 'Mandaue Foam', 'Quilted Waterproof Mattress Protector', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/ChatGPTImageSep28_2026_08_51_08AM.png?v=1790560581', 'https://mandauefoam.ph/products/quilted-waterproof-mattress-protector'),
    ('Rectangular Pillow', 'Mandaue Foam', 'Deluxe Pillow', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/DeluxePSb.jpg?v=1782960245', 'https://mandauefoam.ph/products/deluxe-pillow'),
    ('Square Pillow (Big)', 'Mandaue Foam', 'Sofa Fiber Cushion Pillow', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/SofaFIberCushionitem117x17in.jpg?v=1789537752', 'https://mandauefoam.ph/products/sofa-fiber-cushion-pillow'),
    ('Wooden Wardrobe', 'Mandaue Foam', 'Averie 3 Door with 2 Drawer Wardrobe', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-averie-3-door-with-2-drawer-wardrobe-oak-1151811247.png?v=1762088421', 'https://mandauefoam.ph/products/averie-3-door-with-2-drawer-wardrobe'),
    ('Bar / Counter Table', 'Mandaue Foam', 'Gerik Bar Table', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-gerik-bar-table-walnut-1151821339.png?v=1760889238', 'https://mandauefoam.ph/products/gerik-bar-table'),
    ('Can Opener', 'Mandaue Foam', 'Ian Stainless Steel Can Opener', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-ian-stainless-steel-can-opener-1151815474.png?v=1760816645', 'https://mandauefoam.ph/products/ian-stainless-steel-can-opener'),
    ('Casserole', 'Mandaue Foam', 'Noe Stainless Steel Soup Pot', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/140414.jpg?v=1787897120', 'https://mandauefoam.ph/products/noe-stainless-steel-soup-pot'),
    ('Chair (White)', 'Mandaue Foam', 'Lyle Plastic Chair', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-lyle-plastic-chair-white-1151826652.png?v=1760979004', 'https://mandauefoam.ph/products/lyle-plastic-chair'),
    ('Dish Rack with cover', 'Mandaue Foam', 'Lin Dish Drainer with Lid', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/processed_140502_1.jpg?v=1786959047', 'https://mandauefoam.ph/products/lin-dish-drainer-with-lid'),
    ('Drainer dish cabinet without cover', 'Mandaue Foam', 'Nova Dish Rack', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-nova-dish-rack-1151817722.png?v=1768292228', 'https://mandauefoam.ph/products/nova-dish-rack'),
    ('Fork', 'Mandaue Foam', 'Orlo Dinner Fork 6pc Set', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-orlo-dinner-fork-6pc-set-1187125821.png?v=1768300954', 'https://mandauefoam.ph/products/orlo-dinner-fork-6pc-set'),
    ('Frying Pan (Ikea)', 'Mandaue Foam', 'Noe Stainless Steel Frying Pan', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/140417.jpg?v=1787899423', 'https://mandauefoam.ph/products/noe-stainless-steel-frying-pan'),
    ('Highball Glass', 'Mandaue Foam', 'Greta Drinking Glass 4pc Set - 21oz', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-greta-drinking-glass-4pc-set-21oz-1151804659.png?v=1760698314', 'https://mandauefoam.ph/products/greta-drinking-glass-4pc-set-21oz'),
    ('Induction Cooker (Hanabishi)', 'Hanabishi', 'Hanabishi Induction Cooker HIC60', 'Hanabishi', 'https://cdn.shopify.com/s/files/1/0766/1033/9097/files/Artboard_2_94c3d718-7471-495e-9d8e-89acb6cba278.jpg?v=1784104086', 'https://myhanabishi.com/products/hanabishi-induction-cooker-hic60'),
    ('Knife', 'Mandaue Foam', 'Levi Chef''s Knife', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/1383141.jpg?v=1788249649', 'https://mandauefoam.ph/products/levi-chefs-knife'),
    ('Ladle', 'Mandaue Foam', 'Orlo Soup Ladle', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-orlo-soup-ladle-1187125915.png?v=1768301036', 'https://mandauefoam.ph/products/orlo-soup-ladle'),
    ('Mug (Colored)', 'Mandaue Foam', 'Daisy Mug - 14oz', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-daisy-mug-14oz-mint-green-1208085871.jpg?v=1770289735', 'https://mandauefoam.ph/products/daisy-mug-14oz'),
    ('Mug (White)', 'Mandaue Foam', 'Avie Basic Mug', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/123444.jpg?v=1788222566', 'https://mandauefoam.ph/products/avie-basic-mug'),
    ('Plate', 'Mandaue Foam', 'Misha Dinner Plate', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/123862.jpg?v=1785388110', 'https://mandauefoam.ph/products/misha-dinner-plate'),
    ('Refrigerator (Fujidenzo)', 'Shopsuki', 'Fujidenzo HD Inverter Two-Door Refrigerator', 'Fujidenzo', 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/110432740-copy.jpg?v=1789614772', 'https://shopsuki.ph/products/fujidenzo-hd-inverter-two-door-refrigerator'),
    ('Rice Cooker (Dowell)', 'Shopsuki', 'Dowell Aluminum Rice Cooker', 'Dowell', 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/105807706RCS-03_2_wframe.jpg?v=1786169809', 'https://shopsuki.ph/products/dowell-aluminum-rice-cooker'),
    ('Sauce Pan (Ikea)', 'Mandaue Foam', 'Noe Stainless Steel Saucepan', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/140413.jpg?v=1787901514', 'https://mandauefoam.ph/products/noe-stainless-steel-saucepan'),
    ('Soup Bowl', 'Mandaue Foam', 'Deni Bowl', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-deni-bowl-blue-1151804788.png?v=1760699880', 'https://mandauefoam.ph/products/deni-bowl'),
    ('Spoon', 'Mandaue Foam', 'Orlo Dinner Spoon 6pc Set', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-orlo-dinner-spoon-6pc-set-1187125824.png?v=1768300971', 'https://mandauefoam.ph/products/orlo-dinner-spoon-6pc-set'),
    ('Teaspoon', 'Mandaue Foam', 'Orlo Teaspoon 6pc Set', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-orlo-teaspoon-6pc-set-1187125813.png?v=1768301053', 'https://mandauefoam.ph/products/orlo-teaspoon-6pc-set'),
    ('Wine Glass', 'Mandaue Foam', 'Delvy Wine Glass 4pc Set - 7oz', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-delvy-wine-glass-4pc-set-7oz-1151804664.png?v=1760698428', 'https://mandauefoam.ph/products/delvy-wine-glass-4pc-set-7oz'),
    ('Center Table', 'Mandaue Foam', 'Yusuf Coffee Table', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-yusuf-coffee-table-1151825002.png?v=1760951156', 'https://mandauefoam.ph/products/yusuf-coffee-table'),
    ('Lampshade', 'Mandaue Foam', 'Bernth Table Lamp', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-bernth-table-lamp-1151802087.png?v=1760665432', 'https://mandauefoam.ph/products/bernth-table-lamp'),
    ('Sofa Bed with mattress', 'Mandaue Foam', 'Benny Sofa Bed', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-benny-sofa-bed-fabric-parson-light-gray-1153891174.png?v=1772783233', 'https://mandauefoam.ph/products/benny-sofa-bed'),
    ('Sofa Cover', 'Mandaue Foam', 'Stretchable Sofa Protector Gray', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/ChatGPTImageSep26_2026_01_28_59PM.png?v=1790401478', 'https://mandauefoam.ph/products/stretchable-sofa-protector-gray'),
    ('Throw Pillow', 'Mandaue Foam', 'Decorative Throw Pillow', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/DECORATIVETHROWPILLOWitem1.jpg?v=1789537556', 'https://mandauefoam.ph/products/decorative-throw-pillow-16x16'),
    ('Throw Pillowcase', 'Mandaue Foam', 'Mede Chenile Throw Pillowcase', null, 'https://cdn.shopify.com/s/files/1/0078/2555/5571/files/mandaue-foam-mede-chenile-throw-pillowcase-silver-gray-1152432812.png?v=1768301766', 'https://mandauefoam.ph/products/mede-chenile-throw-pillowcase');

  select string_agg(x.item || ' (' || x.n || ')', ', ') into v_bad
  from (select t.item, (select count(*) from public.inventory_items i where i.property_id = v_prop and i.name = t.item and i.is_active) n
        from (select distinct item from s116_photo_src) t) x
  where x.n <> 1;
  if v_bad is not null then raise exception 's116 item photos: item name does not match exactly one active item: %', v_bad; end if;

  select string_agg(t.supplier, ', ') into v_bad
  from (select distinct supplier from s116_photo_src) t
  where not exists (select 1 from public.inventory_suppliers s where s.property_id = v_prop and lower(btrim(s.name)) = lower(t.supplier));
  if v_bad is not null then raise exception 's116 item photos: supplier missing: %', v_bad; end if;

  insert into public.inventory_item_options(property_id, item_id, supplier_id, title, brand, price, image_url, source_url, is_usual, is_preferred, available, captured_at)
  select v_prop, i.id, s.id, t.title, t.brand, null, t.image_url, t.source_url, false, false, true, timestamptz '2026-11-11 12:00+08'
  from s116_photo_src t
  join public.inventory_items i on i.property_id = v_prop and i.name = t.item and i.is_active
  join public.inventory_suppliers s on s.property_id = v_prop and lower(btrim(s.name)) = lower(t.supplier)
  on conflict (item_id, source_url) do nothing;
end
$d$;

commit;
