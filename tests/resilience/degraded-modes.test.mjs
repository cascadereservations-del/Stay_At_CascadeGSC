import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const contractPath = path.join(root, 'docs', 'architecture', 'degraded-mode-contract.json');
const runbookPath = path.join(root, 'docs', 'runbooks', 'degraded-operations.md');
const expectedProviders = ['airbnb', 'chatwoot', 'gmail', 'n8n', 'openrouter'];

async function loadContract() {
  const raw = await readFile(contractPath, 'utf8').catch(() => null);
  assert.ok(raw, 'machine-readable degraded-mode contract must exist');
  return JSON.parse(raw);
}

test('degraded-mode contract has an exact closed provider set and safe schema', async () => {
  const contract = await loadContract();
  assert.equal(contract.schema_version, 1);
  assert.deepEqual(Object.keys(contract.providers).sort(), expectedProviders);

  for (const [provider, decision] of Object.entries(contract.providers)) {
    assert.match(decision.reason_code, /^[A-Z][A-Z0-9_]{4,63}$/, `${provider}: reason code`);
    assert.equal(decision.acknowledge, true, `${provider}: acknowledge`);
    assert.equal(decision.preserve_canonical_state, true, `${provider}: preserve state`);
    assert.equal(decision.automatic_financial_decision, false, `${provider}: financial decision`);
    assert.match(decision.retry_policy, /^[a-z][a-z0-9_]{2,63}$/, `${provider}: retry policy`);
    assert.match(decision.action, /^[a-z][a-z0-9_]{5,127}$/, `${provider}: action`);
    assert.equal(typeof decision.human_review, 'boolean', `${provider}: human review`);
  }
});

test('provider failures retain their required non-destructive decision', async () => {
  const { providers } = await loadContract();
  assert.equal(providers.openrouter.action, 'create_human_review_without_fabricating_output');
  assert.equal(providers.n8n.action, 'retain_canonical_outbox_event_and_retry_idempotently');
  assert.equal(providers.gmail.action, 'allow_manual_evidence_review_without_nonpayment_inference');
  assert.equal(providers.chatwoot.action, 'stop_automated_replies_and_prevent_webhook_echo');
  assert.equal(providers.airbnb.action, 'preserve_calendar_blocks_and_require_manual_review');
});

test('runbook names every executable reason code', async () => {
  const contract = await loadContract();
  const runbook = await readFile(runbookPath, 'utf8');
  for (const decision of Object.values(contract.providers)) {
    assert.ok(runbook.includes(decision.reason_code), `${decision.reason_code}: runbook coverage missing`);
  }
});
