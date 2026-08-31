# Cascade Hideaway — Development Handoff Center

**Prepared:** 2026-08-31  
**Canonical working tree:** `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`  
**Branch at handoff:** `codex/cascade-waves-0-1-sol`  
**Latest handoff commit:** `51d2053 docs(cascade): add profitability analytics mockup`

This directory is the single starting point for the next developer. It indexes the working code, executable plans, validation evidence, operational runbooks, visual contracts, and historical Obsidian memory without copying credentials, customer data, private evidence, or production exports into a new location.

## Start here

1. Read [CURRENT-STATE.md](./CURRENT-STATE.md) for what is complete, gated, planned, and intentionally deferred.
2. Read [DEVELOPMENT-PLAYBOOK.md](./DEVELOPMENT-PLAYBOOK.md) before editing or deploying anything.
3. Use [FILE-MAP.md](./FILE-MAP.md) to locate canonical source, plans, tests, workflows, runbooks, data definitions, and mockups.
4. Read `docs/plans/module-execution-queue.md` for the current approved execution order.
5. Before any production-affecting step, read the applicable release/runbook under `docs/runbooks/`, then obtain fresh owner approval.

## What this repository is

Cascade Hideaway is a one-property boutique accommodation business, designed to grow to three properties. The objective is a customer-centred, mostly self-hosted operating system built on Supabase, GitHub, the existing Portainer n8n instance, and narrow Apps Script/Google integrations—not a commercial PMS replacement by a single deployment.

The repository is the **implementation authority**. Its plans, migrations, Edge Functions, tests, release contracts, workflow exports, and validation records determine what can be changed. The Obsidian vault is an important historical/business-memory source, but entries must be reconciled against source-controlled evidence before being treated as current production state.

## Current position in one minute

| Area | State | Meaning |
| --- | --- | --- |
| Wave 0 safety foundation | Local release candidate / partly protected live | Source, tests, safe-release and privacy/observability packets exist. Production cutover gates are still open. |
| Direct booking site | Existing live product | Do not replace it with a mockup. Wave 1 will connect the final canonical booking decision flow after gates close. |
| n8n | Existing shared Portainer runtime, workflows inactive | Use `Cascade Hideaway` folder and dedicated Cascade credentials only. Do not publish workflows without approval. |
| Cleaner and inventory apps | Existing products with local security foundations | Production named-cleaner/RLS cutover remains gated. |
| AI / OCR / vision / chat | Planned advisory layer | OpenRouter may advise only; it cannot confirm payment, override policy, or post financial decisions. |
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

The next engineering outcome is **Module A production-gate closure** (or an explicit owner decision to re-sequence it), followed by **Wave 1: reliable booking, calendar, and human payment review**. Do not start chatbot, cleaning AI, or marketing automation as substitute work while booking authority and authorization gates remain unresolved.

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
| [CURRENT-STATE.md](./CURRENT-STATE.md) | Verified current status, gates, decisions, and known conflicts. |
| [DEVELOPMENT-PLAYBOOK.md](./DEVELOPMENT-PLAYBOOK.md) | Safe continuation workflow, test commands, approval gates, and development rules. |
| [FILE-MAP.md](./FILE-MAP.md) | Canonical file and data map; what each location owns. |
| [RESUME-PROMPT.md](./RESUME-PROMPT.md) | Copy/paste context block for a new developer or new coding session. |
| `docs/plans/` | Executable plans and handoffs. |
| `docs/runbooks/` | Production, privacy, recovery, scheduler and n8n procedures. |
| `docs/validation/` | Evidence for local/prod-related verification. |
| `docs/architecture/` | Architectural decisions and contracts. |
| `automation/n8n/workflows/` | Inactive, source-controlled workflow exports. |
| `supabase/` | Migrations, Edge Functions, SQL tests, release contracts, recovery tooling. |
| `docs/mockups/` | Product design audit, editable source, portable mockup and visual checks. |

## Handoff acceptance criteria

Another developer should be able to resume safely by reading this directory, running the documented local checks, choosing the next approved module, and stopping at each named production gate. If a fact cannot be supported by current repository evidence, record it as unverified rather than assuming it is live.
