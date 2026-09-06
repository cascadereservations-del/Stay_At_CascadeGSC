# P3 dormant Cascade stack evidence — 2026-09-06

Status: **PENDING OWNER MFA.** The approved Portainer deployment, isolation checks, inactive workflow import, semantic round trip and first post-start Alfred baseline pass. P3 cannot pass until the owner completes the named account, TOTP enrollment and sign-out/sign-in check through the private SSH tunnel.

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

## First post-start Alfred baseline

At `2026-09-06T13:04:59Z`:

- available RAM: 2,673,143,808 bytes;
- usable swap: 2,148,528,128 bytes;
- free swap: 2,146,168,832 bytes;
- free disk under `/opt`: 33,296,281,600 bytes;
- load: 0.27 / 0.21 / 0.11.

The 20 pre-existing running containers retained their captured identities and start times. Every restart count remained zero and every OOM flag remained false. Their memory and NanoCPU limits were unchanged. Alfred's existing n8n remained healthy on `127.0.0.1:5678`. The two new Cascade containers were the only new running containers.

## Remaining P3 gate

The initial n8n placeholder owner row is present, but aggregate checks show zero rows with both a named email and password and zero MFA-enabled users. The owner must complete the first account interactively through the private SSH tunnel, enroll TOTP, sign out, sign in with MFA, and verify the editor shows 13 inactive workflows and no credentials. Evidence must record only aggregate completion, never identity, password, TOTP seed, recovery codes, cookie or user ID.

P4's 72-hour dormant soak starts only after this P3 record changes to PASS.
