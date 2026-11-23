-- rollback_20261205_guide_v8.sql: removes everything 20261205000000_guide_v8_messages_analytics.sql created.
-- Guest messages and usage events are deleted with their tables. Export them first if they matter:
--   copy (select * from public.guide_messages) to stdout with csv header;  (run through the read-only runner)
begin;
drop trigger if exists guide_messages_push on public.guide_messages;
drop function if exists public.guide_messages_push_trg();
drop function if exists public.guide_sweep_v1();
drop function if exists public.staff_guide_usage_v1(int, uuid);
drop function if exists public.staff_guide_resolve_v1(uuid, boolean);
drop function if exists public.staff_guide_reply_v1(uuid, text, text);
drop function if exists public.staff_guide_thread_v1(uuid);
drop function if exists public.staff_guide_threads_v1(uuid);
drop function if exists public.guide_track_v1(text, jsonb, text, text);
drop function if exists public.guide_send_v1(text, text, text);
drop function if exists public.guide_thread_v1(text, timestamptz);
drop function if exists public.guide_session_v1(date, text, text, uuid);
drop function if exists public.guide_token_thread_v1(text);
drop table if exists public.guide_events;
drop table if exists public.guide_auth_attempts;
drop table if exists public.guide_messages;
drop table if exists public.guide_sessions;
drop table if exists public.guide_threads;
commit;
