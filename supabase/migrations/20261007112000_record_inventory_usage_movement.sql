-- 20261007112000_record_inventory_usage_movement.sql
-- Session 74, lane G3 (money): release money_fixes_20261007, part 3 - record_inventory_usage writes the stock movement.
--
-- Read before writing (migrations 20260908000100, 20260913120000, 20260905060000; 01-FACTS and 03-BASELINE B47/B95):
--   * v2 (inventory_movement_compat_v1) wrote a movement ONLY for movement-controlled items; 0 items are controlled in production, so every
--     clean's usage (612 rows, all consumables) decremented qty_on_hand and left no inventory_stock_movements row.
--   * v2's controlled path called inventory_apply_event_v1 -> record_inventory_movement -> inventory_human_authorized, which wants an
--     owner/admin. The RPC itself needs only submit_cleaning (a cleaner), so a cleaner logging a controlled item got "inventory access
--     denied" and the whole session save failed. The first controlled item would have broken the checklist's Log Usage.
-- v3 (same signature, same return shape, same grants, same optional rows[i].usage_key replay key):
--   * Movement-controlled item: the movement is written here (kind='usage', quantity_before -> quantity_after, the actor, a reason) with the
--     same invariants record_inventory_movement enforces and the same deterministic idempotency key as inventory_apply_event_v1
--     ('inventory_usage' source = the usage row id). The caller's own authorization (submit_cleaning on the property, checked above) is
--     the gate, not inventory_human_authorized, so a cleaner can log it. Contract unchanged: the ledger must agree with qty_on_hand first
--     ('stock reconciliation required' otherwise) and insufficient stock is rejected, not clamped.
--   * Not controlled: exactly the legacy behaviour (clamp at zero, a cleaner is never blocked) and NO movement. Fable audit (G3): a movement
--     on an uncontrolled item would make the "last movement == qty_on_hand" gate of dashboard Adjust / forecast pass by coincidence, the
--     next receipt or /count would break the chain again, and a negative legacy qty would trip quantity_before >= 0 and refuse a cleaner's
--     save. inventory_usage is the audit row for those items; INV03 stays a human, reviewed baseline.
-- Rollback: supabase/rollbacks/20261007_money_fixes.sql (restores v2 byte for byte from migration 20260913120000; movement rows already
-- written stay as history).

begin;

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
  v_row jsonb; v_item uuid; v_qty numeric; v_count integer := 0; v_controlled boolean; v_usage_id uuid; v_usage_key text; v_existing uuid;
  v_moves jsonb := '[]'::jsonb; v_name text; v_before numeric; v_after numeric; v_last numeric; v_move uuid; v_who text;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if not public.current_staff_authorized('submit_cleaning', p_property_id) then raise exception using errcode = '42501', message = 'staff access denied'; end if;
  if p_session_date is null then raise exception using errcode = '22023', message = 'session_date required'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception using errcode = '22023', message = 'rows required'; end if;
  v_who := nullif(btrim(coalesce(p_logged_by, '')), '');

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_item := (v_row ->> 'item_id')::uuid;
    v_qty  := (v_row ->> 'used_qty')::numeric;
    v_usage_key := nullif(v_row ->> 'usage_key', '');
    if v_item is null or v_qty is null or v_qty <= 0 then raise exception using errcode = '22023', message = 'each row needs item_id and a positive used_qty'; end if;
    select (movement_controlled_at is not null), name, coalesce(qty_on_hand, 0) into v_controlled, v_name, v_before
      from public.inventory_items i where i.id = v_item and i.property_id = p_property_id for update;
    if v_controlled is null then raise exception using errcode = '22023', message = 'unknown item for property'; end if;

    -- Replay: a usage row with the same client key already exists (its movement was written with it).
    if v_usage_key is not null then
      select id into v_existing from public.inventory_usage u where u.item_id = v_item and u.notes like '%[key:' || v_usage_key || ']%' limit 1;
      if v_existing is not null then v_count := v_count + 1; continue; end if;
    end if;

    insert into public.inventory_usage(item_id, used_qty, session_date, logged_by, notes, property_id, submitted_by_user_id)
    values (v_item, v_qty, p_session_date, v_who,
            nullif(btrim(coalesce(p_notes, '')) || case when v_usage_key is not null then ' [key:' || v_usage_key || ']' else '' end, ''),
            p_property_id, auth.uid())
    returning id into v_usage_id;

    if v_controlled then
      -- Same two refusals record_inventory_movement makes: the ledger must agree with the shelf, and stock cannot go below zero.
      select quantity_after into v_last from public.inventory_stock_movements m where m.item_id = v_item order by sequence_no desc limit 1;
      if v_last is distinct from v_before then raise exception using errcode = '22023', message = 'stock reconciliation required for ' || v_name; end if;
      if v_before < v_qty then raise exception using errcode = '22023', message = 'insufficient stock for ' || v_name; end if;
      v_after := v_before - v_qty;
    else
      v_after := greatest(0, v_before - v_qty);   -- legacy clamp: a cleaner's log is never refused
    end if;

    update public.inventory_items set qty_on_hand = v_after where id = v_item;

    if v_controlled and v_after <> v_before then
      insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key)
      values (v_item, p_property_id, 'usage', v_before, v_after,
              'Usage ' || p_session_date::text || coalesce(' by ' || v_who, ''),
              auth.uid(),
              left('evt-' || encode(extensions.digest('inventory_usage|' || v_usage_id::text || '|' || v_item::text || '|usage', 'sha256'), 'hex'), 80))
      returning id into v_move;
      v_moves := v_moves || to_jsonb(v_move);
    end if;
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('ok', true, 'rows', v_count, 'movements', v_moves);
end;
$$;

revoke all on function public.record_inventory_usage(uuid, date, text, text, jsonb) from public, anon;
grant execute on function public.record_inventory_usage(uuid, date, text, text, jsonb) to authenticated, service_role;
comment on function public.record_inventory_usage(uuid, date, text, text, jsonb) is
  'v3 (G3, 2026-10-07): same contract. Movement-controlled items write a kind=usage inventory_stock_movements row (actor, before, after), reject insufficient stock and need the ledger to agree; others keep the legacy clamp at zero and write no movement. Needs submit_cleaning, not inventory_human_authorized. Optional rows[i].usage_key makes retries replay-safe.';

commit;
