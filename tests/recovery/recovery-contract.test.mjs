import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  assertDisposableProjectId,
  buildRecoveryMigrationPlan,
  compareWorkflowSets,
  inventoryWorkflowFiles,
  normalizeWorkflow,
  prepareRecoveryMigrationContent,
  rewriteDisposableSupabaseConfig,
  selectRecoveryMigrationFiles,
  validateRecoveryBaselineManifest,
} from '../../scripts/recovery/recovery-contract.mjs';
import { prepareCommandSpawn } from '../../scripts/recovery/process-runner.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const n8nCli = path.join(repoRoot, 'scripts', 'recovery', 'verify-n8n-restore.mjs');
const supabaseCli = path.join(repoRoot, 'scripts', 'recovery', 'verify-supabase-reset.mjs');

const workflow = (name, overrides = {}) => ({
  name,
  active: false,
  nodes: [{ name: 'Manual', type: 'n8n-nodes-base.manualTrigger', parameters: {}, position: [0, 0], typeVersion: 1 }],
  connections: {},
  settings: { executionOrder: 'v1' },
  tags: [],
  ...overrides,
});

test('workflow inventory requires unique inactive JSON definitions', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'cascade-recovery-contract-'));
  try {
    await writeFile(path.join(root, 'a.json'), JSON.stringify(workflow('A')));
    await writeFile(path.join(root, 'b.json'), JSON.stringify(workflow('B')));
    const inventory = await inventoryWorkflowFiles(root);
    assert.deepEqual(inventory.map(item => item.name), ['A', 'B']);

    await writeFile(path.join(root, 'b.json'), JSON.stringify(workflow('A')));
    await assert.rejects(inventoryWorkflowFiles(root), /duplicate workflow name/i);

    await writeFile(path.join(root, 'b.json'), JSON.stringify(workflow('B', { active: true })));
    await assert.rejects(inventoryWorkflowFiles(root), /must be inactive/i);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('workflow normalization ignores generated identity but keeps executable semantics', () => {
  const source = workflow('A');
  const exported = {
    ...source,
    nodes: source.nodes.map(node => ({ ...node, id: 'generated-node-id' })),
    id: 'generated-id',
    versionId: 'generated-version',
    createdAt: '2026-08-30T00:00:00.000Z',
    updatedAt: '2026-08-30T00:01:00.000Z',
  };
  assert.deepEqual(normalizeWorkflow(exported), normalizeWorkflow(source));

  const changed = structuredClone(exported);
  changed.nodes[0].parameters = { changed: true };
  assert.notDeepEqual(normalizeWorkflow(changed), normalizeWorkflow(source));
});

test('workflow set comparison proves exact semantic round trip', () => {
  const expected = [workflow('B'), workflow('A')];
  const restored = [
    { ...workflow('A'), id: 'one', versionId: 'v1' },
    { ...workflow('B'), id: 'two', versionId: 'v2' },
  ];
  const result = compareWorkflowSets(expected, restored);
  assert.equal(result.count, 2);
  assert.deepEqual(result.names, ['A', 'B']);
  assert.match(result.semantic_sha256, /^[a-f0-9]{64}$/);

  restored[0].active = true;
  assert.throws(() => compareWorkflowSets(expected, restored), /round-trip mismatch/i);
});

test('disposable project IDs fail closed outside the recovery prefix', () => {
  assert.equal(assertDisposableProjectId('cascade-recovery-a1b2c3d4'), 'cascade-recovery-a1b2c3d4');
  for (const unsafe of ['direct-booking', 'cascade-recovery-', 'cascade-recovery-AABB', 'other-recovery-1234']) {
    assert.throws(() => assertDisposableProjectId(unsafe), /unsafe disposable project id/i);
  }
});

test('Supabase configuration rewrite changes only isolated identity, ports, and seed behavior', () => {
  const source = `project_id = "direct-booking"\n[db]\nport = 54322\nshadow_port = 54320\n[db.seed]\nenabled = true\n`;
  const rewritten = rewriteDisposableSupabaseConfig(source, {
    projectId: 'cascade-recovery-a1b2c3d4',
    dbPort: 55432,
    shadowPort: 55433,
  });
  assert.match(rewritten, /^project_id = "cascade-recovery-a1b2c3d4"/m);
  assert.match(rewritten, /^port = 55432$/m);
  assert.match(rewritten, /^shadow_port = 55433$/m);
  assert.match(rewritten, /\[db\.seed\]\nenabled = false/);
  assert.doesNotMatch(rewritten, /project_id = "direct-booking"/);

  assert.throws(
    () => rewriteDisposableSupabaseConfig(source.replace('port = 54322\n', ''), {
      projectId: 'cascade-recovery-a1b2c3d4', dbPort: 55432, shadowPort: 55433,
    }),
    /expected exactly one database port/i,
  );
});

test('recovery baseline is hash-bound and selects only post-snapshot migrations', () => {
  const baselineSql = 'create table public.example(id bigint primary key);\n';
  const prerequisiteSql = 'create extension if not exists vector with schema extensions;\n';
  const compatibilitySql = 'drop policy if exists example_policy on public.example;\n';
  const manifest = {
    schema_version: 1,
    prerequisite_migration_version: '20260823999999',
    prerequisite_source: 'recovery/prerequisites.sql',
    prerequisite_sha256: createHash('sha256').update(prerequisiteSql).digest('hex'),
    baseline_migration_version: '20260824000000',
    baseline_source: 'schemas/000_remote_public_schema.sql',
    baseline_sha256: createHash('sha256').update(baselineSql).digest('hex'),
    compatibility_migration_version: '20260824002000',
    compatibility_source: 'recovery/pre_forward_compat.sql',
    compatibility_sha256: createHash('sha256').update(compatibilitySql).digest('hex'),
    includes_through: '20260817044851',
    forward_migrations_from: '20260824002834',
  };
  const validated = validateRecoveryBaselineManifest(manifest, { baselineSql, prerequisiteSql, compatibilitySql });
  assert.equal(validated.prerequisite_migration_version, '20260823999999');
  assert.equal(validated.compatibility_migration_version, '20260824002000');
  assert.equal(validated.baseline_migration_version, '20260824000000');
  assert.deepEqual(selectRecoveryMigrationFiles([
    '20260817044851_old.sql',
    '20260824002834_first.sql',
    '20260824044700_second.sql',
  ], validated.forward_migrations_from), [
    '20260824002834_first.sql',
    '20260824044700_second.sql',
  ]);

  assert.throws(
    () => validateRecoveryBaselineManifest({ ...manifest, baseline_sha256: '0'.repeat(64) }, { baselineSql, prerequisiteSql, compatibilitySql }),
    /baseline hash mismatch/i,
  );
  assert.throws(
    () => validateRecoveryBaselineManifest({ ...manifest, prerequisite_sha256: '0'.repeat(64) }, { baselineSql, prerequisiteSql, compatibilitySql }),
    /prerequisite hash mismatch/i,
  );
  assert.throws(
    () => validateRecoveryBaselineManifest({ ...manifest, compatibility_sha256: '0'.repeat(64) }, { baselineSql, prerequisiteSql, compatibilitySql }),
    /compatibility hash mismatch/i,
  );
  assert.throws(
    () => selectRecoveryMigrationFiles(['20260824044700_second.sql'], manifest.forward_migrations_from),
    /forward migration boundary is missing/i,
  );
});

test('CI recovery plan replaces historical migrations with the verified snapshot sequence', () => {
  const manifest = {
    prerequisite_migration_version: '20260823999999',
    baseline_migration_version: '20260824000000',
    compatibility_migration_version: '20260824002000',
    forward_migrations_from: '20260824002834',
  };
  const plan = buildRecoveryMigrationPlan(manifest, [
    '20260525010807_historical.sql',
    '20260817044851_snapshot_tail.sql',
    '20260824002834_first_forward.sql',
    '20260824044700_second_forward.sql',
  ]);
  assert.deepEqual(plan, [
    '20260823999999_recovery_prerequisites.sql',
    '20260824000000_recovered_production_baseline.sql',
    '20260824002000_pre_forward_compat.sql',
    '20260824002834_first_forward.sql',
    '20260824044700_second_forward.sql',
  ]);
});

test('CI recovery plan excludes explicitly identified production-only cleanup migrations', () => {
  const manifest = {
    prerequisite_migration_version: '20260823999999',
    baseline_migration_version: '20260824000000',
    compatibility_migration_version: '20260824002000',
    forward_migrations_from: '20260824002834',
    recovery_excluded_migrations: ['20260910020000_drop_ledger_reconciliation_backup.sql'],
  };
  const plan = buildRecoveryMigrationPlan(manifest, [
    '20260824002834_first_forward.sql',
    '20260910020000_drop_ledger_reconciliation_backup.sql',
    '20260910030000_next_forward.sql',
  ]);
  assert.deepEqual(plan, [
    '20260823999999_recovery_prerequisites.sql',
    '20260824000000_recovered_production_baseline.sql',
    '20260824002000_pre_forward_compat.sql',
    '20260824002834_first_forward.sql',
    '20260910030000_next_forward.sql',
  ]);
});

test('recovery preparation retains DDL while omitting an explicitly marked production-data assertion', () => {
  const source = [
    'create or replace function public.example() returns void language sql as $$ select; $$;',
    '',
    '-- Assertions against the live data that motivated the change. These run inside',
    '-- the apply transaction, so a wrong result rolls the whole thing back.',
    'do $$ begin raise exception \'production fixture\'; end $$;',
  ].join('\n');
  const prepared = prepareRecoveryMigrationContent(
    '20260910070000_verify_turnover_requires_a_guest_checkout.sql',
    source,
    ['20260910070000_verify_turnover_requires_a_guest_checkout.sql'],
  );
  assert.match(prepared, /create or replace function public\.example/i);
  assert.doesNotMatch(prepared, /production fixture/i);
  assert.match(prepared, /omitted from the disposable recovery copy/i);
});

test('recovery baseline hashes are stable across Windows and Linux line endings', () => {
  const baselineSql = 'create table public.example(id bigint primary key);\n';
  const prerequisiteSql = 'create extension if not exists vector with schema extensions;\n';
  const compatibilitySql = 'drop policy if exists example_policy on public.example;\n';
  const hash = source => createHash('sha256').update(source.replace(/\r\n/g, '\n')).digest('hex');
  const manifest = {
    schema_version: 1,
    prerequisite_migration_version: '20260823999999',
    prerequisite_source: 'recovery/prerequisites.sql',
    prerequisite_sha256: hash(prerequisiteSql),
    baseline_migration_version: '20260824000000',
    baseline_source: 'schemas/000_remote_public_schema.sql',
    baseline_sha256: hash(baselineSql),
    compatibility_migration_version: '20260824002000',
    compatibility_source: 'recovery/pre_forward_compat.sql',
    compatibility_sha256: hash(compatibilitySql),
    includes_through: '20260817044851',
    forward_migrations_from: '20260824002834',
  };
  assert.deepEqual(
    validateRecoveryBaselineManifest(manifest, {
      baselineSql: baselineSql.replace(/\n/g, '\r\n'),
      prerequisiteSql: prerequisiteSql.replace(/\n/g, '\r\n'),
      compatibilitySql: compatibilitySql.replace(/\n/g, '\r\n'),
    }),
    manifest,
  );
});

test('recovery prerequisites leave production-managed scheduler state absent', async () => {
  const prerequisites = await readFile(path.join(repoRoot, 'supabase', 'recovery', 'prerequisites.sql'), 'utf8');
  assert.doesNotMatch(prerequisites, /create extension if not exists pg_cron/i);
});

test('recovered schema does not define the price-history view recursively', async () => {
  const schema = await readFile(path.join(repoRoot, 'supabase', 'schemas', '000_remote_public_schema.sql'), 'utf8');
  const view = schema.match(/CREATE OR REPLACE VIEW "public"\."price_history_by_item"[\s\S]*?;\r?\n/i)?.[0] ?? '';
  assert.match(view, /inventory_purchases/i);
  assert.match(view, /inventory_items/i);
  assert.doesNotMatch(view, /FROM "public"\."price_history_by_item"/i);
});

test('n8n recovery CLI rejects a missing workflow source before Docker access', () => {
  const result = spawnSync(process.execPath, [n8nCli, '--source', path.join(repoRoot, 'missing-workflows')], {
    cwd: repoRoot,
    encoding: 'utf8',
  });
  assert.notEqual(result.status, 0);
  assert.match(`${result.stdout}\n${result.stderr}`, /workflow source directory does not exist/i);
});

test('n8n recovery CLI refuses a cleanup target outside its disposable prefix', () => {
  const result = spawnSync(process.execPath, [
    n8nCli,
    '--source', path.join(repoRoot, 'automation', 'n8n', 'workflows'),
    '--volume-name', 'cascade_n8n_data',
  ], { cwd: repoRoot, encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.match(`${result.stdout}\n${result.stderr}`, /unsafe disposable n8n volume/i);
});

test('Supabase recovery CLI refuses the active project ID before Docker access', () => {
  const result = spawnSync(process.execPath, [supabaseCli, '--project-id', 'direct-booking'], {
    cwd: repoRoot,
    encoding: 'utf8',
  });
  assert.notEqual(result.status, 0);
  assert.match(`${result.stdout}\n${result.stderr}`, /unsafe disposable project id/i);
});

test('Supabase recovery CLI refuses a non-prefixed cleanup target before Docker access', () => {
  const result = spawnSync(process.execPath, [supabaseCli, '--project-id', 'other-recovery-1234'], {
    cwd: repoRoot,
    encoding: 'utf8',
  });
  assert.notEqual(result.status, 0);
  assert.match(`${result.stdout}\n${result.stderr}`, /unsafe disposable project id/i);
});

test('Windows recovery orchestration can launch the npx command shim', { skip: process.platform !== 'win32' }, () => {
  const prepared = prepareCommandSpawn('npx.cmd', ['--version'], 'win32', process.env.ComSpec);
  assert.equal(prepared.options.shell, false);
  assert.match(prepared.command, /cmd\.exe$/i);
  assert.deepEqual(prepared.args.slice(0, 3), ['/d', '/s', '/c']);
  const result = spawnSync(prepared.command, prepared.args, { ...prepared.options, encoding: 'utf8', windowsHide: true });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout.trim(), /^\d+\.\d+\.\d+/);
  assert.throws(
    () => prepareCommandSpawn('npx.cmd', ['unsafe"argument'], 'win32', process.env.ComSpec),
    /unsafe Windows command argument/i,
  );
});
