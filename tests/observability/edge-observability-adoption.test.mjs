import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const readJson = async (relativePath) => JSON.parse(await readFile(path.join(root, relativePath), 'utf8'));

test('observability manifest covers every recovered function exactly once', async () => {
  const production = await readJson('docs/architecture/production-contract.json');
  const manifest = await readJson('docs/architecture/edge-observability-manifest.json');
  assert.equal(manifest.schema_version, 1);

  const slugs = manifest.entries.map((entry) => entry.slug);
  assert.equal(new Set(slugs).size, slugs.length, 'observability slugs must be unique');
  assert.deepEqual([...slugs].sort(), [...production.recovered_slugs].sort());
  for (const entry of manifest.entries) {
    assert.match(entry.slug, /^[a-z0-9-]+$/);
    assert.ok(['finance', 'ops', 'guest', 'internal'].includes(entry.route), `${entry.slug}: invalid route`);
  }
});

test('every recovered function uses the shared request wrapper with its declared route', async () => {
  const manifest = await readJson('docs/architecture/edge-observability-manifest.json');
  for (const entry of manifest.entries) {
    const source = await readFile(path.join(root, 'supabase', 'functions', entry.slug, 'index.ts'), 'utf8');
    assert.match(
      source,
      /import\s+\{\s*withObservability\s*\}\s+from\s+['"]\.\.\/_shared\/observability\.ts['"]/,
      `${entry.slug}: shared observability import missing`,
    );
    assert.ok(
      source.includes(`withObservability({ functionName: '${entry.slug}', route: '${entry.route}' }, async`),
      `${entry.slug}: wrapper configuration missing`,
    );
  }
});
