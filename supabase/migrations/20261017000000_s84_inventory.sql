-- 20261017000000_s84_inventory.sql
-- Session 84, lane I-sql: release s84_inventory_20261017. Inventory: barcodes, par levels, price and level edits, item create, and the unit_cost leak closed.
--   1. Leak      inventory_items granted SELECT on every column to authenticated, and policy inventory_staff_read lets any read_operations session read
--                rows, so a cleaner could read unit_cost over REST (and the table was in the supabase_realtime publication, which would stream it).
--                Now: authenticated has SELECT on every column EXCEPT unit_cost (list derived from pg_attribute, so no column is dropped by mistake),
--                INSERT / UPDATE / DELETE and both policies are untouched, and the table leaves the realtime publication. unit_cost stays readable
--                through the definer RPCs only (get_inventory_catalogue_v1 for finance_human_authorized sessions). The service role keeps everything.
--   2. Par       inventory_items.par_qty (nullable): the level to buy back up to. Null means "2 x reorder_below" in the order list.
--   3. Codes     inventory_item_codes (RLS on, no client grants): one code maps to one item, one item may have many codes. No direct client access.
--   4. Catalogue get_inventory_catalogue_v1 = the live body plus two keys per item: par and codes. Codes are not sensitive and go to every
--                read_operations role. unitCost rule unchanged. Guarded by the md5 of the live body.
--   4b. Phase 1b  the catalogue also carries `countedAt` (latest app count or Telegram count, null if never). See section 4 below for
--                inventory_undo_v1, inventory_item_history_v1 and the weekly low-stock task trigger.
--   5. RPCs      inventory_code_attach_v1, inventory_code_detach_v1, inventory_item_create_v1, inventory_item_update_v1 (manage_inventory) and
--                inventory_item_price_set_v1 (read_finance: owner, admin, finance). Quantity changes stay on reconcile_inventory_baseline_v1 (Count it).
-- SINGLE SHOT: the guard compares the live catalogue body with the body this release was cut from, so a second run stops on its own md5 guard by design.
-- Apply after s82_staff_31_20261015 and s82_checklist_20261015. Another lane ships 20261017010000 in the same window: this file touches no calendar object
-- and not admin_stays_v1.
-- Rollback: supabase/rollbacks/20261017_s84_inventory.sql

begin;

-- 0. guard: the catalogue must still be the body this release was cut from (md5 of prosrc, carriage returns stripped) -------------------------
do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.get_inventory_catalogue_v1(uuid)');
  if v_got is null then
    raise exception 's84 inventory: public.get_inventory_catalogue_v1(uuid) does not exist' using errcode = '55000';
  end if;
  if v_got <> '07c22913a8cf0148d6f79f282d1585d1' then
    raise exception 's84 inventory: get_inventory_catalogue_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
end $$;

-- 1. schema --------------------------------------------------------------------------------------------------------------------------------
alter table public.inventory_items add column if not exists par_qty numeric(10,2)
  check (par_qty is null or (par_qty >= 0 and par_qty < 100000000));
comment on column public.inventory_items.par_qty is 'S84: the level to buy back up to. Null = 2 x reorder_below in the order list.';

-- the leak: revoking the table-level SELECT also clears any column grants, then every column but unit_cost is granted back
revoke select on table public.inventory_items from authenticated;
do $$
declare v_cols text;
begin
  select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into v_cols
  from pg_attribute a
  where a.attrelid = 'public.inventory_items'::regclass and a.attnum > 0 and not a.attisdropped and a.attname <> 'unit_cost';
  execute format('grant select (%s) on table public.inventory_items to authenticated', v_cols);
end $$;
comment on column public.inventory_items.unit_cost is 'S84: not readable by authenticated (column grant). Read through get_inventory_catalogue_v1 (finance_human_authorized) only.';

-- no client subscribes to it, and realtime does not enforce column grants
do $$
begin
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'inventory_items') then
    alter publication supabase_realtime drop table public.inventory_items;
  end if;
end $$;

create table public.inventory_item_codes (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete restrict,
  item_id     uuid not null references public.inventory_items(id) on delete cascade,
  code        text not null check (code ~ '^[!-~]{1,128}$'),
  format      text check (format is null or format ~ '^[a-z0-9_]{2,20}$'),
  created_by  uuid not null references auth.users(id) on delete restrict,
  created_at  timestamptz not null default now(),
  unique (property_id, code)
);
comment on table public.inventory_item_codes is 'S84: barcodes and QR codes linked to inventory items. One code = one item per property. No client access: codes reach the app inside get_inventory_catalogue_v1; writes go through inventory_code_attach_v1 / detach_v1 / inventory_item_create_v1.';
alter table public.inventory_item_codes enable row level security;
revoke all on table public.inventory_item_codes from public, anon, authenticated, service_role;
grant select on table public.inventory_item_codes to service_role;
create index inventory_item_codes_item_idx on public.inventory_item_codes (item_id);

-- 2. catalogue: the live body plus par and codes ---------------------------------------------------------------------------------------------
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
    'par', i.par_qty,
    'codes', coalesce((select jsonb_agg(c.code order by c.created_at, c.code) from public.inventory_item_codes c where c.item_id = i.id), '[]'::jsonb),
    'countedAt', (select max(t.at) from (
        select max(m.created_at) as at from public.inventory_stock_movements m where m.item_id = i.id and m.kind = 'reconcile'
        union all
        select max(a.created_at) from public.inventory_audit_log a where a.entity_type = 'inventory_items' and a.entity_id = i.id and a.action = 'telegram_count') t)
  ) order by i.sort_order, i.name), '[]'::jsonb) into v_items
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
revoke all on function public.get_inventory_catalogue_v1(uuid) from public, anon, service_role;
grant execute on function public.get_inventory_catalogue_v1(uuid) to authenticated;

-- 3. RPCs ------------------------------------------------------------------------------------------------------------------------------------
-- All security definer with an empty search_path; execute for signed-in users only (every one gates itself on a named action).

create or replace function public.inventory_code_attach_v1(p_property_id uuid, p_code text, p_format text, p_item_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_code text := btrim(coalesce(p_code, ''));
  v_fmt text := nullif(lower(btrim(coalesce(p_format, ''))), '');
  v_prop uuid; v_other uuid; v_other_name text;
begin
  perform public.admin_require('manage_inventory', p_property_id);
  select i.property_id into v_prop from public.inventory_items i where i.id = p_item_id;
  if v_prop is distinct from p_property_id then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  if v_code !~ '^[!-~]{1,128}$' or (v_fmt is not null and v_fmt !~ '^[a-z0-9_]{2,20}$') then
    return jsonb_build_object('ok', false, 'reason', 'bad_code');
  end if;
  insert into public.inventory_item_codes(property_id, item_id, code, format, created_by)
  values (p_property_id, p_item_id, v_code, v_fmt, auth.uid())
  on conflict (property_id, code) do nothing;
  if found then
    return jsonb_build_object('ok', true, 'item_id', p_item_id, 'code', v_code, 'replayed', false);
  end if;
  select c.item_id, i.name into v_other, v_other_name
  from public.inventory_item_codes c join public.inventory_items i on i.id = c.item_id
  where c.property_id = p_property_id and c.code = v_code;
  if v_other = p_item_id then
    return jsonb_build_object('ok', true, 'item_id', p_item_id, 'code', v_code, 'replayed', true);
  end if;
  return jsonb_build_object('ok', false, 'reason', 'code_taken', 'item_id', v_other, 'item_name', v_other_name);
end;
$$;

create or replace function public.inventory_code_detach_v1(p_property_id uuid, p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_removed boolean;
begin
  perform public.admin_require('manage_inventory', p_property_id);
  delete from public.inventory_item_codes where property_id = p_property_id and code = btrim(coalesce(p_code, ''));
  v_removed := found;
  return jsonb_build_object('ok', true, 'removed', v_removed);
end;
$$;

create or replace function public.inventory_item_create_v1(p_property_id uuid, p_item jsonb, p_code text default null, p_format text default null, p_idempotency_key text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_name text; v_cat text; v_unit text; v_cons boolean; v_reorder numeric; v_par numeric; v_pu text; v_upp numeric; v_qty numeric;
  v_code text := nullif(btrim(coalesce(p_code, '')), '');
  v_fmt text := nullif(lower(btrim(coalesce(p_format, ''))), '');
  v_key text; v_k text; v_existing uuid; v_other uuid; v_other_name text; v_id uuid; v_sort integer;
begin
  perform public.admin_require('manage_inventory', p_property_id);
  if p_item is null or jsonb_typeof(p_item) <> 'object' then raise exception using errcode = '22023', message = 'item must be an object'; end if;
  for v_k in select jsonb_object_keys(p_item) loop
    if v_k <> all (array['name', 'category', 'unit', 'consumable', 'reorder_below', 'par_qty', 'purchase_unit', 'units_per_purchase', 'qty']) then
      raise exception using errcode = '22023', message = 'field not allowed when adding an item: ' || v_k;
    end if;
  end loop;
  v_name := btrim(coalesce(p_item->>'name', ''));
  v_cat  := btrim(coalesce(p_item->>'category', ''));
  v_unit := coalesce(nullif(btrim(coalesce(p_item->>'unit', '')), ''), 'pc');
  if char_length(v_name) not between 2 and 80 then raise exception using errcode = '22023', message = 'name must be 2 to 80 characters'; end if;
  if char_length(v_cat) not between 1 and 60 then raise exception using errcode = '22023', message = 'category must be 1 to 60 characters'; end if;
  if char_length(v_unit) not between 1 and 20 then raise exception using errcode = '22023', message = 'unit must be 1 to 20 characters'; end if;
  v_cons    := coalesce((p_item->>'consumable')::boolean, false);
  v_reorder := (p_item->>'reorder_below')::numeric;
  v_par     := (p_item->>'par_qty')::numeric;
  v_qty     := (p_item->>'qty')::numeric;
  v_pu      := nullif(btrim(coalesce(p_item->>'purchase_unit', '')), '');
  v_upp     := coalesce((p_item->>'units_per_purchase')::numeric, 1);
  if v_reorder is not null and (v_reorder < 0 or v_reorder >= 100000000 or v_reorder <> round(v_reorder, 2)) then raise exception using errcode = '22023', message = 'reorder level must be 0 or more, with at most 2 decimals'; end if;
  if v_par is not null and (v_par < 0 or v_par >= 100000000 or v_par <> round(v_par, 2)) then raise exception using errcode = '22023', message = 'buy-up-to level must be 0 or more, with at most 2 decimals'; end if;
  if v_qty is not null and (v_qty < 0 or v_qty >= 100000000 or v_qty <> round(v_qty, 2)) then raise exception using errcode = '22023', message = 'counted quantity must be 0 or more, with at most 2 decimals'; end if;
  if v_upp <= 0 or v_upp >= 1000000 or v_upp <> round(v_upp, 4) then raise exception using errcode = '22023', message = 'units per pack must be more than 0'; end if;
  if v_pu is not null and char_length(v_pu) > 30 then raise exception using errcode = '22023', message = 'pack name is too long'; end if;
  if p_idempotency_key is not null and char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key must be 16 to 160 characters'; end if;
  if v_code is not null and (v_code !~ '^[!-~]{1,128}$' or (v_fmt is not null and v_fmt !~ '^[a-z0-9_]{2,20}$')) then
    return jsonb_build_object('ok', false, 'reason', 'bad_code');
  end if;

  -- one create per property + name at a time; an active item with the same name is the replay guard
  perform pg_advisory_xact_lock(hashtextextended('s84-item-create:' || p_property_id::text || ':' || lower(v_name), 0));
  select i.id into v_existing from public.inventory_items i
  where i.property_id = p_property_id and i.is_active and lower(btrim(i.name)) = lower(v_name) limit 1;
  if v_existing is not null then return jsonb_build_object('ok', false, 'reason', 'name_exists', 'item_id', v_existing); end if;
  if v_code is not null then
    select c.item_id, i.name into v_other, v_other_name
    from public.inventory_item_codes c join public.inventory_items i on i.id = c.item_id
    where c.property_id = p_property_id and c.code = v_code;
    if v_other is not null then return jsonb_build_object('ok', false, 'reason', 'code_taken', 'item_id', v_other, 'item_name', v_other_name); end if;
  end if;

  select coalesce(max(i.sort_order), 0) + 1 into v_sort from public.inventory_items i where i.property_id = p_property_id;
  insert into public.inventory_items(property_id, name, category, unit, qty_on_hand, reorder_below, par_qty, is_consumable, is_active, sort_order, purchase_unit, units_per_purchase)
  values (p_property_id, v_name, v_cat, v_unit, 0, v_reorder, v_par, v_cons, true, v_sort, v_pu, v_upp)
  returning id into v_id;
  if v_qty is not null then
    v_key := coalesce(p_idempotency_key, 'stk-create-' || replace(v_id::text, '-', ''));
    perform public.reconcile_inventory_baseline_v1(v_id, v_qty, 'First count when added in the staff app', v_key);
  end if;
  if v_code is not null then
    insert into public.inventory_item_codes(property_id, item_id, code, format, created_by)
    values (p_property_id, v_id, v_code, v_fmt, auth.uid())
    on conflict (property_id, code) do nothing;
    if not found then raise exception using errcode = '23505', message = 'code was linked by someone else a moment ago: try again'; end if;
  end if;
  return jsonb_build_object('ok', true, 'item_id', v_id);
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
    if v_k <> all (array['name', 'category', 'unit', 'consumable', 'reorder_below', 'par_qty', 'purchase_unit', 'units_per_purchase', 'active']) then
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
  update public.inventory_items set
    name = i.name, category = i.category, unit = i.unit, is_consumable = i.is_consumable, is_active = i.is_active,
    reorder_below = i.reorder_below, par_qty = i.par_qty, purchase_unit = i.purchase_unit, units_per_purchase = i.units_per_purchase
  where id = i.id;
  return jsonb_build_object('ok', true, 'item_id', i.id);
end;
$$;

create or replace function public.inventory_item_price_set_v1(p_item_id uuid, p_unit_cost numeric)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_prop uuid; v_before numeric;
begin
  select i.property_id, i.unit_cost into v_prop, v_before from public.inventory_items i where i.id = p_item_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  if not public.finance_human_authorized(v_prop) then raise exception using errcode = '42501', message = 'read_finance denied'; end if;
  if p_unit_cost is not null and (p_unit_cost <= 0 or p_unit_cost >= 1000000 or p_unit_cost <> round(p_unit_cost, 2)) then
    raise exception using errcode = '22023', message = 'price must be more than 0 and less than 1,000,000, with at most 2 decimals';
  end if;
  update public.inventory_items set unit_cost = p_unit_cost where id = p_item_id;
  return jsonb_build_object('ok', true, 'item_id', p_item_id, 'before', v_before, 'after', p_unit_cost);
end;
$$;

revoke all on function public.inventory_code_attach_v1(uuid, text, text, uuid) from public, anon, service_role;
revoke all on function public.inventory_code_detach_v1(uuid, text) from public, anon, service_role;
revoke all on function public.inventory_item_create_v1(uuid, jsonb, text, text, text) from public, anon, service_role;
revoke all on function public.inventory_item_update_v1(uuid, jsonb) from public, anon, service_role;
revoke all on function public.inventory_item_price_set_v1(uuid, numeric) from public, anon, service_role;
grant execute on function public.inventory_code_attach_v1(uuid, text, text, uuid) to authenticated;
grant execute on function public.inventory_code_detach_v1(uuid, text) to authenticated;
grant execute on function public.inventory_item_create_v1(uuid, jsonb, text, text, text) to authenticated;
grant execute on function public.inventory_item_update_v1(uuid, jsonb) to authenticated;
grant execute on function public.inventory_item_price_set_v1(uuid, numeric) to authenticated;

-- 4. Phase 1b: undo, item history, and the weekly low-stock task ------------------------------------------------------------------------------

-- Undo of a count or an app receipt, by the person who made it, within 15 minutes, only while it is still the item's latest change.
-- The ledger stays append-only: a count / receipt is reversed by a new 'adjustment' movement keyed stk-undo-<movement id> (a repeat replays).
-- A receipt undo also deletes that one app-made inventory_purchases row (never a Telegram OCR row) and reopens its shopping-list row.
-- Refusals come back as {ok:false, reason}: not_found | not_undoable | not_yours | too_late | stock_moved.
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
  perform public.admin_require('manage_inventory', i.property_id);

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
    if m.kind not in ('reconcile', 'receipt') then return jsonb_build_object('ok', false, 'reason', 'not_undoable'); end if;
    if m.actor_user_id is distinct from auth.uid() then return jsonb_build_object('ok', false, 'reason', 'not_yours'); end if;
    if m.created_at <= now() - interval '15 minutes' then return jsonb_build_object('ok', false, 'reason', 'too_late'); end if;
    if i.qty_on_hand is distinct from m.quantity_after
       or exists (select 1 from public.inventory_stock_movements x where x.item_id = m.item_id and x.sequence_no > m.sequence_no) then
      return jsonb_build_object('ok', false, 'reason', 'stock_moved');
    end if;
    perform public.record_inventory_movement(i.id, 'adjustment', m.quantity_before - m.quantity_after,
      'Undo in the staff app of ' || m.kind || ' ' || m.sequence_no::text, v_key);
  else
    -- an app receipt on an item that is not movement-controlled changed qty_on_hand directly
    if i.updated_at > pu.created_at + interval '5 seconds' or i.qty_on_hand < pu.qty then
      return jsonb_build_object('ok', false, 'reason', 'stock_moved');
    end if;
    update public.inventory_items set qty_on_hand = qty_on_hand - pu.qty where id = i.id;
  end if;

  if v_have_p then
    update public.inventory_shopping_list set status = 'approved', received_by = null, received_at = null, received_quantity = null,
      unit_cost = null, supplier = null, movement_id = null, purchase_id = null, version = version + 1, updated_at = now()
    where purchase_id = pu.id;
    delete from public.inventory_purchases where id = pu.id;
  end if;
  select it.qty_on_hand into v_after from public.inventory_items it where it.id = i.id;
  return jsonb_build_object('ok', true, 'item_id', i.id, 'qty', v_after);
end;
$$;

-- What happened to one item: use per clean, the last 10 changes (first names only), and the last purchase. unit_cost only for finance sessions.
create or replace function public.inventory_item_history_v1(p_item_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_prop uuid; v_fin boolean; v_c30 integer; v_c14 integer; v_used numeric; v_changes jsonb; v_last jsonb;
begin
  select i.property_id into v_prop from public.inventory_items i where i.id = p_item_id;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('read_operations', v_prop);
  v_fin := public.finance_human_authorized(v_prop);
  select count(*)::integer, (count(*) filter (where cs.cleaned_at >= now() - interval '14 days'))::integer into v_c30, v_c14
  from public.cleaning_sessions cs
  where cs.property_id = v_prop and cs.cleaning_type in ('turnover', 'deep_clean') and cs.cleaned_at >= now() - interval '30 days';
  select coalesce(sum(u.used_qty), 0) into v_used from public.inventory_usage u where u.item_id = p_item_id and u.session_date >= public.manila_today() - 30;
  select coalesce(jsonb_agg(jsonb_build_object('at', x.ts, 'kind', x.kind, 'before', x.qb, 'after', x.qa, 'who', x.who) order by x.ts desc), '[]'::jsonb) into v_changes
  from (
    select * from (
      select m.created_at as ts,
             case when m.kind = 'adjustment' and m.reason like 'Undo in the staff app%' then 'undo' when m.kind = 'reconcile' then 'counted'
                  when m.kind = 'receipt' then 'received' when m.kind = 'usage' then 'used' else 'adjusted' end as kind,
             m.quantity_before as qb, m.quantity_after as qa,
             (select public.staff_redact_v1(split_part(btrim(coalesce(nullif(btrim(au.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(au.raw_user_meta_data ->> 'display_name'), ''),
                       initcap(replace(split_part(coalesce(au.email, ''), '@', 1), '.', ' ')))), ' ', 1)) from auth.users au where au.id = m.actor_user_id) as who
      from public.inventory_stock_movements m where m.item_id = p_item_id
      union all
      select a.created_at, 'telegram_count', (a.before ->> 'qty_on_hand')::numeric, (a.after ->> 'qty_on_hand')::numeric, null::text
      from public.inventory_audit_log a where a.entity_type = 'inventory_items' and a.entity_id = p_item_id and a.action = 'telegram_count'
    ) u order by u.ts desc limit 10
  ) x;
  select jsonb_build_object('at', p.purchased_at, 'qty', p.qty) || case when v_fin then jsonb_build_object('unit_cost', p.unit_cost) else '{}'::jsonb end into v_last
  from public.inventory_purchases p where p.item_id = p_item_id order by p.purchased_at desc, p.created_at desc limit 1;
  return jsonb_build_object('ok', true,
    'usage', jsonb_build_object('cleans_30d', v_c30, 'used_30d', v_used, 'per_clean', case when v_c30 > 0 then round(v_used / v_c30, 2) end, 'cleans_14d', v_c14),
    'changes', v_changes, 'last_bought', v_last);
end;
$$;

revoke all on function public.inventory_undo_v1(uuid, uuid) from public, anon, service_role;
revoke all on function public.inventory_item_history_v1(uuid) from public, anon, service_role;
grant execute on function public.inventory_undo_v1(uuid, uuid) to authenticated;
grant execute on function public.inventory_item_history_v1(uuid) to authenticated;

-- Low stock becomes ONE task per property per ISO week (D-218): opened through system_task_open_v1 (keyed system:low_stock:<week>), refreshed while
-- open, reopened if this trigger closed it earlier in the same week, closed by this trigger when nothing is low, and an earlier week's open task is
-- closed when this week's opens. Unassigned, no Telegram, no push. Statement-level, so a bulk checklist submission runs it once. A task problem
-- must never block a count, a receipt or a checklist: any error becomes a WARNING and the work of this function (only) is rolled back.
create or replace function public.s_inventory_low_task_v1()
returns trigger language plpgsql security definer set search_path = '' as $$
declare r record; v_week text := to_char(timezone('Asia/Manila', now()), 'IYYY-"W"IW'); v_id uuid; v_title text; v_detail text;
begin
  begin
    for r in
      select i.property_id, count(*)::integer as n, (array_agg(i.name order by i.qty_on_hand - i.reorder_below, i.name))[1:8] as names
      from public.inventory_items i
      where i.is_active and i.reorder_below is not null and i.qty_on_hand <= i.reorder_below
      group by i.property_id
    loop
      v_title := 'Restock: ' || r.n::text || case when r.n = 1 then ' item is low' else ' items are low' end;
      v_detail := 'Open Inventory and choose Low first, or send the order list from there. ' || public.staff_redact_v1(array_to_string(r.names, ', '));
      v_id := public.system_task_open_v1(r.property_id, 'low_stock', v_week, v_title, v_detail, 'normal');
      update public.follow_up_tasks t
         set status = 'open', completed_at = null, completion_note = null, updated_at = now()
       where t.id = v_id and t.status = 'done' and t.completion_note like 'Closed automatically%';
      update public.follow_up_tasks t set title = v_title, detail = v_detail, updated_at = now()
       where t.id = v_id and t.status in ('open', 'in_progress') and (t.title is distinct from v_title or t.detail is distinct from v_detail);
      update public.follow_up_tasks t
         set status = 'done', completed_at = now(), completion_note = 'Closed automatically: this week''s list replaces it.', updated_at = now()
       where t.property_id = r.property_id and t.source_kind = 'low_stock' and t.idempotency_key like 'system:low_stock:%'
         and t.status in ('open', 'in_progress') and t.source_ref <> v_week;
    end loop;
    update public.follow_up_tasks t
       set status = 'done', completed_at = now(), completion_note = 'Closed automatically: nothing is low now.', updated_at = now()
     where t.source_kind = 'low_stock' and t.idempotency_key like 'system:low_stock:%' and t.status in ('open', 'in_progress')
       and not exists (select 1 from public.inventory_items i where i.property_id = t.property_id and i.is_active and i.reorder_below is not null and i.qty_on_hand <= i.reorder_below);
  exception when others then
    raise warning 's_inventory_low_task_v1: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;
revoke all on function public.s_inventory_low_task_v1() from public, anon, authenticated, service_role;
comment on function public.s_inventory_low_task_v1() is 'S84 Q6 (D-218): keeps ONE Follow-ups task per property per ISO week for low stock; warning-only on failure.';

create trigger s_inventory_low_task
  after insert or update of qty_on_hand, reorder_below, is_active on public.inventory_items
  for each statement execute function public.s_inventory_low_task_v1();

commit;
