# Resume prompt — P3 approval pending

```text
Continue the Cascade Hideaway business-system project from:
C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol

Start with:
- git status --short
- git log -7 --oneline

Then read, in order:
1. HANDOFF.md
2. docs/handoff/COMPLETE-HANDOFF-2026-09-06.md
3. docs/handoff/CURRENT-STATE.md
4. docs/plans/2026-09-06-portainer-n8n-completion-plan.md
5. docs/plans/2026-09-06-p3-dormant-stack-action-packet.md
6. docs/validation/2026-09-06-p3-preparation.md
7. docs/validation/2026-09-06-p2-host-maintenance.md
8. docs/plans/2026-09-06-workstation-docker-repair-packet.md
9. docs/runbooks/cascade-n8n-deploy.md

Branch: codex/cascade-waves-0-1-sol
Verify current Git history rather than trusting copied SHAs. Expected completed sequence:
- cf4c9f3: P1 Alfred n8n recovery proof passed.
- 993c5e1: owner-approved P2 swap and fresh Alfred baseline passed.
- 0252f59: immutable, SSH-only P3 source and exact action packet prepared.
- 9204289: tested guarded P3 environment generator and P4 Docker-repair packet added.
- A later handoff commit may follow; use Git as authority.

P2 live state:
- `/swapfile-cascade` is active and persistent.
- File size 2,148,532,224 bytes; usable swap 2,148,528,128 bytes; zero used at completion.
- 20 existing container identities/start times/restart/OOM/limit fingerprints matched before and after.
- Final P2 sample had about 2.90 GiB available RAM, 31.53 GiB free disk and low load.
- No Cascade stack, route, credential, workflow activation, provider action, message or production migration was created.

P3 source state:
- Compose pins exact Linux/amd64 manifests for n8n 2.37.10 and PostgreSQL 17.11.
- Target resources are only `cascade-n8n-app`, `cascade-n8n-postgres`, `cascade_n8n_data`, `cascade_n8n_postgres_data`, `cascade_n8n_internal`, and `cascade_n8n_egress`.
- n8n binds only `127.0.0.1:5679`; PostgreSQL has no host port.
- Dormant access is SSH-only at `http://localhost:5679`; P3 creates no DNS, Cloudflare or Caddy route.
- All 13 source workflows must import inactive with zero provider credentials and semantic hash `d3077384d1bca5cf6d9941eb1a104183c3348f964ebba49741baf6436c4cd8ce`.
- `scripts/deployment/p3-environment.mjs` generates independent secrets outside Git, does not print values, and refuses overwrite/repository paths. Three focused tests pass.
- Alfred's Compose 5.1.4 parser accepted the candidate with validation-only placeholders without creating resources.
- Portainer 2.45.0 is reachable at its existing hostname, but the browser has no authenticated session and is waiting at the login page. Do not request, view or handle the owner's password. After approval, open Portainer and let the owner sign in personally.

Immediate gate:
Ask exactly: “Approve P3 execution from commit 9204289 (plus the current handoff-only commit), creating only the isolated dormant stack and owner-controlled secrets, importing 13 inactive workflows, and making no route, provider, activation or message?”

After approval:
1. Re-run the full host baseline and exact manifest/collision checks from the P3 packet.
2. Generate the owner-only local environment file and dedicated P3 age identity without printing secrets; verify ACLs.
3. Create only `/opt/cascade/n8n`, copy approved files/workflows and verify hashes.
4. Open the Portainer login page and hand off authentication to the owner. Resume after they confirm login.
5. Upload the approved Compose and environment file to a Portainer stack named exactly `cascade-n8n`; deploy once with GitOps/webhooks disabled.
6. Verify health, caps, loopback-only binding and every pre-existing container fingerprint.
7. Import all 13 workflows inactive, prove zero credentials/zero active and compare semantic hash.
8. Open an SSH tunnel to the editor. The owner personally creates the named account and enrolls n8n TOTP MFA. Record pass/fail only.
9. Commit dated P3 evidence. Do not claim P4 soak completion.

P4 prerequisite discovered:
- Workstation Docker Desktop is partially absent: the GUI executable, uninstall registration and service were not found, though an orphaned CLI remains.
- Alfred has Docker/Compose but no PowerShell, standalone docker-compose or age.
- Use docs/plans/2026-09-06-workstation-docker-repair-packet.md and obtain separate approval before installing Docker Desktop. Repair does not authorize backup/restore.

Remaining phase order is P3, P4 encrypted restore plus 72-hour dormant soak, P5 Module A production closure, P6 core booking, P7 operations/insight, P8 guest lifecycle, P9 individually approved provider/workflow batches, and P10 operational acceptance. Every production, provider, credential, route, message, order, publication and destructive cleanup remains separately action-time approval-gated.

Preserve the unrelated Task Master files exactly as found. Do not stage, edit, clean or make them a prerequisite:
- .gitignore
- .env.example
- .taskmaster/
- AGENTS.md
- docs/handoff/TASKMASTER.md
- scripts/taskmaster-codex.mjs
- scripts/taskmaster-schema.mjs
- tests/taskmaster/
```
