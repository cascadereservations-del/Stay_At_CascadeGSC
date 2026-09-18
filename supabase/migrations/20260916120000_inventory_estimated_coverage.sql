-- 20260916120000_inventory_estimated_coverage.sql (admin session 21)
-- get_inventory_catalogue_v1's coverageDays/avgDaily need 14+ days of real
-- inventory_usage rows, and live query 2026-09-16 confirms 0 of 64 active
-- items have that yet (D-134/D-135's known blocker). Lloyd asked for a
-- simpler estimate meanwhile: each item already carries consumption_per_booking
-- (set per turnover), and the recent turnover rate is directly observable
-- from cleaning_sessions. estDailyUsage/estCoverageDays are additive fields,
-- clearly separate from the measured usage30d/avgDaily/coverageDays above
-- them - the client must label them as an estimate, never presented as
-- measured. Every consumable currently has consumption_per_booking = 2.00
-- (confirmed live, looks like an unset default, not tuned per-item data), so
-- the first estimates shown will be uniform until Lloyd sets real values -
-- the mechanism itself is correct regardless.
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

-- forward check: query the read model directly (bypassing the RPC's staff
-- auth gate, which has no session to check under a raw psql connection) and
-- confirm the new fields exist in shape for a real consumable.
--
-- It only asserts where there IS a consumable to assert on. This file was untracked until 2026-09-18
-- because it had only ever run against production; tracked as a migration, it also runs against CI's
-- FRESH database, which has no inventory rows, and the unconditional raise took Cascade CI red
-- (run 35367021851, D-193). Skipping on an empty catalogue keeps the check honest where it matters and
-- silent where there is nothing to check.
do $$
declare v_est_daily numeric; v_est_cov numeric; v_rows int;
begin
  select count(*) into v_rows
  from public.inventory_items
  where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and is_consumable and is_active and consumption_per_booking is not null;
  if v_rows = 0 then
    raise notice 'no active consumable with consumption_per_booking: forward check skipped (fresh database)';
    return;
  end if;

  select round(i.consumption_per_booking * t.rate, 4), round(i.qty_on_hand / (i.consumption_per_booking * t.rate), 1)
    into v_est_daily, v_est_cov
  from public.inventory_items i
  cross join lateral (
    select coalesce(count(*)::numeric / 60, 0) rate from public.cleaning_sessions
    where property_id = i.property_id and cleaning_type in ('turnover', 'deep_clean') and cleaned_at >= now() - interval '60 days'
  ) t
  where i.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and i.is_consumable and i.is_active and i.consumption_per_booking is not null
  limit 1;
  if v_est_daily is null or v_est_cov is null then
    raise exception 'estimated coverage calculation produced no result for a real consumable';
  end if;
end $$;

commit;
