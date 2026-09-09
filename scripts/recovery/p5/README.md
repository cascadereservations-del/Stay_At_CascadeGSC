# Cascade production backup and restore proof

Two scripts. Both run from Git Bash on the workstation with
`CASCADE_SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe`; the heavy lifting happens in disposable
containers on the Docker host `alfred` (a **shared** host — leave nothing behind).

| Script | Does | Needs local Docker |
|---|---|---|
| `supabase-backup-over-alfred.sh` | `pg_dump` inside the pinned image on Alfred, streamed over SSH, **encrypted on the workstation** (`openssl aes-256-cbc`, PBKDF2 600k). Writes `C:/Cascade-Backups/cascade-supabase-<UTC>Z/` with `cascade-production.dump.enc`, `SHA256SUMS`, `MANIFEST.txt`, `COMPLETE`. | no |
| `supabase-restore-check-on-alfred.sh <set> <expected-ledger-rows>` | Decrypts locally, restores into a throwaway network-internal container on the `pgvector/pgvector:pg17` image, asserts ledger count **and** restored tables == dump TOC base tables (D-045), removes everything. | no |

Secrets: `~/Cascade-Secrets/supabase-production-db-url.txt` and
`~/Cascade-Secrets/supabase-backup-passphrase.txt`. Never printed, never copied into the repo or
the vault; the DB URL reaches Alfred only as a root-only env file that a trap deletes.

## Legacy — do not use

`scripts/recovery/backup-supabase-production.ps1` is the pre-Alfred path. It needs **local**
Docker and PowerShell 7 (`-Encoding utf8NoBOM`); under Windows PowerShell 5.1 it writes the
encrypted dump and then dies before `SHA256SUMS`/`COMPLETE`, leaving a set every other script
rejects. Kept for history only; retirement is P10 item 8.

## Why the image matters

The Supabase schema has `kb_documents.embedding vector`. A bare `postgres` image has no
pgvector, so `pg_restore` silently skipped that table and every proof before 2026-09-09
reported one table short while passing. The TOC assertion exists so that can never pass again.
