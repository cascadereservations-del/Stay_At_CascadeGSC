# Hetzner read-only capacity and collision preflight — 2026-09-05

Status: reached the configured SSH target read-only. Deployment gate failed; no change made.

The preflight emitted only redacted capacity and collision facts. It did not read container environments, credentials, public addresses, application data, or provider configuration.

| Check | Observed | Gate |
| --- | ---: | --- |
| Available RAM | 3,224 MiB | Pass; exceeds 2.5 GiB minimum |
| Swap | 0 MiB | **Fail; at least 1 GiB required** |
| Free disk on `/` and `/opt` | 37,208 MiB | Pass; exceeds 10 GiB minimum |
| Docker server | 29.5.3 | Available |
| Docker Compose | 5.1.4 | Available |
| Running containers | 19 | Inventory only; none changed |
| `cascade-n8n-app` / `cascade-n8n-postgres` name collisions | 0 | Pass |
| Port 5679 listeners | 0 | Pass |
| `/opt/cascade/n8n` already exists | No | Pass; no existing target overwritten |

The migration cannot proceed while swap is absent. Adding swap, creating `/opt/cascade/n8n`, changing DNS/TLS, placing secrets, creating containers/volumes, importing workflows, or configuring providers are separate VPS or production actions. They were not performed. Module A production backup/restore, Auth/staff, monitoring, and runtime recovery gates also remain open.
