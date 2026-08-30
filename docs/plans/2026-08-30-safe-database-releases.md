# Safe Database Releases Implementation Plan

**Goal:** Make every Cascade production database release fail closed unless its migration files, backup/restore point, forward checks, feature gates, compatibility phase and compensating rollback are explicit and locally verified.

**Architecture:** A pure Node module validates a versioned JSON release contract and scans referenced SQL before any database command runs. Thin CLI wrappers perform static expand/contract verification and, for `--local`, compare the contract with the local Supabase migration ledger; they never apply or roll back a migration. The first contract describes the coordinated staff/RLS/named-cleaner release candidate.

**Tech Stack:** Node.js built-ins, JSON, Supabase CLI migration metadata, Node test runner, Markdown runbook.

---

### Task 1: Release-contract validator

**Files:**
- Create: `scripts/migrations/release-safety.mjs`
- Create: `tests/migrations/release-safety.test.mjs`

- [ ] Write tests that require schema version, release ID, ordered migration versions, backup/restore point, non-empty forward checks, compensating rollback, feature flags and cutover phase.
- [ ] Run `node --test tests/migrations/release-safety.test.mjs`; expect failure because `release-safety.mjs` does not exist.
- [ ] Implement `validateReleaseContract(contract)`, `validateMigrationFiles(contract, root)`, `findUnsafeExpandSql(sql)` and `parseAppliedMigrationVersions(output)` using Node built-ins only.
- [ ] Rerun the test and expect all validator tests to pass.

### Task 2: Static and local preflight CLIs

**Files:**
- Create: `scripts/migrations/verify-expand-contract.mjs`
- Create: `scripts/migrations/preflight.mjs`
- Modify: `tests/migrations/release-safety.test.mjs`

- [ ] Add subprocess tests proving the verifier rejects a destructive expand migration and accepts an additive fixture, and that preflight rejects a missing local migration version.
- [ ] Run the focused test; expect command-not-found/non-zero failures because the CLIs do not exist.
- [ ] Implement `verify-expand-contract.mjs` as a static, read-only validator and `preflight.mjs` as a fail-closed wrapper that adds local migration-ledger comparison only when `--local` is supplied.
- [ ] Rerun the focused test and expect every subprocess case to pass.

### Task 3: Current coordinated cutover contract

**Files:**
- Create: `supabase/releases/20260830_staff_cleaner_cutover.release.json`
- Modify: `tests/migrations/release-safety.test.mjs`

- [ ] Add a test loading the real contract and asserting exact ordered references to operational RLS, staff identities, DB-backed authorization and named-cleaner migrations.
- [ ] Run the test; expect failure because the release contract does not exist.
- [ ] Add the versioned release contract with backup/restore evidence requirements, forward queries, compatibility flags, stop conditions and non-destructive compensating actions. Do not include credentials or authorize deployment.
- [ ] Run `node scripts/migrations/verify-expand-contract.mjs` and `node scripts/migrations/preflight.mjs --local`; expect both to pass against the migrated local development database.

### Task 4: Operator runbook and regression integration

**Files:**
- Create: `docs/runbooks/database-release.md`
- Modify: `package.json`
- Modify: `docs/plans/module-execution-queue.md`
- Modify: `docs/plans/HANDOFF-2026-08-30-sol-security-and-release-preflight.md`

- [ ] Document expand/backfill/dual compatibility/verify/contract, immutable backup evidence, production approval boundaries, dry-run commands, stop conditions and compensating rollback rules.
- [ ] Add `test:release-safety` and `preflight:local` scripts.
- [ ] Run focused tests, the static verifier, local preflight, existing content tests and `git diff --check`.
- [ ] Commit with `test(cascade): enforce expand contract database releases`.

### Completion evidence

- The tooling never applies, deploys, rolls back or sends anything.
- Expand releases reject destructive SQL before any database connection.
- Contract releases require explicit compatibility verification and a separate approval gate.
- Local preflight proves required migration versions exist both in source and the local ledger.
- Production mode requires immutable source/backup evidence and remains a manual SOL/owner action.
