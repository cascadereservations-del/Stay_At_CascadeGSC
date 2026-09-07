# P5 gate 1 evidence — encrypted Supabase production backup and disposable restore proof

**Date:** 2026-09-07T23:07Z to 2026-09-07T23:15Z (2026-09-08 07:07–07:15 +08)
**Operator:** claude-code session on Lloyd's workstation, owner approval "go" given in chat after the SCRAM self-check confirmed the stored credential matched the `postgres` role.
**Scripts:** `scripts/recovery/p5/supabase-backup-over-alfred.sh`, `scripts/recovery/p5/supabase-restore-check-on-alfred.sh` (both at repo commit `afd011c`).
**Invocation:** foreground, `CASCADE_SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe`, `CASCADE_PW_MODE=literal`, Session-pooler connection (port 5432).

## Backup

| Item | Result |
| --- | --- |
| Backup set | `C:\Cascade-Backups\cascade-supabase-20260907T230736Z` |
| Format | `pg_dump --format=custom --no-owner --no-acl`, postgres 17.11 client in the pinned image on Alfred |
| Encryption | OpenSSL AES-256-CBC, PBKDF2 SHA-512, 600 000 iterations, owner-only passphrase file on the workstation |
| Ciphertext size | 1 631 840 bytes |
| SHA-256 prefix | `1770b30ce68100e9` |
| Plaintext on disk | none (streamed over SSH, encrypted on arrival) |
| Remote temp cleanup | trap removed `/opt/cascade/.supabase-backup-*` |
| Exit | 0, `COMPLETE` marker written |

## Restore proof

| Check | Result |
| --- | --- |
| Ciphertext checksum | verified |
| TOC entries | 848 |
| Restore error lines | 85, all in the expected classes for a non-Supabase host: 60 missing roles, 14 missing relations, 8 missing/unavailable extensions, 2 missing schemas, 1 missing type |
| Public base tables | 40 |
| Public functions | 69 |
| Migration ledger rows | 61 (expected 61) |
| Container / volume / network / temp dir leftovers | 0 |
| Exit | 0 — `Disposable Supabase restore passed` |

## Gate 2 cross-check (read-only, same day)

Live ledger = 61 versions, every one present as a local migration file; 18 local files are unledgered (the live-but-unledgered `20260824045800_dispatch_w01_to_n8n` plus the Module A and Module B–E release candidates). Nothing in the ledger is missing locally.

## Attempts that preceded this pass

Five failed logins (2026-09-06 to 2026-09-07) across both hosts and both decode modes were all one fault: the value in the workstation secrets file never matched the `postgres` role. Proven offline on 2026-09-08 with a SCRAM-SHA-256 self-check run by the owner in the Supabase SQL editor (`false` for the old value), then fixed by copying the reset dialog's generated value with its Copy button. Two additional same-day failures were SSH-binary selection inside the script, not Supabase (see vault lesson 2026-09-07-an-interactive-alias-is-not-the-binary-a-script-gets).

## Decision after gate 1

Module A migrations (`20260828000200`, `20260828000400`, `20260828000500`, `20260830002347`) were **not** applied. The release contract `supabase/releases/20260830_staff_cleaner_cutover.release.json` declares `old_reader: false, old_writer: false` and stop conditions requiring an owner `aal2` session, a proven real cleaner account and property assignment, and backend + PWA deployment in the same staffed window. None of those are satisfied yet; applying the migrations alone would break the live anonymous cleaner flow (`cleaning-photos` bucket private, anonymous `inventory_usage` insert revoked). Release verifier `verify-expand-contract.mjs` reports `ok: true` for the four locked hashes at this commit.

No secrets, backup passphrases, user identifiers or raw logs are recorded here.
