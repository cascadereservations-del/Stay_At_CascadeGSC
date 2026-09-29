// deno test --no-check messenger-concierge/persona.test.ts
// D-268 / D-269: the tone gate for persona.ts. Whatever the flow does, every move passes the persona lint in every register, the
// REQUIRED disclosures are always carried, and Bislish never carries a Tagalog "po". A flow change cannot break these;
// a wording change that does fails here before it reaches a guest. A NEW export of persona.ts fails the coverage test
// until it has samples below.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import * as P from './persona.ts';
import { CAPACITY, LAST_MINUTE } from './persona.ts';
import { rateLine, type Flow, type Lang } from './booking.ts';
import { decisionInvite, firstInvite, lintReply, lookNudge, paragraphs, toneRules, turnoverCheckinLine } from './voice.ts';
import { AIRBNB_URL, SITE_URL } from '../_shared/cascade-core/facts.ts';
import { scoreReply } from './golden-score.ts';

const LANGS = ['en', 'tl', 'bis'] as const;
const card: P.CardFacts = { resume: false, who: 'Ben Munez', range: 'Oct 20 to 22', nights: 2, pax: 2, phone: '09171234567', email: 'ben@example.com', total: '₱3,382', promo: null };
const pay: P.PaymentFacts = { name: 'Ben', dates: 'Oct 20 to 22', ref: 'DIR-1', until: 'Sep 18 at 10:00 AM', rel: 'tomorrow', hold: true, near: false, deposit: '₱1,691', balance: '₱1,691', full: false };

// ---- D-286: compose() fixtures ----
const ANSWER: Record<Lang, string> = {
  en: `For a month-long stay, the direct rate comes down to PHP 1,335 per night, about PHP 40,050 for 30 nights, and the longer stay includes drinking water and a mid-stay refresh.`,
  tl: `Para sa month-long stay po, PHP 1,335 per night ang direct rate, mga PHP 40,050 for 30 nights, kasama na ang drinking water at mid-stay refresh.`,
  bis: `Para sa month-long stay, PHP 1,335 per night ang direct rate, mga PHP 40,050 for 30 nights, apil na ang drinking water ug mid-stay refresh.`,
};
const ASK: Record<Lang, string> = { en: 'Which dates do you have in mind?', tl: 'Kailan po ninyo balak mag-stay?', bis: 'Kanus-a mo plano mag-stay?' };
const ctx = (o: Partial<P.ComposeCtx> = {}): P.ComposeCtx => ({ lang: 'en', name: 'Ben', greet: false, intro: false, followUp: true, flowFollowUp: null,
  hostLine: '', quiet: false, look: '', decision: false, bookingTurn: false, siteRecent: false, datesKnown: false,
  held: { dates: false, pax: false, name: true }, prevBot: '', ...o });
const A = (l: Lang, ask: string | null = null) => ({ answer: ANSWER[l], ask });
const CARD_TAIL = `Here's your stay, ready whenever you are:\n📅 Oct 20 to 22 · 2 nights · 2 guests\n💰 Total ₱3,382`;
/** One of every shape: first reply, first with an ask, follow-up with and without a link, an ask, a host line, a look turn,
 *  a pay hold, a flow card. */
const COMPOSE_CASES = (l: Lang): Array<[Partial<P.ComposeCtx>, { answer: string; ask: string | null }]> => [
  [{ greet: true, intro: true, followUp: false }, A(l)],
  [{ greet: true, intro: true, followUp: false, name: null, held: { dates: false, pax: false, name: false } }, A(l, ASK[l])],
  [{ bookingTurn: true }, A(l)],
  [{ bookingTurn: true, siteRecent: true }, A(l)],
  [{ datesKnown: true, siteRecent: true }, A(l)],
  [{}, A(l, ASK[l])],
  [{ hostLine: P.discountHostLine(l), bookingTurn: true }, A(l)],
  [{ look: lookNudge('is there wifi?', l, { site: false, reviews: false }) }, A(l)],
  [{ look: lookNudge('legit ba?', l, { site: true, reviews: false }), greet: true, intro: true, followUp: false }, A(l)],
  [{ quiet: true }, A(l)],
  [{ flowFollowUp: CARD_TAIL }, A(l)],
];
const NEXT_CASES: Array<Partial<P.ComposeCtx>> = [
  { greet: true, followUp: false }, { bookingTurn: true }, { bookingTurn: true, datesKnown: true }, { decision: true }, {},
];

/** Every guest-facing move, with the fact shapes it is called with. Fragments (partyName, datesOpen, relDayWord) are
 *  linted inside the sentences that carry them. */
const SAMPLES: Record<string, (l: Lang) => string[]> = {
  greeting: (l) => [P.greeting('Ben', l), P.greeting(null, l, true)],
  greetBlock: (l) => [P.greetBlock('Ben', l, true) + P.datesOpen('Oct 3 to 4', l) + '.'],
  BOT_REPLY: (l) => [P.BOT_REPLY[l]],
  CASSY_INTRO: (l) => [P.CASSY_INTRO[l]],
  partyName: (l) => [1, 2, 3, 4].map((n) => P.openAck(P.datesOpen('Oct 3 to 4', l), n, l)),
  datesOpen: (l) => [P.openAck(P.datesOpen('the night of Oct 3', l), 2, l)],
  datesChecking: (l) => [P.datesChecking('Oct 3 to 4', l) + '.'],
  datesReserved: (l) => [P.datesReserved('tonight (Sep 26)', l)],
  datesReservedNearest: (l) => [true, false].flatMap((one) => [true, false].map((ask) => P.datesReservedNearest('Sep 26 to 27', one ? 'Oct 2' : 'Oct 2 to 4', one, ask, l))),
  openAck: (l) => [P.openAck(P.datesOpen('Oct 20 to 22', l), 2, l)],
  openerText: (l) => [P.openerText(P.greeting('Ben', l), P.datesOpen('Oct 20 to 22', l), null, 2, l), P.openerText(P.greeting(null, l), '', ['Oct 20', 'Oct 22'], 3, l), P.openerText('', '', null, 1, l)],
  datesAsk: (l) => [P.datesAsk('Ben', 'Oct 5 to 7', l), P.datesAsk('', 'Oct 5 to 7', l)],
  nightsAsk: (l) => [P.nightsAsk('Oct 3', true, l), P.nightsAsk('Oct 3', false, l)],
  earliestCheckout: (l) => [P.earliestCheckout('Oct 3', 'Oct 4', l)],
  pastDate: (l) => [P.pastDate(l)],
  retryLine: (l) => (['dates', 'checkout', 'guests', 'details', 'that'] as const).map((w) => P.retryLine(w, P.partyAsk(l), l)),
  partyAsk: (l) => [P.partyAsk(l)],
  overCapacityLine: (l) => [P.overCapacityLine(6, l)],
  partyWelcome: (l) => [1, 2, 3, 4].map((n) => `${P.partyWelcome(n, l)}\n\n${P.detailsAsk('', l, false)}`),
  oneNight: (l) => [P.oneNight('PHP 1,780', l), `${P.oneNight('PHP 1,780', l)} ${LAST_MINUTE}\n\n${P.holdOffer(true, l)}`],
  nightsPrice: (l) => [`${P.nightsPrice(2, 'PHP 1,691', 'PHP 1,780', 'PHP 3,382', l)}\n\n${P.holdOffer(false, l, false)}`],
  promoOneNight: (l) => [P.promoOneNight('PHP 1,543', 'Anniversary Promotion', 'PHP 1,780', l)],
  promoAllNights: (l) => [P.promoAllNights(3, 'Anniversary Promotion', 'PHP 1,543', 'PHP 1,780', 'PHP 4,629', l)],
  promoMixed: (l) => [P.promoMixed({ n: 3, total: 'PHP 4,777', promoNights: 1, when: 'Oct 17', name: 'Anniversary Promotion', promoRate: 'PHP 1,543', rest: 2, restRate: 'PHP 1,617', std: 'PHP 1,780' }, l)],
  holdOffer: (l) => [P.holdOffer(true, l), P.holdOffer(false, l), P.holdOffer(false, l, false)],
  choiceAck: (l) => [`${P.choiceAck('Oct 2', l)} ${P.partyAsk(l)}`],
  detailsAsk: (l) => [P.detailsAsk('Suzanne', l), P.detailsAsk('', l), P.detailsAsk('', l, false)],
  nextDetail: (l) => (['name', 'phone', 'email'] as const).map((m) => P.nextDetail(m, 'Ben Munez', l)),
  stayCard: (l) => [`${P.stayCard(card, l)}\n\n${P.payChoiceLine(false, '₱3,382', '₱1,691', l)}`, `${P.stayCard({ ...card, resume: true, pax: 1, nights: 1, promo: { name: 'Anniversary Promotion', nights: 1, rate: '₱1,543' } }, l)}\n\n${P.payChoiceLine(true, '₱1,543', '₱772', l)}`],
  payChoiceLine: (l) => [P.payChoiceLine(false, '₱3,382', '₱1,691', l), P.payChoiceLine(true, '₱3,382', '₱1,691', l)],
  cancelReply: (l) => [P.cancelReply(l)],
  holdCancelLine: (l) => (['cancel', 'receipt', 'change'] as const).map((k) => P.holdCancelLine(k, 'Ben Munez', 'Oct 20 to 22', l)),
  paidClaimLine: (l) => [P.paidClaimLine(true, 'Ben', 'DIR-1', l), P.paidClaimLine(false, null, 'DIR-1', l)],
  strayReceiptLine: (l) => [P.strayReceiptLine('Ben', l)],
  payHow: (l) => [`${P.payHow('Ben', l, true)}\n\n${P.nextDetail('phone', 'Ben', l)}`, P.payHow(null, l, false)],
  paymentPromise: (l) => [P.paymentPromise(l)],
  paymentMessage: (l) => [P.paymentMessage(pay, l), P.paymentMessage({ ...pay, hold: false, near: true, full: true }, l), P.paymentMessage({ ...pay, name: '', hold: false }, l)],
  relDayWord: (l) => [P.paymentMessage({ ...pay, rel: P.relDayWord(0, l) }, l)],
  houseRule: (l) => (['party', 'pets', 'guests'] as const).map((k) => P.houseRule(k, l)),
  discountHostLine: (l) => [`Booking directly gives our best rate, and the nightly rate goes down the longer you stay. ${P.discountHostLine(l)}`],
  // Session 58: the fixed turns index.ts sends.
  HANDOFF: () => Object.values(P.HANDOFF).filter(Boolean),
  ATTACHMENT_REPLY: () => [P.ATTACHMENT_REPLY],
  ACK_SUGGEST: () => [P.ACK_SUGGEST],
  datesFirstLine: (l) => [true, false].flatMap((f) => [P.datesFirstLine('Ben', l, f), P.datesFirstLine(null, l, f)]),
  closers: (l) => [true, false].flatMap((t) => [...P.closers('Ben', l, t), ...P.closers(null, l, t).map((c) => `${c}\n\n${P.readyInvite(l)}`)]),
  readyInvite: (l) => [P.readyInvite(l)],
  nudgeSite: (l) => [`The nearest mall is ten minutes by car.\n\n${P.nudgeSite(l)}`],
  nudgeDates: (l) => [`${P.nudgeDates(l)} ${P.nudgeSite(l)}`, P.nudgeDates(l)],
  nudgeReady: (l) => [P.nudgeReady(l)],
  confirmSiteInvite: (l) => [`${P.stayCard(card, l)}\n\n${P.confirmSiteInvite(l)}`],
  datesTaken: (l) => [P.datesTaken(l)],
  submitFailed: (l) => [P.submitFailed(l)],
  receiptThanks: (l) => [P.receiptThanks('Ben Munez', l), P.receiptThanks(null, l)],
  receiptAlready: (l) => [P.receiptAlready(l)],
  receiptLapsed: (l) => [P.receiptLapsed('hold', l), P.receiptLapsed('link', l)],
  receiptRetry: (l) => [P.receiptRetry(l)],
  handoffFollowUp: (l) => [P.handoffFollowUp(l)],
  accessVerify: (l) => [P.accessVerify(l)],
  priorityAsk: (l) => [P.priorityAsk(l)],
  priorityRetry: (l) => [P.priorityRetry(l)],
  houseVerifyAsk: (l) => [P.houseVerifyAsk(l)],
  priorityVerified: (l) => [P.priorityVerified('Allyssa', l), P.priorityVerified('Guest', l), P.priorityVerified(null, l)],
  priorityUnmatched: (l) => [P.priorityUnmatched(l)],
  attachmentNoted: (l) => [P.attachmentNoted(l)],
  voiceNote: (l) => [P.voiceNote(l)],
  welcomeBack: () => [P.welcomeBack('Joseph', 'Oct 2 to 4'), P.welcomeBack('there', '')],
  // D-286: the frame compose() writes around the model's answer - every shape it can emit.
  compose: (l) => COMPOSE_CASES(l).map(([o, a]) => P.compose(a, ctx({ lang: l, ...o })).reply),
  nextStep: (l) => NEXT_CASES.map((o) => P.nextStep(ctx({ lang: l, ...o }), null)).filter(Boolean),
  cleanAnswer: (l) => [P.cleanAnswer(ANSWER[l] + ' We can arrange the booking right here in the chat, or you may secure your dates on our site:\n👉 ' + SITE_URL, { greeted: true, followUp: false }).text],
  closeLine: (l) => [P.closeLine(l, ''), P.closeLine(l, P.closeLine(l, ''))],
};
/** Lloyd approved these word for word: they carry his "!" greeting and up to six purposeful "po" (voice.test.ts pins them). */
const APPROVED = new Set(['greeting', 'greetBlock', 'BOT_REPLY', 'CASSY_INTRO', 'paymentMessage', 'relDayWord', 'paymentPromise']);
/** The guest lines voice.ts composes (invites, the chat route, the turnover line, the look block): same gate. */
const VOICE_LINES = (l: Lang) => [decisionInvite(l, SITE_URL), firstInvite(l, SITE_URL),
  turnoverCheckinLine('Oct 2', l), lookNudge('may wifi po ba?', l, { site: false, reviews: false }), lookNudge('legit ba ni?', l, { site: true, reviews: false })];

Deno.test('every persona export has samples, so a new move cannot skip the tone gate', () => {
  const skip = new Set(['pick', 'CAPACITY', 'LAST_MINUTE']);
  for (const k of Object.keys(P)) if (!skip.has(k)) assert(k in SAMPLES, `persona.ts exports ${k} with no samples in persona.test.ts`);
});

Deno.test('every persona move passes the lint and the voice rules in all three registers', () => {
  for (const lang of LANGS) for (const [name, make] of Object.entries(SAMPLES)) for (const m of make(lang)) {
    assertEquals([...lintReply(m), ...toneRules(m, lang, APPROVED.has(name))], [], `${name}/${lang}: ${m.slice(0, 90)}`);
  }
});

Deno.test('the lines voice.ts composes pass the same gate in all three registers', () => {
  for (const lang of LANGS) for (const m of VOICE_LINES(lang)) assertEquals([...lintReply(m), ...toneRules(m, lang)], [], `${lang}: ${m.slice(0, 90)}`);
});

Deno.test('the gate itself catches what it is for (a check that cannot fail proves nothing)', () => {
  assertEquals(toneRules('Book now, only 2 nights left.'), ['urgency']);
  assertEquals(toneRules('Thank you. 🌿 See you soon.'), ['leaf_not_at_close']);
  assertEquals(toneRules('Salamat po.', 'bis'), ['po_in_bislish']);
  assertEquals(toneRules('Welcome, the two of you.', 'tl'), ['two_of_you_in_taglish']);
  assertEquals(toneRules('See you soon!'), ['exclamation']);
  assertEquals(toneRules('Hi Ben! See you soon.'), []);
  assertEquals(toneRules('Opo po, sige po, salamat po.'), ['po_over_two']);
  assertEquals(toneRules('Opo po, sige po, salamat po.', 'tl', true), []);
});

Deno.test('session 58: no raw error code and no "Thank you, po." reaches a guest', () => {
  for (const lang of LANGS) {
    assert(!/,\s*po\./.test(P.receiptThanks(null, lang)), lang);
    assert(P.receiptThanks('Ben Munez', lang).includes('Ben.'), lang);
    for (const m of [P.submitFailed(lang), P.receiptRetry(lang)]) assert(!/_|\(|error/i.test(m), `${lang}: ${m}`);
  }
});

Deno.test('the REQUIRED disclosures are carried whatever the wording', () => {
  for (const lang of LANGS) {
    assert(P.partyAsk(lang).includes(CAPACITY[lang]), `partyAsk ${lang}`);
    assert(P.overCapacityLine(5, lang).includes(CAPACITY[lang]), `overCapacityLine ${lang}`);
    assert(P.stayCard(card, lang).includes('₱1,000 refundable security deposit'), `card deposit ${lang}`);
    for (const full of [true, false]) assert(P.payChoiceLine(full, '₱3,382', '₱1,691', lang).includes('₱1,000 refundable deposit'), `payChoice ${lang}`);
    // inside five days the rate line always carries the full-payment rule, whatever the price wording
    const soon: Flow = { step: 'offer', checkin: '2026-10-01', checkout: '2026-10-02', lang, started_at: '', updated_at: '' };
    assert(rateLine(soon, new Date('2026-09-29T02:00:00Z')).endsWith(LAST_MINUTE), `LAST_MINUTE ${lang}`);
  }
  assert(/3 adults, or 2 adults with 2 (children|kids)/.test(CAPACITY.en + CAPACITY.tl + CAPACITY.bis));
  assert(/five days/.test(LAST_MINUTE) && /full amount/.test(LAST_MINUTE));
});

Deno.test('the details are asked in one message, and the name is used once when known', () => {
  for (const lang of LANGS) {
    const d = P.detailsAsk('Suzanne', lang);
    assert(/name/i.test(d) && /mobile/i.test(d) && /email/i.test(d), `${lang}: ${d}`);
    assertEquals(d.split('Suzanne').length - 1, 1, lang);
  }
});

Deno.test('the party is named in the register: kayong dalawa / dalawa kayo in Taglish, never the two of you', () => {
  assertEquals([1, 2, 3, 4].map((n) => P.partyName(n, 'tl')), ['you', 'kayong dalawa', 'kayong tatlo', 'kayong apat']);
  assertEquals([1, 2, 3].map((n) => P.partyName(n, 'en')), ['you', 'the two of you', 'your party of 3']);
  assertEquals(P.partyWelcome(2, 'tl'), 'Noted po, dalawa kayo. We\'re looking forward to welcoming you.');
  assertEquals(P.partyWelcome(2, 'en'), 'The two of you, then, and we\'re already looking forward to it.');
});

Deno.test('every offer asks the same one-yes question: the price path, the offer step and the reserved line', () => {
  for (const lang of LANGS) {
    const q = P.holdOffer(true, lang, false);
    assert(P.datesReservedNearest('tonight (Sep 26)', 'Oct 2', true, true, lang).includes(q), `reserved ${lang}`);
    assert(/already reserved|reserved na/.test(P.datesReservedNearest('Sep 26 to 27', 'Oct 2', true, true, lang)), `index.ts RESERVED_RE ${lang}`);
  }
});

// ---- D-286: the model writes only the answer; compose() writes the frame (DESIGN-model-answers-code-composes section 1) ----
const leaves = (s: string) => (s.match(/🌿/gu) ?? []).length;
const po = (s: string) => (s.match(/\bpo\b/gi) ?? []).length;
const endsOnLink = (s: string) => /(👉|⭐|🏡)[^\n]*https?:\/\/\S+\s*$/.test(s.trim());

Deno.test('D-286 nextStep: one next step, first match wins (design section 1, rules 1-7)', () => {
  for (const l of LANGS) {
    const n = (o: Partial<P.ComposeCtx>, ask: string | null = null) => P.nextStep(ctx({ lang: l, ...o }), ask);
    assertEquals(n({ flowFollowUp: CARD_TAIL }), '', `1 mid-flow ${l}`);                       // the flow's card is the step
    assertEquals(n({ quiet: true, bookingTurn: true }, ASK[l]), '', `2 quiet ${l}`);           // pay hold, staying, host matter
    const look = lookNudge('is there wifi?', l, { site: false, reviews: false });
    const lk = n({ look, bookingTurn: true }, ASK[l]);
    assert(lk.includes(SITE_URL) && lk.includes(AIRBNB_URL) && /chat/i.test(lk), `3 look carries both routes ${l}: ${lk}`);
    assertEquals(n({}, ASK[l]), ASK[l], `4 ask ${l}`);
    assertEquals(n({ held: { dates: true, pax: false, name: true }, datesKnown: true, siteRecent: true }, 'Which dates would you like?'), '', `4 a held slot is not asked ${l}`);
    assertEquals(n({ decision: true, siteRecent: true }), decisionInvite(l, SITE_URL), `5 decision ${l}`);
    assertEquals(n({ greet: true, followUp: false }), firstInvite(l, SITE_URL), `6 first ${l}`);
    assertEquals(n({ bookingTurn: true }), P.nudgeSite(l), `6 booking, dates unknown ${l}`);
    assertEquals(n({ bookingTurn: true, datesKnown: true }), P.nudgeReady(l), `6 booking, dates known ${l}`);
    assertEquals(n({ bookingTurn: true, siteRecent: true }), P.nudgeDates(l), `7 link recent, dates unknown ${l}`);
    assertEquals(n({}), P.nudgeDates(l), `7 dates unknown ${l}`);
    assertEquals(n({ datesKnown: true, siteRecent: true }), '', `7 dates known, link recent ${l}`);
  }
});

Deno.test('D-286 cleanAnswer: the model frame goes - greeting, Cassy, links, invitations, closes, leaves - and is logged', () => {
  const url = SITE_URL;
  const g = P.cleanAnswer(`Hi Ben! Thank you for reaching out to Cascade Hideaway. I'm Cassy, the home's digital concierge. For a month-long stay, the rate is PHP 1,335 per night.`, { greeted: true, followUp: false, name: 'Ben' });
  assertEquals(g.text, 'For a month-long stay, the rate is PHP 1,335 per night.');
  assert(g.stripped.length >= 2);
  assertEquals(P.cleanAnswer(`Hi Ben, yes po, may wifi.`, { greeted: false, followUp: true }).text, 'Ben, yes po, may wifi.');
  assertEquals(P.cleanAnswer(`Hi Ben, welcome back. Yes, the wifi is fibre.`, { greeted: false, followUp: false }).text, 'Hi Ben, welcome back. Yes, the wifi is fibre.'); // a long-gap return keeps its salutation (SPEC-21)
  assertEquals(P.cleanAnswer(`Yes, parking is free.\n\nYou may check availability on our site:\n👉 ${url}`, { greeted: false, followUp: true }).text, 'Yes, parking is free.');
  assertEquals(P.cleanAnswer(`Yes, parking is free. We can arrange the booking right here in the chat, or you may secure your dates on our site.`, { greeted: false, followUp: true }).text, 'Yes, parking is free.');
  const closes = P.cleanAnswer(`Ben, yes - the PHP 1,000 refundable deposit applies to every stay.\n\nWe're here if you have any other questions.\n\nWe'll have everything prepared before you arrive. 🌿`, { greeted: false, followUp: true });
  assertEquals(closes.text, 'Ben, yes - the PHP 1,000 refundable deposit applies to every stay.');
  assertEquals(leaves(P.cleanAnswer('Yes, there is a kitchen. 🌿 It has an induction cooker.', { greeted: false, followUp: true }).text), 0);
  assertEquals(P.cleanAnswer('Yes.', { greeted: false, followUp: true }).stripped, []);
  assertEquals(P.cleanAnswer(`Airbnb reviews: ${AIRBNB_URL}`, { greeted: false, followUp: true }).text, '');   // an answer that was only frame is empty
});

Deno.test('D-286 closeLine: one 🌿 at the end, never the previous reply close', () => {
  for (const l of LANGS) {
    const a = P.closeLine(l, ''), b = P.closeLine(l, `Something.\n\n${a}`);
    assert(a.endsWith('🌿') && leaves(a) === 1, a);
    assert(a !== b, `${l}: ${a} twice`);
  }
});

Deno.test('D-286 compose: the first reply is greeting / answer / invitation, ends on the link, the name once', () => {
  for (const l of LANGS) {
    const live = { ...A(l), answer: l === 'en' ? `For a month-long stay, Ben, the direct rate is PHP 1,335 per night, about PHP 37,380 for 28 nights.` : ANSWER[l] };
    const r = P.compose(live, ctx({ lang: l, greet: true, intro: true, followUp: false })).reply, ps = paragraphs(r);
    assert(/Cassy/.test(ps[0]) && !/\d/.test(ps[0]), `greeting paragraph alone ${l}: ${ps[0]}`);
    assert(ps.length <= 4 && endsOnLink(r), `${l}: ${r}`);
    assertEquals((r.match(/\bBen\b/g) ?? []).length, 1, `name once ${l}: ${r}`);
    assertEquals(leaves(r), 0, l);
    const s = scoreReply({ guest: 'How much for a month-long stay?', reply: r, prevReply: null, kind: 'model', lang: l, firstTurn: true, siteUrl: SITE_URL, name: 'Ben' });
    for (const k of ['R1', 'R4', 'R7', 'R10'] as const) assertEquals(s[k], null, `${k} ${l}: ${r}`);
    // an ask on a first reply rides in the answer; the reply still ends on the link (Lloyd's approved first replies)
    const q = P.compose(A(l, ASK[l]), ctx({ lang: l, greet: true, intro: true, followUp: false })).reply;
    assert(q.includes(ASK[l]) && endsOnLink(q), `${l}: ${q}`);
  }
});

Deno.test('D-286 compose: a follow-up ends on its one next step, and closes only after a link', () => {
  for (const l of LANGS) {
    const prev = `Earlier reply.\n\n${P.closeLine(l, '')}`;
    const linked = P.compose(A(l), ctx({ lang: l, bookingTurn: true, prevBot: prev })).reply;
    assert(linked.trimEnd().endsWith('🌿') && leaves(linked) === 1, `close after link ${l}: ${linked}`);
    assert(!linked.endsWith(P.closeLine(l, '')), `not the previous close ${l}`);
    assert(!/^(hi|hello)\b/i.test(linked), l);
    const unlinked = P.compose(A(l), ctx({ lang: l })).reply;
    assert(unlinked.endsWith(P.nudgeDates(l).replace(/ po\b/g, '').slice(-20)) && leaves(unlinked) === 0, `no link, no close ${l}: ${unlinked}`);
    const asked = P.compose(A(l, ASK[l]), ctx({ lang: l })).reply;
    assert(asked.endsWith(ASK[l].replace(/ po\b/g, '').slice(-10)) && leaves(asked) === 0, `the ask ends it ${l}: ${asked}`);
    for (const r of [linked, unlinked, asked]) assert(paragraphs(r).length <= 4, `${l}: ${r}`);
  }
});

Deno.test('D-286 compose: host line once in the answer, look turn one invitation, quiet and flow turns add nothing', () => {
  for (const l of LANGS) {
    const host = P.compose(A(l), ctx({ lang: l, hostLine: P.discountHostLine(l), bookingTurn: true })).reply;
    assertEquals(host.split(P.discountHostLine(l)).length - 1, 1, l);
    assert(paragraphs(host)[0].includes(P.discountHostLine(l)), `joined to the answer ${l}: ${host}`);
    const look = P.compose(A(l), ctx({ lang: l, look: lookNudge('is there wifi?', l, { site: false, reviews: false }) })).reply;
    assertEquals(paragraphs(look).filter((p) => p.includes(SITE_URL)).length, 1, `${l}: ${look}`);
    assert(/chat/i.test(look), l);
    // a staying guest's or a paying guest's own question stays in the answer; nothing else is added
    assertEquals(P.compose(A(l, ASK[l]), ctx({ lang: l, quiet: true, bookingTurn: true })).reply, `${ANSWER[l]} ${ASK[l]}`);
    assertEquals(P.compose(A(l), ctx({ lang: l, flowFollowUp: CARD_TAIL })).reply, `${ANSWER[l]}\n\n${CARD_TAIL}`);
  }
});

Deno.test('D-286 compose: "po" thinned over the whole message - two in Taglish, none in Bislish', () => {
  const heavy = { answer: 'Opo, may wifi po kami. Fibre po ito, at mabilis po talaga para sa work po.', ask: null };
  assert(po(P.compose(heavy, ctx({ lang: 'tl', bookingTurn: true })).reply) <= 2);
  assertEquals(po(P.compose(heavy, ctx({ lang: 'bis', bookingTurn: true })).reply), 0);
});
