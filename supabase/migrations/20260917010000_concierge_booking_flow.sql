-- Messenger book intent (session 27, booking PRD §A): the slot-filling state and, once submitted,
-- the booking id / reference / receipt token live in ONE jsonb on the thread. concierge_threads is
-- already fully granted to service_role, so this is a column and nothing else.
begin;
alter table public.concierge_threads add column if not exists booking_flow jsonb;
comment on column public.concierge_threads.booking_flow is
  'Messenger book flow state (session 27): {step, checkin, checkout, pax, phone, email, booking_id, ref, deposit, total, hold, hold_expires_at, receipt_token, receipt_expires_at, started_at, updated_at}. Null = no flow.';
commit;
