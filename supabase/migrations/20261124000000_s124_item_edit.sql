-- Session 124 (lane L1 SQL): release s124_item_edit_20261124. A cleaner (and owner/admin) edits an inventory item's details, price and photo in the staff app, every edit applies at once and can be undone, and the
-- item card shows "Updated <date> by <first name>". Contract: docs/s124/CONTRACT-item-edit.md (SQL section).
--
--   inventory_items.updated_by                    uuid null, no FK: who last wrote the item through this release (updated_at already exists and is set to now() with it).
--   inventory_item_changes                        closed table (RLS on, no grant to any API role): one row per details / price / photo edit with ONLY the changed keys in before / after.
--   inventory_item_update_v1(uuid, jsonb)         manage_inventory (every key as before) OR submit_cleaning (name, category, unit, reorder_below, par_qty, location; any other key 42501;
--                                                 a category must already be on an active item of the property). Return adds change_id (null when nothing changed).
--   inventory_item_price_set_v1(uuid, numeric)    finance_human_authorized (return unchanged + change_id) OR submit_cleaning: a blind price set, p_unit_cost required, return {ok,item_id,change_id}.
--                                                 A price edit ALWAYS writes a row (and a blind caller always gets a change_id): a null change_id would tell a cleaner the guess equals the price.
--   inventory_item_photo_set_v1(uuid, text)       same auth, now writes a 'photo' change row (return adds change_id; null when the path did not change).
--   inventory_item_change_undo_v1(uuid)           NEW: the actor (or manage_inventory) restores `before`; refusals not_found / already_undone / too_late (30 min, non-managers) / changed_since / name_exists.
--                                                 Never returns a price value.
--   get_inventory_catalogue_v1                    each item adds updatedAt / updatedBy (first name) from the newest not-undone change.
--   inventory_item_history_v1                     `changes` also carries change rows {at, kind:'details'|'price'|'photo', who, fields}: price fields only for finance, photo fields {}.
--   s_inventory_actor_name_v1(uuid)               internal helper (first name through staff_redact_v1), no grants to any role.
--
-- Money rule: no function here hands a price to a caller without finance. The change table is readable by nobody but the definer functions below; the price row's before/after reach a client only through
-- inventory_item_history_v1 when finance_human_authorized.
-- The five replaced bodies are read live 2026-11-19 (md5 of the CR-stripped body in each guard below); a DO block per function stops with 55000 when the live body is neither that original nor this release.
-- Rollback: supabase/rollbacks/20261124_s124_item_edit.sql (puts the five bodies back, drops the undo function, the helper, the table and the column; recorded changes are lost by design).

begin;

-- 1. guards: the live bodies this release replaces ----------------------------------------------------------------------------------------------------------------------------------
do $g$
declare r record; v text;
begin
  for r in select * from (values
    ('public.inventory_item_update_v1(uuid,jsonb)'::text,        '6b3e2d70b638282ed422166cb09ca0ad'::text, '209ac7a02e8f34fdbbd2ba6bf432316a'::text),
    ('public.inventory_item_price_set_v1(uuid,numeric)',          'aaf21c54f78fdd6abc7375632b95ee9b',       '0d89710776ad21c6f0e79c793184977a'),
    ('public.inventory_item_photo_set_v1(uuid,text)',             'fd631b2e5a376f17eff4e5ab5620f06f',       '833a1b7ade464cfad312924aa6a7d3f4'),
    ('public.get_inventory_catalogue_v1(uuid)',                   '60476644226a96e42ef723b513071cf9',       '2b07eed9209ccb4fe09836e30bf52999'),
    ('public.inventory_item_history_v1(uuid)',                    '2b70dd8912c80c42f20cc0441e865478',       'a8669ba0b6ff6654edf352e9b8d98543')
  ) as t(fn, orig, patched) loop
    select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = r.fn::regprocedure;
    if v is distinct from r.orig and v is distinct from r.patched then
      raise exception using errcode = '55000', message = 's124: ' || r.fn || ' is neither the expected live body nor this release (md5 ' || coalesce(v, 'null') || ')';
    end if;
  end loop;
end $g$;

-- 2. column and the closed table ----------------------------------------------------------------------------------------------------------------------------------------------------
alter table public.inventory_items add column if not exists updated_by uuid;
comment on column public.inventory_items.updated_by is 'S124: auth user who last edited the item through inventory_item_update_v1, inventory_item_price_set_v1, inventory_item_photo_set_v1 or inventory_item_change_undo_v1. No FK.';

create table if not exists public.inventory_item_changes (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.inventory_items(id) on delete cascade,
  property_id uuid not null,
  actor uuid not null,
  kind text not null check (kind in ('details', 'price', 'photo')),
  before jsonb not null,
  after jsonb not null,
  created_at timestamptz not null default now(),
  undone_at timestamptz
);
create index if not exists inventory_item_changes_item_idx on public.inventory_item_changes (item_id, created_at desc);
alter table public.inventory_item_changes enable row level security;
-- Supabase default privileges would grant a new table to the API roles: take every grant away
revoke all on table public.inventory_item_changes from public, anon, authenticated, service_role;
comment on table public.inventory_item_changes is
  'S124: one row per staff edit of an inventory item (details, price, photo) with only the changed keys in before / after. Closed table: read and written only by inventory_item_update_v1, inventory_item_price_set_v1, inventory_item_photo_set_v1, inventory_item_change_undo_v1, get_inventory_catalogue_v1 and inventory_item_history_v1. Price rows hold amounts: never expose them to a role without finance.';

-- 3. internal helper (no grants to any role) ------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.s_inventory_actor_name_v1(p_uid uuid)
returns text language sql stable set search_path = '' as $$
  select nullif(public.staff_redact_v1(split_part(btrim(coalesce(nullif(btrim(au.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(au.raw_user_meta_data ->> 'display_name'), ''),
           initcap(replace(split_part(coalesce(au.email, ''), '@', 1), '.', ' ')))), ' ', 1)), '')
  from auth.users au where au.id = p_uid
$$;
revoke all on function public.s_inventory_actor_name_v1(uuid) from public, anon, authenticated, service_role;

-- 4. inventory_item_update_v1 ------------------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.inventory_item_update_v1(p_item_id uuid, p_patch jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $body$
declare
  i public.inventory_items%rowtype; o public.inventory_items%rowtype; v_k text; v_n numeric; v_t text; v_dupe uuid; v_mgr boolean;
  v_b jsonb; v_a jsonb; v_cid uuid;
begin
  select * into i from public.inventory_items where id = p_item_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  -- s124: owner/admin (manage_inventory) as before; a cleaner (submit_cleaning) edits the plain details only; anyone else is refused 42501
  v_mgr := public.current_staff_authorized('manage_inventory', i.property_id);
  if not v_mgr then perform public.admin_require('submit_cleaning', i.property_id); end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then raise exception using errcode = '22023', message = 'nothing to change'; end if;
  for v_k in select jsonb_object_keys(p_patch) loop
    if not v_mgr and v_k <> all (array['name', 'category', 'unit', 'reorder_below', 'par_qty', 'location']) then
      raise exception using errcode = '42501', message = 'field not allowed for this role: ' || v_k;
    end if;
    if v_k <> all (array['name', 'category', 'unit', 'consumable', 'reorder_below', 'par_qty', 'purchase_unit', 'units_per_purchase', 'active', 'location']) then
      raise exception using errcode = '22023', message = 'field not allowed: ' || v_k;
    end if;
  end loop;
  o := i;
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
    if not v_mgr then
      -- a cleaner picks from the categories already on an active item (or the item's own); the stored spelling is the existing one
      select x.category into v_t from public.inventory_items x
      where x.property_id = i.property_id and (x.is_active or x.id = i.id) and lower(btrim(x.category)) = lower(v_t) order by (x.id = i.id) desc limit 1;
      if v_t is null then raise exception using errcode = '22023', message = 'category must be one already in use'; end if;
    end if;
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
  -- only the keys that really changed go into the change row (patch key names)
  select coalesce(jsonb_object_agg(b.key, b.value), '{}'::jsonb), coalesce(jsonb_object_agg(a.key, a.value), '{}'::jsonb) into v_b, v_a
  from jsonb_each(jsonb_build_object('name', o.name, 'category', o.category, 'unit', o.unit, 'consumable', o.is_consumable, 'active', o.is_active, 'reorder_below', o.reorder_below,
                                     'par_qty', o.par_qty, 'purchase_unit', o.purchase_unit, 'units_per_purchase', o.units_per_purchase, 'location', o.location)) b
  join jsonb_each(jsonb_build_object('name', i.name, 'category', i.category, 'unit', i.unit, 'consumable', i.is_consumable, 'active', i.is_active, 'reorder_below', i.reorder_below,
                                     'par_qty', i.par_qty, 'purchase_unit', i.purchase_unit, 'units_per_purchase', i.units_per_purchase, 'location', i.location)) a on a.key = b.key
  where b.value is distinct from a.value;
  if v_a = '{}'::jsonb then return jsonb_build_object('ok', true, 'item_id', i.id, 'change_id', null); end if;
  update public.inventory_items set
    name = i.name, category = i.category, unit = i.unit, is_consumable = i.is_consumable, is_active = i.is_active,
    reorder_below = i.reorder_below, par_qty = i.par_qty, purchase_unit = i.purchase_unit, units_per_purchase = i.units_per_purchase, location = i.location,
    updated_at = now(), updated_by = auth.uid()
  where id = i.id;
  insert into public.inventory_item_changes(item_id, property_id, actor, kind, before, after) values (i.id, i.property_id, auth.uid(), 'details', v_b, v_a) returning id into v_cid;
  return jsonb_build_object('ok', true, 'item_id', i.id, 'change_id', v_cid);
end;
$body$;
revoke all on function public.inventory_item_update_v1(uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.inventory_item_update_v1(uuid, jsonb) to authenticated;

-- 5. inventory_item_price_set_v1 ------------------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.inventory_item_price_set_v1(p_item_id uuid, p_unit_cost numeric)
returns jsonb language plpgsql volatile security definer set search_path = '' as $body$
declare v_prop uuid; v_before numeric; v_fin boolean; v_cid uuid;
begin
  select i.property_id, i.unit_cost into v_prop, v_before from public.inventory_items i where i.id = p_item_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  -- s124: finance as before; anyone else needs submit_cleaning and sets the price blind (no price comes back)
  v_fin := public.finance_human_authorized(v_prop);
  if not v_fin then perform public.admin_require('submit_cleaning', v_prop); end if;
  if p_unit_cost is null and not v_fin then raise exception using errcode = '22023', message = 'price is required'; end if;
  if p_unit_cost is not null and (p_unit_cost <= 0 or p_unit_cost >= 1000000 or p_unit_cost <> round(p_unit_cost, 2)) then
    raise exception using errcode = '22023', message = 'price must be more than 0 and less than 1,000,000, with at most 2 decimals';
  end if;
  update public.inventory_items set unit_cost = p_unit_cost, updated_at = now(), updated_by = auth.uid() where id = p_item_id;
  -- always a row: a missing change_id would tell a blind caller that the guess equals the current price
  insert into public.inventory_item_changes(item_id, property_id, actor, kind, before, after)
  values (p_item_id, v_prop, auth.uid(), 'price', jsonb_build_object('unit_cost', v_before), jsonb_build_object('unit_cost', p_unit_cost)) returning id into v_cid;
  if v_fin then return jsonb_build_object('ok', true, 'item_id', p_item_id, 'before', v_before, 'after', p_unit_cost, 'change_id', v_cid); end if;
  return jsonb_build_object('ok', true, 'item_id', p_item_id, 'change_id', v_cid);
end;
$body$;
revoke all on function public.inventory_item_price_set_v1(uuid, numeric) from public, anon, authenticated, service_role;
grant execute on function public.inventory_item_price_set_v1(uuid, numeric) to authenticated;

-- 6. inventory_item_photo_set_v1 ------------------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.inventory_item_photo_set_v1(p_item_id uuid, p_path text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $body$
declare v_prop uuid; v_before text; v_cid uuid;
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
  update public.inventory_items set photo_path = p_path, updated_at = now(), updated_by = auth.uid() where id = p_item_id;
  if v_before is distinct from p_path then
    insert into public.inventory_item_changes(item_id, property_id, actor, kind, before, after)
    values (p_item_id, v_prop, auth.uid(), 'photo', jsonb_build_object('photo_path', v_before), jsonb_build_object('photo_path', p_path)) returning id into v_cid;
  end if;
  return jsonb_build_object('ok', true, 'before', v_before, 'change_id', v_cid);
end;
$body$;
revoke all on function public.inventory_item_photo_set_v1(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.inventory_item_photo_set_v1(uuid, text) to authenticated;

-- 7. inventory_item_change_undo_v1 ------------------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.inventory_item_change_undo_v1(p_change_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $body$
declare
  c public.inventory_item_changes%rowtype; i public.inventory_items%rowtype; v_item uuid; v_mgr boolean; v_cur jsonb; v_k text;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  select x.item_id into v_item from public.inventory_item_changes x where x.id = p_change_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  -- the item first, then the change (the writers lock the item before they insert a change)
  select * into i from public.inventory_items where id = v_item for update;
  select * into c from public.inventory_item_changes where id = p_change_id for update;
  v_mgr := public.current_staff_authorized('manage_inventory', c.property_id);
  if not v_mgr then
    if c.actor <> auth.uid() then raise exception using errcode = '42501', message = 'only the person who made the change can undo it'; end if;
    perform public.admin_require('submit_cleaning', c.property_id);
  end if;
  if c.undone_at is not null then return jsonb_build_object('ok', false, 'reason', 'already_undone'); end if;
  if not v_mgr and c.created_at < now() - interval '30 minutes' then return jsonb_build_object('ok', false, 'reason', 'too_late'); end if;
  if exists (select 1 from public.inventory_item_changes n where n.item_id = c.item_id and n.kind = c.kind and n.undone_at is null and n.id <> c.id
             and (n.created_at, n.id) > (c.created_at, c.id)) then
    return jsonb_build_object('ok', false, 'reason', 'changed_since');
  end if;
  v_cur := jsonb_build_object('name', i.name, 'category', i.category, 'unit', i.unit, 'consumable', i.is_consumable, 'active', i.is_active, 'reorder_below', i.reorder_below,
                              'par_qty', i.par_qty, 'purchase_unit', i.purchase_unit, 'units_per_purchase', i.units_per_purchase, 'location', i.location,
                              'unit_cost', i.unit_cost, 'photo_path', i.photo_path);
  for v_k in select jsonb_object_keys(c.after) loop
    if v_cur -> v_k is distinct from c.after -> v_k then return jsonb_build_object('ok', false, 'reason', 'changed_since'); end if;
  end loop;
  if c.kind = 'details' then
    if c.before ? 'name' and exists (select 1 from public.inventory_items x where x.property_id = i.property_id and x.is_active and x.id <> i.id
                                     and lower(btrim(x.name)) = lower(btrim(c.before ->> 'name'))) then
      return jsonb_build_object('ok', false, 'reason', 'name_exists');
    end if;
    update public.inventory_items set
      name = case when c.before ? 'name' then c.before ->> 'name' else name end,
      category = case when c.before ? 'category' then c.before ->> 'category' else category end,
      unit = case when c.before ? 'unit' then c.before ->> 'unit' else unit end,
      is_consumable = case when c.before ? 'consumable' then (c.before ->> 'consumable')::boolean else is_consumable end,
      is_active = case when c.before ? 'active' then (c.before ->> 'active')::boolean else is_active end,
      reorder_below = case when c.before ? 'reorder_below' then (c.before ->> 'reorder_below')::numeric else reorder_below end,
      par_qty = case when c.before ? 'par_qty' then (c.before ->> 'par_qty')::numeric else par_qty end,
      purchase_unit = case when c.before ? 'purchase_unit' then c.before ->> 'purchase_unit' else purchase_unit end,
      units_per_purchase = case when c.before ? 'units_per_purchase' then (c.before ->> 'units_per_purchase')::numeric else units_per_purchase end,
      location = case when c.before ? 'location' then c.before ->> 'location' else location end,
      updated_at = now(), updated_by = auth.uid()
    where id = i.id;
  elsif c.kind = 'price' then
    update public.inventory_items set unit_cost = (c.before ->> 'unit_cost')::numeric, updated_at = now(), updated_by = auth.uid() where id = i.id;
  else
    update public.inventory_items set photo_path = c.before ->> 'photo_path', updated_at = now(), updated_by = auth.uid() where id = i.id;
  end if;
  update public.inventory_item_changes set undone_at = now() where id = c.id;
  return jsonb_build_object('ok', true, 'item_id', i.id, 'kind', c.kind);
end;
$body$;
revoke all on function public.inventory_item_change_undo_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.inventory_item_change_undo_v1(uuid) to authenticated;

-- 8. get_inventory_catalogue_v1: updatedAt / updatedBy ------------------------------------------------------------------------------------------------------------------------------
create or replace function public.get_inventory_catalogue_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $body$
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
    'usageState', i.usage_state, 'usagePerTurnover', i.consumption_per_booking, 'usageBaseline', i.usage_baseline_per_turnover,
    'lastRefillAt', i.last_refill_at, 'lastRefillQty', i.last_refill_qty,
    'lastCountAt', (select max(x.anchor_at) from public.inventory_usage_intervals x where x.item_id = i.id and x.source = 'count'),
    'usageCounts', (select count(*) from public.inventory_usage_intervals x where x.item_id = i.id and x.accepted and x.anchor_at > now() - interval '90 days'),
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
        select max(a.created_at) from public.inventory_audit_log a where a.entity_type = 'inventory_items' and a.entity_id = i.id and a.action = 'telegram_count') t),
    -- S124: the newest edit that was not undone, with the first name of who made it (null and null when there is none); never a price
    'updatedAt', lc.at, 'updatedBy', lc.who
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
  left join lateral (
    select c.created_at as at, public.s_inventory_actor_name_v1(c.actor) as who from public.inventory_item_changes c
    where c.item_id = i.id and c.undone_at is null order by c.created_at desc, c.id desc limit 1
  ) lc on true
  where i.property_id = p_property_id;
  return jsonb_build_object(
    'items', v_items, 'sourceAsOf', v_asof, 'turnoverRatePerDay', round(v_turnover_rate, 4),
    'forecastNote', 'Advisory reorder estimates use the last 30 days of recorded usage and require at least 14 usage days. When that history is not yet available, an estimate is shown instead, based on each item''s catalogued per-turnover consumption times the recent turnover rate. Forecasting never places orders.'
  );
end;
$body$;
revoke all on function public.get_inventory_catalogue_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_inventory_catalogue_v1(uuid) to authenticated;

-- 9. inventory_item_history_v1: change rows -----------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.inventory_item_history_v1(p_item_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $body$
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
  -- S124: movement rows keep their old shape; a change row is {at, kind: details|price|photo, who, fields}. Price amounts only for finance; photo fields are {}.
  select coalesce(jsonb_agg(case when x.fields is not null then jsonb_build_object('at', x.ts, 'kind', x.kind, 'who', x.who, 'fields', x.fields)
                                 else jsonb_build_object('at', x.ts, 'kind', x.kind, 'before', x.qb, 'after', x.qa, 'who', x.who) end order by x.ts desc), '[]'::jsonb) into v_changes
  from (
    select * from (
      select m.created_at as ts,
             case when m.kind = 'adjustment' and m.reason like 'Undo in the staff app%' then 'undo' when m.kind = 'reconcile' then 'counted'
                  when m.kind = 'receipt' then 'received' when m.kind = 'usage' then 'used' else 'adjusted' end as kind,
             m.quantity_before as qb, m.quantity_after as qa,
             (select public.staff_redact_v1(split_part(btrim(coalesce(nullif(btrim(au.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(au.raw_user_meta_data ->> 'display_name'), ''),
                       initcap(replace(split_part(coalesce(au.email, ''), '@', 1), '.', ' ')))), ' ', 1)) from auth.users au where au.id = m.actor_user_id) as who,
             null::jsonb as fields
      from public.inventory_stock_movements m where m.item_id = p_item_id
      union all
      select a.created_at, 'telegram_count', (a.before ->> 'qty_on_hand')::numeric, (a.after ->> 'qty_on_hand')::numeric, null::text, null::jsonb
      from public.inventory_audit_log a where a.entity_type = 'inventory_items' and a.entity_id = p_item_id and a.action = 'telegram_count'
      union all
      select c.created_at, c.kind, null::numeric, null::numeric, public.s_inventory_actor_name_v1(c.actor),
             case when c.kind = 'details' or (c.kind = 'price' and v_fin)
                  then (select coalesce(jsonb_object_agg(k.key, jsonb_build_object('before', c.before -> k.key, 'after', c.after -> k.key)), '{}'::jsonb) from jsonb_object_keys(c.after) as k(key))
                  else '{}'::jsonb end
      from public.inventory_item_changes c where c.item_id = p_item_id and c.undone_at is null
    ) u order by u.ts desc limit 10
  ) x;
  select jsonb_build_object('at', p.purchased_at, 'qty', p.qty) || case when v_fin then jsonb_build_object('unit_cost', p.unit_cost) else '{}'::jsonb end into v_last
  from public.inventory_purchases p where p.item_id = p_item_id order by p.purchased_at desc, p.created_at desc limit 1;
  return jsonb_build_object('ok', true,
    'usage', jsonb_build_object('cleans_30d', v_c30, 'used_30d', v_used, 'per_clean', case when v_c30 > 0 then round(v_used / v_c30, 2) end, 'cleans_14d', v_c14),
    'changes', v_changes, 'last_bought', v_last);
end;
$body$;
revoke all on function public.inventory_item_history_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.inventory_item_history_v1(uuid) to authenticated;

commit;
