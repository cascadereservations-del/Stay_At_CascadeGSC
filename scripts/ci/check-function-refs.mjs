// Static guard for the disposable recovery database: walks the prepared plan order (prerequisites, baseline,
// compatibility, then bridges and forward migrations merged by version) and fails when a GRANT / REVOKE / ALTER /
// COMMENT ON FUNCTION public.NAME( refers to a function no earlier file creates. Name-level matching only.
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { buildRecoveryMigrationPlan } from '../recovery/recovery-contract.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

function stripComments(sql) {
  return sql.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/--[^\n]*/g, ' ');
}

const CREATE_RE = /\bcreate\s+(?:or\s+replace\s+)?function\s+(?:"?public"?\.)?"?([a-z_][a-z0-9_]*)"?\s*\(/gi;

function refsOf(sql) {
  const found = [];
  for (const statement of sql.split(';')) {
    const head = statement.trim().toLowerCase();
    let pattern;
    if (/^(grant|revoke)\b/.test(head)) pattern = /\bon\s+function\s+"?public"?\."?([a-z_][a-z0-9_]*)"?\s*\(/i;
    else if (/^alter\s+function\b/.test(head)) pattern = /^alter\s+function\s+"?public"?\."?([a-z_][a-z0-9_]*)"?\s*\(/i;
    else if (/^comment\s+on\s+function\b/.test(head)) pattern = /^comment\s+on\s+function\s+"?public"?\."?([a-z_][a-z0-9_]*)"?\s*\(/i;
    else continue;
    const match = pattern.exec(head);
    if (match) found.push(match[1]);
  }
  return found;
}

// files: [{ name, sql }] in execution order. Returns [{ file, fn }] gaps.
export function findFunctionGaps(files) {
  const created = new Set();
  const gaps = [];
  for (const { name, sql } of files) {
    const clean = stripComments(sql);
    for (const match of clean.matchAll(CREATE_RE)) created.add(match[1].toLowerCase());
    // ALTER FUNCTION ... RENAME TO also brings a name into existence.
    for (const match of clean.matchAll(/\balter\s+function\s+[^;]*?\brename\s+to\s+"?([a-z_][a-z0-9_]*)"?/gi)) created.add(match[1].toLowerCase());
    for (const fn of refsOf(clean)) {
      if (!created.has(fn)) gaps.push({ file: name, fn });
    }
  }
  return gaps;
}

export function loadPreparedPlan(sourceSupabase = path.join(repoRoot, 'supabase')) {
  const manifest = JSON.parse(readFileSync(path.join(sourceSupabase, 'recovery', 'baseline.json'), 'utf8'));
  const read = relative => readFileSync(path.join(sourceSupabase, ...relative.split('/')), 'utf8');
  const migrationDirectory = path.join(sourceSupabase, 'migrations');
  const plan = buildRecoveryMigrationPlan(manifest, readdirSync(migrationDirectory).filter(name => name.endsWith('.sql')));
  const bridges = new Set(manifest.recovery_bridge_migrations ?? []);
  return plan.map((name, index) => {
    if (index === 0) return { name, sql: read(manifest.prerequisite_source) };
    if (index === 1) return { name, sql: read(manifest.baseline_source) };
    if (index === 2) return { name, sql: read(manifest.compatibility_source) };
    if (bridges.has(name)) return { name, sql: read(`recovery/bridges/${name}`) };
    return { name, sql: readFileSync(path.join(migrationDirectory, name), 'utf8') };
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const gaps = findFunctionGaps(loadPreparedPlan());
  if (gaps.length) {
    for (const gap of gaps) process.stderr.write(`${gap.file}: references public.${gap.fn}( but no earlier file creates it\n`);
    process.exitCode = 1;
  } else {
    process.stdout.write('check-function-refs: 0 gaps\n');
  }
}
