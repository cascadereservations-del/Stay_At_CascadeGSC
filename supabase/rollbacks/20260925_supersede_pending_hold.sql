-- Rollback for release supersede_pending_hold_20260925: drops supersede_pending_direct_requests_v1. submit-booking
-- logs the RPC error as non-fatal and carries on as before the release (redeploy the previous submit-booking to
-- silence the warning). Requests already superseded stay cancelled with their note.
begin;
drop function if exists public.supersede_pending_direct_requests_v1(uuid, text, text, date, date);
commit;
