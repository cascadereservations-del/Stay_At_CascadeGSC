import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const migration = fileURLToPath(new URL('../../supabase/migrations/20260901010000_canonical_booking_decision.sql', import.meta.url));

test('canonical booking decision is implemented as one database RPC with an idempotency key', () => {
  assert.ok(existsSync(migration), 'canonical booking decision migration must exist');
  const sql = readFileSync(migration, 'utf8');
  assert.match(sql, /create\s+or\s+replace\s+function\s+public\.decide_direct_booking\s*\(\s*p_booking_id\s+uuid\s*,\s*p_action\s+text\s*,\s*p_idempotency_key\s+text/is);
  assert.match(sql, /pg_advisory_xact_lock/is);
  assert.match(sql, /cascade-booking-decision:/i);
});
