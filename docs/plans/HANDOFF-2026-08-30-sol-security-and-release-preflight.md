# Cascade handoff — 2026-08-30 SOL security and release preflight

## Resume location

- Worktree: `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`
- Branch: `codex/cascade-waves-0-1-sol`
- Starting commit for this batch: `492aa39`
- Supabase project: `qkgfhsdppslwunarczeq`
- Approved automation runtime: existing Portainer n8n, Personal → `Cascade Hideaway`

## Production changes completed

- [x] `20260829173431_harden_sensitive_monitor_views`
  - `v_direct_bookings`, `v_direct_state_desync`, and `v_status_desync_wide` now use `security_invoker=true`.
  - `anon` and `authenticated` cannot select; `service_role` retains select.
  - Repo-wide search and recent API logs found no client consumers.
  - The three security-definer-view advisor errors are cleared.
- [x] `20260829173700_notification_route_guard`
  - Adds closed route/template contracts and rejects financial keys/text from OPS payloads.
  - Live preflight found zero outbox rows, zero notification routes, and zero incompatible values.
  - Live verification confirmed both columns, both principal constraints, safe OPS acceptance, financial detection, and no anonymous helper execution.
- [x] `20260829174048_revoke_direct_booking_trigger_rpc_execution`
  - `fn_direct_booking_cascade()` remains attached to one trigger.
  - `anon`, `authenticated`, and `service_role` can no longer call it as an RPC.
  - The related advisor warning is cleared.

## Verification

- Sensitive monitoring views: 12/12 local pgTAP assertions passed.
- Notification route guard: 8/8 local pgTAP assertions passed immediately before deployment.
- Direct-booking trigger permissions: 4/4 local pgTAP assertions passed.
- Production migration ledger versions were read back and local filenames reconciled exactly.
- Post-deploy security advisors were rerun after each permission change.
- No guest, Telegram, email, bank, or social message was sent.
- No n8n workflow or scheduler was activated.
- No credential or secret value was read, copied, or entered.

## Deliberate production blockers

### Staff/RLS cutover — do not deploy yet

- The named Cascade owner email exists in Supabase Auth, but there are **zero verified MFA factors**.
- `20260828000200_operational_rls_lockdown`, `20260828000400_staff_roles_and_sessions`, and `20260828000500_db_backed_operational_authorization` must remain a coordinated cutover.
- Before deployment: enroll owner TOTP MFA, prove an `aal2` session, define/time-box the cleaner compatibility path, then bootstrap the owner from a DB-owner session and verify stale-token denial.

### Named cleaner cutover release candidate — complete locally

- Cleaner PWA branch/worktree: `codex/named-cleaner-auth` / `cleaners-auth-sol`.
- Backend branch/worktree: `codex/cascade-waves-0-1-sol` / `direct-booking-waves-0-1-sol`.
- The PWA blocks startup until an owner-provisioned Supabase Auth user signs in, refreshes the session, attaches the user JWT to private calls and supports sign-out. There is no public sign-up.
- `last-readings` requires property-scoped `read_operations`. `upload-photo` uses a server-chosen property/user/submission path in a private bucket. `submit-cleaning` verifies the named user, property and every photo path and records submitter IDs.
- Cleaner-entered expenses create `pending_review` rows in `cleaning_expense_claims`; they no longer create confirmed ledger transactions. Amounts are removed from the GAS operational payload and remain Finance-only.
- The database packet closes anonymous inventory/photo access and prevents direct RLS writes from spoofing another submitter.
- Verification: 63/63 pgTAP assertions, 3/3 backend boundary tests, 2/2 shared-auth Deno tests, Edge Function type-check, 5/5 PWA tests, and the 23-endpoint auth manifest audit pass.
- Production remains blocked: the live owner has zero verified MFA factors, and a real cleaner Auth user/property assignment plus a coordinated smoke window have not been proven. The three functions therefore remain `migration_blocked` in the live manifest.
- Fresh read-only preflight after the commits confirmed: `verified_mfa_factor_count=0`, `staff_profiles_deployed=false`, and `required_scheduler_secret_count=0`. No production mutation followed.

### Heartbeat scheduler — do not activate yet

- `cascade_supabase_url` and `cascade_cron_shared_secret` are absent from Vault.
- `job-heartbeat-monitor` is local-only; its custom shared-secret authentication is intentional, so deployment uses `verify_jwt=false` only after the secret is configured.
- One existing Cascade scheduler job is present, but its command/secret content was not read. Do not replace it until it is safely inventoried and rollback is documented.
- `20260828000300_job_heartbeats` remains local-only until the Vault and Edge Function preconditions are satisfied.

## Advisor disposition

- Remaining public SECURITY DEFINER RPC warnings are not safe for blanket revocation:
  - `verify_booking` and `verify_admin_pin` are used by the guest guide.
  - `get_usage_medians` is used by CH Inventory.
  - `get_welcome_info` needs a consumer/contract review before any change.
- Remaining search-path warnings (`apply_inventory_purchase`, `match_inventory_item`), public `pg_trgm`, RLS-with-no-policy INFO findings, and leaked-password protection require separate tested packets. Do not mix them into the staff cutover.

## Next executable task group

1. Have the owner enroll Supabase TOTP MFA and sign in again to obtain an `aal2` session.
2. Create the real cleaner Auth account, then assign `cleaner` plus the Cascade property from an MFA-proven owner session.
3. Capture a fresh production preflight and rollback snapshot; deploy staff/RLS, the named-cleaner migration and the three JWT functions as one backend packet.
4. Immediately deploy the authenticated PWA and prove sign-in, property-scoped inventory, photo upload, meter lookup, report submission, pending expense claim, sign-out and disabled/stale-session denial.
5. Configure the two Cascade scheduler secrets without exposing values; keep schedules and all n8n workflows inactive until their separate activation review.
6. Only after those proofs, close the production cutover and move to the next Wave 0 packet.

## Current invariant

OPS receives operational/staff information only. Payment totals, payment status, receipts, bank data, prices, rates, deposits, refunds, fees, ledger fields, and guest contact details must never enter OPS payloads.
