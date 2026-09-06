# P1 recovery and proposed P2/P3 action packet

Date: 2026-09-06. Source baseline: `b00ae93`, branch `codex/cascade-waves-0-1-sol`.

**Verdict: P1 incomplete; P2/P3 NOT READY FOR APPROVAL.** This is a local preparation packet, not permission to capture production data or change Alfred. No recovery capture, server connection, swap, stack, route, secret, provider or production action was performed for this packet.

## Evidence and unresolved inputs

| Item | Current evidence | Required closure |
| --- | --- | --- |
| Source workflows | 13 inactive exports; historical disposable source round trip | Repeat on the selected replacement image, without provider credentials |
| Alfred recovery | No approved runtime backup/restore evidence | Approved encrypted capture and isolated credential-decryption proof |
| Image | Source pins 2.34.6; rejected for new deployment pending security remediation | Review replacement release, all applicable advisories, registry digest and compatibility |
| Compose | Capped two-service source; example render is syntax evidence only | Private action-time render with independent secrets and reviewed image digest |
| Host | Historical 0 MiB swap; capacity audit is not a fresh baseline | Approved swap action, fresh baseline and peak-load evidence |
| Proxy | Caddy fragment assumes proxy can reach host loopback | Verify proxy topology, Access enforcement, origin bypass denial and log redaction |
| Recovery tooling | Current scripts are partial checks | Resolve gaps below before using them as recovery gates |

## Action-time image review

The official [2.34.6 release](https://github.com/n8n-io/n8n/releases/tag/n8n%402.34.6) is dated August 14. On September 6, the official [latest release](https://github.com/n8n-io/n8n/releases/tag/n8n%402.37.10) is 2.37.10, dated September 4. This establishes a replacement candidate, not compatibility or blanket security approval.

[GHSA-6xcw-7xm6-48c6](https://github.com/n8n-io/n8n/security/advisories/GHSA-6xcw-7xm6-48c6), published September 2, describes a high-severity legacy expression-engine escape, patched in 2.37.7 and other supported lines. The existing 2.34.6 pin must not be treated as a deployment-approved stable release. Do not upgrade Alfred's existing runtime as part of Cascade preparation.

Before selecting the new pin, review the full [official advisory inventory](https://github.com/n8n-io/n8n/security/advisories), record applicable affected/fixed ranges, resolve the registry digest for the host architecture, and run inactive import/export plus capped PostgreSQL startup tests on disposable local resources. The existing source pin is retained as historical recovery input, explicitly blocked for deployment. Do not equate release existence with a verified image pull or runtime test.

## Existing Alfred recovery: next separate approval boundary

Target: Alfred's existing shared n8n only, for an encrypted backup and a local isolated restore. The owner-approved capture must include its actual database engine/version, immutable running image digest, workflow inventory and active-state counts, credential ciphertext, the matching encryption key, required n8n data/binary storage, and deployment configuration. Inventory identifiers and paths before finalizing capture commands; do not assume the existing runtime uses the new stack's PostgreSQL layout.

Store the encrypted archive and manifest outside Git with owner-only access and an off-host copy. Keep recovery identity/key material separately protected. Never print environment inspection, credential plaintext, database URLs, decrypted exports, or production records. Record only timestamps, versions, counts, encrypted artifact checksums, and pass/fail results in source.

Capture consistency must be explicit: a database snapshot alone cannot prove consistency with changing filesystem binary data. If quiescence or stopping the shared service is needed, present that downtime action separately before doing it. Never tar a live database directory as a substitute for an engine-supported backup.

Restore into uniquely named local resources with no host ports, no production mounts and no external egress. Do not start the normal n8n server against restored active workflows. Disable workflow activation in the disposable copy before any server start; prefer CLI-only validation. Verify database integrity, workflow semantic hashes and counts, credential ciphertext counts, and successful credential decryption using the matching key without writing plaintext to logs. If plaintext temporary output is required by the selected CLI, use restricted ephemeral storage inside the isolated target and destroy it before cleanup. Test binary-data references and required configuration. Record exact cleanup identifiers and confirm that Alfred remained unchanged.

Approval scope for this next step: encrypted production-data capture and local isolated restore only. No Alfred restart, upgrade, swap, stack creation, provider call or workflow execution. Final capture commands depend on a read-only topology inventory and the chosen protected artifact destination; these inputs remain unresolved, so a copy-and-run capture command is intentionally not claimed ready.

## Recovery tooling defects to resolve before execution

`infrastructure/cascade-n8n/backup.ps1` and `restore-check.ps1` are new-Cascade candidates, not Alfred recovery tooling. Their present success messages do not close P1 or P4:

- Backup does not explicitly preserve the environment-supplied encryption key/JWT configuration; a data-volume archive is insufficient when the encryption key comes from the environment.
- Backup takes database and volume snapshots separately without a consistency protocol and omits the `./files` bind mount.
- Database/user arguments come from the caller environment, although the Compose environment file is a separate input.
- Restore does not verify the encrypted manifest before decryption, decrypt credentials, compare workflow semantics, or run n8n readiness checks. A queryable workflow table and a `config` file are insufficient proof.
- Restore helpers use default Docker networking, allowing outbound access; production-data recovery requires an isolated network before credentials are restored.
- Helper image availability, runtime prerequisites, and every external process exit status need validation. The host is Linux while these scripts require PowerShell; no PowerShell installation on Alfred is authorized or assumed.

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

P1 may close only when the image/security decision, Alfred encrypted restore, corrected backup/restore implementation, validated private Compose/proxy plan and exact reviewed host commands all have evidence. P2/P3 approval must name the final source commit and action scope. The present document does not satisfy those exits.
