-- 20261120000005_s120_count_learning.sql
-- Session 120 (lane S10): release s120_count_learning_20261120. Counts keep learning, a missed refill is record-only.
-- Why: the admin count screens failed the Opus review. "Was this a refill?" recorded a normal receipt, which adds stock on top of a count that already held it and dates it today,
-- and the recount route (reconcile_inventory_baseline_v1) set movement_controlled_at, which removes the item from the usage learning for good. Production on 2026-11-19: 0 of 22 active
-- consumables are movement controlled, so nothing is lost yet.
--
-- DEPENDS ON 20261120000000_s120_usage_learning.sql (the intervals table, record_inventory_anchor_v1, s_inventory_usage_recompute_v1, get_inventory_usage_kpi_v1). Apply it first.
-- Additive for clients: no existing signature, grant or result key changes.
--
-- WHAT THIS DOES
--   1. inventory_usage_intervals + refill_recorded_qty numeric (nullable, check > 0): the quantity an admin recorded as a missed refill for that interval. No API grant changes.
--   2. reconcile_inventory_baseline_v1 (live md5 7cbb2ea861268b3fbe848c974e32b2f2): a count of an ACTIVE CONSUMABLE that is NOT movement controlled no longer sets movement_controlled_at (baseline_reviewed_by
--      and baseline_note are still written, the movement row and its idempotency key are unchanged). When this call created the movement (its created_at = now(); a replay returns an older one) it then calls
--      record_inventory_anchor_v1(item, counted, movement created_at, 'count') inside a begin / exception block that turns any error into a WARNING. Every other item (already controlled, non-consumable,
--      inactive) behaves exactly as before. The movement is written by record_inventory_movement (owner/admin) or s_inventory_staff_movement_v1 (cleaner); neither reads movement_controlled_at,
--      so both work for a not-controlled item (s_inventory_staff_movement_v1, live md5 61b51c8b14d81d167dffd74c14dfe6e0, is not changed).
--   3. inventory_undo_v1 (live md5 b3923b0bae57e812bb8375eea81f93e9): after a successful undo of a 'reconcile' movement on an item that is not controlled, the interval with anchor_at = the movement's created_at is removed
--      when it is the NEWEST interval of the item, and the rate is recomputed at now(). A newer interval leaves the history alone. Its stays become claimable again because turnover_keys leave with the row.
--      A problem here is a WARNING, never a failed undo.
--   4. record_missed_refill_v1(item, qty) returns jsonb: admin (manage_inventory) records that the newest count's jump was a refill nobody entered. STOCK AND PURCHASES ARE NEVER WRITTEN.
--      It updates the newest interval (received_between + qty, refill_recorded_qty, consumed, then the anchor function's reasons: same-day purchase, too short, too few turnovers; accepted when none applies),
--      moves last_refill_at / last_refill_qty under the receipt path's guard, recomputes the rate at the interval's anchor and writes one inventory_audit_log row (action missed_refill).
--      Results: ok false not_learning (controlled, inactive, non-consumable); ok false not_waiting (newest interval is not an unrecorded restock); ok false too_small with minimum (consumed would be below 0);
--      ok true replayed (the newest interval already holds this qty); ok true accepted, reason, consumed, received.
--   5. get_inventory_usage_kpi_v1: an ordinary purchase no longer clears the "waiting for a recorded refill" prompt (the count already holds the stock it added). It ends when the refill is recorded here or a newer count arrives.
--
-- S11 FIXES FROM THE OPUS REVIEW (edited in place: this migration has never been applied)
--   a. AN APP COUNT IS AUDITED. inventory_qty_at_v1 rebuilds past stock of an item that is not movement controlled from usage, purchases and inventory_audit_log rows with numeric before / after qty_on_hand;
--      a count made in the app wrote only a movement, so a later Telegram count "as of yesterday" overwrote it. reconcile_inventory_baseline_v1 now inserts one audit row (action app_count, before / after
--      qty_on_hand, after.movement_id) when this call wrote the movement of an active, not controlled consumable; inventory_undo_v1 inserts the matching app_count_undo row (before = counted, after = restored)
--      when the undone movement has an app_count row. Both inserts are outside the warning guards: a row that cannot be written fails the count or the undo as a whole.
--      Readers of inventory_audit_log (checked): inventory_qty_at_v1 (reads every action but ocr_restock with numeric before / after: the intended reader), the counted-at date and the count history in the
--      inventory catalogue and item detail (read telegram_count and movements only), the usage backfill (telegram_count only), s120_linen_stains (writer). No other function mentions the new actions.
--   b. THE REFILL MARK STAYS TRUE. s_inventory_refill_mark_sync_v1 sets last_refill_at / last_refill_qty from the newest of the remaining purchases (received-date rule) and the intervals with a recorded
--      refill (anchor_at). s_inventory_refill_mark_after_delete_v1 (the purchase delete trigger of the usage-learning migration) now calls it, and so does the undo of a count that removes an interval.
--   c. THIS FILE SUPERSEDES the sentence in 20261120000000_s120_usage_learning.sql that says these counts end the usage learning (the count route of an active consumable that is not controlled no longer
--      sets movement_controlled_at). That migration is not edited.
--   d. Accepted, not built: two reconciles of one item in one transaction (not reachable through the API); concurrent counts where the later commit is skipped as older.
--   e. Usage undo on a counted consumable is absent by design (no consumable on production is movement controlled: 0 of 22).
--
-- DESIGN CHOICES THE REVIEW SHOULD KNOW
--   * Every replaced body is the live body with the inserted block (patched in place inside a DO, so the migration starts from whatever the live body is): md5 of prosrc with CR stripped, 55000 on a body
--     that is neither the release body nor the original, a re-run is a notice. Pattern and replacement texts are stripped of CR too, so a CRLF checkout patches the same bytes.
--   * The count that anchors uses the movement's own created_at, so a count and its movement carry one instant (undo finds the interval by it). Two counts of one item in one transaction share that instant;
--     the second is a duplicate anchor (idempotent by (item, anchor_at)).
--   * record_missed_refill_v1 checks p_qty < 100000000 (the movement ledger limit) and rejects NaN with it: a deviation from the brief, which names only null, not above 0 and more than 2 decimals.
--   * The audit actor is auth.uid()::text (the pattern of s120_linen_stains), 'admin' without a session.
--   * Release phase is backfill, not expand: the undo block holds a DELETE of one interval row at run time, which the expand-phase guard refuses to see in a migration (s84, s85, s86 are backfill for the same reason).
--
-- GUARDS (55000, nothing changes):
--   reconcile_inventory_baseline_v1  7cbb2ea861268b3fbe848c974e32b2f2  (20261018000000_s85_cleaner_count.sql)
--   inventory_undo_v1                b3923b0bae57e812bb8375eea81f93e9  (20261020000000_s86_inventory_db.sql)
--   get_inventory_usage_kpi_v1       f0a2052c3ccc56673808d000ba21d189  (20261120000000_s120_usage_learning.sql)
-- Grants restated (ML-21) for every function this file creates or replaces.
-- Rollback: supabase/rollbacks/20261120_s120_count_learning.sql (run it BEFORE the usage-learning rollback).

begin;

do $d$
begin
  if to_regclass('public.inventory_usage_intervals') is null or to_regprocedure('public.record_inventory_anchor_v1(uuid,numeric,timestamptz,text)') is null
     or to_regprocedure('public.s_inventory_usage_recompute_v1(uuid,timestamptz)') is null or to_regprocedure('public.get_inventory_usage_kpi_v1(uuid)') is null then
    raise exception 's120 count learning: apply 20261120000000_s120_usage_learning.sql first' using errcode = '55000';
  end if;
end $d$;

-- 1. column ----------------------------------------------------------------------------------------------------------------------------------------------------
alter table public.inventory_usage_intervals add column if not exists refill_recorded_qty numeric check (refill_recorded_qty > 0);
comment on column public.inventory_usage_intervals.refill_recorded_qty is
  'S120: the refill an admin recorded for this interval through record_missed_refill_v1 (stock and purchases are not written). Null when none.';

-- 1b. the refill mark: one helper for every path that removes the thing the mark was taken from ---------------------------------------------------------------------
-- The mark is the newest of the purchases that remain (the received-date rule of the receipt path) and the intervals with a recorded refill (their anchor_at). Only an item that has a mark gets one back
-- (the rule the delete trigger always had). A receipt undone no longer wipes a recorded refill, and an undone count takes its recorded refill out of the mark.
create or replace function public.s_inventory_refill_mark_sync_v1(p_item_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.inventory_items i
     set (last_refill_at, last_refill_qty) = (select c.at, c.q from (
           select (public.s_inventory_received_date_v1(p.purchased_at, p.created_at)::timestamp at time zone 'Asia/Manila') as at, p.qty as q, p.created_at as tie
             from public.inventory_purchases p where p.item_id = p_item_id
           union all
           select x.anchor_at, x.refill_recorded_qty, x.anchor_at
             from public.inventory_usage_intervals x where x.item_id = p_item_id and x.refill_recorded_qty is not null) c
           order by c.at desc, c.tie desc limit 1)
   where i.id = p_item_id and i.last_refill_at is not null;
end $$;
comment on function public.s_inventory_refill_mark_sync_v1(uuid) is
  'S120: sets last_refill_at / last_refill_qty from the newest of the remaining purchases (received date) and the intervals with a recorded refill (anchor_at). Internal, no grants. Called by the purchase delete trigger and by the undo of a count.';
revoke all on function public.s_inventory_refill_mark_sync_v1(uuid) from public, anon, authenticated, service_role;

create or replace function public.s_inventory_refill_mark_after_delete_v1()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.s_inventory_refill_mark_sync_v1(old.item_id);
  return null;
end $$;
revoke all on function public.s_inventory_refill_mark_after_delete_v1() from public, anon, authenticated, service_role;

-- 2. a count keeps a consumable in the learning ------------------------------------------------------------------------------------------------------------------
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)');
  if v_src is null then raise exception 's120: public.reconcile_inventory_baseline_v1 is missing' using errcode = '55000'; end if;
  if position('record_inventory_anchor_v1' in v_src) > 0 then raise notice 's120: reconcile_inventory_baseline_v1 already carries the hook'; return; end if;
  if md5(v_src) is distinct from '7cbb2ea861268b3fbe848c974e32b2f2' then
    raise exception 's120: public.reconcile_inventory_baseline_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000';
  end if;
  v_new := replace(v_src, replace($f$update public.inventory_items set movement_controlled_at = coalesce(movement_controlled_at, now()), baseline_reviewed_by = auth.uid(), baseline_note = btrim(p_note) where id = p_item_id;$f$, chr(13), ''),
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
  end if;$r$, chr(13), ''));
  if v_new = v_src then raise exception 's120: reconcile patch point not found' using errcode = '55000'; end if;
  execute format($e$create or replace function public.reconcile_inventory_baseline_v1(p_item_id uuid, p_counted_qty numeric, p_note text, p_idempotency_key text)
    returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
end $g$;
revoke all on function public.reconcile_inventory_baseline_v1(uuid, numeric, text, text) from public, anon, service_role;
grant execute on function public.reconcile_inventory_baseline_v1(uuid, numeric, text, text) to authenticated;

-- 3. undoing such a count takes its interval out ------------------------------------------------------------------------------------------------------------------
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.inventory_undo_v1(uuid,uuid)');
  if v_src is null then raise exception 's120: public.inventory_undo_v1 is missing' using errcode = '55000'; end if;
  if position('s_inventory_usage_recompute_v1' in v_src) > 0 then raise notice 's120: inventory_undo_v1 already carries the hook'; return; end if;
  if md5(v_src) is distinct from 'b3923b0bae57e812bb8375eea81f93e9' then
    raise exception 's120: public.inventory_undo_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000';
  end if;
  v_new := replace(v_src, replace($f$select it.qty_on_hand into v_after from public.inventory_items it where it.id = i.id;$f$, chr(13), ''),
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
  select it.qty_on_hand into v_after from public.inventory_items it where it.id = i.id;$r$, chr(13), ''));
  if v_new = v_src then raise exception 's120: undo patch point not found' using errcode = '55000'; end if;
  execute format($e$create or replace function public.inventory_undo_v1(p_movement_id uuid default null, p_purchase_id uuid default null)
    returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
end $g$;
revoke all on function public.inventory_undo_v1(uuid, uuid) from public, anon, service_role;
grant execute on function public.inventory_undo_v1(uuid, uuid) to authenticated;

-- 4. a missed refill: record only ----------------------------------------------------------------------------------------------------------------------------------
create or replace function public.record_missed_refill_v1(p_item_id uuid, p_qty numeric)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  i public.inventory_items%rowtype;
  x public.inventory_usage_intervals%rowtype;
  v_day date; v_consumed numeric; v_recv numeric; v_same boolean; v_reason text; v_ok boolean; v_pred numeric;
begin
  select * into i from public.inventory_items where id = p_item_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('manage_inventory', i.property_id);
  -- NaN is greater than every number, so the upper bound refuses it too
  if p_qty is null or p_qty <= 0 or p_qty >= 100000000 or p_qty <> round(p_qty, 2) then
    raise exception using errcode = '22023', message = 'refill quantity must be above 0, below 100000000, with at most 2 decimals';
  end if;
  if i.movement_controlled_at is not null or not i.is_consumable or not i.is_active then
    return jsonb_build_object('ok', false, 'reason', 'not_learning');
  end if;

  -- the newest interval decides
  select * into x from public.inventory_usage_intervals y where y.item_id = i.id order by y.anchor_at desc limit 1;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_waiting'); end if;
  if x.refill_recorded_qty = p_qty then return jsonb_build_object('ok', true, 'replayed', true); end if;
  if x.reject_reason is distinct from 'unrecorded restock' then return jsonb_build_object('ok', false, 'reason', 'not_waiting'); end if;

  v_consumed := x.qty_prev + x.received_between + p_qty - x.qty_now;
  if v_consumed < 0 then
    return jsonb_build_object('ok', false, 'reason', 'too_small', 'minimum', x.qty_now - x.qty_prev - x.received_between);
  end if;
  v_recv := x.received_between + p_qty;

  -- the same reasons, in the same order, as record_inventory_anchor_v1 (the consumed test above is its first)
  v_day := (x.prev_anchor_at at time zone 'Asia/Manila')::date;
  v_same := exists (select 1 from public.inventory_purchases p
                     where p.item_id = i.id and p.created_at > x.prev_anchor_at and p.created_at <= x.anchor_at
                       and public.s_inventory_received_date_v1(p.purchased_at, p.created_at) = v_day);
  if v_same then v_reason := 'same-day purchase';
  elsif x.days < 7 then v_reason := 'too short';
  elsif x.turnovers < 3 then v_reason := 'too few turnovers';
  end if;
  v_ok := v_reason is null;
  if v_ok and i.consumption_per_booking > 0 then v_pred := i.consumption_per_booking * x.turnovers; end if;

  update public.inventory_usage_intervals
     set received_between = v_recv, refill_recorded_qty = p_qty, consumed = v_consumed, accepted = v_ok, reject_reason = v_reason, predicted = v_pred
   where id = x.id;
  -- the refill mark, under the guard the receipt path uses (only when empty or not newer)
  update public.inventory_items set last_refill_at = x.anchor_at, last_refill_qty = p_qty
   where id = i.id and (last_refill_at is null or last_refill_at <= x.anchor_at);
  perform public.s_inventory_usage_recompute_v1(i.id, x.anchor_at);
  insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor)
  values ('inventory_items', i.id, 'missed_refill',
          jsonb_build_object('interval_id', x.id, 'accepted', x.accepted, 'reason', x.reject_reason, 'consumed', x.consumed, 'received', x.received_between),
          jsonb_build_object('refill_qty', p_qty, 'accepted', v_ok, 'reason', v_reason, 'consumed', v_consumed, 'received', v_recv),
          coalesce(auth.uid()::text, 'admin'));
  return jsonb_build_object('ok', true, 'accepted', v_ok, 'reason', v_reason, 'consumed', v_consumed, 'received', v_recv);
end $$;

comment on function public.record_missed_refill_v1(uuid, numeric) is
  'S120: an admin (manage_inventory) records the refill behind the newest count of an item (reason unrecorded restock). Stock and purchases are never written; the interval, the refill mark, the rate and one audit row are. Replay-safe by the recorded qty.';
revoke all on function public.record_missed_refill_v1(uuid, numeric) from public, anon, authenticated, service_role;
grant execute on function public.record_missed_refill_v1(uuid, numeric) to authenticated;

-- 5. KPI: an ordinary purchase no longer clears the prompt -------------------------------------------------------------------------------------------------------
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.get_inventory_usage_kpi_v1(uuid)');
  if v_src is null then raise exception 's120: public.get_inventory_usage_kpi_v1 is missing' using errcode = '55000'; end if;
  if position('inventory_purchases' in v_src) = 0 then raise notice 's120: the KPI already ignores ordinary purchases'; return; end if;
  if md5(v_src) is distinct from 'f0a2052c3ccc56673808d000ba21d189' then
    raise exception 's120: public.get_inventory_usage_kpi_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000';
  end if;
  v_new := replace(v_src, replace($f$-- the newest interval of the item was rejected as an unrecorded restock and nothing has been recorded since that count$f$, chr(13), ''),
    replace($r$-- the newest interval of the item was rejected as an unrecorded restock and the refill is not recorded yet: only a missed refill (record_missed_refill_v1) or a newer count ends the prompt, an ordinary purchase does not (the count already holds its stock)$r$, chr(13), ''));
  if v_new = v_src then raise exception 's120: KPI comment patch point not found' using errcode = '55000'; end if;
  v_src := v_new;
  v_new := regexp_replace(v_src, $re$\n\s+and not exists \(select 1 from public\.inventory_purchases p where p\.item_id = i\.id and p\.created_at > x\.anchor_at\)\) w;$re$, ') w;');
  if v_new = v_src or position('inventory_purchases' in v_new) > 0 then raise exception 's120: KPI purchase condition not found' using errcode = '55000'; end if;
  execute format($e$create or replace function public.get_inventory_usage_kpi_v1(p_property_id uuid)
    returns jsonb language plpgsql stable security definer set search_path = '' as %L$e$, v_new);
end $g$;
comment on function public.get_inventory_usage_kpi_v1(uuid) is
  'S120: usage-learning KPI (read_operations). itemsMeasured of itemsTotal, medianForecastError (null with no sample), items under 14 days of stock at the learned rate, items waiting for a recorded refill (the newest count was an unrecorded restock; ends with record_missed_refill_v1 or a newer count, not with an ordinary purchase).';
revoke all on function public.get_inventory_usage_kpi_v1(uuid) from public, anon, service_role;
grant execute on function public.get_inventory_usage_kpi_v1(uuid) to authenticated;

-- 6. self-check ------------------------------------------------------------------------------------------------------------------------------------------------------
do $v$
begin
  if position('record_inventory_anchor_v1' in (select p.prosrc from pg_proc p where p.oid = 'public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)'::regprocedure)) = 0 then
    raise exception 's120: the count route lacks the anchor hook';
  end if;
  if position('app_count' in (select p.prosrc from pg_proc p where p.oid = 'public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)'::regprocedure)) = 0
     or position('app_count_undo' in (select p.prosrc from pg_proc p where p.oid = 'public.inventory_undo_v1(uuid,uuid)'::regprocedure)) = 0
     or position('s_inventory_refill_mark_sync_v1' in (select p.prosrc from pg_proc p where p.oid = 'public.s_inventory_refill_mark_after_delete_v1()'::regprocedure)) = 0 then
    raise exception 's120: the app count audit rows or the refill mark helper are missing';
  end if;
  if position('s_inventory_usage_recompute_v1' in (select p.prosrc from pg_proc p where p.oid = 'public.inventory_undo_v1(uuid,uuid)'::regprocedure)) = 0 then
    raise exception 's120: the undo lacks the interval clean-up';
  end if;
  if position('inventory_purchases' in (select p.prosrc from pg_proc p where p.oid = 'public.get_inventory_usage_kpi_v1(uuid)'::regprocedure)) > 0 then
    raise exception 's120: the KPI still reads ordinary purchases';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'inventory_usage_intervals' and column_name = 'refill_recorded_qty') then
    raise exception 's120: refill_recorded_qty is missing';
  end if;
end $v$;

commit;
