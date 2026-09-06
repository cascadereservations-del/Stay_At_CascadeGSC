# Alfred existing n8n recovery procedure

Status: executed successfully on 2026-09-06 under the approved P1 recovery window. See the [redacted recovery evidence](../validation/2026-09-06-p1-alfred-recovery.md). This procedure targets Alfred's existing shared `deploy`/`n8n` runtime. It does not create the new Cascade stack, add swap, upgrade n8n, activate a workflow, configure a provider, or send a message.

## Approval scope

The next owner approval should authorize only:

1. a read-only topology inventory of container `n8n` and its database/storage dependencies;
2. a short, announced quiescence window if the inventory confirms that consistent capture requires it;
3. an encrypted engine-supported database dump, n8n data/binary archive, encrypted environment/config escrow, checksums, and off-host copy;
4. a disposable isolated restore on the local workstation with no published port and no external network;
5. cleanup of only uniquely named `cascade-alfred-restore-*` resources.

It does not authorize changing or restarting any unrelated Alfred service. If n8n cannot be isolated from another service's database or storage without widening the action, stop and revise the packet.

## Required private inputs

Keep these outside Git and do not paste their contents into logs or this repository:

- SSH target already configured for Alfred;
- absolute owner-only backup staging directory on Alfred;
- off-host encrypted backup destination;
- `age` recipient public key and separately protected recovery identity;
- current maintenance-window contact and rollback owner.

The recovery identity must not be created in a world-readable directory. On Windows, verify its ACL grants access only to the owner before accepting it. On Linux, use mode `0600`.

## Step 1 — read-only topology inventory

Run only narrowly filtered commands. Do not print the full container environment or a Portainer stack export.

```text
docker inspect --format '{{.Name}} image={{.Config.Image}} image_id={{.Image}} running={{.State.Running}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restarts={{.RestartCount}} oom={{.State.OOMKilled}} project={{index .Config.Labels "com.docker.compose.project"}} service={{index .Config.Labels "com.docker.compose.service"}}' n8n
docker inspect --format '{{range .Mounts}}{{.Type}} name={{.Name}} source={{.Source}} destination={{.Destination}} rw={{.RW}}{{println}}{{end}}' n8n
docker inspect --format '{{range $name, $network := .NetworkSettings.Networks}}{{$name}}{{println}}{{end}}' n8n
docker exec n8n sh -c 'for key in DB_TYPE DB_POSTGRESDB_HOST DB_POSTGRESDB_PORT DB_POSTGRESDB_DATABASE DB_POSTGRESDB_USER N8N_DEFAULT_BINARY_DATA_MODE; do value=$(printenv "$key" || true); printf "%s=%s\n" "$key" "$value"; done; for key in N8N_ENCRYPTION_KEY N8N_USER_MANAGEMENT_JWT_SECRET; do if printenv "$key" >/dev/null 2>&1; then printf "%s=present\n" "$key"; else printf "%s=absent\n" "$key"; fi; done'
```

For each attached Docker network, list only container names and images to identify the database peer:

```text
docker ps --filter network=<exact-network-from-inventory> --format '{{.Names}} image={{.Image}} status={{.Status}}'
```

Record the database engine/version, database container/service, n8n image digest, mount types, binary-data mode, encryption-key source, Compose/Portainer ownership, and whether stopping only `n8n` is sufficient for a consistent application snapshot. Redact public addresses, usernames and host paths from repository evidence.

Stop if the database is external, storage is shared with another project, the encryption key cannot be located without printing it, the stack is not `deploy`, or the container/image identity differs materially from the August baseline. Final capture commands must be generated from these observed facts.

## Step 2 — pre-capture checks

Before any stop, verify the backup directory is owner-only, the `age` recipient matches the offline identity, enough disk exists for two copies, and the off-host destination is reachable. Record the exact existing container ID, image digest, restart count and health. Export aggregate workflow, active-workflow and credential counts without row content.

Use the n8n CLI only if its version supports the command. Export workflow and encrypted credential records to the owner-only staging directory; do not use `--decrypted` on Alfred. Treat these exports as supplementary evidence: the database dump and matching encryption key remain the recovery authority.

## Step 3 — consistent encrypted capture

Present the exact commands after Step 1. The reviewed sequence must:

1. write an `INCOMPLETE` marker;
2. stop only container/service `n8n` if quiescence is required;
3. use the database engine's logical dump tool, never a tar archive of a live database directory;
4. archive every n8n data/binary mount and the supplementary encrypted exports;
5. escrow the matching n8n encryption key and required configuration directly into an encrypted artifact without printing them;
6. restart only `n8n` if this procedure stopped it, then prove its prior health and restart baseline;
7. encrypt each artifact with the approved `age` recipient, calculate SHA-256 over ciphertext, copy the complete encrypted set off-host, remove `INCOMPLETE`, and write `COMPLETE` last;
8. remove plaintext staging only after both encrypted copies and checksums exist.

If n8n fails to return to its prior health, stop the backup procedure and restore only its prior container/service state through Portainer. Do not upgrade, recreate, or change its image during recovery capture.

## Step 4 — disposable isolated restore

Download the encrypted set to the owner-controlled workstation. Verify ciphertext checksums before decryption. Create only uniquely named resources beginning `cascade-alfred-restore-`; reject any other cleanup prefix. The restore network must be Docker-internal, with no host ports and no provider access.

Restore the database using the same major engine version, then restore all n8n data/binary mounts. Use the matching encryption key only inside the isolated target. Do not start the normal n8n web server while restored workflows retain their captured active flags. Prefer CLI exports and database aggregates.

Acceptance requires:

- database restore exits successfully;
- workflow, active-workflow and credential counts match capture metadata;
- workflows export successfully from the restored database;
- when credentials exist, `n8n export:credentials --all --decrypted` succeeds into ephemeral container storage and that plaintext is destroyed with the container without being printed or copied out;
- binary-data references and required config files are present;
- no host port, external network, provider call or workflow execution occurred;
- encrypted off-host backup and recovery identity custody are confirmed;
- cleanup removes only the exact disposable containers, networks, volumes and plaintext temp directory.

## P1 exit record

Commit a redacted validation record containing timestamps, versions/digests, aggregate counts, encrypted artifact hashes, quiescence duration, restore result, cleanup result, and Alfred post-check. Do not commit secret values, database URLs, decrypted exports, host addresses or personal data.

P1 closed when the [dated Alfred recovery record](../validation/2026-09-06-p1-alfred-recovery.md) passed together with the local Cascade stack evidence. P2/P3 remain held for their separate action-time approval.
