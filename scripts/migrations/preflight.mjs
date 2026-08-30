import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { migrationVersions, parseAppliedMigrationVersions, validateSourceState } from './release-safety.mjs';
import { resolveReleasePath, verify } from './verify-expand-contract.mjs';

function option(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : null;
}

function localLedger(root) {
  const windows = process.platform === 'win32';
  const executable = windows ? (process.env.ComSpec ?? 'cmd.exe') : 'npx';
  const args = windows
    ? ['/d', '/s', '/c', 'npx.cmd --yes supabase migration list --local']
    : ['--yes', 'supabase', 'migration', 'list', '--local'];
  const result = spawnSync(executable, args, {
    cwd: root,
    encoding: 'utf8',
    shell: false,
  });
  if (result.error) throw new Error(`local migration ledger unavailable: ${result.error.message}`);
  if (result.status !== 0) throw new Error(`local migration ledger unavailable: ${String(result.stderr || result.stdout || '').trim()}`);
  return result.stdout;
}

try {
  if (!process.argv.includes('--local')) throw new Error('preflight is read-only and requires explicit --local mode');
  const root = resolve(option('--root') ?? process.cwd());
  const release = resolveReleasePath(root, option('--release'));
  const result = verify(root, release);
  const errors = [...result.errors, ...validateSourceState(result.contract, root)];
  const ledgerFile = option('--ledger-file');
  const ledgerOutput = ledgerFile ? readFileSync(resolve(ledgerFile), 'utf8') : localLedger(root);
  const applied = parseAppliedMigrationVersions(ledgerOutput);
  for (const version of migrationVersions(result.contract)) {
    if (!applied.has(version)) errors.push(`missing from local migration ledger: ${version}`);
  }
  if (errors.length) {
    for (const error of errors) console.error(error);
    process.exitCode = 1;
  } else {
    console.log(JSON.stringify({ ok: true, mode: 'local', release_id: result.contract.release_id, applied_migrations: result.contract.migrations.length }));
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
