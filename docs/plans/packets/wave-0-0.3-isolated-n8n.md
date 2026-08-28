# Wave 0 Task 0.3 Packet — Isolated Cascade n8n

## Starting point

- Repository: `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`
- Branch: `codex/cascade-waves-0-1-sol`
- Starting commit: `9c5daf6`
- Remote target for a later approved deployment: `/opt/cascade/n8n`

## Version decision

- Pin n8n stable `2.34.6`, not the `2.35.x` beta line observed in August 2026 issue reports.
- Pin PostgreSQL official image `17.11-alpine3.24`.
- The reverse-proxy fragment targets a new `cascade-n8n.rocloyd.com` host and never reuses the existing `n8n.rocloyd.com` application.
- n8n is fair-code under its Sustainable Use License, not OSI open source. PostgreSQL, Caddy and age are open-source dependencies.

## RED

Create `tests/infrastructure/cascade-n8n.test.mjs` before the infrastructure files. Assert exact image pins, Cascade-prefixed containers/network/volumes, required secret placeholders, localhost-only application binding, health checks, resource ceilings, no Alfred/Alex identifiers, a separate Caddy host, encrypted backup inputs and capacity/approval gates.

```powershell
node --test tests/infrastructure/cascade-n8n.test.mjs
```

Expected RED: missing `infrastructure/cascade-n8n/compose.yaml`.

## GREEN

Create the compose stack, example environment, Caddy fragment, backup/restore-check scripts and deployment runbook. PostgreSQL, credentials, encryption key, volume, network, hostname and webhook URL must be Cascade-only. Bind n8n to `127.0.0.1`; Caddy/Cloudflare provide HTTPS. Keep workflows inactive through import and require an explicit owner approval for deployment, DNS, credentials and activation.

## Verification

```powershell
node --test tests/infrastructure/cascade-n8n.test.mjs
docker-compose -f infrastructure/cascade-n8n/compose.yaml --env-file infrastructure/cascade-n8n/.env.example config
```

The example environment uses valid non-secret test values only for syntax validation. The stack must not be started locally.

## Forward verification and rollback

- Forward: perform the runbook's read-only VPS preflight; then, with separate approval, deploy under `/opt/cascade/n8n`, verify health and import workflows inactive.
- Rollback: stop only the `cascade-n8n` Compose project, restore the prior Caddy file, and retain encrypted backups. Never remove the existing Personal/Alfred/Alex n8n resources.
- Stop if RAM, swap, disk, port, DNS, TLS or backup restoration gates fail.

## Commit

```powershell
git add docs/plans/packets/wave-0-0.3-isolated-n8n.md infrastructure/cascade-n8n docs/runbooks/cascade-n8n-deploy.md tests/infrastructure/cascade-n8n.test.mjs
git commit -m "infra(cascade): define isolated n8n deployment"
```
