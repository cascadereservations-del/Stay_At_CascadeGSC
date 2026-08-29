# Cascade handoff — 2026-08-29 Terra live audit and local release proof

## Resume location

- Worktree: `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`
- Branch: `codex/cascade-waves-0-1-sol`
- Starting HEAD for this uncommitted batch: `4707ac8`
- Canonical Supabase project: `qkgfhsdppslwunarczeq`
- Shared n8n folder: Personal → `Cascade Hideaway`

## Completed in this batch

- [x] Restored the in-app browser connection and audited Supabase, Portainer and n8n.
- [x] Confirmed Portainer uses the existing shared `deploy` n8n container and `n8nio/n8n:latest`; no isolated Cascade Docker stack was created.
- [x] Confirmed 14 Cascade n8n drafts and **zero published workflows**.
- [x] Identified duplicate W01 drafts and recorded why neither is publishable.
- [x] Confirmed the older W01 leaks payment/contact information into an OPS-bound message; it remains unpublished and blocked.
- [x] Added a reproducible local-only Supabase drift repair for missing `properties`, `meter_readings`, `inventory_items_pkey`, and `cleaning_sessions_pkey`.
- [x] Completed the staff-access Edge Function, MFA/local config, guarded management RPCs, normalized property scopes, append-only audit, and session revocation.
- [x] Added DB-backed operational authorization so JWT role/property claims cannot expand access and disabled staff lose access immediately.
- [x] Verified the W01 trigger function is trigger-only and cannot be executed by `anon`, `authenticated`, or `service_role`.
- [x] Applied one narrow live hotfix: `20260829044725_revoke_w01_dispatch_rpc_execution`.
- [x] Re-ran the live security advisor; the W01 finding is gone.
- [x] Updated the master gap review and Obsidian State/Decision records.

## Verification evidence

- Full Edge Function suite: **54 passed, 0 failed**.
- Static production/security/staff tests: **15 passed, 0 failed**.
- pgTAP database suites: **74 passed, 0 failed**:
  - notification route guard: 8
  - job heartbeats: 14
  - staff roles/sessions: 21
  - operational RLS: 24
  - W01 dispatcher: 7
- n8n source exports: **13 inactive graphs validated**.
- Edge authority manifest: **23 endpoints**, eight known unsafe recovered endpoints remain deployment-blocked.
- Secret scan: no high-confidence credential patterns.
- Production contract: 21 deployed functions = 12 recovered + 9 versioned; local-only `job-heartbeat-monitor` and `staff-access` recorded.

## Live state and explicit non-actions

- No n8n workflow was published, activated, renamed, archived or deleted.
- No real email, Telegram, WhatsApp or guest message was sent.
- No n8n/OAuth/API credential was created or entered.
- No scheduler/cron was activated.
- No isolated Docker stack was deployed.
- The route guard was subsequently deployed by SOL as production migration `20260829173700_notification_route_guard`; migrations `20260828000200` through `20260828000500` remain local-only.
- The production outbox and notification-route tables were empty during preflight.
- The three W01 Vault secret records exist; their values were never read or copied.
- The n8n in-app session expired after the read-only audit. Owner sign-in is required to resume UI cleanup.

## SOL-required next task group — stop Terra here

- [ ] Inspect consumers, grants and definitions for the three live advisor errors:
  - `public.v_status_desync_wide`
  - `public.v_direct_bookings`
  - `public.v_direct_state_desync`
- [ ] Decide whether each view can safely use `security_invoker = true`, needs narrower grants, or requires a compatibility replacement. Include rollback and consumer smoke tests.
- [ ] Review the coordinated production batch in source order:
  - `20260829173700_notification_route_guard.sql` (deployed and ledger-reconciled by SOL)
  - `20260828000200_operational_rls_lockdown.sql`
  - `20260828000300_job_heartbeats.sql`
  - `20260828000400_staff_roles_and_sessions.sql`
  - `20260828000500_db_backed_operational_authorization.sql`
  - `staff-access` and `job-heartbeat-monitor` Edge Functions
- [ ] Preserve the source-controlled migration versions. Do not use a connector path that invents new versions without reconciling the migration ledger.
- [ ] Replace/time-box the shared-code cleaner path, deploy with JWT verification, bootstrap the named owner from a DB-owner session, enroll MFA, issue a fresh session and verify stale-token denial.
- [ ] Run Supabase security/performance advisors and all tests again after the cutover.

## Owner/UI task group after SOL review

- [ ] Sign back into `https://n8n.rocloyd.com` in the in-app browser.
- [ ] Export both live W01 drafts before mutation.
- [ ] Rename the newer draft `CH-W01 Booking Requested — Routed Draft`.
- [ ] Rename the older unsafe draft `CH-W01 Booking Requested — Legacy OPS BLOCKED`.
- [ ] Verify/create dedicated credentials named `Cascade — <provider/purpose>`; never reuse Alfred/Alex credentials.
- [ ] Re-import/rebuild from source-controlled inactive exports and run graph checks.
- [ ] Obtain separate action-time approval before publishing or sending a test message.

## Remaining Wave 0 tasks

- [ ] Wave 0.8: disposable restore and backup/recovery proof.
- [ ] Wave 0.10: privacy schema enforcement after SOL review.
- [ ] Wave 0.11: adopt redaction/correlation across recovered functions.
- [ ] Wave 0.12: migration preflight, ledger reconciliation and expand/contract release tooling.
- [ ] Only after those gates, create Wave 1 atomic booking/payment packets.

## Durable references

- `docs/runbooks/n8n-live-baseline-2026-08-29.md`
- `docs/runbooks/staff-access-lifecycle.md`
- `supabase/scripts/repair_local_schema_drift.sql` — local Docker only
- `C:\Users\Lloyd\Claude\Projects\Cascade\docs\plans\2026-08-28-cascade-plan-gap-review.md`
- `D:\ObsidianVault\20-projects\cascade-hideaway\00-STATE-cascade.md`
- `D:\ObsidianVault\20-projects\cascade-hideaway\02-DECISIONS-cascade.md` (D-022)
