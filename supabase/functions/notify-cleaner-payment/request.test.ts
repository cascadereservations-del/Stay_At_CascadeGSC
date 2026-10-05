// deno test --no-check --allow-env notify-cleaner-payment/request.test.ts
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { parseRequest } from './request.ts';

Deno.test('a well-formed body passes with empty lists defaulted', () => {
  const r = parseRequest({ idempotency_key: 'zz-key-00000001', sessions: [{ id: 'x', transport: true }] });
  assertEquals(r.ok, true);
  if (r.ok) { assertEquals(r.value.key, 'zz-key-00000001'); assertEquals(r.value.sessions.length, 1); assertEquals(r.value.claim_ids, []); assertEquals(r.value.extras, []); }
});

Deno.test('a missing, short or long key, a non-object body and a non-array list are bad_request', () => {
  for (const b of [null, 'text', [], {}, { idempotency_key: 'short' }, { idempotency_key: 'k'.repeat(81) }, { idempotency_key: 'zz-key-00000001', sessions: 'nope' }, { idempotency_key: 'zz-key-00000001', extras: {} }]) {
    assertEquals(parseRequest(b), { ok: false, reason: 'bad_request' });
  }
});

Deno.test('an oversized list is refused here, never silently cut', () => {
  assertEquals(parseRequest({ idempotency_key: 'zz-key-00000001', extras: new Array(41).fill({}) }).ok, false);
  assertEquals(parseRequest({ idempotency_key: 'zz-key-00000001', extras: new Array(40).fill({}) }).ok, true);
});
