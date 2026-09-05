# Module C local candidate validation — 2026-09-05

## Result

Module C is source-complete and Deno-verified as a local candidate. It is not deployed and is not production-ready. The database runtime suite remains an open environment gate.

## Authority boundary

- Payment evidence from receipt OCR, the pinned OpenRouter task profile, allowlisted bank email, or manual entry is advisory.
- Deterministic comparison records exact match, mismatch, ambiguity, missing fields, or duplicate evidence. It cannot approve a payment or booking.
- Only an authenticated named owner/admin/Finance user with a current AAL2 session and property scope can create a Finance review.
- A generic service role cannot create or edit a Finance review and cannot call the unreviewed booking transaction.
- The canonical booking decision now requires the immutable Finance review ID and verifies that its outcome authorizes the requested action.
- OPS roles cannot read payment evidence, comparisons, or Finance reviews.

## Candidate source

- `supabase/migrations/20260905010000_payment_evidence_finance_review.sql`
- `supabase/functions/_shared/payment-evidence.ts`
- `supabase/functions/approve-booking/index.ts`
- `supabase/functions/submit-booking/index.ts`
- `supabase/tests/database/payment_evidence_finance_review.sql`
- `tests/bookings/payment-evidence-adapters.test.mjs`
- `tests/bookings/payment-evidence-boundary.test.mjs`
- `tests/fixtures/payment-evidence/module-c-cases.json`

The synthetic pack covers matching, wrong-amount, duplicate, ambiguous, spoofed-looking, and missing-bank-message cases. It contains no production data.

## SOL review corrections

- The reviewed booking wrapper now re-reads the persisted decision after the serialized transaction and rejects any competing Finance review ID. This prevents a losing concurrent caller from reporting a review that was not stored.
- Direct `service_role` access to `booking_decisions` is revoked. Integrations can reach booking state only through the four-argument reviewed RPC and cannot fabricate or relink decision audit rows.
- Source and pgTAP regression assertions cover both boundaries.

## Fresh checks

| Check | Result |
| --- | --- |
| Focused Module B/C, booking/security, and handoff source tests | Pass: 27/27 |
| Platform safety | Pass: 37/37 |
| n8n workflow source graph | Pass: 13 inactive exports |
| Secret scan | Pass: no high-confidence credential pattern |
| TypeScript/JavaScript syntax checks | Pass |
| `git diff --check` | Pass |
| Module C pgTAP | Blocked: local Postgres at `127.0.0.1:54322` was not running |
| Deno type checks | Pass with Deno 2.9.5: shared adapter and `approve-booking` |
| Deno adapter runtime tests | Pass: 4/4 against synthetic fixtures |
| Full content suite | Pass: 36/36 |
| Browser suite | Incomplete: 38/54 passed; 16 navigation/locator timeouts occurred under the parallel run and the serial rerun was interrupted |

The pgTAP file contains 47 rollback-scoped assertions for table privacy, RPC and direct-table grants, evidence outcomes, named reviewer identity, AAL2 enforcement, OPS denial, manual review with missing bank evidence, final-review idempotency, and reviewed booking confirmation. The test command was attempted and returned connection refused. Docker was not started because the handoff prohibits Docker changes in this session.

The browser timeouts affect the repository-wide UI suite, not the Module C backend paths changed here. They remain recorded as an incomplete broad check rather than a passing result.

## Task ledger note

Task Master was located and its existing project initialization was repaired with the local CLI. The CLI still did not create `.taskmaster/tasks/tasks.json`, so manual task creation failed closed. The prepared architecture PRD was not transmitted to an external model and `tasks.json` was not hand-edited.

## Remaining release gates

1. Run the 47 pgTAP assertions in an approved local/disposable Supabase environment.
2. Re-run the repository browser suite serially in a stable browser environment before a broad release claim.
3. Perform the final release review against the resulting database runtime evidence.
4. Keep Module A recovery and coordinated production gates closed until their separate approvals and proofs exist.

No migration, Edge Function, provider, workflow, credential, message, or infrastructure change was made in production.
