-- 20260913160000_finance_watch_cron.sql (phase 5, D-106 #5 / D-108)
-- Schedule the finance-watch Edge Function daily at 00:30 UTC (08:30 Manila), after the 08:00 digests.
-- The command is copied from the daily-digest ops job (jobid 3) with the function name swapped, so the
-- bearer header never appears in this file; finance-watch ignores the request body.
begin;

select cron.unschedule(jobid) from cron.job where jobname = 'finance-watch-daily';

select cron.schedule(
  'finance-watch-daily',
  '30 0 * * *',
  replace((select command from cron.job where jobname = 'daily-digest-ops-0700'), '/functions/v1/daily-digest', '/functions/v1/finance-watch')
);

-- forward check: one active job, pointing at finance-watch
do $$
begin
  if (select count(*) from cron.job where jobname = 'finance-watch-daily' and active and command like '%/functions/v1/finance-watch%') <> 1 then
    raise exception 'finance-watch-daily not scheduled';
  end if;
end $$;

commit;
