
-- Phase 1: receipt -> inventory sync support

create extension if not exists pg_trgm;

create index if not exists inventory_items_name_trgm
  on inventory_items using gin (name gin_trgm_ops);

-- Fuzzy-match a receipt line-item name against active inventory items.
create or replace function match_inventory_item(p_name text, p_limit int default 1, p_threshold real default 0.3)
returns table (
  id uuid, name text, category text, is_consumable boolean,
  units_per_purchase numeric, qty_on_hand numeric, score real
)
language sql stable as $$
  select i.id, i.name, i.category, i.is_consumable,
         coalesce(i.units_per_purchase, 1) as units_per_purchase,
         i.qty_on_hand,
         greatest(similarity(i.name, p_name), word_similarity(i.name, p_name)) as score
  from inventory_items i
  where i.is_active
    and greatest(similarity(i.name, p_name), word_similarity(i.name, p_name)) >= p_threshold
  order by score desc, i.is_consumable desc
  limit greatest(p_limit, 1);
$$;

-- Apply a restock purchase atomically: insert purchase, bump stock, write audit row.
create or replace function apply_inventory_purchase(
  p_item_id uuid,
  p_qty numeric,
  p_unit_cost numeric default null,
  p_supplier text default null,
  p_purchased_at date default current_date,
  p_txn_id uuid default null
) returns jsonb
language plpgsql as $$
declare
  v_upp numeric; v_before numeric; v_after numeric; v_pid uuid; v_name text;
begin
  select coalesce(units_per_purchase, 1), qty_on_hand, name
    into v_upp, v_before, v_name
  from inventory_items where id = p_item_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'item_not_found');
  end if;

  insert into inventory_purchases(item_id, qty, unit_cost, supplier, purchased_at, units_per_purchase, notes)
  values (p_item_id, p_qty, p_unit_cost, p_supplier, coalesce(p_purchased_at, current_date), v_upp,
          'Auto-restock from receipt OCR' || case when p_txn_id is not null then ' (txn ' || p_txn_id::text || ')' else '' end)
  returning id into v_pid;

  v_after := coalesce(v_before, 0) + (p_qty * v_upp);
  update inventory_items set qty_on_hand = v_after where id = p_item_id;

  insert into inventory_audit_log(entity_type, entity_id, action, before, after, actor)
  values ('inventory_items', p_item_id, 'ocr_restock',
          jsonb_build_object('qty_on_hand', v_before),
          jsonb_build_object('qty_on_hand', v_after, 'purchase_id', v_pid, 'qty_added', p_qty * v_upp),
          'telegram-ocr');

  return jsonb_build_object('ok', true, 'name', v_name, 'purchase_id', v_pid,
                            'qty_before', v_before, 'qty_after', v_after, 'added', p_qty * v_upp);
end; $$;

-- Allow a new pending kind for the inventory-sync confirmation step.
alter table telegram_pending drop constraint if exists telegram_pending_kind_check;
alter table telegram_pending add constraint telegram_pending_kind_check
  check (kind = any (array['duplicate','large_amount','photo_dup','inventory_sync']));
;
