-- Sprint 0 (2026-09-16, D-160). One-off production SQL for Lloyd to run with
-- run-sql-on-host.sh (records no ledger row; reviewed here). Idempotent: safe to re-run.
--
-- What it does:
--   1. Seeds job_heartbeats rows for the six scheduled functions that now call
--      record_job_heartbeat (calendar-sync, daily-digest x2, missed-cleaning-alert,
--      finance-watch, verify-meter-photo). record_job_heartbeat refuses an unknown
--      job_name, so the rows must exist before the new function versions run.
--      last_succeeded_at is seeded as now() so the monitor does not fire
--      JOB_NEVER_SUCCEEDED before the first real run.
--   2. Renames cron job 1 to match its real schedule (every 15 min; the function
--      self-limits to one real sync per 30 min) and moves cron job 4 to Mondays so
--      the Finance digest becomes the weekly roll-up (Telegram plan section 4).
--      cron.alter_job cannot rename, so both are unschedule + schedule with the
--      identical command text.
--   3. Adds a nightly pruning job (01:00 Manila) for the three unpruned logs plus
--      ANALYZE on the tables that were never analysed.
--
-- Hard Rule 9 after running: POST daily-digest {"mode":"ops"} and finance-watch by hand
-- and confirm job_heartbeats.last_succeeded_at moves; then check Settings -> System
-- health still loads.

begin;

-- 1. Heartbeat rows -----------------------------------------------------------
insert into public.job_heartbeats (job_name, expected_interval_seconds, ops_risk, last_succeeded_at)
values
  ('calendar-sync-15m',           3600,   true,  now()),   -- cron every 15 min, real sync every 30
  ('daily-digest-ops-0700',       86400,  true,  now()),
  ('weekly-finance-monday-0700',  604800, false, now()),   -- weekly once step 2 runs
  ('missed-cleaning-alert',       86400,  true,  now()),
  ('finance-watch-daily',         86400,  false, now()),
  ('verify-meter-photo-daily',    86400,  false, now())
on conflict (job_name) do update
  set expected_interval_seconds = excluded.expected_interval_seconds,
      ops_risk = excluded.ops_risk;

-- 2. Cron renames / reschedules -----------------------------------------------
do $$
begin
  if exists (select 1 from cron.job where jobname = 'calendar-sync-6h') then
    perform cron.unschedule('calendar-sync-6h');
  end if;
  if not exists (select 1 from cron.job where jobname = 'calendar-sync-15m') then
    perform cron.schedule('calendar-sync-15m', '*/15 * * * *', $cmd$
    SELECT net.http_post(
      url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/calendar-sync',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer sb_publishable_JFuRYZ9csmQULcMRmHXDSg_Abo9UeCj'
      ),
      body    := '{}'::jsonb
    );
  $cmd$);
  end if;

  if exists (select 1 from cron.job where jobname = 'weekly-finance-monday-0700' and schedule <> '0 0 * * 1') then
    perform cron.unschedule('weekly-finance-monday-0700');
  end if;
  if not exists (select 1 from cron.job where jobname = 'weekly-finance-monday-0700') then
    perform cron.schedule('weekly-finance-monday-0700', '0 0 * * 1', $cmd$SELECT net.http_post(
    url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/daily-digest',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer sb_publishable_JFuRYZ9csmQULcMRmHXDSg_Abo9UeCj'),
    body    := '{"mode":"finance"}'::jsonb
  );$cmd$);
  end if;

  -- 3. Nightly pruning + analyze (01:00 Manila = 17:00 UTC previous day)
  if not exists (select 1 from cron.job where jobname = 'nightly-prune-logs') then
    perform cron.schedule('nightly-prune-logs', '0 17 * * *', $cmd$
    delete from cron.job_run_details where end_time < now() - interval '90 days';
    delete from public.reconciliation_log where created_at < now() - interval '90 days';
    delete from public.calendar_sync_log where synced_at < now() - interval '90 days';
    analyze public.calendar_events; analyze public.airbnb_transactions; analyze public.guests;
    analyze public.transactions; analyze public.cleaning_sessions; analyze public.inventory_items;
  $cmd$);
  end if;
end $$;

commit;

-- Forward checks (run after commit; every row should read true):
-- select count(*) = 6 from public.job_heartbeats where job_name in ('calendar-sync-15m','daily-digest-ops-0700','weekly-finance-monday-0700','missed-cleaning-alert','finance-watch-daily','verify-meter-photo-daily');
-- select schedule = '0 0 * * 1' from cron.job where jobname = 'weekly-finance-monday-0700';
-- select not exists (select 1 from cron.job where jobname = 'calendar-sync-6h');
-- select exists (select 1 from cron.job where jobname in ('calendar-sync-15m','nightly-prune-logs'));
