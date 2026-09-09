# P9 provider-activation action packet

**Prepared:** 2026-09-09 UTC · **Status:** ready for Lloyd's credential actions; nothing activated
**Parent:** `2026-09-06-portainer-n8n-completion-plan.md` §P9 — "Delivery is introduced one narrow path at a time."
**Gate:** P4 soak must pass first (closes 2026-09-09 16:15:37 UTC).

## What is actually true on 2026-09-09

This packet exists because the plan's one-line P9 description hid a fact that changes the work:

**The 13 source-controlled workflow exports are skeletons.** Every file in
`automation/n8n/workflows/` is `manualTrigger → code → noOp → noOp`. There is no Telegram,
HTTP, email or webhook node anywhere in source, and therefore no credential reference. The
live `cascade-n8n` stack on Alfred holds the same 13 workflows (ids below), all inactive, zero
credentials (P3 evidence; list re-checked today). "Provider activation" therefore cannot mean
flipping these on — it means **authoring each real workflow, reviewing it, then activating
it**, one at a time.

What *is* in place on the Supabase side:

| Piece | State |
|---|---|
| `automation_outbox` + `automation_outbox_dispatch_w01` trigger | live; dispatches only `booking.requested`, body carries ids only |
| `automation-event-detail`, `automation-callback` edge functions | deployed (v7) — n8n fetches detail and posts results through these |
| Vault secrets | `cascade_n8n_w01_webhook_secret`, `cascade_cf_w01_client_id`, `cascade_cf_w01_client_secret` — names exist, values set by Lloyd |
| Route/template guard | `notification_routes` + `_shared/notifications.ts`; OPS templates structurally cannot carry money fields |
| Job heartbeats | `job_heartbeats` live and `turnover-verifier` writing to it since the platform batch |
| `job-heartbeat-monitor` | **deployed v1 by Lloyd 2026-09-09 15:05Z** via the CLI; returns 401 until `CASCADE_CRON_SHARED_SECRET` exists |
| Pending outbox rows | 0 |

## Activation order and why

Smallest blast radius first. Each step is its own approval.

| # | Workflow (live id) | Why this position | Provider credential it needs |
|---|---|---|---|
| 1 | **CH-S01 Host Alert Router** (`a6suf8qOJnp7ASdG`) | Internal-only. Receives `system.job_stale` and `internal.*` outbox events and posts to the **owner's** Telegram. Proves the outbox → n8n → provider chain with no guest or Finance data. | `Cascade — Telegram/owner-alerts` (bot token) |
| 2 | **CH-W07 Error Handler** (`SAm8geADy5x8hz0y`) | n8n's error workflow. Must exist before any workflow that can fail in front of a guest. | reuses #1 |
| 3 | **CH-W04 Outbox Reconciliation** (`ms3Se1z2vKW9fLO5`) | Read-only sweep: outbox rows vs delivery log. Catches the failure mode where a webhook fires and nothing lands. | `Cascade — Supabase/outbox-read` (restricted key, not service role) |
| 4 | **CH-W01 Booking Requested** (`sLxyjQVXusLnCTE4`) | First guest-facing path, but the trigger is already live and the body is ids-only, so the new exposure is the Telegram message to OPS/Finance. | `Cascade — Telegram/ops`, `Cascade — Telegram/finance` |
| 5+ | W02 `g14GDFV6CsBbYBU7`, W03 `Njxk2jiH2Cg65nyd`, W05 `bWmU7OulmjPU3AC6`, W09 `ijfHca2h45MaYk85`, W12 `D7UMKswLGq5GR5Gn` | Operational digests and projections — after W01 has run clean for a week. | as above |
| last | W06 `ZLeU5W3uK5izg2KE`, W10 `SqY8ALR4BcoSUOUu`, W11 `z8x7dnl2PSTXjaym` | Consume P8 tables. **No marketing send exists in the schema** (`check (not publication_authorized)`); these may notify staff only. | as above |

W08 `v3gHI8piCXh6NOYX` (Airbnb proof audit) needs a Gmail/IMAP credential and a separate
privacy decision; park it.

## Per-workflow procedure (the plan's five steps, made concrete)

1. **Author** the workflow in the stack's editor (loopback-only `127.0.0.1:5679`, owner MFA)
   against `automation-event-detail`; provider node present but **disabled**.
2. **Fixture test**: fire one outbox row of the target `event_type` with a synthetic aggregate;
   confirm the workflow runs to the disabled provider node and `automation-callback` records
   the attempt. Assert the OPS payload passes `assertRoutePayloadSafe`.
3. **Credential** — Lloyd creates `Cascade — <provider/purpose>` in the stack (never in the
   shared `deploy` n8n), scoped to the Cascade project, no reuse across purposes.
4. **Activate** that one workflow; enable the provider node; observe for the agreed window
   (S01: 24 h; W01: 7 days) with CH-W04 reporting zero unreconciled rows.
5. **Export** the reviewed JSON back to `automation/n8n/workflows/`, commit, and record the
   activation in `02-DECISIONS`. Rollback = deactivate the workflow; outbox rows remain the
   durable retry source.

## What an agent may do vs. may not

- **May:** author and fixture-test workflows, write outbox fixtures, export JSON, run W04,
  evaluate evidence, prepare edge-function deploy commands.
- **May not:** create or paste any credential or secret value, set `CASCADE_CRON_SHARED_SECRET`,
  activate a workflow, or send a provider message. Those are Lloyd's, one approval each.

## Lloyd's checklist (names only — values never enter the repo or vault)

- [x] Deploy the monitor — done 2026-09-09 15:05Z (v1, 401 without header as designed).
- [x] Watchtower pin run by Lloyd 2026-09-09 15:54Z: four images digest-pinned, Watchtower in opt-in mode
      ("Only checking containers using enable label"), production containers untouched (D-050).
- [x] pg_cron wiring — release `20260909_heartbeat_monitor_cron` applied 4/4: monitor job every 15 min,
      job 8 header added; both read `vault.decrypted_secrets` name `cascade_cron_shared_secret` at run time.
- [x] Secret created 2026-09-09 21:05Z (Vault + edge, 48-char, same value). First 200 at 21:15Z; heartbeat row
      `job-heartbeat-monitor-every-15m` started/succeeded 21:15:03Z, 0 stale jobs. **Monitor is live.**
- [ ] `Cascade — Telegram/owner-alerts` bot token (S01, W07)
- [ ] `Cascade — Telegram/ops` and `Cascade — Telegram/finance` (W01+)
- [ ] `Cascade — Supabase/outbox-read` (W04)
- [ ] Confirm the three `cascade_*_w01_*` Vault values are current
