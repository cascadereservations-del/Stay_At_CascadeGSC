#!/usr/bin/env bash
# P4 encrypted backup of the dormant Cascade n8n stack on Alfred, driven from the
# owner workstation over SSH. Produces the same artifact set as backup.ps1 so
# restore-check contracts stay identical:
#   cascade-postgres.dump.age, cascade-n8n-data.tar.gz.age, cascade-files.tar.gz.age,
#   cascade-environment.env.age, recovery-metadata.json.age, SHA256SUMS, COMPLETE
# Plaintext is streamed from Alfred straight into age; nothing plaintext touches
# the workstation disk and no value is printed. Requires -Quiesce semantics:
# cascade-n8n-app is stopped for the capture window and restarted by a trap.
set -euo pipefail

SSH_HOST="${CASCADE_SSH_HOST:-alfred}"
BACKUP_ROOT="${CASCADE_BACKUP_DIR:?CASCADE_BACKUP_DIR is required (absolute path outside the repository)}"
AGE_RECIPIENT="${AGE_RECIPIENT:-}"
if [[ -z "$AGE_RECIPIENT" && -n "${AGE_RECIPIENT_FILE:-}" ]]; then AGE_RECIPIENT="$(tr -d '\r\n' < "$AGE_RECIPIENT_FILE")"; fi
[[ -n "$AGE_RECIPIENT" ]] || { echo 'AGE_RECIPIENT or AGE_RECIPIENT_FILE is required' >&2; exit 2; }
QUIESCE="${1:-}"
APP=cascade-n8n-app
PG=cascade-n8n-postgres
N8N_IMAGE_ID=sha256:848166b4051fd4251869f48c18455bddff922f04cb2f2676929463ba973dbde2
N8N_IMAGE_REF=n8nio/n8n:2.37.10
REMOTE_ENV=/opt/cascade/n8n/.env
REMOTE_FILES=/opt/cascade/n8n/files

[[ "$QUIESCE" == "--quiesce" ]] || { echo 'A consistent backup requires --quiesce and a reviewed maintenance action.' >&2; exit 2; }
for t in ssh age sha256sum; do command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 2; }; done
case "$BACKUP_ROOT" in /*|[A-Za-z]:*) ;; *) echo 'CASCADE_BACKUP_DIR must be absolute' >&2; exit 2;; esac
case "$AGE_RECIPIENT" in age1*) ;; *) echo 'AGE_RECIPIENT must be an age public recipient' >&2; exit 2;; esac
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
case "$(cd "$BACKUP_ROOT" 2>/dev/null && pwd || echo "$BACKUP_ROOT")" in "$repo_root"*) echo 'Backups must be stored outside the repository.' >&2; exit 2;; esac

# Prefer Windows OpenSSH when present: it reaches the Windows ssh-agent that holds the owner key.
SSH_BIN="${CASCADE_SSH_BIN:-}"
if [[ -z "$SSH_BIN" ]]; then
  if [[ -x /c/Windows/System32/OpenSSH/ssh.exe ]]; then SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe; else SSH_BIN=ssh; fi
fi
# MSYS_NO_PATHCONV stops Git Bash rewriting /opt/... arguments into Windows paths for ssh.exe.
rssh() { MSYS_NO_PATHCONV=1 "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" "$@"; }

ts="$(date -u +%Y%m%dT%H%M%SZ)"
set_dir="$BACKUP_ROOT/cascade-n8n-$ts"
mkdir -p "$set_dir"
echo 'Backup has not completed.' > "$set_dir/INCOMPLETE"

# Entry checks: expected containers, image identity, health.
rssh "docker inspect --format '{{.Image}}' $APP" | grep -qx "$N8N_IMAGE_ID" || { echo 'n8n image identity drifted; stop.' >&2; exit 3; }
rssh "docker inspect --format '{{with .State.Health}}{{.Status}}{{end}}' $PG" | grep -qx healthy || { echo 'postgres not healthy; stop.' >&2; exit 3; }
was_running="$(rssh "docker inspect --format '{{.State.Running}}' $APP")"

stopped=0
cleanup() {
  if [[ $stopped -eq 1 ]]; then
    rssh "docker start $APP >/dev/null" || echo 'WARNING: could not restart cascade-n8n-app; operator action required.' >&2
    for _ in $(seq 1 40); do
      s="$(rssh "docker inspect --format '{{with .State.Health}}{{.Status}}{{end}}' $APP" || true)"
      [[ "$s" == healthy ]] && break
      sleep 5
    done
    echo "post-backup app health: ${s:-unknown}"
  fi
}
trap cleanup EXIT

if [[ "$was_running" == "true" ]]; then
  quiesce_start="$(date -u +%s)"
  rssh "docker stop $APP >/dev/null"
  stopped=1
fi

# 1. PostgreSQL custom-format dump, streamed into age.
rssh "docker exec $PG sh -c 'exec pg_dump --format=custom --no-owner --no-acl --username=\"\$POSTGRES_USER\" --dbname=\"\$POSTGRES_DB\"'" \
  | age -r "$AGE_RECIPIENT" -o "$set_dir/cascade-postgres.dump.age"

# 2. Aggregate counts (no row content) for recovery metadata.
counts_json="$(rssh "docker exec -i $PG sh -c 'psql -At -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\"'" <<'SQL'
select json_build_object('workflow_count',(select count(*) from workflow_entity),'active_workflow_count',(select count(*) from workflow_entity where active),'credential_count',(select count(*) from credentials_entity));
SQL
)"
image_digest="$(rssh "docker image inspect $N8N_IMAGE_ID --format '{{index .RepoDigests 0}}'")"
[[ -n "$image_digest" ]] || { echo 'Could not resolve the n8n image digest.' >&2; exit 3; }
wf="$(printf '%s' "$counts_json" | sed -E 's/.*"workflow_count" ?: ?([0-9]+).*/\1/')"
act="$(printf '%s' "$counts_json" | sed -E 's/.*"active_workflow_count" ?: ?([0-9]+).*/\1/')"
cred="$(printf '%s' "$counts_json" | sed -E 's/.*"credential_count" ?: ?([0-9]+).*/\1/')"
printf '{\n  "schema_version": 1,\n  "captured_at": "%s",\n  "image": "%s",\n  "image_digest": "%s",\n  "workflow_count": %s,\n  "active_workflow_count": %s,\n  "credential_count": %s,\n  "consistent_capture": true\n}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$N8N_IMAGE_REF" "$image_digest" "$wf" "$act" "$cred" \
  | age -r "$AGE_RECIPIENT" -o "$set_dir/recovery-metadata.json.age"

# 3. n8n data volume, archived by the pinned n8n image itself (no new image pull), no network.
rssh "docker run --rm --network none --volumes-from $APP:ro --entrypoint tar $N8N_IMAGE_ID -czf - -C /home/node/.n8n ." \
  | age -r "$AGE_RECIPIENT" -o "$set_dir/cascade-n8n-data.tar.gz.age"

# 4. Files bind directory, archived on the host as root.
rssh "tar -czf - -C $REMOTE_FILES ." | age -r "$AGE_RECIPIENT" -o "$set_dir/cascade-files.tar.gz.age"

# 5. Environment escrow, streamed without display.
rssh "cat $REMOTE_ENV" | age -r "$AGE_RECIPIENT" -o "$set_dir/cascade-environment.env.age"

# Restart n8n before hashing so the quiescence window stays short.
if [[ $stopped -eq 1 ]]; then
  trap - EXIT; cleanup; stopped=0
  echo "quiescence seconds: $(( $(date -u +%s) - quiesce_start ))"
fi

( cd "$set_dir" && sha256sum cascade-postgres.dump.age cascade-n8n-data.tar.gz.age cascade-files.tar.gz.age cascade-environment.env.age recovery-metadata.json.age > SHA256SUMS )
rm -f "$set_dir/INCOMPLETE"
printf '%s\n' "$ts" > "$set_dir/COMPLETE"
echo "Encrypted Cascade backup created: $set_dir"
echo "aggregates: workflows=$wf active=$act credentials=$cred"
cat "$set_dir/SHA256SUMS"
