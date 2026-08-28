# Wave 0 Task 0.6 Packet — Scheduler Heartbeats and Recovery

## Starting point

- Repository: `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`
- Branch: `codex/cascade-waves-0-1-sol`
- Starting commit: `78916da`

## RED

Create tests before implementation:

- `supabase/functions/_shared/cron-auth.test.ts` for exact signed-header validation.
- `supabase/functions/job-heartbeat-monitor/index.test.ts` for fresh/stale evaluation, Finance-only system failure, optional financial-free OPS risk, and stable idempotency.
- `supabase/tests/database/job_heartbeats.sql` for table/RPC/configurator contracts and deduplicated outbox events.

Expected Deno RED: missing cron-auth and heartbeat logic modules.

## GREEN

- Add `job_heartbeats` and a service-only `record_job_heartbeat` RPC.
- Extend outbox types for `system.job_stale` / `scheduled_job`.
- Build a signed monitor Edge Function that emits closed Finance and OPS templates through the guarded outbox; retries reuse deterministic idempotency keys.
- Require `X-Cascade-Cron-Secret` on turnover and monitor endpoints.
- Record turnover start/success/failure heartbeats.
- Create—but do not automatically invoke—a `configure_cascade_scheduler()` function. It verifies vault secret names, replaces `turnover-verifier-daily`, and creates a 15-minute heartbeat monitor schedule without embedding secret values in raw cron commands.

## Verification

```powershell
npx.cmd --yes deno test --no-lock supabase/functions/_shared/cron-auth.test.ts
npx.cmd --yes deno test --no-lock --node-modules-dir=auto supabase/functions/job-heartbeat-monitor/index.test.ts
npx.cmd --yes deno check --no-lock --node-modules-dir=auto supabase/functions/turnover-verifier/index.ts
npx.cmd --yes supabase test db supabase/tests/database/job_heartbeats.sql
```

The database command remains a deployment gate while local Docker/PostgreSQL is unavailable.

## Activation gate and rollback

Do not call `configure_cascade_scheduler()` until vault secrets, function deployment, staging heartbeat evidence and owner approval are present. Rollback unschedules only the two named Cascade jobs and restores the previous reviewed turnover schedule; it never edits unrelated cron jobs.

## Commit

```powershell
git add docs/plans/packets/wave-0-0.6-scheduler-heartbeats.md docs/runbooks/scheduler-recovery.md supabase/functions/_shared/cron-auth.ts supabase/functions/_shared/cron-auth.test.ts supabase/functions/job-heartbeat-monitor supabase/functions/turnover-verifier/index.ts supabase/functions/_shared/notifications.ts supabase/migrations/20260828000300_job_heartbeats.sql supabase/tests/database/job_heartbeats.sql
git commit -m "feat(cascade): monitor cron health and repair turnover schedule"
```
