# ADR-002 — Dedicated Hetzner Cascade operations plane

**Status:** Accepted direction; source-only and deployment-gated; revised to conditional Alfred co-location after detailed read-only audit on 2026-09-06

**Supersedes:** the future deployment target in ADR-001 after its migration gates pass

**Current live state:** unchanged

## Decision

Move Cascade automation to its own Compose project when the Module A, capacity, backup, access, and action-time approval gates are closed. The initial budget-conscious target may be Alfred's existing Docker Engine because the detailed audit found stable low load, about 3.2 GiB available RAM, no current unhealthy containers, and no OOM/restart evidence. Use the reviewed candidate under `infrastructure/cascade-n8n/`: one n8n application container, one dedicated PostgreSQL container, Cascade-only networks, volumes, credentials, encryption key, backup set, hostname, and access policy.

“All Cascade operations” means the isolated automation plane and its execution database. Supabase remains the canonical business-state authority. The public booking site and static guides remain on their reviewed hosts, and Google Apps Script remains a narrow legacy integration until separately replaced. Combining those systems into one container would create a second business authority and a single recovery boundary, so it is outside this decision.

## Required topology

- Host: Alfred is permitted only for a capped dormant trial after backup/restore and swap gates pass. A separate Cascade VPS remains the fallback when an abort threshold or isolation trigger is reached.
- Compose project: `cascade-n8n` initially; it may be renamed only through a reviewed source change before deployment.
- Containers: `cascade-n8n-app` and `cascade-n8n-postgres`.
- Editor binding: loopback only; TLS and identity-aware access terminate at the reviewed reverse proxy.
- Data: independent named volumes and encrypted off-host backups with a disposable restore proof.
- Workflows: import the 13 source-controlled exports inactive. Provider nodes and credentials stay disabled until their own approval.
- Authority: n8n may consume signed events and report delivery outcomes. It may not own bookings, payments, calendars, finance, inventory, consent, approvals, or marketing publication.

## Gates before any Hetzner change

1. Close or explicitly re-plan every open Module A gate in `cascade-authority-inventory.json`.
2. Prove Alfred backup/restore, add at least 2 GiB swap through a separate approval, and re-run the detailed capacity audit. Reject co-location if available memory is below 2.5 GiB before startup or any current service is unhealthy/restarting.
3. Approve a Cascade-only DNS name, TLS route, editor access policy, and secret location.
4. Produce encrypted backups for the current automation state and target database, then prove both restores in disposable targets.
5. Review the exact source commit, rendered Compose configuration, target directory, external effects, rollback, smoke test, and abort conditions.
6. Obtain fresh owner approval before creating directories, swap, DNS, secrets, containers, volumes, credentials, imports, provider traffic, or ordering a fallback server.

## Migration sequence after the gates close

1. Run the read-only Alfred baseline and confirm every same-host threshold in `docs/validation/2026-09-06-alfred-detailed-capacity-audit.md`.
2. Render `infrastructure/cascade-n8n/compose.yaml` with owner-only secrets and reject public bindings, unpinned images, shared resource names, or placeholders.
3. Create only the dedicated Cascade directory, networks, volumes, PostgreSQL service, and n8n service.
4. Import source workflows inactive and verify their semantic hashes and Cascade-only credential references.
5. Complete backup/restore, access, health, and no-provider fixture checks.
6. Soak the inactive stack for at least 72 hours and stop only `cascade-n8n` if an abort threshold is reached.
7. Approve each workflow activation and provider connection separately; keep the old delivery path available until verified cutover.
8. Retire an old Cascade path only after evidence shows no pending executions or rollback dependency.

## Rollback boundary

Stop only the new Cascade Compose project, revert only its new proxy/DNS route, and preserve its encrypted backups. Never modify or delete another project’s containers, networks, volumes, credentials, or database. Volume deletion is a separate destructive action and is not part of routine rollback.

No Hetzner, Docker, DNS, provider, production, or workflow change was made by accepting this direction.
