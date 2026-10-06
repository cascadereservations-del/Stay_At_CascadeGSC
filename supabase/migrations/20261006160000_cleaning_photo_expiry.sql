-- Session 72 (SPEC-42 section 3, SPEC-15 phase 2): weekly expiry of cleaning photos that Drive already holds.
-- Deploy the Edge Function expire-cleaning-photos BEFORE this applies (it schedules the first call).
--   1. job_heartbeats row 'expire-cleaning-photos-weekly' (record_job_heartbeat refuses an unknown job name). It is seeded as
--      succeeded now and expected every 8 days, so one late Monday is not an alert and the monitor does not fire before the first run.
--   2. pg_cron 'expire-cleaning-photos-weekly': Sunday 22:00 UTC = Monday 06:00 Manila, calling the function with ?delete=1 and the
--      Vault cron secret (same pattern as power-watch-hourly; the secret is read when the job runs and is never in this file).
-- The function deletes nothing without ?delete=1, never a photo without a Drive archive record, and at most 10 sessions a run.
-- Related finding F2 (2026-09-29 13:46Z turnover with no session_folder_id / drive_files, so nothing here ever expires it): proximate cause:
-- Edge 150 s wall clock; Code.gs outcome unconfirmed - owner reads the Code.gs execution log for 2026-09-29 13:46Z before any resend.
-- (submit-cleaning now aborts the GAS wait from a request-start deadline, leaving the Finance alert at least 10 s.)
-- No table changes. pg_cron is absent from rehearsal and CI copies; the block skips there (same pattern as 20260913160000).
begin;

insert into public.job_heartbeats (job_name, expected_interval_seconds, ops_risk, last_succeeded_at)
values ('expire-cleaning-photos-weekly', 691200, false, now())
on conflict (job_name) do update set expected_interval_seconds = excluded.expected_interval_seconds, ops_risk = excluded.ops_risk;

do $$
begin
  if to_regclass('cron.job') is null or to_regnamespace('net') is null then
    raise notice 'pg_cron or pg_net absent (rehearsal copy) - expire-cleaning-photos cron wiring skipped';
    return;
  end if;

  perform cron.unschedule(jobid) from cron.job where jobname = 'expire-cleaning-photos-weekly';

  perform cron.schedule('expire-cleaning-photos-weekly', '0 22 * * 0', $cmd$
    select net.http_post(
      url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/expire-cleaning-photos?delete=1',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cascade-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret')
      ),
      body    := '{}'::jsonb,
      timeout_milliseconds := 120000
    ) as request_id;
  $cmd$);

  if (select count(*) from cron.job where jobname = 'expire-cleaning-photos-weekly' and active and schedule = '0 22 * * 0'
        and command like '%/functions/v1/expire-cleaning-photos?delete=1%' and command like '%x-cascade-cron-secret%') <> 1 then
    raise exception 'expire-cleaning-photos-weekly not scheduled';
  end if;
end $$;

commit;
