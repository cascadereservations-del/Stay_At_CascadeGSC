// deno test --no-check -A messenger-concierge/house-path.test.ts
// D-282: a guests-only house fact (the Wi-Fi password) is locked for an unverified thread - one fixed ask that never says what
// the fact is; the guide's check (date + name, stay on today) opens it through check-out without paging the host; two misses
// take the ordinary unmatched path. Public how-tos (the aircon remote) never ask.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { clearHouseCache } from '../_shared/cascade-core/house.ts';

(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { handle, probeEffects } = await import('./index.ts');

const now = new Date('2026-09-28T04:00:00Z'); // noon, Sept 28 in Manila
const ago = (h: number) => new Date(now.getTime() - h * 3_600_000).toISOString();
const HOUSE = [
  { topic: 'wifi', title: 'Wi-Fi', tier: 'guest', keywords: ['wifi', 'password', 'wifi password'], body: 'The network is {{WIFI_SSID}} and the password is {{WIFI_PASSWORD}}.' },
  { topic: 'wifi-name', title: 'Wi-Fi, for prospects', tier: 'public', keywords: ['wifi', 'internet'], body: 'Fibre broadband.' },
];

// deno-lint-ignore no-explicit-any
function fakeDb(row: any, verify: any) {
  const writes: Array<{ table: string; op: string; v: any }> = [], rpcs: any[] = [];
  const q = (table: string): any => new Proxy({}, { get(_t, k) {
    if (k === 'then') return (res: (x: unknown) => void) => res({ data: table === 'house_facts' ? HOUSE : [], error: null });
    if (k === 'maybeSingle' || k === 'single') return () => Promise.resolve({ data: table === 'concierge_threads' ? row : null, error: null });
    if (k === 'upsert' || k === 'insert' || k === 'update') return (v: any) => { writes.push({ table, op: String(k), v }); return q(table); };
    return () => q(table);
  } });
  return { db: { from: q, rpc: (name: string, args: unknown) => { rpcs.push({ name, args }); return Promise.resolve({ data: name === 'verify_booking' ? verify : null, error: null }); } }, writes, rpcs };
}
// deno-lint-ignore no-explicit-any
async function turn(text: string, history: any[] = [], verify: any = null, extra: Record<string, unknown> = {}) {
  clearHouseCache();
  const row = { psid: 'probe:h1', guest_name: 'Allyssa', human_until: null, bot_turns: 1, last_risk: null, last_mid: null, booking_flow: null, verified_until: null, history, ...extra };
  const { db, writes, rpcs } = fakeDb(row, verify);
  const calls: Array<{ fx: string; text?: string; detail?: any }> = [];
  await handle(db as any, { sender: { id: 'probe:h1' }, recipient: { id: 'page' }, message: { mid: `m-${Math.random()}`, text } }, 'auto', probeEffects(calls as any, 'Allyssa', now), now);
  const saved = writes.find((w) => w.table === 'concierge_threads' && w.op === 'upsert')?.v;
  return { reply: calls.filter((c) => c.fx === 'send').map((c) => c.text).join('\n\n'), handoffs: calls.filter((c) => c.fx === 'handoff'), saved, rpcs: rpcs.filter((r) => r.name === 'verify_booking') };
}
const asked = (tries: number, h = 0.1) => [{ role: 'guest', text: "what's the wifi password?", at: ago(h) }, { role: 'bot', text: 'ask', at: ago(h), route: { house: tries, q: "what's the wifi password?" } }];
const stay = { found: true, match: true, first_name: 'Allyssa', checkin_date: '2026-09-27', checkout_date: '2026-09-29' };

Deno.test('unverified: the wifi password gets the stay check, which never names the fact, and no host card', async () => {
  const r = await turn("Hi, what's the wifi password?");
  assert(/kept for guests staying with us/.test(r.reply));
  assert(!/password|wifi|wi-fi/i.test(r.reply));
  assertEquals(r.handoffs.length, 0);
  assertEquals(r.saved.history.at(-1).route, { house: 1, q: "Hi, what's the wifi password?" });
});

Deno.test('the answer matches a stay on today: verified through check-out, no priority card, the question goes on', async () => {
  const r = await turn('Sept 27, Allyssa', asked(1), stay);
  assertEquals(r.rpcs, [{ name: 'verify_booking', args: { p_checkin_date: '2026-09-27', p_initial: 'A' } }]);
  assertEquals(r.saved.verified_until, '2026-09-29');
  assert(!r.handoffs.some((h) => h.detail.risk === 'priority'));
  assert(!/couldn't quite find/.test(r.reply));
  assertEquals(r.saved.history.filter((h: any) => h.role === 'guest').at(-1).text, 'Sept 27, Allyssa'); // what they typed is kept
});

Deno.test('a verified thread is never asked again until check-out', async () => {
  const r = await turn("what's the wifi password?", [], null, { verified_until: '2026-09-29' });
  assert(!/kept for guests staying with us/.test(r.reply));
  const after = await turn("what's the wifi password?", [], null, { verified_until: '2026-09-27' });
  assert(/kept for guests staying with us/.test(after.reply));
});

Deno.test('no match: one retry, then the ordinary unmatched card and the phone route', async () => {
  const wrong = { ...stay, match: false };
  const first = await turn('Sept 27, Ben', asked(1), wrong);
  assert(/couldn't quite find today's stay/.test(first.reply));
  assertEquals(first.handoffs.length, 0);
  assertEquals(first.saved.history.at(-1).route.house, 2);
  const second = await turn('Sept 26, Ben', asked(2), wrong);
  assertEquals(second.handoffs.map((h) => h.detail.risk), ['uncertain']);
  assertEquals(second.saved.history.at(-1).route, { priority: 'unmatched' });
});

Deno.test('a prospect asking "is there wifi?" is not asked for a stay', async () => {
  const r = await turn('Hi, is there wifi?');
  assert(!/kept for guests staying with us/.test(r.reply));
  assertEquals(r.saved.history.at(-1).route?.house, undefined);
});
