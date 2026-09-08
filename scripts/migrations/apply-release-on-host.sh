#!/usr/bin/env bash
# Apply a reviewed release contract's migrations to production, in timestamp order.
#
# Each migration is streamed as its exact reviewed bytes and executed inside ONE
# transaction (ON_ERROR_STOP + explicit begin/commit) together with its
# supabase_migrations.schema_migrations ledger row, so a failure leaves neither a
# half-applied schema nor a lying ledger. The version recorded is the migration
# filename's own timestamp, which keeps production and the repository in
# agreement instead of inventing a fresh version string.
#
# psql runs inside the pinned postgres image on the Docker host, the same way the
# backup script does, because the workstation has no local Docker or psql. The
# connection parameters live in a root-only env file for the duration of the run
# and are removed by trap; nothing is ever printed.
#
# This applies to PRODUCTION. Rehearse first:
#   scripts/recovery/p6/migration-rehearsal-on-host.sh <backup-set> <contract>
#
# Usage: apply-release-on-host.sh <release-contract-json> [--verify-only]
# Env:   CASCADE_SSH_HOST (default alfred), CASCADE_SSH_BIN, CASCADE_PW_MODE,
#        CASCADE_SUPABASE_URL_FILE
set -euo pipefail

SSH_HOST="${CASCADE_SSH_HOST:-alfred}"
RELEASE="${1:?release contract path is required}"
MODE="${2:-apply}"
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
[[ "$PW_MODE" == decoded || "$PW_MODE" == literal ]] || { echo 'CASCADE_PW_MODE must be decoded or literal' >&2; exit 2; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
release_abs="$(cd "$(dirname "$RELEASE")" && pwd)/$(basename "$RELEASE")"

# Refuse to apply a contract that does not validate.
node -e '
  const s = require(process.argv[1] + "/scripts/migrations/release-safety.mjs");
  const c = require(process.argv[2]);
  const errors = [...s.validateReleaseContract(c), ...s.validateMigrationFiles(c, process.argv[1])];
  if (errors.length) { console.error("contract invalid:\n  " + errors.join("\n  ")); process.exit(1); }
  console.log("contract valid: " + c.release_id + " (" + c.phase + "), " + c.migrations.length + " migrations");
' "$repo_root" "$release_abs"

mapfile -t MIGRATIONS < <(node -e 'const c=require(process.argv[1]);for(const m of c.migrations)process.stdout.write(m+"\n");' "$release_abs")

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
remote_tmp="/opt/cascade/.release-apply-$suffix"
cleanup() { set +e; rssh "rm -rf $remote_tmp"; }
trap cleanup EXIT

rssh "docker image inspect $PG_IMAGE_ID >/dev/null" || { echo 'pinned postgres image missing on the host' >&2; exit 3; }
rssh "mkdir -p $remote_tmp/migrations && chmod 700 $remote_tmp"
emit_pg_env | rssh "umask 077; cat > $remote_tmp/pg.env"

for m in "${MIGRATIONS[@]}"; do
  [[ -f "$repo_root/supabase/migrations/$m" ]] || { echo "missing migration file: $m" >&2; exit 2; }
  rssh "umask 077; cat > $remote_tmp/migrations/$m" < "$repo_root/supabase/migrations/$m"
done

node -e 'const c=require(process.argv[1]);for(const v of c.forward_verification){process.stdout.write([v.name,String(v.expect),v.query.replace(/\s+/g," ")].join("\t")+"\n");}' "$release_abs" \
  | rssh "umask 077; cat > $remote_tmp/checks.tsv"

rssh bash -s -- "$remote_tmp" "$PG_IMAGE_ID" "$MODE" <<'REMOTE'
set -euo pipefail
R="$1"; PG="$2"; MODE="$3"
pg() { docker run --rm --env-file "$R/pg.env" -v "$R:/work:ro" "$PG" psql -v ON_ERROR_STOP=1 "$@" </dev/null; }

if [[ "$MODE" != "--verify-only" ]]; then
  applied=0
  for f in $(ls "$R/migrations" | sort); do
    version="${f%%_*}"
    name="${f#*_}"; name="${name%.sql}"
    if pg -At -c "select 1 from supabase_migrations.schema_migrations where version = '$version'" | grep -q 1; then
      echo "skip     $f (already in ledger)"; continue
    fi
    # One transaction: the migration and its ledger row land together or not at all.
    {
      echo "begin;"
      cat "$R/migrations/$f"
      echo ";"
      echo "insert into supabase_migrations.schema_migrations (version, name) values ('$version', '$name');"
      echo "commit;"
    } > "$R/tx-$f"
    if pg -f "/work/tx-$f" > "$R/$f.log" 2>&1; then
      applied=$((applied+1)); echo "applied  $f  (ledger $version)"
    else
      echo "FAILED   $f"; tail -6 "$R/$f.log" >&2; exit 6
    fi
  done
  echo "migrations applied: $applied"
fi

pass=0; fail=0
while IFS=$'\t' read -r name expect query; do
  [[ -n "${name:-}" ]] || continue
  got="$(pg -At -c "$query" 2>"$R/check.err" || echo ERROR)"
  if { [[ "$got" == "t" ]] && [[ "$expect" == "true" ]]; } || { [[ "$got" == "f" ]] && [[ "$expect" == "false" ]]; }; then
    pass=$((pass+1)); echo "  ok    $name"
  else
    fail=$((fail+1)); echo "  FAIL  $name (got '$got', expected $expect)"; head -2 "$R/check.err" >&2
  fi
done < "$R/checks.tsv"
echo "forward verification: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 7
echo "Release applied and verified."
REMOTE
