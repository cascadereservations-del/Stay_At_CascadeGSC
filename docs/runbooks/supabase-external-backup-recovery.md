# Supabase external logical backup and recovery candidate

**Status:** Candidate safety runbook. It is not yet approved as a substitute for a Supabase-managed restore point.

## Why this exists

The current Cascade Supabase Free plan has no scheduled backups or point-in-time recovery. The staff/cleaner cutover requires a fresh immutable recovery path, so this candidate uses an encrypted PostgreSQL logical dump outside the repository. It is designed to preserve the low-cost stack without weakening the cutover standard.

## Boundaries

- Do not run it until the owner approves the exact cutover window.
- Do not put database URLs, passwords, Age keys, dumps, backup IDs, user IDs, or raw output in Git, chat, screenshots, or shared n8n.
- The backup contains production personal and financial data. Store it only in an approved encrypted location controlled by Cascade.
- A successful dump is not a recovery proof. The backup becomes eligible for a production cutover only after a disposable restore verification succeeds and its pass/fail evidence is recorded without sensitive data.
- This runbook does not authorize production migration, Edge Function deployment, workflow activation, provider actions, or deletion.

## One-time prerequisites

1. Install PostgreSQL client tools (`pg_dump`, `pg_restore`) and `age` on the approved operator device.
2. Create an Age keypair in the approved secret manager. Keep the private identity out of the repository and out of the shared n8n runtime.
3. Choose an encrypted backup root outside any Git working tree and outside a synchronised public/shared folder.
4. Obtain the production Postgres connection URL through the approved Supabase administrative channel. Provide it only as the `CASCADE_PRODUCTION_DATABASE_URL` process environment variable for the current operator session.

## Create a candidate backup

From the repository root, with the connection URL set only in the current process environment:

```powershell
./scripts/recovery/backup-supabase-production.ps1 \
  -BackupRoot 'D:\Cascade-Backups' \
  -AgeRecipient 'age1...'
```

The script refuses to write under the repository. It produces an encrypted custom-format dump, a SHA-256 checksum file, and a non-secret manifest. It removes its temporary plaintext dump before returning.

## Prove restoration before a production cutover

Perform this only against a newly created disposable local/Postgres environment. Never restore over the Cascade production database.

1. Verify the checksum of `cascade-production.dump.age`.
2. Decrypt the archive to a temporary path using the private Age identity held by the approved operator.
3. Run `pg_restore --list` against the decrypted archive; it must finish successfully.
4. Restore into the empty disposable database with `pg_restore --clean --if-exists --no-owner --no-acl`.
5. Run only non-sensitive aggregate verification: table count, migration-ledger count, and application health queries. Do not export or attach restored records to evidence.
6. Destroy the disposable database and temporary plaintext archive through the environment's documented cleanup route.
7. Record the timestamp, backup checksum prefix, restore operator, disposable target, and pass/fail result in the production release evidence. Do not record a connection URL, passwords, the full checksum, data rows, or authentication identifiers.

## Approval decision

Before using this runbook to satisfy the staff/cleaner cutover backup gate, the owner must explicitly approve either:

1. a Supabase plan with a fresh provider restore point; or
2. this external backup method after a successful disposable restore proof and review of its evidence.

Until that decision and proof exist, the release remains blocked.
