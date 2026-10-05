-- Compensating rollback for release concierge_conversations_20261006 (session 72, SPEC-42 section 7).
-- The release added two read functions and nothing else, so dropping them restores the previous state. The Conversations page then
-- shows its error state; roll the admin dashboard back too. The host-reply Edge Function may stay: it only sends when a signed-in owner or admin taps Send.
begin;
drop function if exists public.concierge_conversations_v1(int);
drop function if exists public.concierge_thread_v1(text);
commit;
