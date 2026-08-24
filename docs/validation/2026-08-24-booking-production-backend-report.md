# Cascade Booking Production Backend Deployment Report

**Date:** 2026-08-24 (Asia/Manila)  
**Target:** Cascade Supabase project `qkgfhsdppslwunarczeq`  
**Scope:** database hardening, CRM/outbox/calendar schema, Edge Functions, and non-mutating production smoke checks.

## Deployment result

- The historical production migration files were fetched into this repository before deployment. The migration ledger is now aligned with the repository.
- `supabase db push --linked --dry-run --debug` after deployment reported `upToDate: true` with no remaining migrations.
- The following release migrations were applied: `20260824044654` through `20260824045700` (12 migrations).
- Seven functions were deployed: `submit-booking`, `approve-booking`, `upload-booking-receipt`, `track-site-event`, `automation-callback`, `automation-event-detail`, and `guest-access`.
- Server-only secrets were configured for receipt-upload authorization, automation callbacks, and least-privilege event detail. Values were neither recorded nor committed.

## Local verification

| Check | Result |
|---|---:|
| pgTAP public availability / outbox / booking events / CRM / transition | 45/45 pass |
| Deno Edge Function tests | 20/20 pass |
| Edge Function type checks | 7/7 pass |
| n8n export validator | 13 inactive exports valid |
| Content/design contract tests | 17/17 pass |

The Playwright runner started all 54 browser checks but this terminal integration did not return its final worker summary. It is therefore **not** counted as verified release evidence.

## Production smoke checks

All checks used deliberately invalid input and the public client authorization boundary. No booking, receipt, analytics event, callback, or message was created.

| Endpoint | Expected / observed status | Result |
|---|---:|---:|
| `upload-booking-receipt` with no upload token | 401 / 401 | pass |
| `track-site-event` with a disallowed event | 400 / 400 | pass |
| `guest-access` with a malformed token | 404 / 404 | pass |
| `automation-callback` with no HMAC | 401 / 401 | pass |
| existing `availability` with the public client boundary | 200 / 200 | pass |

## Deliberately not activated

- No n8n database webhook or workflow was activated.
- No Google Calendar OAuth credential or projection workflow was connected.
- No WhatsApp, Telegram, or email automation recipient/template was configured or sent.
- No synthetic booking was submitted to production.

## Remaining release gates

1. Resolve the GitHub remote push so `origin/main` receives the already-validated frontend commits and GitHub Pages can rebuild.
2. Obtain/configure an n8n instance plus provider credentials and approved templates; import the versioned workflow exports inactive, execute fixtures, then enable only approved routes.
3. Connect a dedicated Google Calendar with OAuth and validate one-way projection before enabling CH-W09.
4. Run a deliberately labelled synthetic booking after the frontend release and verify its private receipt, outbox, callback, CRM event, and calendar projection.
5. Capture a definitive Playwright result and production monitoring evidence before declaring full end-to-end completion.
