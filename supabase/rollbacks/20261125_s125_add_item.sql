-- Rollback of s125_add_item_20261125: puts the four live bodies (read 2026-11-19) back and takes 'created' out of the change kinds.
-- 'created' change rows are deleted by design (the items they describe stay; they just lose their Undo). Roll the staff app back first.
-- Each restored body is checked against its original md5 (CR stripped). Grants are restated as they were before this release.
begin;

delete from public.inventory_item_changes where kind = 'created';
alter table public.inventory_item_changes drop constraint if exists inventory_item_changes_kind_check;
alter table public.inventory_item_changes add constraint inventory_item_changes_kind_check check (kind in ('details', 'price', 'photo'));

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
revoke all on function public.inventory_item_create_v1(uuid, jsonb, text, text, text) from public, anon, service_role;
grant execute on function public.inventory_item_create_v1(uuid, jsonb, text, text, text) to authenticated;

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
    perform public.admin_require('read_operations', c.property_id);
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
    if (case when c.before ? 'active' then (c.before ->> 'active')::boolean else i.is_active end)
       and exists (select 1 from public.inventory_items x where x.property_id = i.property_id and x.is_active and x.id <> i.id
                   and lower(btrim(x.name)) = lower(btrim(coalesce(c.before ->> 'name', i.name)))) then
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

create or replace function public.inventory_option_request_v1(p_item_id uuid, p_action text, p_option_id uuid, p_payload jsonb, p_note text, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_prop uuid; v_mgr boolean; v_fin boolean; v_payload jsonb; v_id uuid; v_old public.inventory_option_requests%rowtype;
  o public.inventory_item_options%rowtype; v_res uuid;
begin
  select i.property_id into v_prop from public.inventory_items i where i.id = p_item_id;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('read_operations', v_prop);
  if p_action is null or p_action <> all (array['add', 'edit', 'delete']) then raise exception using errcode = '22023', message = 'action must be add, edit or delete'; end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key must be 16 to 160 characters'; end if;
  if p_note is not null and char_length(p_note) > 500 then raise exception using errcode = '22023', message = 'note must be at most 500 characters'; end if;

  select * into v_old from public.inventory_option_requests r where r.requested_by = v_uid and r.idempotency_key = p_idempotency_key;
  if found then
    if v_old.item_id <> p_item_id then raise exception using errcode = '22023', message = 'idempotency key already used for another item'; end if;
    return jsonb_build_object('ok', true, 'applied', v_old.status = 'approved', 'request_id', v_old.id, 'option_id', coalesce(v_old.result_option_id, v_old.option_id), 'replay', true);
  end if;

  perform 1 from public.inventory_items i where i.id = p_item_id for update;
  v_mgr := public.current_staff_authorized('manage_inventory', v_prop);
  v_fin := v_mgr or public.finance_human_authorized(v_prop);
  v_payload := case when p_action = 'delete' then '{}'::jsonb else public.s_inventory_option_payload_v1(v_prop, p_payload, v_fin) end;

  if p_action = 'add' then
    if not (v_payload ? 'title') then raise exception using errcode = '22023', message = 'title is required'; end if;
    if not (v_payload ? 'supplier_id') then raise exception using errcode = '22023', message = 'supplier is required'; end if;
  else
    select * into o from public.inventory_item_options x where x.id = p_option_id and x.item_id = p_item_id;
    if not found then raise exception using errcode = '22023', message = 'option must belong to the item'; end if;
    if p_action = 'delete' and o.is_usual then raise exception using errcode = '22023', message = 'usual_option'; end if;
    if p_action = 'edit' and v_payload = '{}'::jsonb then raise exception using errcode = '22023', message = 'nothing to change'; end if;
  end if;

  insert into public.inventory_option_requests(property_id, item_id, option_id, option_title, action, payload, note, idempotency_key, requested_by)
  values (v_prop, p_item_id, case when p_action = 'add' then null else p_option_id end, case when p_action = 'add' then v_payload ->> 'title' else o.title end,
          p_action, v_payload, nullif(btrim(p_note), ''), p_idempotency_key, v_uid)
  on conflict (requested_by, idempotency_key) do nothing returning id into v_id;
  if v_id is null then
    select * into v_old from public.inventory_option_requests r where r.requested_by = v_uid and r.idempotency_key = p_idempotency_key;
    return jsonb_build_object('ok', true, 'applied', v_old.status = 'approved', 'request_id', v_old.id, 'option_id', coalesce(v_old.result_option_id, v_old.option_id), 'replay', true);
  end if;

  if v_mgr then
    v_res := public.s_inventory_option_apply_v1(p_item_id, v_prop, p_action, p_option_id, v_payload, v_uid);
    update public.inventory_option_requests set status = 'approved', decided_by = v_uid, decided_at = now(), result_option_id = v_res where id = v_id;
    return jsonb_build_object('ok', true, 'applied', true, 'option_id', v_res, 'request_id', v_id);
  end if;
  perform public.s_inventory_option_request_task_v1(v_prop, p_item_id);
  return jsonb_build_object('ok', true, 'applied', false, 'request_id', v_id);
end;
$$;
revoke all on function public.inventory_option_request_v1(uuid, text, uuid, jsonb, text, text) from public, anon, service_role;
grant execute on function public.inventory_option_request_v1(uuid, text, uuid, jsonb, text, text) to authenticated;

do $g$
declare r record; v text;
begin
  for r in select * from (values
    ('public.inventory_item_create_v1(uuid,jsonb,text,text,text)'::text, '30170851aad1418e0ec7b104ba6842d3'::text),
    ('public.inventory_item_change_undo_v1(uuid)', 'ad1665a60b979918ecb0260e1227137a'),
    ('public.get_inventory_catalogue_v1(uuid)', '2b07eed9209ccb4fe09836e30bf52999'),
    ('public.inventory_option_request_v1(uuid,text,uuid,jsonb,text,text)', '5c0fdd0dd45e331ae643300805226a86')
  ) as t(fn, orig) loop
    select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = r.fn::regprocedure;
    if v is distinct from r.orig then
      raise exception using errcode = '55000', message = 's125 rollback: ' || r.fn || ' is not the original body (md5 ' || coalesce(v, 'null') || ')';
    end if;
  end loop;
end $g$;

commit;
