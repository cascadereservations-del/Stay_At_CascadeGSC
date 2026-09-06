# Cascade Hideaway — Complete handoff after P3

**Prepared:** 2026-09-06 after the final `2026-09-06T15:10:43Z` Alfred baseline

**Canonical working tree:** `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`

**Branch:** `codex/cascade-waves-0-1-sol`

**Live posture:** P0–P3 complete. P4 has not started. Production remains frozen behind P4 and Module A.

**Next safe outcome:** obtain the exact P4 start approval, prove an encrypted backup/disposable restore of the new stack, then begin a complete 72-hour dormant soak with all workflows inactive.

This document supersedes the P2-era status at the top of [COMPLETE-HANDOFF-2026-09-06.md](./COMPLETE-HANDOFF-2026-09-06.md). Use current source and dated evidence when older text conflicts with this record.

## Executive state

The selected zero-subscription runtime now exists on Alfred's existing Docker Engine and is managed by Portainer CE as stack `cascade-n8n`. It is separate from Alfred's shared n8n. PostgreSQL and n8n are healthy, capped, provider-free and isolated. The editor is reachable only through an owner SSH tunnel to `127.0.0.1:5679`. The named owner enrolled TOTP MFA and verified sign-out/sign-in. All 13 source workflows are present, inactive and semantically identical to source. No credentials exist in the new stack.

P4 still must prove encrypted recovery and at least 72 hours of stable co-location. P5 must then close the Supabase Module A production gates. No local feature candidate may be released before those dependencies and its own fresh action approval.

## Phase ledger

| Phase | State | Evidence / remaining outcome |
| --- | --- | --- |
| P0 — Decision and source lock | **Complete** | Portainer CE on Alfred with a separate capped Compose stack is canonical. No second Docker daemon or new subscription. |
| P1 — Recovery and deployment packet | **Complete** | Alfred's existing n8n was encrypted, restored in isolation and returned healthy; capped replacement stack and recovery tooling passed. See [P1 Alfred evidence](../validation/2026-09-06-p1-alfred-recovery.md). |
| P2 — Host protection and fresh baseline | **Complete** | `/swapfile-cascade` provides 2,148,528,128 usable bytes and persists through `/etc/fstab`; all 20 existing container fingerprints matched. See [P2 evidence](../validation/2026-09-06-p2-host-maintenance.md). |
| P3 — Dormant Cascade stack | **Complete** | Stack healthy and isolated; owner MFA enabled; 13 workflows inactive; zero credentials; semantic hash matched. See [P3 evidence](../validation/2026-09-06-p3-dormant-stack.md). |
| P4 — Recovery drill and 72-hour soak | **Not started** | Run encrypted backup/disposable restore, then collect complete 60-second samples for at least 72 hours. No missing interval may be counted as proof. |
| P5 — Module A production closure | **Blocked by P4 and fresh approvals** | Prove Supabase recovery, release staff/RLS/privacy foundations, enroll project-user AAL2, authorize a real cleaner, release price history, and configure reviewed liveness. |
| P6 — Core booking release | **Local candidates ready; not live** | Release Modules B/C/D/E in reviewed batches after P5; prove named Finance review before canonical booking confirmation. |
| P7 — Operations and insight release | **Local candidates ready; not live** | Release Waves 3/4/5 with role smoke tests, Finance/OPS isolation and no supplier ordering. |
| P8 — Guest lifecycle release | **Local candidates ready; not live** | Release Waves 2/6/7 without unreviewed sending or publication. |
| P9 — Provider/workflow activation | **Not authorized** | Create one reviewed credential and activate one reviewed workflow at a time, observe it, then export the live JSON back to source. |
| P10 — Operational acceptance | **Future** | Close access, backup cadence, restore drills, alerts, incident ownership, authority inventory and carefully reviewed retirement work. |

The executable dependency order remains:

```text
P0 → P1 → P2 → P3 → P4 → P5 → P6 → P7/P8 → P9 → P10
```

## Live Alfred state after P3

Portainer stack `cascade-n8n` owns exactly:

- containers `cascade-n8n-postgres` and `cascade-n8n-app`;
- volumes `cascade_n8n_postgres_data` and `cascade_n8n_data`;
- networks `cascade_n8n_internal` and `cascade_n8n_egress`;
- root-owned staging under `/opt/cascade/n8n`.

The live image IDs are pinned to:

- `postgres:17.11-alpine3.24@sha256:7456ef82e5f5bc43d997f4781bbd7c0d6389bff397564649a356e206ba473aee`;
- `n8nio/n8n:2.37.10@sha256:848166b4051fd4251869f48c18455bddff922f04cb2f2676929463ba973dbde2`.

Resource and exposure boundaries:

| Service | Memory | CPU | Exposure |
| --- | ---: | ---: | --- |
| PostgreSQL | 768 MiB | 0.75 | no host port |
| n8n | 1536 MiB | 1.5 | `127.0.0.1:5679 → 5678/tcp` only |

There is no Cascade DNS record, Cloudflare/Caddy route, public editor hostname, provider credential, stack webhook, GitOps source or private registry. Alfred's existing n8n remains separately healthy on `127.0.0.1:5678` and its existing public route was not changed.

At the final P3 sample (`2026-09-06T15:10:43Z`):

- available RAM: 2,668,470,272 bytes;
- total/free swap: 2,148,528,128 / 2,146,168,832 bytes;
- free disk under `/opt`: 33,292,050,432 bytes;
- load average: 0.15 / 0.12 / 0.12;
- running containers: 22, consisting of the unchanged 20 existing containers and two approved Cascade containers.

Every existing full container ID, start time, restart count, OOM flag and resource limit matched the pre-P3 capture. Both Cascade containers were healthy, restart count zero and OOM false. Swap use was unchanged across the recorded post-start samples.

## P3 workflow and access proof

Database aggregate evidence:

- named credentialed owners: 1;
- MFA-enabled users: 1;
- workflows: 13;
- active workflows: 0;
- credentials: 0.

The authenticated n8n Personal Settings page showed two-factor authentication enabled. The owner personally enrolled TOTP and reported a successful sign-out/sign-in check. The workflow overview displayed all 13 expected names. A fresh export compared with source using `scripts/recovery/recovery-contract.mjs` and produced semantic SHA-256:

`d3077384d1bca5cf6d9941eb1a104183c3348f964ebba49741baf6436c4cd8ce`

No identity, email, password, TOTP seed, recovery code, cookie, workflow body or credential value belongs in evidence.

## Secret custody and resolved deployment anomaly

Owner-controlled P3 material is outside Git:

- environment file: `C:\Users\Lloyd\Cascade-Secrets\cascade-n8n-portainer.env`;
- age identity: `C:\Users\Lloyd\Cascade-Secrets\cascade-n8n-recovery-age.txt`;
- public recipient: `C:\Cascade-Backups\cascade-n8n-recovery-age-recipient.txt`.

The two private files have inheritance disabled and a single owner-only ACL rule. Alfred's matching `.env` is root-owned mode `0600` under `/opt/cascade/n8n`.

During Portainer form preparation, an accessibility snapshot rendered the first generated environment values. They had not been deployed. All affected values were regenerated, the local and Alfred files were replaced, the form was reloaded, and only the rotated values were deployed. The exposed values are inactive.

The first workflow import failed closed because root:root `0750` staging was unreadable to n8n's UID/GID 1000. Directories remain root-owned `0750`; group 1000 now has read/traverse access. The second import succeeded. No workflow became active and no credential was created.

## P4 exact next phase

P4 must not be marked complete from point-in-time P3 samples. Before mutation, review [the completion plan](../plans/2026-09-06-portainer-n8n-completion-plan.md), [deployment runbook](../runbooks/cascade-n8n-deploy.md), `infrastructure/cascade-n8n/backup.ps1`, and `infrastructure/cascade-n8n/restore-check.ps1`. Prepare a concrete P4 action packet and obtain fresh owner approval for backup creation and disposable restore resources.

P4 sequence:

1. Recheck both Cascade containers, all 20 existing container fingerprints, RAM, swap, disk, load, loopback listener, 13/0/0 workflow aggregates and owner MFA aggregate.
2. Create an encrypted backup using the dedicated age recipient. Never print `.env`, database contents, n8n keys, MFA fields or workflow bodies.
3. Verify ciphertext checksum and run the disposable restore checker with uniquely named containers, networks and volumes, no host port and no provider access.
4. Require database integrity, 13 workflows, zero active workflows, zero credentials, successful semantic export comparison and exact cleanup of disposable resources. Preserve the encrypted backup.
5. Start an outside-Git soak log with UTC timestamps and a 60-second interval. Record complete samples for at least 72 hours; missing periods extend the end time.
6. At every sample capture available RAM, total/free swap, root and `/opt` free disk, 1/5/15-minute load, both Cascade health/restart/OOM/limits, existing-container identity/restart/OOM state, workflow active count, credential count, and both n8n health endpoints.
7. Produce a dated P4 report and only then decide whether same-host co-location passes.

P4 abort conditions:

- available RAM below 1.5 GiB for three consecutive samples;
- swap used grows for five consecutive samples rather than settling;
- 15-minute load exceeds 3;
- free disk falls below 15 GiB;
- any pre-existing service changes identity/start time, restarts, becomes unhealthy or records OOM;
- either Cascade container restarts, becomes unhealthy or records OOM;
- any Cascade workflow activates, credential appears, provider traffic occurs, or the editor becomes public;
- samples are missing or evidence becomes incomplete.

On an abort, stop only `cascade-n8n-app` and `cascade-n8n-postgres`, preserve logs/backups/volumes and move the plan to the separate-VPS fallback. Do not delete volumes, remove swap, restart Docker, alter the existing n8n or change DNS/proxy state without a separate reviewed action.

## P5 Module A gates

Production remains frozen until all six gates have fresh dated evidence:

1. **Supabase recovery:** place the Session Pooler URI on port 5432 in the existing owner-only connection file, create an encrypted production backup, verify it, restore it into a disposable target, reconcile the migration ledger and prove rollback readiness. Do not reset the production database password merely to obtain a URI.
2. **Coordinated staff/RLS/privacy release:** use [the Module A cutover packet](../plans/2026-08-31-module-a-cutover-packet.md) and release only the reviewed migration/function set after a fresh preflight and owner approval.
3. **Project-user MFA/AAL2:** enroll TOTP for the Cascade application owner and prove a fresh `aal2` session. Supabase dashboard-account MFA does not satisfy this application gate.
4. **Real cleaner authorization:** create or select the real cleaner Auth identity, assign it to the correct property, then prove sign-in, property isolation, private photo upload, meter lookup, report submission, pending expense claim, sign-out, disabled-user denial and stale-session denial.
5. **Scheduler/liveness:** create dedicated secrets, deploy and smoke-test the reason-only heartbeat, then separately approve any schedule or Uptime Kuma monitor activation.
6. **Price history:** release the corrected price-history view under its own reviewed packet and prove access/rollback.

P5 contains production data and identity changes. Each coherent batch needs fresh action-time owner approval. P4 passing does not authorize P5 automatically.

## P6–P10 remaining release work

### P6 — Core booking

- Release Module B's canonical, transaction-owned booking decision and idempotency boundary.
- Release Module C payment evidence/comparison with immutable named Finance review.
- Connect Module D's Finance-only review UI in its owning product repository; that UI source is not present here.
- Release Module E holds, lifecycle, rates, cancellations/no-shows, refund authorization and reconciliation.
- Prove concurrency, RLS, named Finance approval, idempotency, lifecycle separation and rollback before delivery exists.

### P7 — Operations and insight

- Release Wave 3 cleaning/meter evidence with named inspector review and manager-only override.
- Release Wave 4 inventory reconciliation and advisory forecasting; purchase-list approval must never order or pay.
- Release Wave 5 named Finance reconciliation and internal analytics; deny OPS and make no BIR/tax/statutory claim.
- Connect each owning UI only after real-role smoke tests.

### P8 — Guest lifecycle

- Release Wave 2 encrypted/redacted shared inbox with named assignment and review; draft approval must not send.
- Release Wave 6 hashed identity, purpose-specific consent, lifecycle/recovery and retention controls.
- Release Wave 7 consent-gated ciphertext drafts and exact-content review; approval must not publish.
- Recheck consent and authority at action time.

### P9 — Provider and workflow activation

- Use credentials named `Cascade — <provider/purpose>` only.
- Fixture-test with provider actions disabled.
- Obtain separate approval for one provider/workflow batch.
- Activate one workflow, observe it, prove routing and delivery, and export reviewed JSON back to source.
- Repeat one batch at a time. Never bulk-activate all 13 workflows.

### P10 — Operational acceptance

- Complete named access review, encrypted backup schedule, restore cadence and alerting.
- Record incident ownership, escalation paths, recovery time expectations and support runbooks.
- Reconcile the machine-readable authority inventory with live state.
- Retire an old Cascade path only after proving no pending execution or rollback dependency and obtaining separate destructive approval.

## Local candidates already complete

Do not rebuild these solely because deployment is pending:

| Workstream | Local evidence | Boundary |
| --- | --- | --- |
| Module B | Atomic booking decision and collision tests | n8n/provider cannot confirm a booking |
| Module C | 47 rollback-only pgTAP assertions plus source/Deno tests | OCR and bank email remain advisory |
| Module D | Finance queue and inactive delivery boundary | OPS receives no Finance or guest-contact detail |
| Module E | 43 rollback-only pgTAP assertions plus two-session collision proof | refund authorization never executes payment |
| Wave 2 | 31 rollback-only pgTAP assertions | draft review never sends |
| Wave 3 | 21 rollback-only pgTAP assertions | AI result cannot approve evidence |
| Wave 4 | 31 rollback-only pgTAP assertions plus concurrency/rollback | purchase review never orders |
| Wave 5 | 50 rollback-only pgTAP assertions plus rollback | Finance-only; no compliance claim |
| Wave 6 | 31 rollback-only pgTAP assertions plus rollback | eligibility does not authorize contact |
| Wave 7 | 33 rollback-only pgTAP assertions plus rollback | review does not publish |
| Wave 8 | Authority inventory, handoff and disposable recovery | local evidence does not imply release |

## Authority boundaries

- Supabase owns bookings, payments, lifecycle, cleaning, inventory, Finance, consent and review facts.
- n8n is delivery and integration only.
- Finance/Admin and OPS remain strictly separated. OPS gets no money, payment, receipt, bank, rate, deposit, refund or guest-contact detail.
- AI, OCR, forecasts, classifications and email evidence are advisory.
- A named human approves booking/payment confirmation, refunds, discounts, exceptions, cleaning overrides, purchase lists and publication.
- A purchase-list review cannot order. A marketing review cannot publish. An inbox review cannot send.
- The business is unregistered; never claim BIR, tax, statutory or filing compliance.
- No passing test, local candidate, plan, platform choice or earlier approval authorizes a later production action or external effect.

## Known risks and unresolved dependencies

- The 72-hour co-location proof is missing until P4 completes.
- Supabase Free has no scheduled backup/PITR; the external encrypted backup path remains mandatory before Module A cutover.
- The owner-only Supabase connection file was prepared but previously empty. The next backup attempt must use the Session Pooler URI on port 5432.
- Project-user TOTP/AAL2 and a real cleaner identity remain separate from the completed n8n MFA.
- Docker Desktop on this workstation is broken/absent after the successful P1 local drill. Repair is prepared in [the workstation packet](../plans/2026-09-06-workstation-docker-repair-packet.md) and requires separate software-install approval. Alfred is unaffected.
- The existing shared n8n uses a mutable image tag even though its current container runs 2.37.10. Do not alter it during Cascade work.
- Direct-booking, Admin, cleaner and inventory product sources may live in other repositories. Inspect their owning repositories before UI integration.
- Obsidian records contain historical context, not deployment authority.

## Git and workspace discipline

Recent phase commits before this handoff:

- `cf4c9f3` — P1 Alfred recovery proof;
- `993c5e1` — approved P2 swap and passing baseline;
- `0252f59` — P3 action packet;
- `9204289` — guarded P3 secret preparation;
- `3f595cb` — P3 pending resume handoff;
- `0128823` — P3 deployment evidence pending owner MFA.

Verify the new handoff commit with `git log -1 --oneline`; do not rely on a copied future SHA.

The worktree intentionally contains unrelated Task Master setup. Do not edit, stage, clean or include these in phase commits:

- `.gitignore`;
- `.env.example`;
- `.taskmaster/`;
- `AGENTS.md`;
- `docs/handoff/TASKMASTER.md`;
- `scripts/taskmaster-codex.mjs`;
- `scripts/taskmaster-schema.mjs`;
- `tests/taskmaster/`.

Stage only files owned by the current phase. Before each commit, run focused tests, secret scanning and `git diff --check`.

## Canonical source and evidence

- [P0–P10 completion plan](../plans/2026-09-06-portainer-n8n-completion-plan.md)
- [P3 action packet](../plans/2026-09-06-p3-dormant-stack-action-packet.md)
- [P3 completion evidence](../validation/2026-09-06-p3-dormant-stack.md)
- [P2 host evidence](../validation/2026-09-06-p2-host-maintenance.md)
- [P1 Alfred recovery evidence](../validation/2026-09-06-p1-alfred-recovery.md)
- [Module A cutover packet](../plans/2026-08-31-module-a-cutover-packet.md)
- [Module execution queue](../plans/module-execution-queue.md)
- [Deployment runbook](../runbooks/cascade-n8n-deploy.md)
- [Development playbook](./DEVELOPMENT-PLAYBOOK.md)
- [File map](./FILE-MAP.md)
- [Copy/paste resume prompt](./RESUME-PROMPT-P3.md)
- [Visual phase dashboard](./cascade-phase-status-p3.html)

## Resume sequence

1. Confirm the branch and Git status; preserve all Task Master files listed above.
2. Read this handoff, the visual dashboard, P3 evidence, completion plan, deployment runbook and Module A cutover packet.
3. Read-only verify Alfred still has 22 running containers, both Cascade services healthy, the 20 existing fingerprints unchanged, workflow aggregates 13/0/0, one MFA-enabled owner, loopback-only port 5679 and the P3 resource thresholds.
4. Prepare the exact P4 backup/restore/soak packet. Stop for fresh owner approval before creating backup or disposable restore resources.
5. Complete the encrypted restore proof, then begin the full 72-hour monitor outside Git.
6. If P4 passes, prepare P5 as separate production batches. Do not treat the P4 approval as Supabase cutover approval.
7. Continue P6–P10 in dependency order, stopping before every production migration, identity/access change, provider credential, workflow activation, message, order, publication, subscription or destructive cleanup unless the owner has approved that exact action.
