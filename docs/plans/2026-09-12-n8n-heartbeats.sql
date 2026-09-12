-- Register the two n8n schedules as heartbeat jobs (D-075). automation-host-alerts records a
-- 'succeeded' pulse on every claim (CH-S01, every 5 min) and every sweep (CH-W04, daily);
-- job-heartbeat-monitor (every 15 min) then raises one deduplicated system.job_stale alert per
-- stale episode. Grace is 1.5x the interval. Idempotent.
begin;
insert into public.job_heartbeats (job_name, expected_interval_seconds, ops_risk)
values ('ch-s01-host-alert-router', 300, false),
       ('ch-w04-outbox-reconciliation', 86400, false)
on conflict (job_name) do nothing;
commit;
