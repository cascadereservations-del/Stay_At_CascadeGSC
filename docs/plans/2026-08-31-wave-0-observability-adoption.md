# Wave 0.11 Observability Adoption Implementation Plan

**Goal:** Make every recovered Cascade Edge Function emit correlation-safe, recursively redacted request events, replace prose-only outage assertions with an executable degraded-mode contract, and provide an independent heartbeat-liveness target without changing booking, finance, cleaning, or notification decisions.

**Architecture:** A shared `withObservability` request wrapper validates or generates one correlation ID, propagates it into the handler and response, installs an isolate-local redacted console, and emits one structured completion/failure event. A machine-readable degraded-mode contract drives both Deno decisions and Node regression tests. A separate signed, read-only `job-heartbeat-liveness` function reports only healthy/stale/missing/unavailable and is prepared, but not deployed, for the existing VPS Uptime Kuma monitor.

**Tech Stack:** Supabase Edge Functions, Deno/TypeScript, Node.js contract tests, GitHub Actions, existing Portainer Uptime Kuma.

---

## Fixed adoption scope

The recovered-function source of truth is `docs/architecture/production-contract.json`. Wave 0.11 must cover all 12 recovered slugs with these conservative log routes:

| Function | Log route |
|---|---|
| `airbnb-email-sync` | `ops` |
| `daily-digest` | `ops` |
| `last-readings` | `ops` |
| `missed-cleaning-alert` | `ops` |
| `notify-cleaner-payment` | `ops` |
| `ocr-receipt` | `finance` |
| `rain-alert` | `ops` |
| `submit-cleaning` | `ops` |
| `telegram-expense` | `ops` |
| `turnover-verifier` | `ops` |
| `upload-photo` | `ops` |
| `weather-proxy` | `guest` |

Using `ops` for a mixed Finance/OPS function is deliberately conservative: financial amounts are removed from all of that function's logs. This phase does not reclassify any endpoint, publish a workflow, deploy a function, configure Uptime Kuma, or send a provider message.

### Task 1: Define failing adoption and redaction contracts

**Files:**
- Create: `docs/architecture/edge-observability-manifest.json`
- Create: `tests/observability/edge-observability-adoption.test.mjs`
- Modify: `supabase/functions/_shared/redaction.test.ts`
- Modify: `supabase/functions/_shared/observability.test.ts`

- [x] **Step 1: Add the exact adoption manifest**

Create schema version 1 with the 12 entries in the fixed scope table. Each entry contains only `slug` and `route`; reject duplicates, unknown routes, missing recovered slugs, and extra slugs in the Node test.

- [x] **Step 2: Add a static recovered-function adoption test**

For every manifest entry, read `supabase/functions/<slug>/index.ts` and assert it imports `withObservability` from `../_shared/observability.ts` and contains this exact configuration:

```ts
withObservability({ functionName: '<slug>', route: '<route>' }, async
```

Also assert the manifest slug set equals `production-contract.json.recovered_slugs` and every source file remains present.

- [x] **Step 3: Add recursive redaction cases**

Extend the Deno tests to require all of these outcomes:

```ts
redactLogFields({ nested: { email: 'guest@example.com' } }).nested.email === '[REDACTED_EMAIL]'
redactLogFields({ access_code: '4821' }).access_code === '[REDACTED_ACCESS_CODE]'
redactLogFields({ message_body: 'guest supplied private details' }).message_body === '[REDACTED_MESSAGE_BODY]'
redactLogFields({ receipt_url: 'https://storage.test/private.jpg' }).receipt_url === '[REDACTED_RECEIPT_URL]'
redactForLog('Meet at Block 47 Lot 39, Bria Homes').includes('[REDACTED_ADDRESS]')
```

Retain the existing rule that currency is removed on `ops` routes but may remain in Finance diagnostic context.

- [x] **Step 4: Add wrapper behavior cases**

Test a fake handler through `withObservability` and prove:

- a valid request correlation ID is preserved;
- an invalid ID is replaced;
- the safe ID is available to the wrapped handler;
- every response has `X-Cascade-Correlation-Id`;
- CORS allow/expose headers include the correlation header;
- completion events contain `event`, `function_name`, `correlation_id`, `reason_code`, `status`, and `duration_ms`;
- thrown errors emit only `UNHANDLED_EXCEPTION` and are rethrown so existing runtime behavior is preserved;
- console arguments are recursively redacted before reaching the underlying console.

- [x] **Step 5: Run RED**

```powershell
node --test tests/observability/edge-observability-adoption.test.mjs
deno test --no-lock supabase/functions/_shared/redaction.test.ts supabase/functions/_shared/observability.test.ts
```

Expected: adoption fails for all 12 recovered functions and the new recursive/wrapper assertions fail against the current shallow utilities.

### Task 2: Harden the shared observability boundary

**Files:**
- Modify: `supabase/functions/_shared/redaction.ts`
- Modify: `supabase/functions/_shared/observability.ts`

- [x] **Step 1: Implement recursive redaction**

Add `redactLogValue(value, route, key?)` and make `redactLogFields` recurse through arrays and plain objects. Replace complete values for sensitive keys matching tokens/secrets/authorization/passwords, access/PIN/door/gate codes, message/body/content, receipt/signed URLs and raw OCR/provider payloads. Convert `Error` objects to a redacted message string. Keep booleans, numbers and null unchanged except that numbers under sensitive keys are replaced.

- [x] **Step 2: Cover unstructured address and access-code strings**

Extend `redactForLog` with bounded address and access-code patterns. Keep replacements deterministic:

```text
[REDACTED_TOKEN]
[REDACTED_SIGNED_URL]
[REDACTED_EMAIL]
[REDACTED_PHONE]
[REDACTED_BANK_REFERENCE]
[REDACTED_ADDRESS]
[REDACTED_ACCESS_CODE]
[REDACTED_AMOUNT]
```

- [x] **Step 3: Implement the request wrapper**

Export:

```ts
export type ObservabilityOptions = {
  functionName: string;
  route: CascadeRoute;
  consoleTarget?: Pick<Console, 'log' | 'warn' | 'error' | 'info' | 'debug'>;
};

export function withObservability(
  options: ObservabilityOptions,
  handler: (request: Request) => Response | Promise<Response>,
): (request: Request) => Promise<Response>;
```

The optional console target exists only for deterministic dependency-injected tests; production callers omit it. The wrapper installs one redacted console per Edge isolate, copies a validated/generated correlation ID into the request passed to the handler, adds it to the response, appends it to CORS allow/expose headers, emits `<functionName>.request_completed` with `OK` or `HTTP_<status>`, and emits `<functionName>.request_failed` with `UNHANDLED_EXCEPTION` before rethrowing.

- [x] **Step 4: Run shared GREEN**

```powershell
deno test --no-lock supabase/functions/_shared/redaction.test.ts supabase/functions/_shared/observability.test.ts
```

Expected: all legacy and new shared tests pass.

### Task 3: Adopt the wrapper in every recovered function

**Files:**
- Modify: `supabase/functions/airbnb-email-sync/index.ts`
- Modify: `supabase/functions/daily-digest/index.ts`
- Modify: `supabase/functions/last-readings/index.ts`
- Modify: `supabase/functions/missed-cleaning-alert/index.ts`
- Modify: `supabase/functions/notify-cleaner-payment/index.ts`
- Modify: `supabase/functions/ocr-receipt/index.ts`
- Modify: `supabase/functions/rain-alert/index.ts`
- Modify: `supabase/functions/submit-cleaning/index.ts`
- Modify: `supabase/functions/telegram-expense/index.ts`
- Modify: `supabase/functions/turnover-verifier/index.ts`
- Modify: `supabase/functions/upload-photo/index.ts`
- Modify: `supabase/functions/weather-proxy/index.ts`

- [x] **Step 1: Import the wrapper in all 12 files**

Add exactly:

```ts
import { withObservability } from '../_shared/observability.ts';
```

- [x] **Step 2: Wrap each existing handler without refactoring its body**

Change only the `Deno.serve` boundary, using the exact slug/route pairs in the fixed scope table:

```ts
Deno.serve(withObservability({ functionName: 'airbnb-email-sync', route: 'ops' }, async (req: Request) => {
}));
```

The displayed empty body documents only the exact new prefix and closing delimiter; retain every statement currently between those delimiters byte-for-byte.

Apply the same exact syntax to each file with its own slug, route, and existing request parameter type. Do not change auth checks, data writes, Telegram text, response bodies, status codes, idempotency, provider calls, or background `waitUntil` behavior.

If a floating ungenerated Supabase client type collapses recovered query rows to `never`, use only the already approved Task 0.2a structural legacy-client type alias and casts. The compatibility annotation must emit no JavaScript and must not change a query, payload, provider call, or control-flow branch.

- [x] **Step 3: Run adoption and type checks**

```powershell
node --test tests/observability/edge-observability-adoption.test.mjs
deno check --no-lock --node-modules-dir=auto supabase/functions/airbnb-email-sync/index.ts supabase/functions/daily-digest/index.ts supabase/functions/last-readings/index.ts supabase/functions/missed-cleaning-alert/index.ts supabase/functions/notify-cleaner-payment/index.ts supabase/functions/ocr-receipt/index.ts supabase/functions/rain-alert/index.ts supabase/functions/submit-cleaning/index.ts supabase/functions/telegram-expense/index.ts supabase/functions/turnover-verifier/index.ts supabase/functions/upload-photo/index.ts supabase/functions/weather-proxy/index.ts
```

Expected: the manifest/adoption contract passes and every recovered entrypoint type-checks.

### Task 4: Replace prose-only degraded-mode assertions

**Files:**
- Create: `docs/architecture/degraded-mode-contract.json`
- Create: `supabase/functions/_shared/degraded-mode.ts`
- Create: `supabase/functions/_shared/degraded-mode.test.ts`
- Modify: `tests/resilience/degraded-modes.test.mjs`
- Modify: `docs/runbooks/degraded-operations.md`

- [x] **Step 1: Define five closed provider decisions**

The JSON contract must contain exactly `openrouter`, `n8n`, `gmail`, `chatwoot`, and `airbnb`. Every entry contains a fixed uppercase `reason_code`, `acknowledge`, `human_review`, `preserve_canonical_state`, `retry_policy`, `automatic_financial_decision`, and `action`.

Required decisions:

| Provider | Required action |
|---|---|
| OpenRouter | acknowledge, create human review, never fabricate OCR/chat output |
| n8n | retain the canonical outbox event, retry idempotently, never undo confirmation |
| Gmail | permit manual evidence review, never infer non-payment from absence |
| Chatwoot | stop automated replies after handoff and prevent webhook echo |
| Airbnb | preserve existing blocks and require manual review while feed health is stale |

- [x] **Step 2: Implement `degradedModeDecision`**

Return a defensive copy of the closed contract entry plus the caller's already validated correlation ID. Reject unknown providers instead of inventing a fallback.

- [x] **Step 3: Simulate every provider failure**

The Deno test calls the decision function for all five providers and verifies the exact action, correlation propagation, no automatic financial decision, human-review/retry behavior and canonical-state preservation. The Node test validates the same JSON schema, exact provider set and runbook coverage instead of testing prose fragments.

- [x] **Step 4: Run GREEN**

```powershell
deno test --no-lock supabase/functions/_shared/degraded-mode.test.ts
node --test tests/resilience/degraded-modes.test.mjs
```

### Task 5: Add an independent heartbeat-liveness target

**Files:**
- Create: `supabase/functions/job-heartbeat-liveness/logic.ts`
- Create: `supabase/functions/job-heartbeat-liveness/index.ts`
- Create: `supabase/functions/job-heartbeat-liveness/index.test.ts`
- Modify: `supabase/config.toml`
- Modify: `docs/architecture/edge-auth-manifest.json`
- Modify: `docs/runbooks/scheduler-recovery.md`

- [x] **Step 1: Test the liveness decision RED**

Use a fixed monitor name `job-heartbeat-monitor-every-15m` and a 30-minute maximum age. Assert:

```text
fresh row       -> HTTP 200 / reason MONITOR_HEALTHY
stale row       -> HTTP 503 / reason MONITOR_STALE
missing row     -> HTTP 503 / reason MONITOR_MISSING
database error  -> HTTP 503 / reason PROBE_UNAVAILABLE
```

No response contains timestamps, job errors, secrets, database details, or notification content.

- [x] **Step 2: Implement the signed read-only probe**

Allow only `GET` and `HEAD`, then require a constant-time match for `X-Cascade-Liveness-Secret` against a dedicated `CASCADE_LIVENESS_SHARED_SECRET` before querying the database. Query the one fixed heartbeat row with the server-side service-role client, evaluate it through the pure logic module, and return only `{ ok, reason_code }`; `HEAD` has no body. Wrap the handler with `withObservability({ functionName: 'job-heartbeat-liveness', route: 'internal' }, ...)`.

- [x] **Step 3: Declare its boundary**

Add `[functions.job-heartbeat-liveness] verify_jwt = false` to local configuration and a `signed` manifest entry whose controls state: dedicated constant-time liveness header, fixed read-only row, boolean/reason-only output, no caller-controlled query, no operational or personal data.

- [x] **Step 4: Document later Uptime Kuma activation**

Add an inactive production gate: after the function is deployed through a separate approved release, configure the existing VPS Uptime Kuma to request the endpoint every five minutes, require HTTP 200, and route downtime only to Finance/Admin. Do not configure or deploy it in this phase.

- [x] **Step 5: Run GREEN**

```powershell
deno test --no-lock --node-modules-dir=auto supabase/functions/job-heartbeat-liveness/index.test.ts
node scripts/audit/check-edge-auth.mjs
node --test tests/security/endpoint-boundaries.test.mjs
```

### Task 6: Wire verification, record evidence, and commit

**Files:**
- Modify: `package.json`
- Modify: `.github/workflows/cascade-ci.yml`
- Modify: `docs/plans/module-execution-queue.md`
- Modify: `docs/plans/HANDOFF-2026-08-30-sol-security-and-release-preflight.md`
- Create: `docs/validation/2026-08-31-wave-0-observability-adoption.md`

- [x] **Step 1: Add one deterministic platform-safety script**

Add `test:platform-safety` that runs the Node observability adoption, degraded-mode, endpoint-boundary, release-safety and recovery-contract tests. Use that script in CI, and include the new liveness Deno test in the Deno CI command.

- [x] **Step 2: Run the full Wave 0.11 matrix**

```powershell
npm.cmd run test:platform-safety
deno test --no-lock --node-modules-dir=auto supabase/functions/_shared/*.test.ts supabase/functions/job-heartbeat-monitor/index.test.ts supabase/functions/job-heartbeat-liveness/index.test.ts
deno check --no-lock --node-modules-dir=auto supabase/functions/airbnb-email-sync/index.ts supabase/functions/daily-digest/index.ts supabase/functions/last-readings/index.ts supabase/functions/missed-cleaning-alert/index.ts supabase/functions/notify-cleaner-payment/index.ts supabase/functions/ocr-receipt/index.ts supabase/functions/rain-alert/index.ts supabase/functions/submit-cleaning/index.ts supabase/functions/telegram-expense/index.ts supabase/functions/turnover-verifier/index.ts supabase/functions/upload-photo/index.ts supabase/functions/weather-proxy/index.ts supabase/functions/job-heartbeat-liveness/index.ts
node scripts/audit/scan-secrets.mjs
node scripts/audit/compare-supabase-production.mjs --check
node scripts/check-n8n-workflows.mjs
npm.cmd run recovery:supabase -- --output C:\Users\Lloyd\AppData\Local\Temp\cascade-wave0-observability-evidence.json
git diff --check
```

Expected: all tests/type checks pass, all 12 recovered functions are adopted, the new liveness function is reported local-only, all 13 n8n workflows remain inactive, 28/28 migrations and every database test file pass, the active local database identity is unchanged, and no production connection is used.

- [x] **Step 3: Record status without claiming deployment**

Mark Wave 0.11 complete locally. Retain these production gates: deploy the liveness function through a reviewed function release, configure Uptime Kuma separately, activate no n8n workflow, and do not reclassify any blocked recovered endpoint.

- [x] **Step 4: Commit atomically**

```powershell
git add .github/workflows/cascade-ci.yml package.json docs/architecture/degraded-mode-contract.json docs/architecture/edge-auth-manifest.json docs/architecture/edge-observability-manifest.json docs/plans/2026-08-31-wave-0-observability-adoption.md docs/plans/HANDOFF-2026-08-30-sol-security-and-release-preflight.md docs/plans/module-execution-queue.md docs/runbooks/degraded-operations.md docs/runbooks/scheduler-recovery.md docs/validation/2026-08-31-wave-0-observability-adoption.md supabase/config.toml supabase/functions/_shared/degraded-mode.ts supabase/functions/_shared/degraded-mode.test.ts supabase/functions/_shared/observability.ts supabase/functions/_shared/observability.test.ts supabase/functions/_shared/redaction.ts supabase/functions/_shared/redaction.test.ts supabase/functions/airbnb-email-sync/index.ts supabase/functions/daily-digest/index.ts supabase/functions/job-heartbeat-liveness/index.ts supabase/functions/job-heartbeat-liveness/index.test.ts supabase/functions/job-heartbeat-liveness/logic.ts supabase/functions/last-readings/index.ts supabase/functions/missed-cleaning-alert/index.ts supabase/functions/notify-cleaner-payment/index.ts supabase/functions/ocr-receipt/index.ts supabase/functions/rain-alert/index.ts supabase/functions/submit-cleaning/index.ts supabase/functions/telegram-expense/index.ts supabase/functions/turnover-verifier/index.ts supabase/functions/upload-photo/index.ts supabase/functions/weather-proxy/index.ts tests/observability/edge-observability-adoption.test.mjs tests/resilience/degraded-modes.test.mjs
git commit -m "feat(cascade): adopt privacy safe observability"
```

## Completion evidence

- Every recovered function is wrapped exactly once and still has its prior authority classification.
- Valid correlation IDs propagate request-to-response; invalid IDs never enter logs or responses.
- Existing console calls are redacted recursively at the isolate boundary.
- OPS logs cannot retain currency amounts; all routes redact contacts, addresses, access codes, tokens, bank references, receipt URLs and message bodies.
- All five provider outages produce deterministic non-destructive, human-review-safe decisions.
- The independent liveness endpoint reveals only health/reason state and remains local-only until a separately approved deployment and Uptime Kuma configuration.
- Full source, security, type-check and disposable-recovery evidence passes without production access or provider messages.
