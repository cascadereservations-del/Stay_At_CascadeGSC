begin;
select plan(14);

select has_table('public', 'job_heartbeats', 'heartbeat table exists');
select has_pk('public', 'job_heartbeats', 'heartbeat job name is primary key');
select has_column('public', 'job_heartbeats', 'expected_interval_seconds', 'expected interval is stored');
select has_column('public', 'job_heartbeats', 'last_succeeded_at', 'last success is stored');
select has_column('public', 'job_heartbeats', 'consecutive_failures', 'failure count is stored');
select has_function('public', 'record_job_heartbeat', array['text', 'text', 'text'], 'heartbeat recorder exists');
select has_function('public', 'configure_cascade_scheduler', array[]::text[], 'scheduler configurator exists');
select ok(not has_table_privilege('anon', 'public.job_heartbeats', 'select'), 'anon cannot read scheduler health');
select ok(not has_table_privilege('service_role', 'public.job_heartbeats', 'insert'), 'service role cannot bypass the heartbeat recorder');
select ok(has_function_privilege('service_role', 'public.record_job_heartbeat(text,text,text)', 'execute'), 'service role can use the heartbeat recorder');
select ok(not has_function_privilege('service_role', 'public.configure_cascade_scheduler()', 'execute'), 'service role cannot change schedules');
select col_is_unique('public', 'automation_outbox', 'idempotency_key', 'outbox idempotency keys are unique');

select lives_ok(
  $$select public.record_job_heartbeat('turnover-verifier-daily', 'started', null)$$,
  'known job records a start'
);

select throws_ok(
  $$select public.record_job_heartbeat('turnover-verifier-daily', 'unknown', null)$$,
  '22023',
  'invalid heartbeat phase',
  'unknown heartbeat phases are rejected'
);

select * from finish();
rollback;
