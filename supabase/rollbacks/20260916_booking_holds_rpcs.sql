-- Compensating rollback for 20260916170000_booking_holds_rpcs.sql: drops the two new functions.
-- booking_holds rows already opened stay (the lifecycle guard handles them on confirm/cancel).
begin;
drop function if exists public.open_booking_hold_v1(uuid, integer);
drop function if exists public.expire_booking_holds_v1();
commit;
