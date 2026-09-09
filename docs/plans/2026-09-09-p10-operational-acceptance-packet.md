# P10 operational-acceptance packet

**Prepared:** 2026-09-09 UTC · **Status:** inventory complete; acceptance items staged; signature is Lloyd's
**Parent:** `2026-09-06-portainer-n8n-completion-plan.md` §P10 — "The new plane is supportable and the old Cascade path is safely retired."

P10 is a checklist with evidence, not a release. Each row below is either **done** (with the
evidence file), **staged** (agent can finish without approval), or **Lloyd** (needs a decision,
a credential, or a signature).

## 1. Live-state inventory (read 2026-09-09, production `qkgfhsdppslwunarczeq`)

| Item | Value |
|---|---|
| Public base tables | 76 |
| Public functions | 118 |
| Migration ledger rows | 83 — reconciliation release landed 2026-09-09 (D-047); 0 MCP-assigned versions |
| Edge functions deployed | 23 of 26 in source — `job-heartbeat-monitor` v1 deployed by Lloyd 2026-09-09 15:05Z (401 until its secret exists); undeployed: `job-heartbeat-liveness`, `staff-access`, `payment-review-queue` |
| pg_cron jobs | 7 active (ids 1,3,4,5,6,7,8); none for the heartbeat monitor |
| Vault secrets (names) | `cascade_n8n_w01_webhook_secret`, `cascade_cf_w01_client_id`, `cascade_cf_w01_client_secret` |
| Staff access profiles (enabled) | owner 1 · admin 2 · cleaner 1 |
| Verified MFA factors | 1 (owner) |
| `job_heartbeats` rows | 2 (turnover-verifier, since the platform batch) |
| `automation_outbox` pending | 0 |
| Feature flags | all off — `guest_inbox_ui`, `marketing_send`, `scheduler_heartbeat_monitoring`, every P6/P7 flag |
| `staff_access_allowed` chain | privacy → P6 → P8 complete, in order (D-046) |
| n8n plane | `cascade-n8n` stack healthy, 13 workflows, 0 active, 0 credentials |
| Latest backup set | `cascade-supabase-20260909T145049Z`, restore-proved 76/76 tables on the pgvector image |

## 2. Acceptance items

| # | Item | State | Evidence / what remains |
|---|---|---|---|
| 1 | **Access review** | Lloyd | Inventory above. Decide: is `admin=2` right (Marifel + Lloyd on the admin account)? Cleaner sign-in dropdown still lists Marifel/Rocloyd who cannot use it. |
| 2 | **Backup schedule** | staged | Canonical: `scripts/recovery/p5/supabase-backup-over-alfred.sh` (pg_dump on Alfred, encrypted on the workstation). No scheduler exists because the passphrase lives only on the workstation. Proposal: weekly Sunday 00:00 UTC via Windows Task Scheduler on the workstation, plus **always** before any apply (already enforced by every contract's `backup.required`). Lloyd approves the cadence. |
| 3 | **Restore drill cadence** | staged | `supabase-restore-check-on-alfred.sh` now asserts restored tables == dump TOC (D-045 fix) and runs on the pgvector image. Proposal: monthly, and after every backup that precedes an apply. |
| 4 | **Alerts** | Lloyd | `job-heartbeat-monitor` **deployed** (v1, verified 401 without header). Still needs `CASCADE_CRON_SHARED_SECRET` set together with pg_cron job 8's header (D-036), a 15-min pg_cron job, and CH-S01 activated (P9 #1). Until then, heartbeat rows accumulate silently. |
| 5 | **Incident ownership** | Lloyd | Proposal: Lloyd = owner/on-call; Finance route = Lloyd; OPS route = Honey (cleaner lead) for turnover only. Record in `01-FACTS`. |
| 6 | **Runbooks** | done | `docs/runbooks/production-apply.md`, `docs/runbooks/heartbeat-stale.md`, `scripts/recovery/p5/README.md`, plus privacy request/breach (`docs/privacy/`) and the P1–P4 recovery packets. |
| 7 | **Final authority inventory** | done | `docs/architecture/edge-auth-manifest.json` (26 entries) + `staff_access_allowed` matrix verified live 2026-09-09 (D-046). |
| 8 | **Old path retirement** | Lloyd | Candidates: the archived Cloudflare Worker (already archived, D-028); the legacy `backup-supabase-production.ps1` (PowerShell-7-only, needs local Docker — supersede by the Alfred path); GAS relays (`airbnb-email-sync`, `telegram-expense`) stay until n8n W02/W08 are live. Retirement is a separate approval per the plan. |
| 9 | **Signed acceptance** | Lloyd | When 1–8 are green: dated signature in `02-DECISIONS` plus this inventory refreshed the same day. |

## 3. Agent-completable next steps (no approval needed)

1. ~~Runbooks~~ done. 2. ~~`scripts/recovery/p5/README.md`~~ done. 3. ~~Ledger reconciliation~~ landed (83 rows).
4. After P4 closes (2026-09-09 16:15:37 UTC): evaluate, write the report, mark P4 — it gates P9.
5. Refresh section 1 on the day Lloyd signs.

## 4. Lloyd-only steps

- Set the cron secret and job 8 header together (D-036); add the 15-min job for the already-deployed monitor.
- Approve backup and drill cadences (items 2–3); name incident owners (item 5).
- Decide the retirements (item 8), then sign (item 9).
