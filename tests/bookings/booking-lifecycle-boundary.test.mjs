import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const migrationPath = fileURLToPath(new URL('../../supabase/migrations/20260905030000_booking_lifecycle.sql', import.meta.url));
const sql = readFileSync(migrationPath, 'utf8');

test('Module E serializes date allocation and makes retries idempotent', () => {
  assert.match(sql, /cascade-booking-property:/i);
  assert.match(sql, /pg_advisory_xact_lock/i);
  assert.match(sql, /booking_holds[\s\S]*idempotency_key text not null unique/i);
  assert.match(sql, /for update skip locked/i);
});

test('Module E cannot create an alternate confirmation path', () => {
  assert.doesNotMatch(sql, /create\s+or\s+replace\s+function\s+public\.decide_direct_booking/i);
  assert.doesNotMatch(sql, /set\s+status\s*=\s*'confirmed'/i);
  assert.doesNotMatch(sql, /booking_inquiries\s+set\s+status\s*=\s*'confirmed'/i);
});

test('refund handling is a named authorization and never executes payment', () => {
  assert.match(sql, /reviewer_user_id uuid not null references auth\.users/i);
  assert.match(sql, /current_staff_authorized\('approve_refund'/i);
  assert.match(sql, /p_aal is distinct from 'aal2'/i);
  assert.doesNotMatch(sql, /update\s+public\.transactions[\s\S]*refund/i);
  assert.doesNotMatch(sql, /provider.*refund|stripe|paypal|paymongo/i);
});

test('OPS roles are excluded from booking and refund authority', () => {
  const cleanerClause = sql.match(/when p_role = 'cleaner'[\s\S]*?when p_role = 'maintenance'/i)?.[0] ?? '';
  assert.doesNotMatch(cleanerClause, /manage_booking|approve_refund|read_finance/i);
  assert.match(sql, /revoke all on public\.booking_rate_policy_versions[\s\S]*booking_refund_authorizations[\s\S]*from public, anon, authenticated, service_role/i);
});

test('lifecycle audit and rate versions are immutable to callers', () => {
  assert.match(sql, /booking_lifecycle_events[\s\S]*idempotency_key text not null unique/i);
  assert.match(sql, /revoke all on public\.booking_rate_policy_versions[\s\S]*authenticated, service_role/i);
  assert.doesNotMatch(sql, /grant\s+(insert|update|delete).*booking_lifecycle_events/i);
});
