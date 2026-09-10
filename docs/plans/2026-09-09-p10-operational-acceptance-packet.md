# P10 operational-acceptance packet

**Prepared:** 2026-09-09 UTC · **Refreshed:** 2026-09-10 UTC · **Status:** rows 2–4 and Lloyd's signature remain open
**Parent:** `2026-09-06-portainer-n8n-completion-plan.md` §P10 — "The new plane is supportable and the old Cascade path is safely retired."

P10 is a checklist with evidence, not a release. Each row below is either **done** (with the
evidence file), **staged** (agent can finish without approval), or **Lloyd** (needs a decision,
a credential, or a signature).

## 1. Live-state inventory (read 2026-09-10 08:28 UTC, production `qkgfhsdppslwunarczeq`)

| Item | Value |
|---|---|
| Public base tables | 76 |
| Public functions | 118 |
| Migration ledger rows | 86; 0 non-filename versions |
| pg_cron jobs | 8 active |
| Staff access profiles (enabled) | owner 1 · admin 2 · cleaner 1 |
| Verified MFA factors | 1 (owner) |
| `job_heartbeats` rows | 2; 0 non-success rows |
| `automation_outbox` pending | 0 |
| Delivery health | 0 stuck dispatched, 0 stale pending, 0 failures or completed-without-delivery in the last 24 hours, 0 S01 delivery errors |
| Turnover failures | 0 unresolved |
| Staff note schema | `staff_access_profiles.note` present |
| n8n plane | Both containers healthy with 0 restarts/OOM; 13 workflows, **2 active** (S01/W04), 2 credentials; W07 inactive |
| Latest backup set | `cascade-supabase-20260910T061420Z`, encrypted and COMPLETE; the prior `20260909T145049Z` set is restore-proved 76/76 |

## 2. Acceptance items

| # | Item | State | Evidence / what remains |
|---|---|---|---|
| 1 | **Access review** | **DONE 2026-09-10 (D-054/D-059)** | Two admin profiles stand; cleaner selector is Honey + Other; staff note is live end-to-end. The protected save/reload human smoke remains an operational check, not an access-policy decision. |
| 2 | **Backup schedule** | **DECIDED; REGISTRATION HELD** | Weekly Sunday 00:00 UTC + always before an apply. Source-controlled Task Scheduler wrapper and contract tests are ready. Persistent registration needs explicit Lloyd approval because the task repeatedly accesses owner-only production credentials and writes sensitive backups to `C:\Cascade-Backups`. |
| 3 | **Restore drill cadence** | **DECIDED; REGISTRATION HELD** | Monthly first Sunday + after every pre-apply backup. New backups carry `EXPECTED_LEDGER_ROWS`; the restore checker can consume it automatically. Persistent registration has the same explicit-approval gate as row 2. |
| 4 | **Alerts** | **IN OBSERVATION** | S01 and W04 are live and clean. S01's 24-hour window closes 2026-09-11 00:55 UTC; W07 remains disabled pending a clean close and exact approval. |
| 5 | **Incident ownership** | **DONE 2026-09-10 (D-054)** | Lloyd = owner/on-call; Finance route = Lloyd and Marifel; OPS route = Honey for turnover only. |
| 6 | **Runbooks** | done | `docs/runbooks/production-apply.md`, `docs/runbooks/heartbeat-stale.md`, `scripts/recovery/p5/README.md`, plus privacy request/breach (`docs/privacy/`) and the P1–P4 recovery packets. |
| 7 | **Final authority inventory** | done | `docs/architecture/edge-auth-manifest.json` (26 entries) + `staff_access_allowed` matrix verified live 2026-09-09 (D-046). |
| 8 | **Old path retirement** | **DONE 2026-09-10 (D-054)** | Removed legacy `scripts/recovery/backup-supabase-production.ps1`; the runbook now names only the Alfred path. Cloudflare Worker and GAS relays remain exactly as decided. Git retains the retired script's history. |
| 9 | **Signed acceptance** | Lloyd — ONLY ROW LEFT | When 1–8 are green: dated signature in `02-DECISIONS` plus this inventory refreshed the same day. |

## 3. Agent-completable next steps (no approval needed)

1. ~~Runbooks and retirement~~ done. 2. ~~Ledger reconciliation~~ clean at 86 rows.
3. With explicit Lloyd approval, run `scripts/recovery/p5/Install-CascadeRecoverySchedule.ps1` as Lloyd and verify both tasks' principals and next-run times.
4. At the S01 window close, rerun read-only delivery checks; do not enable W07 without the exact approval.
5. Refresh section 1 again on the day Lloyd signs.

## 4. Lloyd-only steps

- Explicitly approve or decline the two Windows scheduled tasks described in rows 2–3.
- Sign row 9 only after rows 1–8 are green.
- Complete the protected staff-note save/reload check while signed in; never share the password or OTP with an agent.

## Decisions taken 2026-09-10 (D-054)

| Row | Decision |
|---|---|
| 1 | Two admin profiles stand. Cleaner sign-in dropdown trimmed to **Honey + Other**. Not green until deployed. |
| 2 | Backup **weekly, Sunday 00:00 UTC** (Task Scheduler on the workstation) **+ always before any apply**. |
| 3 | Restore drill **monthly** + after every pre-apply backup. |
| 5 | Lloyd = owner/on-call. **Finance route = Lloyd AND Marifel.** OPS route = Honey, turnover only. |
| 8 | `backup-supabase-production.ps1` **retired**. Cloudflare Worker stays on the books. GAS relays stay until W02/W08 are live. |
| 9 | Outstanding. Gated on rows 1–8 green. |
