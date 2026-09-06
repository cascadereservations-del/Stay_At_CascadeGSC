import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  assertP3OutputPath,
  buildP3Environment,
  writeP3Environment,
} from '../../scripts/deployment/p3-environment.mjs';

const repoRoot = path.resolve(import.meta.dirname, '..', '..');

test('builds distinct cryptographic secrets without placeholders or provider values', () => {
  const first = buildP3Environment();
  const second = buildP3Environment();
  const parse = text => Object.fromEntries(text.trim().split('\n').map(line => line.split('=')));
  const one = parse(first);
  const two = parse(second);

  assert.deepEqual(Object.keys(one), [
    'CASCADE_N8N_DB_NAME', 'CASCADE_N8N_DB_USER', 'CASCADE_N8N_DB_PASSWORD',
    'CASCADE_N8N_ENCRYPTION_KEY', 'CASCADE_N8N_USER_MANAGEMENT_JWT_SECRET',
    'CASCADE_N8N_HOST', 'CASCADE_N8N_PROTOCOL', 'CASCADE_N8N_EDITOR_BASE_URL',
    'CASCADE_N8N_WEBHOOK_URL', 'CASCADE_N8N_PROXY_HOPS', 'CASCADE_N8N_BIND_PORT',
  ]);
  assert.match(one.CASCADE_N8N_DB_PASSWORD, /^[A-Za-z0-9_-]{64}$/);
  assert.match(one.CASCADE_N8N_ENCRYPTION_KEY, /^[A-Za-z0-9_-]{86}$/);
  assert.match(one.CASCADE_N8N_USER_MANAGEMENT_JWT_SECRET, /^[A-Za-z0-9_-]{86}$/);
  assert.equal(new Set([
    one.CASCADE_N8N_DB_PASSWORD,
    one.CASCADE_N8N_ENCRYPTION_KEY,
    one.CASCADE_N8N_USER_MANAGEMENT_JWT_SECRET,
  ]).size, 3);
  assert.notEqual(one.CASCADE_N8N_DB_PASSWORD, two.CASCADE_N8N_DB_PASSWORD);
  assert.equal(one.CASCADE_N8N_HOST, 'localhost');
  assert.equal(one.CASCADE_N8N_PROTOCOL, 'http');
  assert.equal(one.CASCADE_N8N_PROXY_HOPS, '0');
  assert.doesNotMatch(first, /replace-with|token|provider|credential/i);
});

test('rejects relative and repository output paths', () => {
  assert.throws(() => assertP3OutputPath('p3.env', repoRoot), /absolute/i);
  assert.throws(() => assertP3OutputPath(path.join(repoRoot, 'p3.env'), repoRoot), /outside the repository/i);
});

test('writes once outside the repository and refuses overwrite', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'cascade-p3-env-'));
  const output = path.join(root, 'cascade-n8n-portainer.env');
  try {
    await writeP3Environment(output, repoRoot);
    const content = await readFile(output, 'utf8');
    assert.match(content, /^CASCADE_N8N_DB_NAME=cascade_n8n$/m);
    await assert.rejects(writeP3Environment(output, repoRoot), /already exists/i);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
