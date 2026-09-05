# Development Playbook

## Local setup and safe checks

Run from the canonical working tree:

```powershell
Set-Location 'C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol'
git status --short
npm.cmd test
node scripts/audit/scan-secrets.mjs
node scripts/check-n8n-workflows.mjs
```

Run only the focused checks relevant to the change as well as the broad checks required by the module’s plan. Existing test groups include application/UI, security, resilience, recovery, infrastructure, migrations, and Supabase database tests.

For mockup changes:

```powershell
Set-Location 'docs/mockups/cascade-command-center-src'
npm.cmd run build
Set-Location '..\..\..'
node docs/mockups/audit/render-complete-mockups.cjs
```

The renderer writes local screenshots under `docs/mockups/`. It does not touch production.

## Work method for every module

1. Identify the module in `docs/plans/module-execution-queue.md`.
2. Read its affected migration/function/workflow/runbook and the latest validation record.
3. State the authority boundary: who can read, write, approve, and receive an alert.
4. Implement the smallest reversible source change.
5. Add/adjust focused tests and run the module’s validation commands.
6. Run secret scanning and diff checks before commit.
7. Commit source, tests, and dated validation evidence together.
8. Stop before production changes and request explicit approval with the exact action, target, rollback, and expected side effects.

## Required authorization model

| Action | Allowed authority |
| --- | --- |
| View public availability | Public/read-only endpoint with minimized fields |
| Submit a direct booking request or receipt | Guest-scoped endpoint with validation/rate limits; creates pending state only |
| Confirm payment / booking | Named Finance/Admin human through atomic Supabase transaction |
| Approve expense or purchase list | Named Admin/Owner human |
| Override cleaning verification | Named inspector/Admin human with reason/audit |
| Send Finance alert | Finance/Admin routing only |
| Send OPS alert | OPS routing only; no money, payment, receipt, rate, deposit, refund, or guest contact data |
| Publish social content | Exact approved content hash through official provider API |

## Data and automation rules

1. Every new business domain is property-scoped (`property_id` directly or immutably inherited).
2. Put business facts and transitions in Supabase; n8n consumes signed outbox events and returns delivery results.
3. Use idempotency keys for all external delivery and booking lifecycle transitions.
4. Keep AI outputs structured, bounded, validated, and explainable. Missing/uncertain model output routes to review, not success.
5. Store receipts, cleaner photos, meter images, and similar evidence privately with least-privilege access.
6. Preserve an audit trail for approvals, overrides, correlation decisions and delivery outcomes.
7. Never use `appendRow()` for the Named Table Google Sheets workflows; use `getRange().setValues()`.
8. Never store credentials, customer data, source receipt images, chat exports, or bank notifications in the repository, mockup files, or Obsidian.

## Financial analytics implementation contract

The mockup defines the management language. The production system must implement it from reconciled canonical facts:

| Metric | Formula / interpretation |
| --- | --- |
| Gross booking income | Confirmed Airbnb/direct booking income before operating expenses; retain channel provenance. |
| Operating expenses | Approved, categorized expenses accumulated in the selected period; exclude unapproved claims. |
| Operating profit | Gross booking income minus operating expenses. Show exclusions such as tax, owner drawings, depreciation, and debt separately. |
| Cost per available night | Selected-period operating expenses ÷ calendar days/available nights. Label the denominator clearly. |
| Cost per occupied night | Selected-period operating expenses ÷ occupied nights. Do not substitute this for cost per available night. |
| Electricity daily use/cost | Meter-backed kWh ÷ days and reconciled electricity cost ÷ days. Preserve reading confidence and gaps. |
| Water daily use/cost | Meter-backed m³ ÷ days and reconciled water cost ÷ days. Preserve decimal reading rules. |
| ADR | Revenue ÷ occupied nights. |
| RevPAR | Revenue ÷ available nights. |
| Occupancy | Occupied nights ÷ available nights. |

Targets must be versioned/owner-approved values with an effective date. The interface should show the target, variance, period, denominator, data freshness, and a plain-language interpretation. Never present a sample/mockup figure as a live fact.

## Production stop conditions

Stop and request owner approval before any of these actions:

- Applying a Supabase migration or deploying an Edge Function.
- Changing RLS, RPC execute grants, secrets, cron, webhooks, or storage policies.
- Publishing/activating an n8n workflow, configuring credentials, or emitting an email, Telegram, WhatsApp, calendar, Meta, or supplier action.
- Altering Portainer/Docker/VPS state, upgrading n8n, or importing a production database/credential backup.
- Editing production bookings, payment status, calendar events, financial facts, or cleaner evidence.
- Pushing a branch expected to affect GitHub Pages or another live hosting target.

For a production request, provide: exact target, source commit/release file, prerequisite check, backup/rollback path, expected external effects, smoke test, and abort condition.

## Existing runbooks

| Need | Read first |
| --- | --- |
| Database release | `docs/runbooks/database-release.md` |
| n8n deployment/restore | `docs/runbooks/cascade-n8n-deploy.md`, `docs/runbooks/n8n-live-baseline-2026-08-29.md` |
| Scheduler/heartbeat recovery | `docs/runbooks/scheduler-recovery.md` |
| Degraded provider operation | `docs/runbooks/degraded-operations.md` |
| Staff access lifecycle | `docs/runbooks/staff-access-lifecycle.md` |
| Privacy request or hold | `docs/runbooks/data-subject-request.md` |
| Personal data breach | `docs/runbooks/personal-data-breach.md` |
| Consolidated operating authority and recovery | `docs/runbooks/cascade-operational-handoff.md` |
| Dedicated Hetzner automation direction | `docs/architecture/adr-002-dedicated-hetzner-cascade-operations.md` and `docs/runbooks/cascade-n8n-deploy.md` |

## Model routing

- Routine documentation, inventories, fixtures and static checks: GPT-5.6 Luna — Medium.
- Isolated UI/Edge Function/n8n configuration and test implementation: GPT-5.6 Terra — High.
- Migrations, payment/booking state changes, access rules, production release audits, and final conflict resolution: GPT-5.6 SOL — High.

Lower-capability work may not independently change financial state, authorization, database schema, production configuration, or payment contracts.
