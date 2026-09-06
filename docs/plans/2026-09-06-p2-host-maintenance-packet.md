# P2 host-maintenance approval packet

Status: prepared locally; not executed. P1 remains complete at `cf4c9f3`.

## Scope and fresh evidence

Target: Alfred, existing host, root filesystem. Approve only creation and activation of `/swapfile-cascade` (2049 MiB, providing at least 2 GiB usable swap), its persistent `/etc/fstab` entry, a protected fstab backup, and read-only before/after validation. Expected effect: 2049 MiB disk allocation and host swap availability, with allocation I/O. No reboot or service restart is planned. P3 stack creation remains a separate approval.

Read-only observation at 2026-09-06 06:04:04 UTC:

- Root filesystem: ext4.
- Available RAM: 3,127,582,720 bytes (2.91 GiB); swap: zero.
- Free disk on root and `/opt`: 36,003,020,800 bytes (33.53 GiB).
- Load averages: 0.13 / 0.16 / 0.09.
- 20 running containers: nine report healthy, eleven have no displayed health check; none reports unhealthy. All inspected running containers report restart count zero and OOMKilled false.
- QuickChart is newly present relative to the earlier 19-container audit and had six minutes uptime. A zero restart count does not prove historical stability across replacement containers.
- `/swapfile-cascade` is absent, including symlink check; no matching fstab line was found. `/opt/cascade/n8n` is absent; port 5679 has no listener; no matching Cascade network or volume was found.

These are point-in-time observations, not peak-load or soak evidence. Recheck immediately before action and compare container IDs, start times, health and restart/OOM counters after action. Stop for unexplained container churn or degradation. P2 cannot authorize P3 automatically.

## Preconditions at action time

Confirm explicit owner approval naming this packet and its commit. Confirm P1 encrypted recovery evidence is available. Repeat the complete baseline: `free -b`, `swapon --show --bytes`, `df -B1 / /opt`, `/proc/loadavg`, listeners, Docker names/IDs/start times/health/restart/OOM/resource limits, networks, volumes and path collisions. Do not print environments, secrets or workflow bodies.

Require at least 2.5 GiB available RAM and 15 GiB free disk after allocation, low stable load, no existing unhealthy/restarting service, no unexplained container replacement, and no path/name/listener collision. Check the currently available swap tools and filesystem with their installed help/manuals. No package installation is included. If filesystem type changes, stop and revise this packet.

## Exact proposed mutation block

Run only after the above review and fresh approval, in a root Bash session on Alfred. The block intentionally has no automatic swap-removal trap: on failure preserve the intermediate state, inspect it, and request a scoped recovery decision.

```bash
set -euo pipefail
test "$(id -u)" = 0
test "$(findmnt -no FSTYPE -T /)" = ext4
test ! -e /swapfile-cascade
test ! -L /swapfile-cascade
! grep -Fq /swapfile-cascade /etc/fstab
test -f /etc/fstab
test ! -L /etc/fstab
test "$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)" -ge 2621440
test "$(df -B1 --output=avail / | tail -1 | tr -d ' ')" -ge 18254659584
for tool in dd mkswap swapon findmnt stat sha256sum; do command -v "$tool" >/dev/null; done
backup="/etc/fstab.cascade-p2.$(date -u +%Y%m%dT%H%M%SZ).bak"
test ! -e "$backup"
test ! -L "$backup"
umask 077
(set -o noclobber; cat /etc/fstab > "$backup")
chmod 600 "$backup"
before=$(sha256sum /etc/fstab | cut -d ' ' -f 1)
(set -o noclobber; : > /swapfile-cascade)
chmod 600 /swapfile-cascade
chown root:root /swapfile-cascade
dd if=/dev/zero of=/swapfile-cascade bs=1M count=2049 conv=fsync status=none
test "$(stat -c %s /swapfile-cascade)" = 2148532224
mkswap /swapfile-cascade
swapon /swapfile-cascade
swapon --show --bytes
test "$(sha256sum /etc/fstab | cut -d ' ' -f 1)" = "$before"
printf '\n/swapfile-cascade none swap sw 0 0\n' >> /etc/fstab
findmnt --verify --tab-file /etc/fstab
```

The dedicated file is 2049 MiB to allow swap-header overhead while meeting the 2 GiB usable threshold. Before adding the fstab entry, verify the displayed usable size for this exact file is at least 2,147,483,648 bytes; stop if it is smaller. Record both file bytes and reported usable swap.

## Post-action acceptance and rollback

Repeat the full baseline and record exact bytes, container identities/counters and health, fstab validation, owner/mode and swap activation. Require at least 2.5 GiB available RAM, 15 GiB free disk, and the approved swap capacity. Investigate any existing-service regression and hold P3. Do not claim a 72-hour soak or peak-load capacity from this check.

If initialization fails, do not retry blindly or overwrite the file. If active swap must be removed, first obtain separate rollback approval and verify sufficient available RAM to absorb its used pages while retaining the 2.5 GiB headroom. Under pressure retain swap and stop work. An approved rollback disables only `swapoff /swapfile-cascade`, removes only the exact added fstab line after confirming it belongs to this action, validates fstab, and removes only this regular, root-owned file after confirming it is no longer active. Never use global swapoff or restore the entire fstab over unrelated edits. Preserve the protected backup and evidence.

References: [completion plan](2026-09-06-portainer-n8n-completion-plan.md), [P1 packet](2026-09-06-p1-recovery-action-packet.md), [P1 recovery proof](../validation/2026-09-06-p1-alfred-recovery.md).
