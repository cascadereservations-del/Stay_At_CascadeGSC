-- Session 74 lane G8 (finding from G7): finance-watch, release-expired-holds and verify-meter-photo checked no secret in code.
-- finance-watch and release-expired-holds run with verify_jwt false, so any POST triggered a Finance card (and release-expired-holds
-- expires real holds); verify-meter-photo runs with verify_jwt true but the anon key is public, so a caller could pick a
-- property_id or submission_id and write meter verdicts. The functions now require the x-cascade-cron-secret header
-- (CASCADE_CRON_SHARED_SECRET, constant-time, fail closed when unset). This migration makes their three pg_cron jobs send it, read
-- from Vault 'cascade_cron_shared_secret' when the job runs, never written here (same pattern as power-watch-hourly).
-- ORDER: apply this FIRST, then deploy the three functions. A job that sends the header to the old function is harmless; the new
-- function without the header is a 401 until the next run. Redeploy verify-meter-photo WITHOUT changing its JWT setting (still
-- verify_jwt true), so its job keeps the legacy anon Authorization the gateway needs.
-- The schedule of each existing job is kept (read from cron.job; the default is the one in the migration/sql that created it).
-- The bodies below are the ones those files created; each job's current Authorization header is carried over. No table change. pg_cron/pg_net/vault are absent
-- from rehearsal and CI copies; the block skips there (same pattern as 20260913160000).
begin;

do $$
declare
  j record;
  cur text;
  cur_cmd text;
  bearer text;
  secret text := $s$(select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret')$s$;
begin
  if to_regclass('cron.job') is null or to_regnamespace('net') is null or to_regclass('vault.decrypted_secrets') is null then
    raise notice 'pg_cron, pg_net or vault absent (rehearsal copy) - cron secret wiring skipped';
    return;
  end if;
  if coalesce((select length(decrypted_secret) from vault.decrypted_secrets where name = 'cascade_cron_shared_secret'), 0) < 1 then
    raise exception 'vault secret cascade_cron_shared_secret is missing or too short - the jobs would send an empty header';
  end if;

  for j in select * from (values
    ('finance-watch-daily',          '30 0 * * *',  'finance-watch',         'Bearer sb_publishable_JFuRYZ9csmQULcMRmHXDSg_Abo9UeCj', '{}',                                         60000),
    ('release-expired-holds-hourly', '20 * * * *',  'release-expired-holds', 'Bearer sb_publishable_JFuRYZ9csmQULcMRmHXDSg_Abo9UeCj', '{}',                                         60000),
    ('verify-meter-photo-daily',     '30 23 * * *', 'verify-meter-photo',    null,                                                     '{"lookback":14,"limit":5,"notify":false}', 300000)
  ) as t(jobname, dflt_schedule, fn, dflt_bearer, body, timeout_ms)
  loop
    cur_cmd := (select command from cron.job where jobname = j.jobname limit 1);
    -- The Authorization value of the live job is carried over unchanged (verify-meter-photo's is the legacy anon JWT its gateway checks;
    -- the secret scan forbids writing a JWT into a tracked file). A job that is missing and has no default stops the release.
    bearer := coalesce(substring(cur_cmd from $re$'Authorization',\s*'([^']+)'$re$), j.dflt_bearer);
    if bearer is null then
      raise exception 'job % has no Authorization header to carry over', j.jobname;
    end if;
    cur := coalesce((select schedule from cron.job where jobname = j.jobname limit 1), j.dflt_schedule);
    perform cron.unschedule(jobid) from cron.job where jobname = j.jobname;
    perform cron.schedule(j.jobname, cur, format($cmd$
      select net.http_post(
        url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/%1$s',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', '%2$s',
          'x-cascade-cron-secret', %3$s
        ),
        body    := '%4$s'::jsonb,
        timeout_milliseconds := %5$s
      ) as request_id;
    $cmd$, j.fn, bearer, secret, j.body, j.timeout_ms));
  end loop;

  if (select count(*) from cron.job where jobname in ('finance-watch-daily', 'release-expired-holds-hourly', 'verify-meter-photo-daily')
        and active and command like '%x-cascade-cron-secret%' and command like '%cascade_cron_shared_secret%') <> 3 then
    raise exception 'the three cron jobs do not all send the cron secret';
  end if;
end $$;

commit;
