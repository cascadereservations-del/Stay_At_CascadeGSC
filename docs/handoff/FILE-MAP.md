# File, Plan, and Data Map

This is an ownership index, not a copy of sensitive data. Keep each artifact in its canonical location; add it here when a new workstream is introduced.

## Repository root

`C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`

| Location | Owns | Use / caution |
| --- | --- | --- |
| `supabase/` | Database migrations, Edge Functions, SQL tests, release contracts, recovery scripts | Canonical backend source. Never apply a migration without the release runbook and approval. |
| `automation/n8n/workflows/` | 13 reviewed, inactive n8n workflow exports | Source baseline; no credentials in JSON; must remain inactive until gate closes. |
| `infrastructure/cascade-n8n/` | Deferred isolated n8n Docker path | Do not deploy unless a documented migration trigger occurs. |
| `docs/plans/` | Master plan, module queue, phase packets and older handoffs | Use `module-execution-queue.md` to choose the next module. |
| `docs/architecture/` | ADRs, production/edge/degraded-mode contracts | Read before changing cross-system design. |
| `docs/runbooks/` | Production and operational procedures | Required reading before an action covered by a runbook. |
| `docs/validation/` | Dated proof and validation records | Evidence, not permission to activate a different release. |
| `docs/privacy/` | Retention, processor register and data inventory | Update when personal-data flows change. |
| `docs/mockups/` | Product audit, interactive prototypes, editable mockup source, visual render scripts | Sample data only; no production UI is changed by these files. |
| `tests/` | Application, security, resilience, recovery, infrastructure and migration checks | Expand focused tests with each source change. |
| `scripts/` | Secret scan, release safety, migration, audit and recovery tools | Prefer provided scripts to improvised production commands. |
| `assets/` | Direct-booking visual/static assets and client scripts | Inspect owning site code before changing public presentation. |

## Planning and decision sources

| File | Why it matters |
| --- | --- |
| `docs/plans/2026-08-31-cascade-system-plan-status-and-architecture.md` | Current architectural briefing, wave status, workflows and open production gates. |
| `docs/plans/module-execution-queue.md` | Approved module sequence, model routing and shared stop conditions. |
| `docs/plans/HANDOFF-2026-08-30-sol-security-and-release-preflight.md` | Security/release preflight continuation detail. |
| `docs/architecture/adr-001-shared-portainer-n8n.md` | Why existing Portainer n8n is used first and when to isolate. |
| `docs/runbooks/n8n-live-baseline-2026-08-29.md` | Read-only shared n8n inventory and duplicate W01 warning. |
| `docs/mockups/2026-08-31-product-experience-redesign-audit.md` | Product design critique and UI implementation priorities. |
| `docs/handoff/` | This handoff center. |

## Product mockup sources

| Asset | Location |
| --- | --- |
| Portable full suite | `docs/mockups/cascade-experience-mockups.html` |
| Compatibility alias | `docs/mockups/cascade-command-center-mockup.html` |
| Editable source | `docs/mockups/cascade-command-center-src/` |
| Mockup build instructions | `docs/mockups/cascade-command-center-src/README.md` |
| Current product audit renderer | `docs/mockups/audit/render-current-products.cjs` |
| Full suite renderer | `docs/mockups/audit/render-complete-mockups.cjs` |
| Analytics screenshots | `docs/mockups/cascade-command-center-analytics.png`, `cascade-command-center-analytics-mobile.png` |

## Core data ownership map

| Domain | Canonical source | Access / implementation rule |
| --- | --- | --- |
| Property and availability | Supabase Postgres / calendar projection | Public availability endpoint returns minimized data only. |
| Direct bookings and confirmations | Supabase transaction/RPC + audit/outbox | Named approval; atomic recheck; idempotency required. |
| Payment evidence | Private Supabase Storage + canonical correlation/review records | OCR and bank-email values are advisory evidence; Finance/Admin only. |
| Guest CRM | Supabase property-scoped records | Consent/minimization required; no separate CRM at current scale. |
| Cleaning/meter evidence | Authenticated cleaner records + private storage | Required evidence, deterministic validation, human override and audit. |
| Inventory / purchases | Canonical stock, verified usage and approved purchase records | Forecast/recommendation allowed; supplier ordering prohibited. |
| Financial facts | Reconciled bookings/payouts plus approved transactions/expenses | Separate gross income, expense, cash-flow, and profit concepts; show freshness/coverage. |
| Automations | Transactional outbox + signed n8n callbacks | n8n is delivery only; it does not become the source of truth. |
| Analytics | Reconciled Supabase facts | Targets are effective-dated, owner-approved and property-scoped. |
| Sensitive operational logs | Redacted observability events | Correlation ID and reason-only telemetry; no secrets or unnecessary PII. |

## External systems and their role

| System | Role | Boundary |
| --- | --- | --- |
| Airbnb | Listing, channel reservations and payouts | Treat imports/feeds as external inputs; no unofficial inbox automation/scraping. |
| Direct booking site | Guest-facing inquiry/request experience | Live availability is read-only; final confirmation occurs in canonical backend. |
| Supabase | Canonical database, private storage, Edge Functions, RLS, audit/outbox | Primary authority. |
| Existing Portainer n8n | Timers, adapters, integrations and delivery retries | Dedicated Cascade folder/credentials; inactive until approval. |
| Telegram | Finance/Admin decisions and OPS advisories | Separate routes/templates; no Finance leakage to OPS. |
| Gmail/bank notifications | Payment-review evidence | Sender allowlist and deterministic correlation; never a payment-confirmation authority. |
| OpenRouter | Chat/OCR/vision/content advisory calls | Structured, minimized, validated prompts/results; no autonomous high-risk actions. |
| Google Apps Script | Narrow legacy/Google integration | Never booking/payment authority; respect Named Table write rule. |
| Meta APIs | Future Messenger, WhatsApp Business and selective publishing | Official APIs only; explicit approval flow. |
| Obsidian vault | Historical project knowledge | Read/reconcile; never store secrets/production payloads. |

## Obsidian location

`D:\ObsidianVault\20-projects\cascade-hideaway\`

Useful starting notes:

- `00-STATE-cascade.md` — curated historical status.
- `01-FACTS-cascade.md` — facts/reference context.
- `02-DECISIONS-cascade.md` — append-only decisions.
- `03-BASELINE-cascade.md` — earlier baseline/audit material.
- `04-HANDOFF-cascade.md` — prior detailed handoff notes.

The vault must not be used as a replacement for release evidence or a credential store.
