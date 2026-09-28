-- Compensating rollback for release guest_message_reads_20260928: drop the two read functions. Deploy guest-messages and
-- daily-digest from before this release's waves commit first, or 5.2 is held and the digest ID line stays empty.
begin;
drop function if exists public.guest_message_hold_v1(uuid);
drop function if exists public.arrivals_without_id_v1(date, date);
commit;
