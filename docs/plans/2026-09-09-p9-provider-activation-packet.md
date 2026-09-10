# P9 provider-activation action packet

**Prepared:** 2026-09-09 UTC · **Refreshed:** 2026-09-10 UTC · **Status:** S01 and W04 live; W07 staged and disabled
**Parent:** `2026-09-06-portainer-n8n-completion-plan.md` §P9 — "Delivery is introduced one narrow path at a time."
**Gate:** P4 closed PASS WITH EXCEPTION on 2026-09-09. S01's 24-hour observation window closes
2026-09-11 00:55 UTC; W07 remains disabled until that window is clean and Lloyd gives the exact
provider-node approval.

## What is actually true on 2026-09-10

The original skeleton-only inventory below is historical. Three workflows have since been authored:

| Workflow | Current state |
|---|---|
| CH-S01 Host Alert Router | **Active**, Telegram enabled under D-053; two delivery rows and no delivery errors since activation |
| CH-W04 Outbox Reconciliation | **Active**, daily 08:00 Asia/Manila; Telegram enabled under D-056 and a live run proved |
| CH-W07 Error Handler | Imported and wired as n8n's error workflow; Telegram disabled; deliberately unproven until S01's observation gate closes |
| Remaining ten exports | Inactive; no provider activation is authorized |

The live Cascade stack has 13 workflows, two active workflows, and two credentials. Production has
zero pending outbox rows, zero failed deliveries in the last 24 hours, and zero delivery errors
since S01 activation as of the 2026-09-10 verification.

This packet exists because the plan's one-line P9 description hid a fact that changes the work:

At packet creation, **the 13 source-controlled workflow exports were skeletons.** Every file in
`automation/n8n/workflows/` was `manualTrigger → code → noOp → noOp`; there was no Telegram,
HTTP, email or webhook node in source and no credential reference. The live `cascade-n8n` stack
held the same 13 workflows, all inactive, with zero credentials. The author/review/approve/export
discipline remains binding even though S01, W04, and W07 have now advanced beyond that baseline.

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
- [x] **S01 authored, fixture-proved, activated, and exported.** The setup steps below are retained as historical execution evidence; do not repeat them against production.
      (`automation/n8n/workflows/CH-S01-host-alert-router.json`; D-053; 24-hour window closes 2026-09-11 00:55 UTC.)
      The poll/ack endpoint `automation-host-alerts` is in source + manifest. The original setup was:
      1. Deploy the endpoint **from the repo folder** (`cd C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol` first, or the CLI cannot find `supabase/functions/`):
         `npx supabase functions deploy automation-host-alerts --project-ref qkgfhsdppslwunarczeq --no-verify-jwt`
      2. Two edge secrets in one PowerShell line (value generated locally, never pasted):
         `$s = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 48 | ForEach-Object {[char]$_}); npx supabase secrets set N8N_HOST_ALERTS_SECRET=$s N8N_HOST_ALERTS_CHAT_ID_FINANCE=-1003819352746 N8N_HOST_ALERTS_CHAT_ID_OPS=-1003798341977 --project-ref qkgfhsdppslwunarczeq; Set-Clipboard "Bearer $s"; "done - clipboard holds the Authorization header value"`
         (group chat ids from @userinfobot, 2026-09-09: finance `-1003819352746`, ops `-1003798341977`; the bot must be a member of both groups)
      3. Tunnel to the stack editor: `ssh -L 5679:127.0.0.1:5679 alfred` then open http://localhost:5679 (owner MFA).
      4. Credentials, exactly these names: **Header Auth** `Cascade — Supabase/host-alerts` (Name `Authorization`, Value = paste clipboard);
         **Telegram API** `Cascade — Telegram/owner-alerts` (bot token from @BotFather).
      5. Import the workflow: `scp automation/n8n/workflows/CH-S01-host-alert-router.json alfred:/tmp/` then
         `ssh alfred "docker cp /tmp/CH-S01-host-alert-router.json cascade-n8n-app:/tmp/ && docker exec cascade-n8n-app n8n import:workflow --input=/tmp/CH-S01-host-alert-router.json"`
         — it replaces the stub by name; in the editor, open it and pick the two credentials on the four HTTP nodes and the Telegram node.
      6. Fixture (SQL editor, one synthetic row):
         `insert into public.automation_outbox (event_type, aggregate_type, aggregate_id, idempotency_key, route_class, template_key, payload) values ('system.job_stale','scheduled_job',gen_random_uuid(),'fixture:s01:'||to_char(now(),'YYYYMMDDHH24MISS'),'finance','finance.system_failure', jsonb_build_object('job_name','fixture-job','reason_code','JOB_HEARTBEAT_STALE','correlation_id',gen_random_uuid()::text,'last_succeeded_at','never','consecutive_failures',0,'rendered_text','FIXTURE - Cascade System Failure test'));`
         Then run the workflow once manually (Telegram still disabled): expect the row to end `completed` with delivery log rows
         `s01:telegram:<id>` = skipped and `s01:internal:<id>` = sent. Say "check S01" and I verify.
      7. Activation approval: enable the Telegram node, run once on a second fixture, confirm the message arrives, then activate the workflow. Observe 24 h.
- [ ] **Calendar-sync v13 is source-ready but not yet deployed** (stops the nightly "1 Airbnb calendar row no longer in the live feed" note — it was the
      rolling 365-day horizon tail, a fresh uid every midnight, not a real cancellation). From the repo folder:
      `npx supabase functions deploy calendar-sync --project-ref qkgfhsdppslwunarczeq --no-verify-jwt`
      Source proof: three focused horizon tests and a Deno type-check pass. Live proof after the
      separately approved release: no reconciliation note at the next 00:15 PHT run;
      `cancelled_reaped` stays 0 and the log shows `horizon-tail row(s) left alone`.
- [x] `Cascade — Telegram/owner-alerts` is present in the **cascade-n8n** stack and used by S01/W04. W07's Telegram node remains disabled.
- [x] ~~`Cascade — Telegram/ops` and `Cascade — Telegram/finance` (W01+)~~ **CANCELLED 2026-09-10** —
      unnecessary. One bot (`@CascadeHideawayBot`) is already a member of both groups, and
      `automation-host-alerts` selects the chat id from the event's `route_class` at claim time.
      CH-S01 has worked this way since it went live. One Telegram credential serves every route.
- [x] ~~`Cascade — Supabase/outbox-read` (W04)~~ **CANCELLED 2026-09-10** — replaced by a read-only
      `sweep` action on `automation-host-alerts`. CH-W04 authenticates with the header credential
      the stack already holds, so no Supabase key ever lands in n8n — the property D-051 exists to
      protect. Cost is one edge redeploy instead of a minted key.
- [x] The signed host-alert boundary is live; the three legacy W01 Vault names remain an inventory item, not a prerequisite for S01/W04.

## Current next gate

At or after 2026-09-11 00:55 UTC, rerun the read-only delivery/outbox checks. If clean, Lloyd must
explicitly approve enabling W07's Telegram provider node and the one controlled failure used to
prove it. No generic site-upgrade instruction substitutes for that provider-action approval.
Calendar-sync v13 also remains a separate production release: prove the named backup restore first,
then deploy and observe the next 00:15 Asia/Manila run.
