// deno test --no-check -A messenger-concierge/s73.test.ts
// Session 73 (GOLDEN-RUN-2026-10-06-spec39-after, 63/82): each golden failure reproduced through the real handle() with the
// probe effects, an in-memory db and a stubbed model reply (the deployed code path, no network), or through the pure piece.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { bookingStart, parsePax, start, type Flow } from './booking.ts';
import * as P from './persona.ts';
import { lintReply, paragraphs } from './voice.ts';
import { promoCases } from './golden.ts';
import { SEED_CARD } from '../_shared/cascade-core/pricing.ts';
import { setProviderKey } from '../_shared/cascade-core/providers.ts';

(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { checkoutHint, handle, priceAnchor, priceAsked, pricedStay, probeEffects, rateAsked } = await import('./index.ts');

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
  const a = priceAnchor(['Hi, how much for Oct 19 to 21?'], now).text;
  assert(a.includes('2 nights') && a.includes('PHP 3,382') && a.includes('PHP 1,691') && !a.includes('5,073'), a);
  assert(priceAnchor(['magkano po Oct 19 to 21?'], now, 'taglish').text.includes('PHP 3,382'));
  // a length named beside one date is that many nights from it (one date alone reads as one night)
  assert(priceAnchor(['Oct 19 po, how much for 3 nights?'], now).text.includes('3 nights'));
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
// D-311.6 (Lloyd 2026-10-07) replaces the s73 F6 hint: code writes the haggle answer - no model call, no rate explanation.
Deno.test('s73 F6 / D-311.6: a price proposal or objection keeps its policy_exception card, and code answers it: we understand, the host line, the hold question', async () => {
  for (const [text, lang] of [['can you do 1,500 a night?', 'en'], ['medyo mahal po', 'tl']] as const) {
    const m = stubModel('We understand. Your three nights come to PHP 5,073 at the direct rate.', 'Shall we hold your dates while our host takes a look?', true);
    try {
      const r = await turn(text, offer(lang), [['Hi, is Oct 26 to 29 available? 2 adults', 'Oct 26 to 29 is available.\n\nShall we hold those dates for you?']]);
      assertEquals(r.calls.filter((c) => c.fx === 'handoff').map((c) => c.detail.risk), ['policy_exception'], text);
      assert(/"handoff"[^}]*policy_exception/.test(JSON.stringify(r.calls.filter((c) => c.fx !== 'send'))), text);
      assertEquals(m.seen.length, 0, 'no model call for a haggle');
      assert(r.reply.startsWith(P.haggleLine(lang)), r.reply);
      assertEquals((r.reply.match(/Our host also looks/g) ?? []).length, 1, r.reply);
      assert(r.reply.trimEnd().endsWith(P.haggleHold('Oct 26 to 29', 'en')), r.reply); // "medyo mahal po" reads as English with a courtesy po
      assert(!/PHP|₱|%|per night/.test(r.reply), r.reply);
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

// ---- Round 2 (Fable review of 4a87ba5) ----
Deno.test('s73 R2-1: two dates are the stay whatever length word sits beside them; a length is read only beside one date', () => {
  for (const t of ['Oct 19 to 21, 3 days 2 nights, how much?', 'how much for Oct 19 to 21, 3 days?', 'Oct 19 to 21 for a week?']) {
    const a = priceAnchor([t], now).text;
    assert(a.includes('PHP 3,382') && !a.includes('5,073') && !/7 nights/.test(a), `${t}: ${a}`);
  }
  const a = priceAnchor(['how much for 5 nights?', 'ok what about Oct 19 to 21?'], now).text;
  assert(a.includes('PHP 3,382') && !/5 nights/.test(a), a);
  assertEquals(priceAnchor(['how much for 5 nights?'], now).text.includes('5 nights'), true); // no date: the length's anchor
});

Deno.test('s73 R2-2: "already given" matches the stay total, not a per-night rate two stays share', async () => {
  const m = stubModel('For Oct 26 to 29 your 3 nights come to PHP 5,073.');
  try {
    const prior: Array<[string, string]> = [['how much for Oct 19 to 21?', 'Booking directly with us brings your 2 nights to PHP 1,691 per night instead of the standard PHP 1,780 — PHP 3,382 for the stay.']];
    await turn('how much for Oct 26 to 29?', null, prior);
    assert(m.seen[0].includes('PHP 5,073') && !m.seen[0].includes('stay figures were already given'), m.seen[0].slice(0, 300));
    await turn('how much again for Oct 19 to 21?', null, prior);
    assert(m.seen[1].includes('stay figures were already given'), m.seen[1].slice(0, 300));
  } finally { m.restore(); }
});

Deno.test('s73 R2-3: cost, total, rates, presyo and bayad are price questions', () => {
  for (const t of ['Hi, what would Oct 19 to 21 cost for 2?', 'total for Oct 19 to 21?', 'your rates po?', 'pricing?', 'magkano presyo?', 'pila ang bayad?', 'hm po'])
    assertEquals(priceAsked(t), true, t);
  assert(priceAnchor(['Hi, what would Oct 19 to 21 cost for 2?'], now).text.includes('PHP 3,382'));
});

Deno.test('s73 R2-4: a yes to the one-night hold starts the flow in every register, for that one night', async () => {
  for (const l of ['en', 'tl', 'bis'] as const) {
    const offerLine = `For Oct 19 the rate is PHP 1,780.\n\n${P.holdOffer(true, l, false)}`;
    assertEquals(bookingStart(l === 'en' ? 'Yes please' : 'opo', ['how much for Oct 19?'], offerLine, now), 'how much for Oct 19?', l);
  }
  const m = stubModel('For Oct 19 the rate is PHP 1,780 for the night.');
  try {
    const t1 = await turn('how much for Oct 19?', null);
    assert(/Shall we hold that night for you\?/.test(t1.reply), t1.reply);
    const t2 = await turn('Yes please', null, [['how much for Oct 19?', t1.reply]]);
    assertEquals([t2.saved.booking_flow.checkin, t2.saved.booking_flow.checkout, t2.saved.booking_flow.step], ['2026-10-19', '2026-10-20', 'pax']);
  } finally { m.restore(); }
});

Deno.test('s73 R2-5/R2-8: no hold offered to a group that does not fit, past 60 nights, or without a price asked', async () => {
  const m = stubModel('Here is what we can share for those dates.');
  try {
    for (const t of ['how much for Oct 19 to 21 for 5 adults?', 'how much for Oct 10 to Dec 20?', 'Oct 10 to Nov 10, is it quiet?']) {
      const r = await turn(t, null);
      assert(!/hold (those dates|that night)/.test(r.reply), `${t}: ${r.reply}`);
    }
  } finally { m.restore(); }
});

Deno.test('s73 R2-6: a day-first date counts as known - figures and no dates question', async () => {
  const m = stubModel('For Oct 19 to 21, your 2 nights come to PHP 3,382.');
  try {
    const r = await turn('how much for 19 to 21 Oct?', null);
    assert(m.seen[0].includes('PHP 3,382') && m.seen[0].includes("dates already given"), m.seen[0].slice(0, 300));
    assert(!/which dates|dates are you looking at/i.test(r.reply), r.reply);
  } finally { m.restore(); }
});

Deno.test('s73 R2-7: a dated first reply whose answer closes on the hold question is not logged no_answer', () => {
  const r = P.compose({ answer: 'For Oct 19 to 21, your 2 nights come to PHP 3,382.', ask: P.holdOffer(false, 'en', false) },
    { lang: 'en', name: 'Ben', greet: true, greetNow: true, followUp: false, flowFollowUp: null, hostLine: '', quiet: false, look: '', decision: false, linkTurn: false, siteShown: false, datesKnown: true, held: { dates: true, pax: false, name: true }, prevBot: '' }).reply;
  assertEquals(lintReply(r, 'how much for Oct 19 to 21?', { firstTurn: true }), [], r);
  assert(lintReply('Your mobile number po?', 'is Oct 3 to 4 available?').includes('no_answer')); // a question back still is
});

Deno.test('s73 R2-8: checkoutHint needs a question about leaving; promo-rate-dated-en steps aside with the straddle', () => {
  for (const t of ['can I check out the steps to book?', 'check out your page', 'Can we check out late, before 3 pm?']) assertEquals(checkoutHint(t), '', t);
  for (const t of ['What are the check-out instructions?', 'anything to do before checking out?']) assert(checkoutHint(t).includes('12:00 noon'), t);
  const full = new Set(Array.from({ length: 9 }, (_, i) => `2026-10-${String(11 + i).padStart(2, '0')}`));
  assertEquals(promoCases(SEED_CARD, new Date('2026-10-01T00:00:00Z'), full).some((c) => c.id === 'promo-rate-dated-en'), false);
  assertEquals(promoCases(SEED_CARD, new Date('2026-10-01T00:00:00Z'), null).some((c) => c.id === 'promo-rate-dated-en'), true);
});

// ---- Round 3 (Fable re-review of 345b8b8) ----
const stayOf = (texts: string[]) => { const s = pricedStay(texts, now); return s ? `${s.checkin}..${s.checkout}` : null; };
Deno.test('s73 R3-1: one incidental date inside the quoted range keeps the range; a yes holds the quoted stay', async () => {
  const q = 'how much for Oct 19 to 21?';
  for (const later of ['our flight lands Oct 19 at 2 pm, can we check in early?', 'we leave on Oct 21', 'we leave Oct 21 early, ok?'])
    assertEquals(stayOf([q, later, 'so how much in total?']), '2026-10-19..2026-10-21', later);
  assert(priceAnchor([q, 'we leave on Oct 21', 'so how much in total?'], now).text.includes('PHP 3,382'));
  const r = await turn('Yes please', null, [[q, 'For Oct 19 to 21 your 2 nights come to PHP 3,382.'], ['we leave Oct 21 early, ok?', 'Of course. Shall we hold those dates for you?']]);
  assertEquals([r.saved.booking_flow.checkin, r.saved.booking_flow.checkout, r.saved.booking_flow.step], ['2026-10-19', '2026-10-21', 'pax']);
});

Deno.test('s73 R3-2: a date the guest takes back is not the stay', async () => {
  assertEquals(stayOf(['sorry not Oct 19, Oct 20']), '2026-10-20..2026-10-21');
  assertEquals(stayOf(['not Oct 19 to 21, Oct 20 to 22 please']), '2026-10-20..2026-10-22');
  assertEquals(stayOf(['how much for Oct 19 to 21?', 'hindi po Oct 19 to 21, Oct 23 to 25 po']), '2026-10-23..2026-10-25');
  assertEquals(stayOf(['available po ba Oct 19 to 21? hindi po ba fully booked?']), '2026-10-19..2026-10-21'); // a question tag, not a correction
  const r = await turn('Yes please', null, [['not Oct 19 to 21, Oct 20 to 22 please, how much?', 'Your 2 nights come to PHP 3,382. Shall we hold those dates for you?']]);
  assertEquals([r.saved.booking_flow.checkin, r.saved.booking_flow.checkout], ['2026-10-20', '2026-10-22']);
});

Deno.test('s73 R3-3: a past stay told about is not priced as next year; a 12 noon check-in question still is', () => {
  assertEquals(stayOf(['last time we stayed Sep 5 to 7, it was lovely']), null); // R4-2: a past stay with a price ask is priced
  assertEquals(stayOf(['we stayed Oct 1 to 3 last year']), null);
  assertEquals(stayOf(['Oct 19 to 21, can we check in 12 noon? how much?']), '2026-10-19..2026-10-21');
});

Deno.test('s73 R3-4: past 60 nights the model is told to quote no total, and no hold is offered', async () => {
  for (const t of ['how much for Oct 10 to Dec 20?', 'how much for 3 months?']) assertEquals(priceAnchor([t], now).text, '[Over 60 nights: quote no total; the host prices long stays.] ', t);
  const m = stubModel('Our host prices stays this long personally.');
  try {
    const r = await turn('how much for Oct 10 to Dec 20?', null);
    assert(m.seen[0].includes('Over 60 nights: quote no total') && !/hold those dates/.test(r.reply), m.seen[0].slice(0, 200));
  } finally { m.restore(); }
});

// ---- Round 4 (Fable final re-check of 00e0bc5) ----
Deno.test('s73 R4-1: a narrowed single date is the stay asked for; only an incidental date joins the quoted range', async () => {
  const cases: Array<[Array<[string, string]>, string, string]> = [
    [[['how much for Oct 19 to 25?', 'Your 6 nights come to PHP 9,612.'], ['hmm how about just Oct 20?', 'One night on Oct 20 is PHP 1,780. Shall we hold that night for you?']], '2026-10-20', '2026-10-21'],
    [[['how much for Oct 19 to 25?', 'Your 6 nights come to PHP 9,612.'], ['actually only Oct 24, 1 night', 'One night on Oct 24 is PHP 1,780. Shall we hold that night for you?']], '2026-10-24', '2026-10-25'],
    [[['how much for Oct 19 to 21?', 'Your 2 nights come to PHP 3,382.'], ['sorry not Oct 19, Oct 20', 'One night on Oct 20 is PHP 1,780. Shall we hold that night for you?']], '2026-10-20', '2026-10-21'],
  ];
  for (const [history, ci, co] of cases) {
    const r = await turn('Yes please', null, history);
    assertEquals([r.saved.booking_flow.checkin, r.saved.booking_flow.checkout], [ci, co], history[1][0]);
  }
  assertEquals(stayOf(['how much for Oct 19 to 25?', 'how about just Oct 20, how much?']), '2026-10-20..2026-10-21'); // the price turn itself
  for (const later of ['we leave on Oct 21', 'our flight lands Oct 19 at 2 pm, can we check in early?'])
    assertEquals(stayOf(['how much for Oct 19 to 21?', later]), '2026-10-19..2026-10-21', later);
});

Deno.test('s73 R4-2: a past stay mentioned beside a price ask is priced', () => {
  assertEquals(stayOf(['same as last year po, Oct 19 to 21, how much?']), '2026-10-19..2026-10-21');
  assert(priceAnchor(['same as last year po, Oct 19 to 21, how much?'], now).text.includes('PHP 3,382'));
  assertEquals(stayOf(['we stayed Oct 1 to 3 last year']), null);
});

// S74 cache: Gemini's implicit cache matches the START of the prompt, so everything static must come first and the per-turn
// blocks last; the OUTPUT contract still follows the voice exemplars (live 2026-09-13).
Deno.test('S74 cache: the concierge system prompt is static first (voice, FACTS, contract), per-turn last (name, landmarks, availability)', async () => {
  const systems: string[] = [], real = globalThis.fetch;
  globalThis.fetch = ((url: string | URL | Request, init?: RequestInit) => {
    if (!String(url).includes('openrouter.ai')) return Promise.resolve(new Response('{}', { status: 500 }));
    const sys = String(JSON.parse(String(init?.body ?? '{}')).messages?.[0]?.content ?? '');
    if (sys.includes('GUEST FIRST NAME:')) systems.push(sys);
    return Promise.resolve(new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify({ answer: 'ok', ask: null, uncertain: false }) }, finish_reason: 'stop' }] }), { status: 200 }));
  }) as typeof fetch;
  setProviderKey('test');
  try { await turn('Hi, how much for Oct 19 to 21?', null); } finally { globalThis.fetch = real; setProviderKey(null); }
  assert(systems.length > 0, 'the brain was called');
  const s = systems[0], at = (m: string) => { const i = s.indexOf(m); assert(i >= 0, m); return i; };
  const order = [at('REFERENCE REPLIES ('), at('\nFACTS\n'), at('OUTPUT: JSON only'), at('GUEST FIRST NAME:'), at('\nLANDMARKS\n'), at('\nAVAILABILITY\n')];
  assertEquals(order, [...order].sort((a, b) => a - b), 'voice exemplars, FACTS, contract, then the per-turn blocks');
  assert(s.indexOf('GUEST FIRST NAME:') === s.lastIndexOf('GUEST FIRST NAME:'), 'the name block appears once (the contract only mentions it in words)');
});
