# P4 recovery drill and 72-hour soak action packet

Status: prepared locally; not executed. P0–P3 pass. This packet requires fresh owner approval naming its final commit before any P4 mutation. Approval of this packet does not authorize P5 or any Supabase, identity, provider, workflow-activation, message or destructive action.

## Read-only re-verification (2026-09-06T15:32Z–15:42Z)

Before drafting, Alfred was re-checked over the owner SSH alias without mutation:

- 22 running containers: the unchanged 20 existing containers plus `cascade-n8n-app` and `cascade-n8n-postgres`, both healthy, restart count 0, OOM false, limits 1536 MiB/1.5 CPU and 768 MiB/0.75 CPU, image IDs matching the pinned P3 digests;
- every existing container retains the P3 full ID and start time with restart count 0 and OOM false;
- aggregates 13 workflows / 0 active / 0 credentials; one credentialed owner; one MFA-enabled user;
- `127.0.0.1:5679` is the only 5679 listener; both `/healthz` endpoints return 200;
- available RAM 2.52–2.67 GiB, swap total 2,148,528,128 bytes with 2.4–13.9 MB used, 33.29 GB free under `/` and `/opt`, 15-minute load below 0.15.

Two tooling facts change how P4 must run:

1. Alfred has Docker Compose v2 (`docker compose`) only. It has no `age`, no `docker-compose` v1 and no PowerShell, so `backup.ps1` and `restore-check.ps1` cannot run there unmodified. `age` 1.1.1 is an installable Ubuntu package, but installing it is a host package change this packet does not request.
2. Docker Desktop on the workstation is broken, so `restore-check.ps1` cannot run locally either.

The scripts under `infrastructure/cascade-n8n/p4/` therefore drive the same contract over SSH from the owner workstation, which has `ssh`, `age` 1.3.1, `sha256sum` and Node. Alfred needs only Docker, `python3` and `tar`, all present.

## Exact scope

P4 consists of three approved mutations plus read-only observation:

1. **Encrypted backup** of the dormant stack with `infrastructure/cascade-n8n/p4/backup-over-ssh.sh --quiesce`, run from the owner workstation. It stops only `cascade-n8n-app` for the capture window and restarts it by trap; PostgreSQL keeps running. Plaintext streams from Alfred straight into local `age` under the dedicated recipient in `C:\Cascade-Backups\cascade-n8n-recovery-age-recipient.txt`; no plaintext is written to any disk and no value is printed. The artifact set and `SHA256SUMS`/`COMPLETE` contract are identical to `backup.ps1`. The n8n data volume is archived by the pinned n8n image itself with `--network none`, so no new image is pulled. Destination: `C:\Cascade-Backups\cascade-n8n\cascade-n8n-<UTC>`.
2. **Disposable restore proof** with `infrastructure/cascade-n8n/p4/restore-check-on-alfred.sh <backup-set>`. It verifies ciphertext checksums, decrypts on the workstation with the owner-only identity, streams plaintext into a root-only `/opt/cascade/.restore-check-<suffix>` on Alfred, and creates only `cascade-restore-check-<suffix>-postgres`, `-export`, `-postgres-data`, `-n8n-data` and `-internal`. The network is Docker-internal, no port is published, images are referenced by the exact P3 IDs (no pull), and the disposable containers are capped at 512 MiB/0.5 CPU and 768 MiB/1 CPU. It requires `pg_restore --exit-on-error`, restored aggregates equal to captured metadata, a successful `export:workflow --backup`, and semantic SHA-256 `d3077384d1bca5cf6d9941eb1a104183c3348f964ebba49741baf6436c4cd8ce` against `automation/n8n/workflows` via `semantic-compare.mjs`. A trap removes every prefixed resource and the temporary directory and prints the leftover count, which must be 0. The encrypted backup is preserved.
3. **Soak monitor** on Alfred: copy `soak-sample.py` to `/usr/local/lib/cascade-soak/`, install `cascade-p4-soak.service` and `cascade-p4-soak.timer` under `/etc/systemd/system/`, write the baseline with `soak-sample.py --baseline`, then `systemctl enable --now cascade-p4-soak.timer`. The timer fires every minute at second 0 with 1-second accuracy and appends one JSON line to root-only `/var/lib/cascade-soak/p4-soak.jsonl`. This is outside Git. Each sample records UTC time, available RAM, total/free swap, free disk under `/` and `/opt`, 1/5/15-minute load, both Cascade containers' health/restarts/OOM/limits/start time, every existing container's ID/start/restarts/OOM/health, workflow/active/credential aggregates, both health endpoints and the 5679 listener. A dry run against temporary paths on 2026-09-06T15:42Z produced a complete sample and a baseline of 20 existing and 2 Cascade containers; the temporary files were removed.

Sequence: entry checks, backup, restore proof, baseline, timer start. The baseline is written after the restore proof so the quiesce restart of `cascade-n8n-app` is the recorded start time for the soak. Total interactive time: about 20 minutes. The soak then needs at least 72 continuous hours.

## Entry checks

Immediately before the backup, record UTC time, RAM/swap/disk/load, the name, full ID, start time, health, restart count, OOM flag and limits of every running container, 13/0/0 aggregates, one MFA-enabled owner, the loopback-only 5679 listener and both health endpoints. Require at least 2 GiB available RAM, at least 2 GiB active swap, at least 15 GiB free disk, no unhealthy or restarting container, and both pinned image IDs unchanged. Stop on any deviation.

## Acceptance

Restore proof passes only if ciphertext checksums verify, decryption succeeds, `pg_restore` completes with `--exit-on-error`, restored aggregates equal captured aggregates (expected 13/0/0), the export produces 13 files whose semantic hash matches, the restore network is internal, no port was published, and cleanup leaves zero `cascade-restore-check-*` resources and no temporary directory on Alfred or the workstation.

Soak passes only if `soak-evaluate.py p4-soak.jsonl p4-baseline.json` reports `pass: true`: one continuous window of at least 72 hours with no gap over 90 seconds and zero abort findings. Evaluation applies the handoff abort conditions exactly: available RAM below 1.5 GiB for three consecutive samples, swap used growing for five consecutive samples, 15-minute load above 3, free disk below 15 GiB, any existing container changing ID or start time, restarting, becoming unhealthy or recording OOM, either Cascade container restarting, becoming unhealthy, recording OOM or changing limits, aggregates other than 13/0/0, a non-200 health endpoint, or a 5679 listener other than `127.0.0.1:5679`. Missing samples end the window; the soak continues until a complete window exists. A dated P4 report is written to `docs/validation/` only after evaluation.

## Abort and rollback boundary

On any abort finding, stop only `cascade-n8n-app` and `cascade-n8n-postgres`, stop the soak timer, preserve the soak log, encrypted backup, volumes and logs, and move the plan to the separate-VPS fallback. Do not delete volumes, remove swap, restart Docker, alter the existing n8n, change DNS/proxy state or install packages without a separate reviewed action. If the backup script's trap cannot restart `cascade-n8n-app`, start it through Portainer before anything else.

Removing the soak unit files, `/usr/local/lib/cascade-soak`, `/var/lib/cascade-soak`, the backup set or any stack resource is destructive cleanup and needs a separate reviewed decision.

## Owner-controlled inputs

- `CASCADE_BACKUP_DIR=C:\Cascade-Backups\cascade-n8n`
- `AGE_RECIPIENT` read from `C:\Cascade-Backups\cascade-n8n-recovery-age-recipient.txt`
- `AGE_IDENTITY_FILE=C:\Users\Lloyd\Cascade-Secrets\cascade-n8n-recovery-age.txt`
- SSH alias `alfred` with the existing owner key

No identity, key, password, environment value, workflow body, cookie or database row belongs in evidence, terminal output or chat.

References: [post-P3 handoff](../handoff/COMPLETE-HANDOFF-P3-2026-09-06.md), [P3 evidence](../validation/2026-09-06-p3-dormant-stack.md), [deployment runbook](../runbooks/cascade-n8n-deploy.md), [completion plan](2026-09-06-portainer-n8n-completion-plan.md).
