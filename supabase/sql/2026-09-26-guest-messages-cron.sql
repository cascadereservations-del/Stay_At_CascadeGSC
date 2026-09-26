-- 2026-09-26 (session 54): schedule guest-messages hourly at minute 5 (SPEC-05 messages 1 and 2, D-253).
-- Run with run-sql-on-host.sh AFTER release guest_message_log_20260926 is applied and guest-messages is deployed.
-- Auth: x-cascade-cron-secret from Vault, the same header system-verifier-hourly sends (memory cascade-cron-secret-via-vault).
-- Idempotent: unschedules by name first.
select cron.unschedule(jobid) from cron.job where jobname = 'guest-messages-hourly';
select cron.schedule('guest-messages-hourly', '5 * * * *', $cron$
  select net.http_post(
    url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/guest-messages',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cascade-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret')
    ),
    body    := '{}'::jsonb
  ) as request_id;
$cron$);
-- Check: select jobname, schedule, active from cron.job where jobname = 'guest-messages-hourly';  -> one row, '5 * * * *', true
