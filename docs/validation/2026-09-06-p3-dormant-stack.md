# P3 dormant Cascade stack evidence — 2026-09-06

Status: **PASS. Phase P3 is complete.** The approved Portainer deployment, isolation checks, inactive workflow import, semantic round trip, named-owner MFA and final Alfred baseline pass. P4 recovery and the 72-hour dormant soak have not started.

## Approved deployment

The owner approved P3 after packet commit `0252f59` and the guarded preparation commits `9204289` and `3f595cb`. Portainer CE created stack `cascade-n8n` on Alfred's existing local Docker endpoint. The stack created exactly:

- containers `cascade-n8n-postgres` and `cascade-n8n-app`;
- volumes `cascade_n8n_postgres_data` and `cascade_n8n_data`;
- networks `cascade_n8n_internal` and `cascade_n8n_egress`;
- host staging under `/opt/cascade/n8n`.

No DNS record, Cloudflare or proxy route, public hostname, provider credential, webhook, GitOps integration, private registry selection, workflow activation, message or order was created.

The live image IDs match the approved Linux/amd64 manifests:

- PostgreSQL: `sha256:7456ef82e5f5bc43d997f4781bbd7c0d6389bff397564649a356e206ba473aee`;
- n8n: `sha256:848166b4051fd4251869f48c18455bddff922f04cb2f2676929463ba973dbde2`.

## Secrets and staging

The owner-controlled environment file and age recovery identity remain outside Git with inheritance disabled and one owner-only ACL rule. Portainer received the environment file through its authenticated stack form. An accessibility snapshot unexpectedly rendered the first generated environment values during form verification. Those values had not been deployed. They were immediately replaced with independent cryptographic values, the local owner-only file was recreated, Alfred's staged root-only `.env` was replaced, and the Portainer form was reloaded before the final upload and deployment. No exposed value is active.

Remote staging has root-owned mode `0700`; `.env` is root-owned mode `0600`. `files` and `files/workflows` retain root ownership and mode `0750`, with group 1000 read/traverse access for the n8n runtime. The initial import failed closed because the directories were root:root `0750`; no workflow was imported. Granting only the runtime group access resolved the mismatch. The 16 reviewed non-secret staged source hashes matched before deployment.

## Live isolation and limits

Both services became healthy with zero restarts and no OOM event:

| Service | Memory ceiling | CPU ceiling | Published port |
| --- | ---: | ---: | --- |
| `cascade-n8n-postgres` | 805,306,368 bytes | 0.75 CPU | none |
| `cascade-n8n-app` | 1,610,612,736 bytes | 1.5 CPU | `127.0.0.1:5679 -> 5678/tcp` |

The n8n `/healthz` endpoint returned status ok through Alfred loopback. Host listener inspection showed only `127.0.0.1:5679`; PostgreSQL has no host binding.

## Workflow proof

The n8n CLI imported exactly 13 source workflows with `--activeState=false`. Database aggregate checks returned:

- workflows: 13;
- active workflows: 0;
- credentials: 0.

A fresh `export:workflow --backup` produced 13 JSON files. `scripts/recovery/recovery-contract.mjs` compared their normalized semantics with the reviewed source and returned:

`d3077384d1bca5cf6d9941eb1a104183c3348f964ebba49741baf6436c4cd8ce`

The validated temporary export and archive were removed from Alfred and the workstation.

## Named owner and MFA

The owner created the first named account through the private SSH tunnel, enrolled TOTP personally, and reported a successful sign-out/sign-in verification. The authenticated Personal Settings page showed two-factor authentication enabled. Aggregate database checks returned one named credentialed owner and one MFA-enabled user. No identity, email, password, TOTP seed, recovery code, cookie or user ID was recorded in Git, terminal evidence or this handoff.

## First post-start Alfred baseline

At `2026-09-06T13:04:59Z`:

- available RAM: 2,673,143,808 bytes;
- usable swap: 2,148,528,128 bytes;
- free swap: 2,146,168,832 bytes;
- free disk under `/opt`: 33,296,281,600 bytes;
- load: 0.27 / 0.21 / 0.11.

The 20 pre-existing running containers retained their captured identities and start times. Every restart count remained zero and every OOM flag remained false. Their memory and NanoCPU limits were unchanged. Alfred's existing n8n remained healthy on `127.0.0.1:5678`. The two new Cascade containers were the only new running containers.

## Final P3 baseline and exit

At `2026-09-06T15:10:43Z`:

- available RAM: 2,668,470,272 bytes;
- usable swap: 2,148,528,128 bytes;
- free swap: 2,146,168,832 bytes;
- free disk under `/opt`: 33,292,050,432 bytes;
- load: 0.15 / 0.12 / 0.12;
- running containers: 22, consisting of the unchanged 20 pre-existing containers and the two approved Cascade containers.

Swap use was 2,359,296 bytes at both recorded post-start samples, so it had settled rather than grown continuously. Every pre-existing container retained its full ID, start time, restart count, OOM state and resource limits. Both Cascade containers were healthy with zero restarts and OOM false. Aggregate checks remained 13 workflows, zero active workflows and zero credentials. Alfred's existing n8n and the new loopback-only Cascade n8n both returned status ok.

P3 passes. P4 must run the encrypted backup/disposable-restore proof and observe at least 72 hours of complete samples before co-location is accepted. This record does not authorize a public route, provider credential, workflow activation, production database change or message.
