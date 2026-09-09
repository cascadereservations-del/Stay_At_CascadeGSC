#!/usr/bin/env bash
# Disposable migration rehearsal for a release contract.
#
# Restores a production backup set into a throwaway PostgreSQL container on the
# Docker host, applies the contract's migrations in timestamp order, and runs the
# contract's forward_verification queries against the result. Nothing touches
# production; the container, volume, network and temp dir are removed by trap.
#
# This is the evidence a contract-phase release needs for compatibility.verified:
# the migrations were actually executed against a copy of real production, in
# order, and the post-state was asserted.
#
# The workstation has no Docker (see the workstation-docker-repair-packet), so
# the disposable database runs on the same host the backup and restore scripts
# already use. Only decryption happens locally.
#
# Usage: migration-rehearsal-on-host.sh <backup-set-dir> <release-contract-json>
# Env:   CASCADE_SSH_HOST (default alfred), CASCADE_SSH_BIN, CASCADE_SUPABASE_PASSPHRASE_FILE
set -euo pipefail

SSH_HOST="${CASCADE_SSH_HOST:-alfred}"
SET_DIR="${1:?backup set directory is required}"
RELEASE="${2:?release contract path is required}"
PASS_FILE="${CASCADE_SUPABASE_PASSPHRASE_FILE:-$HOME/Cascade-Secrets/supabase-backup-passphrase.txt}"
# pgvector/pgvector:pg17 (PostgreSQL 17.11). Restores need the vector extension for
# kb_documents.embedding; the bare image silently lost that table (D-045).
PG_IMAGE_ID=sha256:cf134a767f474095eeba57e0117be8e568e011a63f33fbf252f14c9b760f8e6f
SSH_BIN="${CASCADE_SSH_BIN:-}"
if [[ -z "$SSH_BIN" ]]; then
  if [[ -x /c/Windows/System32/OpenSSH/ssh.exe ]]; then SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe; else SSH_BIN=ssh; fi
fi
rssh() { MSYS_NO_PATHCONV=1 "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" "$@"; }

for t in openssl sha256sum node; do command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 2; }; done
[[ -f "$SET_DIR/COMPLETE" && ! -e "$SET_DIR/INCOMPLETE" ]] || { echo 'backup set is not COMPLETE' >&2; exit 2; }
( cd "$SET_DIR" && sha256sum -c --strict SHA256SUMS >/dev/null ) || { echo 'ciphertext checksum failed' >&2; exit 3; }
echo 'ciphertext checksum verified'

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
release_abs="$(cd "$(dirname "$RELEASE")" && pwd)/$(basename "$RELEASE")"
mapfile -t MIGRATIONS < <(node -e 'const c=require(process.argv[1]);for(const m of c.migrations)process.stdout.write(m+"\n");' "$release_abs")
[[ ${#MIGRATIONS[@]} -gt 0 ]] || { echo 'release contract lists no migrations' >&2; exit 2; }
echo "migrations to rehearse: ${#MIGRATIONS[@]}"

suffix="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
prefix="cascade-migration-rehearsal-$suffix"
remote_tmp="/opt/cascade/.migration-rehearsal-$suffix"
cleanup() {
  set +e
  rssh "docker rm -f $prefix-db >/dev/null 2>&1; docker volume rm $prefix-data >/dev/null 2>&1; docker network rm $prefix-internal >/dev/null 2>&1; rm -rf $remote_tmp"
  left="$(rssh "docker ps -a -q --filter name=$prefix; docker volume ls -q --filter name=$prefix; docker network ls -q --filter name=$prefix; ls -d $remote_tmp 2>/dev/null" | grep -c . || true)"
  echo "cleanup leftovers for $prefix: $left"
}
trap cleanup EXIT

rssh "docker image inspect $PG_IMAGE_ID >/dev/null" || { echo 'pinned postgres image missing on the host' >&2; exit 3; }
rssh "mkdir -p $remote_tmp/migrations && chmod 700 $remote_tmp"

pass_path="$PASS_FILE"; command -v cygpath >/dev/null && pass_path="$(cygpath -w "$PASS_FILE")"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha512 -pass "file:$pass_path" -in "$SET_DIR/cascade-production.dump.enc" \
  | rssh "umask 077; cat > $remote_tmp/cascade-production.dump"

for m in "${MIGRATIONS[@]}"; do
  [[ -f "$repo_root/supabase/migrations/$m" ]] || { echo "missing migration file: $m" >&2; exit 2; }
  rssh "umask 077; cat > $remote_tmp/migrations/$m" < "$repo_root/supabase/migrations/$m"
done

# Forward-verification queries, one per line as name<TAB>expect<TAB>query.
node -e 'const c=require(process.argv[1]);for(const v of c.forward_verification){process.stdout.write([v.name,String(v.expect),v.query.replace(/\s+/g," ")].join("\t")+"\n");}' "$release_abs" \
  | rssh "umask 077; cat > $remote_tmp/checks.tsv"

rssh bash -s -- "$prefix" "$remote_tmp" "$PG_IMAGE_ID" <<'REMOTE'
set -euo pipefail
prefix="$1"; R="$2"; PG="$3"
db="$prefix-db"; vol="$prefix-data"; net="$prefix-internal"
pw="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
umask 077; printf 'POSTGRES_DB=rehearsal\nPOSTGRES_USER=rehearsal\nPOSTGRES_PASSWORD=%s\n' "$pw" > "$R/pg.env"; unset pw
docker network create --internal "$net" >/dev/null
docker volume create "$vol" >/dev/null
docker run -d --name "$db" --network "$net" --env-file "$R/pg.env" -v "$vol:/var/lib/postgresql/data" -v "$R:/work:ro" --memory 768m --cpus 1 "$PG" >/dev/null
ready=0
for i in $(seq 1 45); do
  if docker logs "$db" 2>&1 | grep -q 'PostgreSQL init process complete' && docker exec "$db" pg_isready -U rehearsal -d rehearsal >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[[ $ready -eq 1 ]] || { echo 'disposable PostgreSQL did not become ready' >&2; exit 5; }

# Supabase dumps reference roles and extensions a bare image does not have. The
# restore is expected to report those; what must survive is the public schema.
docker exec "$db" pg_restore --no-owner --no-acl -U rehearsal -d rehearsal /work/cascade-production.dump > "$R/restore.log" 2>&1 || true
before_tables="$(docker exec "$db" psql -At -U rehearsal -d rehearsal -c "select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE'")"
before_ledger="$(docker exec "$db" psql -At -U rehearsal -d rehearsal -c "select count(*) from supabase_migrations.schema_migrations")"
echo "restored baseline: $before_tables public tables, $before_ledger ledger rows"

# The dump omits Supabase-managed schemas and roles; the migrations reference
# auth.uid(), extensions.*, and GRANT/REVOKE the anon/authenticated/service_role
# roles. Provide the minimum shims the DDL needs to execute. These are local to
# the disposable container and never touch production.
cat > "$R/shims.sql" <<'SHIM'
create schema if not exists auth;
create schema if not exists extensions;
create or replace function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
create extension if not exists "uuid-ossp" schema extensions;
create extension if not exists pgcrypto schema extensions;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated','service_role','authenticator'] loop
    if not exists (select 1 from pg_roles where rolname = r) then
      execute format('create role %I nologin noinherit', r);
    end if;
  end loop;
end $$;
SHIM
docker exec "$db" psql -v ON_ERROR_STOP=1 -U rehearsal -d rehearsal -f /work/shims.sql >/dev/null 2>&1 </dev/null
echo "compatibility shims installed (auth.uid, uuid-ossp, pgcrypto, supabase roles)"

applied=0; failed=0
for f in $(ls "$R/migrations" | sort); do
  # No -i: this script's own stdin is the remote heredoc, and an interactive
  # docker exec consumes it, silently truncating everything after the loop.
  if docker exec "$db" psql -v ON_ERROR_STOP=1 -U rehearsal -d rehearsal -f "/work/migrations/$f" > "$R/$f.log" 2>&1 </dev/null; then
    applied=$((applied+1)); echo "applied  $f"
  else
    failed=$((failed+1)); echo "FAILED   $f"; tail -5 "$R/$f.log" >&2
  fi
done
echo "migrations applied: $applied, failed: $failed"
[[ $failed -eq 0 ]] || { echo 'a migration failed against restored production' >&2; exit 6; }

pass=0; fail=0
while IFS=$'\t' read -r name expect query; do
  [[ -n "${name:-}" ]] || continue
  got="$(docker exec "$db" psql -At -U rehearsal -d rehearsal -c "$query" 2>"$R/check.err" || echo ERROR)"
  if { [[ "$got" == "t" ]] && [[ "$expect" == "true" ]]; } || { [[ "$got" == "f" ]] && [[ "$expect" == "false" ]]; }; then
    pass=$((pass+1)); echo "  ok    $name"
  else
    fail=$((fail+1)); echo "  FAIL  $name (got '$got', expected $expect)"; head -2 "$R/check.err" >&2
  fi
done < "$R/checks.tsv"
echo "forward verification: $pass passed, $fail failed"

after_tables="$(docker exec "$db" psql -At -U rehearsal -d rehearsal -c "select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE'")"
echo "public tables after: $after_tables (was $before_tables)"
[[ "$(docker network inspect "$net" --format '{{.Internal}}')" == "true" ]] || { echo 'network not internal' >&2; exit 5; }
[[ -z "$(docker ps -a --filter "name=$prefix" --format '{{.Ports}}' | grep -- '->' || true)" ]] || { echo 'published a host port' >&2; exit 5; }
[[ $fail -eq 0 ]] || { echo 'forward verification failed' >&2; exit 7; }
echo "Migration rehearsal passed: prefix=$prefix"
REMOTE
