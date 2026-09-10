# Supabase external logical backup and recovery

**Status:** Production-proven on Alfred. Use only the scripts under `scripts/recovery/p5/`; the retired local-Docker PowerShell path was removed under P10 decision D-054.

## Why this exists

The Cascade Supabase Free plan has no scheduled backups or point-in-time recovery. This path runs
`pg_dump` and disposable `pg_restore` containers on Alfred, streams the dump over SSH, and encrypts
it on the workstation. The production database URL and backup passphrase remain in owner-only
workstation files and never enter Git or Alfred's persistent storage.

## Boundaries

- Do not run it until the owner approves the exact cutover window.
- Do not put database URLs, passwords, backup passphrases, dumps, backup IDs, user IDs, or raw output in Git, chat, screenshots, or shared n8n.
- The backup contains production personal and financial data. Store it only in an approved encrypted location controlled by Cascade.
- A successful dump is not a recovery proof. The backup becomes eligible for a production cutover only after a disposable restore verification succeeds and its pass/fail evidence is recorded without sensitive data.
- This runbook does not authorize production migration, Edge Function deployment, workflow activation, provider actions, or deletion.

## One-time prerequisites

1. Confirm Alfred has the pinned PostgreSQL and pgvector restore images used by the scripts. The scripts refuse to substitute an unreviewed image.
2. Create a high-entropy backup passphrase file in the approved secret location, outside the repository and shared n8n runtime. The file must be readable only by the approved operator.
3. Choose an encrypted backup root outside any Git working tree and outside a synchronised public/shared folder.
4. Obtain the production Postgres connection URL through the approved Supabase administrative channel. Paste it only into an owner-only `ConnectionUrlFile` outside the repository; never into Git, chat, shell history, or a shared folder.

## Create a candidate backup

From Git Bash in the repository root, with the connection URL stored only in the owner-only local file:

```bash
export CASCADE_SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe
export CASCADE_SUPABASE_URL_FILE=/c/Users/Lloyd/Cascade-Secrets/supabase-production-db-url.txt
export CASCADE_BACKUP_PASSPHRASE_FILE=/c/Users/Lloyd/Cascade-Secrets/supabase-backup-passphrase.txt
export CASCADE_BACKUP_DIR=/c/Cascade-Backups
scripts/recovery/p5/supabase-backup-over-alfred.sh
```

The script refuses to write under the repository, reads both secrets only from owner-only local files, and produces an OpenSSL-encrypted custom-format dump, a SHA-256 checksum file, a non-secret manifest, and a `COMPLETE` marker. Plaintext and the temporary root-only Alfred environment file are removed by traps.

## Prove restoration before a production cutover

Perform this only through the isolated Alfred checker. Never restore over the Cascade production database.

```bash
scripts/recovery/p5/supabase-restore-check-on-alfred.sh \
  /c/Cascade-Backups/cascade-supabase-<UTC>Z \
  <expected-ledger-rows>
```

The checker verifies ciphertext integrity and dump structure, restores into uniquely named
network-internal disposable resources on the pinned pgvector image, checks the migration ledger
and that restored base-table count matches the dump TOC, then removes the container, network,
volume, and plaintext automatically. Record only non-sensitive aggregate evidence.

## Approval decision

The owner selected and proved this Free-plan path in September 2026. A fresh production backup is
still mandatory before every apply, and the approved operating cadence is weekly Sunday 00:00 UTC;
restore drills run monthly and after every pre-apply backup. Each production apply keeps its own
action-time approval and named restore point. The source-controlled Windows Task Scheduler wrapper
is `scripts/recovery/p5/Install-CascadeRecoverySchedule.ps1`; do not register it without explicit
approval because it grants recurring access to the owner-only connection URL and passphrase files.
