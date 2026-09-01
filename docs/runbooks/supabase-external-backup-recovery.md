# Supabase external logical backup and recovery candidate

**Status:** Selected Free-plan recovery direction. It is not yet eligible as a production restore point until the owner approves a backup run and a disposable restore proof succeeds.

## Why this exists

The current Cascade Supabase Free plan has no scheduled backups or point-in-time recovery. The staff/cleaner cutover requires a fresh immutable recovery path, so this candidate uses an encrypted PostgreSQL logical dump outside the repository. It uses the already-present local `postgres:17` Docker image for `pg_dump`, `pg_restore`, and OpenSSL; no new backup software or image download is required.

## Boundaries

- Do not run it until the owner approves the exact cutover window.
- Do not put database URLs, passwords, backup passphrases, dumps, backup IDs, user IDs, or raw output in Git, chat, screenshots, or shared n8n.
- The backup contains production personal and financial data. Store it only in an approved encrypted location controlled by Cascade.
- A successful dump is not a recovery proof. The backup becomes eligible for a production cutover only after a disposable restore verification succeeds and its pass/fail evidence is recorded without sensitive data.
- This runbook does not authorize production migration, Edge Function deployment, workflow activation, provider actions, or deletion.

## One-time prerequisites

1. Confirm the existing local Docker image `postgres:17` is present. The backup script refuses to pull an image during a cutover.
2. Create a high-entropy backup passphrase file in the approved secret location, outside the repository and shared n8n runtime. The file must be readable only by the approved operator.
3. Choose an encrypted backup root outside any Git working tree and outside a synchronised public/shared folder.
4. Obtain the production Postgres connection URL through the approved Supabase administrative channel. Paste it only into an owner-only `ConnectionUrlFile` outside the repository; never into Git, chat, shell history, or a shared folder.

## Create a candidate backup

From the repository root, with the connection URL stored only in the owner-only local file:

```powershell
./scripts/recovery/backup-supabase-production.ps1 \
  -BackupRoot 'C:\Cascade-Backups' \
  -PassphraseFile 'C:\Users\Lloyd\Cascade-Secrets\supabase-backup-passphrase.txt' \
  -ConnectionUrlFile 'C:\Users\Lloyd\Cascade-Secrets\supabase-production-db-url.txt'
```

The script refuses to write under the repository, reads both secrets only from owner-only local files, uses the already-present `postgres:17` image with image pulls disabled, and produces an OpenSSL-encrypted custom-format dump, a SHA-256 checksum file, and a non-secret manifest. It removes its temporary plaintext dump and database-password file before returning.

## Prove restoration before a production cutover

Perform this only against a newly created disposable local/Postgres environment. Never restore over the Cascade production database.

1. Verify the checksum of `cascade-production.dump.enc`.
2. Decrypt the archive to a temporary path using the approved passphrase file. Do not place the passphrase in shell history, Git, chat, screenshots, or Docker command arguments.
3. Run `pg_restore --list` against the decrypted archive; it must finish successfully.
4. Restore into the empty disposable database with `pg_restore --clean --if-exists --no-owner --no-acl`.
5. Run only non-sensitive aggregate verification: table count, migration-ledger count, and application health queries. Do not export or attach restored records to evidence.
6. Destroy the disposable database and temporary plaintext archive through the environment's documented cleanup route.
7. Record the timestamp, backup checksum prefix, restore operator, disposable target, and pass/fail result in the production release evidence. Do not record a connection URL, passwords, the full checksum, data rows, or authentication identifiers.

## Approval decision

The owner selected the Free-plan path on 2026-09-01. Before using this runbook to satisfy the staff/cleaner cutover backup gate, the owner must still explicitly approve this external backup method at action time, then review a successful disposable restore proof. Until that proof exists, the release remains blocked.
