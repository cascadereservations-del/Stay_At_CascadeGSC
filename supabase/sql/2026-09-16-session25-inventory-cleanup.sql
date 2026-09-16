-- One-off reviewed SQL (session 25 step 5, D-160, PLAN-inventory-data-cleanup.md).
-- Run with run-sql-on-host.sh from stay-site. Idempotent: every step checks before it acts.
--
-- 1. Merge "Nescafe Stick" (28 pc, created 2026-09-16 from the photo count) into
--    "3-in-1 Coffee" (33 pc): same product, Nescafe is the brand. The survivor keeps
--    its id (2 purchase rows, 42 usage logs, legacy_id, unit_cost, purchase_unit) and is
--    renamed "Nescafe 3-in-1 Coffee Stick" so both names fuzzy-match on receipts.
--    Quantity 33 -> 61 through an inventory_stock_movements 'reconcile' row, the same
--    shape reconcile_inventory_baseline_v1 writes (that RPC needs a live staff session
--    this runner does not have). ASSUMPTION flagged in the plan: the 28 was a separate
--    pile from the 33 on the 2026-09-16 count. If Lloyd says it was the same sticks
--    counted twice, change v_merged below to 33 before running.
--    "Nescafe Stick" is retired (is_active = false, resolution note), never deleted.
-- 2. Rename "Coffee sticks (sugar/creamer)" -> "Sugar & Creamer Sticks". The old
--    CH_Inventory seed always priced it as sugar/creamer (PHP 8 vs PHP 18); it was never
--    coffee. Rename only; its 50 pc and usage history stay.
-- 3. In-unit vs spare: notes convention "in-unit: N · spare: M" written only where it is
--    a fact without a shelf look -- every non-consumable with qty_on_hand = 1 is in the
--    unit. Multi-quantity durables (towels, sheets, hangers...) wait for Lloyd's numbers.
--    purchase_unit for the other consumables also waits for Lloyd's pack sizes.
--
-- Hard Rule 9 after running: Cassy "/inventory" lists 73 active items; the dashboard
-- Inventory tab's three groups still sum to the active total (B70); the checklist supply
-- log still shows the sugar row under Everyday Items (QUICK_ITEM_NAMES gained 'sugar').

begin;

do $$
declare
  v_property uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  v_actor    uuid := '6f29516a-719e-49d9-b3ad-9ddb5b436f52';  -- owner staff_access_profiles row (NOT NULL on movements)
  v_keep     uuid;  v_keep_qty numeric;
  v_drop     uuid;  v_drop_qty numeric;
  v_merged   numeric;
begin
  -- ── 1. Merge ─────────────────────────────────────────────────────────────
  select id, qty_on_hand into v_keep, v_keep_qty from public.inventory_items
   where property_id = v_property and is_active and name in ('3-in-1 Coffee', 'Nescafe 3-in-1 Coffee Stick') limit 1;
  select id, qty_on_hand into v_drop, v_drop_qty from public.inventory_items
   where property_id = v_property and is_active and name = 'Nescafe Stick' limit 1;

  if v_keep is null then raise exception 'survivor coffee row not found'; end if;

  if v_drop is not null then
    v_merged := v_keep_qty + v_drop_qty;   -- 33 + 28 = 61 on 2026-09-16 (see ASSUMPTION above)

    -- any history the retired row accumulated moves to the survivor (0 rows on 2026-09-16, kept for safety)
    update public.inventory_usage     set item_id = v_keep where item_id = v_drop;
    update public.inventory_purchases set item_id = v_keep where item_id = v_drop;

    insert into public.inventory_stock_movements
      (item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key)
    values
      (v_keep, v_property, 'reconcile', v_keep_qty, v_merged,
       'Merge: Nescafe Stick (' || v_drop_qty || ' pc) folded into 3-in-1 Coffee -- same product. Session 25, D-160, applied by Claude Code on Lloyd''s approval',
       v_actor, 'session25-merge-nescafe-into-3in1-20260916')
    on conflict (idempotency_key) do nothing;

    update public.inventory_items
       set qty_on_hand = v_merged
     where id = v_keep;

    update public.inventory_items
       set is_active = false,
           resolved_at = now(),
           resolution_note = 'Merged into "Nescafe 3-in-1 Coffee Stick" (' || v_keep || ') on 2026-09-16, session 25 (D-160). Same product; the 28 pc joined the survivor''s count.'
     where id = v_drop;
  end if;

  update public.inventory_items
     set name = 'Nescafe 3-in-1 Coffee Stick'
   where id = v_keep and name <> 'Nescafe 3-in-1 Coffee Stick';

  -- ── 2. Rename the sugar/creamer row ─────────────────────────────────────
  update public.inventory_items
     set name = 'Sugar & Creamer Sticks'
   where property_id = v_property and name = 'Coffee sticks (sugar/creamer)';

  -- ── 3. In-unit vs spare, only where it is a fact ─────────────────────────
  update public.inventory_items
     set notes = 'in-unit: 1 · spare: 0'
   where property_id = v_property and is_active and not is_consumable and qty_on_hand = 1
     and (notes is null or notes = '');
end $$;

commit;

-- Forward checks (each should return true):
-- select count(*) = 73 from public.inventory_items where is_active;
-- select qty_on_hand = 61 from public.inventory_items where name = 'Nescafe 3-in-1 Coffee Stick';
-- select not is_active from public.inventory_items where name = 'Nescafe Stick';
-- select exists (select 1 from public.inventory_items where name = 'Sugar & Creamer Sticks' and qty_on_hand = 50);
-- select count(*) = 0 from public.inventory_items where is_active and unit <> 'pc';
-- select name = 'Nescafe 3-in-1 Coffee Stick' from public.match_inventory_item('nescafe') limit 1;
