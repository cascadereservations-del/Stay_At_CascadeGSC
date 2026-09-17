-- Compensating rollback for 20260917020000_staff_decide_direct_booking.sql: drops the staff gate. Decisions
-- already recorded through it stay (they are real decisions). The dashboard's Confirm / Decline for direct
-- bookings then fails closed again; the Telegram tap keeps working.
begin;
drop function if exists public.staff_decide_direct_booking_v1(uuid, text, text, uuid);
commit;
