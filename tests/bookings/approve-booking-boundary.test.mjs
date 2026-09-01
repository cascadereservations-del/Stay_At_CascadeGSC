import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const source = fileURLToPath(new URL('../../supabase/functions/approve-booking/index.ts', import.meta.url));

test('approve-booking delegates the state decision to the canonical RPC', () => {
  const code = readFileSync(source, 'utf8');
  assert.match(code, /\.rpc\('decide_direct_booking'/);
  assert.doesNotMatch(code, /\.from\('calendar_events'\)\.update\(/);
  assert.doesNotMatch(code, /\.from\('transactions'\)\.update\(/);
});
