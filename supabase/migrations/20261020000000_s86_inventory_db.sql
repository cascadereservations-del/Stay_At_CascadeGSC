-- 20261020000000_s86_inventory_db.sql
-- Session 86, lane D-sql: release s86_inventory_db_20261020. Inventory becomes a database: suppliers, supplier links, price history, item photo path RPC,
-- storage location, category tidy, QR code minting, an automatic categoriser write, and the price basis fixed on the Telegram OCR path.
-- Spec: docs/s86/SPEC-inventory-db.md sections 2, 8 and 9 (9 overrides 8, 8 overrides 2); lane brief overrides O1-O5.
--   1. Tables     inventory_suppliers, inventory_item_suppliers (RLS on, no client grants, service_role select). supplier_id on inventory_purchases and
--                 inventory_shopping_list. inventory_items.location (+ column grant to authenticated; unit_cost stays closed).
--   2. Data       backfill suppliers from purchases (SM, KCC, Robinsons) and link them; delete the one 'test' purchase (Lloyd D-330, guarded: exactly one row,
--                 nothing references it; its values are in the rollback); tidy categories with one audit row per moved item (category_tidy_s86).
--   3. Price basis  inventory_purchases.unit_cost = PHP per base unit and qty = base units on BOTH write paths. apply_inventory_purchase (Telegram OCR) is
--                 rebuilt: it stores qty = packs x units_per_purchase and unit_cost = pack price / units_per_purchase, is now SECURITY DEFINER with an empty
--                 search_path (it was invoker rights, search_path public) and is executable by service_role ONLY (the bot). Both write paths take a supplier id.
--   4. RPCs       R1-R9 (authenticated, each gates itself), R10-R12 and the category writer (service_role only), the exact-match supplier resolver, and an
--                 internal price-jump helper with no grant at all. R1 read_operations with a v_full split (a cleaner gets id, name, location, maps_url, active only).
--                 R7 read_operations. Catalogue: location + supplier {id,name,location} for every role; lastPrice and priceUp inside the finance-gated sub-select.
--   5. Redefined  get_inventory_catalogue_v1, inventory_item_update_v1 (+ location), inventory_undo_v1 (+ supplier_id = null on the reopened shopping row),
--                 get_shopping_list_v1 (a non-finance session also loses the new supplier_id key, as it already loses supplier; the s82 pgTAP asserts no supplier key),
--                 record_inventory_receipt_v1 (9 args), apply_inventory_purchase (7 args). The 6- and 8-argument signatures are dropped first (no PGRST203).
--   6. Storage    per override O1 only the bucket limits (1 MB, jpeg/webp); the anon policies are already gone and the bucket is already private. Skipped
--                 where the storage schema does not exist (rehearsal). Realtime: inventory_purchases leaves supabase_realtime (conditional).
--   7. View       price_history_by_item: anon loses everything, authenticated keeps SELECT only.
-- SINGLE SHOT. Apply AFTER s84_inventory_20261017, s85_cleaner_count_20261018 and s85_pay_details_20261019 (inventory_undo_v1 is guarded on the s85 body).
-- Guard (55000, nothing changed): md5(replace(prosrc, chr(13), '')) of the five bodies cut from. catalogue 5a2625ae6aab612a0f9c054df904e9b7, receipt(8) 8e024f7f97169ed122175a2095cb1822,
-- apply(6) d94fceb8b7d074b16fca508f81b81156, shopping list cb564fcd1f2c6bff367018691c5e644d, item_update d359c1e34bccebcb1300f3a4bd5fb865, undo (the s85 body) 06ba21967be72a96d9eb7d4ceb94976f; no OCR purchase with units_per_purchase <> 1; exactly one 'test' purchase.
-- Rollback: supabase/rollbacks/20261020_s86_inventory_db.sql

begin;

-- 0. guard ---------------------------------------------------------------------------------------------------------------------------------
do $$
declare v_got text; v_n integer;
begin
  if to_regclass('public.inventory_item_codes') is null or to_regprocedure('public.inventory_undo_v1(uuid,uuid)') is null then
    raise exception 's86 inventory db: s84_inventory_20261017 is not applied (inventory_item_codes or inventory_undo_v1 is missing)' using errcode = '55000';
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.get_inventory_catalogue_v1(uuid)');
  if v_got is distinct from '5a2625ae6aab612a0f9c054df904e9b7' then
    raise exception 's86 inventory db: get_inventory_catalogue_v1 is not the body this release was cut from (md5 %): re-cut it', v_got using errcode = '55000';
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text)');
  if v_got is distinct from '8e024f7f97169ed122175a2095cb1822' then
    raise exception 's86 inventory db: record_inventory_receipt_v1 (8 args) is not the body this release was cut from (md5 %): re-cut it', v_got using errcode = '55000';
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.apply_inventory_purchase(uuid,numeric,numeric,text,date,uuid)');
  if v_got is distinct from 'd94fceb8b7d074b16fca508f81b81156' then
    raise exception 's86 inventory db: apply_inventory_purchase (6 args) is not the body this release was cut from (md5 %): re-cut it', v_got using errcode = '55000';
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.inventory_item_update_v1(uuid,jsonb)');
  if v_got is distinct from 'd359c1e34bccebcb1300f3a4bd5fb865' then
    raise exception 's86 inventory db: inventory_item_update_v1 is not the body this release was cut from (md5 %): re-cut it', v_got using errcode = '55000';
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.inventory_undo_v1(uuid,uuid)');
  if v_got is distinct from '06ba21967be72a96d9eb7d4ceb94976f' then
    raise exception 's86 inventory db: inventory_undo_v1 is not the s85 body this release was cut from (md5 %): apply s85_cleaner_count first, or re-cut it', v_got using errcode = '55000';
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.get_shopping_list_v1(uuid)');
  if v_got is distinct from 'cb564fcd1f2c6bff367018691c5e644d' then
    raise exception 's86 inventory db: get_shopping_list_v1 is not the body this release was cut from (md5 %): re-cut it', v_got using errcode = '55000';
  end if;
  select count(*) into v_n from public.inventory_purchases where notes like 'Auto-restock from receipt OCR%' and units_per_purchase <> 1;
  if v_n <> 0 then
    raise exception 's86 inventory db: % OCR purchase row(s) with units_per_purchase <> 1 hold a per-pack price: rewrite them first, do not guess', v_n using errcode = '55000';
  end if;
  select count(*) into v_n from public.inventory_purchases where lower(btrim(supplier)) = 'test';
  if v_n <> 1 then
    raise exception 's86 inventory db: expected exactly 1 purchase with supplier test, found %', v_n using errcode = '55000';
  end if;
  select count(*) into v_n from public.inventory_shopping_list s join public.inventory_purchases p on p.id = s.purchase_id where lower(btrim(p.supplier)) = 'test';
  if v_n <> 0 then
    raise exception 's86 inventory db: a shopping row points at the test purchase; resolve it first' using errcode = '55000';
  end if;
end $$;

-- 1. tables --------------------------------------------------------------------------------------------------------------------------------
create table public.inventory_suppliers (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete restrict,
  name text not null check (char_length(btrim(name)) between 2 and 80),
  aliases text[] not null default '{}',
  phone text check (phone is null or phone ~ '^[0-9+() -]{7,20}$'),
  location text check (location is null or char_length(location) <= 120),
  maps_url text check (maps_url is null or (maps_url like 'https://%' and char_length(maps_url) <= 300)),
  payment_method text check (payment_method is null or payment_method in ('cash','gcash','maya','card','bank_transfer','cod','online')),
  notes text check (notes is null or char_length(notes) <= 500),
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index inventory_suppliers_name_uq on public.inventory_suppliers (property_id, lower(btrim(name)));
alter table public.inventory_suppliers enable row level security;
revoke all on table public.inventory_suppliers from public, anon, authenticated, service_role;
grant select on table public.inventory_suppliers to service_role;
create trigger inventory_suppliers_updated_at before update on public.inventory_suppliers for each row execute function public.set_updated_at();
comment on table public.inventory_suppliers is 'S86: shops and suppliers. No client access: read and written through the inventory_supplier_* definer RPCs (aliases are lower-case receipt spellings).';

create table public.inventory_item_suppliers (
  item_id uuid not null references public.inventory_items(id) on delete cascade,
  supplier_id uuid not null references public.inventory_suppliers(id) on delete restrict,
  pack_label text check (pack_label is null or char_length(pack_label) <= 40),
  pack_size numeric(10,2) check (pack_size is null or (pack_size > 0 and pack_size < 100000)),
  quoted_pack_price numeric(12,2) check (quoted_pack_price is null or (quoted_pack_price > 0 and quoted_pack_price < 1000000)),
  is_preferred boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (item_id, supplier_id)
);
create unique index inventory_item_suppliers_one_preferred on public.inventory_item_suppliers (item_id) where is_preferred;
alter table public.inventory_item_suppliers enable row level security;
revoke all on table public.inventory_item_suppliers from public, anon, authenticated, service_role;
grant select on table public.inventory_item_suppliers to service_role;
comment on table public.inventory_item_suppliers is 'S86: which shop sells which item, with an optional pack size and a quoted price. The usual price is derived from inventory_purchases, never stored here.';

-- 2. columns -------------------------------------------------------------------------------------------------------------------------------
alter table public.inventory_purchases     add column if not exists supplier_id uuid references public.inventory_suppliers(id) on delete set null;
alter table public.inventory_shopping_list add column if not exists supplier_id uuid references public.inventory_suppliers(id) on delete set null;
create index inventory_purchases_item_date_idx on public.inventory_purchases (item_id, purchased_at desc);
alter table public.inventory_items add column if not exists location text check (location is null or char_length(btrim(location)) between 1 and 60);
grant select (location) on table public.inventory_items to authenticated;
comment on column public.inventory_purchases.unit_cost is 'S86: PHP per base unit (inventory_items.unit) on every write path; the pack price is unit_cost * units_per_purchase of the row. qty is in base units.';

-- 3. backfill suppliers from purchases, link them, delete the test purchase -----------------------------------------------------------------
insert into public.inventory_suppliers(property_id, name, aliases)
select d.property_id, d.name, array[lower(d.name)]
from (
  select distinct on (i.property_id, lower(btrim(p.supplier))) i.property_id, btrim(p.supplier) as name
  from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
  where p.supplier is not null and btrim(p.supplier) <> '' and lower(btrim(p.supplier)) <> 'test'
  order by i.property_id, lower(btrim(p.supplier)), p.purchased_at, p.created_at
) d;

update public.inventory_purchases p set supplier_id = s.id
from public.inventory_items i, public.inventory_suppliers s
where i.id = p.item_id and s.property_id = i.property_id and lower(btrim(s.name)) = lower(btrim(p.supplier)) and p.supplier_id is null;

-- Lloyd D-330 answer 4: the 'test' purchase goes (guarded above: exactly one, nothing points at it). Its full values are in the rollback.
delete from public.inventory_purchases where lower(btrim(supplier)) = 'test';

-- 4. category tidy (Lloyd D-330 answer 5): one audit row per moved item, reversed by item id from those rows ------------------------------------
with t(from_c, to_c) as (values ('Cleaning', 'Cleaning Supplies'), ('Utility / Cleaning / Bathroom', 'Bathroom & Utility'), ('Guest Supplies', 'Toiletries')),
log as (
  insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor)
  select 'inventory_items', i.id, 'category_tidy_s86', jsonb_build_object('category', i.category), jsonb_build_object('category', t.to_c), 'migration'
  from public.inventory_items i join t on i.category = t.from_c
  returning 1
)
update public.inventory_items i set category = t.to_c from t where i.category = t.from_c;

-- 5. photos bucket (override O1: limits only; the policies are gone and the bucket is private) and realtime ---------------------------------------
do $$
begin
  if to_regclass('storage.buckets') is not null then
    update storage.buckets set file_size_limit = 1048576, allowed_mime_types = array['image/jpeg', 'image/webp'] where id = 'inventory-photos';
  end if;
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'inventory_purchases') then
    alter publication supabase_realtime drop table public.inventory_purchases;
  end if;
end $$;

-- 6. the price history view is a read view ---------------------------------------------------------------------------------------------------
revoke all on public.price_history_by_item from anon;
revoke all on public.price_history_by_item from authenticated;
grant select on public.price_history_by_item to authenticated;

-- 7. drop the old signatures first (a defaulted new argument next to the old overload would be PGRST203) -----------------------------------------
drop function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid);
drop function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text);

-- 8. internal helpers ---------------------------------------------------------------------------------------------------------------------------

-- Exact match only: the lower-cased trimmed name equals a supplier name or one of its aliases. Active suppliers only. No fuzzy guessing of who was paid.
create or replace function public.s_inventory_supplier_resolve_v1(p_property_id uuid, p_name text)
returns uuid language sql stable security definer set search_path = '' as $$
  select s.id from public.inventory_suppliers s
  where s.property_id = p_property_id and s.is_active and nullif(btrim(coalesce(p_name, '')), '') is not null
    and (lower(btrim(s.name)) = lower(btrim(p_name)) or lower(btrim(p_name)) = any (s.aliases))
  order by (lower(btrim(s.name)) = lower(btrim(p_name))) desc, s.created_at
  limit 1
$$;

-- The price-jump rule (spec 2.8), shared by R6 and the catalogue: base = median of the up-to-5 purchases before the newest within 365 days (numeric, no float).
create or replace function public.s_inventory_price_jump_v1(p_item_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  with r as (
    select p.unit_cost, p.purchased_at, row_number() over (order by p.purchased_at desc, p.created_at desc, p.id desc) as rn
    from public.inventory_purchases p where p.item_id = p_item_id and p.unit_cost is not null
  ), prev as (
    select r.unit_cost from r where r.rn between 2 and 6 and r.purchased_at >= public.manila_today() - 365
  ), ranked as (
    select q.unit_cost, row_number() over (order by q.unit_cost) as a, count(*) over () as c from prev q
  ), base as (
    select avg(ranked.unit_cost) as b, max(ranked.c) as n from ranked where ranked.a in ((ranked.c + 1) / 2, (ranked.c + 2) / 2)
  )
  select case when base.n >= 2 and base.b > 0 and newest.unit_cost * 100 >= base.b * 120
              then jsonb_build_object('pct', round((newest.unit_cost / base.b - 1) * 100), 'base', round(base.b, 4)) end
  from base, (select r.unit_cost from r where r.rn = 1) newest
$$;
revoke all on function public.s_inventory_price_jump_v1(uuid) from public, anon, authenticated, service_role;

-- 9. redefined functions (bodies cut from the s84 / s85 migrations, md5 guarded above) ------------------------------------------------------------
create or replace function public.get_inventory_catalogue_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_items jsonb; v_asof timestamptz; v_fin boolean; v_turnover_rate numeric;
begin
  perform public.admin_require('read_operations', p_property_id);
  v_fin := public.finance_human_authorized(p_property_id);
  select max(updated_at) into v_asof from public.inventory_items where property_id = p_property_id;
  select coalesce(count(*)::numeric / 60, 0) into v_turnover_rate
  from public.cleaning_sessions
  where property_id = p_property_id and cleaning_type in ('turnover', 'deep_clean') and cleaned_at >= now() - interval '60 days';
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', i.id, 'name', i.name, 'category', i.category, 'unit', i.unit, 'qty', i.qty_on_hand, 'reorderBelow', i.reorder_below, 'consumable', i.is_consumable, 'active', i.is_active,
    'status', i.status, 'unitCost', case when v_fin then i.unit_cost end, 'purchaseUnit', i.purchase_unit, 'unitsPerPurchase', i.units_per_purchase, 'photo', i.photo_path,
    'movementControlled', i.movement_controlled_at is not null, 'baselineNote', i.baseline_note,
    'usage30d', u.used, 'usageDays', u.days, 'avgDaily', case when u.days >= 14 and u.used > 0 then round(u.used / 30.0, 3) end,
    'coverageDays', case when u.days >= 14 and u.used > 0 then round(i.qty_on_hand / (u.used / 30.0), 1) end,
    'estDailyUsage', case when i.consumption_per_booking is not null and v_turnover_rate > 0 then round(i.consumption_per_booking * v_turnover_rate, 4) end,
    'estCoverageDays', case when i.consumption_per_booking is not null and i.consumption_per_booking * v_turnover_rate > 0 then round(i.qty_on_hand / (i.consumption_per_booking * v_turnover_rate), 1) end,
    'attention', (i.reorder_below is not null and i.qty_on_hand <= i.reorder_below) or lower(coalesce(i.status, 'good')) not in ('good','ok') or not i.is_active,
    'par', i.par_qty, 'location', i.location,
    'codes', coalesce((select jsonb_agg(c.code order by c.created_at, c.code) from public.inventory_item_codes c where c.item_id = i.id), '[]'::jsonb),
    'countedAt', (select max(t.at) from (
        select max(m.created_at) as at from public.inventory_stock_movements m where m.item_id = i.id and m.kind = 'reconcile'
        union all
        select max(a.created_at) from public.inventory_audit_log a where a.entity_type = 'inventory_items' and a.entity_id = i.id and a.action = 'telegram_count') t)
  )
    -- S86: the shop to buy at (name and place) is for every role that reads operations; never a phone, a note or a price
    || coalesce((select jsonb_build_object('supplier', jsonb_build_object('id', s.id, 'name', s.name, 'location', s.location))
                 from public.inventory_suppliers s
                 where s.is_active and s.id = coalesce(
                   (select l.supplier_id from public.inventory_item_suppliers l join public.inventory_suppliers ls on ls.id = l.supplier_id and ls.is_active where l.item_id = i.id and l.is_preferred),
                   (select p.supplier_id from public.inventory_purchases p join public.inventory_suppliers ps on ps.id = p.supplier_id and ps.is_active where p.item_id = i.id and p.supplier_id is not null order by p.purchased_at desc, p.created_at desc limit 1))),
                '{}'::jsonb)
    -- S86: money (lastPrice, priceUp) sits in a sub-select whose WHERE carries the finance gate, and the keys are absent (not null) for everyone else
    || coalesce((select jsonb_build_object('lastPrice', (select p.unit_cost from public.inventory_purchases p where p.item_id = i.id and p.unit_cost is not null order by p.purchased_at desc, p.created_at desc, p.id desc limit 1))
                        || coalesce((select jsonb_build_object('priceUp', (j.v->>'pct')::numeric) from (select public.s_inventory_price_jump_v1(i.id) as v) j where j.v is not null), '{}'::jsonb)
                 where v_fin), '{}'::jsonb)
  order by i.sort_order, i.name), '[]'::jsonb) into v_items
  from public.inventory_items i
  left join lateral (
    select coalesce(sum(used_qty), 0) used, count(distinct session_date) days from public.inventory_usage x where x.item_id = i.id and x.session_date >= public.manila_today() - 30
  ) u on true
  where i.property_id = p_property_id;
  return jsonb_build_object(
    'items', v_items, 'sourceAsOf', v_asof, 'turnoverRatePerDay', round(v_turnover_rate, 4),
    'forecastNote', 'Advisory reorder estimates use the last 30 days of recorded usage and require at least 14 usage days. When that history is not yet available, an estimate is shown instead, based on each item''s catalogued per-turnover consumption times the recent turnover rate. Forecasting never places orders.'
  );
end;
$$;
create or replace function public.inventory_item_update_v1(p_item_id uuid, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  i public.inventory_items%rowtype; v_k text; v_n numeric; v_t text; v_dupe uuid;
begin
  select * into i from public.inventory_items where id = p_item_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('manage_inventory', i.property_id);
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then raise exception using errcode = '22023', message = 'nothing to change'; end if;
  for v_k in select jsonb_object_keys(p_patch) loop
    if v_k <> all (array['name', 'category', 'unit', 'consumable', 'reorder_below', 'par_qty', 'purchase_unit', 'units_per_purchase', 'active', 'location']) then
      raise exception using errcode = '22023', message = 'field not allowed: ' || v_k;
    end if;
  end loop;
  if p_patch ? 'name' then
    v_t := btrim(coalesce(p_patch->>'name', ''));
    if char_length(v_t) not between 2 and 80 then raise exception using errcode = '22023', message = 'name must be 2 to 80 characters'; end if;
    select x.id into v_dupe from public.inventory_items x
    where x.property_id = i.property_id and x.is_active and x.id <> i.id and lower(btrim(x.name)) = lower(v_t) limit 1;
    if v_dupe is not null then return jsonb_build_object('ok', false, 'reason', 'name_exists', 'item_id', v_dupe); end if;
    i.name := v_t;
  end if;
  if p_patch ? 'category' then
    v_t := btrim(coalesce(p_patch->>'category', ''));
    if char_length(v_t) not between 1 and 60 then raise exception using errcode = '22023', message = 'category must be 1 to 60 characters'; end if;
    i.category := v_t;
  end if;
  if p_patch ? 'unit' then
    v_t := btrim(coalesce(p_patch->>'unit', ''));
    if char_length(v_t) not between 1 and 20 then raise exception using errcode = '22023', message = 'unit must be 1 to 20 characters'; end if;
    i.unit := v_t;
  end if;
  if p_patch ? 'consumable' then
    if p_patch->'consumable' = 'null'::jsonb then raise exception using errcode = '22023', message = 'consumable must be true or false'; end if;
    i.is_consumable := (p_patch->>'consumable')::boolean;
  end if;
  if p_patch ? 'active' then
    if p_patch->'active' = 'null'::jsonb then raise exception using errcode = '22023', message = 'active must be true or false'; end if;
    i.is_active := (p_patch->>'active')::boolean;
  end if;
  if p_patch ? 'reorder_below' then
    v_n := (p_patch->>'reorder_below')::numeric;
    if v_n is not null and (v_n < 0 or v_n >= 100000000 or v_n <> round(v_n, 2)) then raise exception using errcode = '22023', message = 'reorder level must be 0 or more, with at most 2 decimals'; end if;
    i.reorder_below := v_n;
  end if;
  if p_patch ? 'par_qty' then
    v_n := (p_patch->>'par_qty')::numeric;
    if v_n is not null and (v_n < 0 or v_n >= 100000000 or v_n <> round(v_n, 2)) then raise exception using errcode = '22023', message = 'buy-up-to level must be 0 or more, with at most 2 decimals'; end if;
    i.par_qty := v_n;
  end if;
  if p_patch ? 'purchase_unit' then
    v_t := nullif(btrim(coalesce(p_patch->>'purchase_unit', '')), '');
    if v_t is not null and char_length(v_t) > 30 then raise exception using errcode = '22023', message = 'pack name is too long'; end if;
    i.purchase_unit := v_t;
  end if;
  if p_patch ? 'units_per_purchase' then
    v_n := (p_patch->>'units_per_purchase')::numeric;
    if v_n is null or v_n <= 0 or v_n >= 1000000 or v_n <> round(v_n, 4) then raise exception using errcode = '22023', message = 'units per pack must be more than 0'; end if;
    i.units_per_purchase := v_n;
  end if;
  if p_patch ? 'location' then
    v_t := nullif(btrim(coalesce(p_patch->>'location', '')), '');
    if v_t is not null and char_length(v_t) > 60 then raise exception using errcode = '22023', message = 'location must be 1 to 60 characters'; end if;
    i.location := v_t;
  end if;
  update public.inventory_items set
    name = i.name, category = i.category, unit = i.unit, is_consumable = i.is_consumable, is_active = i.is_active,
    reorder_below = i.reorder_below, par_qty = i.par_qty, purchase_unit = i.purchase_unit, units_per_purchase = i.units_per_purchase, location = i.location
  where id = i.id;
  return jsonb_build_object('ok', true, 'item_id', i.id);
end;
$$;
create or replace function public.inventory_undo_v1(p_movement_id uuid default null, p_purchase_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  m public.inventory_stock_movements%rowtype; m2 public.inventory_stock_movements%rowtype;
  pu public.inventory_purchases%rowtype; i public.inventory_items%rowtype;
  v_item uuid; v_key text; v_ekey text; v_have_m boolean := false; v_have_p boolean := false;
  v_sh_found boolean; v_sh_by uuid; v_after numeric;
begin
  if p_movement_id is null and p_purchase_id is null then raise exception using errcode = '22023', message = 'nothing to undo'; end if;
  if p_movement_id is not null then
    select * into m from public.inventory_stock_movements where id = p_movement_id;
    if not found then raise exception using errcode = 'P0002', message = 'movement not found'; end if;
    v_have_m := true; v_item := m.item_id;
  end if;
  if p_purchase_id is not null then
    select * into pu from public.inventory_purchases where id = p_purchase_id;
    v_have_p := found;
    if v_have_p then
      if v_have_m and pu.item_id is distinct from v_item then raise exception using errcode = '22023', message = 'movement and purchase are for different items'; end if;
      v_item := pu.item_id;
    end if;
  end if;
  if v_item is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  select * into i from public.inventory_items where id = v_item for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  -- s85: a cleaner may undo THEIR OWN count (movement path only; the own-actor check below stays); a purchase undo needs manage_inventory
  if not public.current_staff_authorized('manage_inventory', i.property_id) then
    perform public.admin_require('submit_cleaning', i.property_id);
    if p_purchase_id is not null then return jsonb_build_object('ok', false, 'reason', 'not_yours'); end if;
  end if;

  -- a repeat of an undo that already happened is answered, not applied twice
  if v_have_m then
    v_key := 'stk-undo-' || replace(m.id::text, '-', '');
    if exists (select 1 from public.inventory_stock_movements x where x.item_id = m.item_id and x.idempotency_key = v_key) then
      return jsonb_build_object('ok', true, 'replayed', true, 'item_id', i.id, 'qty', i.qty_on_hand);
    end if;
  end if;
  if p_purchase_id is not null and not v_have_p then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  if v_have_p then
    if pu.notes is null or pu.notes not like 'Admin receipt [key:%' then return jsonb_build_object('ok', false, 'reason', 'not_undoable'); end if;
    if pu.created_at <= now() - interval '15 minutes' then return jsonb_build_object('ok', false, 'reason', 'too_late'); end if;
    select s.received_by into v_sh_by from public.inventory_shopping_list s where s.purchase_id = pu.id limit 1;
    v_sh_found := found;
    if v_sh_found and v_sh_by is distinct from auth.uid() then return jsonb_build_object('ok', false, 'reason', 'not_yours'); end if;
    -- the receipt movement of a controlled item is found by the key inventory_apply_event_v1 gave it
    v_ekey := left('evt-' || encode(extensions.digest('inventory_purchases|' || pu.id::text || '|' || pu.item_id::text || '|receipt', 'sha256'), 'hex'), 80);
    select * into m2 from public.inventory_stock_movements x where x.item_id = pu.item_id and x.idempotency_key = v_ekey;
    if found then
      if v_have_m and m.id <> m2.id then raise exception using errcode = '22023', message = 'movement does not belong to this purchase'; end if;
      m := m2; v_have_m := true; v_key := 'stk-undo-' || replace(m.id::text, '-', '');
    elsif v_have_m then
      raise exception using errcode = '22023', message = 'movement does not belong to this purchase';
    elsif i.movement_controlled_at is not null then
      return jsonb_build_object('ok', false, 'reason', 'not_undoable');
    end if;
  end if;

  if v_have_m then
    if m.kind not in ('reconcile', 'receipt', 'usage') then return jsonb_build_object('ok', false, 'reason', 'not_undoable'); end if;  -- s85 r2: a usage movement (record_inventory_usage, controlled items) is undoable by its own author
    if m.actor_user_id is distinct from auth.uid() then return jsonb_build_object('ok', false, 'reason', 'not_yours'); end if;
    if m.created_at <= now() - interval '15 minutes' then return jsonb_build_object('ok', false, 'reason', 'too_late'); end if;
    if i.qty_on_hand is distinct from m.quantity_after
       or exists (select 1 from public.inventory_stock_movements x where x.item_id = m.item_id and x.sequence_no > m.sequence_no) then
      return jsonb_build_object('ok', false, 'reason', 'stock_moved');
    end if;
    if public.inventory_human_authorized(i.property_id) then
      perform public.record_inventory_movement(i.id, 'adjustment', m.quantity_before - m.quantity_after,
        'Undo in the staff app of ' || m.kind || ' ' || m.sequence_no::text, v_key);
    else
      perform public.s_inventory_staff_movement_v1(i.id, 'adjustment', m.quantity_before - m.quantity_after,
        'Undo in the staff app of ' || m.kind || ' ' || m.sequence_no::text, v_key);
    end if;
  else
    -- an app receipt on an item that is not movement-controlled changed qty_on_hand directly
    if i.updated_at > pu.created_at + interval '5 seconds' or i.qty_on_hand < pu.qty then
      return jsonb_build_object('ok', false, 'reason', 'stock_moved');
    end if;
    update public.inventory_items set qty_on_hand = qty_on_hand - pu.qty where id = i.id;
  end if;

  if v_have_p then
    update public.inventory_shopping_list set status = 'approved', received_by = null, received_at = null, received_quantity = null,
      unit_cost = null, supplier = null, supplier_id = null, movement_id = null, purchase_id = null, version = version + 1, updated_at = now()
    where purchase_id = pu.id;
    delete from public.inventory_purchases where id = pu.id;
  end if;
  select it.qty_on_hand into v_after from public.inventory_items it where it.id = i.id;
  return jsonb_build_object('ok', true, 'item_id', i.id, 'qty', v_after);
end;
$$;
create or replace function public.get_shopping_list_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_fin boolean; v_rows jsonb;
begin
  perform public.admin_require('read_operations', p_property_id);
  v_fin := public.finance_human_authorized(p_property_id);
  select coalesce(jsonb_agg(case when v_fin then to_jsonb(l) else to_jsonb(l) - 'estimated_cost' - 'unit_cost' - 'supplier' - 'supplier_id' end order by l.proposed_at desc), '[]'::jsonb)
    into v_rows
    from (select * from public.inventory_shopping_list where property_id = p_property_id order by proposed_at desc limit 200) l;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;
create or replace function public.record_inventory_receipt_v1(p_item_id uuid, p_packs numeric, p_unit_cost numeric, p_supplier text, p_purchased_at date, p_receipt_path text, p_shopping_list_id uuid, p_idempotency_key text, p_supplier_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i public.inventory_items%rowtype; v_units numeric; v_pid uuid; v_mid uuid; v_existing public.inventory_purchases%rowtype; v_sh_status text; v_sid uuid; v_sname text;
begin
  select * into i from public.inventory_items where id = p_item_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('manage_inventory', i.property_id);
  if p_packs is null or p_packs <= 0 then raise exception using errcode = '22023', message = 'packs must be positive'; end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key required'; end if;
  select * into v_existing from public.inventory_purchases p where p.notes like '%[key:' || p_idempotency_key || ']%' limit 1;
  if found then return jsonb_build_object('ok', true, 'replayed', true, 'purchaseId', v_existing.id); end if;
  -- S84: a shopping row that is no longer approved (already received, cancelled, ...) adds no stock; checked after the replay above and before anything is written
  if p_shopping_list_id is not null then
    select s.status into v_sh_status from public.inventory_shopping_list s where s.id = p_shopping_list_id and s.property_id = i.property_id for update;
    if not found or v_sh_status <> 'approved' then
      return jsonb_build_object('ok', false, 'reason', case v_sh_status when 'received' then 'already_received' else 'not_open' end);
    end if;
  end if;
  -- S86: the supplier is the picked id (same property), else an exact name or alias match of the printed name; the text column keeps the name
  if p_supplier_id is not null then
    select s.id, s.name into v_sid, v_sname from public.inventory_suppliers s where s.id = p_supplier_id and s.property_id = i.property_id;
  end if;
  if v_sid is null then
    v_sid := public.s_inventory_supplier_resolve_v1(i.property_id, p_supplier);
    if v_sid is not null then select s.name into v_sname from public.inventory_suppliers s where s.id = v_sid; end if;
  end if;
  -- Purchase packs convert to base units once, here (INV06).
  v_units := round(p_packs * coalesce(i.units_per_purchase, 1), 2);
  insert into public.inventory_purchases(item_id, purchased_at, qty, unit_cost, supplier, supplier_id, notes, receipt_path, purchase_unit, units_per_purchase)
  values (p_item_id, coalesce(p_purchased_at, current_date), v_units, case when p_unit_cost is not null then round(p_unit_cost / coalesce(nullif(i.units_per_purchase, 0), 1), 4) end, coalesce(v_sname, p_supplier), v_sid, 'Admin receipt [key:' || p_idempotency_key || ']', p_receipt_path, i.purchase_unit, coalesce(i.units_per_purchase, 1)::integer)
  returning id into v_pid;
  if i.movement_controlled_at is not null then
    v_mid := public.inventory_apply_event_v1(p_item_id, 'receipt', v_units, 'Receipt of ' || p_packs::text || ' ' || coalesce(i.purchase_unit, 'pack') || coalesce(' from ' || coalesce(v_sname, p_supplier), ''), 'inventory_purchases', v_pid::text);
  else
    update public.inventory_items set qty_on_hand = coalesce(qty_on_hand, 0) + v_units, unit_cost = coalesce(case when p_unit_cost is not null then round(p_unit_cost / coalesce(nullif(units_per_purchase, 0), 1), 2) end, unit_cost) where id = p_item_id;
  end if;
  if p_shopping_list_id is not null then
    update public.inventory_shopping_list set status = 'received', received_by = auth.uid(), received_at = now(), received_quantity = v_units, unit_cost = p_unit_cost, supplier = coalesce(v_sname, p_supplier), supplier_id = v_sid, movement_id = v_mid, purchase_id = v_pid, version = version + 1, updated_at = now()
    where id = p_shopping_list_id and property_id = i.property_id and status = 'approved';
  end if;
  return jsonb_build_object('ok', true, 'purchaseId', v_pid, 'movementId', v_mid, 'unitsAdded', v_units, 'controlled', i.movement_controlled_at is not null);
end;
$$;
create or replace function public.apply_inventory_purchase(p_item_id uuid, p_qty numeric, p_unit_cost numeric, p_supplier text, p_purchased_at date, p_txn_id uuid, p_supplier_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
-- S86: the Telegram OCR restock. Was invoker rights with search_path public; now definer, empty search_path, service_role only (the bot).
-- p_qty is packs and p_unit_cost is the receipt line price per pack: the row stores base units (qty = p_qty * units_per_purchase) and PHP per base unit
-- (unit_cost = p_unit_cost / units_per_purchase), the same basis as record_inventory_receipt_v1.
declare
  v_upp numeric; v_before numeric; v_after numeric; v_pid uuid; v_name text; v_controlled boolean; v_mv jsonb; v_prop uuid; v_sid uuid; v_sname text;
begin
  select coalesce(units_per_purchase, 1), qty_on_hand, name, movement_controlled_at is not null, property_id
    into v_upp, v_before, v_name, v_controlled, v_prop
  from public.inventory_items where id = p_item_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'item_not_found');
  end if;

  -- S82: a movement-controlled item with this receipt transaction already restocked is answered, not added twice
  if v_controlled and p_txn_id is not null then
    select id into v_pid from public.inventory_purchases where item_id = p_item_id and notes like '%(txn ' || p_txn_id::text || ')%' limit 1;
    if found then
      return jsonb_build_object('ok', true, 'replayed', true, 'name', v_name, 'purchase_id', v_pid, 'qty_before', v_before, 'qty_after', v_before, 'added', 0);
    end if;
  end if;

  -- S86: the supplier is the picked id (same property), else an exact name or alias match of the printed name; the text column keeps the name
  if p_supplier_id is not null then
    select s.id, s.name into v_sid, v_sname from public.inventory_suppliers s where s.id = p_supplier_id and s.property_id = v_prop;
  end if;
  if v_sid is null then
    v_sid := public.s_inventory_supplier_resolve_v1(v_prop, p_supplier);
    if v_sid is not null then select s.name into v_sname from public.inventory_suppliers s where s.id = v_sid; end if;
  end if;

  insert into public.inventory_purchases(item_id, qty, unit_cost, supplier, supplier_id, purchased_at, units_per_purchase, notes)
  values (p_item_id, p_qty * v_upp, round(p_unit_cost / nullif(v_upp, 0), 4), coalesce(v_sname, p_supplier), v_sid, coalesce(p_purchased_at, current_date), v_upp,
          'Auto-restock from receipt OCR' || case when p_txn_id is not null then ' (txn ' || p_txn_id::text || ')' else '' end)
  returning id into v_pid;

  if v_controlled then
    v_mv := public.s_inventory_purchase_movement_v1(p_item_id, p_qty * v_upp,
              'Auto-restock from receipt OCR' || case when p_txn_id is not null then ' (txn ' || p_txn_id::text || ')' else '' end, v_pid::text);
    v_before := (v_mv ->> 'before')::numeric;
    v_after := (v_mv ->> 'after')::numeric;
  else
    v_after := coalesce(v_before, 0) + (p_qty * v_upp);
    update public.inventory_items set qty_on_hand = v_after where id = p_item_id;
  end if;

  insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor)
  values ('inventory_items', p_item_id, 'ocr_restock',
          jsonb_build_object('qty_on_hand', v_before),
          jsonb_build_object('qty_on_hand', v_after, 'purchase_id', v_pid, 'qty_added', p_qty * v_upp),
          'telegram-ocr');

  return jsonb_build_object('ok', true, 'name', v_name, 'purchase_id', v_pid,
                            'qty_before', v_before, 'qty_after', v_after, 'added', p_qty * v_upp);
end;
$$;

-- 10. R1-R9 (signed-in users; every one gates itself) -----------------------------------------------------------------------------------------------

-- R1: every role that can read operations may list the shops (where to buy). Only the full-detail roles (manage_inventory or finance) get contact and money-adjacent keys.
create or replace function public.inventory_supplier_list_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_full boolean; v_list jsonb;
begin
  perform public.admin_require('read_operations', p_property_id);
  v_full := public.current_staff_authorized('manage_inventory', p_property_id) or public.finance_human_authorized(p_property_id);
  select coalesce(jsonb_agg(
    jsonb_build_object('id', s.id, 'name', s.name, 'location', s.location, 'maps_url', s.maps_url, 'active', s.is_active)
    || coalesce((
      select jsonb_build_object('phone', s.phone, 'payment', s.payment_method, 'notes', s.notes,
        'items', (select count(distinct t.item_id) from (
                    select l.item_id from public.inventory_item_suppliers l where l.supplier_id = s.id
                    union select p.item_id from public.inventory_purchases p where p.supplier_id = s.id and p.item_id is not null) t),
        'last_bought_at', (select max(p.purchased_at) from public.inventory_purchases p where p.supplier_id = s.id))
      where v_full), '{}'::jsonb)
    order by s.is_active desc, lower(s.name)), '[]'::jsonb) into v_list
  from public.inventory_suppliers s where s.property_id = p_property_id;
  return jsonb_build_object('ok', true, 'suppliers', v_list);
end;
$$;

-- R2: create (no id) or patch (id). Finance may add and edit suppliers; the cleaner may not.
create or replace function public.inventory_supplier_save_v1(p_property_id uuid, p_supplier jsonb, p_idempotency_key text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_k text; v_id uuid; s public.inventory_suppliers%rowtype; v_before jsonb := '{}'::jsonb; v_t text; v_dupe public.inventory_suppliers%rowtype; v_new text[]; v_all text[];
begin
  if not (public.current_staff_authorized('manage_inventory', p_property_id) or public.finance_human_authorized(p_property_id)) then
    raise exception using errcode = '42501', message = 'supplier access denied';
  end if;
  if p_supplier is null or jsonb_typeof(p_supplier) <> 'object' then raise exception using errcode = '22023', message = 'supplier must be an object'; end if;
  if p_idempotency_key is not null and char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key must be 16 to 160 characters'; end if;
  for v_k in select jsonb_object_keys(p_supplier) loop
    if v_k <> all (array['id', 'name', 'phone', 'location', 'maps_url', 'payment', 'notes', 'active', 'aliases_add']) then
      raise exception using errcode = '22023', message = 'field not allowed: ' || v_k;
    end if;
  end loop;
  v_id := nullif(p_supplier->>'id', '')::uuid;
  if v_id is null then
    if not (p_supplier ? 'name') then raise exception using errcode = '22023', message = 'name is required'; end if;
    s.property_id := p_property_id; s.is_active := true; s.aliases := '{}';
  else
    select * into s from public.inventory_suppliers x where x.id = v_id and x.property_id = p_property_id for update;
    if not found then raise exception using errcode = 'P0002', message = 'supplier not found'; end if;
  end if;
  if p_supplier ? 'name' then
    v_t := btrim(coalesce(p_supplier->>'name', ''));
    if char_length(v_t) not between 2 and 80 then raise exception using errcode = '22023', message = 'name must be 2 to 80 characters'; end if;
    select * into v_dupe from public.inventory_suppliers x where x.property_id = p_property_id and lower(btrim(x.name)) = lower(v_t) and x.id is distinct from v_id limit 1;
    if found then return jsonb_build_object('ok', false, 'reason', 'name_exists', 'supplier_id', v_dupe.id, 'active', v_dupe.is_active); end if;
    v_before := v_before || jsonb_build_object('name', s.name);
    s.name := v_t;
  end if;
  if p_supplier ? 'phone' then
    v_t := nullif(btrim(coalesce(p_supplier->>'phone', '')), '');
    if v_t is not null and v_t !~ '^[0-9+() -]{7,20}$' then raise exception using errcode = '22023', message = 'phone must be 7 to 20 digits, spaces or + ( ) -'; end if;
    v_before := v_before || jsonb_build_object('phone', s.phone);
    s.phone := v_t;
  end if;
  if p_supplier ? 'location' then
    v_t := nullif(btrim(coalesce(p_supplier->>'location', '')), '');
    if v_t is not null and char_length(v_t) > 120 then raise exception using errcode = '22023', message = 'location is too long'; end if;
    v_before := v_before || jsonb_build_object('location', s.location);
    s.location := v_t;
  end if;
  if p_supplier ? 'maps_url' then
    v_t := nullif(btrim(coalesce(p_supplier->>'maps_url', '')), '');
    if v_t is not null and (v_t not like 'https://%' or char_length(v_t) > 300) then raise exception using errcode = '22023', message = 'map link must start with https:// and be at most 300 characters'; end if;
    v_before := v_before || jsonb_build_object('maps_url', s.maps_url);
    s.maps_url := v_t;
  end if;
  if p_supplier ? 'payment' then
    v_t := nullif(btrim(coalesce(p_supplier->>'payment', '')), '');
    if v_t is not null and v_t <> all (array['cash', 'gcash', 'maya', 'card', 'bank_transfer', 'cod', 'online']) then raise exception using errcode = '22023', message = 'payment method not allowed'; end if;
    v_before := v_before || jsonb_build_object('payment', s.payment_method);
    s.payment_method := v_t;
  end if;
  if p_supplier ? 'notes' then
    v_t := nullif(btrim(coalesce(p_supplier->>'notes', '')), '');
    if v_t is not null and char_length(v_t) > 500 then raise exception using errcode = '22023', message = 'notes are too long'; end if;
    v_before := v_before || jsonb_build_object('notes', s.notes);
    s.notes := v_t;
  end if;
  if p_supplier ? 'active' then
    if jsonb_typeof(p_supplier->'active') <> 'boolean' then raise exception using errcode = '22023', message = 'active must be true or false'; end if;
    v_before := v_before || jsonb_build_object('active', s.is_active);
    s.is_active := (p_supplier->>'active')::boolean;
  end if;
  if p_supplier ? 'aliases_add' then
    select coalesce(array_agg(distinct a order by a), '{}') into v_new from (
      select lower(btrim(x)) as a from jsonb_array_elements_text(case jsonb_typeof(p_supplier->'aliases_add') when 'array' then p_supplier->'aliases_add' else jsonb_build_array(p_supplier->>'aliases_add') end) x
    ) q where q.a <> '' and char_length(q.a) <= 80;
    select coalesce(array_agg(distinct u order by u), '{}') into v_all from unnest(s.aliases || v_new) u;
    if cardinality(v_all) > 30 then raise exception using errcode = '22023', message = 'too many aliases'; end if;
    s.aliases := v_all;
  end if;
  if v_id is null then
    begin
      insert into public.inventory_suppliers(property_id, name, aliases, phone, location, maps_url, payment_method, notes, is_active, created_by)
      values (p_property_id, s.name, s.aliases, s.phone, s.location, s.maps_url, s.payment_method, s.notes, s.is_active, auth.uid())
      returning id into v_id;
    exception when unique_violation then
      select * into v_dupe from public.inventory_suppliers x where x.property_id = p_property_id and lower(btrim(x.name)) = lower(s.name) limit 1;
      return jsonb_build_object('ok', false, 'reason', 'name_exists', 'supplier_id', v_dupe.id, 'active', v_dupe.is_active);
    end;
    return jsonb_build_object('ok', true, 'supplier_id', v_id, 'before', null);
  end if;
  if v_before = '{}'::jsonb and not (p_supplier ? 'aliases_add') then raise exception using errcode = '22023', message = 'nothing to change'; end if;
  update public.inventory_suppliers set name = s.name, aliases = s.aliases, phone = s.phone, location = s.location, maps_url = s.maps_url,
    payment_method = s.payment_method, notes = s.notes, is_active = s.is_active where id = v_id;
  return jsonb_build_object('ok', true, 'supplier_id', v_id, 'before', v_before);
end;
$$;

-- R3: one shop with the items bought there (manage or finance only; never a cleaner).
create or replace function public.inventory_supplier_detail_v1(p_supplier_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare s public.inventory_suppliers%rowtype; v_items jsonb;
begin
  select * into s from public.inventory_suppliers x where x.id = p_supplier_id;
  if not found then raise exception using errcode = 'P0002', message = 'supplier not found'; end if;
  if not (public.current_staff_authorized('manage_inventory', s.property_id) or public.finance_human_authorized(s.property_id)) then
    raise exception using errcode = '42501', message = 'supplier access denied';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'item_id', it.id, 'name', it.name, 'unit', it.unit, 'last_unit_price', lp.unit_cost, 'last_pack_price', lp.pack_price, 'last_at', lp.purchased_at,
      'times', coalesce(lp.times, 0), 'preferred', coalesce(l.is_preferred, false), 'pack_size', l.pack_size, 'pack_label', l.pack_label, 'quoted_pack_price', l.quoted_pack_price
    ) order by lower(it.name)), '[]'::jsonb) into v_items
  from (
    select k.item_id from public.inventory_item_suppliers k where k.supplier_id = s.id
    union select p.item_id from public.inventory_purchases p where p.supplier_id = s.id and p.item_id is not null
  ) ids
  join public.inventory_items it on it.id = ids.item_id
  left join public.inventory_item_suppliers l on l.item_id = it.id and l.supplier_id = s.id
  left join lateral (
    select p.unit_cost, round(p.unit_cost * p.units_per_purchase, 2) as pack_price, p.purchased_at,
           (select count(*) from public.inventory_purchases p2 where p2.item_id = it.id and p2.supplier_id = s.id and p2.unit_cost is not null) as times
    from public.inventory_purchases p where p.item_id = it.id and p.supplier_id = s.id and p.unit_cost is not null
    order by p.purchased_at desc, p.created_at desc, p.id desc limit 1
  ) lp on true;
  return jsonb_build_object('ok', true,
    'supplier', jsonb_build_object('id', s.id, 'name', s.name, 'phone', s.phone, 'location', s.location, 'maps_url', s.maps_url, 'payment', s.payment_method,
      'notes', s.notes, 'active', s.is_active, 'aliases', to_jsonb(s.aliases)),
    'items', v_items);
end;
$$;

-- R4: link an item to a shop (upsert). quoted_pack_price additionally needs finance (owner and admin have it).
create or replace function public.inventory_item_supplier_link_v1(p_item_id uuid, p_supplier_id uuid, p_link jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_prop uuid; v_k text; l public.inventory_item_suppliers%rowtype; v_had boolean; v_before jsonb; v_fin boolean; v_n numeric; v_t text;
begin
  select i.property_id into v_prop from public.inventory_items i where i.id = p_item_id;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('manage_inventory', v_prop);
  v_fin := public.finance_human_authorized(v_prop);
  if not exists (select 1 from public.inventory_suppliers s where s.id = p_supplier_id and s.property_id = v_prop) then
    raise exception using errcode = 'P0002', message = 'supplier not found';
  end if;
  if p_link is null or jsonb_typeof(p_link) <> 'object' or p_link = '{}'::jsonb then raise exception using errcode = '22023', message = 'nothing to change'; end if;
  for v_k in select jsonb_object_keys(p_link) loop
    if v_k <> all (array['pack_label', 'pack_size', 'quoted_pack_price', 'preferred']) then
      raise exception using errcode = '22023', message = 'field not allowed: ' || v_k;
    end if;
  end loop;
  if (p_link ? 'quoted_pack_price') and not v_fin then raise exception using errcode = '42501', message = 'read_finance denied'; end if;
  select * into l from public.inventory_item_suppliers k where k.item_id = p_item_id and k.supplier_id = p_supplier_id for update;
  v_had := found;
  v_before := case when v_had then jsonb_build_object('pack_label', l.pack_label, 'pack_size', l.pack_size, 'preferred', l.is_preferred)
                     || case when v_fin then jsonb_build_object('quoted_pack_price', l.quoted_pack_price) else '{}'::jsonb end end;
  if p_link ? 'pack_label' then
    v_t := nullif(btrim(coalesce(p_link->>'pack_label', '')), '');
    if v_t is not null and char_length(v_t) > 40 then raise exception using errcode = '22023', message = 'pack label is too long'; end if;
    l.pack_label := v_t;
  end if;
  if p_link ? 'pack_size' then
    v_n := (p_link->>'pack_size')::numeric;
    if v_n is not null and (v_n <= 0 or v_n >= 100000 or v_n <> round(v_n, 2)) then raise exception using errcode = '22023', message = 'pack size must be more than 0'; end if;
    l.pack_size := v_n;
  end if;
  if p_link ? 'quoted_pack_price' then
    v_n := (p_link->>'quoted_pack_price')::numeric;
    if v_n is not null and (v_n <= 0 or v_n >= 1000000 or v_n <> round(v_n, 2)) then raise exception using errcode = '22023', message = 'price must be more than 0 and less than 1,000,000, with at most 2 decimals'; end if;
    l.quoted_pack_price := v_n;
  end if;
  if p_link ? 'preferred' then
    if jsonb_typeof(p_link->'preferred') <> 'boolean' then raise exception using errcode = '22023', message = 'preferred must be true or false'; end if;
    l.is_preferred := (p_link->>'preferred')::boolean;
  end if;
  if coalesce(l.is_preferred, false) then
    update public.inventory_item_suppliers set is_preferred = false where item_id = p_item_id and supplier_id <> p_supplier_id and is_preferred;
  end if;
  if v_had then
    update public.inventory_item_suppliers set pack_label = l.pack_label, pack_size = l.pack_size, quoted_pack_price = l.quoted_pack_price, is_preferred = l.is_preferred
    where item_id = p_item_id and supplier_id = p_supplier_id;
  else
    insert into public.inventory_item_suppliers(item_id, supplier_id, pack_label, pack_size, quoted_pack_price, is_preferred)
    values (p_item_id, p_supplier_id, l.pack_label, l.pack_size, l.quoted_pack_price, coalesce(l.is_preferred, false));
  end if;
  return jsonb_build_object('ok', true, 'before', v_before);
end;
$$;

-- R5: remove a link.
create or replace function public.inventory_item_supplier_unlink_v1(p_item_id uuid, p_supplier_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_prop uuid; l public.inventory_item_suppliers%rowtype; v_fin boolean;
begin
  select i.property_id into v_prop from public.inventory_items i where i.id = p_item_id;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('manage_inventory', v_prop);
  v_fin := public.finance_human_authorized(v_prop);
  delete from public.inventory_item_suppliers k where k.item_id = p_item_id and k.supplier_id = p_supplier_id returning * into l;
  if not found then return jsonb_build_object('ok', true, 'removed', false, 'before', null); end if;
  return jsonb_build_object('ok', true, 'removed', true,
    'before', jsonb_build_object('pack_label', l.pack_label, 'pack_size', l.pack_size, 'preferred', l.is_preferred)
              || case when v_fin then jsonb_build_object('quoted_pack_price', l.quoted_pack_price) else '{}'::jsonb end);
end;
$$;

-- R6: price history of one item (owner, admin, finance).
create or replace function public.inventory_price_history_v1(p_item_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare i public.inventory_items%rowtype; v_rows jsonb; v_stats jsonb; v_by jsonb; v_today date := public.manila_today();
begin
  select * into i from public.inventory_items x where x.id = p_item_id;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  if not public.finance_human_authorized(i.property_id) then raise exception using errcode = '42501', message = 'read_finance denied'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('at', x.purchased_at, 'supplier_id', x.supplier_id, 'supplier', x.sname, 'qty', x.qty, 'unit_price', x.unit_cost,
      'pack_price', round(x.unit_cost * x.units_per_purchase, 2), 'source', x.src) order by x.purchased_at desc, x.created_at desc, x.id desc), '[]'::jsonb) into v_rows
  from (
    select p.id, p.purchased_at, p.created_at, p.supplier_id, p.qty, p.unit_cost, p.units_per_purchase, coalesce(s.name, p.supplier) as sname,
           case when p.notes like 'Admin receipt [key:%' then 'app' when p.notes like 'Auto-restock from receipt OCR%' then 'telegram' else 'old' end as src
    from public.inventory_purchases p left join public.inventory_suppliers s on s.id = p.supplier_id
    where p.item_id = p_item_id and p.unit_cost is not null
    order by p.purchased_at desc, p.created_at desc, p.id desc limit 50
  ) x;
  select jsonb_build_object(
    'last', (array_agg(p.unit_cost order by p.purchased_at desc, p.created_at desc, p.id desc))[1],
    'last_at', (array_agg(p.purchased_at order by p.purchased_at desc, p.created_at desc, p.id desc))[1],
    'avg_180d', round(sum(p.qty * p.unit_cost) filter (where p.purchased_at >= v_today - 180) / nullif(sum(p.qty) filter (where p.purchased_at >= v_today - 180), 0), 4),
    'min_365d', min(p.unit_cost) filter (where p.purchased_at >= v_today - 365),
    'n', count(*)) into v_stats
  from public.inventory_purchases p where p.item_id = p_item_id and p.unit_cost is not null;
  select coalesce(jsonb_agg(jsonb_build_object('supplier_id', y.supplier_id, 'name', y.name, 'last_unit_price', y.unit_cost, 'last_at', y.purchased_at, 'times', y.times)
      order by y.unit_cost, y.purchased_at desc), '[]'::jsonb) into v_by
  from (
    select distinct on (p.supplier_id) p.supplier_id, s.name, p.unit_cost, p.purchased_at, count(*) over (partition by p.supplier_id) as times
    from public.inventory_purchases p join public.inventory_suppliers s on s.id = p.supplier_id
    where p.item_id = p_item_id and p.unit_cost is not null
    order by p.supplier_id, p.purchased_at desc, p.created_at desc, p.id desc
  ) y;
  return jsonb_build_object('ok', true, 'unit', i.unit, 'units_per_purchase', i.units_per_purchase, 'rows', v_rows, 'stats', v_stats, 'by_supplier', v_by,
    'jump', public.s_inventory_price_jump_v1(p_item_id));
end;
$$;

-- R7: set or clear an item's photo path (every staff role that reads operations; override 9.1). The object must already exist in the bucket.
create or replace function public.inventory_item_photo_set_v1(p_item_id uuid, p_path text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_prop uuid; v_before text;
begin
  select i.property_id, i.photo_path into v_prop, v_before from public.inventory_items i where i.id = p_item_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('read_operations', v_prop);
  if p_path is not null then
    if p_path !~ ('^items/' || p_item_id::text || '/[0-9a-f-]{36}[.](jpg|webp)$')
       or not exists (select 1 from storage.objects o where o.bucket_id = 'inventory-photos' and o.name = p_path) then
      return jsonb_build_object('ok', false, 'reason', 'bad_path');
    end if;
  end if;
  update public.inventory_items set photo_path = p_path where id = p_item_id;
  return jsonb_build_object('ok', true, 'before', v_before);
end;
$$;

-- R8: rename or merge categories by moving items.
create or replace function public.inventory_items_recategorize_v1(p_property_id uuid, p_item_ids uuid[], p_category text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_cat text := btrim(coalesce(p_category, '')); v_moved jsonb;
begin
  perform public.admin_require('manage_inventory', p_property_id);
  if char_length(v_cat) not between 1 and 60 then raise exception using errcode = '22023', message = 'category must be 1 to 60 characters'; end if;
  if p_item_ids is null or cardinality(p_item_ids) not between 1 and 200 then raise exception using errcode = '22023', message = 'choose 1 to 200 items'; end if;
  if (select count(*) from public.inventory_items i where i.property_id = p_property_id and i.id = any (p_item_ids)) <> (select count(distinct x) from unnest(p_item_ids) x) then
    raise exception using errcode = '22023', message = 'some items are not in this property';
  end if;
  with old as (
    select i.id, i.category from public.inventory_items i where i.property_id = p_property_id and i.id = any (p_item_ids) and i.category is distinct from v_cat
  ), upd as (
    update public.inventory_items i set category = v_cat from old where i.id = old.id returning i.id
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', old.id, 'before', old.category)), '[]'::jsonb) into v_moved from old join upd on upd.id = old.id;
  return jsonb_build_object('ok', true, 'moved', v_moved);
end;
$$;

-- R9: give every active item that has no code at all a deterministic CH- QR code. A repeat call mints nothing new.
create or replace function public.inventory_code_mint_v1(p_property_id uuid, p_item_ids uuid[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_minted jsonb; v_cnt integer; v_total integer;
begin
  perform public.admin_require('manage_inventory', p_property_id);
  if p_item_ids is null or cardinality(p_item_ids) not between 1 and 500 then raise exception using errcode = '22023', message = 'choose 1 to 500 items'; end if;
  select count(distinct x) into v_total from unnest(p_item_ids) x;
  with todo as (
    select i.id from public.inventory_items i
    where i.property_id = p_property_id and i.id = any (p_item_ids) and i.is_active and not exists (select 1 from public.inventory_item_codes c where c.item_id = i.id)
  ), ins as (
    insert into public.inventory_item_codes(property_id, item_id, code, format, created_by)
    select p_property_id, todo.id, 'CH-' || upper(left(replace(todo.id::text, '-', ''), 10)), 'qr_code', auth.uid() from todo
    on conflict (property_id, code) do nothing
    returning item_id, code
  )
  select coalesce(jsonb_agg(jsonb_build_object('item_id', ins.item_id, 'code', ins.code)), '[]'::jsonb), count(*)::integer into v_minted, v_cnt from ins;
  return jsonb_build_object('ok', true, 'minted', v_minted, 'skipped', v_total - v_cnt);
end;
$$;

-- 11. service_role functions: the Telegram bot and the categoriser --------------------------------------------------------------------------------

-- R10: create (or return the same-name) supplier and teach it the receipt spelling.
create or replace function public.s_inventory_supplier_create_v1(p_property_id uuid, p_name text, p_alias text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_name text := btrim(coalesce(p_name, '')); v_alias text := lower(btrim(coalesce(p_alias, ''))); v_id uuid; v_created boolean := false;
begin
  if char_length(v_name) not between 2 and 80 then raise exception using errcode = '22023', message = 'name must be 2 to 80 characters'; end if;
  if not exists (select 1 from public.properties where id = p_property_id) then raise exception using errcode = 'P0002', message = 'property not found'; end if;
  insert into public.inventory_suppliers(property_id, name) values (p_property_id, v_name)
  on conflict (property_id, (lower(btrim(name)))) do nothing returning id into v_id;
  v_created := v_id is not null;
  if v_id is null then select s.id into v_id from public.inventory_suppliers s where s.property_id = p_property_id and lower(btrim(s.name)) = lower(v_name); end if;
  if v_alias <> '' and char_length(v_alias) <= 80 then
    update public.inventory_suppliers set aliases = array(select distinct u from unnest(aliases || v_alias) u order by u) where id = v_id and not (v_alias = any (aliases));
  end if;
  return jsonb_build_object('ok', true, 'supplier_id', v_id, 'created', v_created);
end;
$$;

-- R11: add a receipt spelling to a supplier (idempotent).
create or replace function public.s_inventory_supplier_alias_v1(p_supplier_id uuid, p_alias text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_alias text := lower(btrim(coalesce(p_alias, '')));
begin
  if not exists (select 1 from public.inventory_suppliers where id = p_supplier_id) then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_alias = '' or char_length(v_alias) > 80 then raise exception using errcode = '22023', message = 'alias must be 1 to 80 characters'; end if;
  update public.inventory_suppliers set aliases = array(select distinct u from unnest(aliases || v_alias) u order by u) where id = p_supplier_id and not (v_alias = any (aliases));
  return jsonb_build_object('ok', true);
end;
$$;

-- R12: re-point purchases made by the OCR path (created in the last 24 hours) to another supplier, or to none.
create or replace function public.s_inventory_purchase_supplier_set_v1(p_purchase_ids uuid[], p_supplier_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_n integer; v_ok integer; v_name text; v_before jsonb; v_changed integer;
begin
  if p_purchase_ids is null or cardinality(p_purchase_ids) not between 1 and 200 then raise exception using errcode = '22023', message = 'choose 1 to 200 purchases'; end if;
  select count(distinct x) into v_n from unnest(p_purchase_ids) x;
  select count(*) into v_ok from public.inventory_purchases p
  where p.id = any (p_purchase_ids) and p.notes like 'Auto-restock from receipt OCR%' and p.created_at > now() - interval '24 hours';
  if v_ok <> v_n then return jsonb_build_object('ok', false, 'reason', 'not_ocr'); end if;
  if p_supplier_id is not null then
    select s.name into v_name from public.inventory_suppliers s where s.id = p_supplier_id
      and not exists (select 1 from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
                      where p.id = any (p_purchase_ids) and i.property_id is distinct from s.property_id);
    if not found then return jsonb_build_object('ok', false, 'reason', 'supplier_not_found'); end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'supplier_id', p.supplier_id, 'supplier', p.supplier)), '[]'::jsonb) into v_before
  from public.inventory_purchases p where p.id = any (p_purchase_ids);
  update public.inventory_purchases set supplier_id = p_supplier_id, supplier = v_name where id = any (p_purchase_ids);
  get diagnostics v_changed = row_count;
  return jsonb_build_object('ok', true, 'changed', v_changed, 'before', v_before);
end;
$$;

-- Categoriser write (9.5): only an Uncategorised item, only into a category that already exists, always with an audit row.
create or replace function public.s_inventory_item_category_auto_v1(p_item_id uuid, p_category text, p_confidence numeric)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i public.inventory_items%rowtype; v_cat text := btrim(coalesce(p_category, ''));
begin
  if p_confidence is null or p_confidence < 0 or p_confidence > 1 then raise exception using errcode = '22023', message = 'confidence must be between 0 and 1'; end if;
  select * into i from public.inventory_items x where x.id = p_item_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'item_not_found'); end if;
  if i.category is distinct from 'Uncategorised' then return jsonb_build_object('ok', false, 'reason', 'not_uncategorised'); end if;
  if v_cat = '' or v_cat = 'Uncategorised' or not exists (select 1 from public.inventory_items x where x.property_id = i.property_id and x.category = v_cat) then
    return jsonb_build_object('ok', false, 'reason', 'unknown_category');
  end if;
  update public.inventory_items set category = v_cat where id = i.id;
  insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor)
  values ('inventory_items', i.id, 'category_auto', jsonb_build_object('category', i.category), jsonb_build_object('category', v_cat, 'confidence', p_confidence), 'jev');
  return jsonb_build_object('ok', true, 'item_id', i.id, 'before', i.category, 'after', v_cat);
end;
$$;

-- 12. grants --------------------------------------------------------------------------------------------------------------------------------------
revoke all on function public.get_inventory_catalogue_v1(uuid) from public, anon, service_role;
revoke all on function public.inventory_item_update_v1(uuid, jsonb) from public, anon, service_role;
revoke all on function public.inventory_undo_v1(uuid, uuid) from public, anon, service_role;
revoke all on function public.get_shopping_list_v1(uuid) from public, anon, service_role;
revoke all on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid) from public, anon, service_role;
revoke all on function public.inventory_supplier_list_v1(uuid) from public, anon, service_role;
revoke all on function public.inventory_supplier_save_v1(uuid, jsonb, text) from public, anon, service_role;
revoke all on function public.inventory_supplier_detail_v1(uuid) from public, anon, service_role;
revoke all on function public.inventory_item_supplier_link_v1(uuid, uuid, jsonb) from public, anon, service_role;
revoke all on function public.inventory_item_supplier_unlink_v1(uuid, uuid) from public, anon, service_role;
revoke all on function public.inventory_price_history_v1(uuid) from public, anon, service_role;
revoke all on function public.inventory_item_photo_set_v1(uuid, text) from public, anon, service_role;
revoke all on function public.inventory_items_recategorize_v1(uuid, uuid[], text) from public, anon, service_role;
revoke all on function public.inventory_code_mint_v1(uuid, uuid[]) from public, anon, service_role;
grant execute on function public.get_inventory_catalogue_v1(uuid) to authenticated;
grant execute on function public.inventory_item_update_v1(uuid, jsonb) to authenticated;
grant execute on function public.inventory_undo_v1(uuid, uuid) to authenticated;
grant execute on function public.get_shopping_list_v1(uuid) to authenticated;
grant execute on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid) to authenticated;
grant execute on function public.inventory_supplier_list_v1(uuid) to authenticated;
grant execute on function public.inventory_supplier_save_v1(uuid, jsonb, text) to authenticated;
grant execute on function public.inventory_supplier_detail_v1(uuid) to authenticated;
grant execute on function public.inventory_item_supplier_link_v1(uuid, uuid, jsonb) to authenticated;
grant execute on function public.inventory_item_supplier_unlink_v1(uuid, uuid) to authenticated;
grant execute on function public.inventory_price_history_v1(uuid) to authenticated;
grant execute on function public.inventory_item_photo_set_v1(uuid, text) to authenticated;
grant execute on function public.inventory_items_recategorize_v1(uuid, uuid[], text) to authenticated;
grant execute on function public.inventory_code_mint_v1(uuid, uuid[]) to authenticated;

revoke all on function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid, uuid) from public, anon, authenticated;
revoke all on function public.s_inventory_supplier_resolve_v1(uuid, text) from public, anon, authenticated;
revoke all on function public.s_inventory_supplier_create_v1(uuid, text, text) from public, anon, authenticated;
revoke all on function public.s_inventory_supplier_alias_v1(uuid, text) from public, anon, authenticated;
revoke all on function public.s_inventory_purchase_supplier_set_v1(uuid[], uuid) from public, anon, authenticated;
revoke all on function public.s_inventory_item_category_auto_v1(uuid, text, numeric) from public, anon, authenticated;
grant execute on function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid, uuid) to service_role;
grant execute on function public.s_inventory_supplier_resolve_v1(uuid, text) to service_role;
grant execute on function public.s_inventory_supplier_create_v1(uuid, text, text) to service_role;
grant execute on function public.s_inventory_supplier_alias_v1(uuid, text) to service_role;
grant execute on function public.s_inventory_purchase_supplier_set_v1(uuid[], uuid) to service_role;
grant execute on function public.s_inventory_item_category_auto_v1(uuid, text, numeric) to service_role;

commit;
