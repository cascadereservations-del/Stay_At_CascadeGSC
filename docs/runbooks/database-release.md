# Cascade database release runbook

## Purpose and authority

This runbook makes a database change reviewable; it does not authorize production deployment. Construction, local verification and production execution are separate tasks. Production requires a named owner approval, a SOL review, a staffed cutover window and a fresh immutable restore point. The repository scripts are read-only: they validate source and compare migration ledgers, but never apply, deploy, roll back or send anything.

## Release sequence

Use these phases for every breaking change:

1. **Expand** — add nullable columns, new tables, indexes, functions or parallel policies while old readers and writers still work. Expand SQL may not drop/rename tables or columns, change a column type, truncate, or delete data.
2. **Backfill** — copy or derive data in bounded, restartable batches. Record counts, rejected rows and the idempotency key. Do not make the old path unreadable.
3. **Dual compatibility** — enable a feature-gated dual-read or dual-write path. Compare old and new projections; keep the new reader/writer flag off until the comparison passes.
4. **Verify** — run every `forward_verification` query, reconcile counts and prove rollback/restore evidence. A passing migration command is not a verification result.
5. **Contract** — remove the obsolete access/path only in a separate approved release after compatibility is explicitly recorded as verified. Security cutovers that cannot preserve the old path must use one coordinated, staffed backend/client window and state that incompatibility in the contract.

## Machine-readable contract

Create one `supabase/releases/<release>.release.json`. It must contain:

- exact, ordered migration filenames, normalized-content SHA-256 hashes and an immutable source commit;
- backup requirement, restore-point identifier and verification timestamp;
- one read-only `SELECT`/`WITH` forward check per invariant, with an explicit expected scalar result;
- compensating rollback steps and the point after which restore/forward-fix is required;
- feature gates and their required pre-release state;
- compatibility evidence, production approval requirement and stop conditions.

Never put passwords, tokens, connection strings, guest data, bank references or secret values in the contract or command output.

## Local construction gate

From the isolated release worktree:

```powershell
npm run test:release-safety
node scripts/migrations/verify-expand-contract.mjs --release supabase/releases/20260830_staff_cleaner_cutover.release.json
node scripts/migrations/preflight.mjs --local --release supabase/releases/20260830_staff_cleaner_cutover.release.json
```

The static verifier checks contract completeness, each migration’s normalized-content SHA-256, exact source files and destructive SQL in an expand phase. Local preflight also proves the source commit is in the current branch ancestry and adds a read-only comparison with the local Supabase migration ledger. `--ledger-file` is for deterministic CI/test fixtures only; it is not production evidence.

## Production preflight

Stop unless all items are true:

1. The feature branch is clean, reviewed and points to the contract’s immutable source commit.
2. A fresh production migration list matches the expected baseline exactly; connector-generated versions are reconciled to repository filenames.
3. The owner has explicitly approved this production action. Staff/finance authorization releases also require a fresh `aal2` owner session.
4. A production-native immutable backup/restore point was created in the cutover window, its identifier recorded outside chat, and a restore operator is available.
5. Old/new application compatibility matches the declared phase. Every new writer/reader feature flag is in the contract’s required state.
6. Edge Functions, PWA/static assets and rollback artifacts are ready to deploy in the documented order.
7. Monitoring and correlation IDs are ready, while OPS routes remain free of Finance data.

The repository preflight intentionally has no production-connect or apply mode. Capture production evidence with approved Supabase tooling, review it, then execute migrations through the approved migration mechanism. Do not paste production credentials into a terminal transcript or release JSON.

## Forward verification and cutover

- Apply only the exact ordered migrations in the reviewed contract.
- Stop after each migration when the ledger version, schema shape or advisory result differs.
- Run each forward query and record its scalar result; do not substitute visual inspection.
- Keep new readers/writers disabled until their compatibility check passes.
- For a coordinated security cutover, deploy the backend boundary first only when the client can immediately follow in the same staffed window. If either artifact is unavailable, do not begin.
- Smoke-test with synthetic/non-financial fixtures. Sending Telegram/email/provider messages or publishing workflows needs its own approval.

## Compensating rollback

Rollback means returning service to a safe state, not pretending converted data never existed.

- Before any new production write: disable the new reader/writer, restore the prior application artifact and, only when explicitly proven safe, reverse additive objects.
- After a new write or data conversion: stop writers and use a forward fix or the approved restore point. **Do not run a destructive down migration after data conversion.**
- Access-control failures fail closed. Do not restore anonymous or broad authenticated access merely to keep a client working; restore the compatible client/backend pair or hold operations manually.
- Preserve audit/outbox rows unless the approved restore operation necessarily reverts the whole database.

## Mandatory stop conditions

Stop and record the mismatch when any of these occurs:

- source migration hash/order differs from the production ledger;
- backup evidence is absent, stale or un-restorable;
- a forward query differs from its expected result;
- a feature gate cannot be proven off/on as required;
- an old reader/writer is incompatible earlier than declared;
- RLS, Auth/MFA, private storage or Finance/OPS boundaries differ from the reviewed contract;
- an operator proposes editing a deployed migration, force-marking production history, or running a destructive down migration.

After a stop, leave workflows/schedulers unpublished, preserve evidence, and create a new reviewed forward migration or a formally approved restore procedure.
