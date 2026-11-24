# Guide v8 backend SQL: release package (s135), NOT APPLIED

Branch `s135/guide-v8-sql`, worktree `C:\Users\Lloyd\Claude\Projects\Cascade\s135-guide-sql`, based on origin/main `5e7a0df` (s134 stamp). Nothing was run against production or the backup host.

## Files

| File | What |
|---|---|
| `supabase/migrations/20261206000000_guide_v8_messages_analytics.sql` | The migration. Re-timed from 20261205000000 to 20261206000000 in s136 because cf_confirm_flow holds 20261205000000 live. sha256 `5602950d120a12a65296fa2462de93c74bd09be20e94eb62563e0aab7bb430ad` (LF-normalised; differs from the cloud file by the file name header and the removed begin/commit, the runner wraps the file). Staff thread / reply / resolve raise P0002 for a missing thread before the 42501 access check. |
| `supabase/rollbacks/20261206_guide_v8.sql` | Drops the trigger, 12 functions and 5 tables. Byte-equal to the cloud file. |
| `supabase/releases/20261206_guide_v8.release.json` | Release contract, same keys as `s134_expenses_20261204.release.json`. 8 forward checks from the verify file. |
| `supabase/tests/database/guide_v8_messages_analytics.sql` | pgTAP suite, `plan(72)`. |
| `supabase/sql/2026-12-06-guide-v8-verify.sql` | The 8 read-only checks (run through `run-sql-on-host.sh` after the apply). Byte-equal to the cloud file. |
| `docs/s135/guide-v8-backend-README.md` | The cloud README, byte-equal. |

Contract notes you should know:

1. `phase` is `backfill`, not `expand`. `release-safety` refuses `DELETE FROM` anywhere in an expand migration and `guide_sweep_v1` (housekeeping of the new tables) contains three. Other releases with `DELETE FROM` in their SQL (s99, s107, s108, s110) use `backfill` too. The migration deletes no existing row.
2. `source.commit` is the base commit `5e7a0df...` (40 characters, ancestor of HEAD). The SQL lands in the commit after it. Restamp it with the SQL commit sha if you want it to point at the SQL, as the s134 stamp commit did.
3. `backup.restore_point` and `verified_at` are placeholders; the block below stamps them with `fill-restore-point.mjs` after a fresh backup.
4. `compatibility.verified` is `false` until the rehearsal has run; replace `compatibility.evidence` with the rehearsal result afterwards.
5. `accepted_failing_tests` copies the `--no-acl` baselines of the other suites from the s134 contract. Re-measure on the rehearsal copy.

## Validation run on the PC (2026-11-24)

```
runner check (validateReleaseContract + validateMigrationFiles + validateSourceState):
contract valid: guide_v8_messages_analytics_20261206 (backfill), 1 migrations, source.commit ancestor of HEAD
node scripts/migrations/verify-expand-contract.mjs --release supabase/releases/20261206_guide_v8.release.json   -> exit 0 (silent)
npm run test:release-safety   -> tests 17, pass 17, fail 0
npm run test:platform-safety  -> tests 43, pass 43, fail 0
node scripts/migrations/preflight.mjs --local ...  -> not usable here (needs the local Supabase stack, Docker is not running); left out of the block
```

The pgTAP suite could not run on the PC (no Docker, no pgTAP; the real run is the rehearsal below). It was run in the cloud sandbox on local Postgres 16 with stubs for `verify_booking`, `current_staff_authorized`, `calendar_events`, `auth` and a small pgTAP shim, against the current migration: `# planned 72 ran 72 failed 0`. The real `verify_booking` and the real restored tables are what the rehearsal adds.

The suite disables the push trigger inside its own transaction so a rehearsal can never queue an HTTP call to the production `notify-staff-inbox`.

## The block (PowerShell 5.1, one paste)

Order: checks, fresh backup, stamp, rehearsal with the pgTAP suite, a typed APPLY gate, apply, verify. It stops at the first failure.

```powershell
$ErrorActionPreference = 'Stop'
$bash = 'C:\Program Files\Git\bin\bash.exe'
$wt   = '/c/Users/Lloyd/Claude/Projects/Cascade/s135-guide-sql'
$rel  = 'supabase/releases/20261206_guide_v8.release.json'
$ssh  = '/c/Windows/System32/OpenSSH/ssh.exe'
function Step([string]$name, [string]$cmd) {
  Write-Host ''; Write-Host "=== $name" -ForegroundColor Cyan
  & $bash -lc "cd $wt && export CASCADE_SSH_BIN=$ssh && $cmd"
  if ($LASTEXITCODE -ne 0) { throw "STOPPED at '$name' (exit $LASTEXITCODE). Nothing after this step ran." }
}

Step '1 branch is s135/guide-v8-sql' '[ $(git rev-parse --abbrev-ref HEAD) = s135/guide-v8-sql ] && git log -1 --oneline && git status --short'
Step '2 release-safety tests' 'npm run test:release-safety'
Step '3 contract and source commit check' 'node scripts/migrations/verify-expand-contract.mjs --release supabase/releases/20261206_guide_v8.release.json'
Step '4 fresh backup' 'bash scripts/recovery/p5/supabase-backup-over-alfred.sh'
Step '5 stamp restore point' 'node scripts/migrations/fill-restore-point.mjs /c/Cascade-Backups supabase/releases/20261206_guide_v8.release.json'
Step '6 rehearsal on Alfred (apply, forward checks, pgTAP 73)' 'SET=$(ls -d /c/Cascade-Backups/cascade-supabase-* | sort | tail -1); echo backup set $SET; REHEARSAL_TAP_LINES=all bash scripts/recovery/p6/migration-rehearsal-on-host.sh $SET supabase/releases/20261206_guide_v8.release.json supabase/tests/database/guide_v8_messages_analytics.sql'

$ans = Read-Host 'Rehearsal above: forward checks all ok, guide_v8 suite 73 of 73, cleanup leftovers 0? Type APPLY to go to production'
if ($ans -ne 'APPLY') { throw 'Stopped by you before the apply. Nothing was applied.' }

Step '7 apply to production' 'bash scripts/migrations/apply-release-on-host.sh supabase/releases/20261206_guide_v8.release.json'

Write-Host ''; Write-Host '=== 8 verify (8 rows, all t)' -ForegroundColor Cyan
$out = & $bash -lc "cd $wt && export CASCADE_SSH_BIN=$ssh && bash scripts/migrations/run-sql-on-host.sh supabase/sql/2026-12-06-guide-v8-verify.sql"
if ($LASTEXITCODE -ne 0) { throw "STOPPED at verify (exit $LASTEXITCODE)." }
$out
$good = @($out | Select-String -Pattern '\|\s*t\s*$').Count
$bad  = @($out | Select-String -Pattern '\|\s*f\s*$').Count
if ($good -ne 8 -or $bad -ne 0) { throw "VERIFY FAILED: $good ok, $bad not ok (need 8 and 0). Rollback: supabase/rollbacks/20261206_guide_v8.sql" }
Write-Host 'Guide v8 SQL applied and verified (8 of 8).' -ForegroundColor Green
```

After a green run:

1. `git -C C:\Users\Lloyd\Claude\Projects\Cascade\s135-guide-sql status` shows the stamped `release.json`; commit it (`s135: stamp guide v8 restore point`).
2. Add `select public.guide_sweep_v1();` to the weekly sweep, or a pg_cron job `guide-sweep-weekly` (service_role).
3. Check `notify-staff-inbox` accepts `{kind:'guest_wrote', psid:'guide:<uuid>'}` from the database caller (cron-secret path); if only service role may send that kind, add the database path in the waves repo. Until then guest messages arrive but the owner phone push is silent.

Rollback (clients first: revert the guide v8.0.0 frontend and the Staff Guide inbox): `bash scripts/migrations/run-sql-on-host.sh supabase/rollbacks/20261206_guide_v8.sql` from `stay-site`-style Git Bash with `CASCADE_SSH_BIN` set. Export `public.guide_messages` first if the messages matter.
