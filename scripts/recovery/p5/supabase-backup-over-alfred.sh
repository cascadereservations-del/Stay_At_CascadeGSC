#!/usr/bin/env bash
# P5 gate 1: encrypted logical backup of the Cascade Supabase production database.
# pg_dump runs inside the pinned postgres:17.11 image on Alfred (the only reachable
# Docker host); the dump streams over SSH and is encrypted on the workstation with
# OpenSSL using the owner-only passphrase file. The passphrase never leaves the
# workstation; connection parameters are placed in a root-only env file on Alfred for
# the duration of the dump and removed by trap. No plaintext dump touches any disk.
# Usage: supabase-backup-over-alfred.sh
# Env:   CASCADE_BACKUP_DIR, CASCADE_SSH_HOST, CASCADE_PW_MODE=decoded|literal
set -euo pipefail

SSH_HOST="${CASCADE_SSH_HOST:-alfred}"
BACKUP_ROOT="${CASCADE_BACKUP_DIR:-C:/Cascade-Backups}"
URL_FILE="${CASCADE_SUPABASE_URL_FILE:-$HOME/Cascade-Secrets/supabase-production-db-url.txt}"
PASS_FILE="${CASCADE_SUPABASE_PASSPHRASE_FILE:-$HOME/Cascade-Secrets/supabase-backup-passphrase.txt}"
PW_MODE="${CASCADE_PW_MODE:-decoded}"
PG_IMAGE_ID=sha256:7456ef82e5f5bc43d997f4781bbd7c0d6389bff397564649a356e206ba473aee
SSH_BIN="${CASCADE_SSH_BIN:-}"
if [[ -z "$SSH_BIN" ]]; then
  if [[ -x /c/Windows/System32/OpenSSH/ssh.exe ]]; then SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe; else SSH_BIN=ssh; fi
fi
rssh() { MSYS_NO_PATHCONV=1 "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" "$@"; }

for t in openssl sha256sum node; do command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 2; }; done
[[ -s "$URL_FILE" ]] || { echo 'connection URL file is missing or empty' >&2; exit 2; }
[[ -s "$PASS_FILE" ]] || { echo 'passphrase file is missing or empty' >&2; exit 2; }
[[ "$PW_MODE" == decoded || "$PW_MODE" == literal ]] || { echo 'CASCADE_PW_MODE must be decoded or literal' >&2; exit 2; }
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
case "$BACKUP_ROOT" in "$repo_root"*) echo 'Backups must be stored outside the repository.' >&2; exit 2;; esac

# Emits libpq environment lines from the stored URL without printing anything to the terminal.
# decoded: percent-decode the password like a URI parser; literal: pass the stored bytes verbatim.
emit_pg_env() {
  node - "$URL_FILE" "$PW_MODE" <<'NODE'
const fs = require("fs");
const u = new URL(fs.readFileSync(process.argv[2], "utf8").trim());
if (!/^postgres(ql)?:$/.test(u.protocol) || !u.username || !u.password || !u.hostname) process.exit(3);
const pw = process.argv[3] === "literal" ? u.password : decodeURIComponent(u.password);
const db = u.pathname.replace(/^\//, "") || "postgres";
process.stdout.write(
  "PGHOST=" + u.hostname + "\n" +
  "PGPORT=" + (u.port || "5432") + "\n" +
  "PGUSER=" + decodeURIComponent(u.username) + "\n" +
  "PGDATABASE=" + db + "\n" +
  "PGPASSWORD=" + pw + "\n" +
  "PGSSLMODE=require\n");
NODE
}
emit_pg_env >/dev/null || { echo 'connection URL is not a valid postgres URL' >&2; exit 2; }

ts="$(date -u +%Y%m%dT%H%M%SZ)"
set_dir="$BACKUP_ROOT/cascade-supabase-$ts"
mkdir -p "$set_dir"
echo 'Backup has not completed.' > "$set_dir/INCOMPLETE"
suffix="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
remote_tmp="/opt/cascade/.supabase-backup-$suffix"
cleanup() { rssh "rm -rf $remote_tmp" >/dev/null 2>&1 || true; }
trap cleanup EXIT

rssh "docker image inspect $PG_IMAGE_ID >/dev/null" || { echo 'pinned postgres image missing on Alfred' >&2; exit 3; }
rssh "mkdir -p $remote_tmp && chmod 700 $remote_tmp"
emit_pg_env | rssh "umask 077; cat > $remote_tmp/pg.env"

# Host networking: the Supabase direct host is IPv6-only and the Docker bridge has no IPv6 route.
# mingw OpenSSL needs a Windows path for -pass file:.
pass_path="$PASS_FILE"; command -v cygpath >/dev/null && pass_path="$(cygpath -w "$PASS_FILE")"
rssh "docker run --rm --pull never --network host --env-file $remote_tmp/pg.env $PG_IMAGE_ID pg_dump --format=custom --no-owner --no-acl" \
  | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -md sha512 -salt -pass "file:$pass_path" -out "$set_dir/cascade-production.dump.enc"
[[ -s "$set_dir/cascade-production.dump.enc" ]] || { echo 'encrypted dump is empty' >&2; exit 4; }
trap - EXIT; cleanup

( cd "$set_dir" && sha256sum cascade-production.dump.enc > SHA256SUMS )
{
  echo 'Cascade production logical backup'
  echo "created_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo 'format=pg_dump custom (postgres 17.11 client on Alfred, pinned image)'
  echo 'encryption=openssl aes-256-cbc pbkdf2 sha512 600000 iterations (workstation)'
  echo 'restore_proof=not yet performed'
  echo 'contains_production_personal_data=true'
} > "$set_dir/MANIFEST.txt"
rm -f "$set_dir/INCOMPLETE"; printf '%s\n' "$ts" > "$set_dir/COMPLETE"
echo "Encrypted Cascade production backup created: $set_dir"
echo "size_bytes=$(stat -c %s "$set_dir/cascade-production.dump.enc")"
cut -c1-16 "$set_dir/SHA256SUMS"
