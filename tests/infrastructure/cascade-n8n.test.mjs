import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const infra = path.join(root, 'infrastructure', 'cascade-n8n');
const read = (name) => readFile(path.join(infra, name), 'utf8');

test('retains explicit historical image pins (not security or deployment approval)', async () => {
  const compose = await read('compose.yaml');
  assert.match(compose, /image:\s*n8nio\/n8n:2\.34\.6\b/);
  assert.match(compose, /image:\s*postgres:17\.11-alpine3\.24\b/);
  assert.doesNotMatch(compose, /:(?:latest|stable|beta)\b/);
});

test('uses Cascade-only containers, network, volumes, database, and user', async () => {
  const compose = await read('compose.yaml');
  assert.match(compose, /container_name:\s*cascade-n8n-app/);
  assert.match(compose, /container_name:\s*cascade-n8n-postgres/);
  assert.match(compose, /name:\s*cascade_n8n_internal/);
  assert.match(compose, /name:\s*cascade_n8n_data/);
  assert.match(compose, /name:\s*cascade_n8n_postgres_data/);
  assert.match(compose, /CASCADE_N8N_DB_NAME/);
  assert.match(compose, /CASCADE_N8N_DB_USER/);
  assert.doesNotMatch(compose, /alfred|alex/i);
});

test('requires independent credentials and encryption secrets', async () => {
  const compose = await read('compose.yaml');
  const env = await read('.env.example');
  for (const key of [
    'CASCADE_N8N_DB_PASSWORD',
    'CASCADE_N8N_ENCRYPTION_KEY',
    'CASCADE_N8N_USER_MANAGEMENT_JWT_SECRET',
  ]) {
    assert.match(compose, new RegExp(`\\$\\{${key}:\\?`));
    assert.match(env, new RegExp(`^${key}=`, 'm'));
  }
  assert.doesNotMatch(env, /(?:sk-|eyJ[a-zA-Z0-9_-]|-----BEGIN|ghp_)/);
});

test('binds only to localhost and applies health and resource boundaries', async () => {
  const compose = await read('compose.yaml');
  assert.match(compose, /127\.0\.0\.1:\$\{CASCADE_N8N_BIND_PORT/);
  assert.match(compose, /healthcheck:/);
  assert.match(compose, /mem_limit:/);
  assert.match(compose, /cpus:/);
  assert.match(compose, /no-new-privileges:true/);
  assert.match(compose, /internal:\s*true/);
  assert.doesNotMatch(compose, /(?:^|\s)-?\s*"?0\.0\.0\.0:/m);
});

test('uses a distinct HTTPS host and security headers', async () => {
  const caddy = await read('Caddyfile.fragment');
  assert.match(caddy, /^cascade-n8n\.rocloyd\.com\s*\{/m);
  assert.doesNotMatch(caddy, /^n8n\.rocloyd\.com\s*\{/m);
  assert.match(caddy, /reverse_proxy\s+127\.0\.0\.1:\{\$CASCADE_N8N_BIND_PORT\}/);
  assert.match(caddy, /Strict-Transport-Security/);
  assert.match(caddy, /X-Content-Type-Options/);
});

test('requires encrypted external backups and disposable restore checks', async () => {
  const backup = await read('backup.ps1');
  const restore = await read('restore-check.ps1');
  assert.match(backup, /CASCADE_BACKUP_DIR/);
  assert.match(backup, /AGE_RECIPIENT/);
  assert.match(backup, /age(?:\.exe)?/i);
  assert.match(backup, /finally/i);
  assert.match(restore, /cascade-restore-check-/);
  assert.match(restore, /AGE_IDENTITY_FILE/);
  assert.doesNotMatch(`${backup}\n${restore}`, /Remove-Item\s+[^\r\n]*(?:\$HOME|~|["']?\/["']?)/i);
});

test('runbook gates deployment, activation, capacity, and rollback', async () => {
  const runbook = await readFile(path.join(root, 'docs', 'runbooks', 'cascade-n8n-deploy.md'), 'utf8');
  for (const phrase of [
    'read-only capacity preflight',
    'owner approval',
    'import inactive',
    'rollback',
    '/opt/cascade/n8n',
  ]) assert.match(runbook, new RegExp(phrase, 'i'));
  assert.match(runbook, /memory|ram/i);
  assert.match(runbook, /disk/i);
  assert.match(runbook, /swap/i);
  assert.match(runbook, /port/i);
});
