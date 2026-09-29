-- Session 60 (D-284, Lloyd 2026-09-29 "A"): schedule power-watch hourly. One-off production SQL for run-sql-on-host.sh
-- (records no ledger row; reviewed here). Idempotent: safe to re-run.
--   1. job_heartbeats row 'power-watch-hourly' (record_job_heartbeat refuses an unknown job name), seeded as succeeded now
--      so the monitor does not fire before the first run.
--   2. pg_cron 'power-watch-hourly' at minute 20, calling the function with the Vault cron secret - the same pattern as
--      system-verifier-hourly (jobid 16).
-- Deploy power-watch BEFORE this runs, or the first calls return 404.
begin;

insert into public.job_heartbeats (job_name, expected_interval_seconds, ops_risk, last_succeeded_at)
values ('power-watch-hourly', 3600, true, now())
on conflict (job_name) do update set expected_interval_seconds = excluded.expected_interval_seconds, ops_risk = excluded.ops_risk;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'power-watch-hourly') then
    perform cron.schedule('power-watch-hourly', '20 * * * *', $cmd$
      select net.http_post(
        url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/power-watch',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cascade-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret')
        ),
        body    := '{}'::jsonb
      ) as request_id;
    $cmd$);
  end if;
end $$;

commit;

-- Forward checks (every row should read true):
-- select exists (select 1 from public.job_heartbeats where job_name = 'power-watch-hourly');
-- select schedule = '20 * * * *' and active from cron.job where jobname = 'power-watch-hourly';
