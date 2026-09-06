# Portainer CE + n8n completion plan

**Decision date:** 2026-09-06

**Selected platform:** Alfred's existing Docker Engine, managed through Portainer CE, with a separate capped Cascade n8n + PostgreSQL Compose stack

**Subscription impact:** none

**Current live state:** P1 recovery passed; Alfred's existing n8n returned healthy and unchanged after its encrypted capture. No Cascade stack, swap, route change, provider, workflow activation, DNS change, or business-production change has been made.

## Decision

Use the already-installed Portainer CE to manage the source-controlled `cascade-n8n` Compose project on Alfred. Do not install a second Docker daemon and do not modify or replace Alfred's existing n8n service. The new stack receives its own containers, database, volumes, networks, encryption key, credentials, hostname, backups, and rollback boundary.

This selection uses the current Hetzner plan without adding a subscription. It is approved as the target architecture, not as permission to change the server. A separate VPS remains the tested fallback if the pre-start threshold or dormant-soak threshold fails, or if later production load no longer fits safely beside Alfred.

Supabase remains the canonical owner of business facts and state transitions. n8n remains a delivery and integration layer. The 13 source-controlled Cascade workflows remain inactive until individually approved.

## Non-negotiable operating boundaries

- Preserve every Alfred service, container, network, volume, credential, database, proxy route, and backup.
- Keep the Cascade editor loopback-bound at `127.0.0.1:5679`; expose it only through the reviewed TLS and identity-aware proxy route.
- Keep the n8n ceiling at 1.5 CPU / 1536 MiB and PostgreSQL at 0.75 CPU / 768 MiB unless a new capacity review changes the source candidate first.
- Do not add provider credentials during the dormant trial.
- Import all workflows inactive and prove their semantic hashes against source.
- Require a named AAL2 human for booking/payment confirmation, refunds, discounts, exceptions, cleaning overrides, purchase-list decisions, and publication review.
- A purchase-list review never authorizes a supplier order or payment.
- Finance/Admin and OPS data remain separated.

## Remaining phases

| Phase | Outcome | Work | Exit evidence | Live action? |
| --- | --- | --- | --- | --- |
| P0 — Decision and source lock | The hosting direction is unambiguous | Record this plan, update ADR/handoff/resume entry points, preserve Task Master files | Documentation tests, link checks, clean owned diff | No |
| P1 — Recovery and deployment packet | **Complete 2026-09-06** | Backed up and disposable-restored Alfred's existing n8n database, credential ciphertext, encryption key, workflows and binary storage; reviewed the exact image/security state; rendered and tested capped Compose; finalized proxy, secret, backup, smoke, abort, and rollback commands | [Redacted recovery report](../validation/2026-09-06-p1-alfred-recovery.md), successful isolated restore, reviewed rendered Compose, no placeholder or public binding | Completed under separate recovery approval; existing n8n returned healthy |
| P2 — Host protection and fresh baseline | Alfred can absorb a dormant capped stack without weakening Alfred | Under a separately approved maintenance action, add at least 2 GiB swap; repeat RAM/load/disk/container health checks; confirm port/name/path collisions remain absent | At least 2.5 GiB available before startup, 2 GiB swap, at least 15 GiB free disk, no unhealthy/restarting current service | Yes; stop for action-time approval |
| P3 — Dormant Cascade stack | The isolated stack exists with zero external business effect | Create only the Cascade stack, volumes, networks, secrets, and loopback route through Portainer CE; start PostgreSQL then n8n; create named users and MFA; omit provider credentials; import all 13 workflows inactive | Both services healthy and inside caps; editor access protected; all workflow exports inactive and hash-matched | Yes; stop for action-time approval |
| P4 — Recovery drill and 72-hour soak | Co-location is proven under observation | Run encrypted backup and disposable restore of the new stack; observe host/container memory, swap, load, disk, restarts, health, and logs for at least 72 hours with workflows inactive | Restore proof plus soak report with no abort condition | Observation is read-only after approved start |
| P5 — Module A production closure | The Supabase safety foundation is complete | Prove encrypted Supabase backup/restore; reconcile migration ledger; release staff/RLS/named-cleaner changes through the cutover packet; enroll project-owner TOTP and prove fresh AAL2; assign and smoke-test a real cleaner; release the corrected price-history view; configure scheduler/liveness only after its own review | Every Module A gate has dated evidence and rollback result | Yes; each production batch requires approval |
| P6 — Core booking release | The authoritative booking and Finance review chain is live before delivery | Release Modules B and C together, wire Module D's Finance review UI in its owning product, then release Module E lifecycle/reconciliation; run concurrency, authorization, idempotency, Finance/OPS, and rollback checks | Named Finance review precedes the booking RPC; lifecycle actions and refund authorization stay separate; no provider delivery is required for acceptance | Yes; staged approvals |
| P7 — Operations and insight release | Staff workflows consume canonical facts safely | Release Wave 3 cleaning/meter access, Wave 4 inventory forecast/purchase review, and Wave 5 Finance reconciliation/analytics in separate batches; then connect the owning product UIs | Real-role smoke tests pass; purchase review cannot order; OPS cannot read Finance; reports disclose freshness/exclusions | Yes; staged approvals |
| P8 — Guest lifecycle release | Guest interaction foundations are live without unreviewed sending | Release Wave 2 inbox, then Wave 6 CRM/consent/retention, then Wave 7 draft/review; preserve ciphertext/redaction and re-check consent at review/action time | No draft approval sends; eligibility is not send authority; publication remains separately controlled | Yes; staged approvals |
| P9 — Workflow/provider activation | Delivery is introduced one narrow path at a time | Create only reviewed `Cascade — <provider/purpose>` credentials; fixture-test with provider actions disabled; activate one workflow; observe; export reviewed JSON back to source; repeat | Per-workflow approval, delivery evidence, source export, recovery proof, rollback path | Yes; one approval per provider/workflow batch |
| P10 — Operational acceptance | The new plane is supportable and the old Cascade path is safely retired | Complete access review, backup schedule, restore drill cadence, alerts, incident ownership, runbooks, and final authority inventory; retire an old Cascade delivery path only after no pending execution or rollback dependency remains | Signed operational acceptance and dated live-state inventory | Yes; retirement is a separate approval |

## Phase order and dependencies

```text
P0 decision
  -> P1 recovery/deployment packet
  -> P2 swap + fresh baseline
  -> P3 dormant stack
  -> P4 restore drill + 72-hour soak
  -> P5 Module A closure
  -> P6 core booking
  -> P7 operations/insight
  -> P8 guest lifecycle
  -> P9 one-by-one delivery activation
  -> P10 operational acceptance
```

P1 recovery evidence must exist before P2 or P3. P4 must pass before P5–P9 use the new automation plane. P5 must close before any local candidate is released. P6 precedes provider delivery because n8n must consume canonical outbox facts rather than make booking or payment decisions.

## Alfred abort and fallback rules

Reject or stop only the new `cascade-n8n` project if any of these occurs:

- available RAM is below 2.5 GiB at the P2 pre-start check;
- available RAM remains below 1.5 GiB during the dormant soak;
- swap use grows continuously rather than settling;
- 15-minute load exceeds 3;
- any existing service restarts, becomes unhealthy, or records an OOM condition;
- free disk falls below 15 GiB;
- editor access is publicly exposed, secrets appear in rendered/logged output, or a workflow/provider becomes active unexpectedly.

When an abort condition occurs, preserve evidence and encrypted backups, stop only the Cascade project, revert only its new proxy/DNS route, and move P3 onward to a separate Cascade VPS. Do not delete volumes during routine rollback.

## Work that is already complete locally

Modules B–E and Waves 2–8 are local candidates with recorded tests. Wave 4 already implements advisory recorded-usage forecasting plus immutable named owner/admin purchase-list review; it contains no supplier-order, provider, outbox, or payment path. These candidates need staged release evidence, product UI wiring where identified, and live authorization/recovery proof. They do not need to be rebuilt merely because the hosting target is now selected.

## Immediate next safe outcome

The [P1 recovery/action packet](./2026-09-06-p1-recovery-action-packet.md), [local completion record](../validation/2026-09-06-p1-local-completion.md), and [Alfred recovery record](../validation/2026-09-06-p1-alfred-recovery.md) close P1. P2/P3 remain held.

The next safe outcome is the concrete P2 action: add at least 2 GiB swap without restarting unrelated services, then rerun the full RAM/load/disk/container/listener/path baseline. Present that exact host-maintenance action for fresh approval. Only after P2 passes should P3 receive a separate approval to create the dormant, provider-free Cascade stack.
