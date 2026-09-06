# P1 Alfred n8n recovery evidence — 2026-09-06

Status: **PASS. Phase P1 is complete.** P2/P3 remain held for a fresh action-time approval covering host swap, a new dormant stack, and its route. This recovery window did not create the Cascade stack, add swap, change a proxy route, change an image, configure a provider, activate a workflow, or send a message.

## Observed live topology

The existing runtime is container `n8n`, service `n8n`, in Compose project `deploy`. Its configured image remains the mutable tag `n8nio/n8n:latest`, but the running container resolved to n8n 2.37.10 and image ID:

`sha256:307d6065be25619aa24cfc63a7c2f04ca56d084a08c05c8e9f189a89f353b1ec`

The application uses SQLite. Persistent application data is in named volume `deploy_n8n_data` at `/home/node/.n8n`; Alfred/LifeVault files are bind-mounted at `/lifevault`. The n8n data occupied about 1,356 MiB at capture time, dominated by a 1,398,628,352-byte SQLite database and 29 MiB of binary-data storage. The encryption key was present in the container environment and was captured without printing its value. The user-management JWT secret was absent.

The container joins `alfred_internal` and publishes n8n only on `127.0.0.1:5678`. Host service `cloudflared` 2026.6.0 is active and routes `n8n.rocloyd.com` to `http://localhost:5678`. Caddy, nginx, Apache and Traefik host services were inactive. No proxy or route was changed.

The live database contained 60 workflows, 28 active workflows, and 31 credentials. A filtered comparison found all 13 expected source-controlled Cascade workflow names, with 14 matching live rows because one name is duplicated; all 14 matching rows were inactive. The 28 active workflows belong to other Alfred automation records and were preserved unchanged.

## Consistent encrypted capture

The accepted capture used n8n 2.37.10's installed `node-sqlite3` backup API against the stopped SQLite database, followed by a closed-volume archive of the remaining n8n data and `/lifevault`. Supplementary workflow exports and credential ciphertext were included. Only `n8n` was stopped. The successful consistency window lasted 19 seconds.

The guarded script restarted `n8n`, confirmed `/healthz`, and verified the same container fingerprint, restart count 0, OOM flag false, 60 workflows, and 28 active workflows. Two earlier guarded attempts aborted before producing a complete set: the first helper lacked permission to read the owner-only config, and the second could not resolve the SQLite module from a mounted script. The restart trap returned n8n healthy after both attempts; their partial files were replaced by the final capture and removed.

The complete recovery archive was encrypted with age 1.3.1. The recovery identity is outside Git with inheritance disabled and one owner-only ACL rule. The verified ciphertext is 169,435,578 bytes with SHA-256:

`e75330ecbd58230baf36387e492f30e51e407fb3719cbf3313c76dcd0d05e48a`

Matching encrypted copies and checksums exist in the owner-controlled off-host backup location and Alfred's owner-only recovery staging location. Both plaintext archives and plaintext checksums were removed after the encrypted copies verified. Secret values, database rows, workflow bodies, credential bodies, host addresses and owner paths are absent from this record.

## Disposable isolated restore

[`restore-alfred-check.ps1`](../../infrastructure/cascade-n8n/restore-alfred-check.ps1) verified the ciphertext checksum, decrypted into a uniquely named temporary directory, rebuilt a uniquely named n8n volume, and used an internal Docker network with no published port. It did not start the normal n8n server. It used CLI exports only, so captured active flags could not execute workflows.

The restored database passed `PRAGMA integrity_check` and matched all captured aggregates:

- workflows: 60;
- active workflow flags: 28;
- credentials: 31;
- workflow export: passed;
- ephemeral `export:credentials --all --decrypted`: passed without printing or copying decrypted content;
- restored binary-data/config archive: present;
- external network: unavailable;
- published ports: zero.

After the proof, zero `cascade-alfred-restore-*` containers, volumes, networks or temporary directories remained. The off-host backup directory contains only the age recipient, ciphertext, ciphertext checksum and completion markers. Alfred contains no recovery plaintext and no capture helper container.

## P1 exit and next gate

This record, [local P1 completion](./2026-09-06-p1-local-completion.md), the [action packet](../plans/2026-09-06-p1-recovery-action-packet.md), and the rendered capped Compose evidence satisfy P1. The next executable phase is P2: add at least 2 GiB swap under a separately reviewed host-maintenance action, rerun the full Alfred baseline, and stop if any threshold fails. P3 must receive its own action-time approval after the fresh P2 baseline.
