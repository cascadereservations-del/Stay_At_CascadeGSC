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

The monitor cannot prove its own liveness. `job-heartbeat-liveness` is the independent read-only target: it checks only `job-heartbeat-monitor-every-15m` and returns `MONITOR_HEALTHY`, `MONITOR_STALE`, `MONITOR_MISSING` or `PROBE_UNAVAILABLE` without timestamps or operational details.

The source remains local-only until a separately reviewed Edge Function release. Before deployment, create a dedicated `CASCADE_LIVENESS_SHARED_SECRET` that is different from the scheduler secret. After deployment approval, configure the existing VPS Uptime Kuma instance to request the liveness URL every five minutes with `X-Cascade-Liveness-Secret`, and require HTTP 200. Route this infrastructure alert only to Finance/Admin. Store the value only as an Edge Function secret and protected Uptime Kuma header; do not send it to n8n, OPS, logs or this repository.

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
