#!/usr/bin/env bash
# P4 disposable restore proof for a backup set produced by backup-over-ssh.sh.
# Driven from the owner workstation; disposable resources are created on Alfred
# with the prefix cascade-restore-check-<suffix>, an internal-only network, no
# host port, pinned image IDs, and are removed by trap. The age identity never
# leaves the workstation: ciphertext is decrypted here and streamed over SSH into
# a root-only temporary directory on Alfred, which is deleted at the end.
# Usage: restore-check-on-alfred.sh <backup-set-dir>
set -euo pipefail

SSH_HOST="${CASCADE_SSH_HOST:-alfred}"
SET_DIR="${1:?backup set directory is required}"
# Owner-only recovery identity; defaults to the P3 custody location outside Git.
AGE_IDENTITY_FILE="${AGE_IDENTITY_FILE:-$HOME/Cascade-Secrets/cascade-n8n-recovery-age.txt}"
SOURCE_WORKFLOWS="${CASCADE_SOURCE_WORKFLOWS:-automation/n8n/workflows}"
N8N_IMAGE_ID=sha256:848166b4051fd4251869f48c18455bddff922f04cb2f2676929463ba973dbde2
PG_IMAGE_ID=sha256:7456ef82e5f5bc43d997f4781bbd7c0d6389bff397564649a356e206ba473aee
EXPECTED_SEMANTIC="${CASCADE_EXPECTED_SEMANTIC:-d3077384d1bca5cf6d9941eb1a104183c3348f964ebba49741baf6436c4cd8ce}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

for t in ssh age sha256sum node tar; do command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 2; }; done
[[ -d "$SET_DIR" ]] || { echo 'BackupSet must be an existing directory.' >&2; exit 2; }
[[ -f "$AGE_IDENTITY_FILE" ]] || { echo 'AGE identity file is missing.' >&2; exit 2; }
[[ -f "$SET_DIR/COMPLETE" ]] || { echo 'Backup is not marked COMPLETE.' >&2; exit 2; }
[[ ! -e "$SET_DIR/INCOMPLETE" ]] || { echo 'Backup is marked INCOMPLETE.' >&2; exit 2; }
required=(cascade-postgres.dump.age cascade-n8n-data.tar.gz.age cascade-files.tar.gz.age cascade-environment.env.age recovery-metadata.json.age)
[[ "$(grep -c . "$SET_DIR/SHA256SUMS")" -eq 5 ]] || { echo 'SHA256SUMS must list exactly five artifacts.' >&2; exit 2; }
for f in "${required[@]}"; do grep -qE "^[a-f0-9]{64} [ *]$f\$" "$SET_DIR/SHA256SUMS" || { echo "SHA256SUMS missing $f" >&2; exit 2; }; done
( cd "$SET_DIR" && sha256sum -c --strict SHA256SUMS >/dev/null ) || { echo 'Encrypted artifact checksum failed.' >&2; exit 3; }
echo 'ciphertext checksums verified'

# Prefer Windows OpenSSH when present: it reaches the Windows ssh-agent that holds the owner key.
SSH_BIN="${CASCADE_SSH_BIN:-}"
if [[ -z "$SSH_BIN" ]]; then
  if [[ -x /c/Windows/System32/OpenSSH/ssh.exe ]]; then SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe; else SSH_BIN=ssh; fi
fi
# MSYS_NO_PATHCONV stops Git Bash rewriting /opt/... arguments into Windows paths for ssh.exe.
rssh() { MSYS_NO_PATHCONV=1 "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" "$@"; }
suffix="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
prefix="cascade-restore-check-$suffix"
remote_tmp="/opt/cascade/.restore-check-$suffix"
local_tmp="$(mktemp -d "${TMPDIR:-/tmp}/$prefix.XXXXXX")"

cleanup() {
  set +e
  # Remove only resources carrying this run's unique prefix, then the root-only temp dir.
  rssh "docker rm -f $prefix-postgres $prefix-export >/dev/null 2>&1; docker volume rm $prefix-postgres-data $prefix-n8n-data >/dev/null 2>&1; docker network rm $prefix-internal >/dev/null 2>&1; rm -rf $remote_tmp"
  rm -rf "$local_tmp"
  left="$(rssh "docker ps -a --filter name=$prefix -q; docker volume ls -q --filter name=$prefix; docker network ls -q --filter name=$prefix; ls -d $remote_tmp 2>/dev/null" | grep -c . || true)"
  echo "cleanup leftovers for $prefix: $left"
}
trap cleanup EXIT

# Remote images must already exist by exact ID (no pull, no network).
rssh "docker image inspect $N8N_IMAGE_ID $PG_IMAGE_ID >/dev/null" || { echo 'Pinned images not present on Alfred; stop.' >&2; exit 3; }

# Decrypt on the workstation, stream plaintext into a root-only remote directory.
rssh "mkdir -p $remote_tmp && chmod 700 $remote_tmp && mkdir -p $remote_tmp/export && chown 1000:1000 $remote_tmp/export"
for f in "${required[@]}"; do
  age -d -i "$AGE_IDENTITY_FILE" "$SET_DIR/$f" | rssh "umask 077; cat > $remote_tmp/${f%.age}"
done

# Everything below runs on Alfred as one guarded block; secrets are read into shell
# variables from the escrowed env and written only to 0600 env-files in remote_tmp.
rssh bash -s -- "$prefix" "$remote_tmp" "$N8N_IMAGE_ID" "$PG_IMAGE_ID" <<'REMOTE'
set -euo pipefail
prefix="$1"; R="$2"; N8N="$3"; PG="$4"
db="$prefix-postgres"; dbvol="$prefix-postgres-data"; n8nvol="$prefix-n8n-data"; net="$prefix-internal"
envf="$R/cascade-environment.env"
val() {
  local v
  [[ "$(grep -cE "^$1=" "$envf")" -eq 1 ]] || { echo "env must contain exactly one $1" >&2; exit 4; }
  v="$(grep -E "^$1=" "$envf" | cut -d= -f2- | tr -d '\r')"
  [[ "$v" =~ $2 ]] || { echo "unsafe $1 format" >&2; exit 4; }
  printf '%s' "$v"
}
DBN="$(val CASCADE_N8N_DB_NAME '^[a-z][a-z0-9_]{2,62}$')"
DBU="$(val CASCADE_N8N_DB_USER '^[a-z][a-z0-9_]{2,62}$')"
DBP="$(val CASCADE_N8N_DB_PASSWORD '^[A-Za-z0-9_-]{32,}$')"
KEY="$(val CASCADE_N8N_ENCRYPTION_KEY '^[A-Za-z0-9_-]{64,}$')"
python3 - "$R/recovery-metadata.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["schema_version"] == 1 and m["consistent_capture"] is True, "unsupported metadata"
assert m["image"] == "n8nio/n8n:2.37.10", "metadata image mismatch"
PY
umask 077
printf 'POSTGRES_DB=%s\nPOSTGRES_USER=%s\nPOSTGRES_PASSWORD=%s\n' "$DBN" "$DBU" "$DBP" > "$R/postgres.env"
{
  printf 'DB_TYPE=postgresdb\nDB_POSTGRESDB_HOST=%s\nDB_POSTGRESDB_PORT=5432\n' "$db"
  printf 'DB_POSTGRESDB_DATABASE=%s\nDB_POSTGRESDB_USER=%s\nDB_POSTGRESDB_PASSWORD=%s\n' "$DBN" "$DBU" "$DBP"
  printf 'N8N_ENCRYPTION_KEY=%s\nN8N_DIAGNOSTICS_ENABLED=false\nN8N_VERSION_NOTIFICATIONS_ENABLED=false\n' "$KEY"
  printf 'N8N_TEMPLATES_ENABLED=false\nN8N_RUNNERS_MODE=internal\n'
} > "$R/n8n.env"
unset DBP KEY

docker network create --internal "$net" >/dev/null
docker volume create "$dbvol" >/dev/null
docker volume create "$n8nvol" >/dev/null
docker run --rm --network none --user 0:0 -v "$n8nvol:/restore" -v "$R:/backup:ro" --entrypoint sh "$N8N" -c 'cd /restore && tar -xzf /backup/cascade-n8n-data.tar.gz && chown -R 1000:1000 /restore'
mkdir -p "$R/files" && tar -xzf "$R/cascade-files.tar.gz" -C "$R/files"
docker run -d --name "$db" --network "$net" --env-file "$R/postgres.env" -v "$dbvol:/var/lib/postgresql/data" --memory 512m --cpus 0.5 "$PG" >/dev/null
ready=0
for i in $(seq 1 45); do
  # The official image runs a temporary server during initdb; wait for init to finish, then for readiness.
  if docker logs "$db" 2>&1 | grep -q 'PostgreSQL init process complete' && docker exec "$db" pg_isready -U "$DBU" -d "$DBN" >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[[ $ready -eq 1 ]] || { echo 'Disposable PostgreSQL did not become ready.' >&2; exit 5; }
docker cp "$R/cascade-postgres.dump" "$db:/tmp/cascade-postgres.dump"
docker exec "$db" pg_restore --exit-on-error --no-owner --no-acl -U "$DBU" -d "$DBN" /tmp/cascade-postgres.dump
counts="$(docker exec "$db" psql -At -U "$DBU" -d "$DBN" -c "select json_build_object('workflow_count',(select count(*) from workflow_entity),'active_workflow_count',(select count(*) from workflow_entity where active),'credential_count',(select count(*) from credentials_entity));")"
python3 - "$R/recovery-metadata.json" "$counts" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); a = json.loads(sys.argv[2])
for f in ("workflow_count", "active_workflow_count", "credential_count"):
    assert int(a[f]) == int(m[f]), f"restored {f} {a[f]} != captured {m[f]}"
print("restored aggregates match capture:", json.dumps(a))
PY
docker run --rm --name "$prefix-export" --network "$net" --env-file "$R/n8n.env" -v "$n8nvol:/home/node/.n8n" -v "$R/export:/out" --memory 768m --cpus 1 "$N8N" export:workflow --backup --output=/out >/dev/null
[[ "$(docker network inspect "$net" --format '{{.Internal}}')" == "true" ]] || { echo 'restore network is not internal' >&2; exit 5; }
# Only host bindings (rendered as "host->container") count; an image's EXPOSE alone is not a published port.
ports="$(docker ps -a --filter "name=$prefix" --format '{{.Ports}}' | grep -- '->' || true)"
[[ -z "$ports" ]] || { echo 'restore published a host port' >&2; exit 5; }
echo "export files: $(find "$R/export" -maxdepth 1 -name '*.json' | wc -l)"
REMOTE

# Pull the exported workflow JSON (no secrets) and compare semantics with source.
mkdir -p "$local_tmp/export"
rssh "tar -czf - -C $remote_tmp/export ." | tar -xzf - -C "$local_tmp/export"
result="$(node "$repo_root/infrastructure/cascade-n8n/p4/semantic-compare.mjs" --source "$SOURCE_WORKFLOWS" --export "$local_tmp/export")"
echo "semantic comparison: $result"
printf '%s' "$result" | grep -q "\"semantic_sha256\":\"$EXPECTED_SEMANTIC\"" || { echo 'Semantic hash does not match the expected source hash.' >&2; exit 6; }
echo "Disposable isolated restore passed: prefix=$prefix"
