-- Compensating rollback for release system_verifier_phase1_20260921
--   20260921010000_system_verifier_phase1.sql
--
-- Nothing depends on this release until the system-verifier Edge Function is
-- deployed in SPEC-11 session 2, so if that has not happened yet this rollback
-- has no ordering requirement at all. If it HAS happened, remove the two cron
-- jobs first (system-verifier-hourly, system-verifier-daily) or they will run
-- against functions that are no longer there and mark their heartbeats failed.
--
-- verifier_findings IS dropped. Unlike the meter follow-up columns it holds no
-- record of a person's decision: every row is a machine-generated diagnostic
-- derived from calendar_events, booking_inquiries and concierge_threads, all of
-- which are untouched here, so a later re-apply simply re-derives them on its
-- first run. The one thing genuinely lost is which findings somebody had
-- acknowledged; those are raised once more and can be acknowledged again.
--
-- The two auto-resolutions this release can perform are NOT undone, and must
-- not be: each of them wrote exactly what an existing, tested function would
-- have written (a cancelled hold, a closed Messenger flow), and both are
-- correct states regardless of what created them.
begin;

drop function if exists public.telegram_ack_verifier_finding_v1(bigint, text);
drop function if exists public.apply_verifier_run_v1(text, jsonb, timestamptz);
drop function if exists public.run_system_verifier_v1(uuid, text, timestamptz);
drop table if exists public.verifier_findings;

delete from public.job_heartbeats
 where job_name in ('system-verifier-hourly', 'system-verifier-daily');

commit;
