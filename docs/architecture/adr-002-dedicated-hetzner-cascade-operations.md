# ADR-002 — Dedicated Hetzner Cascade operations plane

**Status:** Accepted direction; source-only and deployment-gated; revised to a separate server after read-only Portainer review on 2026-09-06

**Supersedes:** the future deployment target in ADR-001 after its migration gates pass

**Current live state:** unchanged

## Decision

Move Cascade automation to its own Hetzner Cloud server and Compose project when the Module A, capacity, backup, access, procurement, and action-time approval gates are closed. Do not place the new stack on Alfred. Use the existing reviewed candidate under `infrastructure/cascade-n8n/`: one n8n application container, one dedicated PostgreSQL container, Cascade-only networks, volumes, credentials, encryption key, backup set, hostname, and access policy.

“All Cascade operations” means the isolated automation plane and its execution database. Supabase remains the canonical business-state authority. The public booking site and static guides remain on their reviewed hosts, and Google Apps Script remains a narrow legacy integration until separately replaced. Combining those systems into one container would create a second business authority and a single recovery boundary, so it is outside this decision.

## Required topology

- Host: a separate Cascade VPS with its own Docker Engine, operating resources, swap, firewall, maintenance window, and recovery boundary. Alfred is not the deployment target.
- Compose project: `cascade-n8n` initially; it may be renamed only through a reviewed source change before deployment.
- Containers: `cascade-n8n-app` and `cascade-n8n-postgres`.
- Editor binding: loopback only; TLS and identity-aware access terminate at the reviewed reverse proxy.
- Data: independent named volumes and encrypted off-host backups with a disposable restore proof.
- Workflows: import the 13 source-controlled exports inactive. Provider nodes and credentials stay disabled until their own approval.
- Authority: n8n may consume signed events and report delivery outcomes. It may not own bookings, payments, calendars, finance, inventory, consent, approvals, or marketing publication.

## Gates before any Hetzner change

1. Close or explicitly re-plan every open Module A gate in `cascade-authority-inventory.json`.
2. Approve the exact separate-VPS region, plan, monthly cost, Primary IP, firewall, owner, and recovery design. The Alfred preflight and Portainer review reject co-location.
3. Approve a Cascade-only DNS name, TLS route, editor access policy, and secret location.
4. Produce encrypted backups for the current automation state and target database, then prove both restores in disposable targets.
5. Review the exact source commit, rendered Compose configuration, target directory, external effects, rollback, smoke test, and abort conditions.
6. Obtain fresh owner approval before ordering a server or creating directories, swap, DNS, secrets, containers, volumes, credentials, imports, or provider traffic.

## Migration sequence after the gates close

1. Provision the separately approved Cascade server and run a read-only baseline inventory before placing application state on it.
2. Render `infrastructure/cascade-n8n/compose.yaml` with owner-only secrets and reject public bindings, unpinned images, shared resource names, or placeholders.
3. Create only the dedicated Cascade directory, networks, volumes, PostgreSQL service, and n8n service.
4. Import source workflows inactive and verify their semantic hashes and Cascade-only credential references.
5. Complete backup/restore, access, health, and no-provider fixture checks.
6. Approve each workflow activation and provider connection separately; keep the old delivery path available until verified cutover.
7. Retire an old Cascade path only after evidence shows no pending executions or rollback dependency.

## Rollback boundary

Stop only the new Cascade Compose project, revert only its new proxy/DNS route, and preserve its encrypted backups. Never modify or delete another project’s containers, networks, volumes, credentials, or database. Volume deletion is a separate destructive action and is not part of routine rollback.

No Hetzner, Docker, DNS, provider, production, or workflow change was made by accepting this direction.
