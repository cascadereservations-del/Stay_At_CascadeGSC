# Module A — lean re-cut (2026-09-08)

**Owner constraints (Lloyd, 2026-09-08):** zero added daily friction for the cleaner; sign-in is once per device with a persistent session; Honey is the real cleaner and gets a real account tied to the `cleaner` role for the one property; optimise, do not ceremonialise. Vault decision: D-031. Source contract: `supabase/releases/20260830_staff_cleaner_cutover.release.json`; superseded sequence: `2026-08-31-module-a-cutover-packet.md` Task 3.

## 1. Required for safety (closes the `upload-photo` hole and attributes writes)

| # | Change | Mechanism | Time |
|---|---|---|---|
| S1 | Private `cleaning-photos` bucket, 5 MB cap, JPEG/PNG/WebP only, all anon/public storage policies dropped | Migration `20260830002347` (bucket + policy block) | in the 4-migration apply |
| S2 | Attributed writes: `submitted_by_user_id` on `cleaning_sessions`, `meter_readings`, `inventory_usage`; anon insert on `inventory_usage` revoked; `cleaner`-role RLS | Migrations `20260828000200`, `000400`, `000500`, `20260830002347` — one unit, apply in order | ~2 min |
| S3 | Honey's identity: one Auth user (email + password, auto-confirmed) + `staff_access_profiles` row `role='cleaner'` + `staff_property_access` row for `6ae230f4-c189-4547-84b1-cb6e0b2cc9bd` (Cascade Bria) | Dashboard Auth → Add user; then SQL from the dashboard editor (database-owner session, same trust level the runbook already uses for `bootstrap_cascade_owner`) | ~5 min |
| S4 | Edge Functions `last-readings`, `upload-photo`, `submit-cleaning` at the auth-required versions (`requireStaffAccess`, signed URLs, `upsert:false`, size/MIME checks) | Supabase MCP `deploy_edge_function` from `supabase/functions/<slug>` + `_shared/staff-auth.ts` | ~5 min |
| S5 | Authenticated cleaner PWA published in the same hour | Merge `codex/named-cleaner-auth` (`f05d702`) into `main` of `CH-Cleaners-Checklist`; `static.yml` deploys Pages | ~5 min + build |
| S6 | Honey signs in once on her phone | See §4 | 1 min of her time |

**Hidden blast radius the packet missed — must be handled in the same window or the lockdown breaks live tools:**

- **Admin dashboard** (`cascade-admin-dashboard`): its two logins already exist in project Auth (`app_metadata.role` = `owner`, last sign-in 2026-07-02; `admin`, last sign-in 2026-08-12). After `000500` their reads of `cleaning_sessions`, `meter_readings`, `inventory_items` need staff rows. Fix in-window: `bootstrap_cascade_owner(<owner uuid>, array[<property>], 'Initial named Cascade owner')` for the `owner` user, plus a direct SQL `admin` profile + property row for the other. No TOTP is needed for `read_operations`/`manage_operations`/`manage_inventory`. The readiness refresh's "0 users" line was wrong; these two exist.
- **Inventory app** (`.research/CH_Inventory`, repo `CH_Inventory`): anon key, 17 `inventory_items` calls, 2 `inventory_usage`. `000200` revokes anon on `inventory_items`; it will stop working the moment migrations land. Options: (a) add the same one-time password sign-in (supabase-js `persistSession` default keeps it alive; ~40 lines) before the window, using the existing owner/admin accounts; (b) a time-boxed compatibility policy keeping anon read on `inventory_items` (write paths still break). Recommend (a), prepared before the window, published in it. Lloyd to confirm who uses it and where it is served.
- **Guest guide**: reads only `app_settings` + RPCs. Unaffected.

## 2. Proof and approval — batch into the same hour

| Step | What | Time |
|---|---|---|
| P1 | Fresh backup, one foreground run of `scripts/recovery/p5/supabase-backup-over-alfred.sh` with `CASCADE_SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe` (script proven 2026-09-07) | 3 min |
| P2 | Ledger check: live ledger still 61 and matches source; release verifier `ok: true` | 1 min |
| P3 | The contract's four forward-verification queries (staff schema, submitter column, bucket private, anon insert revoked) | 1 min |
| P4 | Hole-closure proof: anon `POST upload-photo` → 401; anon `GET storage/v1/object/public/cleaning-photos/...` → 400/404; Honey's session `GET last-readings` → 200; one test photo upload → signed URL; delete the test object | 5 min |
| P5 | Dashboard sanity: owner login still lists cleaning sessions and inventory | 2 min |
| P6 | Evidence commit `docs/validation/2026-09-XX-module-a-cutover.md` (timestamps, versions, pass/fail only) and D-031 executed note | 5 min |

Approval is one word from Lloyd before P1; everything after runs in sequence with a stop at the first mismatch. Rollback before any named write: hold the PWA merge and the three function versions; after writes: restore from the P1 set.

## 3. Drop or defer (does not reopen the hole)

| Item | Disposition | Why |
|---|---|---|
| Project-owner TOTP + fresh `aal2` session (packet Task 3 step 4) | **Defer** | Only `manage_staff`, `approve_payment`, `read_finance` require `aal2`. Nothing on Honey's path does. Cost of deferral: disabling/rotating Honey later is SQL by Lloyd instead of the `staff-access` RPC. Amend release JSON `approvals.owner_mfa_required` → `false` and drop the "owner session is not aal2" stop condition in the evidence commit. |
| `staff-access` Edge Function deploy | Defer with TOTP | Not called by the cleaner PWA. |
| Full denial matrix (disabled cleaner, stale session, other property) | Defer to the first second account | Already proven by 63 pgTAP locally; one anon 401 in P4 is the production proof that matters. |
| Live test of `submit-cleaning` in the window | Drop | It sends real Telegram/e-mail. Honey's first real turnover is the test; Lloyd watches the ops chat. |
| Packet Tasks 4 (heartbeat), 5 (n8n recovery), 6 (closeout) | Not Module A safety; separate approvals | Unchanged. |

## 4. How the session stays alive, and what Honey does once

**Supabase Auth facts (docs, 2026-09-08):** a session lasts indefinitely by default; the access token (JWT) expires after 1 hour; the refresh token never expires and is swapped for a new pair on each refresh. Time-box, inactivity timeout and single-session-per-user are Pro-plan features and are off on this Free project, so nothing can silently expire her. A used refresh token is accepted again within 10 s, and the parent of the active token always returns the active token, so a lost response on a bad signal does not end the session. The session ends only on sign-out, password change, or Lloyd revoking it.

**PWA behaviour (`cleaners-auth-sol/index.html`, `f05d702`):** sign-in is `POST /auth/v1/token?grant_type=password`; the pair is stored in `localStorage` (`AUTH_SESSION_KEY`). Every call goes through `requireStaffSession()`: if the access token has >60 s left it is used; otherwise the refresh token is exchanged and stored. The installed PWA (`display: standalone`, scope `/CH-Cleaners-Checklist/`) shares that `localStorage`, so the session survives closing the app, reboots and days between shifts. The cleaner-name dropdown (Honey/Marifel) stays as the display name; `submitted_by_user_id` is the attribution.

**One functional patch before publish (required by constraint 1):** `requireStaffSession()` clears the session on *any* refresh failure, including a network error. Opening the app offline more than an hour after the last refresh would show the login screen. Change it to clear only on an HTTP 400/401/403 from Auth and otherwise keep the stored session (the offline queue already retries submissions). ~6 lines; add it to the branch before the merge.

**Honey, once:** (1) open `https://cascadereservations-del.github.io/CH-Cleaners-Checklist/` on her phone; (2) Add to Home Screen / Install; (3) open the installed app; (4) type the e-mail and password Lloyd hands her in person; (5) tap Sign in. The gate hides and never shows again on that phone. A "Sign out" link exists top-right; tell her not to tap it. New phone = repeat steps 1–5.

## 5. Window checklist (≈60 min, Lloyd present for S3 and the two pushes)

1. Before the window (prep, no live change): patch the offline-refresh bug on `codex/named-cleaner-auth`; add sign-in to the Inventory app; confirm `cleaners-auth-sol` tests pass. Tell Honey: "From <date> the cleaning app will ask you to sign in once; I will give you the login in person."
2. P1 backup → P2 ledger → S2 migrations → P3 forward checks (stop on mismatch).
3. S3: Honey's user + cleaner rows; owner bootstrap + admin profile for the dashboard users.
4. S4 functions → S5 PWA merge (Lloyd's push approval) → Inventory app publish.
5. P4/P5 proofs → S6 Honey signs in (in person or by call) → P6 evidence commit → vault + status board updated.
