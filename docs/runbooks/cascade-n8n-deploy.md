# Cascade n8n Deployment Runbook

This runbook defines the selected new Cascade-only n8n service under `/opt/cascade/n8n`, managed through Alfred's existing Portainer CE and Docker Engine only after the detailed same-host gates pass. Do not add a second Docker daemon. The stack never reuses the existing n8n container, database, user, encryption key, volume, network, credentials, project/folder, hostname or backup set.

For the P3 dormant trial, keep the editor loopback-only and reach it through an owner SSH tunnel at `http://localhost:5679`. Do not create DNS, Cloudflare, Caddy, webhook bypass or a public hostname in P3. The source Caddy fragment remains a later reviewed candidate for P9 provider delivery. P3 still requires a named n8n owner and personally enrolled MFA before acceptance.

The isolated Cascade candidate pins n8n 2.37.10. The September 6 review found the historical 2.34.6 pin within affected ranges for newly published advisories; official advisories identify 2.37.7 or later on that release line as patched. See the [P1 recovery/action packet](../plans/2026-09-06-p1-recovery-action-packet.md) for official sources and validation evidence. Recheck releases and advisories at action time. Do not upgrade Alfred's existing n8n as part of this deployment. n8n is fair-code under its Sustainable Use License; it is not described as OSI open source.

The 2026-09-05 SSH preflight found 3,224 MiB available RAM and 0 MiB swap on Alfred. A more detailed 2026-09-06 audit found 3,196–3,209 MiB available across repeated samples, load below 0.3 on four cores, 36 GB free disk, no current unhealthy container, no running-container restart/OOM flag, no kernel/Docker OOM evidence, and no active Ollama model. It also found Metabase consistently using about 1.459 GiB of its 1.5 GiB limit. See `docs/validation/2026-09-06-alfred-detailed-capacity-audit.md`.

P1 recovery and image gates passed on 2026-09-06. The same-host stack remains source-only until Alfred has at least 2 GiB swap, the fresh baseline meets every threshold, and P2/P3 receive action-time approval. P3/P4 permit only a dormant infrastructure trial; Module A must close before business delivery or feature release. A separate 8 GB Cascade VPS remains the fallback if the dormant trial crosses an abort threshold.

## Read-only capacity preflight

Run these checks without changing the VPS:

```text
free -h
swapon --show
df -h / /opt
ss -ltnp
docker ps --format <reviewed-fields-only>
docker system df
```

Stop before deployment unless all gates pass:

- At least 2.5 GiB RAM remains available during normal peak load.
- At least 15 GiB free disk remains, including after projected images, database growth and two encrypted backups.
- At least 2 GiB swap exists on the selected host. Adding it to Alfred is a separate maintenance action and is not authorized by this runbook.
- Local port 5679 and the proposed hostname are unused.
- Existing services are healthy and their container/network/volume names do not begin with `cascade-n8n`.
- An external encrypted backup destination and an age recovery identity are available.

Record timestamped output in the Wave 0 recovery report, redacting public IPs, usernames and container environment details.

## Approval gates

Fresh owner approval is required before each of these actions:

1. Creating `/opt/cascade/n8n`, changing host packages/swap, or ordering a fallback VPS.
2. Creating DNS, Cloudflare Access/service-token policy or TLS routing for `cascade-n8n.rocloyd.com`.
3. Copying real `.env` secrets or OAuth/provider credentials.
4. Starting containers, importing workflows, sending provider test messages or activating a workflow.

Source construction and syntax validation do not authorize those actions.

## Prepare the isolated directory

Copy only the reviewed files from `infrastructure/cascade-n8n` into `/opt/cascade/n8n`. Create `files/` and a real `.env` owned by the deployment account with mode 0600. Generate independent random values for the database password, n8n encryption key and user-management JWT secret. Never copy secrets from Personal, Alfred or Alex.

Validate the rendered configuration before starting:

```text
docker-compose --env-file .env -f compose.yaml config
```

Reject output containing an unbound public port, an unpinned image, a non-Cascade resource name or a `replace-with` value.

## Deploy and validate

After owner approval, start PostgreSQL first, confirm its health, then start n8n. Confirm both containers stay within the declared memory/CPU ceilings and that n8n is reachable only at `127.0.0.1:5679` from the VPS.

For an Alfred trial, keep all workflows inactive and omit real provider credentials for at least 72 hours. Stop only the `cascade-n8n` project if available memory remains below 1.5 GiB, swap use rises continuously, 15-minute load exceeds 3, an existing service restarts/OOMs, or free disk falls below 15 GB.

The two-service dormant trial uses n8n's internal JavaScript runner and must not execute Code nodes. Every current Cascade workflow contains a JavaScript Code node. Before any P9 workflow activation, add and capacity-test a version-matched external runner sidecar or record a new reviewed architecture decision; n8n's official guidance does not recommend internal runners for production.

When a later provider phase requires the public route, install the Caddy fragment only after its syntax check passes. Configure Cloudflare so the editor requires owner/admin identity. Create a separate scoped service token for signed webhook traffic; never share an interactive login credential. Do not log Authorization, Cookie or query-string values.

Create named n8n users and enable MFA for owner/admin identities before connecting provider credentials.

## Import inactive

Export a backup of the source workflows first. Import Cascade workflow JSON files inactive. Reload each workflow canvas, verify credential bindings refer only to Cascade credentials, and run fixture executions with provider nodes disabled. Activating any workflow or sending a real Telegram/email/calendar event requires owner approval after the fixture report is reviewed.

## Backup and restore proof

Set `CASCADE_BACKUP_DIR` to an absolute path outside the repository and `AGE_RECIPIENT` to the offline recovery public key. Run `backup.ps1 -Quiesce` only in an approved maintenance action, copy the complete encrypted set off-host, then run `restore-check.ps1` from an owner-controlled workstation with `AGE_IDENTITY_FILE`. The scripts passed a local synthetic encrypted round trip with 13 inactive workflows and one credential-decryption proof. Production acceptance still requires protected key custody, the off-host copy, and dated evidence. These scripts target the new Cascade stack; use the separate [Alfred existing-n8n procedure](./alfred-existing-n8n-recovery.md) for the shared runtime.

## Rollback

If health, authentication, routing or fixture checks fail:

1. Disable only newly activated Cascade workflows.
2. Stop only the `cascade-n8n` Compose project.
3. Remove only the new Cascade Caddy fragment and restore the previously validated Caddy configuration.
4. Leave encrypted backups intact and record the failure reason.
5. Do not delete or modify the existing n8n service, its volumes, credentials, database, network or workflows.

DNS rollback and container removal remain owner-approved actions. Volume deletion is not part of routine rollback.
