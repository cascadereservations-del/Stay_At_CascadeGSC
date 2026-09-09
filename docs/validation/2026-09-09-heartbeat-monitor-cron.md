# Heartbeat monitor cron wiring — pre-state and rollback record

**Release:** `20260909_heartbeat_monitor_cron` · **Applied:** 2026-09-09 ~15:30 UTC, 4/4 · **Path:** `apply-release-on-host.sh`

## Pre-release state (read 2026-09-09 15:20 UTC)

| Job | Schedule | Command (pre-release) |
|---|---|---|
| `turnover-verifier-daily` (id 8) | `0 0 * * *` | `SELECT net.http_post(url := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/turnover-verifier', headers := '{"Content-Type":"application/json"}'::jsonb, body := '{}'::jsonb) AS request_id;` |
| `job-heartbeat-monitor-every-15m` | — | did not exist |

Pre-state `--verify-only`: 3 FAIL (monitor job absent, job 8 without header, monitor count 0),
1 ok (no secret value embedded anywhere). Post-apply: 4/4.

## What the release does

- Schedules `job-heartbeat-monitor-every-15m` at `*/15 * * * *`.
- Rewrites job 8's command to add `x-cascade-cron-secret`, read at run time from
  `vault.decrypted_secrets` where `name = 'cascade_cron_shared_secret'`.

Until that Vault secret exists the header is null: `job-heartbeat-monitor` answers 401 on every
run (it requires the secret) and `turnover-verifier` keeps working exactly as before (its check
is conditional, D-036). Nothing is delivered anywhere until CH-S01 is live (P9 #1).

## Rollback

```sql
select cron.unschedule('job-heartbeat-monitor-every-15m');
select cron.alter_job(job_id := 8, command := $$
  SELECT net.http_post(
    url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/turnover-verifier',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body    := '{}'::jsonb
  ) AS request_id;
$$);
```

Package the rollback as a release contract too; do not run it through the MCP.

## Lloyd's two steps to switch it on

1. In the SQL editor, as the owner (value never leaves the editor):
   `select vault.create_secret('<value>', 'cascade_cron_shared_secret');`
2. `npx supabase secrets set CASCADE_CRON_SHARED_SECRET=<same value> --project-ref qkgfhsdppslwunarczeq`

Both must be the same value and land in the same sitting. Then the next 15-minute tick writes a
`job-heartbeat-monitor-every-15m` row to `job_heartbeats` — that row appearing is the proof.
