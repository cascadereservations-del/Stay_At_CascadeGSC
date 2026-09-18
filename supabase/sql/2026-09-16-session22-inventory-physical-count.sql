-- Applied to production 2026-09-16 (admin session 22) with run-sql-on-host.sh, which writes no ledger row. Data only, not a schema migration: it lives here, not in supabase/migrations, so CI never replays it against a fresh database.
-- One-off reviewed SQL, not a release contract (additive + reconciliation only,
-- no destructive statements). Session 22 item 2: Lloyd's handwritten physical
-- stock count, cross-checked against the live catalogue and confirmed by him.
--
-- Two parts:
--   1. Nine new consumable inventory_items rows for products the catalogue
--      never tracked (Ambi Pur, Natural Air, two Mr Muscle products, Lysol
--      Disinfectant Spray, Baygon Spray, Breeze fabric conditioner, two
--      garbage-bag sizes).
--   2. Four quantity corrections on existing rows, done the same way
--      reconcile_inventory_baseline_v1 does it internally (insert an
--      inventory_stock_movements 'reconcile' row, then update qty_on_hand) --
--      that RPC itself requires a real signed-in staff session (auth.uid()
--      + AAL2 via inventory_human_authorized), which this SQL-runner
--      connection does not have, so the same effect is reproduced directly.
--      actor_user_id is set to the owner staff_access_profiles row (the only
--      one, 6f29516a-719e-49d9-b3ad-9ddb5b436f52 -- inventory_stock_movements
--      has a NOT NULL constraint on this column, unlike auth.uid() which can
--      be null; confirmed live after the first attempt failed on it), with
--      the reason text noting this was Lloyd's own physical count, applied
--      by Claude Code on his explicit approval.
--
-- Not touched, deliberately: "Bathroom Tissue" / "Tissue Square" (ambiguous
-- against the single existing "Tissues / Paper Towels" row) and "Nescafe
-- Stick" (ambiguous against "3-in-1 Coffee", corrected below, and "Coffee
-- sticks (sugar/creamer)") -- flagged to Lloyd as open questions, not
-- guessed at here.

begin;

do $$
declare
  v_property_id uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  v_item record;
  v_mid uuid;
begin
  -- ── Part 1: nine new catalogue items ──────────────────────────────
  insert into public.inventory_items
    (property_id, name, category, unit, is_consumable, is_active, qty_on_hand, reorder_below, consumption_per_booking)
  values
    (v_property_id, 'Ambi Pur',                              'Cleaning', 'pc', true, true, 2.00, 1.00, 2.00),
    (v_property_id, 'Natural Air',                           'Cleaning', 'pc', true, true, 1.00, 1.00, 2.00),
    (v_property_id, 'Mr Muscle Glass Cleaner (Blue)',        'Cleaning', 'pc', true, true, 1.00, 1.00, 2.00),
    (v_property_id, 'Mr Muscle Mold & Mildew (Orange)',      'Cleaning', 'pc', true, true, 2.00, 1.00, 2.00),
    (v_property_id, 'Lysol Disinfectant Spray',               'Cleaning', 'pc', true, true, 1.00, 1.00, 2.00),
    (v_property_id, 'Baygon Spray',                          'Cleaning', 'pc', true, true, 3.00, 1.00, 2.00),
    (v_property_id, 'Breeze Fabric Conditioner Liquid',       'Cleaning', 'pc', true, true, 1.00, 1.00, 2.00),
    (v_property_id, 'Garbage Bags (Large)',                   'Cleaning', 'pc', true, true, 2.00, 1.00, 2.00),
    (v_property_id, 'Garbage Bags (Small)',                   'Cleaning', 'pc', true, true, 1.00, 1.00, 2.00);

  -- ── Part 2: four quantity corrections on existing items ───────────
  -- (name, counted_qty, idempotency_key)
  for v_item in
    select * from (values
      ('Liquid Hand Soap (Safeguard)', 0.00::numeric,  'session22-reconcile-hand-soap-20260916'),
      ('Liquid Body Soap (Dove)',      1.00::numeric,  'session22-reconcile-body-wash-20260916'),
      ('Bottled Water',                24.00::numeric, 'session22-reconcile-bottled-water-20260916'),
      ('3-in-1 Coffee',                33.00::numeric, 'session22-reconcile-3in1-coffee-20260916')
    ) as t(item_name, counted_qty, idem_key)
  loop
    declare
      v_id uuid;
      v_before numeric;
    begin
      select id, qty_on_hand into v_id, v_before
      from public.inventory_items
      where property_id = v_property_id and name = v_item.item_name and is_active = true;

      if v_id is null then
        raise exception 'item not found for reconciliation: %', v_item.item_name;
      end if;

      insert into public.inventory_stock_movements
        (item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key)
      values
        (v_id, v_property_id, 'reconcile', v_before, v_item.counted_qty,
         'Baseline count: physical stock count 2026-09-16, applied by Claude Code on Lloyd''s explicit confirmation',
         '6f29516a-719e-49d9-b3ad-9ddb5b436f52'::uuid, v_item.idem_key)
      returning id into v_mid;

      update public.inventory_items set qty_on_hand = v_item.counted_qty where id = v_id;
    end;
  end loop;
end $$;

commit;
