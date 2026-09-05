# Cascade n8n Deployment Runbook

This runbook defines a new Cascade-only n8n service under `/opt/cascade/n8n` on a separate Cascade VPS. It must not be deployed on Alfred and does not reuse the existing n8n container, database, user, encryption key, volume, network, credentials, project/folder, hostname or backup set.

The configuration pins n8n 2.34.6, the stable line observed in August 2026. The newer 2.35.x line was still used as a beta in contemporary reports and has scheduler/tool-call issue reports. Review the official release and security notes again before any upgrade. n8n is fair-code under its Sustainable Use License; it is not described as OSI open source.

The 2026-09-05 SSH preflight found 3,224 MiB available RAM and 0 MiB swap on Alfred. The 2026-09-06 Portainer review then found a busy 8.1 GB host with 19 running containers and an n8n service coupled to Alfred's Compose project, network, SQLite volume, and LifeVault host files. The deployment gate therefore fails for co-location, even if swap were added. See `docs/validation/2026-09-05-hetzner-read-only-preflight.md` and `docs/validation/2026-09-06-portainer-capacity-feasibility.md`.

Run the remaining capacity checks against the separately approved Cascade VPS. The stack remains source-only until that server exists, has at least 4 GB RAM and 2 GB swap, and every Module A and migration gate is closed. An 8 GB server is preferred for operating margin and future Cascade-only services.

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
- At least 10 GiB free disk remains after projected images, database growth and two encrypted backups.
- At least 2 GiB swap exists on the new Cascade VPS. Do not add swap to Alfred as part of this migration.
- Local port 5679 and the proposed hostname are unused.
- Existing services are healthy and their container/network/volume names do not begin with `cascade-n8n`.
- An external encrypted backup destination and an age recovery identity are available.

Record timestamped output in the Wave 0 recovery report, redacting public IPs, usernames and container environment details.

## Approval gates

Fresh owner approval is required before each of these actions:

1. Ordering the separate VPS, creating `/opt/cascade/n8n`, or changing its packages/swap.
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

Install the Caddy fragment only after its syntax check passes. Configure Cloudflare so the editor requires owner/admin identity. Create a separate scoped service token for signed webhook traffic; never share an interactive login credential. Do not log Authorization, Cookie or query-string values.

Create named n8n users and enable MFA for owner/admin identities before connecting provider credentials.

## Import inactive

Export a backup of the source workflows first. Import Cascade workflow JSON files inactive. Reload each workflow canvas, verify credential bindings refer only to Cascade credentials, and run fixture executions with provider nodes disabled. Activating any workflow or sending a real Telegram/email/calendar event requires owner approval after the fixture report is reviewed.

## Backup and restore proof

Set `CASCADE_BACKUP_DIR` to an absolute path outside the repository and `AGE_RECIPIENT` to the offline recovery public key. Run `backup.ps1`, copy the encrypted set off the VPS, and execute `restore-check.ps1` against a disposable `cascade-restore-check-*` container/volume set. Do not accept a backup that has not passed restore verification.

## Rollback

If health, authentication, routing or fixture checks fail:

1. Disable only newly activated Cascade workflows.
2. Stop only the `cascade-n8n` Compose project.
3. Remove only the new Cascade Caddy fragment and restore the previously validated Caddy configuration.
4. Leave encrypted backups intact and record the failure reason.
5. Do not delete or modify the existing n8n service, its volumes, credentials, database, network or workflows.

DNS rollback and container removal remain owner-approved actions. Volume deletion is not part of routine rollback.
