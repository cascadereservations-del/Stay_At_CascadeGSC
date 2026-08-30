# Wave 0.10 privacy enforcement verification

**Verified:** 2026-08-31 Asia/Manila / 2026-08-30 UTC

**Mode:** local and disposable Supabase only; no production connection, deployment, data deletion, anonymization or provider message

## Verdict

**Local release candidate: PASS.** Migration `20260831010000_privacy_requests_and_holds.sql` adds private, property-scoped request/hold/audit storage and guarded lifecycle RPCs. Only an active, non-revoked owner/admin session at AAL2 can enter the RPCs; admins remain restricted to assigned properties. Finance, anonymous, service-role impersonation, disabled staff and poisoned JWT role metadata do not expand access.

## Contract

- Requests cover `access`, `correction` and `deletion`.
- Holds cover legal, dispute, chargeback, safety, tax/accounting and unresolved-payment cases.
- Direct table privileges are revoked from `public`, `anon`, `authenticated` and `service_role`; authenticated users can only enter the three security-definer RPCs.
- Request and hold transitions lock the target row and append an audit record in the same transaction.
- An active matching hold blocks deletion approval/completion and blocks review resumption.
- Releasing a hold never silently resumes or completes a request.
- No function deletes or anonymizes guest, financial, operational, safety or audit records.

## Verification evidence

| Check | Result |
|---|---|
| Initial focused pgTAP run | RED: required privacy relations/RPCs absent |
| Focused privacy pgTAP after migration | 49/49 pass |
| Disposable Supabase recovery | 28/28 migrations applied; 15/15 database test files pass |
| Disposable evidence timestamp | `2026-08-30T17:36:34.602Z` |
| Active local database identity | unchanged |
| Production connection | not used |
| Disposable cleanup | no `cascade-recovery-` containers or volumes remain |
| Recovery contract | 12/12 pass |
| Release safety | 17/17 pass |
| Privacy release preflight | pass; one required migration present in local ledger |
| Endpoint boundary tests | 3/3 pass |
| Source inventory | 21 deployed functions = 12 recovered + 9 versioned |
| Secret scan / diff check | pass |

Release contract `20260831_privacy_enforcement.release.json` binds the normalized migration SHA-256, read-only forward checks, compensating actions and production stop conditions.

## Production gates

- Obtain a current Philippine privacy/retention review before activation; existing documentation is operational guidance, not legal certification.
- Enroll and prove owner/admin AAL2 MFA through the coordinated staff cutover.
- Capture a fresh immutable production restore point during an approved maintenance window.
- Run a staffed smoke test for property isolation, disabled/revoked-session denial, request transitions, active-hold blocking and audit persistence.
- Keep privacy RPC production access off until every release-contract stop condition clears.

Wave 0.10 privacy enforcement is complete locally and remains intentionally undeployed.
