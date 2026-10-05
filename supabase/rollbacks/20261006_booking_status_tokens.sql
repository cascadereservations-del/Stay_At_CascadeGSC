-- Compensating rollback for release booking_status_tokens_20261006 (session 72).
-- Drops the status RPC and its index. Issued tokens stay in guest_access_tokens (the guest guide still uses them); the status page
-- simply stops answering. Roll the stay-site (stay.html) and guest-access back too.
begin;
drop function if exists public.guest_booking_status_v1(text);
drop index if exists public.guest_access_tokens_booking_id_idx;
commit;
