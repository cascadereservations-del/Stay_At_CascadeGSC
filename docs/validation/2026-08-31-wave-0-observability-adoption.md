# Wave 0.11 observability adoption verification

**Verified:** 2026-08-31 Asia/Manila / 2026-08-30 UTC

**Mode:** local source, tests and disposable Supabase only; no function deployment, Uptime Kuma configuration, n8n activation, provider message or production connection

## Verdict

**Local release candidate: PASS.** Every recovered Edge Function now enters the same privacy-safe request boundary. The wrapper validates or replaces inbound correlation IDs, propagates the safe value into the handler and response, exposes it through CORS and emits one JSON-line completion/failure event while preserving existing handler failures and response behavior.

## Implemented contract

- `edge-observability-manifest.json` covers exactly the 12 recovered functions and assigns conservative route classes.
- Redaction recurses through arrays, nested objects and error values. All routes remove tokens, signed/receipt URLs, contacts, addresses, access codes, bank references, raw provider/OCR payloads and message bodies. OPS also removes string and structured numeric financial fields.
- Existing console calls are sanitized at the isolated Edge runtime boundary; business handler bodies, auth checks, writes, provider calls, Telegram text and response decisions were not refactored.
- Provider outages have closed decisions for OpenRouter, n8n, Gmail, Chatwoot and Airbnb. Each preserves canonical state and prohibits an automatic financial decision.
- `job-heartbeat-liveness` independently checks the fixed monitor heartbeat. `GET`/`HEAD` require a dedicated constant-time liveness secret before any database query and reveal only `{ ok, reason_code }`.

## Verification evidence

| Check | Result |
|---|---|
| Adoption contract initial run | RED: first recovered function lacked the wrapper |
| Shared observability/redaction initial run | RED: 5 expected failures |
| Degraded-mode initial run | RED: machine contract and decision module absent |
| Liveness initial behavioral run | RED: 5/5 intentionally unimplemented |
| Signed-probe boundary initial run | RED: missing/invalid secret still reached the loader |
| Node platform-safety matrix | 37/37 pass |
| Full Deno matrix | 35/35 pass |
| Recovered/new entrypoint type-check | 13/13 pass |
| Edge authority manifest | 24/24 entries pass; eight existing endpoints remain deployment-blocked |
| Source inventory | 21 deployed = 12 recovered + 9 versioned; liveness is local-only |
| n8n workflow graph | 13/13 valid and inactive |
| Secret scan | pass |
| Disposable Supabase recovery | 28/28 migrations; all 15 database test files pass |
| Disposable evidence timestamp | `2026-08-31T00:04:48.626Z` |
| Active local database identity | unchanged |
| Production connection | not used |

## Production gates

- Do not redeploy any recovered function merely to obtain observability. Each keeps its existing authority classification and must ship only through its owning release/cutover; all eight blocked endpoints remain blocked.
- Create `CASCADE_LIVENESS_SHARED_SECRET` separately from the scheduler secret, deploy the liveness function through a reviewed function release, then configure the existing VPS Uptime Kuma header and five-minute HTTP-200 monitor.
- Route liveness downtime to Finance/Admin only. Never expose its secret to OPS, n8n, logs or source control.
- Stage wrapper adoption and inspect sanitized log shape/volume before broad production rollout.
- No Wave 0.11 artifact authorizes n8n publication, scheduler activation, provider messages or production deployment.
