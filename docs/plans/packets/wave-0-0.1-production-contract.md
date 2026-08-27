# Wave 0 Task 0.1 Packet — Freeze Production Contract

## Starting point

- Repository: `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`
- Branch: `codex/cascade-waves-0-1-sol`
- Starting commit: `a1b700c`
- Production project: `qkgfhsdppslwunarczeq`

## Preconditions and evidence

- Read `docs/validation/2026-08-24-booking-production-backend-report.md`.
- Read `supabase/config.toml` and enumerate `supabase/functions/*/index.ts`.
- Capture only safe Edge Function fields from the read-only CLI: slug, version, status, JWT setting, update time and deployment hash.
- Never commit function IDs, temporary entrypoint paths, tokens, database URLs, raw cron commands or secret values.
- The 2026-08-28 read-only inventory contains 21 active functions. `upload-photo` is a critical missing-source function and is added to the recovery scope.

## RED

Create `tests/production-contract.test.mjs` importing `evaluateProductionContract` and `validateSafeSnapshot` from the not-yet-created audit script. Cover:

1. Local deployed source is classified `versioned`.
2. A critical deployed function without `index.ts` is classified `missing-source` and creates a blocking error.
3. Noncritical local-only helpers do not create a production-source failure.
4. Snapshots containing secret-like keys, deployment IDs or temporary entrypoint paths are rejected.

Run:

```powershell
node --test tests/production-contract.test.mjs
```

Expected RED: `ERR_MODULE_NOT_FOUND` for `scripts/audit/compare-supabase-production.mjs`.

## GREEN

Create:

- `scripts/audit/compare-supabase-production.mjs`
- `docs/architecture/production-contract.json`
- `docs/architecture/production-inventory.md`

The script must accept an injected root/snapshot for tests, classify every deployed function, list local-only functions, reject unsafe snapshot fields, and make `--check` nonzero whenever a business-critical deployed function is missing local source. The Markdown inventory must name the broken `turnover-verifier-daily` schedule and clearly separate observed facts from unverified metadata.

Run:

```powershell
node --test tests/production-contract.test.mjs
node scripts/audit/compare-supabase-production.mjs
node scripts/audit/compare-supabase-production.mjs --check
```

Expected GREEN for the unit test. The real `--check` is expected to block until Task 0.2 recovers the missing production sources; that nonzero result proves the guard is active and is not waived.

## Forward verification and rollback

- Forward: re-run the read-only function list and compare safe fields with `production-contract.json`; run the unit test and checker.
- Smoke check: every one of the 21 deployed slugs appears once in the generated inventory.
- Rollback: revert only this task's commit; no database, function or workflow is deployed by this packet.
- Stop if the live project ref differs, the function count changes during capture, or the CLI reports an unknown authentication profile.

## Commit

```powershell
git add docs/plans/packets/wave-0-0.1-production-contract.md docs/architecture/production-contract.json docs/architecture/production-inventory.md scripts/audit/compare-supabase-production.mjs tests/production-contract.test.mjs
git commit -m "docs(cascade): freeze production function and schema inventory"
```
