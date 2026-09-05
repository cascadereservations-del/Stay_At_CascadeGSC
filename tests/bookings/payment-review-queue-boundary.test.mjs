import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(new URL('../../supabase/migrations/20260905020000_payment_review_queue.sql', import.meta.url), 'utf8');
const endpoint = await readFile(new URL('../../supabase/functions/payment-review-queue/index.ts', import.meta.url), 'utf8');

test('review queue is a named AAL2 Finance-only read boundary', () => {
  assert.match(migration, /current_staff_authorized\('read_finance', p_property_id\)/);
  assert.match(migration, /revoke all[\s\S]*service_role/i);
  assert.match(migration, /grant execute[\s\S]*authenticated/i);
  assert.doesNotMatch(migration, /guest_(?:email|phone)/i);
  assert.match(endpoint, /requireStaffAccess\(request, 'read_finance'/);
});

test('review queue cannot make a booking or payment decision', () => {
  assert.doesNotMatch(migration, /decide_direct_booking\s*\(/i);
  assert.doesNotMatch(endpoint, /approve-booking|decide_direct_booking|record_payment_finance_review/i);
  assert.match(migration, /review_history/);
  assert.match(migration, /source_admissibility/);
  assert.match(migration, /duplicate_of_candidate_id/);
});
