// deno test --no-check -A messenger-concierge/s75.test.ts
// Session 75, D-311 (Lloyd's rulings on GOLDEN-RUN-2026-10-07-wave3-x1): each failing golden reply is replayed through the
// real handle() (probe effects, an in-memory db, a stubbed model and Jev - no network) or through the pure piece, and is
// scored with the golden case's own expectations. One test per ruling; the example for each is named beside it.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { start, type Flow } from './booking.ts';
import * as P from './persona.ts';
import { dedupeAvailability, dropPassingRange, earlyFeeFor, fixEarlyFee, kusang, lintReply, nameOnce, noPo, offersEarlyCheckin, paragraphs, setTurnoverCheckin, turnoverCheckinLine } from './voice.ts';
import { goldenCases, range, type GoldenTurn } from './golden.ts';
import { failures, heldFrom, scoreReply } from './golden-score.ts';
import { SITE_URL } from '../_shared/cascade-core/facts.ts';
import { setProviderKey } from '../_shared/cascade-core/providers.ts';

(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { handle, probeEffects, dropForward } = await import('./index.ts');

const now = new Date('2026-10-06T06:00:00Z');
const ago = (m: number) => new Date(now.getTime() - m * 60_000).toISOString();
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
/** The model's JSON for every draft; `jev` answers the router (null = no router, as when its key is missing). */
function stub(answer: string, ask: string | null = null, jev: { intent: string; host: number } | null = null) {
  const seen: string[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = ((url: string | URL | Request, init?: RequestInit) => {
    if (String(url).includes('/decisions')) {
      return Promise.resolve(jev ? new Response(JSON.stringify({ answers: { intent: { choice: jev.intent, confidence: 0.95 }, needs_host: { noul: jev.host }, lang: { choice: 'en', confidence: 0.5 } } }), { status: 200 }) : new Response('{}', { status: 500 }));
    }
    if (!String(url).includes('openrouter.ai')) return Promise.resolve(new Response('{}', { status: 500 }));
    seen.push(String(JSON.parse(String(init?.body ?? '{}')).messages?.at(-1)?.content ?? ''));
    return Promise.resolve(new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify({ answer, ask, uncertain: false }) }, finish_reason: 'stop' }] }), { status: 200 }));
  }) as typeof fetch;
  setProviderKey('test');
  if (jev) Deno.env.set('CASCADE_OPENROUTER_BOT_KEY', 'test');
  return { seen, restore: () => { globalThis.fetch = real; setProviderKey(null); Deno.env.delete('CASCADE_OPENROUTER_BOT_KEY'); } };
}
async function turn(text: string, history: Array<[string, string]> = [], bf: Flow | null = null) {
  const row = { psid: 'probe:s75', guest_name: 'Ben', human_until: null, bot_turns: history.length, last_risk: null, last_mid: null, booking_flow: bf,
    history: history.flatMap(([g, b], i) => [{ role: 'guest', text: g, at: ago(10 - i) }, { role: 'bot', text: b, at: ago(10 - i) }]) };
  const { db } = fakeDb(row);
  const calls: Call[] = [];
  await handle(db as any, { sender: { id: 'probe:s75' }, recipient: { id: 'page' }, message: { mid: 'm-' + Math.random(), text } }, 'auto', probeEffects(calls as any, 'Ben', now), now);
  const reply = calls.filter((c) => c.fx === 'send').map((c) => c.text).join('\n\n');
  if (Deno.env.get('S75_SHOW')) console.log(`\n>>> ${text}\n${reply}\n<<<`); // S75_SHOW=1: read the composed replies
  return { reply, calls };
}
const CASES = goldenCases(now, null, 'Oct 19');
/** The golden case's turn `i`, scored the way golden-run.ts scores it. */
function score(id: string, i: number, reply: string, prevReply: string | null = null): string[] {
  const c = CASES.find((x) => x.id === id);
  assert(c, `no golden case ${id}`);
  const t: GoldenTurn = c.turns[i];
  return failures(scoreReply({ guest: t.say, reply, prevReply, kind: t.kind, lang: t.lang, firstTurn: i === 0, siteUrl: SITE_URL, name: 'Ben',
    held: heldFrom(c.turns.slice(0, i + 1).map((x) => x.say), 'Ben'), noInvite: t.noInvite, guestUsedPo: /\bpo\b/i.test(t.say), must: t.must, mustNot: t.mustNot }));
}

// ---- 1 + 10. promo questions: the live promotion and the direct price, first paragraph, every language; never forwarded --------
// Example: persona.ts promoLine / promoFirst (code rule) + the promo hint in index.ts.
Deno.test('D-311.1/.7: a promo question names the live promotion and the direct price first, is never forwarded (even when Jev reads negotiation), and Taglish says "kusa"', async () => {
  const en = stub("We completely understand wanting to get the best value for your stay.\n\nOur direct booking rate automatically applies our best standard pricing for your dates, with all cleaning fees already included.", null, { intent: 'negotiation', host: 0.9 });
  try {
    const r = await turn('Do you have any promo this month or next?');
    assertEquals(r.calls.filter((c) => c.fx === 'handoff').length, 0, 'a plain promo question is not forwarded');
    assert(!r.reply.includes('Our host also looks'), r.reply);
    const p1 = paragraphs(r.reply)[1];
    assert(p1.includes('Anniversary Promotion') && p1.includes('1,543') && /lower than on Airbnb/.test(p1), r.reply);
    assertEquals(score('promo-ask-en', 0, r.reply), []);
  } finally { en.restore(); }
  const tl = stub('May ongoing Anniversary Promotion po kami ngayong October 11 to 17, kung saan PHP 1,543 per night na lang ang unit.\n\nPara naman po sa ibang petsa, automated na ring bumababa ang nightly rate kapag mas mahaba ang stay.', null, { intent: 'negotiation', host: 0.9 });
  try {
    const r = await turn('May promo po ba kayo ngayong October?');
    assertEquals(r.calls.filter((c) => c.fx === 'handoff').length, 0);
    assert(!/automated/i.test(r.reply) && r.reply.includes('kusa na ring bumababa'), r.reply);
    assert(r.reply.includes('kaysa sa Airbnb'), r.reply);
    assertEquals(score('promo-ask-tl', 0, r.reply), []);
  } finally { tl.restore(); }
  // the pure pieces: a first paragraph without the rate gets code's line; one with it gets the direct sentence only
  const promo: P.PromoFacts = { name: 'Anniversary Promotion', when: 'Oct 11 to 17', rate: 'PHP 1,543', base: 'PHP 1,780' };
  assert(P.promoFirst('We understand.', [promo], 'en').startsWith(P.promoLine([promo], 'en')));
  assertEquals(P.promoFirst('Our Anniversary Promotion is PHP 1,543 a night.', [promo], 'en'), `Our Anniversary Promotion is PHP 1,543 a night. ${P.directBetter('en')}`);
  assertEquals(kusang('automated na ring bumababa, automatic ang discount'), 'kusa na ring bumababa, kusa ang discount');
  // audit D4: "kusang" only before a verb; a capital stays a capital
  assertEquals(kusang('The rate applies automatically. Automatic po ang discount, at automatic bumababa ang rate.'), 'The rate applies kusa. Kusa po ang discount, at kusang bumababa ang rate.');
  assertEquals(kusang('automatically nag-a-apply ang rate'), 'kusang nag-a-apply ang rate');
});

// ---- 2. turnover-day early check-in: never a promised time; Lloyd's words -------------------------------------------------
// Example: voice.ts turnoverCheckinLine (code rule) + FACTS / the AVAILABILITY block / the VOICE turnover reference reply.
Deno.test('D-311.2: on a turnover day a noon promise becomes Lloyd\'s line - 12 NN or 1 PM only if ready, no fee, 2:00 PM named', () => {
  assertEquals(turnoverCheckinLine('Oct 19', 'en'), "We'll be happy to accommodate an earlier check-in at 12:00 NN or 1:00 PM if the unit is already fully prepared and ready by then. We'll do our best to have everything ready ahead of the standard 2:00 PM check-in and will keep you posted once we can confirm the earliest time.");
  const live = 'Hi Ben! Salamat sa pag-message sa Cascade Hideaway.\n\nYes, available po ang Oct 19. Open din po ang 12:00 noon early check-in at no extra charge dahil wala pong guest na mag-che-check out nung araw na iyon.\n\nCassy, Cascade Concierge';
  assert(offersEarlyCheckin(live));
  const fixed = setTurnoverCheckin(live, turnoverCheckinLine('Oct 19', 'tl'));
  assert(fixed.includes('12:00 NN o 1:00 PM') && fixed.includes('standard 2:00 PM') && !/no extra charge|complimentary/i.test(fixed), fixed);
  assertEquals(score('first-noon-checkin-on-turnover-day-tl', 0, fixed), []);
  // the fee rule is unchanged: 12 NN and 1 PM carry no fee, a 10 AM arrival is PHP 200
  assertEquals(earlyFeeFor('Pwede po ba check in 12 noon?'), null);
  assertEquals(fixEarlyFee(fixed, 'Pwede po ba check in 12 noon?'), fixed);
  assertEquals(earlyFeeFor('Can we check in at 10am?'), 200);
  for (const l of ['en', 'tl'] as const) assertEquals(lintReply(turnoverCheckinLine('Oct 19', l)), []);
});

// ---- 3. first-contact "How do I book?" answered with dates and guests is FINE (the checker was wrong) ------------------------
// Example: golden-score.ts R1 (code rule) + golden.ts first-howtobook-en.
Deno.test('D-311.3: the first "How do I book?" answered by asking for dates and guests passes R1', () => {
  const live = "Hi Ben, thank you for reaching out to Cascade Hideaway.\n\nTo book a stay, we just need your target dates and the number of guests in your group to confirm availability and set up your reservation.\n\nWe'd be delighted to have you with us. Which dates are you looking at? Share your check-in and check-out here and we'll check the calendar for you right away.\n\nCassy, Cascade Concierge";
  assertEquals(score('first-howtobook-en', 0, live), []);
  // R1 still fails a reply that answers nothing
  assert(score('first-howtobook-en', 0, live.replace('To book a stay, we just need your target dates and the number of guests in your group to confirm availability and set up your reservation.', 'We hope you are well.')).some((f) => f.startsWith('R1')));
});

// ---- 4. follow-up "How do I book?": warmth and the two ways (this chat or the site) ------------------------------------------
// Example: persona.ts nextStep (the site step before the model's question) + the VOICE mid-conversation "How do I book?" example.
Deno.test('D-311.4: a follow-up "How do I book?" gets the two ways and the link, then a warm close - not the model\'s dates question', async () => {
  const prev = "Hi Ben, thank you for reaching out to Cascade Hideaway.\n\nOur direct rate starts at PHP 1,780 per night, and the nightly rate goes lower the longer you stay.\n\nWe'd be delighted to have you with us. Which dates are you looking at? Share your check-in and check-out here and we'll check the calendar for you right away.\n\nCassy, Cascade Concierge";
  const m = stub("Once we have your dates, we'll verify the calendar and guide you through the quick GCash payment to confirm your stay.", 'May we know your intended check-in and check-out dates?');
  try {
    const r = await turn('How do I book?', [['How much per night?', prev]]);
    assert(r.reply.includes(SITE_URL) && /right here in the chat/.test(r.reply) && !r.reply.includes('intended check-in'), r.reply);
    assertEquals(score('fu-howtobook-en', 1, r.reply, prev), []);
  } finally { m.restore(); }
});

// ---- 5. the dates said open once -------------------------------------------------------------------------------------------
// Example: voice.ts dedupeAvailability (code rule) + golden first-avail-and-amenity-en.
Deno.test('D-311.5: "Oct 21 to 23 is open" from the model drops the flow\'s own availability line, never a different range', async () => {
  const flowPart = "Oct 21 to 23 is available, and we'd be delighted to welcome you.\n\nHow many of you will be staying? The home is most comfortable for up to 3 adults, or 2 adults with 2 children.";
  assertEquals(dedupeAvailability('Yes, Ben, Oct 21 to 23 is open and we\'d be glad to host you.', flowPart), flowPart.split('\n\n')[1]);
  assertEquals(dedupeAvailability('The home has fiber Wi-Fi.', flowPart), flowPart);
  assertEquals(dedupeAvailability('Yes, Oct 24 to 26 is open too.', flowPart), flowPart);
  const m = stub("Yes, Ben, Oct 21 to 23 is open and we'd be glad to host you.\n\nThe home has fiber Wi-Fi with backup power, so you can work or stream without a second thought.");
  try {
    const r = await turn('Hi, is Oct 21 to 23 open? Is there wifi?');
    assertEquals((r.reply.match(/Oct 21 to 23/g) ?? []).length, 1, r.reply);
    assert(/wi-?fi/i.test(r.reply) && /How many of you/.test(r.reply), r.reply);
  } finally { m.restore(); }
});

// Golden s75 deploy: the dates in passing inside the Wi-Fi paragraph, then the flow's availability line - said twice.
Deno.test('s76: "during your stay from Nov 18 to 20" loses the range when the flow line names it; other ranges stay', async () => {
  const flowPart = "Nov 18 to 20 is available, and we'd be delighted to welcome you.\n\nHow many of you will be staying?";
  const wifi = 'Yes, Ben, we have high-speed fiber Wi-Fi with a dedicated workspace, perfect for video calls and streaming during your stay from Nov 18 to 20.';
  assertEquals(dropPassingRange(wifi, flowPart), 'Yes, Ben, we have high-speed fiber Wi-Fi with a dedicated workspace, perfect for video calls and streaming during your stay.');
  assertEquals(dropPassingRange('Wi-Fi is ready for Nov 24 to 26.', flowPart), 'Wi-Fi is ready for Nov 24 to 26.');
  assertEquals(dropPassingRange(wifi, 'How many of you will be staying?'), wifi);
  assertEquals(dropPassingRange('Nov 18 to 20 works well for a quiet stay.', flowPart), 'Nov 18 to 20 works well for a quiet stay.');
  // Fable s76: a fronted phrase and a coordinated range are left whole
  const fronted = 'Yes, we have fast Wi-Fi.\n\nFor Nov 18 to 20, the rate is PHP 5,000 per night.';
  assertEquals(dropPassingRange(fronted, flowPart), fronted);
  assertEquals(dropPassingRange('Yes! For Nov 18 to 20, we have the unit ready.', flowPart), 'Yes! For Nov 18 to 20, we have the unit ready.');
  assertEquals(dropPassingRange('Wi-Fi is included from Nov 18 to 20 and Nov 25 to 27.', flowPart), 'Wi-Fi is included from Nov 18 to 20 and Nov 25 to 27.');
  assertEquals(dropPassingRange('The rate for Nov 18 to 20 is PHP 5,000 per night.', flowPart), 'The rate is PHP 5,000 per night.');
  const m = stub(`${wifi}\n\nWe also have an EcoFlow backup station so you can stay connected throughout your visit.`);
  try {
    const r = await turn('Hi, is Nov 18 to 20 open? Is there wifi?');
    assertEquals((r.reply.match(/Nov 18 to 20/g) ?? []).length, 1, r.reply);
    assert(/wi-?fi/i.test(r.reply) && /How many of you/.test(r.reply), r.reply);
  } finally { m.restore(); }
});

// ---- 6. the name once after the greeting -------------------------------------------------------------------------------------
// Example: voice.ts nameOnce (code rule) + golden s63-month-tl.
Deno.test('D-311.5: "Hi Ben!" then "Ben, para sa..." - the second name goes', () => {
  const live = 'Hi Ben! Salamat sa pag-message sa Cascade Hideaway.\n\nBen, para sa 30 nights po, bumababa ang direct rate namin sa PHP 1,335 per night mula sa standard PHP 1,780. Lumalabas na mga PHP 40,050 lang ito para sa buong stay imbes na PHP 53,400.\n\nWe\'d be delighted to have you. Kailan ninyo gustong mag-stay? Share lang dito ang check-in at check-out and iche-check namin agad.\n\nCassy, Cascade Concierge';
  const fixed = nameOnce(live, 'Ben');
  assert(fixed.includes('\n\nPara sa 30 nights po'), fixed);
  assertEquals((fixed.match(/\bBen\b/g) ?? []).length, 1);
  assertEquals(score('s63-month-tl', 0, fixed), []);
  // a follow-up with no greeting keeps the name early, and a greeting without the name changes nothing
  assertEquals(nameOnce("Hi Ben! Salamat.\n\nWe'd be delighted to have you. Ben, kailan po?", 'Ben'), "Hi Ben! Salamat.\n\nWe'd be delighted to have you. Kailan po?");
  assertEquals(nameOnce('Ben, yes, there is parking.', 'Ben'), 'Ben, yes, there is parking.');
  assertEquals(nameOnce('Hello po! Salamat.\n\nBen, para sa 30 nights.', 'Ben'), 'Hello po! Salamat.\n\nBen, para sa 30 nights.');
});

// ---- 7. no "po" in an English reply -------------------------------------------------------------------------------------------
// Example: voice.ts noPo in index.ts's guard (code rule) + golden fu-second-link-en.
Deno.test('D-311.5: "Ben, yes po, free parking..." in English loses the "po"; English with a courtesy "po" keeps one', async () => {
  assertEquals(noPo('Ben, yes po, free parking is right in front. Opo, it is gated.'), 'Ben, yes, free parking is right in front. Yes, it is gated.');
  assertEquals(noPo('Yes po, Ben, it is gated po.', 1), 'Yes po, Ben, it is gated.');
  const prev = "Hi Ben, thank you for reaching out to Cascade Hideaway.\n\nWe'd be glad to help you plan your stay, so you can settle in smoothly whenever you visit.\n\nWe'd be delighted to have you with us. Which dates are you looking at? Share your check-in and check-out here and we'll check the calendar for you right away.\n\nCassy, Cascade Concierge";
  const m = stub("Ben, yes po, free parking is available right in front of the unit, inside our gated community with security at the entrance. We also have an outdoor CCTV camera facing the parking area 24/7 for your peace of mind.");
  try {
    const r = await turn('Is there parking?', [['Good evening', prev]]);
    assert(!/\bpo\b/.test(r.reply), r.reply);
    assertEquals(score('fu-second-link-en', 1, r.reply, prev), []);
  } finally { m.restore(); }
});

// ---- 8. Taglish: four paragraphs at most, three "po" at most, the welcome joined to the dates ask --------------------------------
// Example: booking.ts flowLead + persona.ts compose's three-"po" cap (code rules) + golden first-two-months-tl.
Deno.test('D-311.5: a Taglish two-month inquiry is four paragraphs, three "po" at most, "We\'d be delighted to have you." beside the dates ask', async () => {
  const m = stub('Para sa 60 nights po, bumababa ang direct rate namin sa PHP 1,335 per night mula sa standard PHP 1,780. Mga PHP 80,100 na lang po ito para sa buong stay imbes na PHP 106,800.\n\nKasama na rin dito ang drinking water for the stay at complimentary mid-stay refresh with fresh linens and towels para komportable ang mahaba ninyong stay.');
  try {
    const r = await turn('Hello po, pwede po magtanong about sa booking for two months?');
    assert(paragraphs(r.reply).length <= 4, r.reply);
    assert((r.reply.match(/\bpo\b/g) ?? []).length <= 3, r.reply);
    assert(!paragraphs(r.reply).some((p) => /^We'd be delighted to have (you|kayo)\.$/.test(p.trim())), r.reply);
    assertEquals((r.reply.match(/\bBen\b/g) ?? []).length, 1, r.reply); // the greeting's name only (D-311.5)
    assertEquals(score('first-two-months-tl', 0, r.reply), []);
  } finally { m.restore(); }
});

// ---- 9. discount and haggle requests: understanding, no rate explanation, the host line, the hold question --------------------
// Example: persona.ts haggleLine / haggleHold (code-written answer) + the VOICE mid-conversation haggle example; s73 F6 runs it
// through handle(). "completely understand" is off the checker's banned list.
Deno.test('D-311.6: the haggle reply passes the golden case, and "completely understand" is no longer an R2 failure', () => {
  const reply = `${P.haggleLine('en')} ${P.discountHostLine('en')}\n\n${P.haggleHold('Oct 26 to 29', 'en')}`;
  const d3 = range(now, 47, 3); // golden.ts d3
  assertEquals(score('fu-objection-dated-en', 1, reply.replace('Oct 26 to 29', d3)), []);
  assertEquals(failures(scoreReply({ guest: 'any discount?', reply: "We completely understand, and we'll gladly pass it to our host personally.", prevReply: null, kind: 'model', lang: 'en', firstTurn: false, siteUrl: SITE_URL, name: 'Ben' })).filter((f) => f.startsWith('R2')), []);
});

// ---- 11. Bisaya and Bislish guests get English; a short rate answer carries one warm clause --------------------------------------
// Example: the VOICE Bisaya example rewritten in English + the NATIVE BISAYA rule (D-311) + booking.ts settleLang (code rule).
Deno.test('D-311.8: a Bisaya guest is answered in English (model and flow), and a cold short rate answer gets the warm clause', async () => {
  assertEquals(start('Naa bay bakante Oct 19 to 21?', now).lang, 'en');
  const m = stub('Ben, our direct rate starts at PHP 1,780 per night, and the nightly rate goes lower the longer you stay, with cleaning and the full amenities included in every night of it.');
  try {
    const prev = "Hi Ben, thank you for reaching out to Cascade Hideaway.\n\nYes, there's fiber Wi-Fi with backup power, so you stay connected without a second thought.\n\nWe'd be delighted to have you with us. Which dates are you looking at? Share your check-in and check-out here and we'll check the calendar for you right away.\n\nCassy, Cascade Concierge";
    const r = await turn('Pila ang rate kada gabii?', [['Maayong gabii, naa bay wifi?', prev]]);
    assert(m.seen[0].includes('Bisaya and Bislish guests get English'), m.seen[0].slice(0, 200));
    assert(r.reply.includes(P.warmClause('en')), r.reply);
    assertEquals(score('reg-bot-bis', 1, r.reply, prev), []);
  } finally { m.restore(); }
});

// ---- audit of 3bd0e1b ----------------------------------------------------------------------------------------------------------
const hostLines = (r: string) => (r.match(/Our host also looks/g) ?? []).length;
// D1: code answers alone only when the price ask is the whole message; a rate question or a second question keeps the model.
Deno.test('audit D1: a discount ask with a stay length or another question keeps the model answer, opened by the understanding line, one host line', async () => {
  const five = stub('For 5 nights, your direct rate comes down to PHP 1,602 per night from the standard PHP 1,780, about PHP 8,010 for the stay, so you can settle in without a second thought.');
  try {
    const r = await turn('what is the best price for 5 nights?');
    assert(five.seen[0].includes('also asks for a lower price') && five.seen[0].includes('5 nights'), five.seen[0].slice(0, 300));
    assert(r.reply.includes('8,010') && r.reply.includes(P.haggleLine('en')) && r.reply.indexOf(P.haggleLine('en')) < r.reply.indexOf('8,010'), r.reply);
    assertEquals(hostLines(r.reply), 1, r.reply);
    assertEquals(r.calls.filter((c) => c.fx === 'handoff').map((c) => c.detail.risk), ['policy_exception']);
  } finally { five.restore(); }
  const thirty = stub('For 30 nights, your direct rate comes down to PHP 1,335 per night from the standard PHP 1,780, about PHP 40,050 for the stay.');
  try {
    const r = await turn('is there a discount for 30 nights?');
    assert(thirty.seen[0].includes('PHP 1,335'), thirty.seen[0].slice(0, 300));
    assert(r.reply.includes('1,335') && r.reply.includes(P.haggleLine('en')), r.reply);
    assertEquals(hostLines(r.reply), 1, r.reply);
  } finally { thirty.restore(); }
  // the model forwards anyway: its sentence goes, code's host line stays the only one
  const park = stub("Yes, there's free parking right in front of the unit, inside the gated community. Our host will look at your rate request personally. We'll keep a space for you.");
  try {
    const r = await turn('can you do 1,500? and is there parking?');
    assert(/free parking/.test(r.reply) && r.reply.startsWith('Hi Ben') && r.reply.includes(P.haggleLine('en')), r.reply);
    assert(!/Our host will look/.test(r.reply), r.reply);
    assertEquals(hostLines(r.reply), 1, r.reply);
    assert(!/1,500|PHP|₱/.test(r.reply.replace(/[\s\S]*?\n\n/, '')), r.reply);
  } finally { park.restore(); }
  // the pure haggle stays code-only (no model call)
  const pure = stub('should not be used');
  try {
    const r = await turn('can you do 1,500 a night?');
    assertEquals(pure.seen.length, 0);
    assert(r.reply.includes(P.haggleLine('en')) && hostLines(r.reply) === 1, r.reply);
  } finally { pure.restore(); }
});

// D3: the three-"po" cap is taken from the answer; the flow's frozen lines keep every "po".
Deno.test('audit D3: the Taglish "po" cap spares the flow lines', () => {
  const flowPart = 'We\'d be delighted to have you. Kailan po ninyo gustong mag-stay? Check-in and check-out lang po (halimbawa, "Oct 13 to 15").';
  const ctx: P.ComposeCtx = { lang: 'tl', name: 'Ben', greet: false, greetNow: false, followUp: true, flowFollowUp: flowPart, hostLine: '', quiet: false, look: '',
    decision: false, linkTurn: false, siteShown: false, datesKnown: false, held: { dates: false, pax: false, name: true }, prevBot: '' };
  const out = P.compose({ answer: 'Opo, may wifi po kami. Fibre po ito, at mabilis po talaga.', ask: null }, ctx).reply;
  assert(out.endsWith(flowPart), out);
  assertEquals((out.match(/\bpo\b/g) ?? []).length, 3, out);
  const heavy = P.compose({ answer: 'May wifi po. Fibre po.', ask: null }, { ...ctx, flowFollowUp: `${flowPart} Salamat po.` }).reply;
  assert(heavy.endsWith(`${flowPart} Salamat po.`) && heavy.startsWith('May wifi. Fibre.'), heavy);
});

// Fable re-audit nit (f9e1824): dropForward removes a forward of the request, never a warm "look forward" sentence.
Deno.test('s75 dropForward keeps "look forward" warmth and drops the forward', () => {
  const out = dropForward('Free parking is right in front of the unit. We have forwarded your request to our team. We look forward to welcoming you.');
  assert(out.includes('We look forward to welcoming you.'), out);
  assert(!/forwarded your request/.test(out), out);
});
