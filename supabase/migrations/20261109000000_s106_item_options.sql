-- 20261109000000_s106_item_options.sql
-- Session 106, lane SQL: release s106_item_options_20261109 (phase expand). Brands and sizes become OPTIONS under one stock item (Lloyd).
--   1. Table  inventory_item_options: many options per item and supplier (inventory_item_suppliers keeps one row per item and supplier). RLS on, no grants to
--             any client role, not in the realtime publication; all access through the two definer RPCs below.
--   2. RPCs   inventory_item_options_v1(item)            read_operations; price key only when read_finance passes (a cleaner never gets it).
--             inventory_item_option_set_usual_v1(option) manage_inventory (the gate inventory_item_supplier_link_v1 uses for preferred); flips the usual option and
--                                                         upserts the item/supplier link as preferred with the option's pack label and price.
--   3. Seed   supplier Shopsuki + 60 options read from shopsuki.ph on 2026-10-31 + one preferred link per item that has none (18 items). Generated from
--             docs/s106/shopsuki-capture.json by docs/s106/gen-item-options-seed.mjs. The seed lives in an internal function (no grants) so a test can re-run it.
-- Additive only: no existing table, column, policy or function is changed.

-- 1. table ---------------------------------------------------------------------------------------------------------------------------------
create table public.inventory_item_options (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete restrict,
  item_id uuid not null references public.inventory_items(id) on delete cascade,
  supplier_id uuid not null references public.inventory_suppliers(id) on delete restrict,
  title text not null check (char_length(btrim(title)) between 1 and 160),
  brand text check (brand is null or char_length(brand) <= 60),
  pack_label text check (pack_label is null or char_length(pack_label) <= 40),
  pack_size numeric check (pack_size is null or (pack_size > 0 and pack_size < 100000)),
  price numeric(10,2) check (price is null or (price > 0 and price < 1000000)),
  image_url text check (image_url is null or image_url ~ '^https://cdn\.shopify\.com/'),
  source_url text check (source_url is null or source_url ~ '^https://(shopsuki\.ph|shopee\.ph)/'),
  is_usual boolean not null default false,
  available boolean,
  captured_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint inventory_item_options_item_source_uq unique (item_id, source_url)
);
create unique index inventory_item_options_one_usual on public.inventory_item_options (item_id) where is_usual;
create index inventory_item_options_supplier_idx on public.inventory_item_options (supplier_id);
alter table public.inventory_item_options enable row level security;
revoke all on table public.inventory_item_options from public, anon, authenticated, service_role;
create trigger inventory_item_options_updated_at before update on public.inventory_item_options for each row execute function public.set_updated_at();
comment on table public.inventory_item_options is 'S106: brand/size options for one stock item (several per supplier). No client access: read and written through the inventory_item_option* definer RPCs; price is shown only to read_finance.';

-- 2. RPCs ----------------------------------------------------------------------------------------------------------------------------------
-- Options of one item, usual first, then cheapest first (price order only for read_finance, so a cleaner cannot rank by price either).
create or replace function public.inventory_item_options_v1(p_item_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_prop uuid; v_fin boolean; v_list jsonb;
begin
  select i.property_id into v_prop from public.inventory_items i where i.id = p_item_id;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('read_operations', v_prop);
  v_fin := public.finance_human_authorized(v_prop);
  select coalesce(jsonb_agg(
    jsonb_build_object('id', o.id, 'supplier_id', o.supplier_id, 'supplier', s.name, 'title', o.title, 'brand', o.brand, 'pack_label', o.pack_label,
                       'pack_size', o.pack_size, 'image_url', o.image_url, 'source_url', o.source_url, 'usual', o.is_usual, 'available', o.available,
                       'captured_at', o.captured_at)
    || case when v_fin then jsonb_build_object('price', o.price) else '{}'::jsonb end
    order by o.is_usual desc, case when v_fin then o.price end nulls last, lower(o.title), o.id), '[]'::jsonb) into v_list
  from public.inventory_item_options o join public.inventory_suppliers s on s.id = o.supplier_id
  where o.item_id = p_item_id;
  return jsonb_build_object('ok', true, 'item_id', p_item_id, 'options', v_list);
end;
$$;

-- Make one option the usual one. Idempotent. The quoted price comes from the option row, never from the caller.
create or replace function public.inventory_item_option_set_usual_v1(p_option_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o public.inventory_item_options%rowtype; v_prop uuid; v_label text;
begin
  select * into o from public.inventory_item_options x where x.id = p_option_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'option not found'; end if;
  perform public.admin_require('manage_inventory', o.property_id);
  select i.property_id into v_prop from public.inventory_items i where i.id = o.item_id;
  if v_prop is distinct from o.property_id then raise exception using errcode = '22023', message = 'option does not belong to the item property'; end if;
  if not exists (select 1 from public.inventory_suppliers s where s.id = o.supplier_id and s.property_id = o.property_id) then
    raise exception using errcode = '22023', message = 'supplier does not belong to the option property';
  end if;
  v_label := left(coalesce(nullif(btrim(o.pack_label), ''),
                           case when o.brand is null or starts_with(lower(o.title), lower(o.brand)) then o.title else o.brand || ' ' || o.title end), 40);
  update public.inventory_item_options set is_usual = false where item_id = o.item_id and is_usual and id <> o.id;
  update public.inventory_item_options set is_usual = true where id = o.id and not is_usual;
  update public.inventory_item_suppliers set is_preferred = false where item_id = o.item_id and supplier_id <> o.supplier_id and is_preferred;
  insert into public.inventory_item_suppliers as k(item_id, supplier_id, pack_label, pack_size, quoted_pack_price, is_preferred)
  values (o.item_id, o.supplier_id, v_label, o.pack_size, o.price, true)
  on conflict (item_id, supplier_id) do update
    set pack_label = excluded.pack_label, pack_size = coalesce(excluded.pack_size, k.pack_size), quoted_pack_price = excluded.quoted_pack_price, is_preferred = true;
  return public.inventory_item_options_v1(o.item_id);
end;
$$;

revoke all on function public.inventory_item_options_v1(uuid) from public, anon, service_role;
revoke all on function public.inventory_item_option_set_usual_v1(uuid) from public, anon, service_role;
grant execute on function public.inventory_item_options_v1(uuid) to authenticated;
grant execute on function public.inventory_item_option_set_usual_v1(uuid) to authenticated;

-- 3. seed ----------------------------------------------------------------------------------------------------------------------------------
-- Internal and idempotent (ON CONFLICT DO NOTHING everywhere). No grants: only the migration and the test owner run it.
create or replace function public.s_inventory_item_options_seed_v1()
returns jsonb language plpgsql set search_path = '' as $$
declare v_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'; v_sid uuid; v_sup int; v_opt int; v_lnk int;
begin
  if not exists (select 1 from public.properties where id = v_prop) then return jsonb_build_object('skipped', 'property missing'); end if;
  insert into public.inventory_suppliers(property_id, name, location, maps_url, payment_method, notes)
  values (v_prop, 'Shopsuki', 'Online delivery, General Santos', null, 'online', 'Prices read from shopsuki.ph on 2026-10-31')
  on conflict do nothing;
  get diagnostics v_sup = row_count;
  select s.id into v_sid from public.inventory_suppliers s where s.property_id = v_prop and lower(btrim(s.name)) = 'shopsuki';

  insert into public.inventory_item_options(property_id, item_id, supplier_id, title, brand, price, image_url, source_url, is_usual, available, captured_at)
  select i.property_id, i.id, v_sid, v.title, v.brand, v.price, v.image_url, 'https://shopsuki.ph/products/' || v.handle, v.usual, v.available, timestamptz '2026-10-31 16:00+08'
  from (values
    -- BEGIN GENERATED (node docs/s106/gen-item-options-seed.mjs)
    ('58d951d1-1455-4157-9820-6b15d02309ff'::uuid, true, 'Ambi Pur Air Freshener Spray Blossom And Breeze 275g', 'Ambi Pur', 262.50::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4902430304726.jpg', 'ambi-pur-air-freshener-spray-blossom-and-breeze-275g'),
    ('58d951d1-1455-4157-9820-6b15d02309ff'::uuid, false, 'Ambi Pur Air Freshener Spray Lavender Vanilla And Comfort 275g', 'Ambi Pur', 262.50::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/103692375.png', 'ambi-pur-air-freshener-spray-lavender-vanilla-and-comfort-275g'),
    ('58d951d1-1455-4157-9820-6b15d02309ff'::uuid, false, 'Ambi Pur Gel Fresh Refreshing Lemon Value Pack 180g x 2''s', 'Ambi Pur', 283.50::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/products/4902430518291.jpg', 'ambi-pur-gel-fresh-refreshing-lemon-value-pack-180g-by-2s'),
    ('513ffc56-3f9d-4e58-a061-3747d7c31189'::uuid, true, 'Baygon Multi Insect Killer Aerosol Kerosene Based 500ml', 'Baygon', 352.55::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4801234108021.jpg', 'baygon-multi-insect-killer-aerosol-kerosene-based-500ml'),
    ('513ffc56-3f9d-4e58-a061-3747d7c31189'::uuid, false, 'Baygon Multi Insect Killer Aerosol Kerosene Based 300ml', 'Baygon', 238.90::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4801234108014.jpg', 'baygon-multi-insect-killer-aerosol-kerosene-based-300ml'),
    ('513ffc56-3f9d-4e58-a061-3747d7c31189'::uuid, false, 'Baygon Multi Insect Killer Odorless 500ml', 'Baygon', 413.05::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/106162544.jpg', 'baygon-multi-insect-killer-odorless-500ml'),
    ('513ffc56-3f9d-4e58-a061-3747d7c31189'::uuid, false, 'Baygon Aerosol Anti Dengue Mosquito Killer 500ml', 'Baygon', 425.25::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4801234106027.jpg', 'baygon-aerosol-anti-dengue-mosquito-killer-500ml'),
    ('e79e4de3-7bfa-4d9d-845c-58f5e038ce03'::uuid, true, 'Breeze Advanced Liquid Power Machine Fresh Clean 535g', 'Breeze', 123.25::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4800888290182.jpg', 'breeze-advanced-liquid-power-machine-fresh-clean-535g'),
    ('e79e4de3-7bfa-4d9d-845c-58f5e038ce03'::uuid, false, 'Breeze Advanced Liquid Power Machine Rose Gold 1.27kg', 'Breeze', 284.20::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4800888290212.jpg', 'breeze-advanced-liquid-power-machine-rose-gold-1-27kg'),
    ('e79e4de3-7bfa-4d9d-845c-58f5e038ce03'::uuid, false, 'Breeze Liquid Detergent Power Machine Luxe Red 950g', 'Breeze', 212.95::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/8934868182535_cd79576f-2e06-40ab-8803-90525bd57fcf.jpg', 'breeze-liquid-detergent-power-machine-luxe-red-950g'),
    ('2bfc792f-9520-4ae1-8b20-dd5afa4a2ab5'::uuid, true, 'Joy Dishwashing Liquid Kalamansi 375ml', 'Joy', 115.65::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/110375265.jpg', 'joy-dishwashing-liquid-kalamansi-375ml'),
    ('2bfc792f-9520-4ae1-8b20-dd5afa4a2ab5'::uuid, false, 'Joy Dishwashing Liquid Lemon Pouch 355ml', 'Joy', 115.30::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/107390382.jpg', 'joy-dishwashing-liquid-lemon-pouch-355ml'),
    ('2bfc792f-9520-4ae1-8b20-dd5afa4a2ab5'::uuid, false, 'Joy Dishwashing Liquid Lemon 250ml', 'Joy', 86.85::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4902430093767.jpg', 'joy-dishwashing-liquid-lemon-250ml'),
    ('2bfc792f-9520-4ae1-8b20-dd5afa4a2ab5'::uuid, false, 'Joy Dishwashing Liquid Kalamansi SUP 1050ml', 'Joy', 286.95::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/108188891.jpg', 'joy-dishwashing-liquid-kalamansi-sup-1050ml'),
    ('360a6b10-c8a7-42e1-885e-98d98f382775'::uuid, true, 'MNM Garbage Bag Large', 'MNM', 61.80::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/1234603225808.jpg', 'mnm-garbage-bag-large'),
    ('360a6b10-c8a7-42e1-885e-98d98f382775'::uuid, false, 'MNM Garbage Bag XL 10''s', 'MNM', 75.05::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/108177724.jpg', 'mnm-garbage-bag-xl-10s'),
    ('360a6b10-c8a7-42e1-885e-98d98f382775'::uuid, false, 'Calypso Garbage Bag Seals Large 26in x 32in 10''s', 'Calypso', 49.20::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4806507662125.jpg', 'calypso-garbage-bag-seals-large-26in-x-32in-10s'),
    ('ae72de9a-871d-43ea-b07a-0fd9427bfc9c'::uuid, true, 'MNM Garbage Bag Small', 'MNM', 32.05::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/108180556.png', 'mnm-garbage-bag-small'),
    ('ae72de9a-871d-43ea-b07a-0fd9427bfc9c'::uuid, false, 'Calypso Garbage Bag Seals 11 in x 11 in x 24 in 10''s', 'Calypso', 28.65::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/102050463.jpg', 'calypso-garbage-bag-seals-medium-22in-x-24in-10s'),
    ('ae72de9a-871d-43ea-b07a-0fd9427bfc9c'::uuid, false, 'MNM Garbage Bag Medium', 'MNM', 50.35::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/108177704.png', 'mnm-garbage-bag-medium'),
    ('691e93b7-0e99-44eb-b1dd-adb70ddd7f9c'::uuid, true, 'Lysol Liquid Disinfectant Spray Crisp Linen 510g', 'Lysol', 627.30::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/products/9556111408088.jpg', 'lysol-liquid-disinfectant-spray-crisp-linen-510g'),
    ('691e93b7-0e99-44eb-b1dd-adb70ddd7f9c'::uuid, false, 'Lysol Liquid Disinfectant Spray Crisp Linen 170g', 'Lysol', 281.10::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/products/102064969.png', 'lysol-liquid-disinfectant-spray-crisp-linen-170g'),
    ('691e93b7-0e99-44eb-b1dd-adb70ddd7f9c'::uuid, false, 'Lysol Liquid Disinfectant Spray Fresh Blossoms 510g', 'Lysol', 627.30::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/products/4801002062883.jpg', 'lysol-liquid-disinfectant-spray-fresh-blossoms-510g'),
    ('744dcd36-f1b5-4ed9-b8b4-e2564d02675e'::uuid, true, 'Mr Muscle Glass And Multi Surface Cleaner Spray Fresh Fragrance 350ml', 'Mr Muscle', 157.95::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/9555222610625.jpg', 'mr-muscle-glass-and-multi-surface-cleaner-spray-fresh-fragrance-350ml'),
    ('744dcd36-f1b5-4ed9-b8b4-e2564d02675e'::uuid, false, 'Mr Muscle Glass and Multi Surface Cleaner Fresh Fragrance Refill 500ml', 'Mr Muscle', 108.40::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/products/4801234072629.jpg', 'mr-muscle-glass-and-multi-surface-cleaner-fresh-fragrance-refill-500ml'),
    ('744dcd36-f1b5-4ed9-b8b4-e2564d02675e'::uuid, false, 'Mr Muscle Glass and Multi-Surface Cleaner Fresh Refill 300ml', 'Mr Muscle', 76.55::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/9555222611103.jpg', 'mr-muscle-glass-and-multi-surface-cleaner-fresh-refill-300ml'),
    ('2137c758-5b95-46d6-8810-2364100b2dda'::uuid, true, 'Mr Muscle Mold & Mildew Killer Primary 500ml', 'Mr Muscle', 194.05::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/mr-muscle-mold-and-mildew-killer-primary-500ml.jpg', 'mr-muscle-mold-mildew-killer-primary-500ml'),
    ('2137c758-5b95-46d6-8810-2364100b2dda'::uuid, false, 'Mr Muscle Mold & Mildew Killer Refill 500ml', 'Mr Muscle', 181.35::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/products/4801234072124.jpg', 'mr-muscle-mold-mildew-killer-refill-500ml'),
    ('c44552af-014b-46fd-a489-50695ecd465d'::uuid, true, 'Nature''s Spring Purified Water 500ml', 'Nature''s Spring', 10.05::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4800049720114.jpg', 'natures-spring-purified-water-500ml'),
    ('c44552af-014b-46fd-a489-50695ecd465d'::uuid, false, 'Wet Drinking Water 500ml', 'Wet', 8.65::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4800049720190.jpg', 'wet-drinking-water-500ml'),
    ('c44552af-014b-46fd-a489-50695ecd465d'::uuid, false, 'Summit Mineral Water 500ml', 'Summit', 11.80::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4800014141081.jpg', 'summit-mineral-water-500ml'),
    ('c44552af-014b-46fd-a489-50695ecd465d'::uuid, false, 'Absolute Distilled Water 500ml', 'Absolute', 16.30::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4800014144082.jpg', 'absolute-distilled-water-500ml'),
    ('da50acdc-1107-4574-ac9e-f2ecd951ed5a'::uuid, true, 'Nescafe 3 in 1 Coffee Mix Creamy White 25.5g', 'Nestle', 9.00::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/105123009.jpg', 'nescafe-3-in-1-coffee-mix-creamy-white-25-5g'),
    ('da50acdc-1107-4574-ac9e-f2ecd951ed5a'::uuid, false, 'Nescafe 3 in 1 Coffee Mix Creamy Latte 20g x 20''s', 'Nestle', 186.15::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4800361426589.jpg', 'nescafe-3-in-1-coffee-mix-creamy-latte-20g-x-20s'),
    ('da50acdc-1107-4574-ac9e-f2ecd951ed5a'::uuid, false, 'Nescafe 3 in 1 coffee Mix Creamylatte Twin Pack 40g x 10''s', 'Nescafe', 131.40::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/110411499_bda72166-cf03-4f07-a726-170cdeb46793.jpg', 'nescafe-3-in-1-coffee-mix-creamylatte-twin-pack-40g-x-10-s'),
    ('837afa3f-ace3-4e30-bc70-c9bc2c90e92c'::uuid, true, 'ECB White Sugar Sachet 7g x 50''s', 'ECB', 73.55::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/102053406.png', 'ecb-white-sugar-sachet-7g-by-50s'),
    ('837afa3f-ace3-4e30-bc70-c9bc2c90e92c'::uuid, false, 'ECB Brown Sugar Sachet 7g x 50''s', 'ECB', 61.45::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/102053405_1.png', 'ecb-brown-sugar-sachet-7g-by-50s'),
    ('837afa3f-ace3-4e30-bc70-c9bc2c90e92c'::uuid, false, 'Coffeemate Coffee Creamer 5g x 48''s', 'Nestle', 99.80::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/103019116.jpg', 'coffeemate-coffee-creamer-5g-by-48s'),
    ('837afa3f-ace3-4e30-bc70-c9bc2c90e92c'::uuid, false, 'Coffeemate Creamer 5g x 24''s', 'Nestle', 52.85::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/109720694_0232d758-7f7e-4ca3-9b0a-70f5c152cdc3.jpg', 'coffeemate-creamer-5g-x-24-s'),
    ('73757510-887b-4a5c-a54b-ab65505392aa'::uuid, true, 'Lipton Yellow Label Tea 2g x 50''s', 'Lipton', 307.55::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/8888086022008.jpg', 'lipton-yellow-label-tea-2g-by-50s'),
    ('73757510-887b-4a5c-a54b-ab65505392aa'::uuid, false, 'Lipton Green Tea Fresh 1.5g x 10''s', 'Lipton', 114.45::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/8999999057411.jpg', 'lipton-green-tea-fresh-1-5g-by-10s'),
    ('73757510-887b-4a5c-a54b-ab65505392aa'::uuid, false, 'Lipton Exclusive Selection Camomile Linden 1.3g x 25''s', 'Lipton', 377.65::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/8720608019977.jpg', 'lipton-exclusive-selection-camomile-linden-1-and-3g-by-25s'),
    ('3179e10e-105f-47eb-8955-c2c2111948f8'::uuid, true, 'Dove Body Wash Deeply Nourishing 400ml', 'Dove', 211.35::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/8934868080015.jpg', 'dove-body-wash-deeply-nourishing-400ml'),
    ('3179e10e-105f-47eb-8955-c2c2111948f8'::uuid, false, 'Dove Deeply Nourishing Body Wash 550ml', 'Dove', 274.20::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/107811601.jpg', 'dove-deeply-nourishing-body-wash-550ml'),
    ('3179e10e-105f-47eb-8955-c2c2111948f8'::uuid, false, 'Dove Body Wash Deeply Nourishing 1000ml', 'Dove', 455.00::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/108010581.jpg', 'dove-body-wash-deeply-nourishing-1000ml'),
    ('0bdd783a-77f8-4211-bf53-e1cbebcc284b'::uuid, true, 'Safeguard Liquid Hand Soap Pure White 450ml', 'Safeguard', 151.85::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/products/4902430805322_2.png', 'safeguard-liquid-hand-soap-pure-white-450ml'),
    ('0bdd783a-77f8-4211-bf53-e1cbebcc284b'::uuid, false, 'Safeguard Liquid Hand Soap Pure White Pouch 420ml', 'Safeguard', 121.35::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/products/4902430805346.png', 'safeguard-liquid-hand-soap-pure-white-pouch-420ml'),
    ('0bdd783a-77f8-4211-bf53-e1cbebcc284b'::uuid, false, 'Safeguard Liquid Hand Soap Pure White Pouch 200ml', 'Safeguard', 68.10::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4902430805384.jpg', 'safeguard-liquid-hand-soap-pure-white-pouch-200ml'),
    ('0bdd783a-77f8-4211-bf53-e1cbebcc284b'::uuid, false, 'Safeguard Liquid Hand Soap Floral Pink SUP 620ml', 'Safeguard', 180.00::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/108332832.png', 'safeguard-liquid-hand-soap-floral-pink-sup-620ml'),
    ('dfb24285-06a5-4e6d-9e6c-a24b23e73bc8'::uuid, true, 'Palmolive Naturals Shampoo And Conditioner Ultra Smooth 180ml', 'Palmolive', 142.70::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4808888411705.png', 'palmolive-naturals-shampoo-and-conditioner-ultra-smooth-180ml'),
    ('dfb24285-06a5-4e6d-9e6c-a24b23e73bc8'::uuid, false, 'Palmolive Naturals Shampoo And Conditioner Ultra Smooth 600ml', 'Palmolive', 334.85::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/108002156.jpg', 'palmolive-naturals-shampoo-and-conditioner-ultra-smooth-600ml'),
    ('dfb24285-06a5-4e6d-9e6c-a24b23e73bc8'::uuid, false, 'Palmolive Naturals Shampoo And Conditioner Ultra Smooth 180ml x 2''s', 'Palmolive', 212.60::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/107968436.jpg', 'palmolive-naturals-shampoo-and-conditioner-ultra-smooth-180ml-2s'),
    ('4f139d96-f1fa-4be6-bbf2-a593a5383202'::uuid, true, 'Femme Facial Tissue Econo Box 2ply 130 pulls', 'Femme', 59.00::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/products/4806502352113.jpg', 'femme-facial-tissue-econo-box-2ply-130-pulls'),
    ('4f139d96-f1fa-4be6-bbf2-a593a5383202'::uuid, false, 'Femme Facial Tissue Large Box 2ply 250 Pulls', 'Femme', 86.30::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/products/4806502352557.jpg', 'femme-facial-tissue-large-box-2ply-250-pulls'),
    ('4f139d96-f1fa-4be6-bbf2-a593a5383202'::uuid, false, 'Kami Interfolded Paper Towel 1 Ply 175 Pulls', 'Kami', 59.35::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/products/kami-house-care-kami-interfolded-paper-towel-1ply-175pulls-15556380754052.jpg', 'kami-interfolded-paper-towel-1-ply-175-pulls'),
    ('4f139d96-f1fa-4be6-bbf2-a593a5383202'::uuid, false, 'Tidy Interfolded Paper Towel White 175 Sheets x 3''s', 'Tidy', 152.85::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/108752904_4becad1b-caef-4fe6-a2af-ddae8d7f84a6.png', 'tidy-interfolded-paper-towel-white-175-sheets-x-3s'),
    ('2ec811c2-4ccc-4885-a8a5-3a8002e791b0'::uuid, true, 'Colgate Oral Care Travel Kit', 'Colgate', 88.95::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/102051508_4a51e63a-5f82-41d4-9641-71a9bcb7ae02.jpg', 'colgate-oral-care-travel-kit'),
    ('2ec811c2-4ccc-4885-a8a5-3a8002e791b0'::uuid, false, 'Colgate Toothbrush Extra Clean Buy 5''s', 'Colgate', 140.65::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/107799193.jpg', 'colgate-toothbrush-extra-clean-buy-5s'),
    ('2ec811c2-4ccc-4885-a8a5-3a8002e791b0'::uuid, false, 'Colgate Toothpaste Great Regular Flavor 74g', 'Colgate', 85.85::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/8850006320518.jpg', 'colgate-toothpaste-great-regular-flavor-74g'),
    ('2ec811c2-4ccc-4885-a8a5-3a8002e791b0'::uuid, false, 'Colgate Classic Deep Clean Toothbrush Medium x 2''s', 'Colgate', 37.00::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/8932102111335.jpg', 'colgate-classic-deep-clean-toothbrush-medium-x-2s')
    -- END GENERATED
  ) as v(item_id, usual, title, brand, price, available, image_url, handle)
  join public.inventory_items i on i.id = v.item_id and i.property_id = v_prop
  on conflict do nothing;
  get diagnostics v_opt = row_count;

  insert into public.inventory_item_suppliers(item_id, supplier_id, pack_label, quoted_pack_price, is_preferred)
  select o.item_id, o.supplier_id,
         left(coalesce(nullif(btrim(o.pack_label), ''), case when o.brand is null or starts_with(lower(o.title), lower(o.brand)) then o.title else o.brand || ' ' || o.title end), 40),
         o.price, true
  from public.inventory_item_options o
  where o.supplier_id = v_sid and o.is_usual
    and not exists (select 1 from public.inventory_item_suppliers k where k.item_id = o.item_id and k.is_preferred)
  on conflict do nothing;
  get diagnostics v_lnk = row_count;
  return jsonb_build_object('suppliers', v_sup, 'options', v_opt, 'links', v_lnk);
end;
$$;
revoke all on function public.s_inventory_item_options_seed_v1() from public, anon, authenticated, service_role;
select public.s_inventory_item_options_seed_v1();
