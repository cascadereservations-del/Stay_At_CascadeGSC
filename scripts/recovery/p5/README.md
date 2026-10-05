# Cascade production backup and restore proof

Two scripts. Both run from Git Bash on the workstation with
`CASCADE_SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe`; the heavy lifting happens in disposable
containers on the Docker host `alfred` (a **shared** host — leave nothing behind).

| Script | Does | Needs local Docker |
|---|---|---|
| `supabase-backup-over-alfred.sh` | `pg_dump` inside the pinned image on Alfred, streamed over SSH, **encrypted on the workstation** (`openssl aes-256-cbc`, PBKDF2 600k). Writes `C:/Cascade-Backups/cascade-supabase-<UTC>Z/` with `cascade-production.dump.enc`, `SHA256SUMS`, `MANIFEST.txt`, `COMPLETE`. | no |
| `supabase-restore-check-on-alfred.sh <set> [expected-ledger-rows]` | Decrypts locally, restores into a throwaway network-internal container on the `pgvector/pgvector:pg17` image, asserts ledger count **and** restored tables == dump TOC base tables (D-045), removes everything. The count defaults to the backup's `EXPECTED_LEDGER_ROWS` marker. | no |
| `guest-id-photos.mjs backup` | SPEC-40. Daily incremental, encrypted backup of the `guest-id-photos` bucket (the first run of a UTC month is a full set): one `openssl` file per object (same settings and passphrase file as the DB sets) into `C:/Cascade-Backups/guest-id-photos/gip-<UTC>-full` or `-incr`, mirrored as ciphertext to `alfred:/opt/cascade/backups/guest-id-photos/`, current + previous month kept. Then purges the photo objects the `guest_companions` trigger queued (7 days old, in the mirrored chain, max 20 per run, Storage API only). Heartbeat `guest-id-photos-backup`. Counts-only output. | no |
| `guest-id-photos.mjs drill` | Monthly, in memory: checksums, decrypts every object of the newest chain and compares sha256, coverage of the live bucket (`uncovered=0`), Alfred copy verified. Heartbeat `guest-id-photos-drill`. Pass line: `drill PASS chain=... decrypted_ok=N uncovered=0 mirror_ok=N`. | no |
| `guest-id-photos.mjs restore <outDir>` | Disaster only (Lloyd runs it). Decrypts the newest chain into a NEW folder (refuses an existing one, anything inside a repo, or OneDrive). Re-uploading to the bucket is a separate manual step. | no |

Secrets: `~/Cascade-Secrets/supabase-production-db-url.txt` and
`~/Cascade-Secrets/supabase-backup-passphrase.txt`. Never printed, never copied into the repo or
the vault; the DB URL reaches Alfred only as a root-only env file that a trap deletes.

## Approved cadence, pending explicit registration

`Invoke-CascadeRecoverySchedule.ps1` is the non-secret runner. `Install-CascadeRecoverySchedule.ps1`
registers a weekly Sunday 08:00 Manila backup and a first-Sunday 09:00 Manila restore drill. The
task principal uses Lloyd's interactive token and starts when available, so the workstation must be
on and Lloyd signed in. Registration is intentionally a separate approval because the recurring
tasks access owner-only production credentials and write sensitive encrypted backups.

The photo modes run through the same runner (`-Mode Photos`, `-Mode PhotosDrill`) inside a Git Bash login shell, so Git's
`openssl`, `tar` and `sha256sum` are on PATH. They need only the passphrase file: the service-role key is read into memory through the stored
Supabase CLI login (`npx supabase projects api-keys`) and is never written, logged or passed in an argument. The installer also registers
`Cascade Guest ID Photos Daily Backup` (08:20 Manila) and `Cascade Guest ID Photos Monthly Drill` (first Sunday 09:30). To decrypt one photo by hand:
`openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha512 -pass file:%USERPROFILE%\Cascade-Secrets\supabase-backup-passphrase.txt -in X.jpg.enc -out X.jpg`.

## Retired path

The pre-Alfred `scripts/recovery/backup-supabase-production.ps1` path was removed under P10
decision D-054 on 2026-09-10. It depended on the retired local Docker runtime and could leave an
incomplete backup set under Windows PowerShell 5.1. Its history remains available in Git; do not
restore or use it for current recovery work.

## Why the image matters

The Supabase schema has `kb_documents.embedding vector`. A bare `postgres` image has no
pgvector, so `pg_restore` silently skipped that table and every proof before 2026-09-09
reported one table short while passing. The TOC assertion exists so that can never pass again.
