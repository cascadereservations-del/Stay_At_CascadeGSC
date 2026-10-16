-- 20261024010000_s89_backlog_inventory_precision.sql
-- Session 89, lane backlog-sql: release s89_backlog_20261024, part 2 (inventory price precision). unit_cost was numeric(10,2), so a per-unit price such
-- as PHP 100 for a pack of 12 (8.3333) was stored as 8.33 and every total built from it drifted. Now:
--   inventory_purchases.unit_cost  numeric(10,2) -> numeric(12,4)
--   inventory_items.unit_cost      numeric(10,2) -> numeric(12,4)   (the cost the stock valuation reads; record_inventory_receipt_v1 wrote it with round(,2))
--   inventory_purchases.total_cost stays numeric(10,2), GENERATED ALWAYS AS (qty * unit_cost) STORED, same expression: dropped and re-added only because
--                                  Postgres will not retype a column a generated column reads. It moves to the last column position; nothing reads by position.
--   price_history_by_item          dropped and recreated byte-for-byte (security_invoker, comment, SELECT for authenticated, ALL for service_role; no anon);
--                                  its unit_cost column is now numeric(12,4). It is the only dependent (pg_depend, read live 2026-10-16).
--   record_inventory_receipt_v1    one change: the inventory_items.unit_cost it sets is round(,4) instead of round(,2). Its purchase insert already rounded to 4.
--                                  apply_inventory_purchase already rounds to 4 and needs no change. Existing rows keep their stored (2 dp) values.
-- Contract-phase release (ALTER COLUMN TYPE, DROP COLUMN): widening is readable and writable by the old app, but the release needs its rehearsal first.
-- Guards (55000, nothing changes): the live columns and the view must be as read; record_inventory_receipt_v1 md5 (CR stripped) c05c174f9d8861813c0a14ad78735195.
-- Rollback: supabase/rollbacks/20261024_s89_backlog.sql (rounds back to 2 dp).

begin;

do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid)');
  if v_got is distinct from 'c05c174f9d8861813c0a14ad78735195' then
    raise exception 's89 inventory precision: record_inventory_receipt_v1 is not the body this release was cut from (md5 %)', v_got using errcode = '55000';
  end if;
  if (select format_type(a.atttypid, a.atttypmod) from pg_attribute a where a.attrelid = 'public.inventory_purchases'::regclass and a.attname = 'unit_cost' and not a.attisdropped) is distinct from 'numeric(10,2)'
     or (select format_type(a.atttypid, a.atttypmod) from pg_attribute a where a.attrelid = 'public.inventory_items'::regclass and a.attname = 'unit_cost' and not a.attisdropped) is distinct from 'numeric(10,2)'
     or (select format_type(a.atttypid, a.atttypmod) from pg_attribute a where a.attrelid = 'public.inventory_purchases'::regclass and a.attname = 'total_cost' and not a.attisdropped) is distinct from 'numeric(10,2)'
     or (select pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum where d.adrelid = 'public.inventory_purchases'::regclass and a.attname = 'total_cost') is distinct from '(qty * unit_cost)' then
    raise exception 's89 inventory precision: the unit_cost / total_cost columns are not as read live 2026-10-16' using errcode = '55000';
  end if;
  if to_regclass('public.price_history_by_item') is null then
    raise exception 's89 inventory precision: price_history_by_item is missing' using errcode = '55000';
  end if;
end $$;

drop view public.price_history_by_item;
alter table public.inventory_purchases drop column total_cost;
alter table public.inventory_purchases alter column unit_cost type numeric(12,4);
alter table public.inventory_purchases add column total_cost numeric(10,2) generated always as (qty * unit_cost) stored;
alter table public.inventory_items alter column unit_cost type numeric(12,4);

create view public.price_history_by_item
with (security_invoker = true)
as
select
  p.item_id,
  i.name as item_name,
  p.supplier,
  p.unit_cost,
  p.purchased_at,
  row_number() over (
    partition by p.item_id
    order by p.purchased_at desc, p.created_at desc, p.id desc
  ) as recency_rank
from public.inventory_purchases p
join public.inventory_items i on i.id = p.item_id
where p.unit_cost is not null;

comment on view public.price_history_by_item is
  'Inventory purchase price history ranked newest-first per item.';
revoke all on public.price_history_by_item from public, anon, authenticated, service_role;
grant select on public.price_history_by_item to authenticated;
grant all on public.price_history_by_item to service_role;

-- the one writer change (see the head of this file); the body is the live s86 one except round(..., 4) on inventory_items.unit_cost
create or replace function public.record_inventory_receipt_v1(p_item_id uuid, p_packs numeric, p_unit_cost numeric, p_supplier text, p_purchased_at date, p_receipt_path text, p_shopping_list_id uuid, p_idempotency_key text, p_supplier_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
  values (p_item_id, coalesce(p_purchased_at, current_date), v_units, case when p_unit_cost is not null then round(p_unit_cost / coalesce(nullif(i.units_per_purchase, 0), 1), 4) end, coalesce(v_sname, p_supplier), v_sid, 'Admin receipt [key:' || p_idempotency_key || ']', p_receipt_path, i.purchase_unit, coalesce(i.units_per_purchase, 1)::integer)
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
  return jsonb_build_object('ok', true, 'purchaseId', v_pid, 'movementId', v_mid, 'unitsAdded', v_units, 'controlled', i.movement_controlled_at is not null);
end;
$$;
revoke all on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid) from public, anon, service_role;
grant execute on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid) to authenticated;

commit;
