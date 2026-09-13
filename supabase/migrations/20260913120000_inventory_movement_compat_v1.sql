-- Admin modernisation, packets P16/P17/P18: one atomic inventory movement
-- path across the admin and the inventory/cleaner PWAs (PRD INV02/INV03/INV04).
--
-- Today two writers exist: record_inventory_usage (PWA, direct qty decrement,
-- clamps at zero) and record_inventory_movement (movement ledger that refuses
-- to run until the item has a reconciled baseline). This migration does NOT
-- drop either. It adds a reviewed baseline step and makes the two writers
-- share one path per item: once an item is baseline-reconciled, every usage
-- and receipt is written as a movement; until then the legacy behaviour is
-- unchanged. No item flips automatically (INV03: an empty movement table is
-- never zero physical stock).

alter table public.inventory_items add column if not exists movement_controlled_at timestamptz;
alter table public.inventory_items add column if not exists baseline_reviewed_by uuid;
alter table public.inventory_items add column if not exists baseline_note text;
comment on column public.inventory_items.movement_controlled_at is 'Set by reconcile_inventory_baseline_v1. From then on every stock change is an inventory_stock_movements row.';

-- Purchasing workflow (INV04): proposed -> approved -> received; receiving
-- writes the movement; financial treatment is a separate, linked step.
create table if not exists public.inventory_shopping_list (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  item_id uuid references public.inventory_items(id),
  item_name text not null,
  quantity numeric(10,2) not null check (quantity > 0),
  purchase_unit text,
  estimated_cost numeric(12,2),
  reason text,
  status text not null default 'proposed' check (status in ('proposed','approved','rejected','received','cancelled')),
  proposed_by uuid, proposed_at timestamptz not null default now(),
  approved_by uuid, approved_at timestamptz, approval_note text,
  received_by uuid, received_at timestamptz, received_quantity numeric(10,2), unit_cost numeric(12,2), supplier text,
  movement_id uuid references public.inventory_stock_movements(id),
  purchase_id uuid references public.inventory_purchases(id),
  transaction_id uuid,
  idempotency_key text not null unique check (char_length(idempotency_key) between 16 and 160),
  version integer not null default 1,
  updated_at timestamptz not null default now()
);
alter table public.inventory_shopping_list enable row level security;
revoke all on public.inventory_shopping_list from public, anon, authenticated, service_role;
grant select on public.inventory_shopping_list to authenticated;
create policy shopping_list_ops_read on public.inventory_shopping_list for select to authenticated using (public.current_staff_authorized('read_operations', property_id));

-- Reviewed baseline: a human states the counted quantity; this becomes the
-- 'reconcile' movement and switches the item to movement control.
create or replace function public.reconcile_inventory_baseline_v1(p_item_id uuid, p_counted_qty numeric, p_note text, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i public.inventory_items%rowtype; v_before numeric; v_mid uuid;
begin
  select * into i from public.inventory_items where id = p_item_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('manage_inventory', i.property_id);
  if p_counted_qty is null or p_counted_qty < 0 or p_counted_qty <> round(p_counted_qty, 2) then raise exception using errcode = '22023', message = 'counted quantity must be a non-negative number with at most 2 decimals'; end if;
  if p_note is null or char_length(btrim(p_note)) < 3 then raise exception using errcode = '22023', message = 'a count note is required'; end if;
  v_before := i.qty_on_hand;
  v_mid := public.record_inventory_movement(p_item_id, 'reconcile', p_counted_qty, 'Baseline count: ' || btrim(p_note), p_idempotency_key);
  update public.inventory_items set movement_controlled_at = coalesce(movement_controlled_at, now()), baseline_reviewed_by = auth.uid(), baseline_note = btrim(p_note) where id = p_item_id;
  return jsonb_build_object('ok', true, 'itemId', p_item_id, 'movementId', v_mid, 'before', v_before, 'after', p_counted_qty, 'variance', p_counted_qty - v_before);
end;
$$;
revoke all on function public.reconcile_inventory_baseline_v1(uuid, numeric, text, text) from public, anon, service_role;
grant execute on function public.reconcile_inventory_baseline_v1(uuid, numeric, text, text) to authenticated;

-- Internal: deterministic movement for a derived event (usage row, receipt).
-- Replaying the same source event yields the same key and therefore one movement.
create or replace function public.inventory_apply_event_v1(p_item_id uuid, p_kind text, p_quantity numeric, p_reason text, p_source_kind text, p_source_ref text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_key text;
begin
  v_key := left('evt-' || encode(extensions.digest(p_source_kind || '|' || p_source_ref || '|' || p_item_id::text || '|' || p_kind, 'sha256'), 'hex'), 80);
  return public.record_inventory_movement(p_item_id, p_kind, p_quantity, p_reason, v_key);
end;
$$;
revoke all on function public.inventory_apply_event_v1(uuid, text, numeric, text, text, text) from public, anon, authenticated, service_role;

-- record_inventory_usage v2: identical contract for callers (the PWA keeps
-- working). Controlled items route through the movement ledger and are
-- rejected (not clamped) when stock is insufficient; uncontrolled items keep
-- the legacy decrement. An optional rows[i].usage_key makes a retried
-- submission replay-safe.
create or replace function public.record_inventory_usage(
  p_property_id uuid,
  p_session_date date,
  p_logged_by text,
  p_notes text,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row jsonb; v_item uuid; v_qty numeric; v_count integer := 0; v_controlled boolean; v_usage_id uuid; v_usage_key text; v_existing uuid; v_moves jsonb := '[]'::jsonb; v_name text;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if not public.current_staff_authorized('submit_cleaning', p_property_id) then raise exception using errcode = '42501', message = 'staff access denied'; end if;
  if p_session_date is null then raise exception using errcode = '22023', message = 'session_date required'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception using errcode = '22023', message = 'rows required'; end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_item := (v_row ->> 'item_id')::uuid;
    v_qty  := (v_row ->> 'used_qty')::numeric;
    v_usage_key := nullif(v_row ->> 'usage_key', '');
    if v_item is null or v_qty is null or v_qty <= 0 then raise exception using errcode = '22023', message = 'each row needs item_id and a positive used_qty'; end if;
    select (movement_controlled_at is not null), name into v_controlled, v_name from public.inventory_items i where i.id = v_item and i.property_id = p_property_id for update;
    if v_controlled is null then raise exception using errcode = '22023', message = 'unknown item for property'; end if;

    -- Replay: a usage row with the same client key already exists.
    if v_usage_key is not null then
      select id into v_existing from public.inventory_usage u where u.item_id = v_item and u.notes like '%[key:' || v_usage_key || ']%' limit 1;
      if v_existing is not null then v_count := v_count + 1; continue; end if;
    end if;

    insert into public.inventory_usage(item_id, used_qty, session_date, logged_by, notes, property_id, submitted_by_user_id)
    values (v_item, v_qty, p_session_date, nullif(btrim(coalesce(p_logged_by, '')), ''),
            nullif(btrim(coalesce(p_notes, '')) || case when v_usage_key is not null then ' [key:' || v_usage_key || ']' else '' end, ''),
            p_property_id, auth.uid())
    returning id into v_usage_id;

    if v_controlled then
      if (select qty_on_hand from public.inventory_items where id = v_item) < v_qty then
        raise exception using errcode = '22023', message = 'insufficient stock for ' || v_name;
      end if;
      v_moves := v_moves || to_jsonb(public.inventory_apply_event_v1(v_item, 'usage', -v_qty, 'Usage ' || p_session_date::text || coalesce(' by ' || p_logged_by, ''), 'inventory_usage', v_usage_id::text));
    else
      update public.inventory_items set qty_on_hand = greatest(0, coalesce(qty_on_hand, 0) - v_qty) where id = v_item;
    end if;
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('ok', true, 'rows', v_count, 'movements', v_moves);
end;
$$;
comment on function public.record_inventory_usage(uuid, date, text, text, jsonb) is
  'v2 (admin modernisation): same contract. Movement-controlled items write inventory_stock_movements and reject insufficient stock; others keep the legacy decrement. Optional rows[i].usage_key makes retries replay-safe.';

-- Purchase receipt through the same path (INV04 receipt -> stock movement).
create or replace function public.record_inventory_receipt_v1(p_item_id uuid, p_packs numeric, p_unit_cost numeric, p_supplier text, p_purchased_at date, p_receipt_path text, p_shopping_list_id uuid, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i public.inventory_items%rowtype; v_units numeric; v_pid uuid; v_mid uuid; v_existing public.inventory_purchases%rowtype;
begin
  select * into i from public.inventory_items where id = p_item_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('manage_inventory', i.property_id);
  if p_packs is null or p_packs <= 0 then raise exception using errcode = '22023', message = 'packs must be positive'; end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key required'; end if;
  select * into v_existing from public.inventory_purchases p where p.notes like '%[key:' || p_idempotency_key || ']%' limit 1;
  if found then return jsonb_build_object('ok', true, 'replayed', true, 'purchaseId', v_existing.id); end if;
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
revoke all on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text) from public, anon, service_role;
grant execute on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text) to authenticated;

create or replace function public.save_shopping_item_v1(p_property_id uuid, p_item jsonb, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_row public.inventory_shopping_list%rowtype; v_id uuid; v_status text;
begin
  perform public.admin_require('read_operations', p_property_id);
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key required'; end if;
  v_id := nullif(p_item->>'id', '')::uuid;
  if v_id is null then
    select * into v_row from public.inventory_shopping_list where idempotency_key = p_idempotency_key;
    if found then return jsonb_build_object('ok', true, 'id', v_row.id, 'replayed', true); end if;
    insert into public.inventory_shopping_list(property_id, item_id, item_name, quantity, purchase_unit, estimated_cost, reason, proposed_by, idempotency_key)
    values (p_property_id, nullif(p_item->>'item_id', '')::uuid, p_item->>'item_name', (p_item->>'quantity')::numeric, p_item->>'purchase_unit', nullif(p_item->>'estimated_cost', '')::numeric, p_item->>'reason', auth.uid(), p_idempotency_key)
    returning * into v_row;
  else
    v_status := p_item->>'status';
    if v_status in ('approved','rejected') then perform public.admin_require('manage_inventory', p_property_id); end if;
    select * into v_row from public.inventory_shopping_list where id = v_id and property_id = p_property_id for update;
    if not found then raise exception using errcode = 'P0002', message = 'shopping item not found'; end if;
    if v_status = 'received' then raise exception using errcode = '22023', message = 'use record_inventory_receipt_v1 to receive goods'; end if;
    update public.inventory_shopping_list set
      status = coalesce(v_status, status), quantity = coalesce(nullif(p_item->>'quantity', '')::numeric, quantity), reason = coalesce(p_item->>'reason', reason),
      approved_by = case when v_status in ('approved','rejected') then auth.uid() else approved_by end,
      approved_at = case when v_status in ('approved','rejected') then now() else approved_at end,
      approval_note = coalesce(p_item->>'approval_note', approval_note), version = version + 1, updated_at = now()
    where id = v_id returning * into v_row;
  end if;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status, 'version', v_row.version);
end;
$$;
revoke all on function public.save_shopping_item_v1(uuid, jsonb, text) from public, anon, service_role;
grant execute on function public.save_shopping_item_v1(uuid, jsonb, text) to authenticated;

-- Catalogue read model with coverage flags (INV01/INV05).
create or replace function public.get_inventory_catalogue_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_items jsonb; v_asof timestamptz; v_fin boolean;
begin
  perform public.admin_require('read_operations', p_property_id);
  v_fin := public.finance_human_authorized(p_property_id);
  select max(updated_at) into v_asof from public.inventory_items where property_id = p_property_id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', i.id, 'name', i.name, 'category', i.category, 'unit', i.unit, 'qty', i.qty_on_hand, 'reorderBelow', i.reorder_below, 'consumable', i.is_consumable, 'active', i.is_active,
    'status', i.status, 'unitCost', case when v_fin then i.unit_cost end, 'purchaseUnit', i.purchase_unit, 'unitsPerPurchase', i.units_per_purchase, 'photo', i.photo_path,
    'movementControlled', i.movement_controlled_at is not null, 'baselineNote', i.baseline_note,
    'usage30d', u.used, 'usageDays', u.days, 'avgDaily', case when u.days >= 14 and u.used > 0 then round(u.used / 30.0, 3) end,
    'coverageDays', case when u.days >= 14 and u.used > 0 then round(i.qty_on_hand / (u.used / 30.0), 1) end,
    'attention', (i.reorder_below is not null and i.qty_on_hand <= i.reorder_below) or lower(coalesce(i.status, 'good')) not in ('good','ok') or not i.is_active
  ) order by i.sort_order, i.name), '[]'::jsonb) into v_items
  from public.inventory_items i
  left join lateral (
    select coalesce(sum(used_qty), 0) used, count(distinct session_date) days from public.inventory_usage x where x.item_id = i.id and x.session_date >= public.manila_today() - 30
  ) u on true
  where i.property_id = p_property_id;
  return jsonb_build_object('items', v_items, 'sourceAsOf', v_asof, 'forecastNote', 'Advisory reorder estimates use the last 30 days of recorded usage and require at least 14 usage days. Forecasting never places orders.');
end;
$$;
revoke all on function public.get_inventory_catalogue_v1(uuid) from public, anon, service_role;
grant execute on function public.get_inventory_catalogue_v1(uuid) to authenticated;
