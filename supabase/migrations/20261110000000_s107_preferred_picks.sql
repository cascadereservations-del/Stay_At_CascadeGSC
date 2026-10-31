-- 20261110000000_s107_preferred_picks.sql
-- Session 107, lane SQL: release s107_preferred_picks_20261110 (phase expand). Lloyd's preferred products become flagged options under their stock items.
--   1. Column   inventory_item_options.is_preferred boolean not null default false.
--   2. Check    image_url also accepts the Shopee image host (https://down-ph.img.susercontent.com/); the Shopify host stays; source_url already allows shopee.ph.
--   3. RPC      inventory_item_options_v1 now returns "preferred" per option and orders usual first, then preferred, then (finance: price, else title) as before.
--               inventory_item_option_set_usual_v1 keeps its signature, gates and result; its data part moves into the internal function
--               s_inventory_option_make_usual_v1(option) (no grants), which the data step below reuses so the pick logic is not copied.
--   4. Data     s_inventory_preferred_picks_v1() (internal, no grants, idempotent), called once: supplier Shopee, item 'All-Purpose Cleaner (Mr Muscle)',
--               19 picks upserted as preferred options (docs/s107/preferred-picks.json via docs/s107/gen-preferred-picks.mjs), the order-1 pick of each of the
--               11 items made the usual option and its supplier link preferred, Toiletries reduced to its two picks and its orphaned Shopsuki link removed.
-- Guarded: the migration refuses to run when the live s106 bodies of the two RPCs differ from the s106 migration text (md5 of prosrc with CR removed).

-- 1. column + check ------------------------------------------------------------------------------------------------------------------------
alter table public.inventory_item_options add column is_preferred boolean not null default false;
comment on column public.inventory_item_options.is_preferred is 'S107: one of the owner''s preferred products for the item. Shown with a Preferred badge right after the usual option.';

alter table public.inventory_item_options drop constraint inventory_item_options_image_url_check;
alter table public.inventory_item_options add constraint inventory_item_options_image_url_check
  check (image_url is null or image_url ~ '^https://(cdn\.shopify\.com|down-ph\.img\.susercontent\.com)/');

-- 2. guard: the live bodies must still be the s106 ones -------------------------------------------------------------------------------------
do $g$
begin
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.inventory_item_options_v1(uuid)'::regprocedure) is distinct from '2bc1ba6bfee6d8e63ca746e0fa6bd5a0' then
    raise exception 'inventory_item_options_v1 differs from the s106 body (expected md5 2bc1ba6bfee6d8e63ca746e0fa6bd5a0); stop and compare';
  end if;
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.inventory_item_option_set_usual_v1(uuid)'::regprocedure) is distinct from '6b8583c30c0c2cddf8d79fcbc9dbfa3b' then
    raise exception 'inventory_item_option_set_usual_v1 differs from the s106 body (expected md5 6b8583c30c0c2cddf8d79fcbc9dbfa3b); stop and compare';
  end if;
end
$g$;

-- 3. RPCs ----------------------------------------------------------------------------------------------------------------------------------
-- Changed from s106 only in: 'preferred', o.is_preferred in each option and "o.is_preferred desc" in the order.
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
                       'pack_size', o.pack_size, 'image_url', o.image_url, 'source_url', o.source_url, 'usual', o.is_usual, 'preferred', o.is_preferred, 'available', o.available,
                       'captured_at', o.captured_at)
    || case when v_fin then jsonb_build_object('price', o.price) else '{}'::jsonb end
    order by o.is_usual desc, o.is_preferred desc, case when v_fin then o.price end nulls last, lower(o.title), o.id), '[]'::jsonb) into v_list
  from public.inventory_item_options o join public.inventory_suppliers s on s.id = o.supplier_id
  where o.item_id = p_item_id;
  return jsonb_build_object('ok', true, 'item_id', p_item_id, 'options', v_list);
end;
$$;

-- The data part of set-usual, shared with the s107 data step. No gates here: only set_usual (after its gates) and the data step call it.
create or replace function public.s_inventory_option_make_usual_v1(p_option_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.inventory_item_options%rowtype; v_label text;
begin
  select * into o from public.inventory_item_options x where x.id = p_option_id;
  if not found then raise exception using errcode = 'P0002', message = 'option not found'; end if;
  v_label := left(coalesce(nullif(btrim(o.pack_label), ''),
                           case when o.brand is null or starts_with(lower(o.title), lower(o.brand)) then o.title else o.brand || ' ' || o.title end), 40);
  update public.inventory_item_options set is_usual = false where item_id = o.item_id and is_usual and id <> o.id;
  update public.inventory_item_options set is_usual = true where id = o.id and not is_usual;
  update public.inventory_item_suppliers set is_preferred = false where item_id = o.item_id and supplier_id <> o.supplier_id and is_preferred;
  insert into public.inventory_item_suppliers as k(item_id, supplier_id, pack_label, pack_size, quoted_pack_price, is_preferred)
  values (o.item_id, o.supplier_id, v_label, o.pack_size, o.price, true)
  on conflict (item_id, supplier_id) do update
    set pack_label = excluded.pack_label, pack_size = coalesce(excluded.pack_size, k.pack_size), quoted_pack_price = coalesce(excluded.quoted_pack_price, k.quoted_pack_price), is_preferred = true;
end;
$$;

-- Signature, gates and result are the s106 ones; only the data part is now the shared function.
create or replace function public.inventory_item_option_set_usual_v1(p_option_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o public.inventory_item_options%rowtype; v_prop uuid;
begin
  select * into o from public.inventory_item_options x where x.id = p_option_id for update;
  if found then perform 1 from public.inventory_items where id = o.item_id for update; end if; -- s106 review: serialise set-usual per item
  if not found then raise exception using errcode = 'P0002', message = 'option not found'; end if;
  perform public.admin_require('manage_inventory', o.property_id);
  select i.property_id into v_prop from public.inventory_items i where i.id = o.item_id;
  if v_prop is distinct from o.property_id then raise exception using errcode = '22023', message = 'option does not belong to the item property'; end if;
  if not exists (select 1 from public.inventory_suppliers s where s.id = o.supplier_id and s.property_id = o.property_id) then
    raise exception using errcode = '22023', message = 'supplier does not belong to the option property';
  end if;
  perform public.s_inventory_option_make_usual_v1(o.id);
  return public.inventory_item_options_v1(o.item_id);
end;
$$;

revoke all on function public.inventory_item_options_v1(uuid) from public, anon, service_role;
revoke all on function public.inventory_item_option_set_usual_v1(uuid) from public, anon, service_role;
grant execute on function public.inventory_item_options_v1(uuid) to authenticated;
grant execute on function public.inventory_item_option_set_usual_v1(uuid) to authenticated;
revoke all on function public.s_inventory_option_make_usual_v1(uuid) from public, anon, authenticated, service_role;

-- 4. data step -----------------------------------------------------------------------------------------------------------------------------
-- Internal and idempotent: a second run inserts, changes and deletes nothing (the upsert only writes rows that differ). No grants.
create or replace function public.s_inventory_preferred_picks_v1()
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  v_toil constant uuid := '2ec811c2-4ccc-4885-a8a5-3a8002e791b0';
  v_shopsuki uuid; v_shopee uuid; v_item uuid; v_oid uuid; v_n int;
  v_sup int; v_new int; v_opt int := 0; v_del int; v_lnk int;
  v_usual uuid[] := '{}'; v_toil_urls text[] := '{}'; r record;
begin
  if not exists (select 1 from public.properties where id = v_prop) then return jsonb_build_object('skipped', 'property missing'); end if;
  select s.id into v_shopsuki from public.inventory_suppliers s where s.property_id = v_prop and lower(btrim(s.name)) = 'shopsuki';
  if v_shopsuki is null then raise exception 'Shopsuki supplier missing: apply the s106 release first'; end if;

  insert into public.inventory_suppliers(property_id, name, location, maps_url, payment_method, notes)
  values (v_prop, 'Shopee', 'Online (Shopee)', null, 'online', 'Prices read from shopee.ph on 2026-10-31')
  on conflict do nothing;
  get diagnostics v_sup = row_count;
  select s.id into v_shopee from public.inventory_suppliers s where s.property_id = v_prop and lower(btrim(s.name)) = 'shopee';

  insert into public.inventory_items(property_id, name, category, unit, reorder_below, is_consumable, is_active)
  select v_prop, 'All-Purpose Cleaner (Mr Muscle)', 'Cleaning Supplies', 'pc', 1, true, true
  where not exists (select 1 from public.inventory_items i where i.property_id = v_prop and lower(btrim(i.name)) = lower('All-Purpose Cleaner (Mr Muscle)'));
  get diagnostics v_new = row_count;

  for r in
    select * from (values
    -- BEGIN GENERATED picks (node docs/s107/gen-preferred-picks.mjs)
    ('66c7ec14-b20c-450d-9576-492c56e6d1c1'::uuid, 'Natural Air', 1, 'shopsuki', 'Ambi Pur Gel Room Fresh Downy 180g', 'Ambi Pur', 184.25::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4987176133458_ffd73b18-f762-4742-b8eb-70c208db0cd7.jpg', 'https://shopsuki.ph/products/ambi-pur-gel-room-fresh-downy-180g', null::numeric),
    ('513ffc56-3f9d-4e58-a061-3747d7c31189'::uuid, 'Baygon Spray', 1, 'shopsuki', 'ARS Jet Gold Multi Insect Killer 600ml', 'ARS', 329.65::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/8850273103814.jpg', 'https://shopsuki.ph/products/ars-jet-gold-multi-insect-killer-600ml', null::numeric),
    ('e79e4de3-7bfa-4d9d-845c-58f5e038ce03'::uuid, 'Breeze Fabric Conditioner Liquid', 1, 'shopsuki', 'Breeze Liquid Detergent Frontload 60ml', 'Breeze', 15.55::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/8934868146582.jpg', 'https://shopsuki.ph/products/breeze-liquid-detergent-frontload-60ml', null::numeric),
    ('e79e4de3-7bfa-4d9d-845c-58f5e038ce03'::uuid, 'Breeze Fabric Conditioner Liquid', 2, 'shopsuki', 'Breeze Power Machine Liquid Detergent Ultraclean Concentrate 60ml', 'Breeze', 15.70::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/105615709.jpg', 'https://shopsuki.ph/products/breeze-power-machine-liquid-detergent-ultraclean-concentrate-60ml', null::numeric),
    ('0bdd783a-77f8-4211-bf53-e1cbebcc284b'::uuid, 'Liquid Hand Soap (Safeguard)', 1, 'shopsuki', 'Green Cross Antibacterial Hand Soap 450ml', 'Green Cross', 112.90::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4800047866029.jpg', 'https://shopsuki.ph/products/green-cross-antibacterial-hand-soap-450ml', null::numeric),
    ('3179e10e-105f-47eb-8955-c2c2111948f8'::uuid, 'Liquid Body Soap (Dove)', 1, 'shopee', 'Lifebuoy Antibacterial Bodywash Refill Total 10 450ml', 'Lifebuoy', 163.00::numeric, true, 'https://down-ph.img.susercontent.com/file/ph-11134207-7rask-m4ilg3yr5r0917', 'https://shopee.ph/product/238345847/8627214070', null::numeric),
    ('3179e10e-105f-47eb-8955-c2c2111948f8'::uuid, 'Liquid Body Soap (Dove)', 2, 'shopsuki', 'Safeguard Body Wash Pure White SUP', 'Safeguard', 228.75::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/108983683.jpg', 'https://shopsuki.ph/products/safeguard-body-wash-pure-white-sup', null::numeric),
    ('2137c758-5b95-46d6-8810-2364100b2dda'::uuid, 'Mr Muscle Mold & Mildew (Orange)', 1, 'shopsuki', 'Mr Muscle Mold & Mildew Killer Primary 500ml', 'Mr Muscle', 194.05::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/mr-muscle-mold-and-mildew-killer-primary-500ml.jpg', 'https://shopsuki.ph/products/mr-muscle-mold-mildew-killer-primary-500ml', null::numeric),
    (null::uuid, 'All-Purpose Cleaner (Mr Muscle)', 1, 'shopsuki', 'Mr Muscle All Purpose Cleaner Lavender 3.7L', 'Mr Muscle', 420.35::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/108179395.jpg', 'https://shopsuki.ph/products/mr-muscle-all-purpose-cleaner-lavender-3-7l', null::numeric),
    (null::uuid, 'All-Purpose Cleaner (Mr Muscle)', 2, 'shopee', 'Mr. Muscle All Purpose Cleaner - Lavender 3.7L', 'Mr Muscle', 559.00::numeric, true, 'https://down-ph.img.susercontent.com/file/ph-11134207-7rase-m8vr4ogrbmhq19', 'https://shopee.ph/product/238345847/7078169120', null::numeric),
    ('2ec811c2-4ccc-4885-a8a5-3a8002e791b0'::uuid, 'Toiletries (toothbrush, toothpaste, soap)', 1, 'shopee', 'Hotel Guest Kit Set 100 sets (toothbrush, toothpaste, shampoo, soap, with box) FFH Hotel - Black-B1', 'FFH Hotel', 1329.00::numeric, true, 'https://down-ph.img.susercontent.com/file/ph-11134207-7rase-m7jbc8uuu4zd71', 'https://shopee.ph/product/814013609/28130171038', 100::numeric),
    ('2ec811c2-4ccc-4885-a8a5-3a8002e791b0'::uuid, 'Toiletries (toothbrush, toothpaste, soap)', 2, 'shopee', 'Hotel Guest Kit 5-in-1, 100 pcs (toothbrush, toothpaste, shampoo) - Blue type 2', 'Hotel Kit', 1220.00::numeric, true, 'https://down-ph.img.susercontent.com/file/ph-11134207-820l4-muyqn2t8u9kyd3', 'https://shopee.ph/product/569141117/45906538836', 100::numeric),
    ('da50acdc-1107-4574-ac9e-f2ecd951ed5a'::uuid, 'Coffee (3-in-1)', 1, 'shopsuki', 'Nescafe Classic Sticks 1.9g x 48''s', 'Nestle', 157.20::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/104692522.jpg', 'https://shopsuki.ph/products/nescafe-classic-sticks-1-9g-by-48s', 48::numeric),
    ('da50acdc-1107-4574-ac9e-f2ecd951ed5a'::uuid, 'Coffee (3-in-1)', 2, 'shopsuki', 'Nescafe 3 in 1 Coffee Mix Creamy Latte 20g x 20''s', 'Nestle', 186.15::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/4800361426589.jpg', 'https://shopsuki.ph/products/nescafe-3-in-1-coffee-mix-creamy-latte-20g-x-20s', 20::numeric),
    ('dfb24285-06a5-4e6d-9e6c-a24b23e73bc8'::uuid, 'Shampoo (Palmolive)', 1, 'shopsuki', 'Palmolive Natural Shampoo And Conditioner Intensive Moisture Coconut Cream Refill Pack 600ml', 'Palmolive', 305.40::numeric, true, 'https://cdn.shopify.com/s/files/1/0358/1335/9748/files/109411851.jpg', 'https://shopsuki.ph/products/palmolive-natural-shampoo-and-conditioner-intensive-moisture-coconut-cream-refill-pack-600ml', null::numeric),
    ('dfb24285-06a5-4e6d-9e6c-a24b23e73bc8'::uuid, 'Shampoo (Palmolive)', 2, 'shopee', 'Palmolive Naturals Shampoo with Coconut Cream 600ml Refill, Value Pack of 3 (buy 2, free 1)', 'Palmolive', 885.00::numeric, true, 'https://down-ph.img.susercontent.com/file/ph-11134201-820lg-mu7ollxsc7ba60', 'https://shopee.ph/product/238345847/53319103966', 3::numeric),
    ('4f139d96-f1fa-4be6-bbf2-a593a5383202'::uuid, 'Tissues / Paper Towels', 1, 'shopee', 'Botare Air-cushion Deluxe Comfort Tissue 4-ply 400 sheets, 20 packs', 'Botare', 399.00::numeric, true, 'https://down-ph.img.susercontent.com/file/cn-11134207-7r98o-lwi7rdyrx9vp1d', 'https://shopee.ph/product/972814538/29003586262', 20::numeric),
    ('4f139d96-f1fa-4be6-bbf2-a593a5383202'::uuid, 'Tissues / Paper Towels', 2, 'shopee', 'Botare 4-ply Facial Tissue 8000 sheets, 20 packs (Basic)', 'Botare', 298.00::numeric, true, 'https://down-ph.img.susercontent.com/file/cn-11134207-820l4-mt3pcazbz7k6dd', 'https://shopee.ph/product/1668619042/55355724148', 20::numeric),
    ('4f139d96-f1fa-4be6-bbf2-a593a5383202'::uuid, 'Tissues / Paper Towels', 3, 'shopee', 'Botare Bow Cute Air-cushion Deluxe Tissue 4-ply 1280 sheets, napkin box 6 pcs', 'Botare', 499.00::numeric, true, 'https://down-ph.img.susercontent.com/file/sg-11134201-7raui-mb26h3xusvv401', 'https://shopee.ph/product/972814538/44204658417', 6::numeric)
    -- END GENERATED picks
    ) as v(item_id, item_name, ord, store, title, brand, price, available, image_url, url, pack_size)
    order by v.item_name, v.ord
  loop
    select i.id into v_item from public.inventory_items i
     where i.property_id = v_prop and (i.id = r.item_id or (r.item_id is null and lower(btrim(i.name)) = lower(r.item_name)));
    if v_item is null then raise exception 'pick item missing: %', r.item_name; end if;

    insert into public.inventory_item_options as o(property_id, item_id, supplier_id, title, brand, price, image_url, source_url, available, pack_size, is_preferred, captured_at)
    values (v_prop, v_item, case r.store when 'shopee' then v_shopee else v_shopsuki end, r.title, r.brand, r.price, r.image_url, r.url, r.available, r.pack_size, true,
            timestamptz '2026-10-31 16:00+08')
    on conflict (item_id, source_url) do update
      set title = excluded.title, brand = excluded.brand, price = excluded.price, image_url = excluded.image_url, available = excluded.available,
          supplier_id = excluded.supplier_id, pack_size = coalesce(excluded.pack_size, o.pack_size), is_preferred = true
      where (o.title, o.brand, o.price, o.image_url, o.available, o.supplier_id, o.pack_size, o.is_preferred)
            is distinct from (excluded.title, excluded.brand, excluded.price, excluded.image_url, excluded.available, excluded.supplier_id, coalesce(excluded.pack_size, o.pack_size), true);
    get diagnostics v_n = row_count;
    v_opt := v_opt + v_n;

    select o.id into v_oid from public.inventory_item_options o where o.item_id = v_item and o.source_url = r.url;
    if r.ord = 1 then v_usual := v_usual || v_oid; end if;
    if v_item = v_toil then v_toil_urls := v_toil_urls || r.url; end if;
  end loop;

  -- Toiletries holds only its two picks.
  delete from public.inventory_item_options o where o.item_id = v_toil and (o.source_url is null or o.source_url <> all (v_toil_urls));
  get diagnostics v_del = row_count;

  -- The order-1 pick of each item becomes the usual option, exactly as inventory_item_option_set_usual_v1 does it.
  foreach v_oid in array v_usual loop
    perform public.s_inventory_option_make_usual_v1(v_oid);
  end loop;

  -- A Shopsuki link on Toiletries that no Shopsuki option backs any more (s106 made one) is an orphan once the Shopee kit is the usual one.
  delete from public.inventory_item_suppliers k
   where k.item_id = v_toil and k.supplier_id = v_shopsuki and not k.is_preferred
     and not exists (select 1 from public.inventory_item_options o where o.item_id = k.item_id and o.supplier_id = k.supplier_id);
  get diagnostics v_lnk = row_count;

  return jsonb_build_object('suppliers', v_sup, 'items', v_new, 'options', v_opt, 'removed', v_del, 'usual', cardinality(v_usual), 'links_removed', v_lnk);
end;
$$;
revoke all on function public.s_inventory_preferred_picks_v1() from public, anon, authenticated, service_role;
select public.s_inventory_preferred_picks_v1();
