// deno test --no-check -A messenger-concierge/spec44.test.ts
// SPEC-44 (s76): at await_receipt, "bayad na po" or a file that is not a photo brings Finance's request card back (fx.bump),
// once an hour per booking, with no new line to the guest - and under a D-317 host hold too. Synthetic data only.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';

(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { handle, probeEffects } = await import('./index.ts');
const { paidClaim } = await import('./booking.ts');

const now = new Date('2026-10-08T02:00:00Z');
const iso = (h: number, at = now) => new Date(at.getTime() + h * 3_600_000).toISOString();
type Call = { fx: string; text?: string; detail?: Record<string, unknown> };
// deno-lint-ignore no-explicit-any
function fakeDb(row: any) {
  // deno-lint-ignore no-explicit-any
  const writes: Array<{ table: string; v: any }> = [];
  // deno-lint-ignore no-explicit-any
  const q = (table: string): any => new Proxy({}, { get(_t, k) {
    if (k === 'then') return (res: (x: unknown) => void) => res({ data: [], error: null });
    if (k === 'maybeSingle' || k === 'single') return () => Promise.resolve({ data: table === 'concierge_threads' ? row : null, error: null });
    // deno-lint-ignore no-explicit-any
    if (k === 'upsert' || k === 'insert' || k === 'update') return (v: any) => { writes.push({ table, v }); return q(table); };
    return () => q(table);
  } });
  return { db: { from: (t: string) => q(t), rpc: () => Promise.resolve({ data: [], error: null }) }, writes };
}
const FLOW = { step: 'await_receipt', ref: 'DIR-T44', booking_id: '0a0a0a0a-1111-4222-8333-444455556666', name: 'Ana Cruz', checkin: '2026-10-20', checkout: '2026-10-22',
  pax: 2, total: 6200, deposit: 3100, hold: true, hold_expires_at: iso(20), lang: 'tl', receipt_token: 't', receipt_expires_at: iso(20), started_at: iso(-2), updated_at: iso(-1) };
// deno-lint-ignore no-explicit-any
async function turn(message: Record<string, unknown>, humanUntil: string | null, flow: any, at = now) {
  const row = { psid: 'probe:s44', guest_name: 'Ana', human_until: humanUntil, bot_turns: 3, last_risk: null, last_mid: null, booking_flow: flow,
    history: [{ role: 'guest', text: 'sige po', at: iso(-1.5, at) }, { role: 'bot', text: 'Here is the QR po.', at: iso(-1.5, at) }] };
  const { db, writes } = fakeDb(row);
  const calls: Call[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = (() => Promise.resolve(new Response('{}', { status: 500 }))) as typeof fetch; // no network: a model call fails closed
  try {
    // deno-lint-ignore no-explicit-any
    await handle(db as any, { sender: { id: 'probe:s44' }, recipient: { id: 'page' }, message: { mid: 'm-' + Math.random(), ...message } }, 'auto', probeEffects(calls as any, 'Ana', at), at);
  } finally { globalThis.fetch = real; }
  const saved = writes.filter((w) => w.table === 'concierge_threads' && w.v.booking_flow).at(-1)?.v.booking_flow ?? null;
  return { calls, saved, bumps: calls.filter((c) => c.fx === 'bump'), sends: calls.filter((c) => c.fx === 'send' || c.fx === 'qr') };
}
const FILE = { attachments: [{ type: 'file', payload: { url: 'https://example.invalid/receipt.pdf' } }] };

Deno.test('paidClaim: claims bump, questions do not', () => {
  for (const t of ['bayad na po', 'Sent na po', 'paid na', 'nabayaran ko na po', 'I transferred it', 'transfer done po',
    'nagbayad na po', 'nakabayad na po', 'nasend ko na', 'na-send na', 'gi-send na nako', 'nabayad na', 'gcash na po', 'transferred', 'transfer done',
    'okay na po, nakapagbayad na', 'na send na po', 'na-gcash ko na po']) assert(paidClaim(t), t);
  for (const t of ['bayad na po?', 'paano mag-transfer', 'how do I pay', 'nabayaran na ba?', 'magbayad ako mamaya', 'what time check-in', '',
    'sent my ID po', 'nasend ko na ang ID', 'we want to transfer the dates', 'magkano bayad', 'how much bayad po', 'transfer',
    'not paid yet', 'hindi pa ako nakabayad', 'mag-bayad ako mamaya', 'bayad later po', 'wala pa bayad', 'di pa nasend']) assert(!paidClaim(t), t);
});

Deno.test('"bayad na po" at await_receipt bumps the request card once, then not again within the hour', async () => {
  const one = await turn({ text: 'bayad na po' }, null, FLOW);
  assertEquals(one.bumps.length, 1, JSON.stringify(one.calls));
  assertEquals(one.bumps[0].detail?.booking, FLOW.booking_id);
  assertEquals(one.saved.paid_bump_at, now.toISOString());
  const later = new Date(now.getTime() + 30 * 60_000);
  const two = await turn({ text: 'sent na po' }, null, one.saved, later);
  assertEquals(two.bumps.length, 0, JSON.stringify(two.calls));
  const nextHour = new Date(now.getTime() + 61 * 60_000);
  const three = await turn({ text: 'bayad na po' }, null, { ...one.saved, receipt_expires_at: iso(20), updated_at: iso(-0.1, nextHour) }, nextHour);
  assertEquals(three.bumps.length, 1, 'an hour later it may bump again');
});

Deno.test('a file that is not a photo bumps once and not twice; a photo is a receipt, not a bump', async () => {
  const one = await turn(FILE, null, FLOW);
  assertEquals(one.bumps.length, 1, JSON.stringify(one.calls));
  const two = await turn(FILE, null, one.saved, new Date(now.getTime() + 10 * 60_000));
  assertEquals(two.bumps.length, 0);
  const photo = await turn({ attachments: [{ type: 'image', payload: { url: 'https://example.invalid/r.jpg' } }] }, null, FLOW);
  assertEquals(photo.bumps.length, 0);
  assertEquals(photo.calls.filter((c) => c.fx === 'receipt').length, 1);
});

Deno.test('a shared link (fallback attachment) is no payment signal', async () => {
  assertEquals((await turn({ attachments: [{ type: 'fallback', payload: { url: 'https://example.invalid/x' } }] }, null, FLOW)).bumps.length, 0);
});

Deno.test('a question about paying is not a claim; no booking waiting for a receipt is not bumped', async () => {
  assertEquals((await turn({ text: 'nabayaran na ba?' }, null, FLOW)).bumps.length, 0);
  assertEquals((await turn({ text: 'bayad na po' }, null, { ...FLOW, step: 'receipt_sent' })).bumps.length, 0);
  assertEquals((await turn({ text: 'bayad na po' }, null, null)).bumps.length, 0);
});

Deno.test('D-317: under a host hold the bump still happens, once, and nothing goes to the guest', async () => {
  const hold = iso(24 * 20);
  const one = await turn({ text: 'bayad na po' }, hold, FLOW);
  assertEquals(one.sends.length, 0, JSON.stringify(one.calls));
  assertEquals(one.bumps.length, 1);
  assert(one.calls.some((c) => c.fx === 'ops' && c.text!.includes('Cassy stays quiet')), 'the host notice still goes');
  const two = await turn(FILE, hold, one.saved, new Date(now.getTime() + 5 * 60_000));
  assertEquals(two.sends.length, 0);
  assertEquals(two.bumps.length, 0);
});

Deno.test('no new guest line: the turn sends what it sent before SPEC-44 (the bump only adds the Finance card)', async () => {
  const { calls } = await turn({ text: 'bayad na po' }, null, FLOW);
  const sends = calls.filter((c) => c.fx === 'send');
  assert(sends.length <= 1, JSON.stringify(sends));
  for (const s of sends) assert(!/Finance|request card|Paid – confirm/i.test(s.text ?? ''), s.text);
});
