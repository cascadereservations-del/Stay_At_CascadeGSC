-- Compensating rollback for release cron_secret_three_jobs_20261007 (session 74 G8).
-- The normal rollback is to redeploy the previous FUNCTION versions: an old function ignores the extra header, so the cron wiring can
-- stay. This script is only for putting the three jobs back to sending no secret header (it strips the x-cascade-cron-secret line
-- from each job's current command and keeps its schedule). With the new functions still deployed those jobs then get 401.
begin;
do $$
declare j record;
begin
  if to_regclass('cron.job') is null then return; end if;
  for j in select jobname, schedule, command from cron.job where jobname in ('finance-watch-daily', 'release-expired-holds-hourly', 'verify-meter-photo-daily') loop
    perform cron.unschedule(j.jobname);
    perform cron.schedule(j.jobname, j.schedule,
      regexp_replace(j.command, $re$,\s*'x-cascade-cron-secret',\s*\(select decrypted_secret from vault\.decrypted_secrets where name = 'cascade_cron_shared_secret'\)$re$, ''));
  end loop;
end $$;
commit;
