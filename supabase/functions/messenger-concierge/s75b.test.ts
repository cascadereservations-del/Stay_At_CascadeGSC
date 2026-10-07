// deno test --no-check -A messenger-concierge/s75b.test.ts
// Incident 2026-10-07 01:55Z (Angel): "Avajlable po oct 8-11?" after a rate answer started no booking flow (the typo missed
// AVAIL_RE), so the model said "available" alone - no party ask, no hold - and "as soon as you arrive" on a day another guest
// checks out. Replayed through the real handle() with a calendar that answers the code's filters (no network).
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { availStart, bookingStart, AVAIL_WORD_RE } from './booking.ts';
import * as P from './persona.ts';
import { addTurnoverNotice, lintReply } from './voice.ts';
import { setProviderKey } from '../_shared/cascade-core/providers.ts';
import { SITE_URL } from '../_shared/cascade-core/facts.ts';
import { goldenCases } from './golden.ts';
import { failures, scoreReply } from './golden-score.ts';

(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { handle, probeEffects } = await import('./index.ts');

const now = new Date('2026-10-07T01:55:00Z');
const ago = (m: number) => new Date(now.getTime() - m * 60_000).toISOString();
// The live calendar around the incident: Ermann G (Airbnb) Oct 6 -> Oct 8; Oct 11-12 blocked.
const CAL = [
  { checkin_date: '2026-10-06', checkout_date: '2026-10-08', status: 'confirmed', guest_name: 'Ermann G', raw_summary: 'Airbnb', source: 'airbnb' },
  { checkin_date: '2026-10-11', checkout_date: '2026-10-13', status: 'confirmed', guest_name: null, raw_summary: 'Blocked', source: 'airbnb' },
];
type Call = { fx: string; text?: string };
// deno-lint-ignore no-explicit-any
function fakeDb(row: any, chained = false) {
  // deno-lint-ignore no-explicit-any
  const writes: Array<{ table: string; v: any }> = [];
  // deno-lint-ignore no-explicit-any
  const q = (table: string, f: Array<(r: any) => boolean> = []): any => new Proxy({}, { get(_t, k) {
    if (k === 'then') return (res: (x: unknown) => void) => res({ data: table === 'calendar_events' ? CAL.filter((r) => f.every((p) => p(r))) : [], error: null });
    if (k === 'maybeSingle' || k === 'single') return () => Promise.resolve({ data: table === 'concierge_threads' ? row : null, error: null });
    // deno-lint-ignore no-explicit-any
    if (k === 'upsert' || k === 'insert' || k === 'update') return (v: any) => { writes.push({ table, v }); return q(table, f); };
    // deno-lint-ignore no-explicit-any
    const cmp: Record<string, (a: any, b: any) => boolean> = { eq: (a, b) => a === b, neq: (a, b) => a !== b, lt: (a, b) => a < b, lte: (a, b) => a <= b, gt: (a, b) => a > b, gte: (a, b) => a >= b };
    if (typeof k === 'string' && cmp[k]) return (col: string, v: unknown) => q(table, [...f, (r) => cmp[k as string](r[col], v)]);
    return () => q(table, f);
  } });
  return { db: { from: (t: string) => q(t), rpc: (fn: string) => Promise.resolve({ data: fn === 'stay_continues_v1' ? chained : [], error: null }) }, writes };
}
function stub(answer: string) {
  const seen: string[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = ((url: string | URL | Request, init?: RequestInit) => {
    if (!String(url).includes('openrouter.ai')) return Promise.resolve(new Response('{}', { status: 500 }));
    seen.push(String(JSON.parse(String(init?.body ?? '{}')).messages?.at(-1)?.content ?? ''));
    return Promise.resolve(new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify({ answer, ask: null, uncertain: false }) }, finish_reason: 'stop' }] }), { status: 200 }));
  }) as typeof fetch;
  setProviderKey('test');
  return { seen, restore: () => { globalThis.fetch = real; setProviderKey(null); } };
}
const RATE = "Hi Angel, thank you for reaching out to Cascade Hideaway.\n\nOur direct rate starts at PHP 1,780 per night, and the nightly rate goes lower the longer you stay.\n\nWe'd be delighted to have you with us. Which dates are you looking at? Share your check-in and check-out here and we'll check the calendar for you right away.\n\nCassy, Cascade Concierge";
async function turn(text: string, history: Array<[string, string]> = [['Hi po hm per night', RATE]], chained = false) {
  const row = { psid: 'probe:s75b', guest_name: 'Angel', human_until: null, bot_turns: history.length, last_risk: null, last_mid: null, booking_flow: null,
    history: history.flatMap(([g, b], i) => [{ role: 'guest', text: g, at: ago(10 - i) }, { role: 'bot', text: b, at: ago(10 - i) }]) };
  const { db, writes } = fakeDb(row, chained);
  const calls: Call[] = [];
  // deno-lint-ignore no-explicit-any
  await handle(db as any, { sender: { id: 'probe:s75b' }, recipient: { id: 'page' }, message: { mid: 'm-' + Math.random(), text } }, 'auto', probeEffects(calls as any, 'Angel', now), now);
  const reply = calls.filter((c) => c.fx === 'send').map((c) => c.text).join('\n\n');
  if (Deno.env.get('S75_SHOW')) console.log(`\n>>> ${text}\n${reply}\n<<<`); // S75_SHOW=1: read the composed replies
  const flow = writes.filter((w) => w.table === 'concierge_threads').at(-1)?.v.booking_flow ?? null;
  return { reply, flow };
}
const NOTICE_EN = P.turnoverNotice('Oct 8', 'en');

// ---- 1. availability asks survive typos; date mentions that are not asks start nothing ------------------------------------
// Example: booking.ts AVAIL_WORD (one letter-shape rule, used by AVAIL_RE, rolledPastStay and index.ts's past-stay reply).
Deno.test('incident 2026-10-07: a misspelt availability ask starts the flow; dates told, confirmed or asked about otherwise do not', () => {
  for (const t of ['Avajlable po oct 8-11?', 'available oct 8-11?', 'availble po oct 8-11', 'avalable po ba oct 8 to 11?', 'avail oct 8-11?', 'avl po oct 8-11?', 'availability oct 8-11?', 'bakanti pa ba oct 8-11?', 'Naa pay bakante oct 8-11?']) {
    assert(availStart(t, now), t);
    assertEquals(bookingStart(t, [], RATE, now), t, t);
  }
  for (const t of ['we stayed Sep 5 to 7 last time', 'checkout is Oct 8 right?', 'what time is check-in on Oct 8?', 'Oct 8 is my birthday po', 'is it avoidable to pay on Oct 8?']) {
    assertEquals(bookingStart(t, [], RATE, now), null, t);
  }
});

// ---- 2. the incident through handle(): the flow starts, the turnover notice rides on Oct 8 ----------------------------------
// Example: persona.ts turnoverNotice + voice.ts addTurnoverNotice, placed once on the reply in index.ts (openStay).
Deno.test('incident 2026-10-07: "Avajlable po oct 8-11?" after the rate answer starts the flow (party ask) and says the Oct 8 turnover', async () => {
  const m = stub('should not be used: the flow answers availability');
  try {
    for (const say of ['Avajlable po oct 8-11?', 'Available po oct 8-11?']) {
      const r = await turn(say);
      assertEquals(m.seen.length, 0, 'code answers, not the model');
      assertEquals([r.flow?.step, r.flow?.checkin, r.flow?.checkout], ['pax', '2026-10-08', '2026-10-11'], say);
      assert(/Oct 8 to 11 is available/.test(r.reply) && /How many/.test(r.reply), r.reply);
      assertEquals(r.reply.split(NOTICE_EN).length, 2, r.reply);
      assert(!/as soon as you arrive|unfortunately/i.test(r.reply), r.reply);
    }
    // the golden case (GOLDEN_TURNOVER="Oct 8"), turn 2, scored the way golden-run.ts scores it
    const g = goldenCases(now, null, 'Oct 8').find((c) => c.id === 'avail-typo-turnover-tl')!, t = g.turns[1];
    assertEquals(t.say, 'Avajlable po Oct 8 to 11?');
    const r = await turn(t.say);
    assertEquals(failures(scoreReply({ guest: t.say, reply: r.reply, prevReply: RATE, kind: t.kind, lang: t.lang, firstTurn: false, siteUrl: SITE_URL, name: 'Angel', guestUsedPo: true, must: t.must, mustNot: t.mustNot })), []);
  } finally { m.restore(); }
});
Deno.test('a stay that does not start on a check-out day, or a chained junction day (D-290), gets no turnover notice', async () => {
  const m = stub('unused');
  try {
    const r = await turn('Avajlable po oct 20-22?');
    assertEquals(r.flow?.step, 'pax');
    assert(/Oct 20 to 22 is available/.test(r.reply) && !/checks out that morning/.test(r.reply), r.reply);
    // D-290: the Oct 8 check-out continues into a chained stay (stay_continues_v1) - no turnover, no notice
    const c = await turn('Avajlable po oct 8-11?', undefined, true);
    assert(/Oct 8 to 11 is available/.test(c.reply) && !/checks out that morning/.test(c.reply), c.reply);
  } finally { m.restore(); }
});
Deno.test('the three date mentions that are not availability asks start no flow through handle()', async () => {
  const m = stub("Check-in is from 2:00 PM and check-out is at 12:00 noon, so you can plan your day with ease.");
  try {
    for (const say of ['we stayed Sep 5 to 7 last time', 'checkout is Oct 8 right?', 'what time is check-in on Oct 8?']) {
      const r = await turn(say);
      assertEquals(r.flow, null, `${say} -> ${r.reply}`);
    }
  } finally { m.restore(); }
});

// ---- 3. the model path (K18 agrees the stay is open): the notice, and "as soon as you arrive" goes ----------------------------
Deno.test('a model reply calling Oct 8 to 11 open on a turnover day carries the notice, without "as soon as you arrive"', async () => {
  const m = stub("Yes, Angel, Oct 8 to 11 is available for your stay. We'll have the queen bed and pull-out prepared so you can settle in comfortably as soon as you arrive.");
  try {
    const r = await turn('Pwede po ba kami sa Oct 8 to 11?');
    assertEquals(m.seen.length > 0, true);
    assert(r.reply.includes(NOTICE_EN) || r.reply.includes(P.turnoverNotice('Oct 8', 'tl')), r.reply);
    assert(!/as soon as you arrive/.test(r.reply) && /settle in comfortably/.test(r.reply), r.reply);
  } finally { m.restore(); }
  // pure: placed on the open paragraph, never twice, and not beside Lloyd's D-311.2 line (2:00 PM already said)
  const once = addTurnoverNotice('Hi Angel.\n\nOct 8 to 11 is available, and we\'d be delighted to welcome you.\n\nHow many of you?', 'Oct 8', NOTICE_EN);
  assertEquals(once, `Hi Angel.\n\nOct 8 to 11 is available, and we'd be delighted to welcome you. ${NOTICE_EN}\n\nHow many of you?`);
  assertEquals(addTurnoverNotice(once, 'Oct 8', NOTICE_EN), once);
  assertEquals(addTurnoverNotice('Oct 8 is available. Check-in is at 2:00 PM.', 'Oct 8', NOTICE_EN), 'Oct 8 is available. Check-in is at 2:00 PM.');
  assertEquals(addTurnoverNotice('Oct 18 is available.', 'Oct 8', NOTICE_EN), 'Oct 18 is available.');
  for (const l of ['en', 'tl'] as const) assertEquals(lintReply(P.turnoverNotice('Oct 8', l)), []);
});

// Fable audit 5d73694: the typo rule matches real misspellings only, never words that merely start with "av".
Deno.test('s75b AVAIL_WORD_RE: typos yes (avable counts as a typo), avalanche/avlon no', () => {
  for (const w of ['available', 'availble', 'avalable', 'avajlable', 'availabe', 'avail', 'avl', 'availability', 'bakante']) assert(AVAIL_WORD_RE.test(w), w);
  for (const w of ['avalanche', 'avlon', 'avoidable']) assert(!AVAIL_WORD_RE.test(w), w);
});
