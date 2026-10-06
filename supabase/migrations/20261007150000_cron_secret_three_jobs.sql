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
-- The bodies and Authorization headers below are the ones those files created. No table change. pg_cron/pg_net/vault are absent
-- from rehearsal and CI copies; the block skips there (same pattern as 20260913160000).
begin;

do $$
declare
  j record;
  cur text;
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
    ('finance-watch-daily',          '30 0 * * *', 'finance-watch',         'Bearer sb_publishable_JFuRYZ9csmQULcMRmHXDSg_Abo9UeCj', '{}',                                         60000),
    ('release-expired-holds-hourly', '20 * * * *', 'release-expired-holds', 'Bearer sb_publishable_JFuRYZ9csmQULcMRmHXDSg_Abo9UeCj', '{}',                                         60000),
    ('verify-meter-photo-daily',     '30 23 * * *', 'verify-meter-photo',   'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFrZ2Zoc2RwcHNsd3VuYXJjemVxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk2MjI3MDYsImV4cCI6MjA5NTE5ODcwNn0.Rf1XhyuxkkoGd2HG0I02CP0BA4mu8kfQalLtStDaXAI',
                                                                                                                                         '{"lookback":14,"limit":5,"notify":false}', 300000)
  ) as t(jobname, dflt_schedule, fn, bearer, body, timeout_ms)
  loop
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
    $cmd$, j.fn, j.bearer, secret, j.body, j.timeout_ms));
  end loop;

  if (select count(*) from cron.job where jobname in ('finance-watch-daily', 'release-expired-holds-hourly', 'verify-meter-photo-daily')
        and active and command like '%x-cascade-cron-secret%' and command like '%cascade_cron_shared_secret%') <> 3 then
    raise exception 'the three cron jobs do not all send the cron secret';
  end if;
end $$;

commit;
