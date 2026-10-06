// deno test --no-check -A messenger-concierge/s73.test.ts
// Session 73 (GOLDEN-RUN-2026-10-06-spec39-after, 63/82): each golden failure reproduced through the real handle() with the
// probe effects, an in-memory db and a stubbed model reply (the deployed code path, no network), or through the pure piece.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { parsePax, start, type Flow } from './booking.ts';
import * as P from './persona.ts';
import { lintReply, paragraphs } from './voice.ts';
import { promoCases } from './golden.ts';
import { SEED_CARD } from '../_shared/cascade-core/pricing.ts';
import { setProviderKey } from '../_shared/cascade-core/providers.ts';

(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { checkoutHint, handle, priceAnchor, probeEffects, rateAsked } = await import('./index.ts');

const now = new Date('2026-10-06T06:00:00Z');
const ago = (m: number) => new Date(now.getTime() - m * 60_000).toISOString();
type Call = { fx: string; text?: string; detail?: any };
type Cal = Array<{ checkin_date: string; checkout_date: string }>;
// deno-lint-ignore no-explicit-any
function fakeDb(row: any, calendar: Cal = []) {
  const writes: Array<{ table: string; op: string; v: any }> = [];
  const q = (table: string): any => new Proxy({}, { get(_t, k) {
    if (k === 'then') return (res: (x: unknown) => void) => res({ data: table === 'calendar_events' ? calendar : [], error: null });
    if (k === 'maybeSingle' || k === 'single') return () => Promise.resolve({ data: table === 'concierge_threads' ? row : null, error: null });
    if (k === 'upsert' || k === 'insert' || k === 'update') return (v: any) => { writes.push({ table, op: String(k), v }); return q(table); };
    return () => q(table);
  } });
  return { db: { from: q }, writes };
}
/** The model's JSON for every draft this turn; `seen` keeps each prompt's last user message (the hints ride on it). */
function stubModel(answer: string, ask: string | null = null, uncertain = false) {
  const seen: string[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = ((url: string | URL | Request, init?: RequestInit) => {
    if (!String(url).includes('openrouter.ai')) return Promise.resolve(new Response('{}', { status: 500 }));
    seen.push(String(JSON.parse(String(init?.body ?? '{}')).messages?.at(-1)?.content ?? ''));
    return Promise.resolve(new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify({ answer, ask, uncertain }) }, finish_reason: 'stop' }] }), { status: 200 }));
  }) as typeof fetch;
  setProviderKey('test');
  return { seen, restore: () => { globalThis.fetch = real; setProviderKey(null); } };
}
async function turn(text: string, bf: Flow | null, history: Array<[string, string]> = [], calendar: Cal = []) {
  const row = { psid: 'probe:s73', guest_name: 'Ben', human_until: null, bot_turns: history.length, last_risk: null, last_mid: null, booking_flow: bf,
    history: history.flatMap(([g, b], i) => [{ role: 'guest', text: g, at: ago(10 - i) }, { role: 'bot', text: b, at: ago(10 - i) }]) };
  const { db, writes } = fakeDb(row, calendar);
  const calls: Call[] = [];
  await handle(db as any, { sender: { id: 'probe:s73' }, recipient: { id: 'page' }, message: { mid: 'm-' + Math.random(), text } }, 'auto', probeEffects(calls as any, 'Ben', now), now);
  const saved = writes.find((w) => w.table === 'concierge_threads' && w.op === 'upsert')?.v;
  return { reply: calls.filter((c) => c.fx === 'send').map((c) => c.text).join('\n\n'), calls, saved };
}
const DIGIT_P1 = /^(?:(?!\n\s*\n)[\s\S])*\d/; // golden s63-month: no figure in the greeting's paragraph

Deno.test('s73 F1: a dated price question with no promo night gets code figures - 2 nights, PHP 3,382, never 5,073', async () => {
  const a = priceAnchor(['Hi, how much for Oct 19 to 21?'], now);
  assert(a.includes('2 nights') && a.includes('PHP 3,382') && a.includes('PHP 1,691') && !a.includes('5,073'), a);
  assert(priceAnchor(['magkano po Oct 19 to 21?'], now, 'taglish').includes('PHP 3,382'));
  // a length named beside one date keeps the length's anchor (one date alone reads as one night)
  assert(priceAnchor(['Oct 19 po, how much for 3 nights?'], now).includes('3 nights'));
  // and it reaches the model through handle(): the turn's prompt carries the figures
  const m = stubModel('For Oct 19 to 21, booking directly brings your 2 nights to PHP 1,691 per night, PHP 3,382 for the stay.');
  try {
    await turn('Hi, how much for Oct 19 to 21?', null);
    assert(m.seen[0].includes('PHP 3,382') && !m.seen[0].includes('5,073'), m.seen[0].slice(0, 400));
  } finally { m.restore(); }
});

Deno.test('s73 F2: a month-scale stay named is a price question, rate word or not', () => {
  for (const t of ['Hello, can I ask for details regarding our booking good for two months?', 'Hello po, pwede po magtanong about sa booking for two months?', 'how much po?', 'a month-long stay'])
    assertEquals(rateAsked(t), true, t);
  for (const t of ['Hello', 'is there parking?', 'we will stay 2 nights', 'a week po']) assertEquals(rateAsked(t), false, t);
});

Deno.test('s73 F3: the first reply keeps the greeting as its own paragraph - no figure in paragraph 1, lint clean, four paragraphs at most', async () => {
  const quote = 'For a month-long stay, your direct rate comes down to PHP 1,335 per night from the standard PHP 1,780, about PHP 40,050 for the stay.';
  for (const l of ['en', 'tl', 'bis'] as const) {
    const r = P.compose({ answer: quote, ask: null }, { lang: l, name: 'Ben', greet: true, greetNow: true, followUp: false, flowFollowUp: null, hostLine: '', quiet: false, look: '', decision: false, linkTurn: false, siteShown: false, datesKnown: false, held: { dates: false, pax: false, name: true }, prevBot: '' }).reply;
    assertEquals(r.split('\n\n')[0], P.greeting('Ben', l).trim(), r);
    assert(!DIGIT_P1.test(r) && paragraphs(r).length <= 4 && r.endsWith(P.SIGNATURE), r);
    assertEquals(lintReply(r, 'How much for a month-long stay?', { firstTurn: true }), [], r);
  }
  // SPEC-39 3.5: the reserved first reply too
  const r = await turn('Hello, is Oct 19 to 21 available?', null, [], [{ checkin_date: '2026-10-18', checkout_date: '2026-10-22' }]);
  assert(r.reply.startsWith('Hi Ben, thank you for reaching out to Cascade Hideaway.\n\nI\'m sorry, Oct 19 to 21 is already reserved'), r.reply);
});

Deno.test('s73 F4: a bare count closing a dated "available?" is the party; dates and other counts are untouched', () => {
  assertEquals(parsePax('Oct 19 to 21 available? 2'), 2);
  assertEquals(parsePax('Oct 19 to 21, 3'), 3);
  const f = start('Oct 19 to 21 available? 2', now);
  assertEquals([f.pax, f.step], [2, 'offer']);
  assertEquals(start('Oct 30 to Nov 1? 2', now).pax, 2);
  // the other direction
  assertEquals(start('Is Oct 19 to 21 available?', now).pax, undefined);
  assertEquals(start('Is Oct 19 to 21 available? 2 nights po', now).pax, undefined);
  assertEquals(start('Available Oct 5, 6', now).pax, undefined); // two dates, not a count
  assertEquals(start('Oct 19 to 21 available? 9', now).pax, undefined);
  assertEquals(parsePax('2 po kami'), 2);
  assertEquals(parsePax('We are 2 adults with 1 kid only.'), 3);
  assertEquals(start('Hi, is Oct 19 to 21 available? 2 adults', now).pax, 2);
});

Deno.test('s73 F5: a dated price answer closes on the hold question, and "Yes please" starts the flow at the guest count', async () => {
  const m = stubModel('For Oct 19 to 21, booking directly brings your 2 nights to PHP 1,691 per night, PHP 3,382 for the stay.');
  try {
    const t1 = await turn('Hi, how much for Oct 19 to 21?', null);
    assert(/Shall we hold those dates for you\?\n\nCassy, Cascade Concierge$/.test(t1.reply), t1.reply);
    assertEquals((t1.reply.match(/\?/g) ?? []).length, 1, t1.reply);
    const calls = m.seen.length;
    const t2 = await turn('Yes please', null, [['Hi, how much for Oct 19 to 21?', t1.reply]]);
    assertEquals(t2.saved.booking_flow.step, 'pax');
    assert(/Oct 19 to 21 is available[\s\S]*How many of you will be staying\?/.test(t2.reply) && !t2.reply.includes(P.SIGNATURE), t2.reply);
    assertEquals(m.seen.length, calls, 'the flow speaks, the model is not asked about "Yes please"');
    // a taken stay is never offered a hold
    const taken = await turn('Hi, how much for Oct 19 to 21?', null, [], [{ checkin_date: '2026-10-20', checkout_date: '2026-10-21' }]);
    assert(!/hold those dates/.test(taken.reply), taken.reply);
  } finally { m.restore(); }
});

const offer = (lang: 'en' | 'tl'): Flow => ({ step: 'offer', checkin: '2026-10-26', checkout: '2026-10-29', pax: 2, lang, started_at: ago(5), updated_at: ago(5) });
Deno.test('s73 F6: a price proposal or objection keeps its policy_exception card when the model is unsure, and the model is told code says the host line', async () => {
  for (const [text, lang] of [['can you do 1,500 a night?', 'en'], ['medyo mahal po', 'tl']] as const) {
    const m = stubModel('We understand. Your three nights come to PHP 5,073 at the direct rate.', 'Shall we hold your dates while our host takes a look?', true);
    try {
      const r = await turn(text, offer(lang), [['Hi, is Oct 26 to 29 available? 2 adults', 'Oct 26 to 29 is available.\n\nShall we hold those dates for you?']]);
      assertEquals(r.calls.filter((c) => c.fx === 'handoff').map((c) => c.detail.risk), ['policy_exception'], text);
      assert(/"handoff"[^}]*policy_exception/.test(JSON.stringify(r.calls.filter((c) => c.fx !== 'send'))), text);
      assert(m.seen[0].includes('Do not say you will forward'), m.seen[0].slice(0, 300));
      assertEquals((r.reply.match(/Our host also looks/g) ?? []).length, 1, r.reply);
    } finally { m.restore(); }
  }
});

Deno.test('s73 F7: "what do I do before check out?" tells the model the 12:00 noon time first; a late check-out ask does not', () => {
  for (const t of ['What do I need to do before check out?', 'Ano po gagawin bago mag check out?', 'Unsay buhaton before checkout?']) assert(checkoutHint(t).includes('12:00 noon'), t);
  for (const t of ['Can we check out late, before 3 pm?', 'What time is check-in?', 'is there parking?']) assertEquals(checkoutHint(t), '', t);
});

Deno.test('s73 F8: promo flow cases pick open promo nights, and step aside when the window is taken', () => {
  const at = new Date('2026-10-01T00:00:00Z'); // the seed promotion: nights of Oct 11 to 17
  const ids = (b: Set<string> | null) => promoCases(SEED_CARD, at, b).map((c) => c.id);
  const say = (b: Set<string> | null, id: string) => promoCases(SEED_CARD, at, b).find((c) => c.id === id)?.turns[0].say;
  assert(say(null, 'promo-inside-flow-en')!.includes('Oct 12 to 15')); // unchanged without a calendar
  const nights = (a: number, b: number) => new Set(Array.from({ length: b - a + 1 }, (_, i) => `2026-10-${String(a + i).padStart(2, '0')}`));
  assert(say(nights(12, 13), 'promo-inside-flow-en')!.includes('Oct 14 to 17'), say(nights(12, 13), 'promo-inside-flow-en'));
  const full = new Set([...nights(11, 19)]);
  assertEquals(ids(full).includes('promo-inside-flow-en') || ids(full).includes('promo-straddle-flow-tl'), false);
  assertEquals(ids(full).includes('promo-ask-en'), true); // the free questions stay
});
