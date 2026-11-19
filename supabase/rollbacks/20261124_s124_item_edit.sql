-- Rollback of s124_item_edit_20261124: puts the five live bodies (read 2026-11-19) back, drops the undo function, the name helper, the change table and inventory_items.updated_by.
-- Recorded changes are lost by design. Roll the staff app back first. Each restored body is checked against its original md5 (CR stripped).
begin;

CREATE OR REPLACE FUNCTION public.inventory_item_update_v1(p_item_id uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;
revoke all on function public.inventory_item_update_v1(uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.inventory_item_update_v1(uuid, jsonb) to authenticated;

CREATE OR REPLACE FUNCTION public.inventory_item_price_set_v1(p_item_id uuid, p_unit_cost numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;
revoke all on function public.inventory_item_price_set_v1(uuid, numeric) from public, anon, authenticated, service_role;
grant execute on function public.inventory_item_price_set_v1(uuid, numeric) to authenticated;

CREATE OR REPLACE FUNCTION public.inventory_item_photo_set_v1(p_item_id uuid, p_path text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;
revoke all on function public.inventory_item_photo_set_v1(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.inventory_item_photo_set_v1(uuid, text) to authenticated;

CREATE OR REPLACE FUNCTION public.get_inventory_catalogue_v1(p_property_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;
revoke all on function public.get_inventory_catalogue_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_inventory_catalogue_v1(uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.inventory_item_history_v1(p_item_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;
revoke all on function public.inventory_item_history_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.inventory_item_history_v1(uuid) to authenticated;

drop function if exists public.inventory_item_change_undo_v1(uuid);
drop function if exists public.s_inventory_actor_name_v1(uuid);
drop table if exists public.inventory_item_changes;
alter table public.inventory_items drop column if exists updated_by;

commit;
