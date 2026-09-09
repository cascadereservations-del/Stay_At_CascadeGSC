#!/usr/bin/env bash
# Run ONE reviewed SQL file against production over the same path
# apply-release-on-host.sh uses: psql inside the pinned postgres image on the
# Docker host, connection parameters in a root-only env file for the duration of
# the run, removed by trap. Nothing is ever printed except psql's own output.
#
# This exists for reviewed maintenance SQL that is not a release contract, such
# as docs/plans/2026-09-09-ledger-reconciliation.sql. It is NOT a migration
# runner: it records no ledger row, so never use it to apply a migration file.
#
# The file is executed under ON_ERROR_STOP; wrap it in begin/commit yourself
# so a failure rolls back as one unit.
#
# Usage: run-sql-on-host.sh <sql-file>
# Env:   CASCADE_SSH_HOST (default alfred), CASCADE_SSH_BIN, CASCADE_PW_MODE,
#        CASCADE_SUPABASE_URL_FILE
set -euo pipefail

SSH_HOST="${CASCADE_SSH_HOST:-alfred}"
SQL_FILE="${1:?sql file path is required}"
URL_FILE="${CASCADE_SUPABASE_URL_FILE:-$HOME/Cascade-Secrets/supabase-production-db-url.txt}"
PW_MODE="${CASCADE_PW_MODE:-decoded}"
PG_IMAGE_ID=sha256:7456ef82e5f5bc43d997f4781bbd7c0d6389bff397564649a356e206ba473aee
SSH_BIN="${CASCADE_SSH_BIN:-}"
if [[ -z "$SSH_BIN" ]]; then
  if [[ -x /c/Windows/System32/OpenSSH/ssh.exe ]]; then SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe; else SSH_BIN=ssh; fi
fi
rssh() { MSYS_NO_PATHCONV=1 "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" "$@"; }

command -v node >/dev/null || { echo 'node is required' >&2; exit 2; }
[[ -s "$URL_FILE" ]] || { echo 'connection URL file is missing or empty' >&2; exit 2; }
[[ -s "$SQL_FILE" ]] || { echo 'sql file is missing or empty' >&2; exit 2; }
[[ "$PW_MODE" == decoded || "$PW_MODE" == literal ]] || { echo 'CASCADE_PW_MODE must be decoded or literal' >&2; exit 2; }

# Identical to apply-release-on-host.sh: libpq env lines from the stored URL, never echoed.
emit_pg_env() {
  node - "$URL_FILE" "$PW_MODE" <<'NODE'
const fs = require("fs");
const u = new URL(fs.readFileSync(process.argv[2], "utf8").trim());
if (!/^postgres(ql)?:$/.test(u.protocol) || !u.username || !u.password || !u.hostname) process.exit(3);
const pw = process.argv[3] === "literal" ? u.password : decodeURIComponent(u.password);
process.stdout.write(
  "PGHOST=" + u.hostname + "\n" +
  "PGPORT=" + (u.port || "5432") + "\n" +
  "PGUSER=" + decodeURIComponent(u.username) + "\n" +
  "PGDATABASE=" + (u.pathname.replace(/^\//, "") || "postgres") + "\n" +
  "PGPASSWORD=" + pw + "\n" +
  "PGSSLMODE=require\n"
);
NODE
}

suffix="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
remote_tmp="/opt/cascade/.sql-run-$suffix"
cleanup() { set +e; rssh "rm -rf $remote_tmp"; }
trap cleanup EXIT

rssh "docker image inspect $PG_IMAGE_ID >/dev/null" || { echo 'pinned postgres image missing on the host' >&2; exit 3; }
rssh "mkdir -p $remote_tmp && chmod 700 $remote_tmp"
emit_pg_env | rssh "umask 077; cat > $remote_tmp/pg.env"
rssh "umask 077; cat > $remote_tmp/run.sql" < "$SQL_FILE"
echo "running $(basename "$SQL_FILE") on $SSH_HOST"

rssh bash -s -- "$remote_tmp" "$PG_IMAGE_ID" <<'REMOTE'
set -euo pipefail
R="$1"; PG="$2"
docker run --rm --env-file "$R/pg.env" -v "$R:/work:ro" "$PG" psql -v ON_ERROR_STOP=1 -f /work/run.sql </dev/null
REMOTE
echo "sql run finished"
