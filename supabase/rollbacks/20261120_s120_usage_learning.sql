-- Compensating rollback for release s120_usage_learning_20261120 (session 120, migration 20261120000000_s120_usage_learning.sql).
-- Takes the inserted hook block back out of the four functions and the seven keys out of the catalogue, then checks each body is the md5 it was before the release:
--   s_apply_inventory_count_core_v1 3937a6da154fe1ed60471689833f96e2, record_inventory_receipt_v1 7cb59453f37eeeeb15b1e9f4c4ffa883, apply_inventory_purchase 48082c76263e15517d733c65f7eb3ccc,
--   s_inventory_receipt_apply_v1 4f09a8ae895d945703f60a96705413e7, get_inventory_catalogue_v1 00ca41d933a5c5a9c4498cff682e7844.
-- A body that is neither the release body nor the original (someone changed it since) stops the rollback (55000) before anything is dropped.
-- Then: unschedules the quarterly job, puts consumption_per_booking of every item the release touched (a seeded baseline or a recompute) back to the value it held before the release, read from the
-- snapshot public.s120_usage_item_snapshot the migration took before any seed (the script stops with 55000 when the snapshot is gone: a rate must never be restored from a guess),
-- drops the refill-mark delete trigger, the new functions (the received-date helper included), the intervals table, the snapshot and the six columns, and narrows consumption_per_booking back to numeric(10,2).
-- An item with a snapshot row that the release seeded or recomputed returns to its snapshot value, hand edits included.
-- Every other item (never touched, or created after the release so it has no snapshot row) keeps its current value rounded to 2 decimals, and a positive value that would round to 0.00 becomes 0.01.
-- DATA LOSS (by design): every interval, every learned rate, the seeded baselines and the refill marks. Stock counts, purchases and the audit log are untouched.
-- Roll back any app that reads usageState / usagePerTurnover / get_inventory_usage_kpi_v1 first. Apply with run-sql-on-host.sh.

begin;

-- 0. the snapshot must exist before anything is taken apart ---------------------------------------------------------------------------------------------------------
do $s$
begin
  if to_regclass('public.s120_usage_item_snapshot') is null then
    raise exception 's120 rollback: public.s120_usage_item_snapshot is missing, so consumption_per_booking cannot be restored from the values before the release' using errcode = '55000';
  end if;
end $s$;

-- 1. the four hooks and the catalogue keys -------------------------------------------------------------------------------------------------------------------------
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.s_apply_inventory_count_core_v1(text,jsonb,text,timestamptz,uuid)');
  if md5(v_src) = '3937a6da154fe1ed60471689833f96e2' then raise notice 'count core already original';
  else
    v_new := replace(v_src, $r$    -- S120: a physical count is an anchor for the usage learning; a problem here must never block a count
    begin
      perform public.record_inventory_anchor_v1(it.id, v_counted, coalesce(p_as_of, now()), 'count');
    exception when others then
      raise warning 's120 usage anchor (count): % (%)', sqlerrm, sqlstate;
    end;
    v_out := v_out || jsonb_build_object('name', it.name, 'before', it.qty_on_hand, 'after', v_new,$r$, $f$    v_out := v_out || jsonb_build_object('name', it.name, 'before', it.qty_on_hand, 'after', v_new,$f$);
    if md5(v_new) is distinct from '3937a6da154fe1ed60471689833f96e2' then
      raise exception 's120 rollback: count core is not the release body (md5 %)', md5(v_src) using errcode = '55000';
    end if;
    execute format($e$create or replace function public.s_apply_inventory_count_core_v1(p_actor text, p_rows jsonb, p_note text, p_as_of timestamptz, p_access_user uuid default null)
      returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
  end if;
end $g$;
revoke all on function public.s_apply_inventory_count_core_v1(text, jsonb, text, timestamptz, uuid) from public, anon, authenticated, service_role;

do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid)');
  if md5(v_src) = '7cb59453f37eeeeb15b1e9f4c4ffa883' then raise notice 'record_inventory_receipt_v1 already original';
  else
    v_new := replace(v_src, $r$  -- S120: remember the refill for the usage learning; a problem here must never block a receipt
  begin
    perform public.record_inventory_anchor_v1(p_item_id, v_units, (coalesce(p_purchased_at, public.manila_today())::timestamp at time zone 'Asia/Manila'), 'receipt');
  exception when others then
    raise warning 's120 usage anchor (receipt): % (%)', sqlerrm, sqlstate;
  end;
  return jsonb_build_object('ok', true, 'purchaseId', v_pid, 'movementId', v_mid, 'unitsAdded', v_units, 'controlled', i.movement_controlled_at is not null);$r$, $f$  return jsonb_build_object('ok', true, 'purchaseId', v_pid, 'movementId', v_mid, 'unitsAdded', v_units, 'controlled', i.movement_controlled_at is not null);$f$);
    if md5(v_new) is distinct from '7cb59453f37eeeeb15b1e9f4c4ffa883' then
      raise exception 's120 rollback: record_inventory_receipt_v1 is not the release body (md5 %)', md5(v_src) using errcode = '55000';
    end if;
    execute format($e$create or replace function public.record_inventory_receipt_v1(p_item_id uuid, p_packs numeric, p_unit_cost numeric, p_supplier text, p_purchased_at date, p_receipt_path text, p_shopping_list_id uuid, p_idempotency_key text, p_supplier_id uuid default null)
      returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
  end if;
end $g$;
revoke all on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid) from public, anon, service_role;
grant execute on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid) to authenticated;

do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.apply_inventory_purchase(uuid,numeric,numeric,text,date,uuid,uuid)');
  if md5(v_src) = '48082c76263e15517d733c65f7eb3ccc' then raise notice 'apply_inventory_purchase already original';
  else
    v_new := replace(v_src, $r$  -- S120: remember the refill for the usage learning; a problem here must never block a restock
  begin
    perform public.record_inventory_anchor_v1(p_item_id, p_qty * v_upp, (coalesce(p_purchased_at, public.manila_today())::timestamp at time zone 'Asia/Manila'), 'receipt');
  exception when others then
    raise warning 's120 usage anchor (ocr restock): % (%)', sqlerrm, sqlstate;
  end;
  return jsonb_build_object('ok', true, 'name', v_name, 'purchase_id', v_pid,$r$, $f$  return jsonb_build_object('ok', true, 'name', v_name, 'purchase_id', v_pid,$f$);
    if md5(v_new) is distinct from '48082c76263e15517d733c65f7eb3ccc' then
      raise exception 's120 rollback: apply_inventory_purchase is not the release body (md5 %)', md5(v_src) using errcode = '55000';
    end if;
    execute format($e$create or replace function public.apply_inventory_purchase(p_item_id uuid, p_qty numeric, p_unit_cost numeric, p_supplier text, p_purchased_at date, p_txn_id uuid, p_supplier_id uuid default null)
      returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
  end if;
end $g$;
revoke all on function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid, uuid) from public, anon, authenticated;
grant execute on function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid, uuid) to service_role;

do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.s_inventory_receipt_apply_v1(uuid,numeric,numeric,text,uuid,date,text,uuid)');
  if md5(v_src) = '4f09a8ae895d945703f60a96705413e7' then raise notice 's_inventory_receipt_apply_v1 already original';
  else
    v_new := replace(v_src, $r$  -- S120: remember the refill for the usage learning; a problem here must never block a receipt
  begin
    perform public.record_inventory_anchor_v1(p_item_id, p_units, (coalesce(p_date, public.manila_today())::timestamp at time zone 'Asia/Manila'), 'receipt');
  exception when others then
    raise warning 's120 usage anchor (staff receipt): % (%)', sqlerrm, sqlstate;
  end;
  return v_pid;$r$, $f$  return v_pid;$f$);
    if md5(v_new) is distinct from '4f09a8ae895d945703f60a96705413e7' then
      raise exception 's120 rollback: s_inventory_receipt_apply_v1 is not the release body (md5 %)', md5(v_src) using errcode = '55000';
    end if;
    execute format($e$create or replace function public.s_inventory_receipt_apply_v1(p_item_id uuid, p_units numeric, p_cost numeric, p_vendor text, p_supplier_id uuid, p_date date, p_path text, p_draft_id uuid)
      returns uuid language plpgsql security definer set search_path = '' as %L$e$, v_new);
  end if;
end $g$;
revoke all on function public.s_inventory_receipt_apply_v1(uuid, numeric, numeric, text, uuid, date, text, uuid) from public, anon, authenticated, service_role;

do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.get_inventory_catalogue_v1(uuid)');
  if md5(v_src) = '00ca41d933a5c5a9c4498cff682e7844' then raise notice 'catalogue already original';
  else
    v_new := replace(v_src, $r$'baselineNote', i.baseline_note,
    'usageState', i.usage_state, 'usagePerTurnover', i.consumption_per_booking, 'usageBaseline', i.usage_baseline_per_turnover,
    'lastRefillAt', i.last_refill_at, 'lastRefillQty', i.last_refill_qty,
    'lastCountAt', (select max(x.anchor_at) from public.inventory_usage_intervals x where x.item_id = i.id and x.source = 'count'),
    'usageCounts', (select count(*) from public.inventory_usage_intervals x where x.item_id = i.id and x.accepted and x.anchor_at > now() - interval '90 days'),$r$, $f$'baselineNote', i.baseline_note,$f$);
    if md5(v_new) is distinct from '00ca41d933a5c5a9c4498cff682e7844' then
      raise exception 's120 rollback: get_inventory_catalogue_v1 is not the release body (md5 %)', md5(v_src) using errcode = '55000';
    end if;
    execute format($e$create or replace function public.get_inventory_catalogue_v1(p_property_id uuid)
      returns jsonb language plpgsql stable security definer set search_path = '' as %L$e$, v_new);
  end if;
end $g$;
revoke all on function public.get_inventory_catalogue_v1(uuid) from public, anon, service_role;
grant execute on function public.get_inventory_catalogue_v1(uuid) to authenticated;

-- 2. the schedule --------------------------------------------------------------------------------------------------------------------------------------------------
do $c$
begin
  if to_regclass('cron.job') is not null then
    perform cron.unschedule(jobid) from cron.job where jobname = 'inventory-usage-quarterly-reset';
  end if;
end $c$;

-- 3. the stored rate goes back to what it was before the release (from the snapshot, which holds every item as it was) ---------------------------------------------------
-- Every item the release touched: seeded (a baseline) or recomputed (usage_updated_at), restored to its snapshot value even when it was edited by hand since. Other items are left; the type change below rounds a leftover four-decimal rate to two.
update public.inventory_items i
   set consumption_per_booking = s.consumption_per_booking
  from public.s120_usage_item_snapshot s
 where s.id = i.id and (i.usage_baseline_per_turnover is not null or i.usage_updated_at is not null);
-- the narrowing must not turn a small positive rate into 0, which would remove the item's coverage
update public.inventory_items set consumption_per_booking = 0.01 where consumption_per_booking > 0 and consumption_per_booking < 0.005;
alter table public.inventory_items alter column consumption_per_booking type numeric(10,2);

-- 4. objects -------------------------------------------------------------------------------------------------------------------------------------------------------
drop trigger if exists s120_refill_mark_after_delete on public.inventory_purchases;
drop function if exists public.s_inventory_refill_mark_after_delete_v1();
drop function if exists public.s_inventory_received_date_v1(date, timestamptz);
drop function if exists public.get_inventory_usage_kpi_v1(uuid);
drop function if exists public.inventory_usage_quarterly_reset_v1();
drop function if exists public.record_inventory_anchor_v1(uuid, numeric, timestamptz, text);
drop function if exists public.s_inventory_usage_recompute_v1(uuid, timestamptz);
drop table if exists public.inventory_usage_intervals;
drop table if exists public.s120_usage_item_snapshot;
alter table public.inventory_items
  drop column if exists usage_baseline_per_turnover,
  drop column if exists usage_baseline_note,
  drop column if exists usage_state,
  drop column if exists last_refill_at,
  drop column if exists last_refill_qty,
  drop column if exists usage_updated_at;

-- 5. check ---------------------------------------------------------------------------------------------------------------------------------------------------------
do $v$
begin
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.s_apply_inventory_count_core_v1(text,jsonb,text,timestamptz,uuid)'::regprocedure) is distinct from '3937a6da154fe1ed60471689833f96e2'
     or (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid)'::regprocedure) is distinct from '7cb59453f37eeeeb15b1e9f4c4ffa883'
     or (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.apply_inventory_purchase(uuid,numeric,numeric,text,date,uuid,uuid)'::regprocedure) is distinct from '48082c76263e15517d733c65f7eb3ccc'
     or (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.s_inventory_receipt_apply_v1(uuid,numeric,numeric,text,uuid,date,text,uuid)'::regprocedure) is distinct from '4f09a8ae895d945703f60a96705413e7'
     or (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.get_inventory_catalogue_v1(uuid)'::regprocedure) is distinct from '00ca41d933a5c5a9c4498cff682e7844' then
    raise exception 's120 rollback: a function is not back to its pre-release body' using errcode = '55000';
  end if;
  if (select numeric_scale from information_schema.columns where table_schema = 'public' and table_name = 'inventory_items' and column_name = 'consumption_per_booking') is distinct from 2 then
    raise exception 's120 rollback: consumption_per_booking is not numeric(10,2) again' using errcode = '55000';
  end if;
end $v$;

commit;
