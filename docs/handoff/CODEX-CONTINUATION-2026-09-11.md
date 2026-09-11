# Cascade Hideaway — Codex continuation handoff

**Prepared:** 2026-09-11  
**Canonical worktree:** `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`  
**Working branch:** `codex/cascade-waves-0-1-sol` (pushed to `origin/main`)  
**Goal:** complete remaining Cascade phases without bypassing owner-only production controls.

This handoff supersedes stale P3-only status when it conflicts with the dated P9/P10 evidence.
Use the current repository, live checks, and release records as authority.

## Current outcome

- P0–P8 are live; P4 closed pass-with-exception and P5–P8 release evidence is recorded in the completion plan.
- The public direct-booking site was hardened and deployed. It uses a same-origin hero fallback, removes payment identifiers from public metadata/FAQ, avoids unsupported confirmation claims, and has browser/content coverage.
- The recovery-baseline CI path was repaired. It prepares a hash-bound schema-only baseline, skips production-managed scheduler state, excludes the irreversible ledger-backup cleanup, and omits only explicitly declared historical-data assertions from the disposable copy. Production migration sources and release hashes were not rewritten.
- CI run `34543502666` passed source/security, browser, and isolated Supabase database checks.
- Current P10 evidence includes the S01 n8n-plane observation: healthy Cascade containers with zero restart/OOM state, 13 workflows / 2 active / 2 credentials, and 276 CH-S01 executions since the observation boundary with zero non-success statuses.
- The P10 clarification immediately before this handoff is `5af91a2`; Pages run `34544329983` and Cascade CI run `34544329967` both passed.

## Recent commits

- `5af91a2` — clarify P10 signature dependency
- `b20ebb6` — record S01 n8n-plane observation
- `d1e88fe` — tolerate missing `pg_cron` in recovery pgTAP checks
- `6fbafbd` — omit live-data assertions only in the disposable recovery copy
- `3ce3fec` — exclude production ledger cleanup from recovery copy
- `630494d` — omit production scheduler state from recovery prerequisites
- `dadf52c` / `fcf7de1` — normalize recovery checksums and add prepared-baseline CI
- `5333691` / `67c2ebd` — public-site hardening and release record

## Start here in the next account

```powershell
$repo = 'C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol'
git -C $repo -c safe.directory=C:/Users/Lloyd/Claude/Projects/Cascade/direct-booking-waves-0-1-sol status --short
git -C $repo -c safe.directory=C:/Users/Lloyd/Claude/Projects/Cascade/direct-booking-waves-0-1-sol log -10 --oneline
gh run view 34544329967 --repo cascadereservations-del/Stay_At_CascadeGSC --json status,conclusion,url
```

Fresh local verification before the final documentation commits:

```powershell
npm.cmd run test:content
node --test tests/recovery/recovery-contract.test.mjs tests/production-contract.test.mjs
```

The first command passed 38 content/link/design contracts. The second passed 23 recovery and 5 production contracts. The hosted run above passed source/security, browser, and database checks.

## Remaining gates — do not infer approval

### 1. Close S01 delivery evidence

The n8n-side observation is complete, but it is not a substitute for production delivery evidence. With explicit owner authorization, run a **read-only, aggregate-only** production outbox/delivery-log check. Record only pending/stuck/stale outbox counts, failed or completed-without-delivery counts, and S01 delivery/error counts.

After a clean aggregate check, Lloyd must separately approve enabling W07's Telegram node and one controlled failure test. Do not combine the read-only check with that provider action. Export the reviewed workflow back to source and record evidence afterward.

### 2. Register recovery cadence

The decision is weekly Sunday 00:00 UTC (08:00 Manila) backup plus a first-Sunday restore drill. The source-controlled installer is `scripts/recovery/p5/Install-CascadeRecoverySchedule.ps1`. It creates two Lloyd-interactive Task Scheduler tasks and accesses owner-only credentials and encrypted backups under `C:\Cascade-Backups`.

Run it only after exact authorization, then verify task principals, triggers, and next-run times. See `scripts/recovery/p5/README.md`.

### 3. Restore proof and calendar-sync v13

The latest encrypted backup needs an explicitly authorized sensitive-data restore proof before deploying calendar-sync v13. Calendar deployment is a separate production release and needs observation on its next scheduled run. Do not print a connection string, secret, backup payload, or calendar row data. See `docs/plans/2026-09-09-p9-provider-activation-packet.md`.

### 4. Human-only acceptance

- Lloyd performs the protected staff-note save/reload smoke while signed in. Never request or automate a password or OTP.
- Lloyd confirms the 2026-09-07 cleaning status required by the current-status record.
- Lloyd signs P10 only after rows 1–8 are green and the live-state inventory is refreshed that day.

## Sources of truth

- `docs/plans/2026-09-09-p10-operational-acceptance-packet.md` — P10 row-by-row state
- `docs/validation/2026-09-11-s01-observation-n8n-check.md` — S01 evidence and limitation
- `docs/validation/2026-09-10-current-status-and-site-upgrade.md` — broader inventory and calendar gate
- `docs/plans/2026-09-09-p9-provider-activation-packet.md` — W07 and calendar boundary
- `docs/plans/2026-09-06-portainer-n8n-completion-plan.md` — long-form phase ledger
- `scripts/recovery/p5/README.md` and `scripts/recovery/p5/Install-CascadeRecoverySchedule.ps1` — recovery cadence

## Safety and workspace hygiene

- Do not create credentials, set edge/Vault secrets, activate workflows, send provider messages, deploy edge functions, schedule tasks, restore production data, or change production access without exact matching owner authorization.
- Do not enable W07 merely because its observation window elapsed.
- Keep production evidence aggregate-only. Never print secrets, connection strings, identity fields, workflow payloads, message bodies, or backup contents.
- Docker Desktop is not available locally. Use hosted CI or the documented Alfred disposable recovery procedure; do not repair/install Docker without separate software-install approval.
- Preserve unrelated user changes. Do not stage, modify, or clean:

```text
.gitignore
deno.lock
.env.example
.taskmaster/
AGENTS.md
docs/handoff/TASKMASTER.md
docs/plans/2026-09-08-module-a-window-apply.sql
scripts/taskmaster-codex.mjs
scripts/taskmaster-schema.mjs
tests/taskmaster/
```

## Recommended resume order

1. Confirm the commit and workspace hygiene.
2. Ask Lloyd for one exact authorization at a time, beginning with the read-only S01 production delivery/outbox aggregate.
3. If clean, seek the separate W07 controlled-failure approval.
4. Independently obtain approval for Task Scheduler registration, then verify created tasks.
5. Independently obtain authorization for restore proof, then for calendar-sync v13 deployment and observation.
6. Refresh P10 only with fresh evidence and seek Lloyd's signature after rows 1–8 are green.
