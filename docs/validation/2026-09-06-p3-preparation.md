# P3 dormant-stack preparation — 2026-09-06

Status: local/source preparation PASS; no P3 resource created. Fresh P3 action approval remains required.

The source candidate now pins the target Linux/amd64 manifests for n8n 2.37.10 and PostgreSQL 17.11, keeps both resource ceilings, binds only n8n to host loopback, and uses an absolute `/opt/cascade/n8n/files` host path so Portainer CE does not reinterpret a relative bind. Dormant configuration defaults to localhost HTTP behind an owner SSH tunnel with zero trusted proxy hops. The existing future Caddy fragment is not part of P3.

Read-only Alfred checks found Docker 29.5.3, Compose 5.1.4 and Portainer CE 2.45.0 on the local Docker socket. Portainer's current public route remains the existing service. Cloudflared has routes for existing services including the original Alfred n8n, but no Cascade n8n route. P2 swap remained active and unused; 3,148,193,792 bytes RAM and 33,854,255,104 bytes disk were available at 06:13 UTC with low load.

Registry inspection on Alfred resolved:

- n8n 2.37.10 multi-platform digest `sha256:307d6065be25619aa24cfc63a7c2f04ca56d084a08c05c8e9f189a89f353b1ec` and Linux/amd64 manifest `sha256:848166b4051fd4251869f48c18455bddff922f04cb2f2676929463ba973dbde2`;
- PostgreSQL 17.11 Alpine 3.24 multi-platform digest `sha256:18cfe3ef5e6815560c98237d6216d1e5119702fb0f3894c8785dd58b8bbe5d73` and Linux/amd64 manifest `sha256:7456ef82e5f5bc43d997f4781bbd7c0d6389bff397564649a356e206ba473aee`.

The official GitHub release page identifies n8n 2.37.10 as the 2026-09-04 stable/latest release. The September 2 security bulletin identifies 2.37.7 or later as patched on this release line. The immutable target still requires action-time drift verification.

Focused validation passed 13/13 infrastructure and consolidation tests, all 13 source workflows remain inactive, the secret scan passed, the source diff passed whitespace checks, and Alfred's Compose parser accepted the candidate with validation-only placeholders. The local Docker client could not run Compose because the workstation Docker runtime remains broken; the successful Alfred parse did not create a remote file, image, network, volume or container.

The exact proposed action, acceptance criteria and rollback boundary are in [the P3 packet](../plans/2026-09-06-p3-dormant-stack-action-packet.md). Named-owner account creation and TOTP enrollment remain interactive owner steps; no identity values or recovery material may enter Git or chat.
