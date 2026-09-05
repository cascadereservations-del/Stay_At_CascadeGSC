# Cascade local operational handoff

**Status:** Wave 8 local operating contract. Production remains frozen.

## Operating authority

Use `docs/architecture/cascade-authority-inventory.json` as the machine-checkable map from each business domain to its single canonical Supabase decision boundary. The inventory records the named-human authority, advisory inputs, forbidden effects, source migration, and dated validation for every completed local wave.

n8n is delivery only. All 13 source exports remain inactive. A passing draft, forecast, comparison, eligibility result, or review never becomes a provider action unless a separate approved delivery boundary exists and has fresh activation approval.

## Named-human decision queue

| Decision | Required human authority | Evidence that must be visible |
| --- | --- | --- |
| Booking and payment confirmation | Finance/Admin at fresh AAL2 | Final Finance review, exact inquiry, comparison, and idempotency key |
| Booking lifecycle exception or refund | Authorized booking manager; named refund approver | Current lifecycle state, collision result, reason, and immutable audit |
| Cleaning evidence | Named inspector; operations manager for override | Cleaner/session/property binding, evidence hash, advisory reason codes |
| Inventory shopping list | Owner/Admin at fresh AAL2 | Locked stock state, recorded-usage forecast, quantity, reason |
| Finance reconciliation and targets | Finance/Admin; owner for targets | Both sources, comparison outcome, reviewed fact, effective target period |
| CRM consent, lifecycle, and retention | Owner/Admin at fresh AAL2 | Purpose, evidence hash, effective time, recovery and retention state |
| Marketing draft review | Owner/Admin at fresh AAL2 | Current eligibility, exact content hash, targeting decision, discount and claim evidence |

## Start-of-session control

1. Verify the canonical path, Git branch, current commit, and dirty-file inventory.
2. Preserve the unrelated Task Master files listed in `RESUME-PROMPT.md`.
3. Read the latest validation record and state whether evidence is local, dated live metadata, or current production proof.
4. Run the focused test for the domain plus platform safety, inactive-workflow, secret, and whitespace checks.
5. Stop before any production, provider, order, publication, Docker, VPS, DNS, or workflow action.

## Access review

For a local release candidate, verify that decision RPCs require authenticated named staff, property scope, active accounts, non-revoked sessions, and AAL2 where defined. Confirm direct table mutation is unavailable, service roles do not hold human decision functions, Finance data cannot reach OPS, and raw guest contact is absent from CRM and marketing tables.

For production, repeat the review with current project Auth identities, real property assignments, TOTP enrollment, fresh AAL2, real cleaner authorization, and disabled-user/session-revocation smoke tests. Source checks do not satisfy that production gate.

## Recovery and incident drills

- Database source recovery: use `scripts/recovery/verify-supabase-reset.mjs` only with its disposable `cascade-recovery-*` project guard. Verify the active local database identity is unchanged.
- Workflow recovery: use `scripts/recovery/verify-n8n-restore.mjs` only with its disposable volume guard. Import and export all workflows inactive and compare semantic hashes.
- Wave rollback: run each wave’s validation script against a disposable restored database. Never use a compensating rollback against production without a reviewed release decision.
- Provider incident: follow `degraded-operations.md`; preserve canonical state, acknowledge safely, and require human review where its contract says so.
- Privacy or breach incident: follow `data-subject-request.md` or `personal-data-breach.md`; retention decisions record due actions and do not auto-delete.

Record only non-sensitive counts, hashes or hash prefixes, timestamps, tool versions, target labels, and pass/fail results. Never record restored rows, credentials, contact data, connection strings, or full production identifiers.

## Hetzner transition

The approved direction is documented in `docs/architecture/adr-002-dedicated-hetzner-cascade-operations.md`. The existing source-only `infrastructure/cascade-n8n/` stack is the migration candidate. Follow `cascade-n8n-deploy.md` after all gates close. A local Compose render or disposable restore does not authorize creating or starting anything on Hetzner.

## Current unresolved gates

Production remains blocked on encrypted production backup/restore, coordinated staff/RLS release, project Auth TOTP and fresh AAL2, real cleaner authorization, scheduler/liveness monitoring, and shared n8n recovery. Hetzner additionally requires a fresh capacity/collision preflight, swap, independent secrets, DNS/TLS/access design, target backup/restore, and action-time owner approval.
