# Guide v9 secrets: SQL release package (s137, lane A), NOT APPLIED

Branch `s137/guide-v9-secrets`, worktree `D:\Claude\Projects\Cascade\s137-guide-secrets`, cut from stay-site origin/main `f60a7de`. Nothing was applied to production. Production was read only (read-only runner, no setting values selected).

## Files

| File | What |
|---|---|
| `supabase/migrations/20261207000000_guide_v9_secrets.sql` | The migration (no begin/commit: the runner wraps it). One table, three functions, one cron job. |
| `supabase/rollbacks/20261207_guide_v9_secrets.sql` | Compensating rollback with its own begin/commit. |
| `supabase/releases/20261207_guide_v9_secrets.release.json` | Release contract, phase `backfill` (the mint deletes expired rows; the runner refuses `DELETE FROM` in `expand`). 10 forward checks. `restore_point` and `verified_at` are placeholders. |
| `supabase/sql/2026-12-07-guide-v9-verify.sql` | The same 10 checks as one read-only script (10 rows, all `t`). Prints no setting value. |
| `supabase/tests/database/guide_v9_secrets.sql` | pgTAP suite, `plan(47)`. |
| `docs/s137/GUIDE-V9-SECRETS.md` | This file. |

Built on the guide session system that is already live (`guide_sessions`, `guide_token_thread_v1`). No second guest token or throttle table. The migration guard raises 55000 if guide v8, `verify_admin_pin` or `app_settings` is missing, or if `guide_staff_sessions` already exists.

## Contract for the front end

All three are called with the anon key (`supabase.rpc`), no other header. Tokens go in the argument, never in a URL.

### `guide_secrets_v1(p_token text) -> jsonb`

- Any null, empty, too short (< 32) or too long (> 128) token, any unknown token, any expired token: `{"ok": false}`. One answer, no reason, so a caller cannot tell a wrong token from an expired one.
- A live guest token (the one `guide_session_v1` returns as `token`) or a live staff token (below):
  `{"ok": true, "kind": "guest" | "staff", "wifi_ssid", "wifi_password", "onground_name", "onground_phone"}`.
  Values are strings; a setting that does not exist is JSON `null` (the key is still there). The front end must show "ask the host" for `null`, never an empty field.
- STABLE, writes nothing. Safe to call on every Wi-Fi card open; the guide should still cache the answer in memory for the visit and not in localStorage.
- A guest token stops working at the session's `expires_at` (end of checkout + 1 day, Manila). On `{"ok": false}` the guide must go back to its sign-in (`guide_session_v1`), not retry.

### `guide_staff_session_v1(p_code text, p_client text default null) -> jsonb`

Returns what `verify_admin_pin` returns, unchanged, plus extras on success:

| Answer | Meaning |
|---|---|
| `{"ok": false}` | Wrong, empty or null code. No token, no row. |
| `{"ok": false, "throttled": true}` | 8 wrong codes from this address in 15 minutes (verify_admin_pin's own rule). Even the right code is refused until the window passes. |
| `{"ok": true, "users": [...], "token": "<64 hex>", "expires_at": "<timestamptz>"}` | Right code. Token lives 12 hours. Keep it in memory (or sessionStorage), pass it to `guide_secrets_v1`. |
| `{"ok": true, "users": [...], "reason": "busy"}` | Right code but no token: 50 staff sessions are live, or the call waited more than 2 s for the lock. Treat "no `token`" as "not signed in" and offer a retry. |

`users` is what `verify_admin_pin` already returns to anyone who knows the PIN; this function does not change that. The guide should not render or store it.

The throttle key is the caller's address (`cf-connecting-ip`, else the rightmost `x-forwarded-for` entry, address-shaped only), exactly as `guide_session_v1` derives it. `p_client` is used only when no header is usable.

### `get_public_settings() -> jsonb`

One object holding only these ten keys (a key that is not set is left out): `wifi_ssid`, `house_times`, `min_nights`, `max_nights`, `review_airbnb_url`, `review_facebook_url`, `review_google_url`, `property_lat`, `property_lng`, `concierge_mode`. Values keep their stored types (`house_times` is an object, the nights and the coordinates are numbers). `wifi_password`, `onground_*`, `admin_pin_hash`, `users` and every other key are never returned. Adding a key means editing the function body and the forward check `public_settings_whitelist_only` together.

## Bounds (Free plan, 500 MB)

- `guide_staff_sessions`: never more than 50 rows. Rows are added only by a successful mint; the mint first deletes every expired row, then counts, then inserts, all under one advisory lock (`pg_advisory_xact_lock`), so the cap is exact. 50 rows of about 100 bytes plus the key index is a few kilobytes. The pgTAP suite loads 49 live and 30 expired rows, mints, and asserts exactly 50; the 51st mint answers `busy` and adds nothing; five more mints at the cap leave it at 50.
- The read functions write nothing. `guide_secrets_v1` is STABLE (asserted via `provolatile`) and the suite asserts no row appeared in `admin_auth_attempts`, `guide_sessions` or `guide_staff_sessions` after it ran.
- pg_net keeps its own response log for the cron job (one row per call, 144 calls a day); it trims that log itself (a few hours by default, from memory, not checked here).

## Weather warm-up

`weather-proxy-warm`, `*/10 * * * *`, `select net.http_get(url := '.../functions/v1/weather-proxy', timeout_milliseconds := 30000)`. Unscheduled by name first (idempotent). It sends no header, as the guide does. It is skipped where `cron.job` or the `net` schema is absent (a rehearsal copy).

What the function does (read in `direct-booking-waves-0-1-sol/supabase/functions/weather-proxy/index.ts`, v7, plus `place.ts` and `_shared/B_weather.ts`):

- Cache: one row `weather_proxy_cache` in `app_settings`, TTL 15 minutes (`CACHE_TTL_MS`), checked with `age < TTL`. A call inside the TTL does no upstream call. No quota or cap exists in the code beyond that cache.
- A refresh costs: 1 PirateWeather call (primary; Google Weather only if it fails, Open-Meteo after that) plus the extras: 1 Open-Meteo hourly call and 1 air-quality call (Google hourly only if Open-Meteo hours come back empty). So 3 upstream calls per refresh in the normal case.
- Calling every 10 minutes: a call 10 minutes after a refresh is a cache hit, the next (20 minutes after) is a refresh. That is a refresh every 20 minutes = 72 a day = 72 PirateWeather calls and 144 Open-Meteo calls a day (about 2,200 and 4,300 a month). The warm-up can never cause more than one refresh per 15 minutes, so the ceiling with guest traffic added is 96 a day (2,880 PirateWeather calls a month); guest visits reset the TTL, so they replace warm-up refreshes rather than add to them.
- Chosen over 5 minutes (same 72 refreshes, twice the invocations) and over 15 minutes (the cache age sits right at the TTL, so refreshes would land on 15 or 30 minutes at random). 10 minutes keeps data at most about 20 minutes old and the function called every 10 minutes.
- Provider limits are not in the repo. From memory, PirateWeather's free tier is 10,000 calls a month and Open-Meteo's free use is 10,000 a day; neither was checked today. 2,880 a month is under a third of the first.
- Measured today with no headers, from this PC: 200 in 3.76 s, then 0.58 s; after a 10 minute gap 200 in 2.49 s, then 0.62 s and 0.80 s. A 22 s cold start was not reproduced; a first call after a gap can also be a cache refresh (the data was 15+ minutes old), so these numbers do not separate a cold isolate from a refresh. Supabase's idle isolate lifetime is not stated in the repo; the 10 minute interval is a judgement, not a measured keep-alive.
- Precondition: the function must answer without headers. The guide already calls it that way and it answered 200 today, so `verify_jwt` must be false in production. If the dashboard setting were ever turned on, the warm-up and the guide would both get 401.

## Findings for the orchestrator (not changed here)

**F1. The secrets are still readable by anon through `app_settings`.** Read-only check, 2026-11-25: `app_settings` has RLS on, and the policy `anon select public` is a deny-list: it hides keys matching `%token%`, `%secret%`, `%pin_hash%`, `%ical%`, `%chat_id%` and the keys `email_recipients` and `users`. `wifi_password`, `onground_name` and `onground_phone` match none of those, and `anon` has table `SELECT`. So anyone with the public anon key can read the Wi-Fi password and the caretaker's phone with `GET /rest/v1/app_settings?key=eq.wifi_password` today. This release adds a token-gated path; it does not close that one. To make the secrets private: ship the v9 front end (it reads secrets only through `guide_secrets_v1`), confirm no other anon reader (staff app, other repos) uses those three keys, then add `wifi_password`, `onground_name`, `onground_phone` to the deny-list of `anon select public` (and the anon branch of `app_settings_staff_read`, which repeats it). Left out of this migration on purpose: it changes an existing policy that other readers share, which the brief did not ask for.

**F2. `verify_admin_pin` throttles only on the `p_client` string the caller sends.** Body read with `pg_get_functiondef` (read-only). It hashes `coalesce(p_client, 'unknown') || '|cascade-guide'` and refuses after 8 failed rows for that hash in 15 minutes. It does not look at request headers or at failures across callers, so a caller that sends a different `p_client` each time is never throttled and can guess the PIN at the speed of one bcrypt compare per call. It was not redesigned. `guide_staff_session_v1` closes this for its own door by keying on the header address (tested: 8 wrong codes with 8 different `p_client` values lock the address out). The existing direct callers of `verify_admin_pin` (the admin app) keep the old weakness. There is also no global failure cap, so a botnet with many addresses is not slowed either. It also returns the `users` list to anyone with the PIN, and is executable by anon.

## Apply steps for the orchestrator

Order: front end only after the SQL. Nothing here is automatic. Same runner as guide v8.

1. Gate: the owner's yes in chat to apply, and F1 decided (it is not part of this apply).
2. `git rev-parse --abbrev-ref HEAD` is `s137/guide-v9-secrets`, `git status --short` empty; `npm run test:release-safety`; `node scripts/migrations/verify-expand-contract.mjs --release supabase/releases/20261207_guide_v9_secrets.release.json`.
3. Fresh backup: `bash scripts/recovery/p5/supabase-backup-over-alfred.sh`, then stamp: `node scripts/migrations/fill-restore-point.mjs /c/Cascade-Backups supabase/releases/20261207_guide_v9_secrets.release.json`.
4. Rehearsal on the fresh set. A set taken now contains guide v8 and s136_followups, so the plain rehearsal is enough: `SET=$(ls -d /c/Cascade-Backups/cascade-supabase-* | sort | tail -1); CASCADE_REHEARSAL_PRE_SQL=supabase/releases/support/s136_pre_grants.sql bash scripts/recovery/p6/migration-rehearsal-on-host.sh $SET supabase/releases/20261207_guide_v9_secrets.release.json supabase/tests/database/guide_v9_secrets.sql` (forward checks 10 of 10, suite 47 of 47). Apply, rollback, re-apply was rehearsed in this lane with a temporary harness (below); that harness is not committed.
5. Apply: `bash scripts/migrations/apply-release-on-host.sh supabase/releases/20261207_guide_v9_secrets.release.json`.
6. Verify: `bash scripts/migrations/run-sql-on-host.sh supabase/sql/2026-12-07-guide-v9-verify.sql` must show 10 rows, all `t`.
7. Post-apply (read-only): `select jobname, schedule, active from cron.job where jobname = 'weather-proxy-warm'` (one row, `*/10 * * * *`, active). After about 10 minutes `select status_code, count(*) from net._http_response group by 1` shows 200s. One `curl` of the weather URL with no headers answers 200.
8. Drift check per the project CLAUDE.md is only needed if an edge function was deployed; this release deploys none.
9. Front end: v9 uses `guide_secrets_v1`, `guide_staff_session_v1`, `get_public_settings` as above. Then decide F1.

## Rollback

Revert the front end first, then `bash scripts/migrations/run-sql-on-host.sh supabase/rollbacks/20261207_guide_v9_secrets.sql`. It unschedules `weather-proxy-warm`, drops the three functions and `guide_staff_sessions`. Guide v8 and `verify_admin_pin` are untouched; staff tokens die with the table (staff sign in again), guest tokens are v8 sessions and keep working.

## Rehearsal evidence

Rehearsed on Alfred (not production) on the restored copy of backup `cascade-supabase-20261125T004039Z`. That backup predates guide v8 and s136_followups (237 ledger rows; production has 239), so both were applied first in the same container. A temporary harness (untracked migrations, deleted afterwards; it is a variation of the s136 `gen-rehearsal.mjs` pattern) ran: snapshot, apply v9, 10 forward checks, v9 fingerprint, rollback with checks (non-v9 fingerprint identical, so guide v8 is untouched), re-apply, 10 forward checks, fingerprint identical.

| Result | Value |
|---|---|
| migrations applied | 8, failed 0 (v8, followups, snapshot, v9, state1, rollback, re-apply, state2) |
| forward verification | 10 passed, 0 failed |
| pgTAP guide_v9_secrets | 47 of 47 |
| pgTAP guide_v8_messages_analytics / s136_followups | 172 of 172 / 41 of 41 |
| other 7 suites | fail exactly the numbers in `accepted_failing_tests` (acl kind, --no-acl copy) |
| baseline method | the same 9 suites run in a second container with only v8 + followups (no v9): the not-ok / error lines are identical (73 lines, `diff` empty), 20 `not ok` in both |
| cleanup leftovers | 0 (both runs) |
| logs | `.rehearsal-logs/rehearsal-guide_v9-post-full.log` (with v9), `...-pre-full.log` (without), `...-quick1.log` (v9 + v8 suite only), `...-mut-A..F.log` (git-ignored folder in the worktree) |

Exit code of the runner is 8 in both runs because of the accepted ACL baseline (same as every release since s134), not because of this lane.

Mutation check (every mutant edited the migration, was rehearsed, and was restored; migration sha256 unchanged after): A throttle key from `p_client` only fails 21, 22, 23. B cap 5000 fails 35 to 39. C whitelist plus `wifi_password` fails the forward check in the harness (the suite did not run for it). D staff expiry removed fails 30, 31. E expired rows not deleted fails 33, 34, 36 to 39. F Wi-Fi password read from the SSID key fails 14, 16, 28.

Not rehearsable on the copy: the `weather-proxy-warm` job (pg_cron and pg_net are absent there; the migration skips it with a notice and the check passes by its absent-cron branch). It is checked by the verify script and step 7 after the production apply.
