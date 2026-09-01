# Current State and Continuation Gate

## Source precedence

Use evidence in this order when records disagree:

1. Current checked-out source, migration/release contracts, and test results.
2. `docs/validation/` records tied to a dated release or audit.
3. `docs/plans/` and `docs/runbooks/` for intended sequence and operational controls.
4. Obsidian notes under `D:\ObsidianVault\20-projects\cascade-hideaway\` for business memory and historical context.

Obsidian is valuable but includes session-era live snapshots. Some are older than the current source-controlled security/release work. Do not treat a status in the vault as a deployment authorization or overwrite more recent repository evidence with it.

## Completed or release-candidate work

| Workstream | State at handoff | Evidence / canonical location |
| --- | --- | --- |
| Shared n8n decision | Accepted | Existing Portainer n8n is the initial runtime; isolated Docker is deferred. `docs/architecture/adr-001-shared-portainer-n8n.md` |
| Finance/OPS delivery boundary | Protected in source and narrow production guard | `supabase/migrations/20260829173700_notification_route_guard.sql`, `tests/security/` |
| Direct booking trigger isolation | Protected | `supabase/migrations/20260829044725_revoke_w01_dispatch_rpc_execution.sql` |
| Named staff / cleaner access | Local release candidate | `supabase/migrations/20260828000400_staff_roles_and_sessions.sql`, `supabase/functions/staff-access/`, tests |
| Operational RLS | Local release candidate | `supabase/migrations/20260828000200_operational_rls_lockdown.sql`, SQL tests |
| Privacy requests/holds | Local release candidate | `supabase/migrations/20260831010000_privacy_requests_and_holds.sql`, `docs/privacy/`, tests |
| Observability/degraded mode | Local release candidate | `supabase/functions/_shared/observability.ts`, `degraded-mode.ts`, `docs/validation/2026-08-31-wave-0-observability-adoption.md` |
| Safe database release discipline | Locally complete | `scripts/migrations/`, `docs/runbooks/database-release.md`, release JSON |
| n8n source recovery | Complete but inactive | `automation/n8n/workflows/`, `scripts/check-n8n-workflows.mjs` |
| Product mockup suite | Complete, sample-only | `docs/mockups/cascade-experience-mockups.html`, editable source in `docs/mockups/cascade-command-center-src/` |

## Latest mockup work

The feature branch contains the following mockup commits after the earlier system-plan artifact:

| Commit | Change |
| --- | --- |
| `db26dd7` | Complete Command Center, Cleaner, and Direct Booking mockup suite. |
| `4eefc7d` | Clarify actual-versus-forecast business outlook. |
| `255c38c` | Add target-driven Owner Analytics tab. |
| `51d2053` | Add profitability, operating-expense, and daily utility analytics. |

The mockup reports **sample** financial values. Do not copy those into production; implement calculations over reconciled booking, payout, expense, meter, and inventory records.

## Latest Module A readiness refresh

On 2026-08-31, local readiness was refreshed: 37 platform-safety tests passed, the staff/cleaner release contract passed local preflight, 13 inactive n8n source workflows validated and round-tripped through disposable pinned n8n, production-inventory comparison passed, and secret scanning passed. The disposable Supabase rerun did not complete its final evidence output and was safely stopped/cleaned; it is not represented as a new pass.

A later read-only production-gate audit confirmed the active project has one property, but none of the four staff/cleaner cutover protections is live and no verified TOTP factor exists. This is an expected held release, not a failed deployment. Full evidence: `docs/validation/2026-08-31-module-a-readiness-refresh.md`. The exact production sequence is `docs/plans/2026-08-31-module-a-cutover-packet.md`.

On 2026-09-01, dashboard-account MFA was enrolled. It secures the Supabase administrative console but does not populate the Cascade project's `auth.mfa_factors` table or produce an application `aal2` claim. Project-owner bootstrap and project-user MFA remain part of the coordinated post-migration cutover; do not conflate the two MFA boundaries.

The production project is on a Supabase Free plan. Its Backups UI reports no scheduled backups or point-in-time recovery, which is a hard stop for any coordinated production schema cutover until the selected encrypted external backup-and-restore runbook is proven.

**Owner decision (2026-09-01):** Keep all Cascade operations on the Supabase Free plan. The selected recovery direction is the external encrypted-backup candidate; do not upgrade the Supabase subscription. Capturing production data and proving a restore remain separate action-time approvals.

`docs/runbooks/supabase-external-backup-recovery.md` and `scripts/recovery/backup-supabase-production.ps1` are the selected low-cost external-backup path. The script has passed PowerShell syntax validation and fail-closed checks. The already-present local `postgres:17` Docker image provides `pg_dump`, `pg_restore`, and OpenSSL with no new installation or image pull; no production backup or restore proof has been attempted.

Local preparation completed on 2026-09-01: an owner-only passphrase file was created outside Git at `C:\Users\Lloyd\Cascade-Secrets\supabase-backup-passphrase.txt`, an owner-only encrypted-backup destination was prepared at `C:\Cascade-Backups`, and an empty owner-only connection-URL file was prepared at `C:\Users\Lloyd\Cascade-Secrets\supabase-production-db-url.txt`. The passphrase and connection URL are not displayed, logged, or recorded in this repository. The script rejects the empty URL file before Docker or database access.

The Supabase Database Settings UI confirms that the current database password cannot be viewed after creation. Do not reset it merely to make a backup: Supabase warns that reset breaks existing direct connections. The owner must either supply the already-known connection URI through the prepared owner-only file, or explicitly approve a password-reset plan that inventories and updates all affected direct connections first.

## Production gates still open

Do not claim Module A complete until the following have fresh, action-time proof:

1. Owner TOTP MFA enrollment and a freshly proven `aal2` session.
2. A real cleaner Auth identity assigned to the correct Cascade property by the MFA-proven owner.
3. Fresh backup, production preflight, migration-ledger reconciliation, and rollback evidence.
4. Coordinated staff/RLS/named-cleaner release, followed by authenticated cleaner smoke tests: sign-in, property isolation, private photo upload, meter lookup, report submit, pending expense claim, sign-out, disabled-user denial, and stale-session denial.
5. Separate scheduler/liveness secrets configured without exposing values, then heartbeat deployment/smoke proof before schedule or Uptime Kuma activation.
6. Corrected price-history view released under its own reviewed release.
7. Owner-approved restore exercise for the shared Portainer n8n database, credential ciphertext, encryption key, and workflow set.

## n8n status and rules

- Approved runtime: shared Portainer n8n, not a new Docker deployment.
- Approved location: `Personal → Cascade Hideaway` folder/project.
- Canonical exports: `automation/n8n/workflows/CH-S01...CH-W12`.
- All Cascade workflows remain **inactive/unpublished**.
- A duplicate/older W01 draft is unsafe because it included Finance/guest detail in an OPS route. Never publish it.
- Before any workflow can be published: create/verify credentials named `Cascade — <provider/purpose>`, prove Finance/OPS routing, export the reviewed workflow back into source control, run `node scripts/check-n8n-workflows.mjs`, and obtain fresh approval.

See `docs/runbooks/n8n-live-baseline-2026-08-29.md` for the read-only runtime inventory.

## Approved roadmap order

| Module | Outcome | State |
| --- | --- | --- |
| A | Platform safety completion: authorization, privacy, recovery, release discipline | Gated; finish before normal feature work unless owner explicitly re-sequences |
| B | Canonical booking decision / transaction / idempotency | Not started |
| C | Advisory receipt + bank-email evidence | Not started |
| D | Staff review UI and n8n delivery | Not started |
| E | Calendar reliability and lifecycle release | Not started |
| Wave 2 | Chatbot/shared inbox | Planned after Wave 1 foundation |
| Wave 3 | Cleaning + meter verification | Planned after canonical evidence contract |
| Wave 4 | Inventory forecast + purchase approval | Planned; never auto-order |
| Wave 5 | Finance, reconciliation, analytics | Planned; internal management reporting while unregistered |
| Waves 6–8 | CRM, selective marketing, consolidation | Planned |

## Business and policy decisions already made

- One property now; architecture must support up to three in three years.
- Channels: Airbnb, direct site, Facebook/Messenger later.
- Direct booking confirmation occurs only when dates remain available **and** deposit/full payment has been verified by an authorized human.
- The initial payment workflow is receipt + allowed bank-email evidence + Admin/Finance one-click approval; OCR never declares funds received.
- Routine guest questions may be automated; discounts, payments, refunds/cancellations, complaints, access, safety and policy exceptions escalate.
- Cleaner evidence: deterministic failures request correction; uncertain/suspicious results require inspection; every result has human override/audit trail.
- Finance/Admin alerts carry booking/financial details. OPS alerts carry only operational/staff information.
- Marketing uses selective luxury content with approval queue for at least the first 90 days.
- Business is unregistered; do not represent reports as BIR/tax filing compliance.

## Known technical and operational risks

- Local release candidates are not production activations. Do not conflate passing tests with live cutover.
- Source-controlled n8n exports are intentionally inactive and may not match unsafe legacy drafts in the shared editor.
- The existing Portainer n8n image is unpinned `latest`; changing it needs its own backup/rollback window.
- Direct booking / legacy products must be inspected in their own repositories before UI work; the prototype is not their source of truth.
- Real financial reporting requires reconciliation: Airbnb payouts, approved expenses, payment rails, cash handling, and meter data must be normalized before P&L is trusted.
- The Obsidian vault has historical notes and is not a deployment log; do not place secrets or production credentials there.
