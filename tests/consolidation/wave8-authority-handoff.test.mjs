import assert from 'node:assert/strict';
import { access, readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const inventoryPath = path.join(root, 'docs', 'architecture', 'cascade-authority-inventory.json');
const inventory = JSON.parse(await readFile(inventoryPath, 'utf8'));
const runbook = await readFile(path.join(root, 'docs', 'runbooks', 'cascade-operational-handoff.md'), 'utf8');
const adr = await readFile(path.join(root, 'docs', 'architecture', 'adr-002-dedicated-hetzner-cascade-operations.md'), 'utf8');
const compose = await readFile(path.join(root, 'infrastructure', 'cascade-n8n', 'compose.yaml'), 'utf8');

test('authority inventory covers every completed local business domain exactly once', () => {
  const expected = ['booking_decision','booking_lifecycle','cleaning_verification','crm_consent_lifecycle','finance_reconciliation','guest_inbox','inventory_forecast','selective_marketing'];
  const ids = inventory.domains.map(domain => domain.id).sort();
  assert.deepEqual(ids, expected);
  assert.equal(new Set(ids).size, ids.length);
  assert.equal(new Set(inventory.domains.map(domain => domain.canonical_state_owner)).size, inventory.domains.length);
  assert.equal(inventory.canonical_system_of_record, 'supabase');
  assert.equal(inventory.production_frozen, true);
});

test('every authority entry is property scoped, named-human governed, and evidence linked', async () => {
  for (const domain of inventory.domains) {
    assert.equal(domain.state, 'local_candidate', domain.id);
    assert.equal(domain.property_scoped, true, domain.id);
    assert.match(domain.named_human_authority, /aal2|inspector|booking_manager/);
    assert.ok(domain.prohibited_effects.length > 0, domain.id);
    await access(path.join(root, domain.source));
    await access(path.join(root, domain.validation));
  }
});

test('legacy and delivery paths cannot become competing business authority', () => {
  assert.deepEqual(inventory.legacy_or_delivery_paths.map(item => item.classification).sort(), [
    'delivery_only', 'legacy_columns_pending_coordinated_reconciliation', 'private_internal_engine'
  ]);
  assert.match(JSON.stringify(inventory.legacy_or_delivery_paths), /never_canonical_business_authority/);
  assert.match(JSON.stringify(inventory.legacy_or_delivery_paths), /not_used_by_wave_6_or_wave_7_eligibility/);
});

test('operating handoff preserves access, recovery, incident, and production stops', () => {
  assert.match(runbook, /## Access review/);
  assert.match(runbook, /## Recovery and incident drills/);
  assert.match(runbook, /Finance data cannot reach OPS/);
  assert.match(runbook, /Stop before any production, provider, order, publication, Docker, VPS, DNS, or workflow action/);
  assert.match(runbook, /active local database identity is unchanged/);
});

test('Hetzner direction uses an isolated two-service stack and remains deployment gated', () => {
  assert.match(adr, /Accepted direction; source-only and deployment-gated/);
  assert.match(adr, /Do not place the new stack on Alfred/);
  assert.match(adr, /separate Cascade VPS with its own Docker Engine/);
  assert.match(adr, /Supabase remains the canonical business-state authority/);
  assert.match(adr, /fresh owner approval before ordering a server or creating directories, swap, DNS, secrets, containers, volumes/);
  assert.match(compose, /^  postgres:/m);
  assert.match(compose, /^  n8n:/m);
  assert.match(compose, /127\.0\.0\.1:\$\{CASCADE_N8N_BIND_PORT:-5679\}:5678/);
  assert.match(compose, /cascade_n8n_postgres_data/);
});

test('all source-controlled workflows remain inactive', async () => {
  const workflowDir = path.join(root, 'automation', 'n8n', 'workflows');
  const files = (await readdir(workflowDir)).filter(name => name.endsWith('.json'));
  assert.equal(files.length, 13);
  for (const file of files) {
    const workflow = JSON.parse(await readFile(path.join(workflowDir, file), 'utf8'));
    assert.equal(workflow.active, false, file);
  }
});
