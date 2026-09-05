# Cascade Hideaway — Complete Remaining-Work Handoff

**Prepared:** 2026-09-05  
**Canonical working tree:** `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`  
**Branch:** `codex/cascade-waves-0-1-sol`  
**Production posture:** Frozen pending Module A gates  
**Next safe engineering outcome:** Begin Wave 8 consolidation, recovery evidence, authority inventory, and operational handoff locally

This is the current source-of-truth handoff for unfinished Cascade Hideaway system work. It consolidates the remaining modules, safety boundaries, recorded validation, repository roles, and exact resume sequence. It does not authorize a deployment or other production action.

## Executive position

- Supabase is the canonical system of record and the only owner of business state transitions.
- The existing Portainer n8n instance is a delivery/integration layer only. All source workflows remain inactive.
- Module B has a tested local candidate, but it is not deployed.
- Module C has a source-complete local candidate and all 47 pgTAP assertions pass.
- Module D has a Finance review queue and inactive delivery local candidate; Admin UI wiring remains in its owning repository.
- Module E has a verified local lifecycle candidate, including a real two-session hold-collision proof.
- Wave 2 has a local shared-inbox candidate with no delivery path.
- Wave 3 has a local cleaning/meter evidence and named-review candidate.
- Wave 4 has a verified local inventory forecast and named purchase-review candidate, including rollback-only database and two-session concurrency proof.
- Wave 5 has verified local named Finance reconciliation and internal management analytics; OPS is excluded and reports make no compliance claim.
- Wave 6 has verified local hashed identity, purpose-specific consent, lifecycle/recovery, and retention controls; it contains no communication path.
- Wave 7 has verified local consent-gated drafts and exact-content named review; publication remains unauthorized and no provider path exists.
- Module A production gates remain open, so production is frozen.
- Wave 8 remains planned local work.
- Finance/Admin and OPS must remain strictly separated.
- OCR, OpenRouter, receipt evidence, and bank-email evidence are advisory. They must never confirm payment or a booking.
- A deterministic comparison and a named Finance review must precede the existing `decide_direct_booking` RPC.
- The Free-plan external backup/restore exercise remains explicitly deferred.

For a visual summary, open [cascade-project-status.html](./cascade-project-status.html).

## Evidence authority

When sources disagree, use this order:

1. Checked-out source, migrations, tests, and current Git state.
2. Dated validation records in `docs/validation/`.
3. Approved plans and runbooks in `docs/plans/` and `docs/runbooks/`.
4. This handoff and the handoff index.
5. Historical notes and Obsidian memory, after reconciliation with repository evidence.

Never infer that local code is live. A production claim needs a dated production validation record.

## Project status at a glance

| Workstream | Status | What is true now | Exit condition |
| --- | --- | --- | --- |
| Module A — safety, access, recovery, observability | **Production gated** | Local release packets and tests exist; some earlier protections are live. The coordinated staff/RLS/named-cleaner cutover is not complete. | Close every production gate below with fresh evidence and owner approval. |
| Module B — canonical booking decision | **Local candidate complete** | Atomic `decide_direct_booking` RPC and delegated approval boundary exist and passed recorded local and Deno checks. | Resolve release prerequisites and deploy only after Module A approval. |
| Module C — payment evidence and Finance review | **Local candidate verified** | Private evidence/comparison/review records, adapters, fixtures, negative tests, and 47 rollback-only pgTAP assertions pass. | Complete coordinated release review after Module A. |
| Module D — Admin payment UI and delivery | **Backend/delivery local candidate** | Finance-only queue, closed delivery projections, and idempotent callbacks pass local tests; owning Admin UI source is outside this worktree. | Wire the owning Admin product after its source is available; keep delivery inactive. |
| Module E — calendar reliability and lifecycle | **Local candidate complete** | Holds, expiry, amendments, cancellations, no-shows, rate versions, refund authorization, audit, and reconciliation pass local tests. | Release only after Module A gates and coordinated review. |
| Wave 2 — guest messaging/shared inbox | **Local candidate complete** | Encrypted-body timeline, redacted previews, escalation, assignment, and human-reviewed drafts pass locally; delivery is absent. | Connect a provider only after Module A and fresh approval. |
| Wave 3 — cleaning/meter verification | **Local candidate complete** | Private evidence, correction/inspection outcomes, and named override boundaries pass locally. | Release only after Module A staffed-access gates. |
| Wave 4 — inventory forecast and purchasing | **Local candidate complete** | Canonical stock reconciliation, advisory recorded-usage forecasts, and immutable named owner/admin shopping-list review pass source, database, concurrency, and rollback checks. | Release only after Module A gates and coordinated review. |
| Wave 5 — Finance reconciliation and analytics | **Local candidate complete** | Paired-source comparisons, named reconciliation, internal metrics, effective owner targets, and rollback pass locally. | Release only after Module A gates and coordinated review. |
| Wave 6 — CRM, consent, retention, and guest lifecycle | **Local candidate complete** | Hashed identity resolution, purpose-specific consent, service-recovery suppression, retention decisions, and rollback pass locally; no communication path exists. | Release only after Module A gates and coordinated review. |
| Wave 7 — selective marketing | **Local candidate complete** | Consent-gated ciphertext drafts and exact-content named review pass locally; publication is always unauthorized. | Release only after Module A gates and coordinated review. |
| Wave 8 — consolidation and handoff | **Planned / later** | Authority, recovery, access, and operating evidence must be consolidated without implying production readiness. | Complete local inventory and keep open production gates explicit. |

No percentage-complete figure is used: local candidates, production gates, and future product waves are materially different kinds of progress.

## What is complete or established

### Foundation and operating boundaries

- Canonical Supabase authority is documented.
- Finance/Admin and OPS data separation is a non-negotiable architecture rule.
- Human approval boundaries are documented for payment/booking confirmation, refunds, discounts, exceptions, cleaning overrides, purchases, and publication.
- Safe database release, degraded-operation, recovery, privacy, scheduler, and n8n runbooks exist.
- Thirteen source-controlled n8n workflows were recorded as inactive and round-trip recoverable.
- Portable product-experience mockups exist for the command center, cleaner checklist, direct booking, and management analytics. Their values are sample data only.

### Module A local evidence

Recorded local validation includes:

- Platform safety: 37 tests passed.
- Release contract/preflight coverage: four coordinated migrations checked.
- n8n source graph: 13 workflows inactive.
- n8n recovery: 13 workflow exports round-tripped inactive.
- Recovery inventory comparison: 21 Edge Functions, 33 tables, 52 policies, and 33 RLS-enabled tables accounted for in the dated report.
- Privacy candidate: 49 pgTAP assertions passed.
- Observability candidate: 37 Node tests, 35 Deno checks, 13 entrypoint checks, 24 authority-manifest checks, and a disposable recovery test passed in the dated report.

These are local or dated validation results, not proof that the remaining production gates are closed.

### Module B local candidate

- `supabase/migrations/20260901010000_canonical_booking_decision.sql` originally defined `decide_direct_booking(uuid, text, text)`; Module C makes that engine private and exposes only the reviewed four-argument boundary.
- The RPC serializes a decision, verifies live overlap, and writes the booking, reservation, calendar, ledger, and projection-outbox state atomically.
- `supabase/functions/approve-booking/index.ts` authorizes the caller and delegates state changes to that RPC.
- Provider delivery is outside the transaction and remains inactive.
- Recorded focused validation passed: two Node boundary tests and ten pgTAP assertions.
- The candidate is local only and is not deployed.
- The current Deno 2.9.5 checks pass for the shared payment-evidence adapter and updated approval function; four adapter runtime tests also pass.

### Module C local candidate

- Receipt upload storage is private and hardened.
- Existing expense OCR writes advisory `pending_review` output and does not confirm payment.
- An inactive CH-W02 workflow export exists.
- The payment-evidence audit is complete and identifies the missing canonical schema, review, adapter, and fixture work.
- `20260905010000_payment_evidence_finance_review.sql` adds private evidence candidates, deterministic comparisons and immutable named Finance reviews.
- The pinned OpenRouter receipt contract and bank-email minimizer fail closed to manual review and store only opaque hashes plus normalized fields.
- Service-signed decision links were removed; the booking decision requires a matching final review from a named AAL2 Finance/Admin user.
- Twenty-seven focused Module B/C, booking/security and handoff source tests, 37 platform-safety tests, inactive n8n validation, secret scanning and diff checks pass.
- Two Deno type checks, four Deno adapter runtime tests, and all 47 pgTAP assertions pass. The suite rolled back its DDL and synthetic fixtures.

## Open Module A production gates

All are mandatory unless a later owner-approved plan explicitly replaces them:

1. **Project Auth assurance:** bootstrap the owner in Cascade project Auth, enroll TOTP, and prove fresh AAL2 after the coordinated staff/RLS release. Dashboard-account MFA is not project Auth MFA.
2. **Real staffed smoke:** prove a real cleaner-to-property assignment and authenticated access boundary without exposing Finance/Admin data.
3. **Recovery proof:** produce a fresh encrypted production backup, restore it to an isolated target, and reconcile the restore ledger. This exercise is deferred; therefore production remains frozen.
4. **Scheduler and liveness:** deploy the approved scheduler/liveness secrets and finish external monitoring only after release authorization.
5. **Shared n8n recovery:** prove the shared database, credential, and encryption-key restore procedure without activating Cascade workflows.
6. **Coordinated release packet:** follow `docs/plans/2026-08-31-module-a-cutover-packet.md` exactly for the staff/RLS/named-cleaner migration group and its rollback checkpoints.

Do not substitute a source-level backup check for a real production backup-and-restore proof.

## Remaining work, in approved order

### 1. Module C — payment evidence and named Finance review

The source candidate and runtime validation are complete. Production release remains gated behind Module A.

Build:

- A canonical payment-evidence candidate table tied to the booking/inquiry and source artifact.
- Source types for receipt upload/OCR, OpenRouter advice, allowlisted bank email, and manual evidence.
- Provenance, content hash/idempotency key, parser version, timestamps, normalized amount/currency/reference fields, confidence/advisory metadata, and non-sensitive failure state.
- A deterministic comparison result that records exact match, mismatch, ambiguity, missing fields, or duplicate evidence without making a payment decision.
- A separate Finance review record with reviewer identity, review time, outcome, reason, and immutable linkage to the compared evidence.
- Database authorization so OPS cannot read or mutate Finance evidence or review records.
- An allowlisted bank-email adapter that stores only required evidence and fails closed to manual review when mail is missing, malformed, duplicated, or outside the allowlist.
- Synthetic fixtures covering valid-looking, mismatched, duplicated, ambiguous, spoofed-looking, and missing bank-email evidence.
- Negative tests proving OCR, model output, mail evidence, and service integrations cannot call or simulate `decide_direct_booking`.

Required decision chain:

```text
Evidence candidate
  -> deterministic comparison
  -> Finance review record
  -> named human Finance approval
  -> decide_direct_booking RPC
  -> inactive outbox delivery path
```

The comparison may assist the reviewer; it may not approve. The reviewer must be a named authorized human, not a generic integration, service role, model, OCR job, or email sender.

### 2. Module D — Admin payment review UI and delivery adapter

After Module C is locally verified:

- Implement an Admin-only review queue over canonical Module C records.
- Show source provenance, deterministic match/mismatch details, missing evidence, duplicate warnings, and review history.
- Require an explicit named-human action and reason before invoking the booking decision boundary.
- Keep all receipt, bank, amount, payment, deposit, refund, rate, and guest-contact fields out of OPS surfaces and notifications.
- Export n8n delivery workflows inactive and validate their source graph and recovery form.
- Keep retries idempotent and ensure delivery failure cannot roll back or alter canonical booking/payment state.
- Do not configure providers or send test messages without fresh approval.

### 3. Module E — calendar reliability and booking lifecycle

The local candidate is complete. Five source-boundary tests, 43 rollback-only pgTAP assertions, and a disposable two-session collision proof pass. See [Module E validation](../validation/2026-09-05-module-e-local-candidate.md). Production release remains gated.

- Define the complete inquiry, hold, review, approval, rejection, expiry, cancellation, refund, and calendar lifecycle.
- Reconcile website and manually entered reservations through the same canonical collision rules.
- Add idempotency, retry, stale-hold expiry, timezone, daylight-boundary, and double-booking tests.
- Separate the legacy key issue from feature work: `booking_inquiries.id` and `calendar_events.id` lack usable unique constraints for some intended foreign keys. Design a reviewed expand/contract migration instead of repairing them opportunistically.
- Prove recovery and reconciliation before production activation.

### 4. Wave 2 — guest messaging and shared inbox

The local Supabase candidate is complete. Four source checks and 31 rollback-only pgTAP assertions pass. Draft approval never queues or authorizes delivery. See [Wave 2 validation](../validation/2026-09-05-wave-2-shared-inbox.md).

- Build a shared guest conversation timeline with consent, escalation, redaction, and staff assignment.
- Keep chatbot/model responses advisory or bounded to approved low-risk templates.
- Escalate uncertainty, money, safety, complaints, refunds, and policy exceptions to a human.

### 5. Wave 3 — cleaning and meter verification

- Complete named-cleaner production authorization after Module A gates.
- Implement task evidence, correction, inspection, and meter-reading review without exposing Finance/Admin data.
- Treat vision/AI as advisory; humans resolve ambiguous or failed evidence.

### 6. Wave 4 — inventory forecast and purchasing

- Local candidate: property-scoped stock movement/reconciliation, advisory forecast snapshots, and named AAL2 owner/admin purchase review.
- Review records always retain `order_authorized = false`; no function creates a supplier order, provider action, outbox item, purchase receipt, or financial transaction.
- Five source-boundary checks and all 31 rollback-only pgTAP assertions pass. A disposable two-session proof showed purchase review waited 5,063 ms for a stock lock and failed stale after the stock change committed. The compensating rollback removed all Wave 4 objects without `CASCADE`.
- See [Wave 4 validation](../validation/2026-09-05-wave-4-inventory-purchase.md).
- Reconcile stock movements to canonical inventory.
- Produce forecasts, recommendations, and approval/shopping lists only.
- Never place supplier orders automatically.

### 7. Wave 5 — Finance, reconciliation, and management analytics

- Local candidate: deterministic paired-source comparisons become immutable facts only after named AAL2 Finance/Admin review.
- Five source checks, 50 rollback-only pgTAP assertions, and the disposable compensating rollback pass.
- Internal reports disclose freshness, exclusions, and effective owner targets; OPS is denied and no statutory/tax claim is made.
- See [Wave 5 validation](../validation/2026-09-05-wave-5-finance-analytics.md).
- Build Finance-only reconciliation and exception queues.
- Calculate management metrics from reconciled canonical data and effective-dated owner targets.
- Treat dashboards as internal management information, not tax, statutory, or BIR compliance output.

### 8. Wave 6 — CRM and guest lifecycle

- Local candidate: property-scoped profiles use hashed identity keys and do not duplicate raw contact fields.
- Purpose-specific consent, lifecycle/service-recovery events, and retention decisions are append-only and restricted to named AAL2 owner/admin users.
- Deterministic marketing eligibility requires current marketing consent, no open recovery, and no restrictive retention state; eligibility authorizes no communication or publication.
- Five source checks, 31 rollback-only pgTAP assertions, and the disposable compensating rollback pass.
- See [Wave 6 validation](../validation/2026-09-05-wave-6-crm-lifecycle.md).

### 9. Wave 7 — selective marketing

- Local candidate: private drafts retain ciphertext, exact hashes, targeting reason, advisory provenance, and discount/claim evidence hashes without recipient contact or delivery state.
- Named AAL2 owner/admin review rechecks CRM eligibility and binds the exact content hash.
- Targeting, discounts, and claims require explicit review scope; both draft and review records retain `publication_authorized = false`.
- Five source checks, 33 rollback-only pgTAP assertions, and the disposable compensating rollback pass.
- See [Wave 7 validation](../validation/2026-09-05-wave-7-selective-marketing.md).

### 10. Wave 8 — consolidation and final operational handoff

- Remove duplicate authority paths and reconcile legacy integrations.
- Complete disaster recovery, access review, observability, data-retention, and incident drills.
- Produce final operating manuals, ownership map, and evidence-backed production inventory.

## Repository map

| Repository | Role | Current use |
| --- | --- | --- |
| `direct-booking-waves-0-1-sol` | Canonical active engineering and handoff worktree | Continue Modules C–E and release evidence here. |
| `direct-booking` | Live direct-booking product line | Preserve existing live behavior; reconcile changes through reviewed releases. |
| `guest-guide` | Live guest guide | Product-specific updates only; do not make it booking/payment authority. |
| `Nearby-POIS` | Nearby places/map product | Product-specific updates only; keep outside canonical business-state authority. |

Generated Claude session archives and completed derivative worktrees are not active projects and must not receive Task Master metadata.

## Task Master status and rule

Task Master AI is installed globally and initialized only in the four critical repositories listed above. Telemetry is disabled; no API keys or `.env` secrets were added.

For this handoff request, `.taskmaster/docs/handoff-status-prd.md` is the prepared local import source. Its AI parsing step was blocked because importing it would transmit detailed internal architecture to an external model provider without separate payload-specific approval. The Task Master task ledger therefore remains empty. Do not hand-edit `tasks.json` or route around that safeguard. If the owner later explicitly approves transmitting that PRD, import it through Task Master and then use the normal `next` / `show` / `set-status` workflow.

Keep Task Master out of generated archives, session mirrors, and completed disposable worktrees.

## Non-negotiable safety boundaries

- No Supabase migrations or Edge Functions may be deployed from this handoff.
- No n8n workflow may be activated or published.
- No provider, credential, webhook, scheduler, or external monitor may be configured.
- No VPS, Portainer, Docker, DNS, or shared-infrastructure changes may be made.
- No email, chat, Telegram, WhatsApp, social, or other message may be sent.
- No production data may be copied into fixtures, screenshots, commits, or handoff documents.
- No booking or payment may be confirmed from AI, OCR, receipt evidence, bank email, deterministic comparison alone, or a service account.
- No OPS surface or payload may include financial or guest-contact data.
- No supplier order or public marketing post may be automated.
- No production action is implied by a passing local test.

## Validation record to consult

| Evidence | Purpose |
| --- | --- |
| [Module A readiness refresh](../validation/2026-08-31-module-a-readiness-refresh.md) | Open production gates and dated source/live evidence. |
| [Wave 0 observability adoption](../validation/2026-08-31-wave-0-observability-adoption.md) | Local observability candidate and liveness gates. |
| [Wave 0 privacy enforcement](../validation/2026-08-31-wave-0-privacy-enforcement.md) | Privacy/RLS candidate and production prerequisites. |
| [Wave 0 recovery report](../validation/2026-08-30-wave-0-recovery-report.md) | Source-level recovery proof and remaining runtime recovery work. |
| [Module B local candidate](../validation/2026-09-01-module-b-local-candidate.md) | Atomic booking-decision implementation and recorded tests. |
| [Module C payment-evidence audit](../validation/2026-09-01-module-c-payment-evidence-audit.md) | Existing foundations, gaps, and required Module C boundary. |
| [Module C local candidate](../validation/2026-09-05-module-c-local-candidate.md) | Implemented local source, passing checks, and open runtime gates. |
| [Handoff/status artifact validation](../validation/2026-09-05-handoff-status-artifacts.md) | Fresh checks for this dated handoff and offline dashboard. |
| [Wave 4 inventory and purchase review](../validation/2026-09-05-wave-4-inventory-purchase.md) | Passing source, rollback-only database, concurrency, and compensating rollback evidence. |
| [Wave 5 Finance and analytics](../validation/2026-09-05-wave-5-finance-analytics.md) | Passing reconciliation, formula, authorization, database, and rollback evidence. |
| [Wave 6 CRM and guest lifecycle](../validation/2026-09-05-wave-6-crm-lifecycle.md) | Passing identity, consent, retention, authorization, database, and rollback evidence. |
| [Wave 7 selective marketing](../validation/2026-09-05-wave-7-selective-marketing.md) | Passing consent, exact-content review, authorization, database, and rollback evidence. |

## Exact next-session sequence

1. Read this file, `CURRENT-STATE.md`, `DEVELOPMENT-PLAYBOOK.md`, `module-execution-queue.md`, and the Wave 7 validation record.
2. Run `git status --short` and preserve all pre-existing user changes.
3. Inventory every local authority path and record duplicate, legacy, production-gated, and provider boundaries without assuming live state.
4. Complete Wave 8 local consolidation, recovery checks, access review, and operating handoff without changing production or infrastructure.
5. Record exact evidence and leave each unresolved Module A or external migration gate explicit.
6. Wire the Module D Admin UI only in its owning repository after that source is available.
7. Stop before any deployment, activation, provider setup, message, or infrastructure change.

## Resume prompt

Use [RESUME-PROMPT.md](./RESUME-PROMPT.md) for a copy/paste continuation block. At the start of a new session, use the current Git log rather than copying a stale commit SHA.

## Definition of a safe handoff

The next developer can identify the canonical repository, distinguish local evidence from live state, consolidate Wave 8 evidence without weakening consent or publication boundaries, preserve the Finance/OPS and human-approval rules, run the documented checks, and stop at production gates. Any unsupported live-state assertion must be recorded as unverified.
