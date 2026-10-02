-- Session 67 (Lloyd 2026-10-02): run power-watch every 15 minutes instead of hourly. One-off production SQL for run-sql-on-host.sh
-- (records no ledger row; reviewed here). Idempotent: safe to re-run. Needs 2026-09-29-s60-power-watch-cron.sql applied first.
--   pg_cron job 'power-watch-hourly' (jobid 20) moves from minute 20 to minutes 7, 22, 37, 52. Those minutes are free: the other jobs
--   sit on 0, 5, 15, 20, 30, 35, 45 (calendar-sync-15m and the heartbeat monitor use */15). The command, the Vault cron secret and the
--   function are untouched, and so is the job NAME: power-watch records its heartbeat under 'power-watch-hourly', so renaming the job
--   would orphan job_heartbeats. The heartbeat row keeps expected_interval_seconds 3600, the same tolerance calendar-sync-15m has, so
--   a normal 15-minute cadence never trips the monitor and a stall is still caught within the hour.
--   power-watch itself is safe at 4x the rate: its state (app_settings.power_watch_state) skips posts and poster images already
--   decided, and it reads at most MAX_READS = 4 poster images per run. Undo: select cron.alter_job(20, schedule := '20 * * * *');
begin;

do $$
declare v_id bigint;
begin
  select jobid into v_id from cron.job where jobname = 'power-watch-hourly';
  if v_id is null then
    raise exception 'cron job power-watch-hourly not found: apply 2026-09-29-s60-power-watch-cron.sql first';
  end if;
  perform cron.alter_job(v_id, schedule := '7,22,37,52 * * * *');
end $$;

commit;

-- Forward checks (every row should read true):
-- select schedule = '7,22,37,52 * * * *' and active from cron.job where jobname = 'power-watch-hourly';
-- select count(*) = 1 from cron.job where jobname = 'power-watch-hourly';
-- select expected_interval_seconds = 3600 from public.job_heartbeats where job_name = 'power-watch-hourly';
-- After the next :07/:22/:37/:52, last_succeeded_at moves:
-- select last_succeeded_at > now() - interval '16 minutes' from public.job_heartbeats where job_name = 'power-watch-hourly';
