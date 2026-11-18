-- 20261120000000_s120_usage_learning.sql
-- Session 120 (lane S): release s120_usage_learning_20261120. Spec docs/s118/SPEC-usage-learning.md (APPROVED), baselines docs/s118/BASELINE-usage-per-turnover.md.
-- Consumable usage per turnover now learns from counts and refills. Every consumable carried consumption_per_booking = 2.00 (an unset default), so coverage read "1 to 2 days".
-- Revised after the Opus review of 44e6647 (docs/s120/review-lane-S-1.md, NO_GO): findings 1-6 and 8-14 are fixed here. Finding 7 (the daily-digest stock alert threshold) is Lloyd's decision and is NOT touched.
-- NOT built: units_per_pack (brief item 9). The item-level units_per_purchase already converts packs to base units on every receive path, and the interval maths reads base units only.
--
-- WHAT THIS ADDS (all additive; no existing signature, grant or result key changes)
--   inventory_items.consumption_per_booking   numeric(10,2) -> numeric(10,4) FIRST (learned rates run from 0.01 to 4; two decimals cut 0.0048 to 0.00 and 0.116 to 0.12)
--   inventory_items       + usage_baseline_per_turnover, usage_baseline_note, usage_state (baseline | learning | measured), last_refill_at, last_refill_qty, usage_updated_at
--   inventory_usage_intervals   one row per anchor (RLS on, no grant to any API role; read only through get_inventory_usage_kpi_v1)
--   record_inventory_anchor_v1(item, qty_now, anchor_at, source)   internal, no grants. source 'count': closes an interval against the previous anchor, accepts it when
--                         days >= 7 and turnovers >= 3 and consumed >= 0, then recomputes the learned rate. source 'receipt': marks the refill only (see below).
--   s_inventory_usage_recompute_v1(item, at)   internal, no grants. rate = (baseline*10 + sum consumed) / (10 + sum turnovers) over accepted intervals in the 90 days to `at`;
--                         once the accepted intervals cover >= 60 days (each interval clamped to the 90-day window) the state is 'measured' and the prior drops out (pure 90-day
--                         average) when the sum consumed is above 0; a measured item with zero usage keeps the prior formula (a rate of 0 would read "not enough history"). Writes consumption_per_booking.
--                         record_inventory_anchor_v1 skips movement-controlled, non-consumable and inactive items; a count at the same instant as a stored anchor is a duplicate;
--                         a count older than the newest anchor returns {ok:true, skipped:'older_than_latest'} (it would rewrite history).
--   inventory_usage_quarterly_reset_v1()   internal, no grants; pg_cron job inventory-usage-quarterly-reset (1 Jan/Apr/Jul/Oct 20:00 UTC) when pg_cron exists. Recomputes every
--                         learning or measured item at now(), so an item nobody counted for 90 days falls back to its baseline.
--   inventory_purchases AFTER DELETE trigger: an undone receipt recomputes last_refill_at / last_refill_qty from the purchases that remain.
--   get_inventory_usage_kpi_v1(property)   admin read (read_operations): measured / total, median forecast error, items under 14 days, items waiting for a recorded refill.
--   Hooks (one block each, after the work of the function is done, any error becomes a WARNING and never blocks a count or a receipt):
--       s_apply_inventory_count_core_v1       per counted row               -> record_inventory_anchor_v1(.., counted, as_of or now(), 'count')
--       record_inventory_receipt_v1           admin receipt                 -> record_inventory_anchor_v1(.., units received, now(), 'receipt')
--       apply_inventory_purchase              Telegram OCR restock          -> same
--       s_inventory_receipt_apply_v1          staff receipt draft confirm   -> same
--   get_inventory_catalogue_v1  + usageState, usagePerTurnover, usageBaseline, lastRefillAt, lastRefillQty, lastCountAt, usageCounts (existing keys untouched;
--                         usageCounts = accepted intervals of the last 90 days, the "3 counts" of the approved mockup)
--   Seed: baselines for the 22 consumables (BASELINE-usage-per-turnover.md); consumption_per_booking = baseline where it was the 2.00 default or null.
--   Backfill: the telegram_count audit rows from 2026-10-27 are replayed through record_inventory_anchor_v1 (27 Oct and 18 Nov counts).
--
-- DESIGN CHOICES THE REVIEW SHOULD KNOW
--   * Anchors are PHYSICAL counts only. qty_on_hand between counts is not physical truth (usage logging stopped, receipts and edits move it), so a receipt does not start or
--     close an interval: it sets last_refill_at (the PURCHASE date, not the entry time) / last_refill_qty, and the next count sums every purchase recorded since the previous count
--     (received_between). received_between = inventory_purchases.qty (base units, already pack-converted by every receive path) with created_at in the window and purchased_at
--     not before the previous anchor's Manila date (a back-dated purchase was already on the shelf at that count), except Telegram OCR rows, which are read from the
--     ocr_restock audit row exactly as inventory_qty_at_v1 does (rows before 20261020 held packs) under the same date rule.
--   * Turnovers of an interval are the cleaning sessions whose EFFECTIVE time falls in (previous anchor, this anchor]. A report entered late is dated by its stay, not by when it was
--     typed: effective time = the earlier of cleaned_at and the end of the checkout_date (Manila); with no checkout_date it is cleaned_at. (A plain checkout_date comparison would count 12 for
--     27 Oct to 18 Nov, because one stay checked out on 18 Nov and was cleaned at 22:03 after the count; the effective time counts it by its stay.)
--   * qty_now of a count is the counted figure at as_of (or now); qty_prev is the previous anchor's qty_now. The 27 Oct 'count of 16 Oct printout recorded as current stock' anchors at the
--     printout, 16 Oct 08:21 Manila (D-351: the inventory is 16 Oct and later consumptions count against that list), so the first interval runs 16 Oct to 18 Nov (17 turnovers).
--   * A count that is not older than the previous anchor never reuses the same instant: (item_id, anchor_at) is unique, a replay is a no-op (idempotent).
--   * Rejected intervals still move the anchor (spec): 'too short', 'too few turnovers' and 'unrecorded restock' (consumed < 0, purchase nobody recorded) are kept as rows and never learned.
--   * With no accepted interval in the 90-day window the item falls back to state 'baseline' and consumption_per_booking = its baseline.
--   * A baseline of null (no research figure) learns the pure average (no prior); with no accepted interval consumption_per_booking is left as it is.
--   * Movement-controlled items are skipped (their ledger is the measurement). Inactive items are skipped by the backfill, so the 18 Nov split (old "Tissues / Paper Towels"
--     inactive at 0, new "Bathroom tissue" and "Kitchen towel" first counted) invents no usage: new items start with a first anchor only.
--   * consumption_per_booking is read by daily-digest (runway = qty / cpb * days) and telegram-expense (short = qty < cpb). Real rates (0.01 to 4) make both quieter than the 2.00 default did.
--     D-375: the deployed digest (waves repo) names stock only when an item is out, so these rates silence nothing there. In telegram-expense only the "may run short" note moves.
--     s_inventory_low_task_v1 and the Telegram low list use reorder_below and are unaffected.
--   * A count made through reconcile_inventory_baseline_v1 (admin counts page, staff stock screen) sets movement_controlled_at and takes the item out of learning; only the Telegram
--     count path feeds it. The self-check therefore looks only at intervals created after an item became controlled.
--
-- GUARDS (55000, nothing changes): every replaced body must be the live body (md5 of prosrc, CR stripped), read on production 2026-11-18, or already carry this release's hook (re-run).
--   s_apply_inventory_count_core_v1        3937a6da154fe1ed60471689833f96e2   (20261103000000_s99f_count_as_of.sql)
--   record_inventory_receipt_v1 (9 args)   7cb59453f37eeeeb15b1e9f4c4ffa883   (20261026000000_s91_kpi_fixes.sql)
--   apply_inventory_purchase (7 args)      48082c76263e15517d733c65f7eb3ccc   (20261020000000_s86_inventory_db.sql)
--   s_inventory_receipt_apply_v1           4f09a8ae895d945703f60a96705413e7   (20261112000000_s110_kpi_supply_laundry.sql)
--   get_inventory_catalogue_v1             00ca41d933a5c5a9c4498cff682e7844   (20261020000000_s86_inventory_db.sql)
-- Each replacement is the live body with ONE inserted block (patched in place inside a DO, so the migration starts from whatever the live body is, never from a stale copy).
-- Grants restated (ML-21) for every function this file creates or replaces.
-- Rollback: supabase/rollbacks/20261120_s120_usage_learning.sql (DATA LOSS by design: the intervals and the learned values).
--
-- FORWARD CHECKS (also in supabase/releases/20261120_s120_usage_learning.release.json):
--   select count(*) = 6 from information_schema.columns where table_schema = 'public' and table_name = 'inventory_items' and column_name in
--     ('usage_baseline_per_turnover','usage_baseline_note','usage_state','last_refill_at','last_refill_qty','usage_updated_at');
--   select relrowsecurity from pg_class where oid = 'public.inventory_usage_intervals'::regclass;
--   select count(*) = 4 from pg_proc where prosrc like '%record_inventory_anchor_v1%' and proname in
--     ('s_apply_inventory_count_core_v1','record_inventory_receipt_v1','apply_inventory_purchase','s_inventory_receipt_apply_v1');
--   select numeric_scale = 4 from information_schema.columns where table_schema = 'public' and table_name = 'inventory_items' and column_name = 'consumption_per_booking';
--   the replayed rates of Laundry Detergent, Hand Soap and Insect Spray: 1.5926, 0.1074, 0.0556 (17 turnovers; consumed 23, 2, 1 against baselines 2.0, 0.09, 0.05)

begin;

-- 1. columns ---------------------------------------------------------------------------------------------------------------------------------------------------
-- numeric(10,2) cut every learned rate to two decimals: widen it before anything is seeded. No view depends on the column (checked on production 2026-11-18).
alter table public.inventory_items alter column consumption_per_booking type numeric(10,4);

alter table public.inventory_items
  add column if not exists usage_baseline_per_turnover numeric check (usage_baseline_per_turnover is null or usage_baseline_per_turnover >= 0),
  add column if not exists usage_baseline_note text,
  add column if not exists usage_state text not null default 'baseline' check (usage_state in ('baseline', 'learning', 'measured')),
  add column if not exists last_refill_at timestamptz,
  add column if not exists last_refill_qty numeric check (last_refill_qty is null or last_refill_qty >= 0),
  add column if not exists usage_updated_at timestamptz;

-- 2. intervals -------------------------------------------------------------------------------------------------------------------------------------------------
create table if not exists public.inventory_usage_intervals (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  item_id uuid not null references public.inventory_items(id),
  prev_anchor_at timestamptz,
  anchor_at timestamptz not null,
  qty_prev numeric,
  received_between numeric not null default 0 check (received_between >= 0),
  qty_now numeric not null check (qty_now >= 0),
  consumed numeric,
  days numeric,
  turnovers integer,
  predicted numeric,
  accepted boolean not null default false,
  reject_reason text,
  source text not null check (source in ('count')),
  created_at timestamptz not null default now(),
  constraint inventory_usage_intervals_item_anchor_uq unique (item_id, anchor_at),
  constraint inventory_usage_intervals_reason check (accepted or reject_reason is not null),
  constraint inventory_usage_intervals_accepted_shape check (not accepted or (consumed >= 0 and days >= 7 and turnovers >= 3))
);
create index if not exists inventory_usage_intervals_item_idx on public.inventory_usage_intervals (item_id, anchor_at desc);
create index if not exists inventory_usage_intervals_property_idx on public.inventory_usage_intervals (property_id, anchor_at desc);
alter table public.inventory_usage_intervals enable row level security;
revoke all on table public.inventory_usage_intervals from public, anon, authenticated, service_role;
comment on table public.inventory_usage_intervals is
  'S120: one row per physical count of a consumable. The first count of an item is reject_reason first anchor. Later rows hold consumed = qty_prev + received_between - qty_now over days and turnovers; accepted only when days >= 7, turnovers >= 3, consumed >= 0. No API grant: read through get_inventory_usage_kpi_v1.';

-- 3. internal: recompute the learned rate ----------------------------------------------------------------------------------------------------------------------
create or replace function public.s_inventory_usage_recompute_v1(p_item_id uuid, p_at timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
declare
  i public.inventory_items%rowtype;
  v_n integer; v_sum numeric; v_turn numeric; v_days numeric; v_state text; v_rate numeric;
begin
  select * into i from public.inventory_items where id = p_item_id;
  if not found then return; end if;
  -- days of each interval are clamped to the 90-day window (an interval that started before it only counts for the part inside)
  select count(*), coalesce(sum(x.consumed), 0), coalesce(sum(x.turnovers), 0),
         coalesce(sum(least(x.days, extract(epoch from (x.anchor_at - (p_at - interval '90 days'))) / 86400.0)), 0)
    into v_n, v_sum, v_turn, v_days
    from public.inventory_usage_intervals x
   where x.item_id = p_item_id and x.accepted and x.anchor_at <= p_at and x.anchor_at > p_at - interval '90 days';
  if v_n = 0 then
    v_state := 'baseline';
    v_rate := i.usage_baseline_per_turnover;
  else
    v_state := case when v_days >= 60 then 'measured' else 'learning' end;
    -- an accepted interval has turnovers >= 3 (table check), so v_turn > 0.
    -- The pure average only when something was used: a rate of 0 reads "not enough history" downstream and orders stock daily, so a zero-usage item keeps the prior formula.
    v_rate := case when v_state = 'measured' and v_sum > 0 then v_sum / v_turn
                   when i.usage_baseline_per_turnover is null then nullif(v_sum, 0) / v_turn
                   else (i.usage_baseline_per_turnover * 10 + v_sum) / (10 + v_turn) end;
  end if;
  update public.inventory_items
     set usage_state = v_state, consumption_per_booking = coalesce(round(v_rate, 4), consumption_per_booking), usage_updated_at = now()
   where id = p_item_id;
end $$;

comment on function public.s_inventory_usage_recompute_v1(uuid, timestamptz) is
  'S120: learned rate from accepted intervals in the 90 days to p_at. learning = (baseline*10 + sum consumed) / (10 + sum turnovers); measured (accepted intervals cover >= 60 days inside the window) = pure sum consumed / sum turnovers when the sum is above 0; none = the baseline.';
revoke all on function public.s_inventory_usage_recompute_v1(uuid, timestamptz) from public, anon, authenticated, service_role;

-- 4. internal: the anchor --------------------------------------------------------------------------------------------------------------------------------------
-- p_source 'count': p_qty_now is the counted quantity at p_anchor_at. 'receipt': p_qty_now is the base units received (sets last_refill_at / last_refill_qty only).
create or replace function public.record_inventory_anchor_v1(p_item_id uuid, p_qty_now numeric, p_anchor_at timestamptz, p_source text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  i public.inventory_items%rowtype;
  v_prev public.inventory_usage_intervals%rowtype;
  v_recv numeric; v_consumed numeric; v_days numeric; v_turn integer; v_ok boolean; v_reason text; v_pred numeric; v_id uuid;
begin
  if p_item_id is null or p_anchor_at is null or p_source is null or p_source not in ('count', 'receipt') then
    return jsonb_build_object('ok', false, 'reason', 'bad_args');
  end if;
  select * into i from public.inventory_items where id = p_item_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'item_not_found'); end if;
  if i.movement_controlled_at is not null then return jsonb_build_object('ok', true, 'skipped', 'movement_controlled'); end if;
  if not i.is_consumable or not i.is_active then return jsonb_build_object('ok', true, 'skipped', 'not_active_consumable'); end if;
  if p_qty_now is null or p_qty_now < 0 then return jsonb_build_object('ok', false, 'reason', 'bad_qty'); end if;

  if p_source = 'receipt' then
    -- p_anchor_at is the PURCHASE date (Manila midnight), not the entry time
    update public.inventory_items set last_refill_at = p_anchor_at, last_refill_qty = p_qty_now
     where id = i.id and (last_refill_at is null or last_refill_at <= p_anchor_at);
    return jsonb_build_object('ok', true, 'refill', true);
  end if;

  -- an exact replay is a duplicate; a count older than the newest anchor would rewrite history (usage and turnovers counted twice) and is skipped
  if exists (select 1 from public.inventory_usage_intervals x where x.item_id = i.id and x.anchor_at = p_anchor_at) then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  if exists (select 1 from public.inventory_usage_intervals x where x.item_id = i.id and x.anchor_at > p_anchor_at) then
    return jsonb_build_object('ok', true, 'skipped', 'older_than_latest');
  end if;

  select * into v_prev from public.inventory_usage_intervals x where x.item_id = i.id and x.anchor_at < p_anchor_at order by x.anchor_at desc limit 1;
  if not found then
    insert into public.inventory_usage_intervals(property_id, item_id, anchor_at, qty_now, accepted, reject_reason, source)
    values (i.property_id, i.id, p_anchor_at, p_qty_now, false, 'first anchor', 'count')
    on conflict (item_id, anchor_at) do nothing returning id into v_id;
    return jsonb_build_object('ok', true, 'first_anchor', v_id is not null, 'duplicate', v_id is null);
  end if;

  -- received between the two anchors, in base units; Telegram OCR rows come from the audit row (their purchase row held packs before 20261020), a purchase undone since is ignored
  -- A purchase dated before the previous count was already on the shelf at that count (a refill recorded late), so it is not "received between".
  v_recv := coalesce((select sum(p.qty) from public.inventory_purchases p
                       where p.item_id = i.id and p.created_at > v_prev.anchor_at and p.created_at <= p_anchor_at
                         and coalesce(p.purchased_at, (p.created_at at time zone 'Asia/Manila')::date) >= (v_prev.anchor_at at time zone 'Asia/Manila')::date
                         and coalesce(p.notes, '') not like 'Auto-restock from receipt OCR%'), 0)
          + coalesce((select sum((a.after ->> 'qty_added')::numeric) from public.inventory_audit_log a
                       where a.entity_type = 'inventory_items' and a.entity_id = i.id and a.action = 'ocr_restock'
                         and a.created_at > v_prev.anchor_at and a.created_at <= p_anchor_at
                         and exists (select 1 from public.inventory_purchases p where p.id::text = a.after ->> 'purchase_id'
                                        and coalesce(p.purchased_at, (p.created_at at time zone 'Asia/Manila')::date) >= (v_prev.anchor_at at time zone 'Asia/Manila')::date)), 0);
  v_consumed := v_prev.qty_now + v_recv - p_qty_now;
  v_days := round(extract(epoch from (p_anchor_at - v_prev.anchor_at)) / 86400.0, 2);
  -- turnovers dated by the stay: a report typed late counts in the interval its stay ended in (effective time = the earlier of cleaned_at and the end of the checkout_date, Manila)
  -- A report typed after the previous count for a stay that ended before it (cleaned_at in this interval, eff in the interval before) belongs to no earlier interval, so it counts here once
  -- (only when the previous anchor itself closed an interval: the first anchor stays excluded). One turnover per stay: duplicate rows of one checkout_date count once; undated sessions count each.
  select count(distinct s.checkout_date) + count(*) filter (where s.checkout_date is null) into v_turn from (
    select cs.checkout_date, cs.cleaned_at,
           least(cs.cleaned_at, coalesce(((cs.checkout_date + 1)::timestamp at time zone 'Asia/Manila') - interval '1 second', cs.cleaned_at)) as eff
      from public.cleaning_sessions cs
     where cs.property_id = i.property_id and coalesce(cs.cleaning_type, 'turnover') in ('turnover', 'deep_clean')) s
   where (s.eff > v_prev.anchor_at and s.eff <= p_anchor_at)
      or (v_prev.prev_anchor_at is not null and s.cleaned_at > v_prev.anchor_at and s.cleaned_at <= p_anchor_at
          and s.eff > v_prev.prev_anchor_at and s.eff <= v_prev.anchor_at);
  if v_consumed < 0 then v_reason := 'unrecorded restock';
  elsif v_days < 7 then v_reason := 'too short';
  elsif v_turn < 3 then v_reason := 'too few turnovers';
  end if;
  v_ok := v_reason is null;
  -- what the rate in force before this count predicted for these turnovers (the forecast error the KPI reports)
  if v_ok and i.consumption_per_booking is not null then v_pred := i.consumption_per_booking * v_turn; end if;

  insert into public.inventory_usage_intervals(property_id, item_id, prev_anchor_at, anchor_at, qty_prev, received_between, qty_now, consumed, days, turnovers, predicted, accepted, reject_reason, source)
  values (i.property_id, i.id, v_prev.anchor_at, p_anchor_at, v_prev.qty_now, v_recv, p_qty_now, v_consumed, v_days, v_turn, v_pred, v_ok, v_reason, 'count')
  on conflict (item_id, anchor_at) do nothing returning id into v_id;
  if v_id is null then return jsonb_build_object('ok', true, 'duplicate', true); end if;

  perform public.s_inventory_usage_recompute_v1(i.id, p_anchor_at);
  return jsonb_build_object('ok', true, 'accepted', v_ok, 'reason', v_reason, 'consumed', v_consumed, 'days', v_days, 'turnovers', v_turn, 'received', v_recv);
end $$;

comment on function public.record_inventory_anchor_v1(uuid, numeric, timestamptz, text) is
  'S120: closes the usage interval for a physical count (source count) or marks a refill (source receipt). Internal: called by the count core and the receive paths only. Skips movement-controlled items. Idempotent per (item, anchor_at).';
revoke all on function public.record_inventory_anchor_v1(uuid, numeric, timestamptz, text) from public, anon, authenticated, service_role;

-- 5. hooks: each replaced body is the live body with ONE block inserted -----------------------------------------------------------------------------------------
-- 5a. the count core: after the audit row, per counted row
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.s_apply_inventory_count_core_v1(text,jsonb,text,timestamptz,uuid)');
  if v_src is null then raise exception 's120: public.s_apply_inventory_count_core_v1 is missing' using errcode = '55000'; end if;
  if position('record_inventory_anchor_v1' in v_src) > 0 then raise notice 's120: count core already carries the hook'; return; end if;
  if md5(v_src) is distinct from '3937a6da154fe1ed60471689833f96e2' then
    raise exception 's120: public.s_apply_inventory_count_core_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000';
  end if;
  v_new := replace(v_src, $f$    v_out := v_out || jsonb_build_object('name', it.name, 'before', it.qty_on_hand, 'after', v_new,$f$, $r$    -- S120: a physical count is an anchor for the usage learning; a problem here must never block a count
    begin
      perform public.record_inventory_anchor_v1(it.id, v_counted, coalesce(p_as_of, now()), 'count');
    exception when others then
      raise warning 's120 usage anchor (count): % (%)', sqlerrm, sqlstate;
    end;
    v_out := v_out || jsonb_build_object('name', it.name, 'before', it.qty_on_hand, 'after', v_new,$r$);
  if v_new = v_src then raise exception 's120: count core patch point not found' using errcode = '55000'; end if;
  execute format($e$create or replace function public.s_apply_inventory_count_core_v1(p_actor text, p_rows jsonb, p_note text, p_as_of timestamptz, p_access_user uuid default null)
    returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
end $g$;
revoke all on function public.s_apply_inventory_count_core_v1(text, jsonb, text, timestamptz, uuid) from public, anon, authenticated, service_role;

-- 5b. admin receipt
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid)');
  if v_src is null then raise exception 's120: public.record_inventory_receipt_v1 is missing' using errcode = '55000'; end if;
  if position('record_inventory_anchor_v1' in v_src) > 0 then raise notice 's120: record_inventory_receipt_v1 already carries the hook'; return; end if;
  if md5(v_src) is distinct from '7cb59453f37eeeeb15b1e9f4c4ffa883' then
    raise exception 's120: public.record_inventory_receipt_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000';
  end if;
  v_new := replace(v_src, $f$  return jsonb_build_object('ok', true, 'purchaseId', v_pid, 'movementId', v_mid, 'unitsAdded', v_units, 'controlled', i.movement_controlled_at is not null);$f$, $r$  -- S120: remember the refill for the usage learning; a problem here must never block a receipt
  begin
    perform public.record_inventory_anchor_v1(p_item_id, v_units, (coalesce(p_purchased_at, public.manila_today())::timestamp at time zone 'Asia/Manila'), 'receipt');
  exception when others then
    raise warning 's120 usage anchor (receipt): % (%)', sqlerrm, sqlstate;
  end;
  return jsonb_build_object('ok', true, 'purchaseId', v_pid, 'movementId', v_mid, 'unitsAdded', v_units, 'controlled', i.movement_controlled_at is not null);$r$);
  if v_new = v_src then raise exception 's120: receipt patch point not found' using errcode = '55000'; end if;
  execute format($e$create or replace function public.record_inventory_receipt_v1(p_item_id uuid, p_packs numeric, p_unit_cost numeric, p_supplier text, p_purchased_at date, p_receipt_path text, p_shopping_list_id uuid, p_idempotency_key text, p_supplier_id uuid default null)
    returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
end $g$;
revoke all on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid) from public, anon, service_role;
grant execute on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid) to authenticated;

-- 5c. Telegram OCR restock
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.apply_inventory_purchase(uuid,numeric,numeric,text,date,uuid,uuid)');
  if v_src is null then raise exception 's120: public.apply_inventory_purchase is missing' using errcode = '55000'; end if;
  if position('record_inventory_anchor_v1' in v_src) > 0 then raise notice 's120: apply_inventory_purchase already carries the hook'; return; end if;
  if md5(v_src) is distinct from '48082c76263e15517d733c65f7eb3ccc' then
    raise exception 's120: public.apply_inventory_purchase is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000';
  end if;
  v_new := replace(v_src, $f$  return jsonb_build_object('ok', true, 'name', v_name, 'purchase_id', v_pid,$f$, $r$  -- S120: remember the refill for the usage learning; a problem here must never block a restock
  begin
    perform public.record_inventory_anchor_v1(p_item_id, p_qty * v_upp, (coalesce(p_purchased_at, public.manila_today())::timestamp at time zone 'Asia/Manila'), 'receipt');
  exception when others then
    raise warning 's120 usage anchor (ocr restock): % (%)', sqlerrm, sqlstate;
  end;
  return jsonb_build_object('ok', true, 'name', v_name, 'purchase_id', v_pid,$r$);
  if v_new = v_src then raise exception 's120: apply_inventory_purchase patch point not found' using errcode = '55000'; end if;
  execute format($e$create or replace function public.apply_inventory_purchase(p_item_id uuid, p_qty numeric, p_unit_cost numeric, p_supplier text, p_purchased_at date, p_txn_id uuid, p_supplier_id uuid default null)
    returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
end $g$;
revoke all on function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid, uuid) from public, anon, authenticated;
grant execute on function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid, uuid) to service_role;

-- 5d. staff receipt draft confirm (internal)
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.s_inventory_receipt_apply_v1(uuid,numeric,numeric,text,uuid,date,text,uuid)');
  if v_src is null then raise exception 's120: public.s_inventory_receipt_apply_v1 is missing' using errcode = '55000'; end if;
  if position('record_inventory_anchor_v1' in v_src) > 0 then raise notice 's120: s_inventory_receipt_apply_v1 already carries the hook'; return; end if;
  if md5(v_src) is distinct from '4f09a8ae895d945703f60a96705413e7' then
    raise exception 's120: public.s_inventory_receipt_apply_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000';
  end if;
  v_new := replace(v_src, $f$  return v_pid;$f$, $r$  -- S120: remember the refill for the usage learning; a problem here must never block a receipt
  begin
    perform public.record_inventory_anchor_v1(p_item_id, p_units, (coalesce(p_date, public.manila_today())::timestamp at time zone 'Asia/Manila'), 'receipt');
  exception when others then
    raise warning 's120 usage anchor (staff receipt): % (%)', sqlerrm, sqlstate;
  end;
  return v_pid;$r$);
  if v_new = v_src then raise exception 's120: s_inventory_receipt_apply_v1 patch point not found' using errcode = '55000'; end if;
  execute format($e$create or replace function public.s_inventory_receipt_apply_v1(p_item_id uuid, p_units numeric, p_cost numeric, p_vendor text, p_supplier_id uuid, p_date date, p_path text, p_draft_id uuid)
    returns uuid language plpgsql security definer set search_path = '' as %L$e$, v_new);
end $g$;
revoke all on function public.s_inventory_receipt_apply_v1(uuid, numeric, numeric, text, uuid, date, text, uuid) from public, anon, authenticated, service_role;

-- 5e. an undone receipt recomputes the refill mark from the purchases that remain ---------------------------------------------------------------------------------
create or replace function public.s_inventory_refill_mark_after_delete_v1()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.inventory_items i
     set last_refill_at = (select (p.purchased_at::timestamp at time zone 'Asia/Manila') from public.inventory_purchases p where p.item_id = old.item_id order by p.purchased_at desc, p.created_at desc limit 1),
         last_refill_qty = (select p.qty from public.inventory_purchases p where p.item_id = old.item_id order by p.purchased_at desc, p.created_at desc limit 1)
   where i.id = old.item_id and i.last_refill_at is not null;
  return null;
end $$;
revoke all on function public.s_inventory_refill_mark_after_delete_v1() from public, anon, authenticated, service_role;
drop trigger if exists s120_refill_mark_after_delete on public.inventory_purchases;
create trigger s120_refill_mark_after_delete after delete on public.inventory_purchases
  for each row execute function public.s_inventory_refill_mark_after_delete_v1();

-- 6. the catalogue, additive: seven new keys after baselineNote --------------------------------------------------------------------------------------------------
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.get_inventory_catalogue_v1(uuid)');
  if v_src is null then raise exception 's120: public.get_inventory_catalogue_v1 is missing' using errcode = '55000'; end if;
  if position('usageState' in v_src) > 0 then raise notice 's120: catalogue already carries the usage keys'; return; end if;
  if md5(v_src) is distinct from '00ca41d933a5c5a9c4498cff682e7844' then
    raise exception 's120: public.get_inventory_catalogue_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000';
  end if;
  v_new := replace(v_src, $f$'baselineNote', i.baseline_note,$f$, $r$'baselineNote', i.baseline_note,
    'usageState', i.usage_state, 'usagePerTurnover', i.consumption_per_booking, 'usageBaseline', i.usage_baseline_per_turnover,
    'lastRefillAt', i.last_refill_at, 'lastRefillQty', i.last_refill_qty,
    'lastCountAt', (select max(x.anchor_at) from public.inventory_usage_intervals x where x.item_id = i.id and x.source = 'count'),
    'usageCounts', (select count(*) from public.inventory_usage_intervals x where x.item_id = i.id and x.accepted and x.anchor_at > now() - interval '90 days'),$r$);
  if v_new = v_src then raise exception 's120: catalogue patch point not found' using errcode = '55000'; end if;
  execute format($e$create or replace function public.get_inventory_catalogue_v1(p_property_id uuid)
    returns jsonb language plpgsql stable security definer set search_path = '' as %L$e$, v_new);
end $g$;
revoke all on function public.get_inventory_catalogue_v1(uuid) from public, anon, service_role;
grant execute on function public.get_inventory_catalogue_v1(uuid) to authenticated;

-- 7. KPI read --------------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.get_inventory_usage_kpi_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_total integer; v_measured integer; v_learning integer; v_err numeric; v_samples integer; v_rate numeric; v_low jsonb; v_wait jsonb;
begin
  perform public.admin_require('read_operations', p_property_id);
  select count(*), count(*) filter (where i.usage_state = 'measured'), count(*) filter (where i.usage_state = 'learning')
    into v_total, v_measured, v_learning
    from public.inventory_items i
   where i.property_id = p_property_id and i.is_active and i.is_consumable and i.movement_controlled_at is null;

  -- median |predicted - consumed| / consumed over the accepted intervals of the last 90 days that consumed something and had a rate in force
  select round((percentile_cont(0.5) within group (order by e.err))::numeric, 3), count(*)::integer into v_err, v_samples
    from (select abs(x.predicted - x.consumed) / x.consumed as err
            from public.inventory_usage_intervals x join public.inventory_items i on i.id = x.item_id
           where i.property_id = p_property_id and x.accepted and x.predicted is not null and x.consumed > 0
             and x.anchor_at > now() - interval '90 days') e;

  -- days of stock at the learned rate and the same turnover rate the catalogue uses (turnovers of the last 60 days / 60)
  select coalesce(count(*)::numeric / 60, 0) into v_rate from public.cleaning_sessions cs
   where cs.property_id = p_property_id and cs.cleaning_type in ('turnover', 'deep_clean') and cs.cleaned_at >= now() - interval '60 days';
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'daysLeft', t.days) order by t.days, t.name), '[]'::jsonb) into v_low
    from (select i.id, i.name, case when i.consumption_per_booking > 0 and v_rate > 0 then round(i.qty_on_hand / (i.consumption_per_booking * v_rate), 1) end as days
            from public.inventory_items i
           where i.property_id = p_property_id and i.is_active and i.is_consumable and i.movement_controlled_at is null) t
   where t.days < 14;

  -- the newest interval of the item was rejected as an unrecorded restock and nothing has been recorded since that count
  select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name, 'since', w.anchor_at, 'qtyBefore', w.qty_prev, 'qtyNow', w.qty_now) order by w.anchor_at, w.name), '[]'::jsonb) into v_wait
    from (select i.id, i.name, x.anchor_at, x.qty_prev, x.qty_now
            from public.inventory_items i
            join lateral (select y.* from public.inventory_usage_intervals y where y.item_id = i.id order by y.anchor_at desc limit 1) x on true
           where i.property_id = p_property_id and i.is_active and i.is_consumable and i.movement_controlled_at is null
             and x.reject_reason = 'unrecorded restock'
             and not exists (select 1 from public.inventory_purchases p where p.item_id = i.id and p.created_at > x.anchor_at)) w;

  return jsonb_build_object('ok', true, 'asOf', now(),
    'itemsTotal', v_total, 'itemsMeasured', v_measured, 'itemsLearning', v_learning,
    'medianForecastError', v_err, 'forecastSamples', v_samples,
    'underFourteenDays', jsonb_build_object('count', jsonb_array_length(v_low), 'items', v_low),
    'waitingForRefill', jsonb_build_object('count', jsonb_array_length(v_wait), 'items', v_wait));
end $$;

comment on function public.get_inventory_usage_kpi_v1(uuid) is
  'S120: usage-learning KPI (read_operations). itemsMeasured of itemsTotal, medianForecastError (null with no sample), items under 14 days of stock at the learned rate, items waiting for a recorded refill.';
revoke all on function public.get_inventory_usage_kpi_v1(uuid) from public, anon, service_role;
grant execute on function public.get_inventory_usage_kpi_v1(uuid) to authenticated;

-- 8. quarterly reset: the stored rate of a measured item becomes the pure 90-day average --------------------------------------------------------------------------
create or replace function public.inventory_usage_quarterly_reset_v1()
returns integer language plpgsql security definer set search_path = '' as $$
declare v_n integer := 0; r record; v_old numeric; v_new numeric;
begin
  -- the same maths as a count (window of 90 days to now), so an item nobody counted for 90 days falls back to its baseline and a stale 'measured' is demoted
  for r in select i.id from public.inventory_items i where i.usage_state in ('learning', 'measured') and i.movement_controlled_at is null loop
    select i.consumption_per_booking into v_old from public.inventory_items i where i.id = r.id;
    perform public.s_inventory_usage_recompute_v1(r.id, now());
    select i.consumption_per_booking into v_new from public.inventory_items i where i.id = r.id;
    if v_new is distinct from v_old then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end $$;

comment on function public.inventory_usage_quarterly_reset_v1() is
  'S120: every 90 days each learning or measured item is recomputed at now() over its last 90 days (a stale item falls back to its baseline). Returns the number of items whose stored rate changed. Cron only.';
revoke all on function public.inventory_usage_quarterly_reset_v1() from public, anon, authenticated, service_role;

do $c$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron absent (rehearsal copy) - inventory-usage-quarterly-reset wiring skipped';
    return;
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'inventory-usage-quarterly-reset';
  perform cron.schedule('inventory-usage-quarterly-reset', '0 20 1 1,4,7,10 *', $cmd$select public.inventory_usage_quarterly_reset_v1();$cmd$);
  if (select count(*) from cron.job where jobname = 'inventory-usage-quarterly-reset' and active and schedule = '0 20 1 1,4,7,10 *'
        and command like '%inventory_usage_quarterly_reset_v1%') <> 1 then
    raise exception 'inventory-usage-quarterly-reset not scheduled';
  end if;
end $c$;

-- 9. seed the baselines (by exact name; a name that does not match exactly one active item is skipped, never an error) ---------------------------------------------
-- "Hotel Guest Kit (set)" in the research table is the item "Toiletries (toothbrush, toothpaste, soap)": both went 50 -> 2 on 27 Oct, 2 sets per booking.
do $s$
declare r record; v_ids uuid[];
begin
  for r in select * from (values
      ('Laundry Detergent',                         2.0,  '1 sachet (60 ml) per load, 1-2 loads per turnover'),
      ('Insect Spray',                              0.05, 'spray when pests are seen'),
      ('Hand Soap',                                 0.09, '40 ml of a 450 ml bottle'),
      ('Body Wash',                                 0.09, '40 ml of a 450 ml refill'),
      ('Shampoo (Palmolive)',                       0.07, '40 ml of a 600 ml refill'),
      ('Dishwashing Liquid (Joy)',                  0.03, '10 ml of a 375 ml bottle'),
      ('Mr Muscle Glass Cleaner (Blue)',            0.03, '10-15 ml of one bottle'),
      ('Mr Muscle Mold & Mildew (Orange)',          0.03, '10-15 ml of one bottle'),
      ('Mr Muscle Tough Grease & Grime',            0.03, '10-15 ml of one bottle'),
      ('Lysol Disinfectant Spray',                  0.03, '15 g of a 510 g can'),
      ('All-Purpose Cleaner (Mr Muscle)',           0.01, '25 ml concentrate of a 3.7 L bottle'),
      ('Ambi Pur',                                  0.02, '4 g of a 275 g can'),
      ('Natural Air',                               0.10, 'a 180 g gel lasts 14-30 days (time based)'),
      ('Garbage Bags (Large)',                      0.05, '1.5 bags per turnover over a 15-20 bag roll'),
      ('Garbage Bags (Small)',                      0.05, '1.5 bags per turnover over a 15-20 bag roll'),
      ('Bottled Water',                             1.0,  '500 ml; 1 per turnover until counts settle (4 would be one per guest-night)'),
      ('Coffee (3-in-1)',                           4.0,  '1 stick per guest-night'),
      ('Tea',                                       2.0,  'half of the guest-nights'),
      ('Sugar & Creamer Sticks',                    2.0,  'half of the guest-nights'),
      ('Bathroom tissue',                           1.0,  '1 fresh roll per check-in (unit assumed to be a roll)'),
      ('Kitchen towel',                             0.06, '10 pulls of a 175-pull pack'),
      ('Toiletries (toothbrush, toothpaste, soap)', 2.0,  'Hotel Guest Kit: 2 sets per booking, packs of 100')) v(n, b, note)
  loop
    select array_agg(i.id) into v_ids from public.inventory_items i where i.is_active and i.name = r.n;
    if coalesce(array_length(v_ids, 1), 0) <> 1 then
      raise notice 's120 seed: "%" matches % active items, skipped', r.n, coalesce(array_length(v_ids, 1), 0);
      continue;
    end if;
    update public.inventory_items
       set usage_baseline_per_turnover = r.b,
           usage_baseline_note = 'Research 2026-11-18: ' || r.note,
           consumption_per_booking = case when consumption_per_booking is null or consumption_per_booking = 2.00 then r.b else consumption_per_booking end
     where id = v_ids[1] and usage_baseline_per_turnover is null;
  end loop;
end $s$;

-- 10. backfill: replay the counts recorded from 27 Oct through the same maths (idempotent: (item, anchor_at) is unique) ---------------------------------------------
-- The audit rows are written by s_apply_inventory_count_core_v1 as action telegram_count: 2026-10-27 06:43 UTC (actor s99f-data-step, note "Count of 16 Oct printout recorded as
-- current stock") and 2026-11-18 03:18 UTC (actor s118-data-step). Older Telegram counts (19 Sep, Tea) are not replayed: that anchor is too old to trust.
-- Inactive items are skipped (the old "Tissues / Paper Towels", counted 50 -> 0 on 18 Nov, is deactivated), and a new item has no earlier anchor, so nothing is invented across the split.
-- This block writes no stock; it refuses (raises) when a replayed quantity is negative or when any qty_on_hand differs after the replay.
do $bf$
declare
  r record; v_q numeric; v_before numeric; v_after numeric; v_min numeric; v_n integer := 0;
begin
  select coalesce(sum(qty_on_hand), 0) into v_before from public.inventory_items;
  for r in
    select z.id, z.item_id, z.anchor_at, z.q
      from (select a.id, a.entity_id as item_id, a.created_at,
                   -- D-351: the 27 Oct rows are the 16 Oct printout, so they anchor at the printout (16 Oct 08:21 Manila), not at the day they were typed in
                   case when a.after ->> 'note' like 'Count of 16 Oct printout%' then timestamptz '2026-10-16 08:21+08'
                        else coalesce((a.after ->> 'as_of')::timestamptz, a.created_at) end as anchor_at,
                   coalesce(a.after ->> 'counted', a.after ->> 'qty_on_hand') as q
              from public.inventory_audit_log a
              join public.inventory_items i on i.id = a.entity_id
             where a.entity_type = 'inventory_items' and a.action = 'telegram_count' and a.created_at >= timestamptz '2026-10-27 00:00:00+08'
               and i.is_active and i.is_consumable and i.movement_controlled_at is null
               and (a.after ->> 'counted' is not null or jsonb_typeof(a.after -> 'qty_on_hand') = 'number')) z
     order by z.anchor_at, z.created_at, z.id
  loop
    v_q := r.q::numeric;
    if v_q < 0 then raise exception 's120 backfill: audit row % holds a negative count (%)', r.id, v_q; end if;
    perform public.record_inventory_anchor_v1(r.item_id, v_q, r.anchor_at, 'count');
    v_n := v_n + 1;
  end loop;
  select coalesce(sum(qty_on_hand), 0), coalesce(min(qty_on_hand), 0) into v_after, v_min from public.inventory_items;
  if v_after is distinct from v_before or v_min < 0 then
    raise exception 's120 backfill: stock changed or went negative (sum % -> %, min %)', v_before, v_after, v_min;
  end if;
  raise notice 's120 backfill: % count rows replayed', v_n;
end $bf$;

-- 11. self-check -----------------------------------------------------------------------------------------------------------------------------------------------
do $v$
begin
  if (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and position('record_inventory_anchor_v1' in p.prosrc) > 0
        and p.proname in ('s_apply_inventory_count_core_v1', 'record_inventory_receipt_v1', 'apply_inventory_purchase', 's_inventory_receipt_apply_v1')) <> 4 then
    raise exception 's120: a hook is missing from the count core or a receive path';
  end if;
  if position('usageState' in (select p.prosrc from pg_proc p where p.oid = 'public.get_inventory_catalogue_v1(uuid)'::regprocedure)) = 0 then
    raise exception 's120: the catalogue lacks the usage keys';
  end if;
  -- only intervals written AFTER an item became controlled are wrong (a later admin count legitimately ends learning for that item)
  if exists (select 1 from public.inventory_usage_intervals x join public.inventory_items i on i.id = x.item_id
              where i.movement_controlled_at is not null and x.created_at > i.movement_controlled_at) then
    raise exception 's120: an interval was written for a movement-controlled item';
  end if;
  if (select numeric_scale from information_schema.columns where table_schema = 'public' and table_name = 'inventory_items' and column_name = 'consumption_per_booking') is distinct from 4 then
    raise exception 's120: consumption_per_booking is not numeric(10,4)';
  end if;
end $v$;

commit;
