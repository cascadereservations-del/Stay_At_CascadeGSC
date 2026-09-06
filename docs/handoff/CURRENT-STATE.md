# Current State and Continuation Gate

## Source precedence

P1 completed on 2026-09-06. The [recovery/action packet](../plans/2026-09-06-p1-recovery-action-packet.md), [local validation](../validation/2026-09-06-p1-local-completion.md), and [Alfred recovery proof](../validation/2026-09-06-p1-alfred-recovery.md) now cover the replacement image, capped stack, encrypted new-stack recovery, actual Alfred storage/proxy topology, encrypted existing-runtime backup, and isolated credential-decryption restore. P2/P3 remain held for fresh action-time approval.

Use evidence in this order when records disagree:

1. Current checked-out source, migration/release contracts, and test results.
2. `docs/validation/` records tied to a dated release or audit.
3. `docs/plans/` and `docs/runbooks/` for intended sequence and operational controls.
4. Obsidian notes under `D:\ObsidianVault\20-projects\cascade-hideaway\` for business memory and historical context.

Obsidian is valuable but includes session-era live snapshots. Some are older than the current source-controlled security/release work. Do not treat a status in the vault as a deployment authorization or overwrite more recent repository evidence with it.

## Completed or release-candidate work

| Workstream | State at handoff | Evidence / canonical location |
| --- | --- | --- |
| n8n hosting decision | Selected | Use Alfred's existing Docker Engine and Portainer CE for a separate capped Cascade n8n/PostgreSQL Compose stack after recovery, swap, capacity, and approval gates. A separate VPS is the fallback. `docs/plans/2026-09-06-portainer-n8n-completion-plan.md` |
| P1 n8n recovery/deployment packet | Complete | Existing Alfred n8n encrypted backup and isolated restore passed with matching 60/28/31 aggregates; current source-controlled Cascade names remain inactive. `docs/validation/2026-09-06-p1-alfred-recovery.md` |
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

The first approved backup attempt made no dump: Docker could not resolve the direct `db.<project-ref>.supabase.co` host. Use the Supabase **Session Pooler** URI on port `5432` in the owner-only connection file for the next retry, not the direct connection URI or the transaction pooler URI. The browser connection dialog is left open for this selection.

**Owner sequencing decision (2026-09-01):** Defer the external backup/restore exercise for now. The Module A production cutover remains frozen: do not apply migrations, deploy functions, activate workflows, or change production data. To keep delivery moving, Module B may proceed as local source work and tests only; its deployment still requires the deferred Module A recovery gates.

## Production gates still open

Do not claim Module A complete until the following have fresh, action-time proof:

1. Owner TOTP MFA enrollment and a freshly proven `aal2` session.
2. A real cleaner Auth identity assigned to the correct Cascade property by the MFA-proven owner.
3. Fresh backup, production preflight, migration-ledger reconciliation, and rollback evidence.
4. Coordinated staff/RLS/named-cleaner release, followed by authenticated cleaner smoke tests: sign-in, property isolation, private photo upload, meter lookup, report submit, pending expense claim, sign-out, disabled-user denial, and stale-session denial.
5. Separate scheduler/liveness secrets configured without exposing values, then heartbeat deployment/smoke proof before schedule or Uptime Kuma activation.
6. Corrected price-history view released under its own reviewed release.

## n8n status and rules

- Current runtime: Alfred's shared Portainer n8n returned healthy on the same 2.37.10 image/container identity after the approved P1 recovery window. Its database has 60 workflows, 28 active and 31 credentials; all 14 live rows matching the 13 source-controlled Cascade names are inactive.
- Selected runtime direction: an isolated Cascade Compose project on Alfred's existing Docker Engine, managed through Portainer CE after all same-host gates; use a separate VPS if any threshold fails. Do not add a second Docker daemon.
- Current editor location: `Personal → Cascade Hideaway` folder/project.
- Canonical exports: `automation/n8n/workflows/CH-S01...CH-W12`.
- All Cascade workflows remain **inactive/unpublished**.
- A duplicate/older W01 draft is unsafe because it included Finance/guest detail in an OPS route. Never publish it.
- Before any workflow can be published: create/verify credentials named `Cascade — <provider/purpose>`, prove Finance/OPS routing, export the reviewed workflow back into source control, run `node scripts/check-n8n-workflows.mjs`, and obtain fresh approval.

See `docs/runbooks/n8n-live-baseline-2026-08-29.md` for the read-only runtime inventory.

## Approved roadmap order

| Module | Outcome | State |
| --- | --- | --- |
| A | Platform safety completion: authorization, privacy, recovery, release discipline | Gated; finish before normal feature work unless owner explicitly re-sequences |
| B | Canonical booking decision / transaction / idempotency | Local candidate complete; not deployed |
| C | Advisory receipt + bank-email evidence | Local candidate; 47/47 pgTAP runtime gate passed |
| D | Staff review UI and n8n delivery | Backend/delivery local candidate; Admin UI source external |
| E | Calendar reliability and lifecycle release | Local candidate complete; not deployed |
| Wave 2 | Chatbot/shared inbox | Local shared-inbox candidate; no delivery |
| Wave 3 | Cleaning + meter verification | Local evidence/review candidate; not deployed |
| Wave 4 | Inventory forecast + purchase approval | Local candidate verified; never auto-order |
| Wave 5 | Finance, reconciliation, analytics | Local candidate verified; internal management reporting only |
| Wave 6 | CRM, consent, retention, guest lifecycle | Local candidate verified; no communication path |
| Wave 7 | Selective marketing and exact-content review | Local candidate verified; no publication path |
| Wave 8 | Consolidation and operational handoff | Local candidate verified; Portainer CE path selected, live work gated |

## Module B local candidate (2026-09-01)

The deferred recovery exercise does not prevent local source work. The first Module B candidate is present but **not deployed**:

- `supabase/migrations/20260901010000_canonical_booking_decision.sql` originally added `booking_decisions` and the service-only `decide_direct_booking(uuid, text, text)` RPC. Module C subsequently made that engine private and exposed only the reviewed four-argument boundary.
- It serializes a repeat decision and a property-wide availability check, then performs booking/reservation/calendar/ledger/projection-outbox writes in one database transaction. Provider delivery is intentionally not performed by the approving Edge Function.
- `supabase/functions/approve-booking/index.ts` is reduced to authorization, one RPC call and response rendering; it no longer directly updates `calendar_events` or `transactions`.
- Focused local checks passed: two Node boundary/contract tests and ten pgTAP assertions for confirmation, projection, retry idempotency and an overlapping-stay conflict. The pgTAP test transaction rolled back all fixture data.

While validating this candidate, the local schema showed that legacy `booking_inquiries.id` and `calendar_events.id` do not have usable unique constraints. The candidate deliberately stores logical UUID references instead of adding foreign keys. Do not “fix” those foundational keys in this migration; investigate and release any key repair separately with a compatibility/backup plan.

## Module C local candidate (2026-09-05)

The local-only Module C candidate adds private payment-evidence candidates, deterministic comparison records, and immutable named Finance reviews. Receipt/OpenRouter/bank/manual evidence remains advisory, the pinned OpenRouter schema and allowlisted bank adapter fail closed to review, and OPS has no Finance-record visibility. The former service-signed approval link was removed. `decide_direct_booking` now requires a matching final Finance review ID; the unreviewed service entry point is revoked.

Fresh checks pass: 27 focused Module B/C, booking/security and handoff tests; 37 platform-safety tests; 13 inactive n8n exports; secret scanning; syntax checks; `git diff --check`; two Deno type checks; four Deno adapter runtime tests; and all 47 rollback-only pgTAP assertions. See `docs/validation/2026-09-05-module-c-database-runtime.md`. The candidate remains local and production-gated.

## Module D local candidate (2026-09-05)

The local Finance review queue is property-scoped and available only to named AAL2 Finance/Admin sessions. It exposes canonical evidence provenance, deterministic comparisons, warnings, and immutable history while excluding guest email and phone and retaining approval in the reviewed booking transaction. Inactive delivery detail now uses closed audience-specific field sets, and callback retries update delivery state idempotently without touching booking or payment facts. Focused source checks, Deno runtime tests, 15 queue assertions, and 18 delivery assertions pass. The audited Admin dashboard source is not present in this worktree, so UI consumption remains in that product's owning repository. See `docs/validation/2026-09-05-module-d-local-candidate.md`.

## Module E local candidate (2026-09-05)

The local lifecycle candidate adds property-locked holds, expiry, human-approved effective-dated rate policies, AAL2 Admin amendments/cancellations/no-shows/reconciliation, separate AAL2 Finance refund authorization, and immutable audit history. Five source checks and 43 rollback-only pgTAP assertions pass, including a timezone-boundary expiry check. A disposable two-session test proved overlapping holds serialize and leave exactly one winner. Calendar records remain projections, refund authorization never executes a payment, and confirmation still flows only through the reviewed Module B/C decision boundary. See `docs/validation/2026-09-05-module-e-local-candidate.md`.

## Wave 2 local candidate (2026-09-05)

The Supabase shared-inbox foundation stores idempotent inbound records with ciphertext bodies and redacted previews, deterministic escalation, named property-scoped assignment, immutable audit, and human-reviewed advisory drafts. Draft approval explicitly does not authorize or queue delivery. OPS and Finance cannot read or manage the guest inbox. Four source checks and 31 rollback-only pgTAP assertions pass. See `docs/validation/2026-09-05-wave-2-shared-inbox.md`.

## Wave 3 local candidate (2026-09-05)

Private cleaning/meter evidence is tied to the named cleaner, property, cleaning session, and matching meter reading. Advisory outcomes cannot approve evidence. Named inspectors review uncertainty, and only operations managers can override. Two source checks and 21 rollback-only pgTAP assertions pass. See `docs/validation/2026-09-05-wave-3-cleaning-meter.md`.

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
- The local Docker Desktop engine stopped after the successful P1 restore proof. Its installed backend subsequently reported a missing Docker Desktop installation registry key and would not restart. The committed Alfred restore checker is the exact revision that already passed; repair or reinstall the workstation Docker runtime before further local Docker-dependent work.
- Source-controlled n8n exports are intentionally inactive and may not match unsafe legacy drafts in the shared editor.
- The existing Portainer n8n image is unpinned `latest`; changing it needs its own backup/rollback window.
- Direct booking / legacy products must be inspected in their own repositories before UI work; the prototype is not their source of truth.
- Real financial reporting requires reconciliation: Airbnb payouts, approved expenses, payment rails, cash handling, and meter data must be normalized before P&L is trusted.
- The Obsidian vault has historical notes and is not a deployment log; do not place secrets or production credentials there.

## Wave 4 local candidate (2026-09-05)

Property-scoped stock reconciliation, recorded-usage forecasts and named AAL2 owner/admin shopping-list decisions are implemented locally. Five source checks and 31 rollback-only pgTAP assertions pass. A disposable two-session proof showed purchase review waits for the canonical item lock and fails stale after a concurrent stock change; the compensating rollback also passed. See [Wave 4 evidence](../validation/2026-09-05-wave-4-inventory-purchase.md). No provider action is authorized by a purchase review.

## Wave 5 local candidate (2026-09-05)

Named AAL2 Finance reconciliation converts deterministic paired-source comparisons into immutable reviewed facts. Five source checks and 50 rollback-only pgTAP assertions pass, as does the compensating rollback. Internal metrics include P&L, cost per night, ADR, RevPAR, occupancy, utilities, data freshness, exclusions, and effective owner targets. OPS has no access, and reports explicitly make no statutory, tax, BIR, or filing claim. See [Wave 5 evidence](../validation/2026-09-05-wave-5-finance-analytics.md).

## Wave 6 local candidate (2026-09-05)

Hashed identity keys, separate purpose consent, private lifecycle/service-recovery events, and retention decisions pass 5 source checks, 31 rollback-only pgTAP assertions, and a disposable rollback. Marketing eligibility is deterministic but authorizes no targeting, sending, or publication. See [Wave 6 evidence](../validation/2026-09-05-wave-6-crm-lifecycle.md).

## Wave 7 local candidate (2026-09-05)

Consent-gated drafts store ciphertext and hashes without recipient contact or delivery state. Named AAL2 owner/admin review rechecks current eligibility, binds the exact content hash, and separately approves targeting, discounts, and claims. Five source checks, 33 rollback-only pgTAP assertions, and a disposable rollback pass. Drafts and reviews retain `publication_authorized = false`; no publication or provider path exists. See [Wave 7 evidence](../validation/2026-09-05-wave-7-selective-marketing.md).

## Wave 8 local candidate (2026-09-05)

The machine-checkable authority inventory and operating handoff pass six consolidation checks and six handoff/status checks. A dormant two-service Compose render passed without starting containers. Disposable recovery restored 13 n8n workflows inactive with matching semantics and rebuilt Supabase through 38 migrations and 26 database test files while leaving the active local database unchanged. Portainer CE on Alfred is now the selected management path for the isolated stack; all live work remains gated. See [Wave 8 evidence](../validation/2026-09-05-wave-8-consolidation-handoff.md) and the [updated completion plan](../plans/2026-09-06-portainer-n8n-completion-plan.md).

## Hetzner read-only preflight (2026-09-05)

The configured Alfred target has current Docker/Compose, no Cascade container-name collision, no listener on port 5679, and no existing `/opt/cascade/n8n` path. It has 0 MiB swap. No VPS or Docker change was made. See [redacted preflight evidence](../validation/2026-09-05-hetzner-read-only-preflight.md).

## Portainer isolation review (2026-09-06)

The initial Portainer review correctly identified coupling and shared-host risk but lacked live resource and OOM evidence. A detailed follow-up found stable low load, about 3.2 GiB available RAM, no current unhealthy container, no OOM/restart evidence, and no active Ollama model. The AppFlowy exit-137 containers report `OOMKilled=false`. The owner selected the existing Portainer CE plus a separate capped Cascade stack, with recovery, 2 GiB swap, fresh capacity, 72-hour inactive soak, and action approvals still mandatory. See [detailed Alfred capacity evidence](../validation/2026-09-06-alfred-detailed-capacity-audit.md), the [interactive hosting decision](./cascade-hosting-decision.html), and the [updated completion plan](../plans/2026-09-06-portainer-n8n-completion-plan.md).
