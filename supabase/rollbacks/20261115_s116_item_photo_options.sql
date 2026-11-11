-- Rollback for the second s116 migration (20261115000100_s116_item_photo_options): deletes only the 51 options it inserted (exact item name + source_url pairs),
-- then the two suppliers it added if nothing references them, then restores the s107 source_url check.
-- If another mandauefoam.ph / myhanabishi.com option exists by now, re-adding the old check fails and the whole script rolls back: resolve by hand.
begin;

delete from public.inventory_item_options o
using public.inventory_items i, (values
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
    ('Throw Pillowcase', 'https://mandauefoam.ph/products/mede-chenile-throw-pillowcase')
) p(item, source_url)
where i.id = o.item_id and i.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid and i.name = p.item and o.source_url = p.source_url;

delete from public.inventory_suppliers s
where s.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid and lower(btrim(s.name)) in ('mandaue foam', 'hanabishi')
  and not exists (select 1 from public.inventory_item_options x where x.supplier_id = s.id)
  and not exists (select 1 from public.inventory_item_suppliers x where x.supplier_id = s.id)
  and not exists (select 1 from public.inventory_purchases x where x.supplier_id = s.id)
  and not exists (select 1 from public.inventory_shopping_list x where x.supplier_id = s.id);

alter table public.inventory_item_options drop constraint inventory_item_options_source_url_check;
alter table public.inventory_item_options add constraint inventory_item_options_source_url_check
  check (source_url is null or source_url ~ '^https://(shopsuki\.ph|shopee\.ph)/');

commit;
