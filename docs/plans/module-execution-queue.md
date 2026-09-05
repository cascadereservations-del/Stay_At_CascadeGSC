# Cascade module execution queue

This queue converts the remaining system plan into independently testable modules. Each module ends with a commit, a local validation record, and a production gate; no module authorizes deployment by itself.

## Model routing

| Work type | Default model | Use GPT-5.6 SOL — High when |
|---|---|---|
| Documentation, inventories, fixtures, static checks, workflow graph updates | GPT-5.6 Luna — Medium | a task changes a security or payment contract |
| Isolated Edge Function logic, UI wiring, n8n configuration, test implementation | GPT-5.6 Terra — High | code crosses authorization, money, or database transaction boundaries |
| Database migrations/RPCs, role access, booking confirmation, payment correlation, final security/release audits | GPT-5.6 SOL — High | always for final design/review and conflict resolution |

SOL is therefore used for narrow high-risk checkpoints rather than routine output. Lower-capability work may not change a database schema, access rule, money state, or production configuration without a SOL review.

## Existing n8n implementation

`automation/n8n/workflows/` is the canonical existing workflow folder. It already contains 13 inactive, validated exports (`CH-S01`, `CH-W01` through `CH-W12`). Reuse and extend these exports in place; do not create another n8n application or duplicate workflow tree.

The approved initial runtime is the existing Portainer n8n instance. Create one dedicated `Cascade` folder/project, use only `Cascade — <provider/purpose>` credentials, and keep exports under this repository folder. `infrastructure/cascade-n8n/` is a deferred migration path only; the exact migration triggers are recorded in `docs/architecture/adr-001-shared-portainer-n8n.md`.

## Module A — Platform safety completion

**Scope:** Wave 0 Tasks 0.9–0.12, then recovery report 0.8.

**Progress (verified 2026-08-31):** named staff plus authenticated cleaner/RLS and privacy enforcement are complete local release candidates. Wave 0.11 observability adoption now wraps all 12 recovered Edge Functions with validated correlation propagation, recursive redaction and JSON-line request events; five provider outage decisions are executable and non-destructive. A signed, reason-only heartbeat-liveness endpoint is local-only for later Uptime Kuma activation. Safe-release tooling and disposable recovery remain green: 28/28 migrations and all 15 database test files pass without altering the active local stack. Production staff/privacy/function activation, the dedicated liveness secret/Uptime Kuma monitor, and restoration of the shared Portainer n8n data/credentials/encryption key remain open; Module B must not start before those Module A gates are closed or explicitly re-sequenced.

- Named staff accounts, property-scoped roles, MFA gate, revocation and offboarding.
- Privacy inventory, retention, request/hold model and breach response.
- Correlation IDs, redaction and provider-outage/degraded-mode tests.
- Migration preflight, expand/contract verification and release runbook.
- Recovery report records Docker/VPS/staging facts without claiming blocked checks passed.

**Exit:** no unsafe endpoint is reclassified without evidence; all new staff-sensitive write paths have named authority; every migration has a forward check and compensating rollback.

## Module B — Canonical booking decision

**Scope:** Wave 1.1–1.2.

**Local progress (2026-09-01):** a local-only candidate migration introduces `decide_direct_booking`, a transaction-owned decision record, per-decision idempotency and a property transaction lock. The candidate confirms the booking/reservation/calendar/ledger/projection outbox together, refuses overlapping approved stays, and leaves delivery to the outbox. `approve-booking` now delegates the state decision to that RPC and contains no calendar or ledger update. Two focused source-boundary tests and ten local pgTAP assertions passed. It has not been deployed, and its release is blocked by Module A recovery gates.

- Audited booking and payment-evidence state machine.
- One database transaction for human-approved direct booking confirmation.
- Concurrency proof: two overlapping requests result in exactly one confirmation.

**Exit:** no Edge Function performs partial booking confirmation writes; a retry returns the same result through idempotency.

## Module C — Advisory payment evidence

**Scope:** Wave 1.3–1.5.

**Local progress (2026-09-05):** the private evidence/comparison/review schema, pinned OpenRouter receipt adapter contract, fail-closed bank-email minimizer, six-case synthetic fixture pack, and named AAL2 Finance review boundary are present. The booking RPC now requires and records an immutable final Finance review; its former unreviewed service entry point and direct service-role table access are revoked. The 47-assertion pgTAP gate passed in a rollback-only local transaction, alongside the focused source, platform, inactive-workflow, secret, Deno type, and adapter runtime checks. See `docs/validation/2026-09-05-module-c-database-runtime.md`.

- Pinned OpenRouter task profile, strict receipt JSON schema, synthetic test fixtures and failure-to-review behaviour.
- Gmail sender/subject allowlist, metadata-minimized n8n handoff, parser-review lane.
- Deterministic receipt/bank/expected-amount correlation. AI never decides that money was received.

**Exit:** human approval remains mandatory; missing bank email does not reject a valid manual review.

## Module D — Staff review and automation delivery

**Scope:** Wave 1.6–1.7.

**Local progress (2026-09-05):** a Finance-only AAL2/property-scoped review queue RPC and Edge Function expose Module C provenance, comparisons, warnings, and review history without guest contact details or decision authority. Booking events now receive closed Finance/guest templates; event detail is shaped by a closed workflow/event/audience matrix; signed callbacks require a stable ID and update delivery state through an idempotent RPC only. Eleven focused source-boundary checks, ten Deno runtime tests, 15 queue pgTAP assertions and 18 delivery pgTAP assertions pass. The existing Admin dashboard source is outside this worktree, so its UI wiring remains for the owning product repository. All n8n exports remain inactive. See `docs/validation/2026-09-05-module-d-local-candidate.md`.

- Clean clone of the admin dashboard before changing its payment-review UI.
- Reuse `CH-W01`–`CH-W04`, `CH-W09`, and `CH-W12` as the only booking workflow exports; extend their signed event-detail/callback contracts.
- Import inactive and test with fixture events/provider actions disabled.

**Exit:** Finance gets payment/admin details, OPS gets only post-confirmation operational details, and n8n remains a replayable outbox consumer rather than the booking authority.

## Module E — Reliability and lifecycle release

**Scope:** Wave 1.8–1.12.

**Local progress (2026-09-05):** property-locked booking holds, safe expiry, effective-dated human-approved rate policies, AAL2 Admin lifecycle commands, separate AAL2 Finance refund authorization, calendar reconciliation, and immutable lifecycle audit are implemented locally. Five source-boundary tests and 43 rollback-only pgTAP assertions pass, including a timezone-boundary expiry check. A disposable two-session proof showed the losing overlapping hold waited for the property lock and failed closed, leaving exactly one active hold. See `docs/validation/2026-09-05-module-e-local-candidate.md`.

- Calendar feed health and safe unpaid-hold expiry.
- Controlled fixture release proof.
- Amendments, cancellation, refund, no-show, effective-dated property rates/policy, and transactional delivery health.

**Exit:** calendar is projection only; every lifecycle action is audited, idempotent and never silently changes financial state.

## Wave 4 — Inventory forecast and purchase review

**Local progress (2026-09-05):** canonical inventory movements and explicit reconciliation feed recorded-usage forecast snapshots. A named AAL2 owner/admin may approve or reject an exact shopping-list quantity with a reason. Review never authorizes or places a supplier order and does not create purchase or Finance facts. Five source-boundary checks and all 31 rollback-only pgTAP assertions pass. A disposable two-session proof showed review waited 5,063 ms for a concurrent stock change and then failed closed; the compensating rollback also passed. See `docs/validation/2026-09-05-wave-4-inventory-purchase.md`.

- Start every item with a verified reconciliation and fail closed on legacy stock drift.
- Keep forecast inputs and outputs immutable, property-scoped, explainable, and explicitly advisory.
- Serialize stock changes, forecasts, and review against the canonical inventory item.
- Keep OPS, Finance-only, anonymous, model, and service identities outside purchase approval.
- Do not add a provider, delivery outbox, supplier order, expense approval, or automatic purchase path.

**Exit:** met locally. Rollback-only pgTAP and concurrency checks pass; the named-human decision is immutable and still cannot order anything. Production remains gated.

## Wave 5 — Finance reconciliation and management analytics

**Local progress (2026-09-05):** paired opaque source facts are classified deterministically, then a named AAL2 Finance/Admin reviewer creates the immutable reconciled fact. Missing and duplicate evidence cannot approve; mismatch review can select only a compared value. Internal metrics use only reconciled facts and effective-dated owner targets, disclose freshness and exclusions, and deny any statutory/tax claim. Five source checks, 50 rollback-only pgTAP assertions, and a disposable compensating rollback pass. See `docs/validation/2026-09-05-wave-5-finance-analytics.md`.

- Keep Finance data and metric output unavailable to OPS and service integrations.
- Require a named human review before a candidate becomes a reconciled fact.
- Use reconciled facts for P&L, cost/night, ADR, RevPAR, occupancy, and daily utility metrics.
- Keep targets effective-dated, non-overlapping, and owner-approved.
- Label every report as internal management information while the business is unregistered.

**Exit:** met locally. Database, source-boundary, formula, authorization, and rollback checks pass. Production remains gated.

## Wave 6 — CRM, consent, retention, and guest lifecycle

**Local progress (2026-09-05):** hashed identity keys resolve deterministically without duplicating raw contact data. Named AAL2 owner/admin staff record append-only purpose consent, lifecycle/recovery events, and retention decisions. Marketing eligibility requires separate current consent, no open recovery, and no restrictive retention action. Five source checks, 31 rollback-only pgTAP assertions, and the disposable rollback pass. See `docs/validation/2026-09-05-wave-6-crm-lifecycle.md`.

**Exit:** met locally. Identity conflicts fail closed, consent purposes remain separate, recovery and retention suppress marketing, and no automatic deletion or communication path exists. Production remains gated.

## Wave 7 — selective marketing drafts and exact-content review

**Local progress (2026-09-05):** consent-gated private drafts store ciphertext and hashes without recipient contact or delivery state. Named AAL2 owner/admin review rechecks eligibility, binds the exact content hash, and separately approves targeting, discounts, and claims. Five source checks, 33 rollback-only pgTAP assertions, and the disposable rollback pass. See `docs/validation/2026-09-05-wave-7-selective-marketing.md`.

**Exit:** met locally. Draft and review records retain `publication_authorized = false`; no outbox, provider, send, or publication path exists. Production remains gated.

## Wave 8 — consolidation and operational handoff

**Local progress (2026-09-05):** the authority inventory covers eight business domains and classifies legacy/delivery paths. The operating handoff covers named decisions, access review, recovery, incidents, evidence, and stop conditions. Six consolidation checks, six handoff checks, a clean dormant Compose render, a 13-workflow inactive n8n recovery round trip, and a 38-migration/26-suite isolated Supabase reset pass. See `docs/validation/2026-09-05-wave-8-consolidation-handoff.md`.

**Exit:** met locally. All approved product waves now have local candidates or explicit owning-product boundaries. Production, providers, and Hetzner remain gated by Module A, fresh target preflight, and action-time approval.

## Shared stop conditions

Stop and request action-time owner approval before production schema deployment, n8n activation, cron activation, Docker/VPS changes, Meta/Gmail setup, or sending any provider message. Preserve the two user-owned untracked W01 files until their ownership is explicitly resolved.
