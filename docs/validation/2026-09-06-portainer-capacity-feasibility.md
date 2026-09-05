# Portainer capacity and isolation feasibility — 2026-09-06

Status: read-only review complete; its conservative host-placement conclusion was superseded by the detailed capacity audit later on 2026-09-06. Alfred was not changed. No stack, container, volume, network, provider, workflow, DNS record, swap file, or server was created or modified.

See `2026-09-06-alfred-detailed-capacity-audit.md` for live Docker statistics, limits, health, restart/OOM history, and the resulting conditional same-host decision.

## Safe observations

The Portainer environment reports 4 CPU cores, 8.1 GB RAM, 29 containers in total, and 19 running containers. The existing n8n service is part of Alfred's `deploy` Compose project and is connected to `alfred_internal`. It uses SQLite in its own n8n data volume and also mounts Alfred/LifeVault files from the host. Its editor port is bound to loopback.

The deployed n8n image is configured with the mutable `latest` tag. Portainer resolved the currently running image to n8n 2.37.10, but a later recreate could select a different release. No explicit CPU or memory limit was visible in the reviewed container details; confirm that point from a redacted Docker inspect before any Alfred maintenance.

Several stopped AppFlowy containers display exit code 137. That code is consistent with a forced termination and can occur during out-of-memory termination, but the Portainer list alone does not prove the cause. It is enough to reject an assumption that the host has risk-free spare capacity.

Portainer administrators can view the existing n8n encryption-key environment setting. The value was not copied or recorded. Preserve the current key for Alfred recovery; changing it without a credential-migration procedure can make existing n8n credentials unreadable. A future Cascade instance must use a separate key.

## Feasibility decision

Do not add swap or deploy the Cascade n8n/PostgreSQL stack on Alfred. Swap could reduce abrupt memory pressure, but it would not create independent CPU, RAM, storage I/O, failure, maintenance, or recovery boundaries. The existing n8n service is coupled to Alfred's Compose project, network, SQLite volume, and LifeVault host files, so co-location would increase the blast radius for both projects.

The feasible target is a separate Hetzner Cloud server with its own Docker Engine and a Cascade-only Compose project. The reviewed source stack requires up to 2.25 GB across n8n and PostgreSQL before the operating system, reverse proxy, backups, and growth. Four GB RAM is the minimum; 8 GB provides the preferred operating margin and room for future Cascade-only services.

Current Hetzner material checked on 2026-09-06 lists these representative choices, excluding VAT and Primary IP charges:

| Location / plan | Resources | Published monthly price | Use |
| --- | --- | ---: | --- |
| Europe CX23 | 2 shared vCPU, 4 GB RAM, 40 GB disk | €5.49 | Minimum isolated n8n/PostgreSQL target; limited growth margin. |
| Europe CX33 | 4 shared vCPU, 8 GB RAM, 80 GB disk | €8.49 | Recommended value target for Cascade automation. |
| Singapore CPX22 | 2 shared vCPU, 4 GB RAM, 80 GB disk | $30.99 | Lower regional latency, minimum memory. |
| Singapore CPX32 | 4 shared vCPU, 8 GB RAM, 160 GB disk | $57.99 | Lower regional latency with preferred headroom. |

Official references:

- Hetzner pricing and shared/dedicated guidance: https://www.hetzner.com/cloud/pricing/
- Hetzner 15 June 2026 price adjustment: https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/
- Hetzner Cloud server and Primary IP overview: https://docs.hetzner.com/cloud/servers/overview/
- Hetzner backup pricing: https://docs.hetzner.com/cloud/billing/faq/

For Cascade's asynchronous automation role, Europe CX33 is the recommended cost/capacity baseline unless a measured end-to-end latency test justifies Singapore's higher price. Supabase remains the canonical business-state authority, so n8n latency must not become part of the booking/payment decision transaction.

## Safe migration sequence

1. Preserve Alfred unchanged and complete its independent backup/restore evidence.
2. Review and approve the exact new-server order, region, monthly cost, Primary IP, firewall, SSH access, and recovery owner.
3. Provision the new server only after that action-time approval; install Docker and create swap on the new server, not Alfred.
4. Deploy the Cascade-only n8n/PostgreSQL Compose project with exact reviewed image digests, resource limits, loopback binding, independent secrets, networks, volumes, and encrypted off-host backups.
5. Import the 13 source-controlled workflows inactive, verify semantic hashes and credential bindings, and run fixtures with provider nodes disabled.
6. Complete restore, access, health, and no-provider proofs.
7. Activate each workflow and provider connection only through its separate approval gate after Module A is closed.

The public booking site, static guides, Google Apps Script integrations, and Supabase do not move into this Docker project under this plan. “Cascade operations” means the isolated automation plane and its execution database, not a second canonical business database or a single container containing every product.
