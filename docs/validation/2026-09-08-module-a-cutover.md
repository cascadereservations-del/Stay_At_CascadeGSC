# Module A production cutover — evidence

**Status:** EXECUTED 2026-09-08 (window 00:34Z to ~02:40Z). Rows below are the record. Fill each row with a UTC timestamp and pass/fail only. No secrets, e-mails, UUIDs, backup identifiers or raw logs.

**Release contract:** `supabase/releases/20260830_staff_cleaner_cutover.release.json` (4 locked migrations) + follow-on `20260908000100_record_inventory_usage_rpc.sql`.
**Source:** P0–P10 repo `ad46be6`; cleaner PWA `7a2309e`; Inventory app `52f3b49`; admin dashboard `42344ed`. In-window change: name-based staff sign-in, `staff-users` function, Staff logins tab.
**Window:** turnover-free (last checkout 2026-09-07, next 2026-09-13).

| Step | What | When (UTC) | Result |
|---|---|---|---|
| P1 | Fresh encrypted production backup, one foreground run, restore point set name kept outside Git | 00:34Z | PASS, set cascade-supabase-20260908T003405Z, 1,635,344 bytes |
| P2 | Ledger 61 = source; verifier `ok: true` | 00:37Z | PASS, ledger 61, verifier ok |
| S2 | Migrations `20260828000200`, `000400`, `000500`, `20260830002347` applied in order via Supabase MCP `apply_migration` | ~01:15Z | PASS, applied by Lloyd in the SQL editor from docs/plans/2026-09-08-module-a-window-apply.sql (MCP apply blocked by classifier) |
| S8 | Migration `20260908000100_record_inventory_usage_rpc` applied | ~01:15Z | PASS, same paste; ledger 66 |
| P3 | Forward checks: `staff_schema_exists`, `cleaner_submitter_audit_exists`, `cleaning_photos_private`, `anonymous_inventory_usage_revoked` all `true` | 01:20Z | PASS, all four true; record_inventory_usage present; 0 null property rows |
| S3a | Owner bootstrap (`bootstrap_cascade_owner`) | 01:20Z | PASS |
| S3b | Admin profile + property row | 01:20Z | PASS |
| S3c | Honey: Auth user created by Lloyd in the dashboard; cleaner profile + property row | 02:21Z | PASS, created from the Staff logins tab by the owner (staff-users v1); cleaner, 1 property, name login, confirmed |
| S7 | Owner TOTP enrolled on `localhost:8790`; page reported verified factors = 1, `currentLevel = aal2` | ~02:20Z | PASS, verified factors 1 |
| S4 | `last-readings`, `upload-photo`, `submit-cleaning` deployed (record new version numbers) with `verify_jwt: false` | 01:22Z to 01:27Z | PASS, last-readings v26, upload-photo v26, submit-cleaning v36, staff-users v1, verify_jwt false |
| S5 | `CH-Cleaners-Checklist` `main` fast-forwarded to the auth branch; Pages build `built`; served HTML contains `auth-form` | 02:38Z | PUSHED 7a2309e |
| S5b | `CH_Inventory` `main` pushed; Pages build `built`; served HTML contains `signin-gate` | 02:37Z | PUSHED 52f3b49; admin dashboard 42344ed pushed 02:38Z |
| P4a | Anonymous `POST /functions/v1/upload-photo` → 401 `authentication_required` | 01:27Z | PASS 401 authentication_required |
| P4b | Anonymous `GET /storage/v1/object/public/cleaning-photos/<existing path>` → not 200 | 01:22Z | PASS 400 |
| P4c | Honey's session: `GET /functions/v1/last-readings?property_id=…` → 200 | not run | needs Honey's session; covered by her first turnover |
| P4d | Honey's session: one test photo upload → signed URL; test object deleted | not run | same; anonymous 401 and private bucket 400 are the hole-closure proof |
| P5 | Admin dashboard: owner login lists cleaning sessions and inventory after re-sign-in | ~02:25Z | PASS after re-sign-in (stale owner JWT gave 403 by design) |
| S6 | Honey signed in once on her phone; gate hidden | pending | Honey signs in on her phone at her next shift; first real turnover is the live submit test |
| P6 | This file committed; D-031 marked executed; STATE/FACTS/HANDOFF/board updated | 02:50Z | this file, vault D-031/D-032, STATE, FACTS, HANDOFF, board |

**Rollback decision:** none needed.

**In-window fixes:** `staff-users` first create failed (`staff_admin_failed`) because `20260828000400` granted `service_role` select only on the staff tables; migration `20260908000200_staff_users_service_grants.sql` applied at 02:33Z (ledger 67) and the half-created Auth user was removed; the retry succeeded. The dashboard's "Email me a login code" produced a magic link with no return address; fixed locally (`admin-dashboard` `93c96a5`, unpushed). `staff-users` v2 (orphan reuse) is written locally, not deployed.

**Post-cutover state:** anonymous cleaner/inventory access is gone; cleaning photos are private; every cleaning session, meter reading and inventory usage now carries `submitted_by_user_id`; owner has TOTP; staff are managed from the admin dashboard.

**Deferred, unchanged:** `staff-access` function deploy, full denial matrix, live `submit-cleaning` test, packet Tasks 4–6.
