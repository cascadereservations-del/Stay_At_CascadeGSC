-- Rollback for release s86_inventory_db_20261020. Compensating.
--   Functions: drops R1-R12, the resolver, the price-jump helper and the category writer; drops the 7-argument apply_inventory_purchase and the 9-argument
--   record_inventory_receipt_v1 and restores the 6- and 8-argument bodies this release was cut from (apply: invoker rights, search_path public, executable by
--   authenticated and service_role as before); puts get_inventory_catalogue_v1, inventory_item_update_v1 and inventory_undo_v1 back to the s84 / s85 bodies.
--   Data: puts the 'test' purchase back verbatim (read live 2026-10-15); reverses the category tidy BY ITEM ID from the category_tidy_s86 audit rows (an item
--   whose category was changed again since stays as it is; the audit rows stay as history).
--   DATA LOSS (by design): every supplier, supplier link and supplier_id on purchases and shopping rows, and every location value. Purchase rows written
--   after the release keep their per-base-unit price and base-unit qty (correct data either way; the old OCR path would have stored per-pack).
--   Storage: the three 'inv photos anon' policies are NOT recreated (they were a public write hole; Lloyd removed them 2026-10-15) and the bucket stays private.
--   Only the bucket size and mime limits are cleared.
-- Apply with run-sql-on-host.sh.

begin;

-- 1. new functions out ----------------------------------------------------------------------------------------------------------------------------
drop function if exists public.inventory_supplier_list_v1(uuid);
drop function if exists public.inventory_supplier_save_v1(uuid, jsonb, text);
drop function if exists public.inventory_supplier_detail_v1(uuid);
drop function if exists public.inventory_item_supplier_link_v1(uuid, uuid, jsonb);
drop function if exists public.inventory_item_supplier_unlink_v1(uuid, uuid);
drop function if exists public.inventory_price_history_v1(uuid);
drop function if exists public.inventory_item_photo_set_v1(uuid, text);
drop function if exists public.inventory_items_recategorize_v1(uuid, uuid[], text);
drop function if exists public.inventory_code_mint_v1(uuid, uuid[]);
drop function if exists public.s_inventory_supplier_create_v1(uuid, text, text);
drop function if exists public.s_inventory_supplier_alias_v1(uuid, text);
drop function if exists public.s_inventory_purchase_supplier_set_v1(uuid[], uuid);
drop function if exists public.s_inventory_item_category_auto_v1(uuid, text, numeric);
drop function if exists public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid, uuid);
drop function if exists public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid);

-- 2. old bodies back --------------------------------------------------------------------------------------------------------------------------------
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
      unit_cost = null, supplier = null, movement_id = null, purchase_id = null, version = version + 1, updated_at = now()
    where purchase_id = pu.id;
    delete from public.inventory_purchases where id = pu.id;
  end if;
  select it.qty_on_hand into v_after from public.inventory_items it where it.id = i.id;
  return jsonb_build_object('ok', true, 'item_id', i.id, 'qty', v_after);
end;
$$;
create or replace function public.record_inventory_receipt_v1(p_item_id uuid, p_packs numeric, p_unit_cost numeric, p_supplier text, p_purchased_at date, p_receipt_path text, p_shopping_list_id uuid, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i public.inventory_items%rowtype; v_units numeric; v_pid uuid; v_mid uuid; v_existing public.inventory_purchases%rowtype; v_sh_status text;
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
  -- Purchase packs convert to base units once, here (INV06).
  v_units := round(p_packs * coalesce(i.units_per_purchase, 1), 2);
  insert into public.inventory_purchases(item_id, purchased_at, qty, unit_cost, supplier, notes, receipt_path, purchase_unit, units_per_purchase)
  values (p_item_id, coalesce(p_purchased_at, current_date), v_units, case when p_unit_cost is not null then round(p_unit_cost / coalesce(nullif(i.units_per_purchase, 0), 1), 4) end, p_supplier, 'Admin receipt [key:' || p_idempotency_key || ']', p_receipt_path, i.purchase_unit, coalesce(i.units_per_purchase, 1)::integer)
  returning id into v_pid;
  if i.movement_controlled_at is not null then
    v_mid := public.inventory_apply_event_v1(p_item_id, 'receipt', v_units, 'Receipt of ' || p_packs::text || ' ' || coalesce(i.purchase_unit, 'pack') || coalesce(' from ' || p_supplier, ''), 'inventory_purchases', v_pid::text);
  else
    update public.inventory_items set qty_on_hand = coalesce(qty_on_hand, 0) + v_units, unit_cost = coalesce(case when p_unit_cost is not null then round(p_unit_cost / coalesce(nullif(units_per_purchase, 0), 1), 2) end, unit_cost) where id = p_item_id;
  end if;
  if p_shopping_list_id is not null then
    update public.inventory_shopping_list set status = 'received', received_by = auth.uid(), received_at = now(), received_quantity = v_units, unit_cost = p_unit_cost, supplier = p_supplier, movement_id = v_mid, purchase_id = v_pid, version = version + 1, updated_at = now()
    where id = p_shopping_list_id and property_id = i.property_id and status = 'approved';
  end if;
  return jsonb_build_object('ok', true, 'purchaseId', v_pid, 'movementId', v_mid, 'unitsAdded', v_units, 'controlled', i.movement_controlled_at is not null);
end;
$$;
create function public.apply_inventory_purchase(p_item_id uuid, p_qty numeric, p_unit_cost numeric, p_supplier text, p_purchased_at date, p_txn_id uuid)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_upp numeric; v_before numeric; v_after numeric; v_pid uuid; v_name text; v_controlled boolean; v_mv jsonb;
begin
  select coalesce(units_per_purchase, 1), qty_on_hand, name, movement_controlled_at is not null
    into v_upp, v_before, v_name, v_controlled
  from inventory_items where id = p_item_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'item_not_found');
  end if;

  -- S82: a movement-controlled item with this receipt transaction already restocked is answered, not added twice
  if v_controlled and p_txn_id is not null then
    select id into v_pid from inventory_purchases where item_id = p_item_id and notes like '%(txn ' || p_txn_id::text || ')%' limit 1;
    if found then
      return jsonb_build_object('ok', true, 'replayed', true, 'name', v_name, 'purchase_id', v_pid, 'qty_before', v_before, 'qty_after', v_before, 'added', 0);
    end if;
  end if;

  insert into inventory_purchases(item_id, qty, unit_cost, supplier, purchased_at, units_per_purchase, notes)
  values (p_item_id, p_qty, p_unit_cost, p_supplier, coalesce(p_purchased_at, current_date), v_upp,
          'Auto-restock from receipt OCR' || case when p_txn_id is not null then ' (txn ' || p_txn_id::text || ')' else '' end)
  returning id into v_pid;

  if v_controlled then
    v_mv := public.s_inventory_purchase_movement_v1(p_item_id, p_qty * v_upp,
              'Auto-restock from receipt OCR' || case when p_txn_id is not null then ' (txn ' || p_txn_id::text || ')' else '' end, v_pid::text);
    v_before := (v_mv ->> 'before')::numeric;
    v_after := (v_mv ->> 'after')::numeric;
  else
    v_after := coalesce(v_before, 0) + (p_qty * v_upp);
    update inventory_items set qty_on_hand = v_after where id = p_item_id;
  end if;

  insert into inventory_audit_log(entity_type, entity_id, action, before, after, actor)
  values ('inventory_items', p_item_id, 'ocr_restock',
          jsonb_build_object('qty_on_hand', v_before),
          jsonb_build_object('qty_on_hand', v_after, 'purchase_id', v_pid, 'qty_added', p_qty * v_upp),
          'telegram-ocr');

  return jsonb_build_object('ok', true, 'name', v_name, 'purchase_id', v_pid,
                            'qty_before', v_before, 'qty_after', v_after, 'added', p_qty * v_upp);
end; $$;
drop function if exists public.s_inventory_supplier_resolve_v1(uuid, text);
drop function if exists public.s_inventory_price_jump_v1(uuid);

revoke all on function public.get_inventory_catalogue_v1(uuid) from public, anon, service_role;
revoke all on function public.inventory_item_update_v1(uuid, jsonb) from public, anon, service_role;
revoke all on function public.inventory_undo_v1(uuid, uuid) from public, anon, service_role;
revoke all on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text) from public, anon, service_role;
grant execute on function public.get_inventory_catalogue_v1(uuid) to authenticated;
grant execute on function public.inventory_item_update_v1(uuid, jsonb) to authenticated;
grant execute on function public.inventory_undo_v1(uuid, uuid) to authenticated;
grant execute on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text) to authenticated;
revoke all on function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid) from public, anon;
grant execute on function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid) to authenticated, service_role;

-- 3. data -----------------------------------------------------------------------------------------------------------------------------------------
insert into public.inventory_purchases(id, item_id, purchased_at, qty, unit_cost, supplier, notes, created_at, batch_id, item_legacy_id, receipt_path, purchase_unit, units_per_purchase)
select '96b5fb7f-3800-49ab-af56-d3d248a87b2a'::uuid, '0bdd783a-77f8-4211-bf53-e1cbebcc284b'::uuid, date '2026-09-19', 1.00, 1.00, 'test',
       'Admin receipt [key:receipt-17a87497a102444394905b22f5f483a5]', timestamptz '2026-09-18 16:37:00.987575+00', null::uuid, null::text, null::text, null::text, 1
where exists (select 1 from public.inventory_items where id = '0bdd783a-77f8-4211-bf53-e1cbebcc284b')
on conflict (id) do nothing;

update public.inventory_items i set category = a.before->>'category'
from public.inventory_audit_log a
where a.action = 'category_tidy_s86' and a.entity_id = i.id and i.category = a.after->>'category';

-- 4. columns and tables out ------------------------------------------------------------------------------------------------------------------------
drop index if exists public.inventory_purchases_item_date_idx;
alter table public.inventory_purchases drop column if exists supplier_id;
alter table public.inventory_shopping_list drop column if exists supplier_id;
alter table public.inventory_items drop column if exists location;
drop table if exists public.inventory_item_suppliers;
drop table if exists public.inventory_suppliers;

-- 5. view grants, realtime, bucket limits -----------------------------------------------------------------------------------------------------------
grant all on public.price_history_by_item to anon, authenticated;
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'inventory_purchases') then
    alter publication supabase_realtime add table public.inventory_purchases;
  end if;
  if to_regclass('storage.buckets') is not null then
    update storage.buckets set file_size_limit = null, allowed_mime_types = null where id = 'inventory-photos';
  end if;
end $$;

commit;
