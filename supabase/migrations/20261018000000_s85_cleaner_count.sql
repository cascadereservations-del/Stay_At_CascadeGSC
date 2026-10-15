-- 20261018000000_s85_cleaner_count.sql
-- Session 85, lane count: release s85_cleaner_count_20261018. A cleaner (role cleaner, submit_cleaning) may set the remaining amount of an item and undo their own count.
-- Decision Lloyd 2026-10-15 (reverses the spec default). Cut from the LIVE bodies read 2026-10-15 (md5 of prosrc, CR stripped):
--   reconcile_inventory_baseline_v1  7cba4397244b2e666b57cd43fb3b31a9   inventory_undo_v1  f2a56a60c4f077871966e797ebd35a83
-- What changes: (1) both gates accept manage_inventory OR submit_cleaning on the item's property (same errcode 42501 on refusal; an undo by a cleaner is the
-- movement path only and still needs the movement to be the caller's own, within 15 minutes, still the latest change; a purchase undo still needs manage_inventory);
-- (2) record_inventory_movement itself refuses anyone but owner/admin (inventory_human_authorized), so for a non-owner/admin caller both functions write the
-- movement through the new internal s_inventory_staff_movement_v1 (reconcile and adjustment only, same invariants, no client grant). The owner/admin path is
-- what it was. Note required, non-negative, 2 decimals, idempotency and the movement ledger are unchanged. SECURITY DEFINER, search_path and grants unchanged.
-- Guard: both live bodies must be the ones cut from, else 55000 and nothing changes (single shot; to undo apply the rollback).
-- Rollback: supabase/rollbacks/20261018_s85_cleaner_count.sql

begin;

do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)');
  if v_got is distinct from '7cba4397244b2e666b57cd43fb3b31a9' then
    raise exception 's85 cleaner count: reconcile_inventory_baseline_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.inventory_undo_v1(uuid,uuid)');
  if v_got is distinct from 'f2a56a60c4f077871966e797ebd35a83' then
    raise exception 's85 cleaner count: inventory_undo_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
end $$;

-- Internal: the movement write for a signed-in cleaner. record_inventory_movement wants an owner/admin (inventory_human_authorized), so a cleaner's count
-- could never reach it. Same invariants, kinds limited to reconcile and adjustment. NOT executable by any client role: only the two definer functions
-- below call it, after their own gate (manage_inventory or submit_cleaning on the item's property).
create or replace function public.s_inventory_staff_movement_v1(p_item_id uuid, p_kind text, p_quantity numeric, p_reason text, p_idempotency_key text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare i public.inventory_items%rowtype; m public.inventory_stock_movements%rowtype; v_after numeric; v_id uuid;
begin
  select * into i from public.inventory_items where id = p_item_id for update;
  if not found or not public.current_staff_authorized('submit_cleaning', i.property_id) then raise exception using errcode = '42501', message = 'inventory access denied'; end if;
  if p_kind is null or p_kind not in ('reconcile', 'adjustment') or p_quantity is null
     or p_quantity <= -100000000 or p_quantity >= 100000000 or p_quantity <> round(p_quantity, 2)
     or p_reason is null or char_length(btrim(p_reason)) not between 3 and 2000
     or p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then
    raise exception using errcode = '22023', message = 'invalid stock movement';
  end if;
  select * into m from public.inventory_stock_movements where item_id = i.id and idempotency_key = p_idempotency_key;
  if found then
    if m.kind is distinct from p_kind or m.reason is distinct from btrim(p_reason) or m.actor_user_id is distinct from auth.uid()
       or (case when p_kind = 'reconcile' then m.quantity_after else m.quantity_after - m.quantity_before end) is distinct from p_quantity then
      raise exception using errcode = '22023', message = 'idempotency conflict';
    end if;
    return m.id;
  end if;
  if not coalesce(i.is_active, false) or i.qty_on_hand is null or i.qty_on_hand < 0 or i.qty_on_hand >= 100000000 then
    raise exception using errcode = '22023', message = 'invalid canonical stock';
  end if;
  select * into m from public.inventory_stock_movements where item_id = i.id order by sequence_no desc limit 1;
  if p_kind <> 'reconcile' and (not found or m.quantity_after is distinct from i.qty_on_hand or m.property_id is distinct from i.property_id) then
    raise exception using errcode = '22023', message = 'stock reconciliation required';
  end if;
  v_after := case when p_kind = 'reconcile' then p_quantity else i.qty_on_hand + p_quantity end;
  insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key)
  values (i.id, i.property_id, p_kind, i.qty_on_hand, v_after, btrim(p_reason), auth.uid(), p_idempotency_key) returning id into v_id;
  update public.inventory_items set qty_on_hand = v_after where id = i.id;
  return v_id;
end;
$$;
revoke all on function public.s_inventory_staff_movement_v1(uuid, text, numeric, text, text) from public, anon, authenticated, service_role;

create or replace function public.reconcile_inventory_baseline_v1(p_item_id uuid, p_counted_qty numeric, p_note text, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i public.inventory_items%rowtype; v_before numeric; v_mid uuid;
begin
  select * into i from public.inventory_items where id = p_item_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  -- s85: a cleaner (submit_cleaning) may count too; owner/admin (manage_inventory) as before; anyone else is refused 42501
  if not public.current_staff_authorized('manage_inventory', i.property_id) then
    perform public.admin_require('submit_cleaning', i.property_id);
  end if;
  if p_counted_qty is null or p_counted_qty < 0 or p_counted_qty <> round(p_counted_qty, 2) then raise exception using errcode = '22023', message = 'counted quantity must be a non-negative number with at most 2 decimals'; end if;
  if p_note is null or char_length(btrim(p_note)) < 3 then raise exception using errcode = '22023', message = 'a count note is required'; end if;
  v_before := i.qty_on_hand;
  if public.inventory_human_authorized(i.property_id) then
    v_mid := public.record_inventory_movement(p_item_id, 'reconcile', p_counted_qty, 'Baseline count: ' || btrim(p_note), p_idempotency_key);
  else
    v_mid := public.s_inventory_staff_movement_v1(p_item_id, 'reconcile', p_counted_qty, 'Baseline count: ' || btrim(p_note), p_idempotency_key);
  end if;
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
    if m.kind not in ('reconcile', 'receipt') then return jsonb_build_object('ok', false, 'reason', 'not_undoable'); end if;
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
revoke all on function public.inventory_undo_v1(uuid, uuid) from public, anon, service_role;
grant execute on function public.inventory_undo_v1(uuid, uuid) to authenticated;

commit;
