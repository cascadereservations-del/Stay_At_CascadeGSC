#!/usr/bin/env bash
# Pin the four images Watchtower has been auto-updating on alfred, and switch
# Watchtower to opt-in mode so it updates nothing unless a container carries
# com.centurylinklabs.watchtower.enable=true.
#
# Runs ON ALFRED as root:   sudo bash pin-watchtower-images.sh
# Agents are classifier-blocked from running this; Lloyd runs it (D-050).
#
# What it changes:
#   /opt/budget-tracker/docker-compose.yml           backend, frontend -> digest
#   /opt/alfred/deploy/docker-compose*.yml           n8n, metabase     -> digest
#   Portainer stack 3 (watchtower) compose           + WATCHTOWER_LABEL_ENABLE=true
# What it recreates: ONLY watchtower-watchtower-1. The four production containers
# already run exactly these digests, so nothing else restarts.
# Rollback: every file gets a .bak-<UTC> copy first; restore it and
#           `docker compose -p watchtower up -d` again.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'run with sudo' >&2; exit 2; }

TS=$(date -u +%Y%m%dT%H%M%SZ)
BT=/opt/budget-tracker/docker-compose.yml
DP=/opt/alfred/deploy/docker-compose.yml
DO=/opt/alfred/deploy/docker-compose.override.yml
WT=/var/lib/docker/volumes/infra_portainer_data/_data/compose/3/docker-compose.yml
for f in "$BT" "$DP" "$DO" "$WT"; do cp -p "$f" "$f.bak-$TS"; done
echo "backups written with suffix .bak-$TS"

# Digests observed running on 2026-09-09 (docker image inspect ... RepoDigests).
python3 - "$BT" "$DP" "$DO" "$WT" <<'PY'
import sys
bt, dp, do, wt = sys.argv[1:5]
pins = {
 "letehaha/budget-tracker-be:latest": "letehaha/budget-tracker-be@sha256:025b510fa45f8dadb263325a62158c4c5d06843228587ba48d6aa6b2c0c67c59",
 "letehaha/budget-tracker-fe:latest": "letehaha/budget-tracker-fe@sha256:4e59662cd67e01f5ecc4ba0ff5fb2cb801963b90e2d97b8ce0864a6c60f2f826",
 "n8nio/n8n:latest":                  "n8nio/n8n@sha256:9f21fbf422982bbdddc31085c180bef82d59cc608ba16dfec4fc48611d0b51b8",
 "metabase/metabase:latest":          "metabase/metabase@sha256:94e647ce8ad35a639980778e9d422e5d55fcb48b5f7f1a055723ff4ee1faa46d",
}
files = [bt, dp, do]
texts = {f: open(f).read() for f in files}
count = {k: sum(t.count(k) for t in texts.values()) for k in pins}
bad = {k: c for k, c in count.items() if c != 1}
if bad:
    sys.exit("refusing: expected exactly one occurrence of each tag, got %s" % bad)
for f, t in texts.items():
    n = t
    for k, v in pins.items():
        n = n.replace(k, v)
    if n != t:
        open(f, "w").write(n); print("pinned:", f)
t = open(wt).read()
if "WATCHTOWER_LABEL_ENABLE" in t:
    print("watchtower already opt-in")
else:
    marker = '"WATCHTOWER_CLEANUP=true"'
    if marker not in t:
        sys.exit("refusing: watchtower compose shape unexpected")
    t = t.replace(marker, marker + ', "WATCHTOWER_LABEL_ENABLE=true"', 1)
    open(wt, "w").write(t); print("watchtower set to opt-in (label-enable)")
PY

(cd /opt/budget-tracker && docker compose config --quiet && echo "budget-tracker compose valid")
(cd /opt/alfred/deploy && docker compose config --quiet && echo "deploy compose valid")
cd "$(dirname "$WT")" && docker compose -p watchtower up -d
docker inspect watchtower-watchtower-1 --format '{{.Config.Env}}' | grep -q 'WATCHTOWER_LABEL_ENABLE=true' && echo "watchtower recreated in opt-in mode"
echo "--- production containers must all still show their previous uptime ---"
docker ps --format '{{.Names}} {{.Status}}' | grep -E 'budget-tracker-prod-(backend|frontend)-1|^n8n |^metabase '
