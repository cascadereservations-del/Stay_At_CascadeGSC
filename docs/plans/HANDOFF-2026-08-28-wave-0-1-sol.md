# Cascade SOL handoff — 2026-08-28

## Resume location

- Worktree: `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`
- Branch: `codex/cascade-waves-0-1-sol`
- HEAD: `99ba867 test(cascade): add platform security regression gates`
- Original user working tree remains untouched at `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking`.

Two untracked files are user-owned Wave 1 work. Preserve them and do not add, delete, or rewrite them unless explicitly asked:

- `supabase/migrations/20260824045800_dispatch_w01_to_n8n.sql`
- `supabase/tests/database/w01_dispatch.sql`

## Completed and committed

1. **Production recovery inventory** — `c3a8be8`
   - Safe deployed-function contract: 21 deployed functions; all critical sources now local.
   - Historical schema snapshot is recorded. Fresh live DB dump remains blocked by unavailable local Docker.
2. **Recovered deployed function source** — `afab977`, then type fixes `9c5daf6`
   - Recovered 12 functions, including `upload-photo` discovered during inventory.
3. **Isolated n8n deployment design** — `47c6b35`
   - Separate Compose, PostgreSQL, secrets, encrypted backups, resource limits and recovery runbook.
   - Do not deploy until a new VPS capacity/swap preflight and owner approval.
4. **Finance/OPS boundary** — `955eaf8`
   - Closed templates, recursive OPS financial-data rejection, database outbox guard and tests.
5. **Operational RLS lockdown design** — `78916da`
   - Migration is intentionally not deployed until named/scoped cleaner and inventory sessions are ready.
6. **Cron scheduler heartbeats** — `574783e`
   - Signed cron header, heartbeat monitor, safe Finance/OPS alerts, turnover instrumentation, inactive scheduler configurator, and recovery runbook.
   - Database pgTAP check is blocked because Docker/PostgreSQL is unavailable locally; no scheduler was activated.
7. **Security regression gate** — `99ba867`
   - GitHub CI, secret scan, endpoint authority manifest and n8n graph checks.
   - Eight recovered endpoints are deliberately marked `migration_blocked`, not treated as safe to redeploy.

## Verified results

- `node scripts/audit/compare-supabase-production.mjs --check` passes: 21 deployed = 12 recovered + 9 versioned.
- Deno scheduler checks pass: cron-secret (1), heartbeat monitor (4), route guards (6); turnover and monitor type-check cleanly.
- `node --test tests/security/endpoint-boundaries.test.mjs` passes (3).
- `node scripts/audit/scan-secrets.mjs` passes.
- `node scripts/audit/check-edge-auth.mjs` passes with 22 endpoint entries.
- `node scripts/check-n8n-workflows.mjs` passes for 13 inactive workflow exports.
- `npx supabase test db supabase/tests/database/job_heartbeats.sql` cannot connect to `127.0.0.1:54322`; this is an environment gate, not a passed DB test.

## Important safety constraints

- Canonical Supabase project: `qkgfhsdppslwunarczeq`.
- Never put finance/payment/amount information in OPS Telegram. Finance chat is `-1003819352746`; OPS chat is `-1003798341977`.
- Direct bookings are confirmed only after a human approval. Receipt OCR and bank email are advisory evidence, never an automatic payment confirmation.
- No production deployment, schema deployment, n8n activation, cron activation, DNS/provider change, real message, or credential setup occurred or is authorized by this branch alone.
- Keep Cascade separate from Alfred/Alex at container, database, credential and data layers.
- OpenRouter must use pinned, evaluated allowlists; avoid a random free-router model in production.

## Security finding requiring follow-up

The following recovered endpoints have `verify_jwt=false` and no sufficient current in-function signature/session boundary. They are tracked as deployment-blocked in `docs/architecture/edge-auth-manifest.json`:

- `last-readings`
- `upload-photo`
- `submit-cleaning`
- `calendar-sync`
- `daily-digest`
- `rain-alert`
- `airbnb-email-sync`
- `missed-cleaning-alert`

Do not redeploy these functions unchanged. Tasks 0.9 and later waves need to supply named staff sessions or shared cron/Gmail signatures before an activation review.

## Next implementation order

1. Wave 0 Task 0.9: named staff identities, property-scoped roles, MFA gate for owner/admin/finance approvals, session revocation/offboarding.
2. Wave 0 Task 0.10: privacy inventory, retention, requests/holds and breach runbook.
3. Wave 0 Task 0.11: correlation IDs, redaction and degraded-mode tests; add an independent liveness probe for the heartbeat monitor.
4. Wave 0 Task 0.12: migration preflight/expand-contract release discipline.
5. Wave 0 Task 0.8 recovery report last, recording the outstanding Docker/VPS/staging gates honestly.
6. Only then begin Wave 1 Task 1.1 booking/payment state-machine migration against this updated baseline.

## Before any production action

1. Start Docker or a disposable Supabase local environment and run all pgTAP files, including route guards, RLS, and heartbeat tests.
2. Re-run read-only VPS capacity/swap and port checks for the isolated n8n design.
3. Stage signed cron functions and capture heartbeat evidence.
4. Obtain fresh owner approval for each external change.
