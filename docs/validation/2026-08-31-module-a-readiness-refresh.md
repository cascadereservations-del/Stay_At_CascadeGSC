# Module A Local Readiness Refresh

**Date:** 2026-08-31 Asia/Manila

**Scope:** Local-only source, workflow, release and recovery readiness refresh. No production database connection, deployment, n8n activation, provider configuration, message, calendar write or VPS change was performed.

## Production gate audit (read-only)

**Date:** 2026-08-31 Asia/Manila
**Method:** Read-only queries against the active Cascade Supabase project. No migration, user, credential, storage, Edge Function or scheduler change was made.

| Gate | Observed state | Consequence |
| --- | --- | --- |
| Supabase project | Active and healthy; one active property recorded. | The production target is available for a staffed cutover. |
| Production restore point | Supabase dashboard reports that the current Free plan does not include project backups or point-in-time recovery. | Hard stop: do not apply the staff/cleaner release until an approved, tested, immutable backup/restore mechanism exists for this window. |
| Four staff/cleaner release migrations | Not present in the production ledger. | Do not publish the authenticated cleaner PWA or advance its three compatible functions. |
| Staff access / property scope schema | Not live. | Named staff roles and per-property access cannot yet be proven in production. |
| Named-cleaner audit field | Not live. | Cleaner submissions are not yet attributable to a signed-in cleaner in the new model. |
| Private `cleaning-photos` bucket | Not live. | The storage hardening portion of the cutover remains pending. |
| Anonymous inventory usage revoked | Not live. | The write-lockdown portion of the cutover remains pending. |
| Verified TOTP factors | 0 factors / 0 users. | Owner must enroll TOTP and obtain a fresh `aal2` session before privileged cutover actions. |

This confirms the release is still correctly held at its feature flags. It is not a failed deployment and must not be treated as one.

### MFA boundary clarification (2026-09-01)

The Supabase **dashboard account** now has an authenticator factor. That protects access to the Supabase administrative console, and is a valuable prerequisite for the operator.

It does **not** satisfy the Cascade application release gate on its own. The gate is checked by `auth.jwt()` inside the Cascade project: it requires a separate named **project Auth user**, bootstrapped as the first database-owned owner after the staff/RLS migration is live, then enrolled in that project's TOTP flow and issued a fresh `aal2` session. A read-only project query still showed zero verified project TOTP factors after dashboard MFA enrollment.

Do not create or bootstrap this project Auth identity before the coordinated migration cutover and a fresh production restore point. At that time, create it through the approved project Auth administration flow, bootstrap it from a database-owner session, enroll its MFA, and record only the pass/fail result and timestamp.

### Backup gate clarification (2026-09-01)

The production project's current Supabase Free plan explicitly reports that it has no scheduled backups or point-in-time recovery. The existing release contract requires a fresh immutable restore point, so this is a release **stop condition**, not an optional improvement.

Resolve it in one of two owner-approved ways before a cutover: enable a Supabase plan with a production-native restore point, or revise the release contract only after a separate, reviewed runbook proves an encrypted external logical backup and restore exercise for the actual production database. Do not substitute a local schema snapshot, a source migration list, or the disposable development recovery proof for a production-data backup.

## Verified results

| Check | Command | Result |
| --- | --- | --- |
| Platform safety | `npm.cmd run test:platform-safety` | PASS — 37 tests, 0 failures. |
| Release source ancestry and contract | `git merge-base --is-ancestor <release-source> HEAD` and `node scripts/migrations/verify-expand-contract.mjs --release ...` | PASS — the locked source is an ancestor of the documented release state; the four-migration contract verified. |
| Staff/cleaner cutover preflight | `npm.cmd run preflight:local -- --release supabase/releases/20260830_staff_cleaner_cutover.release.json` | PASS — release `staff_cleaner_cutover_20260830`, 4 required migrations. |
| n8n source graph | `node scripts/check-n8n-workflows.mjs` | PASS — 13 inactive source exports. |
| Disposable n8n recovery | `npm.cmd run recovery:n8n` | PASS — 13 workflows imported/exported semantically; all inactive; no persistent container started. |
| Tracked production inventory comparison | `node scripts/audit/compare-supabase-production.mjs --check` | PASS — 21 deployed functions: 12 recovered + 9 versioned; 33 tables, 52 policies, 33 RLS tables in tracked snapshot. |
| Secret scan | `node scripts/audit/scan-secrets.mjs` | PASS — no high-confidence credential patterns. |

## Final source-control rerun (2026-09-01)

The non-production controls were rerun after the cutover-plan and external-backup candidate updates:

| Check | Result |
| --- | --- |
| `npm.cmd run test:platform-safety` | PASS — 37 tests, 0 failures. |
| `node scripts/check-n8n-workflows.mjs` | PASS — 13 inactive workflow exports. |
| `node scripts/audit/scan-secrets.mjs` | PASS — no high-confidence credential patterns. |
| `git diff --check` | PASS — no whitespace errors. |

These results verify source controls only. They do not close the production backup, project-Auth, cleaner, scheduler, or shared-n8n-runtime gates.

### External-backup candidate fail-closed check

On 2026-09-01, `scripts/recovery/backup-supabase-production.ps1` was invoked without `CASCADE_PRODUCTION_DATABASE_URL`. It correctly refused before any database/tool invocation, and no test backup directory was created. The existing `postgres:17` Docker image was also inspected and contains `pg_dump`, `pg_restore`, and OpenSSL. This proves only the missing-credential guardrail and available local runtime; it is not a backup or restore proof.

## Disposable Supabase recovery rerun

The local disposable Supabase recovery command was started on 2026-08-31. Its uniquely named `cascade-recovery-*` database became healthy, but the process did not reach its final evidence output/cleanup in the tool window. It was therefore **not recorded as a new successful recovery proof**.

The exact disposable project was safely stopped with:

```powershell
npx.cmd supabase stop --project-id cascade-recovery-3c524742fb76 --no-backup --yes
```

Post-cleanup verification found no `cascade-recovery-*` containers or volumes. The active local `supabase_db_direct-booking` container remained healthy and running. This is a cleanup/audit result, not a replacement for the successful 2026-08-30 disposable recovery evidence in `docs/validation/2026-08-30-wave-0-recovery-report.md`.

## Interpretation

Module A local source readiness remains strong: release contracts, workflow safety, authority boundaries, recovery contracts, degraded-mode rules and secret scanning are current. The following remain external, action-time gates and cannot be inferred from these tests:

1. Owner TOTP enrollment and fresh `aal2` proof.
2. Real cleaner account/property assignment and authenticated production smoke test.
3. Fresh production backup/restore point and ledger reconciliation.
4. Scheduler/liveness secrets, deployment and Uptime Kuma activation evidence.
5. Shared Portainer n8n database/credential/encryption-key restore exercise.

See `docs/plans/2026-08-31-module-a-cutover-packet.md` for the exact owner-approved sequence.
