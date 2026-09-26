-- Compensating rollback for release guest_message_log_20260926 (SPEC-05 messages 1 and 2).
-- Unschedule the cron job first (the one-off sql/2026-09-26-guest-messages-cron.sql names it) so the function is not
-- called against a missing table. Dropping the log loses the record of which guests were messaged: export it first
-- (select * from public.guest_message_log) if it has rows. guest-messages then fails closed (500, heartbeat failed).
begin;
select cron.unschedule(jobid) from cron.job where jobname = 'guest-messages-hourly';
drop function if exists public.due_guest_messages_v1(timestamptz);
drop table if exists public.guest_message_log;
delete from public.job_heartbeats where job_name = 'guest-messages-hourly';
commit;
