# Runbook — applying a release to production

One page. Every step is a command that already exists; nothing here is improvised.
Run from the waves repo root in Git Bash on the workstation, with
`CASCADE_SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe` exported (bare `ssh` inside a script
resolves to Git's agent-less binary and fails `Permission denied (publickey)`).

## 0. Preconditions (2 min)

- `date -u` — gates are defined in UTC; Manila local date leads by 16 h at midnight.
- `docker info` is **not** required. Backup, rehearsal and apply all run on Alfred.
- Alfred reachable: `ssh alfred hostname` → `alfred-brain`. It is a shared host (Alfred Money
  runs there); never leave a container, volume, network or temp dir behind.
- Owner MFA satisfied if the contract says `owner_mfa_required: true`.
- Lloyd's explicit go for this contract. Stop-hook prompts are not consent.

## 1. Validate the contract (10 s)

```bash
node scripts/migrations/verify-expand-contract.mjs --release supabase/releases/<contract>.release.json
```
Must print `{"ok":true,...}`. It checks every `migration_sha256` against the file and that
`source.commit` is an ancestor of HEAD.

## 2. Fresh backup (2 min)

```bash
bash scripts/recovery/p5/supabase-backup-over-alfred.sh
```
Produces `C:/Cascade-Backups/cascade-supabase-<UTC>Z/` with `COMPLETE`, `SHA256SUMS`,
`MANIFEST.txt`. The contract's `backup.restore_point` must be **newer than every schema change
already live**; an older set trips `restore point is older than the window`.

## 3. Restore proof (3 min)

```bash
bash scripts/recovery/p5/supabase-restore-check-on-alfred.sh "C:/Cascade-Backups/<set>" <expected-ledger-rows>
```
Passes only if the ledger count matches **and** restored tables == dump TOC (D-045). Runs on
the pgvector image; a bare image silently drops `kb_documents`.

## 4. Rehearse (2–3 min)

```bash
bash scripts/recovery/p6/migration-rehearsal-on-host.sh "C:/Cascade-Backups/<set>" supabase/releases/<contract>.release.json
```
Restores the set into a throwaway, network-internal container, applies the contract's
migrations in timestamp order, asserts every `forward_verification` query, removes everything.
Last line must be `cleanup leftovers ...: 0`.

## 5. Pre-state check, then apply (1 min)

```bash
bash scripts/migrations/apply-release-on-host.sh supabase/releases/<contract>.release.json --verify-only
bash scripts/migrations/apply-release-on-host.sh supabase/releases/<contract>.release.json
```
`--verify-only` should show the checks that the release is *about* to satisfy as FAIL — that is
the expected pre-state. The apply records each migration's ledger row **under its filename's
version** in the same transaction; it skips versions already present, so a retry after a
workstation-side failure is safe. This script passes the permission classifier; the Supabase
MCP and generic SQL runners do not — using them is what created the 2026-09-08 ledger drift.

## 6. Confirm independently (1 min)

- Ledger: `select version, name from supabase_migrations.schema_migrations order by version desc limit 5` — versions must equal the filenames.
- `get_advisors security` — nothing new above INFO except the release's own guarded RPCs.
- Re-run **every** authority check if the release replaces `staff_access_allowed` (D-038).

## 7. Record (5 min)

`02-DECISIONS` entry, `00-STATE` counts, `04-HANDOFF`, Knowledge OS event. Commit the contract,
migrations and evidence by explicit path (never `git add -A` — Task Master files are untracked
on purpose). Do not push without Lloyd's approval.

## If it goes wrong

- Workstation fork/SSH errors at high commit charge → close sessions, retry; the apply is idempotent.
- A rehearsal hang with no container on Alfred → check `/opt/cascade/.migration-rehearsal-*`
  and `docker ps -a`; kill the local script, `rm -rf` the remote temp dir, rerun.
- Forward check fails in production → follow the contract's `rollback.steps`; never improvise SQL.
