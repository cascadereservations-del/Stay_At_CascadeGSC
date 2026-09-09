-- Wire the scheduler heartbeat monitor (P10 item 4 / P9 prerequisite).
--
-- 1. Schedule job-heartbeat-monitor every 15 minutes.
-- 2. Give turnover-verifier (pg_cron job 8) the x-cascade-cron-secret header it
--    has never sent, so CASCADE_CRON_SHARED_SECRET can finally be set without
--    401-ing it every night (D-036).
--
-- The secret value never appears here. Both jobs read it at run time from
-- Vault: vault.decrypted_secrets where name = 'cascade_cron_shared_secret'.
-- Until Lloyd creates that Vault secret AND sets the same value as the edge
-- function secret CASCADE_CRON_SHARED_SECRET, the header is null and both
-- functions answer 401 - a safe, visible failure, not a silent one.
--
-- Rehearsal copies have no pg_cron; the block skips cleanly there and the
-- contract's forward checks are written to tolerate that.

do $$
declare
  v_monitor_cmd text := $cmd$
  SELECT net.http_post(
    url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/job-heartbeat-monitor',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cascade-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret')
    ),
    body    := '{}'::jsonb
  ) AS request_id;
$cmd$;
  v_verifier_cmd text := $cmd$
  SELECT net.http_post(
    url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/turnover-verifier',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cascade-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret')
    ),
    body    := '{}'::jsonb
  ) AS request_id;
$cmd$;
  v_job8 record;
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron absent (rehearsal copy) - heartbeat monitor cron wiring skipped';
    return;
  end if;

  -- 1. Monitor job, idempotent by name.
  if not exists (select 1 from cron.job where jobname = 'job-heartbeat-monitor-every-15m') then
    perform cron.schedule('job-heartbeat-monitor-every-15m', '*/15 * * * *', v_monitor_cmd);
  end if;

  -- 2. Job 8 header. Match by name, not id, and refuse to touch anything unexpected.
  select * into v_job8 from cron.job where jobname = 'turnover-verifier-daily';
  if v_job8 is null then
    raise exception 'turnover-verifier-daily cron job not found';
  end if;
  if v_job8.command not like '%functions/v1/turnover-verifier%' then
    raise exception 'turnover-verifier-daily command is not the expected http_post';
  end if;
  if v_job8.command not like '%x-cascade-cron-secret%' then
    perform cron.alter_job(job_id := v_job8.jobid, command := v_verifier_cmd);
  end if;

  raise notice 'heartbeat monitor cron wired; secret is read from vault at run time';
end $$;
