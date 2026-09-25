// deno test --no-check -A messenger-concierge/flow-after-qr.test.ts
// SPEC-31 (REVIEW-bot-2026-09-26 F1-F3, F16): every turn after the QR, through the real handle() with the probe effects and
// an in-memory db. No model is called on these paths - that is the point: code owns them.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { paymentReply, type Flow } from './booking.ts';
import { lintReply } from './voice.ts';
import { SITE_URL } from '../_shared/cascade-core/facts.ts';

// index.ts serves on import; the test only needs handle().
(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { handle, probeEffects } = await import('./index.ts');

const now = new Date('2026-09-26T04:00:00Z');
const ago = (h: number) => new Date(now.getTime() - h * 3_600_000).toISOString();
const flow = (over: Partial<Flow> = {}): Flow => ({ step: 'await_receipt', checkin: '2026-10-20', checkout: '2026-10-22', pax: 2, name: 'Ben Munez', phone: '09171234567', email: 'ben@example.com',
  lang: 'en', booking_id: 'b1', ref: 'DIR-1', deposit: 1691, total: 3382, hold: true, hold_expires_at: ago(-23), receipt_token: 't', receipt_expires_at: ago(-23), started_at: ago(2), updated_at: ago(1), ...over });

type Call = { fx: string; text?: string; detail?: any };
// deno-lint-ignore no-explicit-any
function fakeDb(row: any) {
  const writes: Array<{ table: string; op: string; v: any }> = [];
  const q = (table: string): any => new Proxy({}, { get(_t, k) {
    if (k === 'then') return (res: (x: unknown) => void) => res({ data: [], error: null });
    if (k === 'maybeSingle' || k === 'single') return () => Promise.resolve({ data: table === 'concierge_threads' ? row : null, error: null });
    if (k === 'upsert' || k === 'insert' || k === 'update') return (v: any) => { writes.push({ table, op: String(k), v }); return q(table); };
    return () => q(table);
  } });
  return { db: { from: q }, writes };
}
async function turn(bf: Flow | null, message: Record<string, unknown>, history: string[] = ['Hi']) {
  const row = { psid: 'probe:t1', guest_name: 'Ben', human_until: null, bot_turns: 1, last_risk: null, last_mid: null, booking_flow: bf,
    history: history.flatMap((t, i) => [{ role: 'guest', text: t, at: ago(3 - i * 0.1) }, { role: 'bot', text: 'Thank you. I am Cassy, noted.', at: ago(3 - i * 0.1) }]) };
  const { db, writes } = fakeDb(row);
  const calls: Call[] = [];
  await handle(db as any, { sender: { id: 'probe:t1' }, recipient: { id: 'page' }, message: { mid: 'm-' + Math.random(), ...message } }, 'auto', probeEffects(calls as any, 'Ben', now), now);
  const saved = writes.find((w) => w.table === 'concierge_threads' && w.op === 'upsert')?.v;
  return { reply: calls.filter((c) => c.fx === 'send').map((c) => c.text).join('\n\n'), calls, saved };
}
const image = { attachments: [{ type: 'image', payload: { url: 'https://example.invalid/r.jpg' } }] };

Deno.test('SPEC-31 s1: "cancel po" during the hold - host card with the ref, flow cancel_requested, no link', async () => {
  const r = await turn(flow(), { text: 'cancel po, change of plans' });
  assertEquals(r.saved.booking_flow.step, 'cancel_requested');
  const h = r.calls.filter((c) => c.fx === 'handoff');
  assertEquals(h.length, 1);
  assertEquals(h[0].detail.risk, 'cancellation');
  assertEquals(h[0].detail.note.includes('DIR-1'), true);
  assertEquals(/release the hold|ire-release|i-release/.test(r.reply), true);
  assertEquals(r.reply.includes(SITE_URL), false);
  assertEquals(/we'?ll cancel|cancelled for you/i.test(r.reply), false);
});

Deno.test('SPEC-31 s1: a date in the cancel message is a change request', async () => {
  const r = await turn(flow(), { text: 'change of plans, can we do Oct 28 to 30 instead?' });
  assertEquals(/passed the change/.test(r.reply), true);
  assertEquals(lintReply(r.reply, 'change of plans, can we do Oct 28 to 30 instead?'), []);
  assertEquals(r.calls.find((c) => c.fx === 'handoff')!.detail.note.includes('change requested'), true);
});

Deno.test('SPEC-31 s1: after the receipt the cancel line never says nothing is charged', async () => {
  const r = await turn(flow({ step: 'receipt_sent' }), { text: 'cancel my booking po' });
  assertEquals(/nothing is charged/.test(r.reply), false);
  assertEquals(/go over your payment/.test(r.reply), true);
});

Deno.test('SPEC-31 s2: "paid na po?" after the receipt - Opo, the receipt, one payment card, lint clean', async () => {
  const r = await turn(flow({ step: 'receipt_sent', lang: 'tl' }), { text: 'Paid na po, received niyo na po ba?' });
  assertEquals(/^Opo, Ben/.test(r.reply), true);
  assertEquals(/receipt/.test(r.reply), true);
  assertEquals(/personally verify/.test(r.reply), false);
  assertEquals(lintReply(r.reply, 'Paid na po, received niyo na po ba?'), []);
  assertEquals(r.calls.filter((c) => c.fx === 'handoff').map((c) => c.detail.risk), ['payment']);
});

Deno.test('SPEC-31 s2: a paid claim with no image yet asks for the screenshot and names the ref', async () => {
  const r = await turn(flow(), { text: 'I sent the GCash payment already, please confirm' });
  assertEquals(/screenshot/.test(r.reply) && r.reply.includes('DIR-1'), true);
  assertEquals(lintReply(r.reply, 'I sent the GCash payment already, please confirm'), []);
});

Deno.test('SPEC-31 s3: a photo after the hold lapsed is a receipt for the host to match, not the sales link', async () => {
  const lapsed = flow({ updated_at: ago(25), hold_expires_at: ago(1), receipt_expires_at: ago(1) });
  const r = await turn(lapsed, image);
  assertEquals(/match it|ima-match|i-match/.test(r.reply), true);
  assertEquals(r.reply.includes(SITE_URL), false);
  const h = r.calls.find((c) => c.fx === 'handoff')!;
  assertEquals([h.detail.risk, h.detail.note.includes('DIR-1'), /lapsed/.test(h.detail.note)], ['payment', true, true]);
  assertEquals([r.saved.booking_flow.step, !!r.saved.booking_flow.photo_at, r.saved.booking_flow.updated_at], ['await_receipt', true, lapsed.updated_at]);
  // ...and a "paid na" after it hears that the photo is with us
  const again = await turn(r.saved.booking_flow, { text: "paid na po kahapon" });
  assertEquals(/^(Opo|Yes), Ben, (nasa amin|your receipt)/.test(again.reply), true);
});

Deno.test('SPEC-31 s3: a photo with no booking but payment talk gets the stray line; any other photo keeps the brochure', async () => {
  const paid = await turn(null, image, ['Hi', 'nasend ko na po yung bayad']);
  assertEquals(/match it|ima-match/.test(paid.reply), true);
  assertEquals(paid.calls.find((c) => c.fx === 'handoff')!.detail.note.startsWith('No booking'), true);
  const plain = await turn(null, image, ['Hi']);
  assertEquals(plain.reply.includes(SITE_URL), true);
  assertEquals(plain.calls.some((c) => c.fx === 'handoff'), false);
  assertEquals(plain.calls.find((c) => c.fx === 'ops')!.text!.includes('attachment'), true);
});

Deno.test('SPEC-31 s6: a full payment far ahead is never "near"; inside 5 days it is', () => {
  const at = new Date('2026-09-26T04:00:00Z');
  const far = paymentReply(flow({ checkin: '2026-11-05', checkout: '2026-11-07', deposit: 3382, hold: false, hold_expires_at: null }), 'Ben', SITE_URL, at);
  assertEquals(/near|Malapit na|Duol na/.test(far), false);
  assertEquals(far.includes('yours as soon as your payment arrives'), true);
  const soon = paymentReply(flow({ checkin: '2026-09-28', checkout: '2026-09-30', deposit: 3382, hold: false, hold_expires_at: null }), 'Ben', SITE_URL, at);
  assertEquals(/As your stay is near/.test(soon), true);
});

Deno.test('SPEC-31 s6: the probe submit mirrors submit-booking - no hold for full, 24 h upload either way', async () => {
  const calls: Call[] = [];
  const fx = probeEffects(calls as any, 'Ben', now);
  const base = { step: 'confirm', checkin: '2026-11-05', checkout: '2026-11-07', pax: 2, lang: 'en', started_at: ago(1), updated_at: ago(1) } as Flow;
  const full = (await fx.submit({ ...base, pay_full: true }, { guest_name: 'Ben' } as any, 'p')).flow;
  const fee = (await fx.submit({ ...base, pay_full: false }, { guest_name: 'Ben' } as any, 'p')).flow;
  assertEquals([full.hold, full.hold_expires_at, Date.parse(full.receipt_expires_at!) - now.getTime()], [false, null, 24 * 3_600_000]);
  assertEquals([fee.hold, !!fee.hold_expires_at], [true, true]);
});
