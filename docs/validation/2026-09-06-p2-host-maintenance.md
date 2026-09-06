# P2 Alfred host maintenance — 2026-09-06

Status: PASS. Owner explicitly approved allocation of 2049 MiB swap, persistence and the full host baseline after reviewing packet commit `4eaacfd`. Execution window: 06:07–06:09 UTC. P3 remains separately approval-gated.

## Change and persistence

Created only `/swapfile-cascade`, 2,148,532,224 bytes, root:root mode 0600, on the verified ext4 root filesystem. Initialized and enabled usable swap of 2,148,528,128 bytes, exceeding 2 GiB. Usage remained zero.

Preserved `/etc/fstab.cascade-p2.20260906T060830Z.bak`, root:root mode 0600. The before/after diff contains only a blank line and `/swapfile-cascade none swap sw 0 0`. Reloaded systemd definitions to recognize persistence; the escaped swap unit is generated, loaded and active. No reboot or service restart was performed. Persistence is configuration-verified, not reboot-tested.

## Baseline comparison

| Measurement | Before | Final after |
| --- | ---: | ---: |
| Available RAM, bytes | 3,121,737,728 | 3,116,380,160 |
| Usable swap, bytes | 0 | 2,148,528,128 |
| Used swap, bytes | 0 | 0 |
| Free disk on root and /opt, bytes | 36,003,000,320 | 33,854,345,216 |
| Load, 1/5/15 minutes | 0.15 / 0.14 / 0.09 | 0.17 / 0.14 / 0.09 |
| Running containers | 20 | 20 |
| Healthy / no health check / unhealthy | 9 / 11 / 0 | 9 / 11 / 0 |

Programmatic comparison matched all 20 container names, full IDs, start times, running states, restart counts, OOM flags, memory limits and NanoCPU limits exactly. Every restart counter was zero and OOM flag false. Existing n8n `/healthz` returned status ok. QuickChart was present before maintenance and its identity/start time remained unchanged.

Port 5679 remains unused; `/opt/cascade/n8n` remains absent including symlink check; no Cascade container, network or volume collision was observed. Available RAM exceeds 2.5 GiB and free disk exceeds 15 GiB after allocation. These samples establish P2 readiness only, not peak-load capacity or the 72-hour dormant soak.

## Validation anomalies resolved

The first read-only Docker template failed for containers without a health-check field. Repeated inspection using supported common fields and a separate status listing captured all 20 containers before mutation.

The mutation block completed allocation, activation and fstab append, then the PowerShell-to-SSH pipe supplied a trailing carriage-return command that caused a nonzero shell exit. The block was not rerun. Independent reads verified all resulting state. Future piped shell execution must avoid the transport-added CRLF.

`findmnt --verify` reported zero parse errors and zero errors, plus a regular-file-source warning for the swap file and an initial stale-systemd warning. Reloading systemd cleared the latter; the regular-file warning remains disclosed. The kernel active-swap listing and generated active swap unit verify the exact file. An initial unescaped unit-name query did not find the unit; listing swap units confirmed its correctly escaped name.

## Boundaries and next step

No Cascade stack, provider credential, route, DNS, workflow activation, message or production migration was created. All 13 source exports remain inactive. P1 recovery remains valid; local Docker repair and Module A gates remain outstanding. P3 needs its own concrete packet and fresh approval. Rollback is unnecessary; swap removal remains separately gated by the approved packet's memory-safety conditions.

Local validation: inactive-workflow checker, secret scan and staged whitespace check must pass with this evidence commit. Unrelated Task Master files remain untouched.
