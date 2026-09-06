# P1 local completion evidence — 2026-09-06

Status: local P1 work complete; Alfred recovery proof open; P2/P3 held. No Alfred connection, production-data capture, Portainer, swap, DNS, proxy, provider, workflow activation or production change occurred.

## Image and security review

The isolated Cascade candidate moved from n8n 2.34.6 to 2.37.10 after review of the official September 2–3 GitHub security advisories. Those advisories list 2.37.7 or later on the 2.37 line as patched. The pulled `linux/amd64` image resolved to:

`n8nio/n8n@sha256:307d6065be25619aa24cfc63a7c2f04ca56d084a08c05c8e9f189a89f353b1ec`

All 13 source workflows round-tripped inactive on that image. Imported and exported counts were 13, active count was zero, and the semantic set hash remained:

`d3077384d1bca5cf6d9941eb1a104183c3348f964ebba49741baf6436c4cd8ce`

## Capped stack proof

The initial full startup exposed a 2.37.10 compatibility failure: the read-only root prevented creation of `/home/node/.cache`. The final Compose adds a 128 MiB tmpfs for only that cache, retains the read-only root and 256 MiB `/tmp`, and replaces deprecated `WEBHOOK_URL` with `N8N_WEBHOOK_URL`.

The final fresh stack reached healthy/ready with zero restarts and zero OOM flags. PostgreSQL had no host port and a 768 MiB / 0.75 CPU ceiling. n8n bound only `127.0.0.1:5679` and retained a 1536 MiB / 1.5 CPU ceiling. All 13 workflows imported inactive and the test database contained zero provider credentials before the synthetic recovery credential was added.

The built-in n8n security audit confirmed community packages, public API, version notifications, templates and diagnostics disabled. MCP is disabled, unverified packages are disabled, SSRF protection is enabled, environment/file access from Code nodes remains restricted, and request URIs are removed from Caddy access logs. The audit still classifies every Code node as an official risky node. The dormant two-service trial therefore keeps workflows inactive and uses the internal JavaScript runner. Official n8n guidance recommends an external runner for production; introduce and capacity-test a matching runner sidecar before any Code-node workflow activation in P9.

## Encrypted new-stack recovery proof

The revised scripts require explicit quiescence, capture a logical PostgreSQL dump, n8n data, `files`, encrypted environment/key escrow and aggregate metadata, then encrypt every artifact and hash ciphertext. Restore rejects incomplete or checksum-invalid sets, uses only uniquely prefixed resources on an internal Docker network with no published port, compares workflow/active/credential counts, exports restored workflows and proves credential decryption only inside ephemeral container storage.

Fresh end-to-end synthetic result:

- n8n 2.37.10 and PostgreSQL 17.11;
- 13 workflows restored, zero active;
- one synthetic credential restored and successfully decrypted with the escrowed key;
- local n8n quiesced and returned to healthy state;
- exact disposable restore containers, volumes, network, plaintext and temporary key directory removed;
- no provider connection or workflow execution.

`age` 1.3.1 was installed user-scoped to run this proof. The generated test identity triggered a Windows world-readable-file warning; it protected synthetic data only and was immediately destroyed. A real recovery identity is not accepted until its ACL is owner-only and separately backed up.

## Remaining P1 action

Follow [Alfred existing n8n recovery](../runbooks/alfred-existing-n8n-recovery.md). It begins with a narrowly filtered read-only topology inventory, then requires a separately approved consistent encrypted capture and isolated restore. The redacted result must prove Alfred's actual database, credential ciphertext, encryption key, workflows, binary storage, image/config and post-capture health.

P1 cannot close from local evidence alone. P2/P3 remain held until that live-runtime proof passes and the actual proxy topology is recorded.
