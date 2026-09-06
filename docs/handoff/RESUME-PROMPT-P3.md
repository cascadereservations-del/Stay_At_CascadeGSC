# Copy/paste resume prompt after P3

```text
Continue the Cascade Hideaway implementation from the post-P3 handoff.

Canonical worktree:
C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol

Branch:
codex/cascade-waves-0-1-sol

Read these first, in order:
1. docs/handoff/COMPLETE-HANDOFF-P3-2026-09-06.md
2. docs/handoff/cascade-phase-status-p3.html
3. docs/validation/2026-09-06-p3-dormant-stack.md
4. docs/plans/2026-09-06-portainer-n8n-completion-plan.md
5. docs/runbooks/cascade-n8n-deploy.md
6. docs/plans/2026-08-31-module-a-cutover-packet.md
7. docs/handoff/DEVELOPMENT-PLAYBOOK.md
8. docs/handoff/FILE-MAP.md

Current phase state:
- P0–P3 are complete. P4 has not started.
- P0 decision/source lock: COMPLETE.
- P1 existing Alfred n8n recovery and isolated restore: COMPLETE.
- P2 2049 MiB swap, persistence and full host baseline: COMPLETE.
- P3 isolated Portainer Cascade n8n/PostgreSQL stack: COMPLETE.
- P4 encrypted recovery drill and 72-hour dormant soak: NOT STARTED.
- P5 Module A production closure: BLOCKED by P4 and fresh production approvals.
- P6 core booking release: local candidates ready, not live.
- P7 operations/insight release: local candidates ready, not live.
- P8 guest lifecycle release: local candidates ready, not live.
- P9 provider/workflow activation: not authorized.
- P10 operational acceptance: future.

Live P3 state verified 2026-09-06:
- Portainer stack name: cascade-n8n.
- Containers: cascade-n8n-postgres and cascade-n8n-app.
- Volumes: cascade_n8n_postgres_data and cascade_n8n_data.
- Networks: cascade_n8n_internal and cascade_n8n_egress.
- Host staging: /opt/cascade/n8n, root-owned mode 0750 with group 1000 read/traverse access; .env root-owned mode 0600.
- PostgreSQL cap: 768 MiB / 0.75 CPU; no host port.
- n8n cap: 1536 MiB / 1.5 CPU; only 127.0.0.1:5679 -> 5678/tcp.
- Both containers healthy, restart 0, OOM false.
- One named owner and one MFA-enabled user; owner reported successful sign-out/sign-in with TOTP.
- 13 workflows, zero active workflows, zero credentials.
- Semantic workflow SHA-256: d3077384d1bca5cf6d9941eb1a104183c3348f964ebba49741baf6436c4cd8ce.
- No Cascade DNS/proxy route, public hostname, provider credential, webhook, GitOps integration, message, order or production business effect.
- Alfred's existing n8n remains separate and healthy on 127.0.0.1:5678.
- Final P3 sample: 2,668,470,272 bytes available RAM; 2,148,528,128 total swap and 2,146,168,832 free; 33,292,050,432 bytes free under /opt; load 0.15/0.12/0.12; 22 running containers.
- The 20 pre-existing container IDs/start times/restart/OOM/limits matched the P3 baseline.

Pinned images:
- postgres:17.11-alpine3.24@sha256:7456ef82e5f5bc43d997f4781bbd7c0d6389bff397564649a356e206ba473aee
- n8nio/n8n:2.37.10@sha256:848166b4051fd4251869f48c18455bddff922f04cb2f2676929463ba973dbde2

Owner-controlled P3 material outside Git:
- C:\Users\Lloyd\Cascade-Secrets\cascade-n8n-portainer.env
- C:\Users\Lloyd\Cascade-Secrets\cascade-n8n-recovery-age.txt
- C:\Cascade-Backups\cascade-n8n-recovery-age-recipient.txt
Never print or copy their secret contents into Git, chat or evidence.

Resolved P3 anomalies:
- A Portainer accessibility snapshot exposed the first generated environment values before deployment. They were rotated locally and on Alfred, the form was reloaded, and only the replacements were deployed. The exposed values are inactive.
- The first workflow import failed because root:root 0750 staging denied UID/GID 1000. Directories remain root-owned 0750 with group 1000 read/traverse access. The successful import kept all workflows inactive.

Immediate task — P4:
1. Verify Git status and preserve unrelated Task Master files.
2. Recheck the complete Alfred baseline and 13/0/0 plus owner-MFA aggregates.
3. Review infrastructure/cascade-n8n/backup.ps1 and restore-check.ps1 and prepare a concrete P4 action packet.
4. Obtain fresh owner approval before creating the encrypted backup or disposable restore resources.
5. Back up using the dedicated age recipient without printing secrets; verify ciphertext and checksum.
6. Run a uniquely named disposable restore with no host port or provider access. Require integrity, 13 workflows, zero active, zero credentials, matching semantic hash and exact cleanup. Preserve the encrypted backup.
7. Start an outside-Git 60-second monitor and collect a complete 72-hour interval. Missing samples extend the soak.
8. Record RAM, swap, disk, load, both Cascade health/restart/OOM/caps, every existing container identity/restart/OOM, workflow active/credential counts, and both n8n health endpoints.
9. Abort if RAM is below 1.5 GiB for three samples, swap grows for five samples, 15-minute load exceeds 3, disk is below 15 GiB, a service changes/restarts/OOMs/unhealthy, a workflow activates, a credential appears, provider traffic occurs, or the editor becomes public.
10. On abort, stop only the two Cascade containers and preserve evidence/backups/volumes. Do not delete volumes, remove swap, restart Docker or alter existing Alfred services.

After P4 passes, P5 must close all Module A gates under separate production approvals:
- encrypted Supabase production backup and disposable restore using the Session Pooler URI on port 5432;
- migration-ledger reconciliation and rollback readiness;
- coordinated staff/RLS/privacy release;
- application-owner TOTP and a fresh AAL2 session (dashboard MFA does not count);
- real cleaner property assignment plus authenticated success and denial smoke tests;
- dedicated scheduler/liveness secrets and heartbeat proof before monitor activation;
- corrected price-history view release and rollback proof.

Remaining release order:
- P6: Modules B/C/D/E, proving named Finance review before booking confirmation, transaction/idempotency/concurrency and lifecycle/refund separation. Module D UI is in its owning product repository.
- P7: Waves 3/4/5 for cleaning, inventory and Finance analytics with real-role isolation and no supplier ordering.
- P8: Waves 2/6/7 for inbox, identity/consent/retention and reviewed marketing drafts with no unreviewed send or publication.
- P9: one separately approved Cascade — <provider/purpose> credential and one workflow activation at a time, followed by observation and source export.
- P10: access review, backup/restore cadence, alerting, incident ownership, live authority inventory and separately approved retirement.

Local candidates already complete; do not rebuild them solely because they are not live:
- Module B atomic canonical booking decision.
- Module C advisory payment evidence and named Finance review; 47/47 pgTAP.
- Module D Finance-only review queue and inactive delivery boundary.
- Module E holds/lifecycle/rates/refund authorization/reconciliation; 43/43 pgTAP plus collision proof.
- Wave 2 shared inbox; 31/31 pgTAP.
- Wave 3 cleaning/meter evidence; 21/21 pgTAP.
- Wave 4 inventory/forecast/purchase-list review; 31/31 pgTAP plus concurrency/rollback.
- Wave 5 Finance reconciliation/analytics; 50/50 pgTAP plus rollback.
- Wave 6 identity/consent/retention; 31/31 pgTAP plus rollback.
- Wave 7 reviewed marketing drafts; 33/33 pgTAP plus rollback.
- Wave 8 authority inventory, handoff and disposable recovery.

Non-negotiable boundaries:
- Supabase is canonical; n8n is delivery/integration only.
- Finance/Admin and OPS are strictly separate.
- AI, OCR, forecasts, classifications and email evidence are advisory.
- Named humans approve booking/payment confirmation, refunds, discounts, exceptions, cleaning overrides, purchase lists and publication.
- Purchase review never orders; draft review never sends; marketing review never publishes.
- The business is unregistered; make no BIR, tax, statutory or filing-compliance claim.
- Stop before every server mutation, production migration, identity/access change, provider credential, workflow activation, message, order, publication, subscription or destructive cleanup unless the owner approved that exact action.

Workstation constraint:
- Docker Desktop is broken/absent after the successful P1 local restore proof. Repair is documented in docs/plans/2026-09-06-workstation-docker-repair-packet.md and needs separate software-install approval. Alfred is healthy and unaffected.

Preserve these unrelated dirty Task Master files and do not stage, edit, clean or depend on them:
- .gitignore
- .env.example
- .taskmaster/
- AGENTS.md
- docs/handoff/TASKMASTER.md
- scripts/taskmaster-codex.mjs
- scripts/taskmaster-schema.mjs
- tests/taskmaster/

Use current source and dated evidence as authority. Stage only files owned by the current phase. Run focused tests, secret scanning and git diff --check before each commit. Do not mark a phase complete without live evidence for every exit condition.
```
