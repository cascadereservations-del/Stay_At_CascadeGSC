# Cascade Hideaway — Complete continuation handoff

**Prepared:** 2026-09-06

**Canonical working tree:** `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`

**Branch:** `codex/cascade-waves-0-1-sol`

**Selected hosting:** Existing Alfred Docker Engine + Portainer CE + separate capped Cascade n8n/PostgreSQL stack

**Subscription decision:** No additional subscription

**Production posture:** Frozen pending recovery, hosting, Module A, and action-time approval gates

**Next safe outcome:** Complete Phase P1 recovery and deployment packet locally

This is the canonical continuation handoff. It records the user's Portainer CE + n8n selection and the full path from the current local candidates to staged operational acceptance. The selection does not authorize a server or production change.

## Current position

- The hosting choice is settled: manage a separate `cascade-n8n` Compose project through the existing Portainer CE on Alfred. Do not add a second Docker daemon and do not replace Alfred's existing n8n.
- Same-host feasibility is conditional on recovery, at least 2 GiB swap, a fresh capacity baseline, strict resource caps, and a 72-hour dormant soak. A separate Cascade VPS is the fallback if a threshold fails or later load grows.
- No new stack, volume, network, secret, route, workflow activation, provider configuration, order, message, or production change has been made.
- Supabase remains the canonical business-state authority. n8n is delivery/integration only.
- All 13 source-controlled n8n workflows are inactive.
- Modules B–E and Waves 2–8 are complete local candidates with recorded evidence. They are not live.
- Module D's Admin UI wiring remains in the owning product repository because that source is outside this worktree.
- Module A production gates remain open and block feature release.

Open the [interactive hosting decision](./cascade-hosting-decision.html) for the capacity and alternatives model, and use the [updated completion plan](../plans/2026-09-06-portainer-n8n-completion-plan.md) for the executable phase sequence.

## Canonical continuation set

- [Current state and production gates](./CURRENT-STATE.md)
- [Development playbook](./DEVELOPMENT-PLAYBOOK.md)
- [Portainer CE + n8n completion plan](../plans/2026-09-06-portainer-n8n-completion-plan.md)
- [Module execution queue](../plans/module-execution-queue.md)
- [Portainer-managed architecture decision](../architecture/adr-002-dedicated-hetzner-cascade-operations.md)
- [Cascade n8n deployment runbook](../runbooks/cascade-n8n-deploy.md)
- [Detailed Alfred capacity audit](../validation/2026-09-06-alfred-detailed-capacity-audit.md)
- [Wave 8 consolidation and recovery evidence](../validation/2026-09-05-wave-8-consolidation-handoff.md)
- [This plan/handoff validation](../validation/2026-09-06-portainer-plan-handoff.md)

## Verified host evidence and decision limits

The 2026-09-06 read-only Alfred audit found four CPU cores, about 3.2 GiB available RAM across repeated samples, load below 0.3, 36 GiB free disk, 19 running containers, no current unhealthy container, and no running-container OOM/restart evidence. Metabase was near its 1.5 GiB memory cap and Alfred had no swap. These facts support a capped dormant trial after prerequisites; they do not prove production capacity.

The candidate stack caps n8n at 1536 MiB / 1.5 CPU and PostgreSQL at 768 MiB / 0.75 CPU, binds the editor to `127.0.0.1:5679`, and uses Cascade-only names, networks, volumes, database, and secrets. Review the exact n8n release and security status before deployment; do not rely on the currently recorded image pin without that action-time check.

## Completed local candidates

| Workstream | Local state | Boundary preserved |
| --- | --- | --- |
| Module A source foundation | Release packets and tests exist; live gates open | Production remains frozen |
| Module B | Atomic canonical booking decision candidate | Delivery cannot own confirmation |
| Module C | Payment evidence/comparison + named Finance review; 47/47 pgTAP pass | AI, OCR, bank email, and service identities cannot confirm payment |
| Module D | Finance-only review queue + inactive delivery boundary | Admin UI wiring is external; OPS receives no Finance/guest-contact detail |
| Module E | Holds, lifecycle, rates, refund authorization, audit, and reconciliation; 43/43 pgTAP pass | Refund authorization never executes a payment |
| Wave 2 | Encrypted/redacted shared inbox + named draft review; 31/31 pgTAP pass | Review does not send or queue a message |
| Wave 3 | Named cleaning/meter evidence and review; 21/21 pgTAP pass | Model results are advisory |
| Wave 4 | Reconciled inventory, usage forecast, and named AAL2 purchase-list review; 31/31 pgTAP plus concurrency/rollback pass | Review never orders, invokes a provider, or creates a Finance fact |
| Wave 5 | Named Finance reconciliation and internal analytics; 50/50 pgTAP plus rollback pass | OPS is denied; no tax/statutory claim |
| Wave 6 | Hashed identity, purpose consent, lifecycle/recovery, retention; 31/31 pgTAP plus rollback pass | Eligibility does not authorize communication |
| Wave 7 | Consent-gated ciphertext drafts + exact-content AAL2 review; 33/33 pgTAP plus rollback pass | Publication remains unauthorized |
| Wave 8 | Authority inventory, operating handoff, dormant Compose render, and disposable recovery | Local evidence does not imply deployment |

## Open Module A gates

Module A is complete only when fresh evidence proves all of the following:

1. Encrypted Supabase production backup and disposable restore, migration-ledger reconciliation, and rollback readiness.
2. Coordinated staff/RLS/named-cleaner release through `docs/plans/2026-08-31-module-a-cutover-packet.md`.
3. Cascade project-owner TOTP enrollment and a fresh AAL2 session. Supabase dashboard-account MFA does not satisfy this gate.
4. A real cleaner Auth identity assigned to the correct property, followed by the full authenticated cleaner smoke and denial checks.
5. Scheduler/liveness secrets and heartbeat smoke before any schedule or monitor activation.
6. Corrected price-history view through its own reviewed release.
7. Recovery proof for Alfred's existing shared n8n database, credential ciphertext, encryption key, and workflows.

## Remaining phase docket

| Phase | Status | Required outcome |
| --- | --- | --- |
| P0 — Decision/source lock | Complete with this handoff when validation passes | Portainer CE + separate n8n/PostgreSQL stack is canonical; no live change |
| P1 — Recovery/deployment packet | **Next** | Existing n8n disposable restore, current image/security review, rendered Compose, exact secret/proxy/backup/smoke/rollback packet |
| P2 — Swap/fresh baseline | Blocked on action approval | At least 2 GiB swap and all pre-start thresholds pass |
| P3 — Dormant stack | Blocked on P1/P2 and action approval | New stack healthy, isolated, MFA-protected, provider-free; 13 workflows inactive |
| P4 — Restore + 72-hour soak | Blocked on P3 | New-stack restore proof and no abort threshold |
| P5 — Module A production closure | Blocked on recovery/action approvals | Every production gate above closed with dated evidence |
| P6 — Core booking release | Blocked on P5 | Modules B/C/D/E released in coordinated batches; named Finance chain proven |
| P7 — Operations/insight release | Blocked on P5/P6 | Waves 3/4/5 released with role isolation and no auto-order |
| P8 — Guest lifecycle release | Blocked on P5 | Waves 2/6/7 released without unreviewed sending/publication |
| P9 — Provider/workflow activation | Blocked on all owning data paths | One credential/provider/workflow batch at a time with source export and rollback |
| P10 — Operational acceptance | Final | Access, backup, restore, monitoring, incident, authority, and retirement evidence complete |

The full entry/exit conditions, dependencies, abort thresholds, and fallback are in the [updated completion plan](../plans/2026-09-06-portainer-n8n-completion-plan.md).

## Immediate continuation sequence

1. Verify Git status/history and preserve the unrelated Task Master files.
2. Read this handoff, the updated completion plan, `CURRENT-STATE.md`, `DEVELOPMENT-PLAYBOOK.md`, ADR-002, the deployment runbook, and the detailed capacity audit.
3. Work on P1 locally: inventory the recovery inputs, prove the existing n8n disposable restore, check official n8n release/security information at execution time, and produce the exact redacted P2/P3 action packet.
4. Run focused recovery, Compose, inactive-workflow, content/link, and whitespace checks. Record exact evidence.
5. Stop before adding swap, creating a stack/route/secret, importing into the live editor, configuring a provider, or changing production. Present the concrete P2/P3 packet for action approval.
6. After approved P2/P3 work, run the 72-hour dormant soak and close Module A before staging any local candidate.
7. Release the remaining modules in P6–P9 order, with separate approvals for production and external effects.

## Abort thresholds and fallback

Reject Alfred before startup if available memory is below 2.5 GiB, swap is below 2 GiB, disk is below 15 GiB, or an existing service is unhealthy/restarting. During the dormant soak, stop only `cascade-n8n` if available memory remains below 1.5 GiB, swap grows continuously, 15-minute load exceeds 3, disk falls below 15 GiB, or any existing service restarts/OOMs. Preserve backups and move the plan to a separate Cascade VPS; never alter or delete Alfred-owned resources.

## Task Master files to preserve outside feature commits

The worktree intentionally contains unrelated Task Master setup. Do not edit, stage, clean, or make these files a prerequisite:

- `.gitignore`
- `.env.example`
- `.taskmaster/`
- `AGENTS.md`
- `docs/handoff/TASKMASTER.md`
- `scripts/taskmaster-codex.mjs`
- `scripts/taskmaster-schema.mjs`
- `tests/taskmaster/`

## Non-negotiable authority and approval rules

- Supabase is canonical for bookings, payments, lifecycle, cleaning, inventory, Finance, consent, and review facts.
- Finance/Admin and OPS remain strictly separate.
- AI, OCR, forecasts, classifications, and email evidence are advisory.
- A named human approves booking/payment confirmation, refunds, discounts, exceptions, cleaning overrides, purchase lists, and publication.
- The business is unregistered; reports make no BIR, tax, statutory, or filing-compliance claim.
- No purchase review places an order. No marketing review publishes. No inbox draft review sends.
- No local test, document, plan, or platform decision authorizes deployment or an external effect.

## Evidence authority

Use current source and Git state first, then dated validation, then approved plans/runbooks, then this handoff. Treat historical notes as context only. Any live-state claim without dated production evidence is unverified.
