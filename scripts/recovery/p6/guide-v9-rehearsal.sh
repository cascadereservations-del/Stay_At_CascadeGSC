#!/usr/bin/env bash
# Guide v9 release rehearsal (s137), re-runnable. Never touches production: it uses migration-rehearsal-on-host.sh (disposable container on the Docker host).
#   guide-v9-rehearsal.sh <backup-set> full             apply -> checks -> committed rollbacks -> checks -> re-apply -> checks; then the 10 suites
#   guide-v9-rehearsal.sh <backup-set> mutant <name>    one mutated copy of a release migration; only the guide_v9_secrets suite; it must FAIL (names: gen-guide-v9-rehearsal.mjs list)
#   guide-v9-rehearsal.sh <backup-set> cron             the suite only, with pg_cron and pg_net shims, so the cron branch and the active check run
# Temp migrations (zzrh / zzmut) are written into supabase/migrations and always removed by trap. Logs go to .rehearsal-logs/ (git-ignored).
set -euo pipefail
SET_DIR="${1:?backup set directory}"; MODE="${2:?full | mutant <name> | cron}"; NAME="${3:-}"
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
mkdir -p .rehearsal-logs/harness
manifest=.rehearsal-logs/harness/manifest.txt
cleanup() { set +e; if [[ -f $manifest ]]; then while read -r f; do [[ -n $f ]] && rm -f "$f"; done < $manifest; rm -f $manifest; fi; }
trap cleanup EXIT
export REHEARSAL_TAP_LINES=all
export CASCADE_REHEARSAL_PRE_SQL=supabase/releases/support/s136_pre_grants.sql
SUITES=(supabase/tests/database/admin_access_simplification.sql supabase/tests/database/confirm_flow.sql supabase/tests/database/guide_v8_messages_analytics.sql
        supabase/tests/database/guide_v9_secrets.sql supabase/tests/database/inquiry_one_tap.sql supabase/tests/database/s104_close_gaps.sql
        supabase/tests/database/s110_kpi_supply_laundry.sql supabase/tests/database/s134_expenses.sql supabase/tests/database/s135_pay_extras_fix.sql
        supabase/tests/database/s136_followups.sql)
case "$MODE" in
  full)
    contract="$(node scripts/recovery/p6/gen-guide-v9-rehearsal.mjs full)"
    echo "rollback files sha256 (committed): $(sha256sum supabase/rollbacks/20261207_verify_admin_pin_bound.sql supabase/rollbacks/20261207_guide_v9_secrets.sql | tr '\n' ' ')"
    bash scripts/recovery/p6/migration-rehearsal-on-host.sh "$SET_DIR" "$contract" "${SUITES[@]}" ;;
  mutant)
    [[ -n $NAME ]] || { echo 'mutant name required' >&2; exit 2; }
    contract="$(node scripts/recovery/p6/gen-guide-v9-rehearsal.mjs mutant "$NAME")"
    bash scripts/recovery/p6/migration-rehearsal-on-host.sh "$SET_DIR" "$contract" supabase/tests/database/guide_v9_secrets.sql ;;
  cron)
    # unmutated stack: the committed files under their own names
    node -e 'const c=require("./supabase/releases/20261207_guide_v9_secrets.release.json");c.migrations=["20261206000000_guide_v8_messages_analytics.sql","20261206100000_s136_followups.sql",...c.migrations];c.migration_sha256={};require("fs").writeFileSync(".rehearsal-logs/harness/tmp-cron.release.json",JSON.stringify(c))'
    export CASCADE_REHEARSAL_PRE_SQL=.rehearsal-logs/harness/pre-cron.sql
    cat supabase/releases/support/s136_pre_grants.sql supabase/releases/support/s137_cron_net_shim.sql > "$CASCADE_REHEARSAL_PRE_SQL"
    bash scripts/recovery/p6/migration-rehearsal-on-host.sh "$SET_DIR" .rehearsal-logs/harness/tmp-cron.release.json supabase/tests/database/guide_v9_secrets.sql ;;
  *) echo 'unknown mode' >&2; exit 2 ;;
esac
