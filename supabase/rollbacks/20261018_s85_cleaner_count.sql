-- Rollback for release s85_cleaner_count_20261018. Compensating: puts reconcile_inventory_baseline_v1 and inventory_undo_v1 back to the live bodies this release
-- was cut from (owner/admin only) and drops s_inventory_staff_movement_v1. Movements a cleaner wrote stay (the ledger is append-only).
-- Apply with run-sql-on-host.sh.

begin;

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
revoke all on function public.inventory_undo_v1(uuid, uuid) from public, anon, service_role;
grant execute on function public.inventory_undo_v1(uuid, uuid) to authenticated;

drop function if exists public.s_inventory_staff_movement_v1(uuid, text, numeric, text, text);

commit;
