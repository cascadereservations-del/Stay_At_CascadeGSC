# Portainer CE + n8n completion plan

**P5 update (2026-09-08 ~01:10 UTC): WINDOW PREP COMPLETE.** Owner TOTP is back in the window at Lloyd's request. Built and committed locally, nothing deployed or pushed: cleaner PWA session patch (`cleaners-auth-sol` `fffc5ce`), Inventory app one-time sign-in + attributed usage RPC (`inventory` clone), `tools/owner-mfa-enrol.html`, migration `20260908000100_record_inventory_usage_rpc.sql`, window SQL, evidence template. `deno check` clean on the three auth functions; contract verifier `ok`; window is turnover-free until 2026-09-13. Live batch runs on Lloyd's "go" with him present (Honey's password, his authenticator, two pushes).

**P5 update (2026-09-08 ~00:00 UTC): RE-CUT LEAN (D-031).** Owner constraints: one-time per-device cleaner sign-in with a persistent session, a real account for Honey, no ceremony. The cutover is now six safety changes and six batched proofs in one ~60-minute window; project-owner TOTP, the `staff-access` function, the full denial matrix and a live submit test are deferred. Two blast-radius items the packet missed are handled in-window: the admin dashboard's existing owner/admin Auth users need staff rows, and the anon-key Inventory app needs the same one-time sign-in. One PWA patch (do not clear the session on a network error) precedes publish. See [lean re-cut](2026-09-08-module-a-lean-recut.md).

**P5 update (2026-09-07 23:15 UTC): GATE 1 COMPLETE.** Encrypted production backup (1.63 MB, set `cascade-supabase-20260907T230736Z`) and disposable restore proof on Alfred both passed: 848 TOC entries, 40 tables, 69 functions, ledger 61/61, zero leftovers. Root cause of the five earlier failures was a copy fault between the reset dialog and the secrets file, proven offline with a SCRAM self-check. Gate 2 ledger reconciliation is clean (61 ledgered, all present locally). **Module A migrations NOT applied**: the release contract is a coordinated cutover (`old_reader/old_writer: false`) whose stop conditions need an owner AAL2 session, a proven real cleaner identity and same-window PWA + Edge deploys — gates 3/4 first. See [P5 gate 1 evidence](../validation/2026-09-08-p5-gate1-supabase-backup-restore.md).

**P5 update (2026-09-07 ~15:00 UTC): gate 1 attempt 4 FAILED on both hosts** after a fresh password reset and a structurally clean Session-pooler string (pooler and direct IPv6 host both return `password authentication failed for user "postgres"`). Five attempts across four resets now; escalated per the standing rule — next diagnostic is setting the role password by SQL in the dashboard editor rather than the reset dialog, then one run. See vault 00-STATE.

**P5 update (2026-09-07 ~09:45 UTC): gate 2 read-only evidence gathered.** Live ledger = 61 migrations, all present locally; 18 local files unledgered (`20260824045800_dispatch_w01_to_n8n` is live-but-unledgered, the rest are the Module A / B–E candidates awaiting release). Gate 1 unchanged.

**P5 update (2026-09-07 ~06:30 UTC): GATE 1 BLOCKED, DEFERRED.** Supabase production backup (`scripts/recovery/p5/supabase-backup-over-alfred.sh`) has failed `password authentication failed for user "postgres"` on 3 separate password resets, against both the Direct connection host and the Session pooler host — ruling out a host/tab mistake. A redacted structural diagnostic found the stored password value syntactically clean, so the defect is most likely a wrong byte in manual percent-encoding, or a stale password copy. Deferred at Lloyd's request 2026-09-07; see `04-HANDOFF-cascade.md` in the vault for full detail and the next unblock step. Gates 2–6 not started.

**P4 update (2026-09-06 ~16:30 UTC): COMPLETE.** Encrypted backup and disposable restore proof both passed (13/0/0 aggregates, semantic hash match, zero cleanup leftovers). 72-hour soak started 2026-09-06T16:16Z on Alfred, completes earliest 2026-09-09T16:16Z — not yet evaluated as of this update. See [P4 evidence](../validation/2026-09-06-p4-recovery-drill.md). This soak gates P9 only; P5 was authorized to proceed in parallel.

**P3 update (2026-09-06 15:10 UTC): COMPLETE.** P0–P3 now pass. The separate `cascade-n8n` Portainer stack is healthy, capped, loopback-only and owner-MFA protected; all 13 workflows are inactive, zero credentials exist, workflow semantics match source, and all 20 pre-existing container fingerprints remain unchanged. See [P3 evidence](../validation/2026-09-06-p3-dormant-stack.md).

**P2 update (2026-09-06 06:09 UTC): COMPLETE.** The owner-approved 2049 MiB swap allocation is active and persistent; all 20 existing container fingerprints match the pre-action baseline. RAM, swap and disk thresholds pass. See [P2 evidence](../validation/2026-09-06-p2-host-maintenance.md). This update supersedes P2-held/no-swap statements below. Next: prepare the separate P3 dormant-stack action packet; P3, soak and Module A remain gated.

**Decision date:** 2026-09-06

**Selected platform:** Alfred's existing Docker Engine, managed through Portainer CE, with a separate capped Cascade n8n + PostgreSQL Compose stack

**Subscription impact:** none

**Current live state:** P1 recovery passed; Alfred's existing n8n returned healthy and unchanged after its encrypted capture. No Cascade stack, swap, route change, provider, workflow activation, DNS change, or business-production change has been made.

## Decision

Use the already-installed Portainer CE to manage the source-controlled `cascade-n8n` Compose project on Alfred. Do not install a second Docker daemon and do not modify or replace Alfred's existing n8n service. The new stack receives its own containers, database, volumes, networks, encryption key, credentials, hostname, backups, and rollback boundary.

This selection uses the current Hetzner plan without adding a subscription. It is approved as the target architecture, not as permission to change the server. A separate VPS remains the tested fallback if the pre-start threshold or dormant-soak threshold fails, or if later production load no longer fits safely beside Alfred.

Supabase remains the canonical owner of business facts and state transitions. n8n remains a delivery and integration layer. The 13 source-controlled Cascade workflows remain inactive until individually approved.

## Non-negotiable operating boundaries

- Preserve every Alfred service, container, network, volume, credential, database, proxy route, and backup.
- Keep the Cascade editor loopback-bound at `127.0.0.1:5679`; expose it only through the reviewed TLS and identity-aware proxy route.
- Keep the n8n ceiling at 1.5 CPU / 1536 MiB and PostgreSQL at 0.75 CPU / 768 MiB unless a new capacity review changes the source candidate first.
- Do not add provider credentials during the dormant trial.
- Import all workflows inactive and prove their semantic hashes against source.
- Require a named AAL2 human for booking/payment confirmation, refunds, discounts, exceptions, cleaning overrides, purchase-list decisions, and publication review.
- A purchase-list review never authorizes a supplier order or payment.
- Finance/Admin and OPS data remain separated.

## Remaining phases

| Phase | Outcome | Work | Exit evidence | Live action? |
| --- | --- | --- | --- | --- |
| P0 — Decision and source lock | The hosting direction is unambiguous | Record this plan, update ADR/handoff/resume entry points, preserve Task Master files | Documentation tests, link checks, clean owned diff | No |
| P1 — Recovery and deployment packet | **Complete 2026-09-06** | Backed up and disposable-restored Alfred's existing n8n database, credential ciphertext, encryption key, workflows and binary storage; reviewed the exact image/security state; rendered and tested capped Compose; finalized proxy, secret, backup, smoke, abort, and rollback commands | [Redacted recovery report](../validation/2026-09-06-p1-alfred-recovery.md), successful isolated restore, reviewed rendered Compose, no placeholder or public binding | Completed under separate recovery approval; existing n8n returned healthy |
| P2 — Host protection and fresh baseline | **Complete 2026-09-06** | Added 2049 MiB persistent swap and repeated the full Alfred baseline | Thresholds passed and all 20 existing container fingerprints matched | Completed under separate approval |
| P3 — Dormant Cascade stack | **Complete 2026-09-06** | Created the isolated Portainer stack, named owner and MFA; imported 13 workflows inactive with no credentials | Services healthy/capped, loopback-only, semantics matched, existing services unchanged | Completed under separate approval |
| P4 — Recovery drill and 72-hour soak | **Restore proof COMPLETE 2026-09-06; soak RUNNING**, earliest pass 2026-09-09T16:16Z | Run encrypted backup and disposable restore of the new stack; observe host/container memory, swap, load, disk, restarts, health, and logs for at least 72 hours with workflows inactive | Restore proof plus soak report with no abort condition | Completed under approval; soak observation read-only, in progress |
| P5 — Module A production closure | **Gate 1 COMPLETE 2026-09-07T23:15Z; gate 2 clean; re-cut lean 2026-09-08 (D-031, [lean re-cut](2026-09-08-module-a-lean-recut.md)): one ~60-min window = 4 migrations + Honey's cleaner identity + 3 Edge Functions + PWA publish, owner TOTP deferred; in-window fixes for the admin dashboard users and the Inventory app; **prep complete 2026-09-08, live batch awaits Lloyd's "go"** | Prove encrypted Supabase backup/restore; reconcile migration ledger; release staff/RLS/named-cleaner changes through the cutover packet; enroll project-owner TOTP and prove fresh AAL2; assign and smoke-test a real cleaner; release the corrected price-history view; configure scheduler/liveness only after its own review | Every Module A gate has dated evidence and rollback result | Yes; each production batch requires approval |
| P6 — Core booking release | The authoritative booking and Finance review chain is live before delivery | Release Modules B and C together, wire Module D's Finance review UI in its owning product, then release Module E lifecycle/reconciliation; run concurrency, authorization, idempotency, Finance/OPS, and rollback checks | Named Finance review precedes the booking RPC; lifecycle actions and refund authorization stay separate; no provider delivery is required for acceptance | Yes; staged approvals |
| P7 — Operations and insight release | Staff workflows consume canonical facts safely | Release Wave 3 cleaning/meter access, Wave 4 inventory forecast/purchase review, and Wave 5 Finance reconciliation/analytics in separate batches; then connect the owning product UIs | Real-role smoke tests pass; purchase review cannot order; OPS cannot read Finance; reports disclose freshness/exclusions | Yes; staged approvals |
| P8 — Guest lifecycle release | Guest interaction foundations are live without unreviewed sending | Release Wave 2 inbox, then Wave 6 CRM/consent/retention, then Wave 7 draft/review; preserve ciphertext/redaction and re-check consent at review/action time | No draft approval sends; eligibility is not send authority; publication remains separately controlled | Yes; staged approvals |
| P9 — Workflow/provider activation | Delivery is introduced one narrow path at a time | Create only reviewed `Cascade — <provider/purpose>` credentials; fixture-test with provider actions disabled; activate one workflow; observe; export reviewed JSON back to source; repeat | Per-workflow approval, delivery evidence, source export, recovery proof, rollback path | Yes; one approval per provider/workflow batch |
| P10 — Operational acceptance | The new plane is supportable and the old Cascade path is safely retired | Complete access review, backup schedule, restore drill cadence, alerts, incident ownership, runbooks, and final authority inventory; retire an old Cascade delivery path only after no pending execution or rollback dependency remains | Signed operational acceptance and dated live-state inventory | Yes; retirement is a separate approval |

## Phase order and dependencies

```text
P0 decision
  -> P1 recovery/deployment packet
  -> P2 swap + fresh baseline
  -> P3 dormant stack
  -> P4 restore drill + 72-hour soak
  -> P5 Module A closure
  -> P6 core booking
  -> P7 operations/insight
  -> P8 guest lifecycle
  -> P9 one-by-one delivery activation
  -> P10 operational acceptance
```

P1 recovery evidence must exist before P2 or P3. P4 must pass before P5–P9 use the new automation plane. P5 must close before any local candidate is released. P6 precedes provider delivery because n8n must consume canonical outbox facts rather than make booking or payment decisions.

## Alfred abort and fallback rules

Reject or stop only the new `cascade-n8n` project if any of these occurs:

- available RAM is below 2.5 GiB at the P2 pre-start check;
- available RAM remains below 1.5 GiB during the dormant soak;
- swap use grows continuously rather than settling;
- 15-minute load exceeds 3;
- any existing service restarts, becomes unhealthy, or records an OOM condition;
- free disk falls below 15 GiB;
- editor access is publicly exposed, secrets appear in rendered/logged output, or a workflow/provider becomes active unexpectedly.

When an abort condition occurs, preserve evidence and encrypted backups, stop only the Cascade project, revert only its new proxy/DNS route, and move P3 onward to a separate Cascade VPS. Do not delete volumes during routine rollback.

## Work that is already complete locally

Modules B–E and Waves 2–8 are local candidates with recorded tests. Wave 4 already implements advisory recorded-usage forecasting plus immutable named owner/admin purchase-list review; it contains no supplier-order, provider, outbox, or payment path. These candidates need staged release evidence, product UI wiring where identified, and live authorization/recovery proof. They do not need to be rebuilt merely because the hosting target is now selected.

## Immediate next safe outcome

P0–P3 are complete from the dated P1, P2 and [P3 evidence](../validation/2026-09-06-p3-dormant-stack.md). P4 remains open.

The next safe outcome is a concrete P4 action packet covering encrypted backup creation, ciphertext verification, uniquely named disposable restore resources, integrity/13-0-0/semantic checks, cleanup identifiers and abort handling. Obtain fresh owner approval for that mutation. After the restore proof passes, start the outside-Git 60-second monitor and collect a complete 72-hour dormant interval. Missing samples extend the soak. Do not start Module A production work until P4 passes and its own production batch is approved.
