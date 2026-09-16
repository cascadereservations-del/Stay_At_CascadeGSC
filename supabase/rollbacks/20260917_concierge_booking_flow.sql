-- Compensating rollback for 20260917010000_concierge_booking_flow.sql: drops the column (and any
-- in-flight Messenger booking state with it; submitted bookings themselves are untouched).
begin;
alter table public.concierge_threads drop column if exists booking_flow;
commit;
