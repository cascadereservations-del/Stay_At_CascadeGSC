-- Rollback of release s132_inventory_update_20261202 (D-396). Run it only when no client calls the new functions any more.
--   * replaced functions go back to their exact previous bodies (the in-place ones by putting the anchor back and pinning the md5, the re-cut ones from the stored bodies); every step is guarded by md5 (55000, nothing changes);
--   * (round 3) inventory_qty_at_v1 and get_usage_medians go back to their previous bodies (section 4b, md5 pinned);
--   * the new functions, the inventory_damage_reports table, the usage trigger and the new columns are dropped; usage rows that were undone (tombstones) are removed, as the first version of the undo did. Stock changes the new functions already made STAY (undo them in the app first if they should go);
--     reports, notes and photo paths kept in the dropped table and columns are lost.
-- The previous bodies were derived from the migrations (s85, s86, s91, s110, s120, s124); the guard md5s in the s132 migration say which is which.

begin;

-- 1. guard: refuse to roll back over a body that is neither this release nor the previous one
do $g$
declare v text; r record;
begin
  for r in select * from (values
    ('public.s_inventory_staff_movement_v1(uuid,text,numeric,text,text)', '61b51c8b14d81d167dffd74c14dfe6e0', 'b56d8bce61c205b3265ff99b8336bf35'),
    ('public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)', '18bea3e74b205dc7526a9614b83521cc', 'fdeaf212bebc578ee82f9240e6c05417'),
    ('public.inventory_undo_v1(uuid,uuid)', 'b1c19525aa43a0a529c511932d97a2fa', '5125463a4d686d5a180f1ee599fa00b7'),
    ('public.inventory_item_update_v1(uuid,jsonb)', 'c6ec09668ba7416ababeebe6a225b9d0', '618e3ec14138f9ce05c4c3dc1b1fe7fa'),
    ('public.get_inventory_catalogue_v1(uuid)', '6832ffc21ce22a01f591cbcf03f42497', '2ed1f4a50454e4072409d98ed0eea53c'),
    ('public.get_inventory_item_moves_v1(uuid)', '84eaa4f00f2e7fcdb2e92a2b13b48f26', '865a052a81b49407dcf1b4e5f8f91f4e'),
    ('public.inventory_item_history_v1(uuid)', 'a8669ba0b6ff6654edf352e9b8d98543', 'bbf90cfbd5f97158307e12502ae1223e'),
    ('public.inventory_item_change_undo_v1(uuid)', '86d7879703760fdc90e6b455e33bdacd', 'f513d523af5ef4f99055ca73e789b7ce'),
    ('public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid,text)', null, 'd190f6b6051be034e9e9babb99cbbf56'),
    ('public.inventory_receipt_manual_v1(jsonb,date,text,text,numeric,text,text)', null, '8c407320edbbc9d944a86461bef23adf'),
    ('public.record_linen_stains_v1(uuid,date,text,text,jsonb,text)', null, 'e4cfcd996dda6d2cd7a3239cf574ab9e'),
    ('public.inventory_qty_at_v1(uuid,timestamptz)', '75e63656262684e72e8e02bdf6179818', '14b0a49112a97cbc3ca8318461af2078'),
    ('public.get_usage_medians()', '30168efbcee85ff9cccd6ab8f76d5a7d', 'eb605dd66ebd70bb83061e2f38795132')
  ) t(sig, m_old, m_new) loop
    select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure(r.sig);
    if v is distinct from r.m_old and v is distinct from r.m_new then
      raise exception using errcode = '55000', message = 's132 rollback: ' || r.sig || ' is neither this release nor the previous body (md5 ' || coalesce(v, 'null') || ')';
    end if;
  end loop;
end $g$;

-- 2. the in-place patches (three gate lines, the update default, the usage reads of the catalogue and the item moves) go back to the previous bodies (read from the live body, the anchor put back, the result pinned)
-- s_inventory_staff_movement_v1
do $g$
declare v_src text; v_old text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.s_inventory_staff_movement_v1(uuid,text,numeric,text,text)');
  if md5(v_src) = '61b51c8b14d81d167dffd74c14dfe6e0' then raise notice 's132 rollback: s_inventory_staff_movement_v1 is already the previous body'; return; end if;
  if md5(v_src) <> 'b56d8bce61c205b3265ff99b8336bf35' then raise exception 's132 rollback: s_inventory_staff_movement_v1 is not this release (md5 %)', md5(v_src) using errcode = '55000'; end if;
  v_old := replace(v_src, replace($r$if not found or not (public.current_staff_authorized('submit_cleaning', i.property_id) or public.current_staff_authorized('report_supply', i.property_id)) then$r$, chr(13), ''), replace($f$if not found or not public.current_staff_authorized('submit_cleaning', i.property_id) then$f$, chr(13), ''));
  if md5(v_old) <> '61b51c8b14d81d167dffd74c14dfe6e0' then raise exception 's132 rollback: s_inventory_staff_movement_v1 did not return to the previous body (md5 %)', md5(v_old) using errcode = '55000'; end if;
  execute format($e$create or replace function public.s_inventory_staff_movement_v1(p_item_id uuid, p_kind text, p_quantity numeric, p_reason text, p_idempotency_key text)
    returns uuid language plpgsql security definer set search_path = '' as %L$e$, v_old);
end $g$;
-- reconcile_inventory_baseline_v1
do $g$
declare v_src text; v_old text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)');
  if md5(v_src) = '18bea3e74b205dc7526a9614b83521cc' then raise notice 's132 rollback: reconcile_inventory_baseline_v1 is already the previous body'; return; end if;
  if md5(v_src) <> 'fdeaf212bebc578ee82f9240e6c05417' then raise exception 's132 rollback: reconcile_inventory_baseline_v1 is not this release (md5 %)', md5(v_src) using errcode = '55000'; end if;
  v_old := replace(v_src, replace($r$if not public.current_staff_authorized('submit_cleaning', i.property_id) then perform public.admin_require('report_supply', i.property_id); end if;$r$, chr(13), ''), replace($f$perform public.admin_require('submit_cleaning', i.property_id);$f$, chr(13), ''));
  if md5(v_old) <> '18bea3e74b205dc7526a9614b83521cc' then raise exception 's132 rollback: reconcile_inventory_baseline_v1 did not return to the previous body (md5 %)', md5(v_old) using errcode = '55000'; end if;
  execute format($e$create or replace function public.reconcile_inventory_baseline_v1(p_item_id uuid, p_counted_qty numeric, p_note text, p_idempotency_key text)
    returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_old);
end $g$;
-- inventory_undo_v1
do $g$
declare v_src text; v_old text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.inventory_undo_v1(uuid,uuid)');
  if md5(v_src) = 'b1c19525aa43a0a529c511932d97a2fa' then raise notice 's132 rollback: inventory_undo_v1 is already the previous body'; return; end if;
  if md5(v_src) <> '5125463a4d686d5a180f1ee599fa00b7' then raise exception 's132 rollback: inventory_undo_v1 is not this release (md5 %)', md5(v_src) using errcode = '55000'; end if;
  v_old := replace(v_src, replace($r$if not public.current_staff_authorized('submit_cleaning', i.property_id) then perform public.admin_require('report_supply', i.property_id); end if;$r$, chr(13), ''), replace($f$perform public.admin_require('submit_cleaning', i.property_id);$f$, chr(13), ''));
  if md5(v_old) <> 'b1c19525aa43a0a529c511932d97a2fa' then raise exception 's132 rollback: inventory_undo_v1 did not return to the previous body (md5 %)', md5(v_old) using errcode = '55000'; end if;
  execute format($e$create or replace function public.inventory_undo_v1(p_movement_id uuid default null, p_purchase_id uuid default null)
    returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_old);
end $g$;
-- inventory_item_update_v1
do $g$
declare v_src text; v_old text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.inventory_item_update_v1(uuid,jsonb)');
  if md5(v_src) = 'c6ec09668ba7416ababeebe6a225b9d0' then raise notice 's132 rollback: inventory_item_update_v1 is already the previous body'; return; end if;
  if md5(v_src) <> '618e3ec14138f9ce05c4c3dc1b1fe7fa' then raise exception 's132 rollback: inventory_item_update_v1 is not this release (md5 %)', md5(v_src) using errcode = '55000'; end if;
  v_old := replace(v_src, replace($r$    i.is_consumable := (p_patch->>'consumable')::boolean;
  elsif p_patch ? 'category' and v_mgr and lower(btrim(i.category)) in ('kitchen utensils', 'appliances') then
    -- s132: a move into a lasting group (no consumable sent) makes the item lasting; only for manage_inventory (a cleaner's edit never flips is_consumable, not even through the category)
    i.is_consumable := false;
  end if;$r$, chr(13), ''), replace($f$    i.is_consumable := (p_patch->>'consumable')::boolean;
  end if;$f$, chr(13), ''));
  if md5(v_old) <> 'c6ec09668ba7416ababeebe6a225b9d0' then raise exception 's132 rollback: inventory_item_update_v1 did not return to the previous body (md5 %)', md5(v_old) using errcode = '55000'; end if;
  execute format($e$create or replace function public.inventory_item_update_v1(p_item_id uuid, p_patch jsonb)
    returns jsonb language plpgsql volatile security definer set search_path = '' as %L$e$, v_old);
end $g$;
-- get_inventory_catalogue_v1
do $g$
declare v_src text; v_old text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.get_inventory_catalogue_v1(uuid)');
  if md5(v_src) = '6832ffc21ce22a01f591cbcf03f42497' then raise notice 's132 rollback: get_inventory_catalogue_v1 is already the previous body'; return; end if;
  if md5(v_src) <> '2ed1f4a50454e4072409d98ed0eea53c' then raise exception 's132 rollback: get_inventory_catalogue_v1 is not this release (md5 %)', md5(v_src) using errcode = '55000'; end if;
  v_old := replace(v_src, replace($r$from public.inventory_usage x where x.item_id = i.id and x.undone_at is null and x.session_date >= public.manila_today() - 30$r$, chr(13), ''), replace($f$from public.inventory_usage x where x.item_id = i.id and x.session_date >= public.manila_today() - 30$f$, chr(13), ''));
  if md5(v_old) <> '6832ffc21ce22a01f591cbcf03f42497' then raise exception 's132 rollback: get_inventory_catalogue_v1 did not return to the previous body (md5 %)', md5(v_old) using errcode = '55000'; end if;
  execute format($e$create or replace function public.get_inventory_catalogue_v1(p_property_id uuid)
    returns jsonb language plpgsql stable security definer set search_path = '' as %L$e$, v_old);
end $g$;
-- get_inventory_item_moves_v1
do $g$
declare v_src text; v_old text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.get_inventory_item_moves_v1(uuid)');
  if md5(v_src) = '84eaa4f00f2e7fcdb2e92a2b13b48f26' then raise notice 's132 rollback: get_inventory_item_moves_v1 is already the previous body'; return; end if;
  if md5(v_src) <> '865a052a81b49407dcf1b4e5f8f91f4e' then raise exception 's132 rollback: get_inventory_item_moves_v1 is not this release (md5 %)', md5(v_src) using errcode = '55000'; end if;
  v_old := replace(v_src, replace($r$from public.inventory_usage u where u.item_id = i.id and u.undone_at is null and u.session_date >= v_today - 30$r$, chr(13), ''), replace($f$from public.inventory_usage u where u.item_id = i.id and u.session_date >= v_today - 30$f$, chr(13), ''));
  if md5(v_old) <> '84eaa4f00f2e7fcdb2e92a2b13b48f26' then raise exception 's132 rollback: get_inventory_item_moves_v1 did not return to the previous body (md5 %)', md5(v_old) using errcode = '55000'; end if;
  execute format($e$create or replace function public.get_inventory_item_moves_v1(p_item_id uuid)
    returns jsonb language plpgsql stable security definer set search_path = '' as %L$e$, v_old);
end $g$;

-- inventory_item_change_undo_v1 (round 2): the usage test of a created item goes back to counting an undone usage row
do $g$
declare v_src text; v_old text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.inventory_item_change_undo_v1(uuid)');
  if md5(v_src) = '86d7879703760fdc90e6b455e33bdacd' then raise notice 's132 rollback: inventory_item_change_undo_v1 is already the previous body'; return; end if;
  if md5(v_src) <> 'f513d523af5ef4f99055ca73e789b7ce' then raise exception 's132 rollback: inventory_item_change_undo_v1 is not this release (md5 %)', md5(v_src) using errcode = '55000'; end if;
  v_old := replace(v_src, replace($r$exists (select 1 from public.inventory_usage u where u.item_id = i.id and u.undone_at is null and u.created_at > c.created_at)$r$, chr(13), ''), replace($f$exists (select 1 from public.inventory_usage u where u.item_id = i.id and u.created_at > c.created_at)$f$, chr(13), ''));
  if md5(v_old) <> '86d7879703760fdc90e6b455e33bdacd' then raise exception 's132 rollback: inventory_item_change_undo_v1 did not return to the previous body (md5 %)', md5(v_old) using errcode = '55000'; end if;
  execute format($e$create or replace function public.inventory_item_change_undo_v1(p_change_id uuid)
    returns jsonb language plpgsql volatile security definer set search_path = '' as %L$e$, v_old);
end $g$;
revoke all on function public.inventory_item_change_undo_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.inventory_item_change_undo_v1(uuid) to authenticated;

-- 3. the history goes back to the s124 body
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
$$;
revoke all on function public.inventory_item_history_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.inventory_item_history_v1(uuid) to authenticated;

-- 4. the three functions that gained arguments: the previous signature comes back with its exact previous body, the new one is dropped
drop function if exists public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid, text);
create or replace function public.record_inventory_receipt_v1(p_item_id uuid, p_packs numeric, p_unit_cost numeric, p_supplier text, p_purchased_at date, p_receipt_path text, p_shopping_list_id uuid, p_idempotency_key text, p_supplier_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $body$
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
  values (p_item_id, coalesce(p_purchased_at, current_date), v_units, case when p_unit_cost is not null then round(p_unit_cost / coalesce(nullif(i.units_per_purchase, 0), 1), 4) end, coalesce(v_sname, p_supplier), v_sid, 'Admin receipt [key:' || p_idempotency_key || ']', p_receipt_path, i.purchase_unit, coalesce(i.units_per_purchase, 1))
  returning id into v_pid;
  if i.movement_controlled_at is not null then
    v_mid := public.inventory_apply_event_v1(p_item_id, 'receipt', v_units, 'Receipt of ' || p_packs::text || ' ' || coalesce(i.purchase_unit, 'pack') || coalesce(' from ' || coalesce(v_sname, p_supplier), ''), 'inventory_purchases', v_pid::text);
  else
    update public.inventory_items set qty_on_hand = coalesce(qty_on_hand, 0) + v_units, unit_cost = coalesce(case when p_unit_cost is not null then round(p_unit_cost / coalesce(nullif(units_per_purchase, 0), 1), 4) end, unit_cost) where id = p_item_id;
  end if;
  if p_shopping_list_id is not null then
    update public.inventory_shopping_list set status = 'received', received_by = auth.uid(), received_at = now(), received_quantity = v_units, unit_cost = p_unit_cost, supplier = coalesce(v_sname, p_supplier), supplier_id = v_sid, movement_id = v_mid, purchase_id = v_pid, version = version + 1, updated_at = now()
    where id = p_shopping_list_id and property_id = i.property_id and status = 'approved';
  end if;
  -- S120: remember the refill for the usage learning; a problem here must never block a receipt
  begin
    perform public.record_inventory_anchor_v1(p_item_id, v_units, (coalesce(p_purchased_at, public.manila_today())::timestamp at time zone 'Asia/Manila'), 'receipt');
  exception when others then
    raise warning 's120 usage anchor (receipt): % (%)', sqlerrm, sqlstate;
  end;
  return jsonb_build_object('ok', true, 'purchaseId', v_pid, 'movementId', v_mid, 'unitsAdded', v_units, 'controlled', i.movement_controlled_at is not null);
end;
$body$;
revoke all on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid) from public, anon, service_role;
grant execute on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid) to authenticated;

drop function if exists public.inventory_receipt_manual_v1(jsonb, date, text, text, numeric, text, text);
create or replace function public.inventory_receipt_manual_v1(p_lines jsonb, p_purchased_on date default null, p_vendor text default null, p_idempotency_key text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_prop uuid; v_id uuid; v_lines jsonb; v_conv jsonb; v_res jsonb; v_vendor text := nullif(btrim(coalesce(p_vendor, '')), ''); v_old public.inventory_receipt_drafts%rowtype;
begin
  if v_uid is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  select x.id into v_prop from public.properties x where public.current_staff_authorized('report_supply', x.id)
   order by exists (select 1 from public.staff_property_access a where a.user_id = v_uid and a.property_id = x.id) desc, (x.id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid) desc, x.id limit 1;
  if v_prop is null then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  if p_idempotency_key is not null and char_length(p_idempotency_key) not between 16 and 160 then
    raise exception using errcode = '22023', message = 'idempotency key must be 16 to 160 characters';
  end if;
  if v_vendor is not null and char_length(v_vendor) > 200 then raise exception using errcode = '22023', message = 'vendor is too long'; end if;
  if p_idempotency_key is not null then
    perform pg_advisory_xact_lock(hashtextextended('s110-manual:' || v_uid::text || ':' || p_idempotency_key, 0));
    select * into v_old from public.inventory_receipt_drafts d where d.created_by = v_uid and d.confirm_key = p_idempotency_key and d.status = 'confirmed' limit 1;
    if found then return v_old.confirm_result || jsonb_build_object('replayed', true, 'draft_id', v_old.id); end if;
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) not between 1 and 100
     or exists (select 1 from jsonb_array_elements(p_lines) c where jsonb_typeof(c) <> 'object') then
    return jsonb_build_object('ok', false, 'error', 'bad_line', 'line_no', null);
  end if;
  select jsonb_agg(e.value || jsonb_build_object('line_no', e.ord) order by e.ord) into v_conv from jsonb_array_elements(p_lines) with ordinality e(value, ord);
  select jsonb_agg(jsonb_build_object('line_no', (c.value ->> 'line_no')::integer,
                   'description', left(coalesce(c.value -> 'new_item' ->> 'name', (select i.name from public.inventory_items i where i.id::text = c.value ->> 'item_id'), 'Supply'), 200),
                   'qty', c.value -> 'qty_units', 'unit_cost', null, 'match_item_id', null, 'match_score', 0) order by (c.value ->> 'line_no')::integer)
    into v_lines from jsonb_array_elements(v_conv) c;
  insert into public.inventory_receipt_drafts(property_id, created_by, receipt_path, vendor, purchased_on, total, lines, status)
  values (v_prop, v_uid, null, v_vendor, p_purchased_on, null, v_lines, 'draft') returning id into v_id;
  v_res := public.s_inventory_receipt_confirm_core_v1(v_id, v_conv, p_purchased_on, p_idempotency_key, true);
  if coalesce((v_res ->> 'ok')::boolean, false) is not true then
    update public.inventory_receipt_drafts set status = 'cancelled' where id = v_id;
  end if;
  return v_res;
end;
$$;
revoke all on function public.inventory_receipt_manual_v1(jsonb, date, text, text) from public, anon, authenticated, service_role;
grant execute on function public.inventory_receipt_manual_v1(jsonb, date, text, text) to authenticated;

drop function if exists public.record_linen_stains_v1(uuid, date, text, text, jsonb, text);
create or replace function public.record_linen_stains_v1(p_property uuid, p_session_date date, p_logged_by text, p_idempotency_key text, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_today date := public.manila_today(); v_who text; v_row jsonb; v_no integer := 0;
  v_item uuid; v_qty numeric; v_out text; v_name text; v_ctl boolean; v_before numeric; v_after numeric; v_last numeric;
  v_rid uuid; v_move uuid; v_moves jsonb := '[]'::jsonb; v_tasks jsonb := '[]'::jsonb;
  v_prev public.linen_stain_reports%rowtype; v_tid uuid; v_gen integer; v_total integer; v_title text; v_hash text;
begin
  if v_uid is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if p_property is null or not public.current_staff_authorized('submit_cleaning', p_property) then
    raise exception using errcode = '42501', message = 'staff access denied';
  end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then
    raise exception using errcode = '22023', message = 'idempotency key must be 16 to 160 characters';
  end if;
  if p_session_date is null or p_session_date > v_today + 1 or p_session_date < v_today - 30 then
    raise exception using errcode = '22023', message = 'session date out of range';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) not between 1 and 30 then
    raise exception using errcode = '22023', message = 'rows required (1 to 30)';
  end if;
  v_who := left(nullif(btrim(coalesce(p_logged_by, '')), ''), 80);
  -- what was sent, as a fingerprint: item, outcome and quantity per row, sorted, so the same rows in another order are the same send. A malformed row still hashes
  -- (the row loop below refuses it with its own message), so this never fails before the checks do.
  select encode(extensions.digest(coalesce(string_agg(x.k, ',' order by x.k), ''), 'sha256'), 'hex') into v_hash
    from (select lower(coalesce(e.value ->> 'item_id', '')) || ':' || coalesce(e.value ->> 'outcome', '') || ':'
                 || case when jsonb_typeof(e.value -> 'qty') = 'number' then trim_scale((e.value ->> 'qty')::numeric)::text else coalesce(e.value ->> 'qty', '') end as k
            from jsonb_array_elements(p_rows) e) x;

  -- two taps or a retry racing the first call wait here: the second one then sees the first one's rows and replays. Held to the end of the transaction, so the
  -- unique (idempotency_key, row_no) can no longer be hit by a replay (a hash clash between two keys only makes them wait for each other).
  perform pg_advisory_xact_lock(hashtextextended('linen_stains|' || p_idempotency_key, 0));

  -- the same submission sent again (a retry after a lost answer) writes nothing
  select * into v_prev from public.linen_stain_reports where idempotency_key = p_idempotency_key order by row_no limit 1;
  if found then
    if v_prev.reported_by_user_id is distinct from v_uid or v_prev.property_id <> p_property or v_prev.rows_hash is distinct from v_hash then
      raise exception using errcode = '22023', message = 'idempotency_key_reused';
    end if;
    return jsonb_build_object('ok', true, 'replayed', true,
      'rows', (select count(*) from public.linen_stain_reports where idempotency_key = p_idempotency_key));
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_no := v_no + 1;
    v_out := v_row ->> 'outcome';
    if jsonb_typeof(v_row -> 'item_id') is distinct from 'string' or jsonb_typeof(v_row -> 'qty') is distinct from 'number'
       or v_out is null or v_out not in ('cleaned', 'needs_replacing', 'replaced') then
      raise exception using errcode = '22023', message = 'each row needs item_id, a whole qty and an outcome';
    end if;
    v_item := (v_row ->> 'item_id')::uuid;
    v_qty := (v_row ->> 'qty')::numeric;
    if v_qty <> floor(v_qty) or v_qty < 1 or v_qty > 99 then
      raise exception using errcode = '22023', message = 'qty must be a whole number from 1 to 99';
    end if;

    select i.name, (i.movement_controlled_at is not null), coalesce(i.qty_on_hand, 0) into v_name, v_ctl, v_before
      from public.inventory_items i
     where i.id = v_item and i.property_id = p_property and i.is_active and not i.is_consumable for update;
    if v_name is null then raise exception using errcode = '22023', message = 'unknown linen item'; end if;

    v_after := case when v_out = 'cleaned' then v_before else greatest(0, v_before - v_qty) end;
    v_move := null;
    if v_ctl and v_after <> v_before then
      select m.quantity_after into v_last from public.inventory_stock_movements m where m.item_id = v_item order by m.sequence_no desc limit 1;
      if v_last is distinct from v_before then raise exception using errcode = '22023', message = 'stock reconciliation required for ' || v_name; end if;
    end if;

    insert into public.linen_stain_reports(property_id, item_id, session_date, qty, outcome, logged_by, reported_by_user_id, idempotency_key, row_no, stock_before, stock_after, rows_hash)
    values (p_property, v_item, p_session_date, v_qty::integer, v_out, v_who, v_uid, p_idempotency_key, v_no, v_before, v_after, v_hash)
    returning id into v_rid;

    if v_after <> v_before then
      update public.inventory_items set qty_on_hand = v_after where id = v_item;
      -- inventory_qty_at_v1 rebuilds past stock from these rows, so a back-dated count stays right.
      insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor)
      values ('inventory_items', v_item, 'linen_stain', jsonb_build_object('qty_on_hand', v_before), jsonb_build_object('qty_on_hand', v_after), coalesce(v_who, v_uid::text, 'staff'));
      if v_ctl then
        insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key)
        values (v_item, p_property, 'adjustment', v_before, v_after,
                'Linen ' || replace(v_out, '_', ' ') || ' ' || p_session_date::text || coalesce(' by ' || v_who, ''), v_uid,
                left('evt-' || encode(extensions.digest('linen_stain_reports|' || v_rid::text || '|' || v_item::text || '|adjustment', 'sha256'), 'hex'), 80))
        returning id into v_move;
        update public.linen_stain_reports set movement_id = v_move where id = v_rid;
        v_moves := v_moves || to_jsonb(v_move);
      end if;
    end if;

    if v_out = 'needs_replacing' then
      -- one open task per item: add to it, or open generation n+1 when the last one was closed
      select t.id into v_tid from public.follow_up_tasks t
       where t.source_kind = 'linen_replace' and t.property_id = p_property and t.source_ref like v_item::text || ':%' and t.status in ('open', 'in_progress')
       order by t.created_at desc limit 1;
      if v_tid is null then
        select count(*) + 1 into v_gen from public.follow_up_tasks t where t.source_kind = 'linen_replace' and t.source_ref like v_item::text || ':%';
        v_tid := public.system_task_open_v1(p_property, 'linen_replace', v_item::text || ':' || v_gen::text, 'Replace linen', null, 'normal');
      end if;
      update public.linen_stain_reports set task_id = v_tid where id = v_rid;
      select coalesce(sum(r.qty), 0)::integer into v_total from public.linen_stain_reports r where r.task_id = v_tid;
      v_title := 'Replace ' || case when v_total = 1 then '1 ' else v_total::text || ' x ' end || v_name || ', stained on ' || to_char(p_session_date, 'FMDD Mon');
      update public.follow_up_tasks t
         set title = left(v_title, 200), detail = 'Reported in the cleaning checklist. Buy or replace it, then mark this task done.', updated_at = now()
       where t.id = v_tid;
      if not v_tasks @> to_jsonb(v_tid) then v_tasks := v_tasks || to_jsonb(v_tid); end if;
    end if;
    v_tid := null;
  end loop;

  return jsonb_build_object('ok', true, 'replayed', false, 'rows', v_no, 'tasks', v_tasks, 'movements', v_moves);
end;
$$;
revoke all on function public.record_linen_stains_v1(uuid, date, text, text, jsonb) from public, anon, service_role;
grant execute on function public.record_linen_stains_v1(uuid, date, text, text, jsonb) to authenticated;
comment on function public.record_linen_stains_v1(uuid, date, text, text, jsonb) is
  'S120 (D-374): the checklist linen check. cleaned = audit row; needs_replacing / replaced = stock down (clamp 0, ledger adjustment for a controlled item); needs_replacing also adds to ONE open linen_replace task per item. Key replays write nothing. Needs submit_cleaning.';

-- 4b. inventory_qty_at_v1 (s99f body) and get_usage_medians (schemas/000 body) go back to their exact previous bodies, each pinned by md5 after the restore
create or replace function public.inventory_qty_at_v1(p_item_id uuid, p_at timestamptz)
returns numeric language plpgsql stable security definer set search_path = '' as $$
declare
  it public.inventory_items%rowtype;
  v_first numeric;
begin
  select * into it from public.inventory_items where id = p_item_id;
  if not found then return null; end if;
  if p_at is null then return it.qty_on_hand; end if;

  if it.movement_controlled_at is not null then
    select m.quantity_before into v_first from public.inventory_stock_movements m
     where m.item_id = it.id and m.created_at > p_at order by m.sequence_no limit 1;
    return coalesce(v_first, it.qty_on_hand);
  end if;

  return it.qty_on_hand
    + coalesce((select sum(u.used_qty) from public.inventory_usage u where u.item_id = it.id and u.created_at > p_at), 0)
    - coalesce((select sum(p.qty) from public.inventory_purchases p
                 where p.item_id = it.id and p.created_at > p_at and coalesce(p.notes, '') not like 'Auto-restock from receipt OCR%'), 0)
    - coalesce((select sum((a.after ->> 'qty_added')::numeric) from public.inventory_audit_log a
                 where a.entity_type = 'inventory_items' and a.entity_id = it.id and a.action = 'ocr_restock' and a.created_at > p_at
                   and exists (select 1 from public.inventory_purchases p where p.id::text = a.after ->> 'purchase_id')), 0)
    - coalesce((select sum((a.after ->> 'qty_on_hand')::numeric - (a.before ->> 'qty_on_hand')::numeric) from public.inventory_audit_log a
                 where a.entity_type = 'inventory_items' and a.entity_id = it.id and a.action <> 'ocr_restock' and a.created_at > p_at
                   and jsonb_typeof(a.before -> 'qty_on_hand') = 'number' and jsonb_typeof(a.after -> 'qty_on_hand') = 'number'), 0);
end $$;
comment on function public.inventory_qty_at_v1(uuid, timestamptz) is
  'S99f (D-351): what was on hand for an item at a past time. Not controlled: qty_now + usage after T - purchases after T - counts and other audited changes after T. Controlled: quantity_before of the first movement after T. Null time = now.';
revoke all on function public.inventory_qty_at_v1(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.inventory_qty_at_v1(uuid, timestamptz) to service_role;
create or replace function public.get_usage_medians() returns table(item_id uuid, median_used numeric)
language sql security definer set search_path to 'public' as $$
  select item_id,
         percentile_cont(0.5) within group (order by used_qty)::numeric(10,2)
  from inventory_usage
  where session_date >= current_date - interval '90 days'
  group by item_id;
$$;
revoke all on function public.get_usage_medians() from public, anon;
grant execute on function public.get_usage_medians() to authenticated, service_role;
do $g$
begin
  if md5(replace((select p.prosrc from pg_proc p where p.oid = to_regprocedure('public.inventory_qty_at_v1(uuid,timestamptz)')), chr(13), '')) is distinct from '75e63656262684e72e8e02bdf6179818'
     or md5(replace((select p.prosrc from pg_proc p where p.oid = to_regprocedure('public.get_usage_medians()')), chr(13), '')) is distinct from '30168efbcee85ff9cccd6ab8f76d5a7d' then
    raise exception 's132 rollback: inventory_qty_at_v1 or get_usage_medians did not return to the previous body' using errcode = '55000';
  end if;
end $g$;

-- 5. the new objects go (the stock changes they made stay: undo what you need through the app first)
drop function if exists public.undo_linen_stain_v1(text);
drop function if exists public.undo_inventory_usage_v1(text);
drop function if exists public.undo_inventory_damage_v1(uuid);
drop function if exists public.record_inventory_damage_v1(uuid, jsonb, text, uuid, boolean, text, text, text);
drop function if exists public.s_inventory_purchase_note_v1(text);
drop table if exists public.inventory_damage_reports;
-- the usage tombstone: an undone usage row is what the first version of the undo deleted, so those rows go; then the trigger, its function and the three columns
-- F15: the usage_undo audit rows carry the real before/after since round 3; the restored s99f inventory_qty_at_v1 has no tombstone term, so once the
-- tombstones are deleted those deltas would count twice for a time before the use. Set before = after on them (the round-2 state the old body expects).
update public.inventory_audit_log set before = jsonb_set(before, '{qty_on_hand}', after -> 'qty_on_hand')
 where entity_type = 'inventory_items' and action = 'usage_undo' and jsonb_typeof(before -> 'qty_on_hand') = 'number' and jsonb_typeof(after -> 'qty_on_hand') = 'number';
delete from public.inventory_usage where undone_at is not null;
drop trigger if exists inventory_usage_removed_v1 on public.inventory_usage;
drop function if exists public.s_inventory_usage_removed_v1();
alter table public.inventory_usage drop column if exists removed_qty, drop column if exists undone_qty, drop column if exists undone_at;
alter table public.inventory_receipt_drafts drop column if exists note;
alter table public.linen_stain_reports drop column if exists undone_at, drop column if exists photo_path, drop column if exists note, drop column if exists reason;

commit;
