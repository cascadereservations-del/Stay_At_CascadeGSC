import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  buildRecoveryMigrationPlan,
  prepareRecoveryMigrationContent,
  validateRecoveryBaselineManifest,
} from '../../scripts/recovery/recovery-contract.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const sha = text => createHash('sha256').update(text).digest('hex');

const FILE = '20260926020000_seed.sql';
const FIRST = 'insert into public.t (a, b)';
const STATEMENT = `${FIRST}\nselect 1, (select user_id from x)\nwhere not exists (select 1 from public.t);\n`;
const SOURCE = `create table public.t (a int, b int);\n${STATEMENT}create index i on public.t (a);\n`;
const entry = (overrides = {}) => ({ first_line: FIRST, sha256: sha(STATEMENT), ...overrides });

test('an omitted seed statement is replaced by a marker that carries the first 12 hash characters', () => {
  const prepared = prepareRecoveryMigrationContent(FILE, SOURCE, [], { [FILE]: [entry()] });
  assert.equal(prepared, `create table public.t (a int, b int);\n-- recovery: omitted production-data seed (sha256 ${sha(STATEMENT).slice(0, 12)})\ncreate index i on public.t (a);\n`);
});

test('a file without omissions, or an empty map, is returned unchanged', () => {
  assert.equal(prepareRecoveryMigrationContent(FILE, SOURCE), SOURCE);
  assert.equal(prepareRecoveryMigrationContent(FILE, SOURCE, [], { 'other.sql': [entry()] }), SOURCE);
});

test('a CRLF source hashes and omits the same as an LF one', () => {
  const prepared = prepareRecoveryMigrationContent(FILE, SOURCE.replace(/\n/g, '\r\n'), [], { [FILE]: [entry()] });
  assert.match(prepared, /-- recovery: omitted production-data seed/);
  assert.doesNotMatch(prepared, /select user_id/);
});

test('a first_line that matches no line is refused', () => {
  assert.throws(() => prepareRecoveryMigrationContent(FILE, SOURCE, [], { [FILE]: [entry({ first_line: 'insert into public.nope' })] }), /exactly one line.*found 0/);
});

test('a first_line that matches two lines is refused', () => {
  assert.throws(() => prepareRecoveryMigrationContent(FILE, `${SOURCE}${STATEMENT}`, [], { [FILE]: [entry()] }), /exactly one line.*found 2/);
});

test('a statement that changed after it was pinned is refused', () => {
  const changed = SOURCE.replace('select 1, (select user_id from x)', 'select 2, (select user_id from x)');
  assert.throws(() => prepareRecoveryMigrationContent(FILE, changed, [], { [FILE]: [entry()] }), /hash mismatch/);
});

test('a statement with no terminating semicolon line is refused', () => {
  const source = `${FIRST}\nselect 1\n`;
  assert.throws(() => prepareRecoveryMigrationContent(FILE, source, [], { [FILE]: [entry()] }), /no terminating/);
});

const baseManifest = () => ({
  schema_version: 1,
  prerequisite_migration_version: '20260823999999',
  prerequisite_source: 'recovery/prerequisites.sql',
  baseline_migration_version: '20260824000000',
  baseline_source: 'schemas/000_remote_public_schema.sql',
  compatibility_migration_version: '20260824002000',
  compatibility_source: 'recovery/pre_forward_compat.sql',
  includes_through: '20260817044851',
  forward_migrations_from: '20260824002834',
  prerequisite_sha256: sha('p'),
  baseline_sha256: sha('b'),
  compatibility_sha256: sha('c'),
});
const validate = manifest => validateRecoveryBaselineManifest(manifest, { baselineSql: 'b', prerequisiteSql: 'p', compatibilitySql: 'c', bridgeSql: {} });

test('manifest validation accepts a forward migration and refuses a bridge, an excluded file, a pre-boundary file, or a bad pin', () => {
  const ok = { ...baseManifest(), recovery_statement_omissions: { [FILE]: [entry()] } };
  assert.doesNotThrow(() => validate(ok));
  const bridgeName = '20260925025900_bridge.sql';
  const bridges = { recovery_bridge_migrations: [bridgeName], recovery_bridge_sha256: { [bridgeName]: sha('x') } };
  assert.throws(() => validateRecoveryBaselineManifest({ ...ok, ...bridges, recovery_statement_omissions: { [bridgeName]: [entry()] } },
    { baselineSql: 'b', prerequisiteSql: 'p', compatibilitySql: 'c', bridgeSql: { [bridgeName]: 'x' } }), /names a bridge/);
  assert.throws(() => validate({ ...ok, recovery_excluded_migrations: [FILE] }), /excluded migration/);
  assert.throws(() => validate({ ...ok, recovery_statement_omissions: { '20260801000000_old.sql': [entry()] } }), /forward migration/);
  assert.throws(() => validate({ ...ok, recovery_statement_omissions: { [FILE]: [entry({ sha256: 'abc' })] } }), /sha256 hex pin/);
});

test('the plan refuses an omission on a file that is not a forward migration in the plan', () => {
  const manifest = { ...baseManifest(), recovery_statement_omissions: { [FILE]: [entry()] } };
  assert.throws(() => buildRecoveryMigrationPlan(manifest, ['20260824002834_a.sql']), /not a forward migration in the plan/);
  assert.doesNotThrow(() => buildRecoveryMigrationPlan(manifest, ['20260824002834_a.sql', FILE]));
});

test('the real baseline prepares the rate card without its production-data seeds', () => {
  const supabase = path.join(repoRoot, 'supabase');
  const manifest = JSON.parse(readFileSync(path.join(supabase, 'recovery', 'baseline.json'), 'utf8'));
  const files = readdirSync(path.join(supabase, 'migrations')).filter(name => name.endsWith('.sql'));
  assert.ok(buildRecoveryMigrationPlan(manifest, files).includes('20260926020000_rate_card.sql'));
  const source = readFileSync(path.join(supabase, 'migrations', '20260926020000_rate_card.sql'), 'utf8');
  const prepared = prepareRecoveryMigrationContent('20260926020000_rate_card.sql', source, manifest.recovery_assertion_only_migrations, manifest.recovery_statement_omissions);
  assert.ok(source.includes('seed:rate-card-v1-20260926'));
  assert.ok(!prepared.includes('seed:rate-card-v1-20260926'));
  assert.ok(!prepared.includes("'Anniversary Promotion', date"));
  assert.ok(prepared.includes('create or replace function public.get_rate_card_v1'));
  assert.equal((prepared.match(/-- recovery: omitted production-data seed/g) ?? []).length, 2);
});
