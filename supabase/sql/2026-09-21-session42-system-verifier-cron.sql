-- SPEC-11 session 2: schedule the system verifier.
-- Run once, with scripts/migrations/run-sql-on-host.sh, AFTER the
-- system-verifier Edge Function is deployed. Scheduling it first would give
-- two jobs an hour that 404 and mark their own heartbeats failed.
--
-- Hourly at :35 - V1-V5, V11, V12. Away from :00 and :15, where calendar-sync
-- and the heartbeat monitor already are.
-- Daily at 23:45 UTC = 07:45 Manila, fifteen minutes before the 08:00 digest,
-- so a red finding is read before the day's summary rather than after it.
--
-- AUTH: the cron secret out of Vault, exactly as turnover-verifier (job 8) and
-- job-heartbeat-monitor (job 9) do it. NOT the Authorization-bearer shape that
-- release-expired-holds (job 15) uses - that function has no cron auth at all,
-- and system-verifier checks x-cascade-cron-secret. The secret is never typed
-- into this file or anywhere else.
--
-- Re-runnable: each job is unscheduled first, but only if it is really there.
-- cron.unschedule() raises on a name that does not exist, so a plain pair of
-- unschedule lines would fail this script the very first time it is run.

do $$
begin
  if exists (select 1 from cron.job where jobname = 'system-verifier-hourly') then
    perform cron.unschedule('system-verifier-hourly');
  end if;
  if exists (select 1 from cron.job where jobname = 'system-verifier-daily') then
    perform cron.unschedule('system-verifier-daily');
  end if;
end $$;

select cron.schedule('system-verifier-hourly', '35 * * * *', $cmd$
  select net.http_post(
    url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/system-verifier?scope=hourly',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cascade-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret')
    ),
    body    := '{}'::jsonb
  ) as request_id;
$cmd$);

select cron.schedule('system-verifier-daily', '45 23 * * *', $cmd$
  select net.http_post(
    url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/system-verifier?scope=daily',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cascade-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret')
    ),
    body    := '{}'::jsonb
  ) as request_id;
$cmd$);

-- What it should look like afterwards: two active rows, the right minutes, each
-- carrying its own scope, and the secret read from Vault rather than written down.
select jobid, jobname, schedule, active,
       command like '%scope=hourly%' as hourly_scope,
       command like '%scope=daily%'  as daily_scope,
       command like '%decrypted_secrets%' as reads_the_vault,
       command not like '%Authorization%' as no_bearer_token
  from cron.job
 where jobname in ('system-verifier-hourly', 'system-verifier-daily')
 order by jobname;
