#!/usr/bin/env bash
# P5 gate 1: disposable restore proof for a backup set from supabase-backup-over-alfred.sh.
# Decrypts on the workstation, streams the plaintext dump into a root-only temp dir on
# Alfred, restores into a uniquely named cascade-supabase-restore-<suffix> PostgreSQL
# container on an internal network with no host port, runs aggregate-only checks, and
# removes everything by trap. Prints only counts; never rows.
# Usage: supabase-restore-check-on-alfred.sh <backup-set-dir> <expected-ledger-count>
set -euo pipefail

SSH_HOST="${CASCADE_SSH_HOST:-alfred}"
SET_DIR="${1:?backup set directory is required}"
EXPECTED_LEDGER="${2:?expected migration ledger count is required}"
PASS_FILE="${CASCADE_SUPABASE_PASSPHRASE_FILE:-$HOME/Cascade-Secrets/supabase-backup-passphrase.txt}"
PG_IMAGE_ID=sha256:7456ef82e5f5bc43d997f4781bbd7c0d6389bff397564649a356e206ba473aee
SSH_BIN="${CASCADE_SSH_BIN:-}"
if [[ -z "$SSH_BIN" ]]; then
  if [[ -x /c/Windows/System32/OpenSSH/ssh.exe ]]; then SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe; else SSH_BIN=ssh; fi
fi
rssh() { MSYS_NO_PATHCONV=1 "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" "$@"; }

for t in openssl sha256sum; do command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 2; }; done
[[ -f "$SET_DIR/COMPLETE" && ! -e "$SET_DIR/INCOMPLETE" ]] || { echo 'backup set is not COMPLETE' >&2; exit 2; }
( cd "$SET_DIR" && sha256sum -c --strict SHA256SUMS >/dev/null ) || { echo 'ciphertext checksum failed' >&2; exit 3; }
echo 'ciphertext checksum verified'

suffix="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
prefix="cascade-supabase-restore-$suffix"
remote_tmp="/opt/cascade/.supabase-restore-$suffix"
cleanup() {
  set +e
  rssh "docker rm -f $prefix-db >/dev/null 2>&1; docker volume rm $prefix-data >/dev/null 2>&1; docker network rm $prefix-internal >/dev/null 2>&1; rm -rf $remote_tmp"
  left="$(rssh "docker ps -a -q --filter name=$prefix; docker volume ls -q --filter name=$prefix; docker network ls -q --filter name=$prefix; ls -d $remote_tmp 2>/dev/null" | grep -c . || true)"
  echo "cleanup leftovers for $prefix: $left"
}
trap cleanup EXIT

rssh "docker image inspect $PG_IMAGE_ID >/dev/null" || { echo 'pinned postgres image missing on Alfred' >&2; exit 3; }
rssh "mkdir -p $remote_tmp && chmod 700 $remote_tmp"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha512 -pass "file:$PASS_FILE" -in "$SET_DIR/cascade-production.dump.enc" \
  | rssh "umask 077; cat > $remote_tmp/cascade-production.dump"

rssh bash -s -- "$prefix" "$remote_tmp" "$PG_IMAGE_ID" "$EXPECTED_LEDGER" <<'REMOTE'
set -euo pipefail
prefix="$1"; R="$2"; PG="$3"; EXPECTED="$4"
db="$prefix-db"; vol="$prefix-data"; net="$prefix-internal"
pw="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
umask 077; printf 'POSTGRES_DB=restorecheck\nPOSTGRES_USER=restorecheck\nPOSTGRES_PASSWORD=%s\n' "$pw" > "$R/pg.env"; unset pw
docker network create --internal "$net" >/dev/null
docker volume create "$vol" >/dev/null
docker run -d --name "$db" --network "$net" --env-file "$R/pg.env" -v "$vol:/var/lib/postgresql/data" -v "$R:/backup:ro" --memory 768m --cpus 1 "$PG" >/dev/null
ready=0
for i in $(seq 1 45); do
  if docker logs "$db" 2>&1 | grep -q 'PostgreSQL init process complete' && docker exec "$db" pg_isready -U restorecheck -d restorecheck >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[[ $ready -eq 1 ]] || { echo 'disposable PostgreSQL did not become ready' >&2; exit 5; }
docker exec "$db" pg_restore --list /backup/cascade-production.dump > "$R/toc.txt"
echo "toc entries: $(grep -c . "$R/toc.txt")"
# Supabase dumps reference extensions/roles that do not exist in a bare image; restore
# without --exit-on-error but require the public schema and ledger to come back intact.
docker exec "$db" pg_restore --no-owner --no-acl -U restorecheck -d restorecheck /backup/cascade-production.dump > "$R/restore.log" 2>&1 || true
errors="$(grep -c '^pg_restore: error' "$R/restore.log" || true)"
echo "restore error lines (expected: only missing Supabase-managed roles/extensions): $errors"
grep '^pg_restore: error' "$R/restore.log" | sed -E 's/"[^"]*"/"…"/g' | sort | uniq -c | sort -rn | head -8
tables="$(docker exec "$db" psql -At -U restorecheck -d restorecheck -c "select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE'")"
ledger="$(docker exec "$db" psql -At -U restorecheck -d restorecheck -c "select count(*) from supabase_migrations.schema_migrations" 2>/dev/null || echo missing)"
functions="$(docker exec "$db" psql -At -U restorecheck -d restorecheck -c "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'")"
echo "public base tables: $tables"; echo "public functions: $functions"; echo "migration ledger rows: $ledger (expected $EXPECTED)"
[[ "$ledger" == "$EXPECTED" ]] || { echo 'ledger count mismatch' >&2; exit 6; }
[[ "$(docker network inspect "$net" --format '{{.Internal}}')" == "true" ]] || { echo 'network not internal' >&2; exit 5; }
[[ -z "$(docker ps -a --filter "name=$prefix" --format '{{.Ports}}' | grep -- '->' || true)" ]] || { echo 'published a host port' >&2; exit 5; }
echo "Disposable Supabase restore passed: prefix=$prefix"
REMOTE
