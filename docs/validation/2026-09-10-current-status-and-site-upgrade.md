# Current production status and admin-site upgrade

**Verified:** 2026-09-10 08:21–08:28 UTC
**Scope:** read-only production inventory, admin-site release, P9/P10 source reconciliation

## Outcome

P0–P8 remain live and healthy. P9 has two narrowly approved active workflows: CH-S01 and CH-W04.
CH-W07 is imported and wired as the error workflow, but its Telegram action is disabled and it has
not been deliberately triggered. P10 remains open on the scheduler registration, the end of S01's
observation window, and Lloyd's signature.

## Production evidence

The Alfred container/API check reported:

- `cascade-n8n-app` and `cascade-n8n-postgres` healthy, zero restarts and no OOM state;
- resource ceilings still 1536 MiB / 1.5 CPU for n8n and 768 MiB / 0.75 CPU for PostgreSQL;
- 13 workflows, two active (CH-S01 and CH-W04), two credentials; CH-W07 inactive;
- loopback and shared `/healthz` endpoints both returned `status=ok`.

The aggregate-only production database check reported:

| Check | Result |
|---|---:|
| Public base tables / functions | 76 / 118 |
| Migration-ledger rows / non-filename versions | 86 / 0 |
| Active cron jobs | 8 |
| Enabled owner / admin / cleaner profiles | 1 / 2 / 1 |
| Verified MFA factors | 1 |
| Heartbeat rows / non-success rows | 2 / 0 |
| Pending / stuck-dispatched / stale-pending outbox rows | 0 / 0 / 0 |
| Failed or completed-without-delivery rows, last 24 h | 0 / 0 |
| S01 delivery rows / errors since activation | 2 / 0 |
| Unresolved turnover failures | 0 |
| Staff note column present | yes |

No row data, credential value, authentication identifier, or full backup checksum was printed or
recorded. The latest encrypted set, `cascade-supabase-20260910T061420Z`, is COMPLETE. The prior
`20260909T145049Z` set is the latest recorded 76/76-table restore proof.

## Admin-site release

The owning `admin-dashboard` repository was upgraded and released to GitHub Pages:

- corrected the Direct Booking card to the production booking site;
- removed server-value interpolation from staff-row inline handlers and delegated the actions;
- aligned the staff-note UI limit with the 500-character backend contract;
- added four focused regression tests, including Windows line-ending coverage.

Commits `95faff8` and `99e558a` are on `main`; Pages run `34454545253` succeeded. A live reload
confirmed the corrected link, 500-character note limit, delegated staff actions, and the published
booking target. The protected note save/reload smoke remains a Lloyd-operated check because the
agent must not receive or automate the owner's password or OTP.

## Recovery cadence and retirement

The obsolete local-Docker `scripts/recovery/backup-supabase-production.ps1` path was removed under
D-054. The Alfred backup now stores its snapshot's aggregate migration-ledger count, and the restore
checker can consume that count automatically. The Windows runner/installer and four contract tests
are present. Persistent registration was not performed: it requires explicit approval because the
recurring tasks access owner-only production credential files and write sensitive encrypted data to
`C:\Cascade-Backups`.

The calendar-sync v13 horizon guard was extracted into a pure classifier and covered by three Deno
tests: an in-feed UID is preserved, a missing row before the guard is reaped, a rolling-tail row is
skipped, and a missing/invalid feed horizon fails closed. All three tests and the Edge Function Deno
type-check pass. The function remains undeployed pending the separately approved restore proof.

## Remaining gates

1. At or after 2026-09-11 00:55 UTC, close the S01 observation with fresh read-only checks.
2. If clean, obtain exact approval before enabling W07 Telegram and triggering one controlled failure.
3. Obtain explicit approval before registering the weekly backup and monthly restore tasks.
4. Obtain explicit approval for the latest backup's sensitive-data restore proof before deploying calendar-sync v13.
5. Lloyd performs the protected staff-note save/reload check and confirms whether the 2026-09-07 cleaning occurred.
6. Lloyd signs P10 only after rows 1–8 are green.
