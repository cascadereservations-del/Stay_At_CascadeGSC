-- Compensating rollback for 20260916160000_work_orders_and_guest_context.sql.
-- Both objects are new functions; dropping them restores the prior schema exactly.
-- Work orders already raised stay (they are ordinary rows the dashboard can close).
begin;
drop function if exists public.raise_work_order_v1(uuid, text, text, text, text, text);
drop function if exists public.guest_context_v1(uuid, uuid, text);
commit;
