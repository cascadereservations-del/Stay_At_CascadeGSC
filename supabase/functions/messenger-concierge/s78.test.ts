// deno test --no-check -A messenger-concierge/s78.test.ts
// s78 (TASKS #6 + #8): Angel's real turns (s77-angel-review.md) and REVIEW-messenger-2026-10-08 G8-G11, replayed through the
// real handle() with the probe effects, an in-memory calendar and a stubbed model (no network), plus the pure pieces.
// Calendar: another guest checks out Oct 19 (turnover), Angel holds Oct 19 to 22; now is Oct 18 (inside five days).
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { answer, guestLang, payTiming, type Flow } from './booking.ts';
import * as P from './persona.ts';
import { dropRepeats, lintReply, setTurnoverCheckin, turnoverCheckinLine } from './voice.ts';
import { setProviderKey } from '../_shared/cascade-core/providers.ts';

(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { handle, haggleRest, probeEffects } = await import('./index.ts');

const now = new Date('2026-10-18T01:55:00Z');
const ago = (m: number) => new Date(now.getTime() - m * 60_000).toISOString();
const CAL = [
  { checkin_date: '2026-10-16', checkout_date: '2026-10-19', status: 'confirmed', guest_name: 'Shaneen', raw_summary: 'Airbnb', source: 'airbnb' },
  { checkin_date: '2026-10-25', checkout_date: '2026-10-27', status: 'confirmed', guest_name: null, raw_summary: 'Blocked', source: 'airbnb' },
];
type Call = { fx: string; text?: string; detail?: { risk?: string; note?: string } };
// deno-lint-ignore no-explicit-any
function fakeDb(row: any) {
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
  return { db: { from: (t: string) => q(t), rpc: (fn: string) => Promise.resolve({ data: fn === 'stay_continues_v1' ? false : [], error: null }) }, writes };
}
function stub(answerText: string) {
  const seen: string[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = ((url: string | URL | Request, init?: RequestInit) => {
    if (!String(url).includes('openrouter.ai')) return Promise.resolve(new Response('{}', { status: 500 }));
    seen.push(String(JSON.parse(String(init?.body ?? '{}')).messages?.at(-1)?.content ?? ''));
    return Promise.resolve(new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify({ answer: answerText, ask: null, uncertain: false }) }, finish_reason: 'stop' }] }), { status: 200 }));
  }) as typeof fetch;
  setProviderKey('test');
  return { seen, restore: () => { globalThis.fetch = real; setProviderKey(null); } };
}
/** Angel's booking: Oct 19 to 22, inside five days, so the full PHP 5,073 is the payment (the card says so). `age` minutes since
 *  the flow last moved: over 24 h the flow is no longer active and only lastRef holds it (Angel's Oct 8 turns). */
const held = (step: Flow['step'] = 'await_receipt', ageMin = 30, extra: Partial<Flow> = {}): Flow => ({ step, checkin: '2026-10-19', checkout: '2026-10-22', pax: 2, lang: 'tl', name: 'Angeleen Luz Villanueva',
  phone: '09170000000', email: 'test.guest@example.com', ref: 'DIR-ANGEL', booking_id: 'b-angel', deposit: 5073, total: 5073, hold: false, receipt_token: 't', receipt_expires_at: new Date(now.getTime() + 3_600_000).toISOString(),
  started_at: ago(ageMin + 60), updated_at: ago(ageMin), ...extra });
async function turn(text: string, o: { flow?: Flow | null; history?: Array<[string, string]>; name?: string | null; human?: string | null } = {}) {
  const history = o.history ?? [['I would like to book Oct 19-22', 'Oct 19 to 22 is available...'], ['2 adults', 'Shall we hold those dates?']];
  const row = { psid: 'probe:s78', guest_name: o.name === undefined ? 'Angel' : o.name, human_until: o.human ?? null, bot_turns: history.length, last_risk: null, last_mid: null, booking_flow: o.flow ?? null,
    history: history.flatMap(([g, b], i) => [{ role: 'guest', text: g, at: ago(40 - 2 * i) }, { role: 'bot', text: b, at: ago(39 - 2 * i) }]) };
  const { db, writes } = fakeDb(row);
  const calls: Call[] = [];
  // deno-lint-ignore no-explicit-any
  await handle(db as any, { sender: { id: 'probe:s78' }, recipient: { id: 'page' }, message: { mid: 'm-' + Math.random(), text } }, 'auto', probeEffects(calls as any, o.name === undefined ? 'Angel' : o.name, now), now);
  const reply = calls.filter((c) => c.fx === 'send').map((c) => c.text).join('\n\n');
  if (Deno.env.get('S78_SHOW')) console.log(`\n>>> ${text}\n${reply}\n<<<`);
  const saved = writes.filter((w) => w.table === 'concierge_threads').at(-1)?.v;
  return { reply, calls, saved };
}

// ---- 1. after the booking: facts only, the card's terms, never "deposit on arrival" -------------------------------------------
// Example: Angel turn 19 "We will pay po the deposit pag nasa area na po" was accepted by the model; turn 13 "We will send the
// deposit tomorrow po" got the receipt chase. Code says the card's terms (persona.ts payTermsLine), no model call.
Deno.test('s78 #1: a booked guest proposing to pay on arrival or later gets the stay card terms from code, never an agreement', async () => {
  for (const [say, kind] of [['We will pay po the deposit pag nasa area na po', 'arrival'], ['We will send the deposit tomorrow po', 'later'], ['pwede po ba bayad ng balance upon check-in?', 'arrival']] as const) {
    assertEquals(payTiming(say), kind, say);
    for (const flow of [held(), held('await_receipt', 26 * 60), held('receipt_sent', 26 * 60)]) {
      const m = stub('Sige po, pwede po ninyong bayaran ang deposit pagdating ninyo.');
      try {
        const r = await turn(say, { flow });
        assertEquals(m.seen.length, 0, `code answers: ${say}`);
        assert(/before you arrive|a day before check-in/.test(r.reply) && /1,000/.test(r.reply), r.reply);
        assert(!/pagdating ninyo|on arrival is fine|upon arrival/i.test(r.reply), r.reply);
        assert(!/exact total|dates na kayo|preferred dates/i.test(r.reply), r.reply);
        assertEquals(r.calls.filter((c) => c.fx === 'handoff').map((c) => c.detail?.risk), kind === 'arrival' ? ['payment'] : [], say);
        assertEquals(lintReply(r.reply), [], r.reply);
      } finally { m.restore(); }
    }
  }
  // the fee case names the balance; the card's words
  const fee = P.payTermsLine('Angel', 'en', { total: '₱5,073', balance: '₱2,537', paid: false });
  assert(fee.includes('remaining ₱2,537 balance and the ₱1,000 refundable security deposit are due at least a day before check-in'), fee);
  // not a timing: a paid claim, a question about the deposit, a check-in time ask
  for (const t of ['Sent po DP', 'Is the deposit refundable?', 'anong oras po pwde makacheckin??', 'paid na po']) assertEquals(payTiming(t), null, t);
});

// Example: Angel turn 17 "may free drinking water na po sa room?" (Oct 8, the flow past 24 h) closed on "Iche-check namin agad ang
// exact total ... once may dates na kayo" (warmClause after a cold rewrite).
Deno.test('s78 #1: a booked guest\'s question is answered from facts with no booking-flow line, also after the flow\'s 24 h', async () => {
  const cold = 'Opo, may water dispenser po sa unit na may complimentary drinking water para sa buong stay ninyo, kasama ang hot at cold na option, at may mga baso rin po sa kitchen para magamit ninyo anytime.';
  for (const flow of [held(), held('await_receipt', 26 * 60), held('receipt_sent', 26 * 60), held('confirmed', 26 * 60)]) {
    const m = stub(cold);
    try {
      const r = await turn('Hi good morning po may free drinking water na po sa room?', { flow });
      assert(m.seen.length > 0, 'the model answers the fact');
      assert(m.seen[0].includes('The stay card\'s payment terms are the ONLY terms') && m.seen[0].includes('Never agree to the balance or the deposit being paid on arrival'), m.seen[0].slice(0, 300));
      assert(/water dispenser/.test(r.reply), r.reply);
      assert(!/exact total|once may dates|preferred dates|Which dates|kailan po|hold those dates|tinyurl/i.test(r.reply), `${flow.step}: ${r.reply}`);
    } finally { m.restore(); }
  }
});

// ---- 2. early check-in on a turnover day: one fixed line, never 12 NN / 1 PM, nothing twice --------------------------------------
// Example: Angel turn 14 "If its possible we would like to checkin early po" printed the 12:00 NN / 1:00 PM paragraph twice.
Deno.test('s78 #2: an early check-in ask on a turnover day gets the one fixed line, once, in the guest\'s register', async () => {
  const drafts = [
    // the live draft shape: the noon offer, then the model's own 2:00 PM sentence, then the same paragraph again
    'Masaya po naming ia-accommodate ang mas maagang check-in ng 12:00 NN o 1:00 PM kung fully prepared at ready na ang unit by then. Gagawin namin ang lahat para maihanda ito bago ang standard 2:00 PM check-in.\n\nMasaya po naming ia-accommodate ang mas maagang check-in ng 12:00 NN o 1:00 PM kung fully prepared at ready na ang unit by then. Gagawin namin ang lahat para maihanda ito bago ang standard 2:00 PM check-in.',
    // no time named at all: the line still goes in
    'Sige po, gagawin namin ang aming makakaya para maging komportable ang pagdating ninyo.',
  ];
  for (const d of drafts) {
    const m = stub(d);
    try {
      const r = await turn('If its possible we would like to checkin early po 🙏', { flow: held() });
      // this thread wrote English with a courtesy "po", so the English line (a Taglish thread gets the Taglish one, s78 #4)
      const n = ['en', 'tl'].map((l) => r.reply.split(turnoverCheckinLine('Oct 19', l as 'en' | 'tl')).length - 1);
      assertEquals(n[0] + n[1], 1, r.reply);
      assert(!/12:00|1:00 PM|12 noon|tanghali/i.test(r.reply), r.reply);
      assertEquals(r.reply, dropRepeats(r.reply));
    } finally { m.restore(); }
  }
  // the stored history holds no date (older turns rolled off): the booking's dates still count - no "share your dates" reply
  const m2 = stub('Sige po, gagawin namin ang aming makakaya.');
  try {
    const r = await turn('we would like to checkin early po', { flow: held(), history: [['Yes pls', 'Thank you. May we have your full name...']] });
    assert(m2.seen.length > 0 && !/dates ninyo|your dates|share/i.test(r.reply) && /2:00 PM/.test(r.reply), r.reply);
  } finally { m2.restore(); }
  // pure: the line replaces every check-in-time sentence, and an untouched reply gets it as its first paragraph
  const en = turnoverCheckinLine('Oct 19', 'en');
  assertEquals(setTurnoverCheckin('We will do our best to have it ready before the standard 2:00 PM check-in. Wi-Fi is fast.', en), `${en} Wi-Fi is fast.`);
  assertEquals(setTurnoverCheckin('Wi-Fi is fast.', en), `${en}\n\nWi-Fi is fast.`);
  assertEquals(dropRepeats('A long sentence that is said twice in this message.\n\nA long sentence that is said twice in this message.\n\nOk.'), 'A long sentence that is said twice in this message.\n\nOk.');
  assertEquals(dropRepeats('Hi Ben, thank you for reaching out to Cascade Hideaway.\n\nOct 19 is open.'), 'Hi Ben, thank you for reaching out to Cascade Hideaway.\n\nOct 19 is open.');
});

// ---- 3. "di na po available ang <day>?" at the party ask is a date question --------------------------------------------------
// Example: Angel turn 4 ("Hi po, di na po available ang 22??") got the over-capacity line for a party of 22.
Deno.test('s78 #3 (G11): an availability question at the party ask passes to the model; the party ask follows', async () => {
  const pax: Flow = { step: 'pax', checkin: '2026-10-19', checkout: '2026-10-22', lang: 'tl', started_at: ago(10), updated_at: ago(5) };
  assertEquals(answer(pax, 'Hi po, di na po available ang 22??', now).action, 'passthrough');
  assertEquals(answer(pax, '2 po kami, available pa?', now).flow.pax, 2); // a guest word: still the count
  assertEquals(answer(pax, '5 adults', now).reply, P.overCapacityLine(5, 'tl'));
  const m = stub('Available pa po ang Oct 22, Angel.');
  try {
    const r = await turn('Hi po, di na po available ang 22??', { flow: pax });
    assert(m.seen.length > 0 && /Oct 22/.test(r.reply) && /Ilan po kayo/.test(r.reply), r.reply);
    assert(!/mas malaking place|larger place|For 22/.test(r.reply), r.reply);
  } finally { m.restore(); }
});

// ---- 4. closers, names and register ------------------------------------------------------------------------------------------
// Example: G9 Hazel "welcome te, ya" re-sent the PHP 3,382 offer; G8 "Hi Ma., thank you"; G10 Angel turn 20 got English.
Deno.test('s78 #4 (G9): "welcome te, ya" after our thanks is a closer - no offer, no model call', async () => {
  for (const say of ['welcome te, ya', 'Welcome te', "you're welcome po", 'welcome ma\'am, ya']) {
    const m = stub('For Oct 19 to 21, the total is PHP 3,382. Shall we hold those dates for you?');
    try {
      const r = await turn(say, { history: [['Hm po Oct 19 to 21?', 'PHP 3,382 for the stay. Shall we hold those dates for you?'], ['Salamat po', 'Walang anuman po, Angel. Nandito lang kami anytime.']] });
      assertEquals(m.seen.length, 0, say);
      assert(!/3,382|hold|dates/i.test(r.reply) && r.reply.length < 120, `${say}: ${r.reply}`);
      assertEquals(r.saved.booking_flow, null, say);
    } finally { m.restore(); }
  }
});
Deno.test('s78 #4 (G8): "Ma." is never the name Cassy uses', async () => {
  assertEquals(P.addressName('Ma.'), null);
  assertEquals(P.addressName('Ma'), null);
  assertEquals(P.addressName('Ma. Cleofe'), 'Cleofe');
  assertEquals(P.addressName('Maria'), 'Maria');
  assertEquals(P.addressName('Mary Ann'), 'Mary Ann');
  assertEquals(P.addressName('Jo'), 'Jo');
  assertEquals(P.addressName(null), null);
  const m = stub('Yes, there is free parking inside the gated property.');
  try {
    const r = await turn('Hello, is there parking?', { name: 'Ma.', history: [] });
    assert(!/\bMa\b\.?,|Hi Ma\b|, Ma\./.test(r.reply), r.reply);
    assert(r.reply.startsWith('Hello, thank you for reaching out'), r.reply);
  } finally { m.restore(); }
});
Deno.test('s78 #4 (G10): a Taglish thread keeps Taglish on an English-with-po turn and on text-speak Taglish', async () => {
  for (const t of ['2 nights lng po ang pwde mabook :(', 'We will pay po the deposit pag nasa area na po', 'pwde po ba dito mag-park']) assertEquals(guestLang(t), 'taglish', t);
  const m = stub('Check-in po ay from 2:00 PM, at iche-check namin kung ready na ang unit nang mas maaga.');
  try {
    await turn("We're here na po, waiting for confirmation", { flow: held('receipt_sent', 26 * 60), history: [['Hi po, anong oras po pwde makacheckin??', 'Check-in po ay from 2:00 PM.']] });
    assert(m.seen[0].includes('natural conversational Taglish'), m.seen[0].slice(0, 200));
  } finally { m.restore(); }
});

// ---- 5. TASKS #8: a pure haggle without "?" that also asks something --------------------------------------------------------
Deno.test('s78 #5 (TASKS #8): "discount please, parking available" answers the discount line AND the parking', async () => {
  for (const t of ['discount please, parking available', 'medyo mahal po, may parking ba', 'can you do 1,500 a night and is there wifi']) assert(haggleRest(t), t);
  for (const t of ['discount please', 'medyo mahal po', 'can you do 1,500 a night', 'may discount po ba?', 'medyo mahal po, pwede pa ba bumaba?']) assert(!haggleRest(t), t);
  const m = stub('Yes, there is free parking inside the gated property, right by the unit.');
  try {
    const r = await turn('discount please, parking available', { history: [['Hi, how much per night?', 'Our direct rate starts at PHP 1,780 per night.']] });
    assert(m.seen.length > 0, 'the model answers the parking');
    assert(r.reply.startsWith(P.haggleLine('en')) && /parking/i.test(r.reply) && /Our host also looks/.test(r.reply), r.reply);
    assertEquals(r.calls.filter((c) => c.fx === 'handoff').map((c) => c.detail?.risk), ['policy_exception']);
  } finally { m.restore(); }
  // a pure haggle stays code-only (D-311.6)
  const p = stub('unused');
  try {
    const r = await turn('discount please', { history: [['Hi, how much per night?', 'Our direct rate starts at PHP 1,780 per night.']] });
    assertEquals(p.seen.length, 0);
    assert(r.reply.startsWith(P.haggleLine('en')), r.reply);
  } finally { p.restore(); }
});

// ---- D-317 still holds: a host reply silences Cassy, whatever the new paths would say -----------------------------------------
Deno.test('s78: D-317 - under a host hold none of the new paths sends anything to the guest', async () => {
  const until = new Date(now.getTime() + 29 * 86_400_000).toISOString();
  for (const say of ['We will pay po the deposit pag nasa area na po', 'welcome te, ya', 'discount please, parking available', 'If its possible we would like to checkin early po']) {
    const m = stub('should not be used');
    try {
      const r = await turn(say, { flow: held(), human: until });
      assertEquals(r.calls.filter((c) => c.fx === 'send').length, 0, say);
      assertEquals(m.seen.length, 0, say);
      assert(r.calls.some((c) => c.fx === 'ops'), `the host hears it: ${say}`);
    } finally { m.restore(); }
  }
});
