# Runbook — a scheduled job's heartbeat is stale

**Trigger:** an `⚠️ Cascade System Failure` (Finance route) or `⚠️ Operational Automation Risk`
(OPS route) message from CH-S01, or a `system.job_stale` row in `automation_outbox`, or — until
the monitor is deployed — a manual look at `public.job_heartbeats`.

## 1. See what the platform thinks (30 s, read-only)

```sql
select job_name, expected_interval_seconds, last_started_at, last_succeeded_at,
       last_error_code, consecutive_failures, ops_risk
from public.job_heartbeats order by last_started_at desc nulls last;
```

Three reason codes, from `job-heartbeat-monitor/logic.ts`:

| Reason | Meaning | First move |
|---|---|---|
| `JOB_NEVER_SUCCEEDED` | no `last_succeeded_at` at all | the job never ran, or ran and failed every time — check its pg_cron row exists and is `active` |
| `JOB_CONSECUTIVE_FAILURE` | started after its last success and `consecutive_failures > 0` | read the function's logs for `last_error_code` |
| `JOB_HEARTBEAT_STALE` | quiet for more than 1.5 × `expected_interval_seconds` | pg_cron stopped firing, or the function is 401-ing |

## 2. Match the job to its cron row and function

```sql
select jobid, jobname, schedule, active, left(command, 120) from cron.job order by jobid;
```

| Job | pg_cron | Function | Auth |
|---|---|---|---|
| `turnover-verifier-daily` | id 8, `0 0 * * *` | `turnover-verifier` | cron secret is **conditional** (D-036) — enforced only when `CASCADE_CRON_SHARED_SECRET` is set |
| `job-heartbeat-monitor-every-15m` | *(to be created)* | `job-heartbeat-monitor` | cron secret **required** — 401 until the secret exists |
| `calendar-sync-6h`, `daily-digest-ops-0700`, `weekly-finance-monday-0700`, `rain-alert-2h`, `missed-cleaning-alert` | ids 1,3,4,5,7 | same-named functions | as deployed |
| `nightly-finance-reconcile` | id 6 | SQL only | n/a |

## 3. The usual causes, in order of likelihood

1. **Secret mismatch.** Someone set `CASCADE_CRON_SHARED_SECRET` without updating job 8's
   header in the same change — every run 401s. Fix both together, never one.
2. **Function redeployed with a broken import** — check the function's invocation logs for the
   last 24 h; a boot error shows on every call.
3. **pg_cron paused** — `active = false` on the row, or the extension restarted.
4. **The job genuinely failed** — `last_error_code` names it; follow that function's own notes.

## 4. What NOT to do

- Never invoke `turnover-verifier` without `?dry=1` to "test" — it messages Finance/OPS.
- Never delete `job_heartbeats` rows to "reset" a stale alert; the monitor de-duplicates on
  `(job, reason, stale_reference)` and will simply re-raise.
- Never patch the function or the cron row through the Supabase MCP; that is how ledger drift
  and unrecorded changes happen. Change source, then deploy from source.

## 5. Close out

Once `last_succeeded_at` advances, the next monitor run stops enqueuing. Record the cause in
`02-DECISIONS` only if it changed a rule; otherwise a line in the session note is enough.
