// deno test --no-check -A messenger-concierge/s76-takeover.test.ts
// D-317 (Lloyd 2026-10-08): "once marifel and i replied, bot only notifies in the app and telegram and no longer send messages".
// Angel (BD296460) got Cassy turns and a 3 AM automated confirmation after the hosts had taken the chat over.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';

(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { handle, probeEffects } = await import('./index.ts');

const now = new Date('2026-10-08T02:00:00Z');
const iso = (h: number) => new Date(now.getTime() + h * 3_600_000).toISOString();
type Call = { fx: string; text?: string; detail?: Record<string, unknown> };
// deno-lint-ignore no-explicit-any
function fakeDb(row: any, handoffs: any[] = []) {
  // deno-lint-ignore no-explicit-any
  const writes: Array<{ table: string; v: any }> = [];
  // deno-lint-ignore no-explicit-any
  const q = (table: string): any => new Proxy({}, { get(_t, k) {
    if (k === 'then') return (res: (x: unknown) => void) => res({ data: table === 'concierge_handoffs' ? handoffs : [], error: null });
    if (k === 'maybeSingle' || k === 'single') return () => Promise.resolve({ data: table === 'concierge_threads' ? row : null, error: null });
    // deno-lint-ignore no-explicit-any
    if (k === 'upsert' || k === 'insert' || k === 'update') return (v: any) => { writes.push({ table, v }); return q(table); };
    return () => q(table);
  } });
  return { db: { from: (t: string) => q(t), rpc: () => Promise.resolve({ data: [], error: null }) }, writes };
}
const FLOW = { step: 'await_receipt', ref: 'BD296460', booking_id: 'bd296460', name: 'Angeleen Luz Villanueva', checkin: '2026-10-08', checkout: '2026-10-11',
  pax: 2, total: 5073, deposit: 5073, pay_full: true, hold: false, lang: 'en', receipt_token: 't', receipt_expires_at: iso(6), started_at: iso(-16), updated_at: iso(-1) };
// deno-lint-ignore no-explicit-any
async function turn(message: Record<string, unknown>, humanUntil: string | null, flow: any = null, handoffs: any[] = []) {
  const row = { psid: 'probe:s76', guest_name: 'Angel', human_until: humanUntil, bot_turns: 4, last_risk: null, last_mid: null, booking_flow: flow,
    history: [{ role: 'guest', text: 'Thank you so much po', at: iso(-3) }, { role: 'bot', text: 'Safe travels po.', at: iso(-3) }] };
  const { db, writes } = fakeDb(row, handoffs);
  const calls: Call[] = [];
  // deno-lint-ignore no-explicit-any
  await handle(db as any, { sender: { id: 'probe:s76' }, recipient: { id: 'page' }, message: { mid: 'm-' + Math.random(), ...message } }, 'auto', probeEffects(calls as any, 'Angel', now), now);
  return { calls, writes, sends: calls.filter((c) => c.fx === 'send' || c.fx === 'qr') };
}

Deno.test('D-317: while a host handles the chat, a routine question gets no reply and one host notice', async () => {
  const { sends, calls } = await turn({ text: 'What time po ang check-in?' }, iso(24 * 20));
  assertEquals(sends.length, 0, JSON.stringify(calls));
  const ops = calls.filter((c) => c.fx === 'ops');
  assertEquals(ops.length, 1);
  assert(ops[0].text!.includes('You are handling this chat, so Cassy stays quiet'), ops[0].text);
  assert(ops[0].text!.includes('What time po ang check-in?'), ops[0].text);
});

Deno.test('D-317: an emergency under a host hold raises the card, still with no line to the guest', async () => {
  const { sends, calls } = await turn({ text: 'may amoy gas sa kusina' }, iso(24 * 20));
  assertEquals(sends.length, 0, JSON.stringify(calls));
  assertEquals(calls.filter((c) => c.fx === 'handoff').map((c) => c.detail?.risk), ['safety']);
});

Deno.test('D-317: a receipt photo under a host hold still reaches Finance, silently', async () => {
  const { sends, calls, writes } = await turn({ attachments: [{ type: 'image', payload: { url: 'https://example.invalid/r.jpg' } }] }, iso(24 * 20), FLOW);
  assertEquals(sends.length, 0, JSON.stringify(calls));
  assertEquals(calls.filter((c) => c.fx === 'receipt').length, 1);
  assert(calls.some((c) => c.fx === 'ops' && c.text!.includes('went to Finance as a receipt')), JSON.stringify(calls));
  // Opus review: the step is saved, so the next photo is not forwarded again.
  const saved = writes.filter((w) => w.table === 'concierge_threads' && w.v.booking_flow).at(-1)!.v.booking_flow;
  assertEquals(saved.step, 'receipt_sent');
});

Deno.test('D-317: a host reply holds Cassy 30 days and never shortens a longer hold', async () => {
  const fresh = await turn({ is_echo: true, text: 'Hello po Ma’am Angel' }, null);
  const until = fresh.writes.find((w) => w.table === 'concierge_threads' && 'human_until' in w.v)!.v.human_until;
  const days = (Date.parse(until) - now.getTime()) / 86_400_000;
  assert(days > 29.9 && days < 30.1, String(until));
  const longer = iso(24 * 45);
  const kept = await turn({ is_echo: true, text: 'Noted po' }, longer);
  assertEquals(kept.writes.find((w) => w.table === 'concierge_threads' && 'human_until' in w.v)!.v.human_until, longer);
});

Deno.test('D-317: with no hold, Cassy still answers as before', async () => {
  const real = globalThis.fetch;
  globalThis.fetch = (() => Promise.resolve(new Response('{}', { status: 500 }))) as typeof fetch; // no network: the model fails, the handoff line still goes out
  try { const { sends } = await turn({ text: 'What time po ang check-in?' }, null); assert(sends.length >= 1); } finally { globalThis.fetch = real; }
});

Deno.test('D-317 review: a sticker under a host hold is neither a receipt nor a notice', async () => {
  const { sends, calls } = await turn({ attachments: [{ type: 'image', payload: { url: 'https://example.invalid/s.png', sticker_id: 369239263222822 } }] }, iso(24 * 20), FLOW);
  assertEquals(sends.length, 0);
  assertEquals(calls.filter((c) => c.fx === 'receipt' || c.fx === 'ops').length, 0, JSON.stringify(calls));
});

Deno.test('D-317 review: a Priority help tap under a host hold is a card for the host, not a line to the guest', async () => {
  const row = { psid: 'probe:s76', guest_name: 'Angel', human_until: iso(24 * 20), bot_turns: 4, last_risk: null, last_mid: null, booking_flow: null, history: [] };
  const { db } = fakeDb(row);
  const calls: Call[] = [];
  // deno-lint-ignore no-explicit-any
  await handle(db as any, { sender: { id: 'probe:s76' }, recipient: { id: 'page' }, postback: { payload: 'PRIORITY', mid: 'p-1' } }, 'auto', probeEffects(calls as any, 'Angel', now), now);
  assertEquals(calls.filter((c) => c.fx === 'send').length, 0, JSON.stringify(calls));
  assertEquals(calls.filter((c) => c.fx === 'handoff').map((c) => c.detail?.risk), ['priority']);
});

Deno.test('D-317 review: a safety report alone (no host reply) still lets the next emergency through, and keeps routine chat quiet without a "handling" notice', async () => {
  const open = [{ risk: 'safety', created_at: iso(-2) }];
  const second = await turn({ text: 'may amoy gas sa kusina' }, null, null, open);
  assert(second.sends.length >= 1, JSON.stringify(second.calls));
  const routine = await turn({ text: 'What is the Wi-Fi password?' }, null, null, open);
  assertEquals(routine.sends.length, 0, JSON.stringify(routine.calls));
  assert(!routine.calls.some((c) => c.fx === 'ops' && String(c.text).includes('You are handling this chat')), JSON.stringify(routine.calls));
});
