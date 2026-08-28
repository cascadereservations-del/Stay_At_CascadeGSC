# Cascade scheduler recovery

Status: **not activated**. This runbook does not authorize production changes.

## Preconditions

1. Apply and verify the heartbeat migration in a staging-equivalent environment.
2. Deploy `turnover-verifier` and `job-heartbeat-monitor` with JWT verification disabled only because both require the separate `X-Cascade-Cron-Secret` header.
3. Store the same high-entropy value as the Edge Function secret `CASCADE_CRON_SHARED_SECRET` and Vault secret `cascade_cron_shared_secret`.
4. Store the canonical project URL as Vault secret `cascade_supabase_url`.
5. Confirm Finance and OPS route-guard tests pass. The OPS stale-job message must contain no financial data.
6. Capture one signed staging invocation for each function and evidence that `job_heartbeats` records start and success.
7. Obtain the owner's explicit action-time approval before changing production schedules.

Never paste secret values into SQL, cron command text, issue trackers, logs, or this repository.

## Activation

After all preconditions are evidenced, an authorized database owner runs:

```sql
select public.configure_cascade_scheduler();
```

Then verify that exactly these named jobs exist:

- `turnover-verifier-daily` at 00:00 UTC (08:00 Asia/Manila)
- `job-heartbeat-monitor-every-15m` every 15 minutes

Confirm two consecutive monitor successes and one turnover success. Review scheduler HTTP results, `job_heartbeats`, and the outbox for sanitized error codes only.

The monitor cannot prove its own liveness. Configure a separate VPS uptime probe in the observability task to alert when `job-heartbeat-monitor-every-15m` stops advancing.

## Failure recovery

1. Do not replay business actions blindly. Identify the job, scheduled time, request result, and heartbeat state.
2. If the endpoint was unauthorized, compare secret presence and fingerprints without logging the values.
3. If the function failed, fix and invoke it once with a unique correlation ID; confirm idempotency before enabling the schedule.
4. If the monitor is stale, verify it independently. A failed monitor does not prove the monitored job is healthy.
5. Keep Finance informed of system failure. Notify OPS only when `ops_risk` is true, using the closed financial-free template.

## Rollback

Rollback is deliberately narrow. Unschedule only the Cascade-owned names:

```sql
select cron.unschedule('turnover-verifier-daily')
where exists (select 1 from cron.job where jobname = 'turnover-verifier-daily');

select cron.unschedule('job-heartbeat-monitor-every-15m')
where exists (select 1 from cron.job where jobname = 'job-heartbeat-monitor-every-15m');
```

Restore a prior turnover schedule only from a reviewed, secret-backed definition. Never delete or modify unrelated cron jobs. The heartbeat rows and outbox history remain as audit evidence.
