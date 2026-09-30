#!/usr/bin/env bash
# Cascade's own OmniRoute (D-287, Lloyd 2026-09-30: "host the cascade omniroute on the vps, separate stack"; never Alfred's).
# A separate stack on alfred: its own dir, volume, port (20129), password and provider keys, and no Alfred network. Only
# https://omniroute-cascade.rocloyd.com/v1/* is public (the Cascade functions call it with an OmniRoute API key); every
# other path answers 404, so the dashboard is reached over SSH only:  ssh -L 20129:localhost:20129 alfred  ->  http://localhost:20129
# Idempotent: a re-run keeps the password, the volume and the tunnel entry. Run as root on alfred.
set -euo pipefail
DIR=/opt/cascade-omniroute
HOST=omniroute-cascade.rocloyd.com
CFG=/etc/cloudflared/config.yml

echo "== 1 image, pinned by digest (Alfred's stack runs :latest; Cascade's does not move under it)"
docker pull -q diegosouzapw/omniroute:latest >/dev/null
DIGEST=$(docker image inspect diegosouzapw/omniroute:latest --format '{{index .RepoDigests 0}}')
echo "   $DIGEST"

echo "== 2 stack files in $DIR"
mkdir -p "$DIR"; chmod 700 "$DIR"
if [ ! -f "$DIR/.env" ]; then
  echo "INITIAL_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-28)" > "$DIR/.env"
  chmod 600 "$DIR/.env"
  echo "   new dashboard password written to $DIR/.env (read it with: ssh alfred cat $DIR/.env)"
fi
cat > "$DIR/docker-compose.yml" <<EOF
name: cascade-omniroute
services:
  omniroute:
    image: $DIGEST
    container_name: cascade-omniroute
    restart: unless-stopped
    stop_grace_period: 40s
    env_file: .env
    ports:
      - "127.0.0.1:20129:20128"
      - "[::1]:20129:20128"
    volumes:
      - cascade-omniroute-data:/app/data
volumes:
  cascade-omniroute-data:
EOF

echo "== 3 start"
docker compose -f "$DIR/docker-compose.yml" up -d
code=000
for _ in $(seq 1 30); do code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:20129/ || true); [ "$code" != "000" ] && break; sleep 2; done
echo "   http://localhost:20129/ -> $code"
[ "$code" != "000" ] || { echo "cascade-omniroute did not answer"; exit 1; }

echo "== 4 tunnel: $HOST, /v1/ only"
if ! grep -q "hostname: $HOST" "$CFG"; then
  cp "$CFG" "$CFG.bak-$(date +%Y%m%d%H%M)-cascade-omniroute"
  sed -i "s#^  - service: http_status:404\$#  - hostname: $HOST\n    path: ^/v1/\n    service: http://localhost:20129\n  - hostname: $HOST\n    service: http_status:404\n  - service: http_status:404#" "$CFG"
fi
cloudflared tunnel --config "$CFG" ingress validate
echo "   restarting cloudflared (the other tunnel hostnames blip for a few seconds)"
systemctl restart cloudflared
sleep 5
systemctl is-active cloudflared

echo "== 5 local checks"
curl -s -o /dev/null -w "   /v1/models without a key -> %{http_code} (401 expected)\n" http://localhost:20129/v1/models
docker ps --filter name=cascade-omniroute --format '   {{.Names}} {{.Status}} {{.Ports}}'
