-- Compensating rollback for release s120_count_learning_20261120 (session 120, migration 20261120000005_s120_count_learning.sql).
-- Takes the inserted blocks (anchor hook and app_count audit rows) back out of reconcile_inventory_baseline_v1 and inventory_undo_v1, puts the purchase condition and the comment back into get_inventory_usage_kpi_v1,
-- puts the usage-learning body back into s_inventory_refill_mark_after_delete_v1 and drops s_inventory_refill_mark_sync_v1,
-- then checks each body is the md5 it was before the release:
--   reconcile_inventory_baseline_v1 7cbb2ea861268b3fbe848c974e32b2f2, inventory_undo_v1 b3923b0bae57e812bb8375eea81f93e9, get_inventory_usage_kpi_v1 f0a2052c3ccc56673808d000ba21d189.
-- A body that is neither the release body nor the original (someone changed it since) stops the rollback (55000) before anything is dropped.
-- Then drops record_missed_refill_v1 and the column inventory_usage_intervals.refill_recorded_qty (the recorded refill quantities are lost; the intervals, their accepted flags and consumed figures are not touched).
-- RUN THIS BEFORE supabase/rollbacks/20261120_s120_usage_learning.sql. Counts already made stay counts: an item that was kept in learning stays in it (movement_controlled_at is not set afterwards).
-- Roll back any app that calls record_missed_refill_v1 first. Apply with run-sql-on-host.sh.

begin;

-- 1. reconcile_inventory_baseline_v1 -------------------------------------------------------------------------------------------------------------------------------------
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)');
  if v_src is null then raise exception 's120 rollback: public.reconcile_inventory_baseline_v1 is missing' using errcode = '55000'; end if;
  if md5(v_src) = '7cbb2ea861268b3fbe848c974e32b2f2' then raise notice 'reconcile_inventory_baseline_v1 already original';
  else
    v_new := replace(v_src,
      replace($r$-- S120: a count of an active consumable that is not movement controlled keeps it in the usage learning: movement_controlled_at stays null and the count is an anchor
  if coalesce(i.is_consumable, false) and coalesce(i.is_active, false) and i.movement_controlled_at is null then
    update public.inventory_items set baseline_reviewed_by = auth.uid(), baseline_note = btrim(p_note) where id = p_item_id;
    -- only the call that wrote the movement audits and anchors it (a replay returns the older movement)
    declare v_at timestamptz;
    begin
      select m.created_at into v_at from public.inventory_stock_movements m where m.id = v_mid;
      if v_at = now() then
        -- the count is a stock change that leaves no trace but its movement, and inventory_qty_at_v1 rebuilds past stock from audit rows: write the row it reads. NOT inside the guard below:
        -- when the row cannot be written the count fails as a whole
        if not exists (select 1 from public.inventory_audit_log a where a.entity_type = 'inventory_items' and a.entity_id = p_item_id and a.action = 'app_count' and a.after ->> 'movement_id' = v_mid::text) then
          insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor)
          values ('inventory_items', p_item_id, 'app_count', jsonb_build_object('qty_on_hand', v_before),
                  jsonb_build_object('qty_on_hand', p_counted_qty, 'movement_id', v_mid), coalesce(auth.uid()::text, 'app'));
        end if;
        -- a problem in the learning must never block a count
        begin
          perform public.record_inventory_anchor_v1(p_item_id, p_counted_qty, v_at, 'count');
        exception when others then
          raise warning 's120 usage anchor (reconcile): % (%)', sqlerrm, sqlstate;
        end;
      end if;
    end;
  else
    update public.inventory_items set movement_controlled_at = coalesce(movement_controlled_at, now()), baseline_reviewed_by = auth.uid(), baseline_note = btrim(p_note) where id = p_item_id;
  end if;$r$, chr(13), ''),
      replace($f$update public.inventory_items set movement_controlled_at = coalesce(movement_controlled_at, now()), baseline_reviewed_by = auth.uid(), baseline_note = btrim(p_note) where id = p_item_id;$f$, chr(13), ''));
    if md5(v_new) is distinct from '7cbb2ea861268b3fbe848c974e32b2f2' then
      raise exception 's120 rollback: reconcile_inventory_baseline_v1 is not the release body (md5 %)', md5(v_src) using errcode = '55000';
    end if;
    execute format($e$create or replace function public.reconcile_inventory_baseline_v1(p_item_id uuid, p_counted_qty numeric, p_note text, p_idempotency_key text)
      returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
  end if;
end $g$;
revoke all on function public.reconcile_inventory_baseline_v1(uuid, numeric, text, text) from public, anon, service_role;
grant execute on function public.reconcile_inventory_baseline_v1(uuid, numeric, text, text) to authenticated;

-- 2. inventory_undo_v1 ---------------------------------------------------------------------------------------------------------------------------------------------------
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.inventory_undo_v1(uuid,uuid)');
  if v_src is null then raise exception 's120 rollback: public.inventory_undo_v1 is missing' using errcode = '55000'; end if;
  if md5(v_src) = 'b3923b0bae57e812bb8375eea81f93e9' then raise notice 'inventory_undo_v1 already original';
  else
    v_new := replace(v_src,
      replace($r$-- S120: undoing an app count (one that wrote an app_count audit row) writes the matching app_count_undo row, so inventory_qty_at_v1 sees the stock come back. NOT inside the guard below:
  -- when the row cannot be written the undo fails as a whole
  if v_have_m and exists (select 1 from public.inventory_audit_log a where a.entity_type = 'inventory_items' and a.entity_id = i.id and a.action = 'app_count' and a.after ->> 'movement_id' = m.id::text) then
    insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor)
    values ('inventory_items', i.id, 'app_count_undo', jsonb_build_object('qty_on_hand', m.quantity_after, 'movement_id', m.id),
            jsonb_build_object('qty_on_hand', m.quantity_before), coalesce(auth.uid()::text, 'app'));
  end if;
  -- S120: undoing a count that anchored the usage learning takes its interval out again (only the newest one, else the history stays); a problem here must never fail an undo
  if v_have_m and m.kind = 'reconcile' and i.movement_controlled_at is null then
    begin
      delete from public.inventory_usage_intervals x
       where x.item_id = i.id and x.anchor_at = m.created_at
         and not exists (select 1 from public.inventory_usage_intervals y where y.item_id = i.id and y.anchor_at > x.anchor_at);
      if found then
        perform public.s_inventory_usage_recompute_v1(i.id, now());
        perform public.s_inventory_refill_mark_sync_v1(i.id);
      end if;
    exception when others then
      raise warning 's120 usage anchor (undo): % (%)', sqlerrm, sqlstate;
    end;
  end if;
  select it.qty_on_hand into v_after from public.inventory_items it where it.id = i.id;$r$, chr(13), ''),
      replace($f$select it.qty_on_hand into v_after from public.inventory_items it where it.id = i.id;$f$, chr(13), ''));
    if md5(v_new) is distinct from 'b3923b0bae57e812bb8375eea81f93e9' then
      raise exception 's120 rollback: inventory_undo_v1 is not the release body (md5 %)', md5(v_src) using errcode = '55000';
    end if;
    execute format($e$create or replace function public.inventory_undo_v1(p_movement_id uuid default null, p_purchase_id uuid default null)
      returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
  end if;
end $g$;
revoke all on function public.inventory_undo_v1(uuid, uuid) from public, anon, service_role;
grant execute on function public.inventory_undo_v1(uuid, uuid) to authenticated;

-- 3. get_inventory_usage_kpi_v1: the purchase condition and the comment come back ----------------------------------------------------------------------------------------
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.get_inventory_usage_kpi_v1(uuid)');
  if v_src is null then raise exception 's120 rollback: public.get_inventory_usage_kpi_v1 is missing' using errcode = '55000'; end if;
  if md5(v_src) = 'f0a2052c3ccc56673808d000ba21d189' then raise notice 'get_inventory_usage_kpi_v1 already original';
  else
    v_new := replace(v_src,
      replace($r$-- the newest interval of the item was rejected as an unrecorded restock and the refill is not recorded yet: only a missed refill (record_missed_refill_v1) or a newer count ends the prompt, an ordinary purchase does not (the count already holds its stock)$r$, chr(13), ''),
      replace($f$-- the newest interval of the item was rejected as an unrecorded restock and nothing has been recorded since that count$f$, chr(13), ''));
    v_new := replace(v_new, $r$'unrecorded restock') w;$r$,
      replace($f$'unrecorded restock'
             and not exists (select 1 from public.inventory_purchases p where p.item_id = i.id and p.created_at > x.anchor_at)) w;$f$, chr(13), ''));
    if md5(v_new) is distinct from 'f0a2052c3ccc56673808d000ba21d189' then
      raise exception 's120 rollback: get_inventory_usage_kpi_v1 is not the release body (md5 %)', md5(v_src) using errcode = '55000';
    end if;
    execute format($e$create or replace function public.get_inventory_usage_kpi_v1(p_property_id uuid)
      returns jsonb language plpgsql stable security definer set search_path = '' as %L$e$, v_new);
  end if;
end $g$;
comment on function public.get_inventory_usage_kpi_v1(uuid) is
  'S120: usage-learning KPI (read_operations). itemsMeasured of itemsTotal, medianForecastError (null with no sample), items under 14 days of stock at the learned rate, items waiting for a recorded refill.';
revoke all on function public.get_inventory_usage_kpi_v1(uuid) from public, anon, service_role;
grant execute on function public.get_inventory_usage_kpi_v1(uuid) to authenticated;

-- 4. objects -------------------------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.s_inventory_refill_mark_after_delete_v1()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.inventory_items i
     set last_refill_at = (select (public.s_inventory_received_date_v1(p.purchased_at, p.created_at)::timestamp at time zone 'Asia/Manila') from public.inventory_purchases p
                            where p.item_id = old.item_id order by public.s_inventory_received_date_v1(p.purchased_at, p.created_at) desc, p.created_at desc limit 1),
         last_refill_qty = (select p.qty from public.inventory_purchases p
                             where p.item_id = old.item_id order by public.s_inventory_received_date_v1(p.purchased_at, p.created_at) desc, p.created_at desc limit 1)
   where i.id = old.item_id and i.last_refill_at is not null;
  return null;
end $$;
revoke all on function public.s_inventory_refill_mark_after_delete_v1() from public, anon, authenticated, service_role;
drop function if exists public.s_inventory_refill_mark_sync_v1(uuid);
drop function if exists public.record_missed_refill_v1(uuid, numeric);
alter table public.inventory_usage_intervals drop column if exists refill_recorded_qty;

-- 5. check ---------------------------------------------------------------------------------------------------------------------------------------------------------------
do $v$
begin
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)'::regprocedure) is distinct from '7cbb2ea861268b3fbe848c974e32b2f2'
     or (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.inventory_undo_v1(uuid,uuid)'::regprocedure) is distinct from 'b3923b0bae57e812bb8375eea81f93e9'
     or (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.get_inventory_usage_kpi_v1(uuid)'::regprocedure) is distinct from 'f0a2052c3ccc56673808d000ba21d189'
     or position('s_inventory_refill_mark_sync_v1' in (select prosrc from pg_proc where oid = 'public.s_inventory_refill_mark_after_delete_v1()'::regprocedure)) > 0
     or to_regprocedure('public.s_inventory_refill_mark_sync_v1(uuid)') is not null then
    raise exception 's120 rollback: a function is not back to its pre-release body' using errcode = '55000';
  end if;
end $v$;

commit;
