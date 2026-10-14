// deno test --no-check -A messenger-concierge/xs-hold.test.ts
// Lane XS (s82): while a host holds the chat, the "host handling" notice also asks for the Inbox push, once per message, with the guest's id only.
// Same harness as s76-takeover.test.ts. Frozen clock: `now` is passed in.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';

(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { handle, probeEffects } = await import('./index.ts');

const now = new Date('2026-10-08T02:00:00Z');
const iso = (h: number) => new Date(now.getTime() + h * 3_600_000).toISOString();
type Call = { fx: string; text?: string; detail?: Record<string, unknown> };
// deno-lint-ignore no-explicit-any
function fakeDb(row: any) {
  // deno-lint-ignore no-explicit-any
  const q = (table: string): any => new Proxy({}, { get(_t, k) {
    if (k === 'then') return (res: (x: unknown) => void) => res({ data: [], error: null });
    if (k === 'maybeSingle' || k === 'single') return () => Promise.resolve({ data: table === 'concierge_threads' ? row : null, error: null });
    if (k === 'upsert' || k === 'insert' || k === 'update') return () => q(table);
    return () => q(table);
  } });
  return { from: (t: string) => q(t), rpc: () => Promise.resolve({ data: [], error: null }) };
}
async function turn(message: Record<string, unknown>, humanUntil: string | null) {
  const row = { psid: 'probe:xs', guest_name: 'Angel', human_until: humanUntil, bot_turns: 4, last_risk: null, last_mid: null, booking_flow: null,
    history: [{ role: 'guest', text: 'Thank you so much po', at: iso(-3) }, { role: 'bot', text: 'Safe travels po.', at: iso(-3) }] };
  const calls: Call[] = [];
  // deno-lint-ignore no-explicit-any
  await handle(fakeDb(row) as any, { sender: { id: 'probe:xs' }, recipient: { id: 'page' }, message: { mid: 'm-' + calls.length, ...message } }, 'auto', probeEffects(calls as any, 'Angel', now), now);
  return calls;
}

Deno.test('XS: a routine message under a host hold asks for one guest_wrote push, with the guest id and no text', async () => {
  const calls = await turn({ text: 'What time po ang check-in?' }, iso(24 * 20));
  const inbox = calls.filter((c) => c.fx === 'inbox');
  assertEquals(inbox.length, 1, JSON.stringify(calls));
  assertEquals(inbox[0].detail, { kind: 'guest_wrote', psid: 'probe:xs' });
  assert(!JSON.stringify(inbox[0]).includes('check-in'));
  assertEquals(calls.filter((c) => c.fx === 'send' || c.fx === 'qr').length, 0);
});

Deno.test('XS: a sticker under a host hold tells nobody', async () => {
  const calls = await turn({ attachments: [{ type: 'image', payload: { url: 'https://example.invalid/s.png', sticker_id: 369239263222822 } }] }, iso(24 * 20));
  assertEquals(calls.filter((c) => c.fx === 'inbox').length, 0, JSON.stringify(calls));
});

Deno.test('XS: with no hold, Cassy answers and no guest_wrote push is asked', async () => {
  const real = globalThis.fetch;
  globalThis.fetch = (() => Promise.resolve(new Response('{}', { status: 500 }))) as typeof fetch;
  try {
    const calls = await turn({ text: 'What time po ang check-in?' }, null);
    assertEquals(calls.filter((c) => c.fx === 'inbox').length, 0, JSON.stringify(calls));
  } finally { globalThis.fetch = real; }
});

Deno.test('XS: an emergency under a host hold goes through the handoff (which sends the handover push itself), not a second guest_wrote', async () => {
  const calls = await turn({ text: 'may amoy gas sa kusina' }, iso(24 * 20));
  assertEquals(calls.filter((c) => c.fx === 'handoff').map((c) => c.detail?.risk), ['safety']);
  assertEquals(calls.filter((c) => c.fx === 'inbox').length, 0, JSON.stringify(calls));
});
