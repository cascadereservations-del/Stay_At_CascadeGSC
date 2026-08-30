# Wave 0 recovery proof

**Verification window:** 2026-08-31 Asia/Manila / 2026-08-30 UTC

**Repository:** `direct-booking-waves-0-1-sol`

**Branch:** `codex/cascade-waves-0-1-sol`

**Mode:** disposable local recovery only; no production connection, deployment, workflow activation or provider message

## Verdict

**Local source-level recovery: PASS.** All 13 source-controlled n8n workflows round-tripped through pinned n8n 2.34.6 and remained inactive. A uniquely named disposable Supabase database rebuilt from the hash-bound recovery chain, applied all 27 recovery migrations and passed all 14 database test files without changing the active `direct-booking` database identity.

**Production disaster recovery: GATED.** This exercise does not prove restoration of the shared Portainer n8n database, credential ciphertext, encryption key or execution history. An owner-approved backup and restore exercise for those runtime assets remains required before production recovery readiness can be claimed.

## Evidence

### Recovery contracts

Command:

```powershell
npm.cmd run test:recovery
```

Expected: recovery CLIs fail closed outside their disposable prefixes, workflows compare semantically, and the Supabase baseline/configuration contract is hash-bound.

Actual: **12/12 passed**, zero failures. The Windows `npx.cmd` launch path was also exercised.

### Disposable n8n import/export

Command:

```powershell
npm.cmd run recovery:n8n -- --output <OS-temp>\cascade-wave0-n8n-evidence.json
```

Evidence timestamp: `2026-08-30T16:36:29.661Z`

| Check | Actual |
|---|---|
| Image | `n8nio/n8n:2.34.6` |
| Image digest | `sha256:f5140088385af2d4e681e177d8264bcb41e8fe126062030c5c65cd8f3e1605e1` |
| Source workflows | 13 |
| Imported workflows | 13 |
| Exported workflows | 13 |
| All inactive | yes |
| Semantic set hash | `d3077384d1bca5cf6d9941eb1a104183c3348f964ebba49741baf6436c4cd8ce` |
| Persistent n8n container started | no |

The round trip covers `CH-S01` and `CH-W01` through `CH-W12`. Generated n8n IDs and timestamps are excluded from comparison; workflow names, nodes, connections, settings, tags and inactive state remain part of the semantic contract.

### Disposable Supabase rebuild

Command:

```powershell
npm.cmd run recovery:supabase -- --output <OS-temp>\cascade-wave0-supabase-evidence.json
```

Evidence timestamp: `2026-08-30T16:39:11.392Z`

| Check | Actual |
|---|---|
| Supabase CLI | 2.116.0 |
| PostgreSQL image | `public.ecr.aws/supabase/postgres:17.6.1.165` |
| Historical migrations replaced by baseline | 44 |
| Forward migrations | 24 |
| Recovery-chain migrations | 27 |
| Applied migrations | 27 |
| Database test files | 14 |
| Active database identity unchanged | yes |
| Production connection used | no |

The recovery chain is deliberately different from normal forward production deployment:

1. `supabase/recovery/prerequisites.sql` installs required extensions.
2. `supabase/schemas/000_remote_public_schema.sql` supplies the hash-bound historical production baseline.
3. `supabase/recovery/pre_forward_compat.sql` removes baseline policies that the preserved forward migrations recreate.
4. Migrations after the snapshot boundary replay unchanged, ending at `20260830070000_fix_price_history_view_recursion.sql`.

The script copies only the versioned Supabase tree to an OS temporary directory, assigns a `cascade-recovery-` project ID and different ports, disables seed execution, resets the disposable database, checks its ledger and tests, compares the active database identity, then stops only the exact disposable project with `--no-backup`.

## Defects found and corrected

1. The raw historical migration sequence was not independently rebuildable because its earliest retained migrations assumed legacy inventory objects already existed. Recovery now uses a checksum-bound production-schema baseline plus the original post-snapshot migrations.
2. `public.price_history_by_item` recursively selected from itself in the tracked production schema and in read-only production verification. The baseline definition now selects from `inventory_purchases` joined to `inventory_items`; migration `20260830070000_fix_price_history_view_recursion.sql` and a pgTAP regression test are versioned locally. The migration is **not deployed**.
3. Three pgTAP files depended on a pre-existing property row. They now create rollback-scoped synthetic fixtures.
4. Snapshot default privileges allowed `service_role` to insert into `job_heartbeats`. The local heartbeat migration now explicitly revokes that insert privilege while retaining its intended read boundary.
5. The scheduler test now stages disposable Vault values inside a transaction, verifies the two named jobs and shared-secret header contract, and rolls back before any schedule can persist or execute.
6. A host interruption left one correctly prefixed disposable database container. Its Compose/Supabase labels and sole volume were inspected, the exact project was stopped with `--no-backup`, its validated OS-temp directory was removed, and the proof was rerun successfully. No `stop --all` or broad cleanup command was used.
7. Final Playwright verification exposed two mobile tests using Playwright's stability-waiting scroll against an animated section. They now use the same instant DOM-scroll pattern already established for animated images; the two focused tests and the complete browser suite pass without changing production UI behavior.

## Cross-check matrix

| Command | Result |
|---|---|
| `node scripts/audit/compare-supabase-production.mjs --check` | pass; 21 deployed = 12 recovered + 9 versioned |
| `node scripts/check-n8n-workflows.mjs` | pass; 13 inactive exports |
| `node scripts/audit/scan-secrets.mjs` | pass |
| `node --test tests/security/endpoint-boundaries.test.mjs` | 3/3 pass |
| `npm.cmd run test:release-safety` | 16/16 pass |
| `node scripts/migrations/preflight.mjs --local --release supabase/releases/20260830_staff_cleaner_cutover.release.json` | pass; 4 required migrations present |
| `npm.cmd run test:content` | 30/30 pass |
| `npm.cmd run test:e2e -- --workers=1` | 54/54 pass |
| Disposable-resource filters after proof | no `cascade-recovery-` containers or volumes |
| Active local database after proof | healthy; identity unchanged |

## Remaining gates

- Back up and restore the actual shared Portainer n8n PostgreSQL/SQLite data, credential ciphertext and encryption key in an owner-approved maintenance window.
- Confirm dedicated `Cascade — <provider/purpose>` credentials and access separation in the shared n8n runtime.
- Resolve/export the duplicate W01 draft before any workflow publication.
- Apply and verify the price-history view correction through the normal production release contract.
- Capture a fresh production database backup/restore point before the coordinated staff/RLS/cleaner cutover.

Wave 0.8 is therefore **complete for local source recoverability** and remains **gated for production runtime disaster recovery**.
