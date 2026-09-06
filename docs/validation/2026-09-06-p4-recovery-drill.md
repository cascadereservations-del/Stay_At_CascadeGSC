# P4 recovery drill evidence and soak start

Status: **Restore proof PASS. Soak RUNNING, not yet complete.** P4 cannot be marked complete until `soak-evaluate.py` reports a continuous window of at least 72 hours with zero abort findings. Earliest completion: 2026-09-09T16:16Z.

Owner authorization: Lloyd, 2026-09-06 ("complete as much phases as possible… authorized to implement changes, run scripts and commands"), after packet commit `53ffde4`. Script fixes proven during execution are in `1486d76`.

## Entry state (2026-09-06T15:32Z–16:07Z, read-only)

22 running containers; both Cascade containers healthy, restart 0, OOM false, limits 1536 MiB/1.5 CPU and 768 MiB/0.75 CPU; all 20 pre-existing containers matched the P3 IDs and start times; aggregates 13/0/0; one MFA-enabled owner; `127.0.0.1:5679` only; both `/healthz` 200; available RAM 2.52–2.69 GiB; swap used under 14 MB of 2 GiB; 33.29 GB free disk.

## Encrypted backup (2026-09-06T16:07:25Z)

`infrastructure/cascade-n8n/p4/backup-over-ssh.sh --quiesce` from the owner workstation. `cascade-n8n-app` was stopped for 37 seconds and returned healthy. Five artifacts were encrypted to the dedicated age recipient at `C:\Cascade-Backups\cascade-n8n\cascade-n8n-20260906T160725Z` with `SHA256SUMS` and `COMPLETE`. Captured aggregates: 13 workflows, 0 active, 0 credentials. No plaintext was written to disk; no value was printed.

Ciphertext SHA-256 prefixes: postgres dump `6991eb0e…`, n8n data `68fcf04a…`, files `4bf5a00e…`, environment `b699a70d…`, metadata `af639b82…`.

## Disposable restore proof (2026-09-06T16:12Z)

`infrastructure/cascade-n8n/p4/restore-check-on-alfred.sh` verified all five ciphertext checksums, decrypted on the workstation, streamed plaintext into root-only `/opt/cascade/.restore-check-081499c1844f`, and created only `cascade-restore-check-081499c1844f-{postgres,export,postgres-data,n8n-data,internal}` from the pinned image IDs with no pull, an internal network and no host port.

Results:

- `pg_restore --exit-on-error` completed;
- restored aggregates equalled captured metadata: 13 / 0 / 0;
- `export:workflow --backup` produced 13 files;
- semantic SHA-256 matched source: `d3077384d1bca5cf6d9941eb1a104183c3348f964ebba49741baf6436c4cd8ce`;
- cleanup leftovers: 0 containers, volumes, networks or temp directories.

Three earlier attempts failed closed on tooling faults (MSYS path conversion of the remote path, a root-only temp dir unreadable by the n8n UID, PostgreSQL init-phase readiness, and an EXPOSE misread as a published port); each cleaned up with zero leftovers before the fix. All fixes are in `1486d76`.

## Soak monitor (started 2026-09-06T16:15Z)

Installed on Alfred: `/usr/local/lib/cascade-soak/soak-sample.py`, `/etc/systemd/system/cascade-p4-soak.{service,timer}`. Baseline `/var/lib/cascade-soak/p4-baseline.json` recorded 20 existing and 2 Cascade containers after the quiesce restart. Timer active at 60-second cadence; first sample 2026-09-06T16:15:37Z: 2,687,643,648 bytes available, swap free 2,117,595,136, 22 running, 13/0/0, both healthz 200, listener `127.0.0.1:5679`, both Cascade containers healthy with zero restarts. At 16:23Z the evaluator reported 9 samples, one window, zero abort findings.

Evaluate with:

```bash
ssh alfred python3 /usr/local/lib/cascade-soak/soak-evaluate.py /var/lib/cascade-soak/p4-soak.jsonl /var/lib/cascade-soak/p4-baseline.json
```

## Operational notes

- Scripts must run from Git Bash where `ssh` resolves to Windows OpenSSH (agent-backed); the scripts now select it explicitly and set `MSYS_NO_PATHCONV=1`.
- Claude Code auto mode blocked the backup and restore commands until they were run with the owner present; the production Supabase backup remained blocked in that mode (see P5 notes in the handoff).
- No workflow, credential, DNS, proxy, package or existing-service change was made.
