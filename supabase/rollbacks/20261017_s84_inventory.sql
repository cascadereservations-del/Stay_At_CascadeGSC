-- Rollback for release s84_inventory_20261017. Compensating: puts get_inventory_catalogue_v1 back to the body this release was cut from, drops the five
-- RPCs, the inventory_item_codes table and inventory_items.par_qty, gives authenticated its table-wide SELECT back (so unit_cost is readable again, as
-- before this release) and puts the table back in the supabase_realtime publication.
-- DATA LOSS (by design): every barcode link and every par_qty value. Items created through inventory_item_create_v1 stay (normal inventory rows).
-- Prices set through inventory_item_price_set_v1 stay (they are unit_cost values). Phase 1b: the 'adjustment' movements an undo wrote stay (the ledger is
-- append-only); open or closed low_stock follow-up tasks stay as history; the catalogue loses `countedAt`.
-- Apply with run-sql-on-host.sh.

begin;

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
    'attention', (i.reorder_below is not null and i.qty_on_hand <= i.reorder_below) or lower(coalesce(i.status, 'good')) not in ('good','ok') or not i.is_active
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

-- record_inventory_receipt_v1 back to the live body (md5 7889f5755cfcbae237434feda42a19e4)
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

drop trigger if exists s_inventory_low_task on public.inventory_items;
drop function if exists public.s_inventory_low_task_v1();
drop function if exists public.inventory_item_history_v1(uuid);
drop function if exists public.inventory_undo_v1(uuid, uuid);
drop function if exists public.inventory_item_price_set_v1(uuid, numeric);
drop function if exists public.inventory_item_update_v1(uuid, jsonb);
drop function if exists public.inventory_item_create_v1(uuid, jsonb, text, text, text);
drop function if exists public.inventory_code_detach_v1(uuid, text);
drop function if exists public.inventory_code_attach_v1(uuid, text, text, uuid);

drop table if exists public.inventory_item_codes;
alter table public.inventory_items drop column if exists par_qty;
comment on column public.inventory_items.unit_cost is null;

revoke select on table public.inventory_items from authenticated;
grant select on table public.inventory_items to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'inventory_items') then
    alter publication supabase_realtime add table public.inventory_items;
  end if;
end $$;

commit;
