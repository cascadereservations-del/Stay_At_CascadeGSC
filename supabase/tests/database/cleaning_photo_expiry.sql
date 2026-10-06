-- Session 72, cleaning photo expiry (migration 20261006160000): the heartbeat row the weekly job reports to, and the cron wiring
-- where pg_cron exists. Inside begin/rollback.
begin;
select plan(10);

select ok(exists (select 1 from public.job_heartbeats where job_name = 'expire-cleaning-photos-weekly' and expected_interval_seconds = 691200 and ops_risk = false),
  'the weekly job has its heartbeat row: 8 days, not ops-risk');

select lives_ok($$select public.record_job_heartbeat('expire-cleaning-photos-weekly', 'started', null)$$, 'the job can record a start');
select lives_ok($$select public.record_job_heartbeat('expire-cleaning-photos-weekly', 'failed', 'REMOVE_FAILED')$$, 'the job can record REMOVE_FAILED (its error code passes the format check)');
select ok((select consecutive_failures = 1 and last_error_code = 'REMOVE_FAILED' from public.job_heartbeats where job_name = 'expire-cleaning-photos-weekly'),
  'one failure is counted with its code');
select lives_ok($$select public.record_job_heartbeat('expire-cleaning-photos-weekly', 'succeeded', null)$$, 'the job can record a success');
select ok((select consecutive_failures = 0 and last_error_code is null and last_succeeded_at is not null from public.job_heartbeats where job_name = 'expire-cleaning-photos-weekly'),
  'a success clears the failure count and code');
select lives_ok($$select public.record_job_heartbeat('expire-cleaning-photos-weekly', 'failed', 'RUN_FAILED')$$, 'the job can record RUN_FAILED');

create function public.test_expiry_cron_contract() returns setof text language plpgsql as $t$
begin
  -- The schema-only recovery baseline has no pg_cron / pg_net; the heartbeat checks above still run there.
  if to_regclass('cron.job') is null then
    return query select * from skip(3, 'pg_cron is absent from the schema-only recovery baseline');
    return;
  end if;
  return query select ok(exists (select 1 from cron.job where jobname = 'expire-cleaning-photos-weekly' and active and schedule = '0 22 * * 0'),
    'scheduled Sunday 22:00 UTC (Monday 06:00 Manila), active');
  return query select ok((select command like '%/functions/v1/expire-cleaning-photos?delete=1%' from cron.job where jobname = 'expire-cleaning-photos-weekly'),
    'it calls the function with the explicit delete flag');
  return query select ok((select command like '%x-cascade-cron-secret%' and command like '%cascade_cron_shared_secret%' and command !~ 'x-cascade-cron-secret''\s*,\s*''[^(]' from cron.job where jobname = 'expire-cleaning-photos-weekly'),
    'the secret is read from Vault at run time, never embedded');
end $t$;
select * from public.test_expiry_cron_contract();
drop function public.test_expiry_cron_contract();

select * from finish();
rollback;
