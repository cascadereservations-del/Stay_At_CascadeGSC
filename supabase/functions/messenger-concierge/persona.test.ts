// deno test --no-check messenger-concierge/persona.test.ts
// D-268 / D-269: the tone gate for persona.ts. Whatever the flow does, every move passes the persona lint in every register, the
// REQUIRED disclosures are always carried, and Bislish never carries a Tagalog "po". A flow change cannot break these;
// a wording change that does fails here before it reaches a guest. A NEW export of persona.ts fails the coverage test
// until it has samples below.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import * as P from './persona.ts';
import { CAPACITY, LAST_MINUTE } from './persona.ts';
import { rateLine, type Flow, type Lang } from './booking.ts';
import { lintReply } from './voice.ts';

const LANGS = ['en', 'tl', 'bis'] as const;
const card: P.CardFacts = { resume: false, who: 'Ben Munez', range: 'Oct 20 to 22', nights: 2, pax: 2, phone: '09171234567', email: 'ben@example.com', total: '₱3,382', promo: null };
const pay: P.PaymentFacts = { name: 'Ben', dates: 'Oct 20 to 22', ref: 'DIR-1', until: 'Sep 18 at 10:00 AM', rel: 'tomorrow', hold: true, near: false, deposit: '₱1,691', balance: '₱1,691', full: false };

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
};
/** Lloyd approved these word for word: they carry his "!" greeting and up to six purposeful "po" (voice.test.ts pins them). */
const APPROVED = new Set(['greeting', 'greetBlock', 'BOT_REPLY', 'CASSY_INTRO', 'paymentMessage', 'relDayWord', 'paymentPromise']);
const URGENCY = /\b(hurry|limited|last chance|act fast|book now|don'?t miss|selling fast|while (it|they) last|only \d+ (left|nights? left))\b/i;

Deno.test('every persona export has samples, so a new move cannot skip the tone gate', () => {
  const skip = new Set(['pick', 'CAPACITY', 'LAST_MINUTE']);
  for (const k of Object.keys(P)) if (!skip.has(k)) assert(k in SAMPLES, `persona.ts exports ${k} with no samples in persona.test.ts`);
});

Deno.test('every persona move passes the lint and the voice rules in all three registers', () => {
  for (const lang of LANGS) for (const [name, make] of Object.entries(SAMPLES)) for (const m of make(lang)) {
    const at = `${name}/${lang}: ${m.slice(0, 90)}`;
    assertEquals(lintReply(m), [], at);
    assert(!URGENCY.test(m), `urgency word: ${at}`);
    assert((m.match(/🌿/gu) ?? []).length <= 1 && (!m.includes('🌿') || m.trimEnd().endsWith('🌿')), `one 🌿, at the close: ${at}`);
    if (lang === 'bis') assert(!/\b(po|opo)\b/i.test(m), `no po in Bislish: ${at}`);
    if (lang === 'tl') assert(!/the two of you/i.test(m), `Taglish says "kayong dalawa": ${at}`);
    if (APPROVED.has(name)) continue;
    const own = m.replace(/^(Hi [A-Z]\w*|Hello po|Hello)! /, ''); // the approved greeting's "!" may lead a composed first reply
    assert(!/!/.test(own), `no exclamation: ${at}`);
    assert((m.match(/\bpo\b/gi) ?? []).length <= 2, `at most two po: ${at}`);
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
