import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const moduleUrl = new URL('../../scripts/migrations/release-safety.mjs', import.meta.url);
const safety = await import(moduleUrl).catch(() => null);
const api = () => {
  assert.ok(safety, 'release-safety module must exist');
  return safety;
};

const FIXTURE_SQL = 'create table if not exists public.fixture(id uuid primary key);';
const FIXTURE_SHA = createHash('sha256').update(FIXTURE_SQL).digest('hex');

const goodContract = {
  schema_version: 1,
  release_id: 'fixture_release',
  phase: 'expand',
  source: { branch: 'fixture', commit: '0123456789abcdef0123456789abcdef01234567' },
  migrations: ['20260830000000_add_fixture.sql'],
  migration_sha256: { '20260830000000_add_fixture.sql': FIXTURE_SHA },
  backup: { required: true, restore_point: 'fixture-backup-id', verified_at: '2026-08-30T00:00:00Z' },
  forward_verification: [{ name: 'fixture_exists', query: "select to_regclass('public.fixture') is not null", expect: true }],
  rollback: { strategy: 'compensating', safe_until: 'contract', steps: [{ name: 'disable_fixture_writer', action: 'set fixture_writer_enabled=false' }] },
  feature_flags: [{ name: 'fixture_writer_enabled', required_state: 'off' }],
  compatibility: { old_reader: true, old_writer: true, verified: false },
  approvals: { production_required: true },
  stop_conditions: ['migration ledger differs from source'],
};

function fixtureRoot(sql = FIXTURE_SQL) {
  const root = mkdtempSync(join(tmpdir(), 'cascade-release-'));
  mkdirSync(join(root, 'supabase', 'migrations'), { recursive: true });
  writeFileSync(join(root, 'supabase', 'migrations', goodContract.migrations[0]), sql);
  return root;
}

function writeRelease(root, contract = goodContract) {
  mkdirSync(join(root, 'supabase', 'releases'), { recursive: true });
  const path = join(root, 'supabase', 'releases', 'fixture.release.json');
  writeFileSync(path, JSON.stringify(contract));
  return path;
}

function runScript(name, args) {
  return spawnSync(process.execPath, [fileURLToPath(new URL(`../../scripts/migrations/${name}`, import.meta.url)), ...args], {
    encoding: 'utf8',
  });
}

test('release safety module exists', () => {
  assert.ok(safety, 'release-safety module must exist');
});

test('valid release contract and additive migration pass', () => {
  assert.deepEqual(api().validateReleaseContract(goodContract), []);
  assert.deepEqual(api().validateMigrationFiles(goodContract, fixtureRoot()), []);
});

test('missing release evidence fails closed', () => {
  const broken = structuredClone(goodContract);
  delete broken.backup.restore_point;
  broken.forward_verification = [];
  broken.rollback.strategy = 'down';
  broken.feature_flags = [];
  delete broken.migration_sha256;
  const errors = api().validateReleaseContract(broken);
  assert.ok(errors.some(error => error.includes('backup.restore_point')));
  assert.ok(errors.some(error => error.includes('forward_verification')));
  assert.ok(errors.some(error => error.includes('rollback.strategy')));
  assert.ok(errors.some(error => error.includes('feature_flags')));
  assert.ok(errors.some(error => error.includes('migration_sha256')));
});

test('migration hash mismatch fails closed', () => {
  const root = fixtureRoot(`${FIXTURE_SQL}\n-- changed after review`);
  const errors = api().validateMigrationFiles(goodContract, root);
  assert.ok(errors.some(error => error.includes('SHA-256 mismatch')));
});

test('expand scanner rejects destructive dynamic SQL', () => {
  const findings = api().findUnsafeExpandSql("do $$ begin execute 'drop table public.fixture'; end $$;");
  assert.ok(findings.some(finding => finding.includes('dynamic')));
});

test('expand migration rejects destructive SQL', () => {
  const root = fixtureRoot('alter table public.fixture drop column legacy_value;');
  const errors = api().validateMigrationFiles(goodContract, root);
  assert.ok(errors.some(error => error.includes('destructive SQL')));
});

test('contract phase requires compatibility proof', () => {
  const contract = structuredClone(goodContract);
  contract.phase = 'contract';
  contract.compatibility.verified = false;
  const errors = api().validateReleaseContract(contract);
  assert.ok(errors.some(error => error.includes('compatibility.verified')));
});

test('forward verification SQL must be one read-only query', () => {
  const broken = structuredClone(goodContract);
  broken.forward_verification[0].query = 'delete from public.fixture; select true';
  const errors = api().validateReleaseContract(broken);
  assert.ok(errors.some(error => error.includes('read-only')));
});

test('migration ledger parser supports JSON and table output', () => {
  assert.deepEqual(
    api().parseAppliedMigrationVersions('{"migrations":[{"local":"20260830000000","remote":"20260830000000"}]}'),
    new Set(['20260830000000']),
  );
  assert.deepEqual(
    api().parseAppliedMigrationVersions('20260830000000 | 20260830000000 | 2026-08-30'),
    new Set(['20260830000000']),
  );
});

test('CLI fixtures can be loaded as file URLs', () => {
  assert.equal(pathToFileURL(fixtureRoot()).protocol, 'file:');
});

test('static verifier accepts additive release and rejects destructive expand', () => {
  const goodRoot = fixtureRoot();
  const goodRelease = writeRelease(goodRoot);
  const accepted = runScript('verify-expand-contract.mjs', ['--root', goodRoot, '--release', goodRelease]);
  assert.equal(accepted.status, 0, accepted.stderr || accepted.stdout);

  const badRoot = fixtureRoot('drop table public.fixture;');
  const badRelease = writeRelease(badRoot);
  const rejected = runScript('verify-expand-contract.mjs', ['--root', badRoot, '--release', badRelease]);
  assert.equal(rejected.status, 1);
  assert.match(rejected.stderr, /destructive SQL/);
});

test('local preflight rejects a required migration missing from ledger', () => {
  const root = fixtureRoot();
  const release = writeRelease(root);
  const ledger = join(root, 'ledger.json');
  writeFileSync(ledger, '{"migrations":[]}');
  const result = runScript('preflight.mjs', ['--local', '--root', root, '--release', release, '--ledger-file', ledger]);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /missing from local migration ledger: 20260830000000/);
});

test('real staff-cleaner contract binds the coordinated migration order', async () => {
  const path = new URL('../../supabase/releases/20260830_staff_cleaner_cutover.release.json', import.meta.url);
  const contract = await import(path, { with: { type: 'json' } }).then(module => module.default).catch(() => null);
  assert.ok(contract, 'staff-cleaner release contract must exist');
  assert.deepEqual(contract.migrations, [
    '20260828000200_operational_rls_lockdown.sql',
    '20260828000400_staff_roles_and_sessions.sql',
    '20260828000500_db_backed_operational_authorization.sql',
    '20260830002347_named_cleaner_access_boundary.sql',
  ]);
  assert.equal(contract.phase, 'contract');
  assert.equal(contract.approvals.production_required, true);
  assert.deepEqual(api().validateReleaseContract(contract), []);
});

test('privacy enforcement contract binds the additive migration and production gates', async () => {
  const path = new URL('../../supabase/releases/20260831_privacy_enforcement.release.json', import.meta.url);
  const contract = await import(path, { with: { type: 'json' } }).then(module => module.default).catch(() => null);
  assert.ok(contract, 'privacy enforcement release contract must exist');
  assert.deepEqual(contract.migrations, ['20260831010000_privacy_requests_and_holds.sql']);
  assert.equal(contract.phase, 'expand');
  assert.equal(contract.approvals.production_required, true);
  assert.equal(contract.approvals.current_privacy_review_required, true);
  assert.deepEqual(api().validateReleaseContract(contract), []);
  assert.deepEqual(api().validateMigrationFiles(contract, fileURLToPath(new URL('../../', import.meta.url))), []);
});

test('preflight source commit must exist in current branch ancestry', async () => {
  assert.equal(typeof api().validateSourceState, 'function', 'validateSourceState must exist');
  const contract = structuredClone(goodContract);
  contract.source.commit = '0000000000000000000000000000000000000000';
  const errors = api().validateSourceState(contract, new URL('../../', import.meta.url));
  assert.ok(errors.some(error => error.includes('not an ancestor')));
});

test('operator runbook preserves approval and non-destructive rollback boundaries', () => {
  let runbook = '';
  try { runbook = readFileSync(new URL('../../docs/runbooks/database-release.md', import.meta.url), 'utf8'); } catch { /* expected before implementation */ }
  assert.ok(runbook, 'database release runbook must exist');
  assert.match(runbook, /expand.*backfill.*verify.*contract/is);
  assert.match(runbook, /do not run a destructive down migration/i);
  assert.match(runbook, /owner approval/i);
  assert.match(runbook, /preflight\.mjs --local/);
  assert.match(runbook, /SHA-256/);
});

test('package scripts expose focused release verification', () => {
  const pkg = JSON.parse(readFileSync(new URL('../../package.json', import.meta.url), 'utf8'));
  assert.equal(pkg.scripts['test:release-safety'], 'node --test tests/migrations/release-safety.test.mjs');
  assert.equal(pkg.scripts['preflight:local'], 'node scripts/migrations/preflight.mjs --local');
});
