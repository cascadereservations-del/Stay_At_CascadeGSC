import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  evaluateProductionContract,
  validateSafeSnapshot,
} from '../scripts/audit/compare-supabase-production.mjs';

async function fixtureRoot(localFunctions = []) {
  const root = await mkdtemp(path.join(tmpdir(), 'cascade-production-contract-'));
  for (const slug of localFunctions) {
    const directory = path.join(root, 'supabase', 'functions', slug);
    await mkdir(directory, { recursive: true });
    await writeFile(path.join(directory, 'index.ts'), '// fixture\n');
  }
  return root;
}

function deployed(slug, overrides = {}) {
  return {
    slug,
    version: 1,
    status: 'ACTIVE',
    verify_jwt: false,
    updated_at: '2026-08-28T00:00:00.000Z',
    deployment_sha256: 'a'.repeat(64),
    critical: true,
    ...overrides,
  };
}

test('classifies deployed functions with local source as versioned', async () => {
  const root = await fixtureRoot(['availability']);
  const result = await evaluateProductionContract({
    root,
    snapshot: { project_ref: 'fixture', functions: [deployed('availability')] },
  });

  assert.equal(result.functions[0].source_status, 'versioned');
  assert.deepEqual(result.errors, []);
});

test('blocks a critical deployed function whose local source is missing', async () => {
  const root = await fixtureRoot();
  const result = await evaluateProductionContract({
    root,
    snapshot: { project_ref: 'fixture', functions: [deployed('turnover-verifier')] },
  });

  assert.equal(result.functions[0].source_status, 'missing-source');
  assert.match(result.errors.join('\n'), /turnover-verifier.*missing local source/i);
});

test('reports local-only functions without treating them as deployed-source failures', async () => {
  const root = await fixtureRoot(['local-helper']);
  const result = await evaluateProductionContract({
    root,
    snapshot: { project_ref: 'fixture', functions: [] },
  });

  assert.deepEqual(result.local_only, ['local-helper']);
  assert.deepEqual(result.errors, []);
});

test('counts table, policy, and RLS metadata in the tracked schema snapshot', async () => {
  const root = await fixtureRoot();
  const schemaDirectory = path.join(root, 'supabase', 'schemas');
  const schemaPath = path.join(schemaDirectory, 'remote.sql');
  const schema = [
    'CREATE TABLE "public"."bookings" ();',
    'CREATE POLICY "owner_read" ON "public"."bookings" USING (true);',
    'ALTER TABLE "public"."bookings" ENABLE ROW LEVEL SECURITY;',
  ].join('\n');
  await mkdir(schemaDirectory, { recursive: true });
  await writeFile(schemaPath, schema);

  const result = await evaluateProductionContract({
    root,
    snapshot: {
      project_ref: 'fixture',
      functions: [],
      database: {
        schema_snapshot: 'supabase/schemas/remote.sql',
        schema_snapshot_sha256: createHash('sha256').update(schema).digest('hex'),
      },
    },
  });

  assert.equal(result.database.table_count, 1);
  assert.equal(result.database.policy_count, 1);
  assert.equal(result.database.rls_table_count, 1);
  assert.deepEqual(result.errors, []);
});

test('rejects unsafe production snapshots', () => {
  for (const unsafeFunction of [
    { ...deployed('availability'), id: 'deployment-id' },
    { ...deployed('availability'), entrypoint_path: 'file:///tmp/source/index.ts' },
    { ...deployed('availability'), access_token: 'secret' },
  ]) {
    assert.throws(
      () => validateSafeSnapshot({ project_ref: 'fixture', functions: [unsafeFunction] }),
      /unsafe production snapshot field/i,
    );
  }
});
