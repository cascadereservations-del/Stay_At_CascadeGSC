# Cascade Hideaway — Development Handoff Center

**Prepared:** 2026-09-06

**Canonical working tree:** `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`

**Branch at handoff:** `codex/cascade-waves-0-1-sol`
**Current revision:** Run `git log -1 --oneline`; do not rely on a copied SHA.

This directory is the single starting point for the next developer. It indexes the working code, executable plans, validation evidence, operational runbooks, visual contracts, and historical Obsidian memory without copying credentials, customer data, private evidence, or production exports into a new location.

## Start here

1. Read [COMPLETE-HANDOFF-P3-2026-09-06.md](./COMPLETE-HANDOFF-P3-2026-09-06.md) for the complete remaining-work handoff.
2. Open the [post-P3 phase dashboard](./cascade-phase-status-p3.html) for the visual completed/remaining map.
3. Read [CURRENT-STATE.md](./CURRENT-STATE.md) for detailed state and production gates.
4. Read [DEVELOPMENT-PLAYBOOK.md](./DEVELOPMENT-PLAYBOOK.md) before editing or deploying anything.
5. Use [FILE-MAP.md](./FILE-MAP.md) to locate canonical source, plans, tests, workflows, runbooks, data definitions, and mockups.
6. Read the [Portainer CE + n8n completion plan](../plans/2026-09-06-portainer-n8n-completion-plan.md), then `docs/plans/module-execution-queue.md`.
7. Use [RESUME-PROMPT-P3.md](./RESUME-PROMPT-P3.md) when continuing in a new chat.
8. Before any production-affecting step, read the applicable release/runbook under `docs/runbooks/`, then obtain fresh owner approval.

## What this repository is

Cascade Hideaway is a one-property boutique accommodation business, designed to grow to three properties. The objective is a customer-centred, mostly self-hosted operating system built on Supabase, GitHub, the existing Portainer n8n instance, and narrow Apps Script/Google integrations—not a commercial PMS replacement by a single deployment.

The repository is the **implementation authority**. Its plans, migrations, Edge Functions, tests, release contracts, workflow exports, and validation records determine what can be changed. The Obsidian vault is an important historical/business-memory source, but entries must be reconciled against source-controlled evidence before being treated as current production state.

## Current position in one minute

| Area | State | Meaning |
| --- | --- | --- |
| Module A safety foundation | Local release candidate / partly protected live | Source, tests, safe-release and privacy/observability packets exist. Production cutover gates are still open. |
| Direct booking site | Existing live product | Do not replace it with a mockup. Wave 1 will connect the final canonical booking decision flow after gates close. |
| n8n hosting P0–P3 | Complete | The separate `cascade-n8n` Portainer stack is healthy, loopback-only and owner-MFA protected; 13 workflows are inactive and credentials are empty. |
| P4 recovery and soak | Next | Encrypted backup/disposable restore and a complete 72-hour dormant soak have not started. |
| Cleaner and inventory apps | Existing products with local security foundations | Production named-cleaner/RLS cutover remains gated. |
| Module B booking decision | Local candidate, not deployed | Atomic Supabase RPC and approval delegation passed recorded local and Deno checks. Release checks remain. |
| Module C payment evidence | Local candidate verified | Source and Deno checks pass; all 47 rollback-only pgTAP assertions pass. |
| Modules D–E | Local candidates | Backend/database boundaries are complete locally; Module D Admin UI wiring remains in its owning repository. |
| Wave 2 | Local candidate | Shared-inbox data, escalation, assignment, and draft-review boundaries pass locally; no delivery path exists. |
| Wave 3 | Local candidate | Private cleaning/meter evidence and named review pass locally; no production change. |
| Wave 4 | Local candidate verified | Inventory reconciliation, advisory forecasts, named owner/admin shopping-list review, and compensating rollback pass locally. |
| Wave 5 | Local candidate verified | Named Finance reconciliation and internal management metrics pass locally; reports make no compliance claim. |
| Wave 6 | Local candidate verified | Hashed identity, separate-purpose consent, recovery suppression, and retention controls pass locally; no communication path exists. |
| Wave 7 | Local candidate verified | Consent-gated ciphertext drafts and exact-content named review pass locally; publication remains unauthorized. |
| Wave 8 | Local candidate verified | Authority inventory, operating handoff, dormant Compose render, and disposable n8n/Supabase recovery pass locally. |
| AI / OCR / vision / chat | Advisory layer only | OpenRouter may advise only; it cannot confirm payment, override policy, or post financial decisions. |
| Product experience mockups | Complete, local, sample data | Dashboard, cleaner and direct-booking prototypes are implementation contracts, not production UI. |

## Non-negotiable boundaries

- **Supabase is the system of record.** n8n, Telegram, AI and Apps Script do not own bookings, payments, calendars, finance, inventory, or approvals.
- **Payment confirmation needs an authorized human.** Receipt OCR and bank-email correlation are evidence, never proof of funds by themselves.
- **Finance/Admin and OPS are separate.** OPS must never receive amounts, payment status, receipts, bank information, rates, deposits, refunds, or guest contact details.
- **AI is advisory.** Validate all model output with deterministic rules; retain human approval for high-risk decisions.
- **No automatic supplier ordering.** Generate recommendations and approval/shopping lists only.
- **No production activation by implication.** Deployment, n8n publication, cron activation, provider setup, email/Telegram sending, Meta publication, Docker/VPS changes, and data migration all require fresh owner approval at action time.
- **No secrets or personal data in Git, mockups, handoff files, or chat.** Use environment secrets/Vault and redacted evidence only.

## The immediate next outcome

Portainer CE on Alfred now manages the separate capped Cascade n8n/PostgreSQL stack. P0–P3 passed on 2026-09-06: the existing n8n recovery proof, 2049 MiB persistent swap, full host baseline, isolated stack, inactive workflow round trip and named-owner MFA are complete. The next outcome is P4's separately approved encrypted recovery drill followed by a complete 72-hour dormant soak.

Production remains frozen until Module A gates close. Do not deploy Supabase changes, activate n8n, configure providers, modify VPS/Docker, or send messages.

## Visual implementation contract

Open the portable local file:

[`docs/mockups/cascade-experience-mockups.html`](../mockups/cascade-experience-mockups.html)

It includes:

- Command Center with owner-safe decision queues, forecast boundary, system health, and target-driven analytics/P&L.
- Cleaner Checklist with the five-stage evidence and correction/inspection flow.
- Direct Booking with luxury guest landing page, date/guest journey, payment-evidence review state, and confirmation boundary.

The numeric values are **sample data only**. Live implementation must compute them from canonical/reconciled data and use owner-approved targets.

## Handoff package contents

| Document | Purpose |
| --- | --- |
| [COMPLETE-HANDOFF-P3-2026-09-06.md](./COMPLETE-HANDOFF-P3-2026-09-06.md) | Current complete remaining-work handoff and exact continuation sequence. |
| [Portainer CE + n8n completion plan](../plans/2026-09-06-portainer-n8n-completion-plan.md) | Selected architecture and phases P0–P10, including gates, aborts, and fallback. |
| [cascade-phase-status-p3.html](./cascade-phase-status-p3.html) | Current offline visual status: completed, gated, next, and planned work. |
| [CURRENT-STATE.md](./CURRENT-STATE.md) | Verified current status, gates, decisions, and known conflicts. |
| [DEVELOPMENT-PLAYBOOK.md](./DEVELOPMENT-PLAYBOOK.md) | Safe continuation workflow, test commands, approval gates, and development rules. |
| [FILE-MAP.md](./FILE-MAP.md) | Canonical file and data map; what each location owns. |
| [RESUME-PROMPT-P3.md](./RESUME-PROMPT-P3.md) | Copy/paste context block for a new developer or new coding session. |
| `docs/plans/` | Executable plans and handoffs. |
| `docs/runbooks/` | Production, privacy, recovery, scheduler and n8n procedures. |
| `docs/validation/` | Evidence for local/prod-related verification. |
| `docs/architecture/` | Architectural decisions and contracts. |
| `automation/n8n/workflows/` | Inactive, source-controlled workflow exports. |
| `supabase/` | Migrations, Edge Functions, SQL tests, release contracts, recovery tooling. |
| `docs/mockups/` | Product design audit, editable source, portable mockup and visual checks. |

## Handoff acceptance criteria

Another developer should be able to resume safely by reading this directory, running the documented local checks, choosing the next approved module, and stopping at each named production gate. If a fact cannot be supported by current repository evidence, record it as unverified rather than assuming it is live.
