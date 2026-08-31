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

- Audited booking and payment-evidence state machine.
- One database transaction for human-approved direct booking confirmation.
- Concurrency proof: two overlapping requests result in exactly one confirmation.

**Exit:** no Edge Function performs partial booking confirmation writes; a retry returns the same result through idempotency.

## Module C — Advisory payment evidence

**Scope:** Wave 1.3–1.5.

- Pinned OpenRouter task profile, strict receipt JSON schema, synthetic test fixtures and failure-to-review behaviour.
- Gmail sender/subject allowlist, metadata-minimized n8n handoff, parser-review lane.
- Deterministic receipt/bank/expected-amount correlation. AI never decides that money was received.

**Exit:** human approval remains mandatory; missing bank email does not reject a valid manual review.

## Module D — Staff review and automation delivery

**Scope:** Wave 1.6–1.7.

- Clean clone of the admin dashboard before changing its payment-review UI.
- Reuse `CH-W01`–`CH-W04`, `CH-W09`, and `CH-W12` as the only booking workflow exports; extend their signed event-detail/callback contracts.
- Import inactive and test with fixture events/provider actions disabled.

**Exit:** Finance gets payment/admin details, OPS gets only post-confirmation operational details, and n8n remains a replayable outbox consumer rather than the booking authority.

## Module E — Reliability and lifecycle release

**Scope:** Wave 1.8–1.12.

- Calendar feed health and safe unpaid-hold expiry.
- Controlled fixture release proof.
- Amendments, cancellation, refund, no-show, effective-dated property rates/policy, and transactional delivery health.

**Exit:** calendar is projection only; every lifecycle action is audited, idempotent and never silently changes financial state.

## Shared stop conditions

Stop and request action-time owner approval before production schema deployment, n8n activation, cron activation, Docker/VPS changes, Meta/Gmail setup, or sending any provider message. Preserve the two user-owned untracked W01 files until their ownership is explicitly resolved.
