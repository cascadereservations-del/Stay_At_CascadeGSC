# P1 recovery and proposed P2/P3 action packet

Date: 2026-09-06. Continuation baseline: `ba19507`, branch `codex/cascade-waves-0-1-sol`.

**Verdict: local P1 work complete; Alfred recovery proof remains open; P2/P3 NOT READY FOR APPROVAL.** This is a local preparation packet, not permission to capture production data or change Alfred. No Alfred connection, production recovery capture, swap, stack, route, provider or production action was performed for this packet.

## Evidence and unresolved inputs

| Item | Current evidence | Required closure |
| --- | --- | --- |
| Source workflows | 13 inactive exports round-tripped on 2.37.10 with semantic hash `d3077384d1bc...` | Complete locally |
| Alfred recovery | No approved runtime backup/restore evidence | Approved encrypted capture and isolated credential-decryption proof |
| Image | 2.37.10 selected; official affected/fixed ranges reviewed; local amd64 digest and workflow compatibility proven | Recheck advisories and host-architecture digest at action time |
| Compose | Hardened capped two-service candidate starts healthy locally; encrypted synthetic restore passes | Private action-time render with independent secrets |
| Host | Historical 0 MiB swap; capacity audit is not a fresh baseline | Approved swap action, fresh baseline and peak-load evidence |
| Proxy | Caddy fragment assumes proxy can reach host loopback | Verify proxy topology, Access enforcement, origin bypass denial and log redaction |
| Recovery tooling | Quiesced encrypted capture and isolated restore scripts pass with 13 workflows and one synthetic credential | Alfred uses its separate observed-topology procedure |

## Action-time image review

The official [2.34.6 release](https://github.com/n8n-io/n8n/releases/tag/n8n%402.34.6) is dated August 14. On September 6, the official [latest release](https://github.com/n8n-io/n8n/releases/tag/n8n%402.37.10) is 2.37.10, dated September 4. This establishes a replacement candidate, not compatibility or blanket security approval.

[GHSA-6xcw-7xm6-48c6](https://github.com/n8n-io/n8n/security/advisories/GHSA-6xcw-7xm6-48c6), published September 2, describes a high-severity legacy expression-engine escape, patched in 2.37.7 and other supported lines. The existing 2.34.6 pin must not be treated as a deployment-approved stable release. Do not upgrade Alfred's existing runtime as part of Cascade preparation.

The selected candidate is n8n 2.37.10. The official September 2–3 advisories reviewed for the 2.37 line identify 2.37.7 or later as patched. Local `linux/amd64` validation resolved `n8nio/n8n@sha256:307d6065be25619aa24cfc63a7c2f04ca56d084a08c05c8e9f189a89f353b1ec`, round-tripped all 13 workflows inactive with semantic hash `d3077384d1bca5cf6d9941eb1a104183c3348f964ebba49741baf6436c4cd8ce`, and started the capped PostgreSQL/n8n pair healthy with zero restarts. Recheck the official advisory inventory and resolve the target-host digest immediately before P3.

## Existing Alfred recovery: next separate approval boundary

Target: Alfred's existing shared n8n only, for an encrypted backup and a local isolated restore. The owner-approved capture must include its actual database engine/version, immutable running image digest, workflow inventory and active-state counts, credential ciphertext, the matching encryption key, required n8n data/binary storage, and deployment configuration. Inventory identifiers and paths before finalizing capture commands; do not assume the existing runtime uses the new stack's PostgreSQL layout.

Store the encrypted archive and manifest outside Git with owner-only access and an off-host copy. Keep recovery identity/key material separately protected. Never print environment inspection, credential plaintext, database URLs, decrypted exports, or production records. Record only timestamps, versions, counts, encrypted artifact checksums, and pass/fail results in source.

Capture consistency must be explicit: a database snapshot alone cannot prove consistency with changing filesystem binary data. If quiescence or stopping the shared service is needed, present that downtime action separately before doing it. Never tar a live database directory as a substitute for an engine-supported backup.

Restore into uniquely named local resources with no host ports, no production mounts and no external egress. Do not start the normal n8n server against restored active workflows. Disable workflow activation in the disposable copy before any server start; prefer CLI-only validation. Verify database integrity, workflow semantic hashes and counts, credential ciphertext counts, and successful credential decryption using the matching key without writing plaintext to logs. If plaintext temporary output is required by the selected CLI, use restricted ephemeral storage inside the isolated target and destroy it before cleanup. Test binary-data references and required configuration. Record exact cleanup identifiers and confirm that Alfred remained unchanged.

Approval scope for this next step: encrypted production-data capture and local isolated restore only. No Alfred restart, upgrade, swap, stack creation, provider call or workflow execution. Final capture commands depend on a read-only topology inventory and the chosen protected artifact destination; these inputs remain unresolved, so a copy-and-run capture command is intentionally not claimed ready.

## Recovery tooling closure

`infrastructure/cascade-n8n/backup.ps1` and `restore-check.ps1` are verified candidates for the new Cascade stack; they do not back up Alfred's existing shared runtime. The local proof used n8n 2.37.10, PostgreSQL 17.11, 13 inactive workflows, one synthetic encrypted credential, a temporary age identity and no provider access. It proved:

- explicit `-Quiesce`, with restart only when the script stopped n8n;
- an engine-supported database dump plus n8n data, `files`, environment/key escrow and metadata artifacts;
- ciphertext checksums and `INCOMPLETE`/`COMPLETE` markers;
- a uniquely prefixed Docker-internal restore with no published port;
- restored workflow, active-workflow and credential counts matching captured metadata;
- successful workflow export and successful decrypted credential export inside ephemeral container storage;
- cleanup of the exact disposable containers, volumes, network, plaintext and temporary identity.

The selected host has no assumed PowerShell dependency. Alfred's existing runtime follows [its observed-topology recovery procedure](../runbooks/alfred-existing-n8n-recovery.md); exact capture commands are finalized after its approved read-only inventory.

## Proposed P2: host protection

Entry: successful Alfred recovery report, approved exact swap-file path and filesystem allocation method, and an explicit maintenance approval. Proposed new path: `/swapfile-cascade`; reject an existing file, symlink or existing fstab entry. Confirm filesystem support before selecting allocation commands. No package installation or Docker restart is included.

Proposed sequence: create a dedicated 2 GiB swap file with root ownership/mode 0600, initialize only that file, enable it, then add exactly its reviewed fstab entry after a successful check. Preserve the prior fstab for comparison. The final shell commands must be reviewed against the actual filesystem; this document does not authorize them.

Repeat read-only `free -b`, `swapon --show --bytes`, `df -B1 / /opt`, `/proc/loadavg`, and narrowly formatted Docker health/restart/OOM/limits checks. Compare existing container IDs and restart counts with the immediate pre-action baseline. Reject startup below 2.5 GiB available RAM, below 2 GiB swap, below 15 GiB disk, or on an existing service health/restart regression. Confirm no port 5679 listener or collision with `/opt/cascade/n8n` and the named Compose resources.

Rollback: retain the new swap while memory is pressured. Swap removal requires sufficient RAM and separate approval; never run global `swapoff -a`. If approved and safe, disable only `/swapfile-cascade`, remove only its exact added fstab line, then remove only the validated dedicated file. Do not overwrite unrelated fstab changes.

## Proposed P3: dormant isolated stack

Entry: P1 and P2 evidence, replacement image tests, exact approved hostname/access route, secret custody, and separate action approval. P3/P4 are infrastructure-only prerequisites; Module A must close before business delivery or feature release.

Target directory `/opt/cascade/n8n`; Compose project `cascade-n8n`; containers `cascade-n8n-app` and `cascade-n8n-postgres`; volumes `cascade_n8n_data` and `cascade_n8n_postgres_data`; networks `cascade_n8n_internal` and `cascade_n8n_egress`. Keep the existing 1536/768 MiB and 1.5/0.75 CPU ceilings. Only `127.0.0.1:5679` may be published; PostgreSQL has no host port.

Use Portainer CE's existing Docker endpoint to manage the reviewed source. Verify how that endpoint resolves the `./files` bind mount before creation; do not assume Portainer's working directory equals `/opt/cascade/n8n`. Keep one stack owner and avoid concurrent CLI/Portainer configuration edits.

Generate independent DB password, encryption key and JWT secret into owner-only storage outside Git; no provider credentials. Escrow encrypted recovery configuration separately from data archives. Render real configuration privately; never paste resolved secrets into approval text or logs. Run the following only against the reviewed files (rendering itself does not start anything):

```text
docker-compose --project-name cascade-n8n --env-file /opt/cascade/n8n/.env -f /opt/cascade/n8n/compose.yaml config --quiet
```

A private inspection must additionally reject example secrets, unreviewed image tags, shared resources and public bindings. Portainer creation/start remains held until this packet's missing inputs are closed.

The proposed editor hostname is `cascade-n8n.rocloyd.com`. Verify whether Caddy runs on the host or in a container: a container's 127.0.0.1 is not host loopback. The current fragment alone does not enforce Cloudflare Access or block direct-origin access. Validate the complete merged Caddy configuration, redact the entire request URI until query filtering is proven, and prove anonymous/editor/origin-bypass denial before exposure. Determine proxy hop count from the actual route. Dormant operation needs no provider service token or webhook bypass.

Start PostgreSQL, wait for health, then n8n through the approved Portainer stack procedure. Enroll named owner MFA before any provider configuration. Import the 13 source exports inactive with no credentials, then re-export and compare semantic hashes. Do not manually execute provider nodes during smoke tests.

## Exact smoke observations and abort response

Inspect only `State.Health.Status`, `State.OOMKilled`, `RestartCount`, memory/CPU limits and port bindings for the two named Cascade containers. Check `/healthz` and `/healthz/readiness` from host loopback for the chosen release. Confirm PostgreSQL health, protected editor access, zero provider credentials, zero active workflows, and 13 matching source exports. Never log complete Docker inspect output.

Observe for at least 72 hours after successful start. Proposed sampling interval: 60 seconds, stored outside Git. Define sustained low RAM as three consecutive samples below 1.5 GiB and growing swap as five consecutive increases; review these operational definitions before activation. Abort immediately on existing-service restart/OOM/unhealthy state, free disk below 15 GiB, 15-minute load average above 3, unexpected workflow activation, provider traffic or exposed editor. Missing samples do not prove a successful soak; extend the observation window.

The proposed approved incident stop command is:

```text
docker-compose --project-name cascade-n8n --env-file /opt/cascade/n8n/.env -f /opt/cascade/n8n/compose.yaml stop n8n postgres
```

Before execution verify the file's project and container names against this packet. Disable only the new route through the approved proxy rollback procedure and preserve encrypted backups and volumes. Never use `down -v`, broad pruning, shared-service restarts, or automatic swap removal. Any fallback VPS purchase requires separate approval.

## Exit record

The image/security decision, new-stack recovery tooling and local capped-stack proof are complete. P1 closes only when Alfred's encrypted restore and actual proxy/storage topology have dated evidence through the dedicated procedure. P2/P3 approval must name the final source commit and action scope. The present packet does not satisfy that remaining live-runtime exit.
