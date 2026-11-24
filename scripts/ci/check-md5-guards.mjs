import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  buildRecoveryMigrationPlan,
  prepareRecoveryMigrationContent,
  validateRecoveryBaselineManifest,
} from '../recovery/recovery-contract.mjs';
import { formatMd5GuardReport, simulateMd5Guards, summarizeMd5Guards } from '../recovery/md5-guards.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

// Guards that are known not to match and are accepted, as { migration, signature, reason }. Keep it empty unless a
// mismatch is understood and cannot be bridged.
export const ALLOWLIST = [];

export function buildPreparedChain(sourceSupabase) {
  const manifest = JSON.parse(readFileSync(path.join(sourceSupabase, 'recovery', 'baseline.json'), 'utf8'));
  const readSource = relativePath => readFileSync(path.join(sourceSupabase, ...relativePath.split('/')), 'utf8');
  const baselineSql = readSource(manifest.baseline_source);
  const prerequisiteSql = readSource(manifest.prerequisite_source);
  const compatibilitySql = readSource(manifest.compatibility_source);
  const bridgeSql = Object.fromEntries((manifest.recovery_bridge_migrations ?? []).map(name => [
    name,
    readFileSync(path.join(sourceSupabase, 'recovery', 'bridges', name), 'utf8'),
  ]));
  const validated = validateRecoveryBaselineManifest(manifest, { baselineSql, prerequisiteSql, compatibilitySql, bridgeSql });
  const migrationsDirectory = path.join(sourceSupabase, 'migrations');
  const plan = buildRecoveryMigrationPlan(validated, readdirSync(migrationsDirectory).filter(name => name.endsWith('.sql')));
  const chain = [
    { label: plan[0], kind: 'base', sql: prerequisiteSql },
    { label: plan[1], kind: 'base', sql: baselineSql },
    { label: plan[2], kind: 'base', sql: compatibilitySql },
  ];
  for (const file of plan.slice(3)) {
    if (file in bridgeSql) { chain.push({ label: file, kind: 'bridge', sql: bridgeSql[file] }); continue; }
    const source = readFileSync(path.join(migrationsDirectory, file), 'utf8');
    chain.push({
      label: file,
      kind: 'forward',
      sql: prepareRecoveryMigrationContent(file, source, validated.recovery_assertion_only_migrations, validated.recovery_statement_omissions),
    });
  }
  return chain;
}

function main() {
  const chain = buildPreparedChain(path.join(repoRoot, 'supabase'));
  const rows = simulateMd5Guards(chain, { allowlist: ALLOWLIST });
  const { counts, failing } = summarizeMd5Guards(rows);
  process.stdout.write(`${formatMd5GuardReport(rows)}\n\n`);
  process.stdout.write(`md5 guards: ${rows.length} checked, MATCH ${counts.MATCH}, DIFF ${counts.DIFF}, MISSING ${counts.MISSING}, DYNAMIC (patched at run time, not verifiable here) ${counts.DYNAMIC}, failing ${failing.length}\n`);
  if (failing.length > 0) process.exitCode = 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
