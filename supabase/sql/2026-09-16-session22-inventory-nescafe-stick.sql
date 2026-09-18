-- Applied to production 2026-09-16 (admin session 22) with run-sql-on-host.sh, which writes no ledger row. Data only, not a schema migration: it lives here, not in supabase/migrations, so CI never replays it against a fresh database.
-- One-off reviewed SQL, additive only. Session 22 item 2 follow-up: Lloyd
-- confirmed "Nescafe Stick" (photo count: 28) is a distinct product from
-- "3-in-1 Coffee" (already corrected to 33 in the prior migration), not the
-- same item miscounted. "Bathroom Tissue" / "Tissue Square" stay as-is
-- against the existing single "Tissues / Paper Towels" row -- Lloyd's call.

begin;

insert into public.inventory_items
  (property_id, name, category, unit, is_consumable, is_active, qty_on_hand, reorder_below, consumption_per_booking)
values
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Nescafe Stick', 'Pantry', 'pc', true, true, 28.00, 20.00, 2.00);

commit;
