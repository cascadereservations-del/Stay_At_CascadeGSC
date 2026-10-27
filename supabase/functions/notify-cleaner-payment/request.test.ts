// deno test --no-check --allow-env notify-cleaner-payment/request.test.ts
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { createRequest, type PayRequestBody, parseRequest } from './request.ts';

Deno.test('a well-formed body passes with empty lists defaulted', () => {
  const r = parseRequest({ idempotency_key: 'zz-key-00000001', sessions: [{ id: 'x', transport: true }] });
  assertEquals(r.ok, true);
  if (r.ok) { assertEquals(r.value.key, 'zz-key-00000001'); assertEquals(r.value.sessions.length, 1); assertEquals(r.value.claim_ids, []); assertEquals(r.value.extras, []); assertEquals(r.value.advance, []); }
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

const K = 'zz-key-00000001';
Deno.test('advance: a well-formed list passes (absent transport becomes null, extra keys dropped); absent or null is []', () => {
  const r = parseRequest({ idempotency_key: K, advance: [{ checkout_date: '2026-10-19', transport: true }, { checkout_date: '2026-10-22', transport: false }, { checkout_date: '2026-10-25', x: 1 }] });
  assertEquals(r.ok && r.value.advance, [{ checkout_date: '2026-10-19', transport: true }, { checkout_date: '2026-10-22', transport: false }, { checkout_date: '2026-10-25', transport: null }]);
  assertEquals(parseRequest({ idempotency_key: K, advance: null }).ok && (parseRequest({ idempotency_key: K, advance: null }) as { value: PayRequestBody }).value.advance, []);
});
Deno.test('advance: bad shape, bad or impossible date, duplicate date, non-boolean transport, non-array and more than 20 are bad_request', () => {
  const bad = [
    'nope', {}, [null], [[]], [{}], [{ checkout_date: 20261019 }], [{ checkout_date: '2026-10-9' }], [{ checkout_date: '2026-02-30' }], [{ checkout_date: '2026-10-19T00:00:00Z' }],
    [{ checkout_date: '2026-10-19', transport: 'yes' }], [{ checkout_date: '2026-10-19', transport: 1 }],
    [{ checkout_date: '2026-10-19', transport: true }, { checkout_date: '2026-10-19', transport: false }],
  ];
  for (const advance of bad) assertEquals(parseRequest({ idempotency_key: K, advance }), { ok: false, reason: 'bad_request' });
  const day = (i: number) => ({ checkout_date: `2026-10-${String(i + 1).padStart(2, '0')}`, transport: false });
  assertEquals(parseRequest({ idempotency_key: K, advance: Array.from({ length: 21 }, (_, i) => ({ checkout_date: i < 9 ? `2026-09-0${i + 1}` : `2026-09-${i + 1}`, transport: false })) }), { ok: false, reason: 'bad_request' });
  assertEquals(parseRequest({ idempotency_key: K, advance: Array.from({ length: 20 }, (_, i) => (i < 9 ? { checkout_date: `2026-09-0${i + 1}`, transport: false } : day(i - 9))) }).ok, true);
});

const base = { key: 'zz-key-00000001', sessions: [], claim_ids: [], extras: [] };
function fake(code: string | null) {
  const calls: string[] = [];
  return { calls, rpc: (n: string) => { calls.push(n); return Promise.resolve(n.endsWith('_v2') && code ? { data: null, error: { code } } : { data: { ok: true }, error: null }); } };
}
Deno.test('W6: create_v2 missing + empty advance falls back to v1 (PGRST202 and 42883)', async () => {
  for (const code of ['PGRST202', '42883']) {
    const f = fake(code);
    const r = await createRequest(f.rpc, { ...base, advance: [] });
    assertEquals([f.calls, r.error], [['staff_pay_request_create_v2', 'staff_pay_request_create_v1'], null]);
  }
});
Deno.test('W6: create_v2 missing + a non-empty advance keeps the error; other errors never fall back', async () => {
  const f = fake('PGRST202');
  const r = await createRequest(f.rpc, { ...base, advance: [{ checkout_date: '2026-10-19', transport: false }] });
  assertEquals([f.calls, r.error?.code], [['staff_pay_request_create_v2'], 'PGRST202']);
  const g = fake('22P02');
  await createRequest(g.rpc, { ...base, advance: [] });
  assertEquals(g.calls, ['staff_pay_request_create_v2']);
});
