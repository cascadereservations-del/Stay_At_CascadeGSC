# P3 dormant Cascade stack action packet

Status: prepared locally; not executed. P1 and P2 pass. This packet requires fresh owner approval naming its final commit before any P3 mutation.

## Exact scope

Create one Portainer CE stack named `cascade-n8n` on Alfred's existing Docker endpoint from the reviewed Compose file. It creates only:

- host directory `/opt/cascade/n8n` with owner-only environment material, the reviewed source files and a `files/workflows` import directory;
- containers `cascade-n8n-postgres` and `cascade-n8n-app`;
- volumes `cascade_n8n_postgres_data` and `cascade_n8n_data`;
- networks `cascade_n8n_internal` and `cascade_n8n_egress`;
- a local owner-controlled P3 environment file and a dedicated age recovery identity outside Git.

The PostgreSQL and n8n ceilings remain 768 MiB / 0.75 CPU and 1536 MiB / 1.5 CPU. PostgreSQL publishes no host port. n8n publishes only `127.0.0.1:5679`. The dormant editor uses an owner SSH tunnel to `http://localhost:5679`; no DNS, Cloudflare route, public hostname, provider credential, webhook exception or service token is created in P3. The existing `n8n.rocloyd.com` route and Alfred n8n remain unchanged.

All 13 source workflows are imported inactive with no credentials. They are not manually executed. The first named owner account and its n8n MFA must be completed interactively before P3 can pass. P3 does not activate a workflow, send a message, change Supabase, or release any business feature.

## Reviewed source and images

The action must name the final packet commit. Its Compose file pins the Linux/amd64 manifests:

- `n8nio/n8n:2.37.10@sha256:848166b4051fd4251869f48c18455bddff922f04cb2f2676929463ba973dbde2`
- `postgres:17.11-alpine3.24@sha256:7456ef82e5f5bc43d997f4781bbd7c0d6389bff397564649a356e206ba473aee`

The multi-platform n8n tag resolves to `sha256:307d6065be25619aa24cfc63a7c2f04ca56d084a08c05c8e9f189a89f353b1ec`, matching P1. The 2026-09-04 GitHub release identifies 2.37.10 as stable/latest. The 2026-09-02 n8n security bulletin requires 2.37.7 or later on this line. Re-resolve both manifests immediately before creation and stop on drift. Sources: `https://github.com/n8n-io/n8n/releases/tag/n8n%402.37.10` and `https://community.n8n.io/t/security-update-02-september-2026/310852`.

The absolute `/opt/cascade/n8n/files:/files` bind removes Portainer CE relative-path ambiguity. Portainer 2.45.0 is already running on the local Docker socket. The stack is uploaded through Portainer's existing authenticated UI with its environment file; no Git credential, webhook or auto-update is enabled.

## Entry checks

Immediately before mutation, record UTC time, RAM/swap/disk/load, and the name, full ID, start time, health, restart count, OOM flag and limits of every running container. Require at least 2.5 GiB available RAM, at least 2 GiB active swap, at least 15 GiB free disk, low stable load, no unhealthy/restarting service, and the existing n8n health endpoint passing.

Reject any listener on port 5679, existing target path or symlink, matching container/network/volume/Compose name, changed image manifest, placeholder value, non-loopback published port, missing resource ceiling, or source workflow that is active. Render the real Compose configuration privately and do not emit the resolved environment or Docker inspect environment.

## Secret and source preparation

After approval, run `node scripts/deployment/p3-environment.mjs --output C:\Users\Lloyd\Cascade-Secrets\cascade-n8n-portainer.env`. It uses independent cryptographic random values, refuses relative/repository paths and refuses overwrite without printing any value. Then disable ACL inheritance and grant only the owner full control. Create a separate age identity at `C:\Users\Lloyd\Cascade-Secrets\cascade-n8n-recovery-age.txt` with the same ACL and store its public recipient separately. Do not reuse Alfred's existing n8n encryption key, credentials or database password.

Create `/opt/cascade/n8n` only after collision checks. Use root ownership and mode 0700 for the directory, 0600 for `.env`, and 0750 for `files` and `files/workflows`. Copy only the reviewed Compose, recovery scripts and 13 source workflow JSON files. Store SHA-256 values for copied non-secret files and compare them with the approved local source. Do not print or copy secret contents into evidence.

Use the owner-only local environment file for Portainer's **Load variables from .env file** control and preserve the matching root-only copy at `/opt/cascade/n8n/.env` for recovery tooling. Upload the reviewed Compose file, name the stack exactly `cascade-n8n`, disable stack webhooks and GitOps, select no private registry, then deploy once. Compose health dependency starts n8n only after PostgreSQL becomes healthy.

## Import and acceptance

After both services are healthy and stable, import only `/files/workflows/*.json` with n8n CLI `import:workflow --separate --input=/files/workflows --activeState=false`. Query only aggregate counts: require 13 workflows, zero active workflows and zero credentials. Export workflows to an owner-only temporary directory, compare normalized source semantics with `scripts/recovery/recovery-contract.mjs`, and require the P1 semantic hash `d3077384d1bca5cf6d9941eb1a104183c3348f964ebba49741baf6436c4cd8ce`. Remove only that validated temporary export after comparison.

Open an SSH tunnel from the owner workstation to Alfred's loopback port. The owner creates the first named n8n account, enrolls TOTP MFA personally, signs out, signs in with MFA, and confirms the editor still shows 13 inactive workflows and no credentials. Do not record the email, password, TOTP seed, recovery code, cookie or user ID in Git, terminal output or chat.

Repeat the full host/container baseline. P3 passes only if:

- both Cascade services remain healthy with zero restarts/OOM flags and exact caps;
- every pre-existing container retains its full ID, start time, restart count and OOM state;
- available RAM is at least 1.5 GiB at each post-start sample, swap does not grow continuously, 15-minute load is at most 3, and disk remains above 15 GiB;
- port 5679 is bound only to 127.0.0.1; PostgreSQL has no published port;
- only the six named Cascade resources and approved target files were created;
- 13 workflows are inactive, credential count is zero, semantic hash matches, and named-owner MFA is proven;
- the existing Alfred n8n health endpoint still passes.

P3 evidence starts the P4 clock but does not satisfy the 72-hour soak.

## Abort and rollback boundary

On any threshold breach, unexpected provider traffic/credential/workflow activation, public editor exposure, existing-service change, checksum mismatch or auth failure, stop only `cascade-n8n-app` and `cascade-n8n-postgres`. Preserve logs, environment escrow, volumes and source for diagnosis. Do not use `down -v`, prune, remove swap, restart Docker, modify the existing n8n, or alter Cloudflare/DNS.

Removing the Portainer stack, containers, networks, volumes, host directory, local secret files or recovery identity is destructive cleanup and needs a separate reviewed decision. A fallback VPS purchase also remains separately approved.

References: [P2 evidence](../validation/2026-09-06-p2-host-maintenance.md), [P1 recovery proof](../validation/2026-09-06-p1-alfred-recovery.md), [deployment runbook](../runbooks/cascade-n8n-deploy.md), and the [completion plan](2026-09-06-portainer-n8n-completion-plan.md).
