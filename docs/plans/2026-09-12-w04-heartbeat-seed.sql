-- Seed CH-W04's first heartbeat so job-heartbeat-monitor does not raise JOB_NEVER_SUCCEEDED
-- before the first 08:00 Manila sweep records a real pulse (D-075). Idempotent.
begin;
update public.job_heartbeats set last_succeeded_at = coalesce(last_succeeded_at, now()), updated_at = now()
where job_name = 'ch-w04-outbox-reconciliation';
commit;
