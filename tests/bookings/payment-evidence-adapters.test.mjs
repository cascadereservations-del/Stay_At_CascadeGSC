import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  minimizeAllowlistedBankEmail,
  normalizeOpenRouterReceiptAdvice,
  OPENROUTER_PAYMENT_TASK_PROFILE,
} from '../../supabase/functions/_shared/payment-evidence.ts';

const fixtures = JSON.parse(readFileSync(new URL('../fixtures/payment-evidence/module-c-cases.json', import.meta.url), 'utf8'));
const allowlist = {
  senders: ['alerts@trusted-bank.example'],
  subject_prefixes: ['Payment received'],
  parser_version: 'bank-mail-v1',
};

test('fixture pack covers the required advisory outcomes without production data', () => {
  assert.deepEqual(fixtures.map(item => item.name), [
    'valid-looking receipt and allowlisted bank evidence',
    'wrong amount',
    'duplicate receipt',
    'ambiguous single source',
    'spoofed-looking bank message',
    'missing bank message remains manually reviewable',
  ]);
});

test('bank adapter accepts only exact allowlisted authenticated envelopes and minimizes identifiers', async () => {
  const candidate = await minimizeAllowlistedBankEmail({
    sender: 'alerts@trusted-bank.example',
    subject: 'Payment received CAS-1001',
    message_id: 'synthetic-message-1001',
    received_at: '2026-09-05T01:00:00.000Z',
    authentication: { spf: 'pass', dkim: 'pass', dmarc: 'pass' },
    amount: 1500,
    currency: 'php',
    reference: 'cas-1001',
  }, allowlist);
  assert.equal(candidate.source_admissibility, 'allowlisted');
  assert.equal(candidate.reference, 'CAS1001');
  assert.match(candidate.source_artifact_id, /^bankmsg_[0-9a-f]{64}$/);
  assert.doesNotMatch(JSON.stringify(candidate), /trusted-bank|Payment received|synthetic-message/i);
});

test('spoofed and missing bank messages fail closed to manual review', async () => {
  const spoofed = await minimizeAllowlistedBankEmail({
    sender: 'alerts@trusted-bank.example.attacker.invalid',
    reply_to: 'collector@attacker.invalid',
    subject: 'Payment received CAS-1005',
    message_id: 'synthetic-message-1005',
    received_at: '2026-09-05T01:00:00.000Z',
    authentication: { spf: 'fail', dkim: 'fail', dmarc: 'fail' },
  }, allowlist);
  const missing = await minimizeAllowlistedBankEmail(null, allowlist);
  assert.equal(spoofed.failure_code, 'sender_not_allowlisted');
  assert.equal(spoofed.source_admissibility, 'rejected');
  assert.equal(missing.failure_code, 'missing_message');
  assert.equal(missing.source_admissibility, 'missing');
  assert.deepEqual(missing.advisory_labels, ['manual_review_required']);
});

test('OpenRouter advice must match the pinned strict schema or route to review', async () => {
  const accepted = await normalizeOpenRouterReceiptAdvice({
    schema_version: 1,
    task_profile: 'cascade-payment-receipt-v1',
    status: 'extracted',
    observed_at: '2026-09-05T01:00:00.000Z',
    amount: 1500,
    currency: 'PHP',
    reference: 'CAS-1001',
    confidence: 0.91,
    labels: ['clear_amount'],
  }, 'receipt_aaaaaaaa', 'openrouter-v1');
  const rejected = await normalizeOpenRouterReceiptAdvice({
    schema_version: 1,
    task_profile: 'unapproved-profile',
    status: 'extracted',
    amount: 1500,
    confidence: 0.99,
    labels: [],
  }, 'receipt_bbbbbbbb', 'openrouter-v1');
  assert.equal(OPENROUTER_PAYMENT_TASK_PROFILE, 'cascade-payment-receipt-v1');
  assert.equal(accepted.failure_code, null);
  assert.equal(rejected.failure_code, 'schema_invalid');
  assert.deepEqual(rejected.advisory_labels, ['manual_review_required']);
});
