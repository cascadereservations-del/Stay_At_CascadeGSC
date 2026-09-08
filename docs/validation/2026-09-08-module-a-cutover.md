# Module A production cutover — evidence

**Status:** NOT EXECUTED. Template prepared 2026-09-08 for the staffed window (D-031). Fill each row with a UTC timestamp and pass/fail only. No secrets, e-mails, UUIDs, backup identifiers or raw logs.

**Release contract:** `supabase/releases/20260830_staff_cleaner_cutover.release.json` (4 locked migrations) + follow-on `20260908000100_record_inventory_usage_rpc.sql`.
**Source:** P0–P10 repo `56a2a2d`; cleaner PWA `cleaners-auth-sol` `fffc5ce`; Inventory app `inventory` `e70878f`.
**Window:** turnover-free (last checkout 2026-09-07, next 2026-09-13).

| Step | What | When (UTC) | Result |
|---|---|---|---|
| P1 | Fresh encrypted production backup, one foreground run, restore point set name kept outside Git | | |
| P2 | Ledger 61 = source; verifier `ok: true` | | |
| S2 | Migrations `20260828000200`, `000400`, `000500`, `20260830002347` applied in order via Supabase MCP `apply_migration` | | |
| S8 | Migration `20260908000100_record_inventory_usage_rpc` applied | | |
| P3 | Forward checks: `staff_schema_exists`, `cleaner_submitter_audit_exists`, `cleaning_photos_private`, `anonymous_inventory_usage_revoked` all `true` | | |
| S3a | Owner bootstrap (`bootstrap_cascade_owner`) | | |
| S3b | Admin profile + property row | | |
| S3c | Honey: Auth user created by Lloyd in the dashboard; cleaner profile + property row | | |
| S7 | Owner TOTP enrolled on `localhost:8790`; page reported verified factors = 1, `currentLevel = aal2` | | |
| S4 | `last-readings`, `upload-photo`, `submit-cleaning` deployed (record new version numbers) with `verify_jwt: false` | | |
| S5 | `CH-Cleaners-Checklist` `main` fast-forwarded to the auth branch; Pages build `built`; served HTML contains `auth-form` | | |
| S5b | `CH_Inventory` `main` pushed; Pages build `built`; served HTML contains `signin-gate` | | |
| P4a | Anonymous `POST /functions/v1/upload-photo` → 401 `authentication_required` | | |
| P4b | Anonymous `GET /storage/v1/object/public/cleaning-photos/<existing path>` → not 200 | | |
| P4c | Honey's session: `GET /functions/v1/last-readings?property_id=…` → 200 | | |
| P4d | Honey's session: one test photo upload → signed URL; test object deleted | | |
| P5 | Admin dashboard: owner login lists cleaning sessions and inventory after re-sign-in | | |
| S6 | Honey signed in once on her phone; gate hidden | | |
| P6 | This file committed; D-031 marked executed; STATE/FACTS/HANDOFF/board updated | | |

**Rollback decision:** (none needed / restored from P1 set at …)

**Deferred, unchanged:** `staff-access` function deploy, full denial matrix, live `submit-cleaning` test, packet Tasks 4–6.
