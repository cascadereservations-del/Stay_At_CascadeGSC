// Voice close-out (2026-09-17): the golden conversations. DATA ONLY. Each one runs on a fresh probe: thread (a long
// thread poisons itself: the model copies its own earlier turns), is scored by golden-score.ts on every reply, and
// passes when three runs out of three pass. Dates are computed from today, so the set does not rot.
// A wording wish after the freeze becomes ONE new case here plus one example in facts.ts (protocol 10 section 8).
import type { Kind, Reg } from './golden-score.ts';

export type GoldenTurn = { say: string; kind: Kind; lang: Reg; noInvite?: boolean; must?: RegExp[]; mustNot?: RegExp[]; image?: boolean;
  /** SPEC-32 s7: minutes the probe clock moves before this turn (default 1), and the effects it must record. */
  advance_minutes?: number; effects?: RegExp[] };
export type GoldenCase = { id: string; group: 'first' | 'followup' | 'register' | 'flow' | 'handoff' | 'payment'; turns: GoldenTurn[] };

const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** "Oct 27 to 29" / "Oct 30 to Nov 1", `offset` days from `now`, `nights` long. */
export function range(now: Date, offset: number, nights: number): string {
  const a = new Date(now.getTime() + offset * 86_400_000), b = new Date(a.getTime() + nights * 86_400_000);
  const left = `${MON[a.getUTCMonth()]} ${a.getUTCDate()}`;
  return a.getUTCMonth() === b.getUTCMonth() ? `${left} to ${b.getUTCDate()}` : `${left} to ${MON[b.getUTCMonth()]} ${b.getUTCDate()}`;
}

const LINK = /tinyurl\.com\/Stay-at-Cascade/;
const m = (say: string, lang: Reg = 'en', extra: Partial<GoldenTurn> = {}): GoldenTurn => ({ say, kind: 'model', lang, ...extra });

// Golden run 6: today + 40 had filled up with a real booking, so the open-date cases tested the reserved path. Pass
// GOLDEN_OPEN_FROM="2026-11-02" (the first day of 15 open nights, from a read-only calendar query) to pin them.
// ---- SPEC-32 s7 (REVIEW-bot-2026-09-26): the payment path after the QR. Flow lines are Lloyd's, frozen: only R2/R9 and
// the case's own checks apply to them. `effects` is what the probe recorded - a card raised, a QR with the amount.
const PAY = 'Ben Munez 09171234567 ben@example.com';
const f = (say: string, lang: Reg, extra: Partial<GoldenTurn> = {}): GoldenTurn => ({ say, kind: 'flow', lang, ...extra });
const img = (kind: Kind, lang: Reg, extra: Partial<GoldenTurn> = {}): GoldenTurn => ({ say: '', image: true, kind, lang, ...extra });
export function paymentCases(d2: string, d3: string): GoldenCase[] {
  const fee = (): GoldenTurn[] => [f(`Hi, is ${d2} available? 2 adults`, 'en'), f('yes', 'en'), f(PAY, 'en'),
    f('fee', 'en', { must: [/24 hours/, /0956 011 5744/, /₱1,691/, /receipt/], mustNot: [LINK, /(?:receipt[\s\S]*){2}/], effects: [/"fx":"submit"/, /"qr"[^}]*1691/] })];
  const full = (): GoldenTurn[] => [f(`Available po ba ang ${d3}? 2 kami`, 'tl'), f('opo', 'tl'), f(PAY, 'tl'),
    f('full', 'tl', { must: [/₱5,073/, /₱1,000/, /\bpo\b/], mustNot: [LINK, /balance/, /near|Malapit na|Duol na/], effects: [/"qr"[^}]*5073/] })];
  const cases: Array<[string, GoldenTurn[]]> = [
    ['pay-fee-en', fee()],
    ['pay-full-tl', full()],
    ['pay-receipt-en', [...fee(), img('flow', 'en', { must: [/received your receipt|receipt is with us/], mustNot: [LINK], effects: [/"fx":"receipt"/] })]],
    ['pay-paid-question-tl', [...full(), img('flow', 'tl'), f('Paid na po, received niyo na po ba?', 'tl', { must: [/^(Opo|Yes)/, /receipt/], mustNot: [LINK, /personally verify/], effects: [/"handoff"[^}]*payment/] })]],
    ['pay-maya-question-en', [...fee(), { say: 'Can I use Maya instead of GCash?', kind: 'midflow', lang: 'en', must: [/QR|Maya/], mustNot: [LINK, /arrange the booking|on our site|\bconfirmed\b/] }]],
    ['pay-question-mid-hold-en', [...fee(), { say: 'Is there parking?', kind: 'midflow', lang: 'en', must: [/parking/i], mustNot: [LINK, /arrange the booking/] }]],
    ['pay-cancel-mid-hold-en', [...fee(), { say: 'cancel po, change of plans', kind: 'code', lang: 'en', must: [/release the hold/], mustNot: [LINK, /we'?ll cancel|cancelled for you/], effects: [/"handoff"[^}]*cancellation/] }]],
    ['pay-hold-expired-tl', [...full(), img('code', 'tl', { advance_minutes: 1500, must: [/ima-match|i-match|match it/], mustNot: [LINK], effects: [/"handoff"[^}]*payment/] })]],
    // The s3 rule wants payment talk (or a booking) before a photo counts as a receipt: a photo after "Hi" alone is
    // anything at all, and keeps the brochure. So this case says it paid first (SPEC-32 s7's 'Hi' + photo contradicted s3).
    ['pay-receipt-no-booking-en', [{ say: 'Hi', kind: 'model', lang: 'en' }, { say: 'I sent the GCash payment for my stay', kind: 'handoff', lang: 'en', noInvite: true },
      img('code', 'en', { must: [/match it to your booking/], mustNot: [LINK], effects: [/"handoff"[^}]*payment/] })]],
    // D-258 (Lloyd 2026-09-26): "when they ask to pay, give them gcash qr" - the QR goes with one line, the name once,
    // no promise of a later QR; in Taglish, English with one "po".
    ['pay-how-first-en', [{ say: 'Hi', kind: 'model', lang: 'en' }, { say: 'How do I pay?', kind: 'code', lang: 'en',
      must: [/QR below/, /check-in and check-out dates/], mustNot: [LINK, /will send you a QR/i], effects: [/"fx":"qr"/] }]],
    ['pay-how-offer-tl', [f(`Available po ba ang ${d3}? 2 kami`, 'tl'), { say: 'paano po magbayad?', kind: 'code', lang: 'tl',
      must: [/QR below/, /\bpo\b/], mustNot: [LINK, /will send you a QR/i], effects: [/"fx":"qr"/] }]],
  ];
  return cases.map(([id, turns]) => ({ id, group: 'payment', turns }));
}

export function goldenCases(now = new Date(), bookedRange: string | null = null, turnoverDay: string | null = null, openFrom: Date | null = null, soonRange: string | null = null): GoldenCase[] {
  const base = openFrom ?? now, o = openFrom ? 0 : 40;
  const d2 = range(base, o, 2), d3 = range(base, o + 7, 3), d1 = range(base, o + 14, 1);
  const cases: GoldenCase[] = [
    // ---- first contact: the link is there, under a both-routes sentence; greeting once; answer first
    { id: 'first-greeting-en', group: 'first', turns: [m('Good evening', 'en', { must: [LINK, /thank you for reaching out/i] })] },
    { id: 'first-greeting-tl', group: 'first', turns: [m('Hello po, good evening', 'en', { must: [LINK] })] }, // an English greeting with a courtesy "po" is English (Lloyd 2026-09-13)
    { id: 'first-rate-en', group: 'first', turns: [m('How much per night?', 'en', { must: [LINK, /1,780/, /thank you for reaching out/i] })] },
    { id: 'first-rate-tl', group: 'first', turns: [m('Hm po per night?', 'tl', { must: [LINK, /1,780/] })] },
    { id: 'first-avail-en', group: 'first', turns: [{ say: `Hi, is ${d2} available? We're 2 adults`, kind: 'flow', lang: 'en', must: [/thank you for reaching out/i, /1,691/, /set the dates aside/i], mustNot: [LINK, /reservation fee|50%/i] }] },
    { id: 'first-avail-tl', group: 'first', turns: [{ say: `Available po ba ang ${d2}? 2 po kami`, kind: 'flow', lang: 'tl', must: [/Salamat sa pag-message/i, /1,691/, /I-set na po/i], mustNot: [LINK, /reservation fee|50%/i] }] },
    { id: 'first-location-en', group: 'first', turns: [m('location', 'en', { must: [LINK, /Bria Homes/i, /thank you for reaching out/i] })] },
    { id: 'first-howtobook-en', group: 'first', turns: [m('How do I book?', 'en', { must: [LINK, /thank you for reaching out/i] })] },
    // SPEC-28 section 2: dates AND a question in the first message - both answered, one greeting (R7)
    { id: 'first-avail-and-amenity-en', group: 'first', turns: [{ say: `Hi, is ${range(base, o + 2, 2)} open? Is there wifi?`, kind: 'midflow', lang: 'en', must: [/wi-?fi/i, /(open|available|free)/i], mustNot: [new RegExp(`${range(base, o + 2, 2)}[\\s\\S]*${range(base, o + 2, 2)}`), /\b(those|the|your) dates (are|is) (open|available|free)\b/i] }] }, // the dates once (golden 2026-09-25 said them twice)
    { id: 'first-bisaya-gets-taglish', group: 'register', turns: [{ say: `Naa bay bakante ${d2}?`, kind: 'flow', lang: 'tl', must: [/Salamat sa pag-message/i], mustNot: [LINK] }] },

    // ---- follow-ups: warm, no greeting, no re-ask, at most one invitation
    { id: 'fu-amenity-en', group: 'followup', turns: [m('Hi, do you have wifi?'), m('Is there a kitchen too?', 'en', { must: [/induction|kitchen/i] })] },
    { id: 'fu-amenity-with-dates-en', group: 'followup', turns: [{ say: `Hi! Is ${d2} open? 2 guests`, kind: 'flow', lang: 'en' }, { say: 'and is there wifi?', kind: 'midflow', lang: 'en', must: [/wi-?fi/i] }] },
    { id: 'fu-rate-3-nights-tl', group: 'followup', turns: [m('Hello po', 'en'), m('magkano po kung 3 nights?', 'tl', { must: [/1,691/, /5,073/] })] }, // D-245: English or Taglish both pass
    { id: 'fu-parking-en', group: 'followup', turns: [{ say: `Hello, is ${d3} available?`, kind: 'flow', lang: 'en' }, { say: 'Is there parking?', kind: 'midflow', lang: 'en', must: [/parking|park/i, /gated|camera|CCTV/i] }] },
    { id: 'fu-early-no-dates-en', group: 'followup', turns: [m('Hi there'), { say: 'Can we check in early, around 9am?', kind: 'code', lang: 'en', mustNot: [/complimentary|confirmed|free of charge/i] }] },
    { id: 'fu-early-with-dates-en', group: 'followup', turns: [{ say: `Hi, is ${d2} available for 2?`, kind: 'flow', lang: 'en' }, { say: 'Can we check in at 10am on the first day?', kind: 'midflow', lang: 'en' }] },
    { id: 'fu-capacity-4-adults-en', group: 'followup', turns: [m('Hello'), m('Can 4 adults stay?', 'en', { must: [/3 adults/i] })] },
    { id: 'fu-transactional-en', group: 'followup', turns: [m('Hi'), m('GCash ok?', 'en', { must: [/gcash/i] })] },
    { id: 'fu-reviews-tl', group: 'followup', turns: [m('Hi po', 'en'), m('Legit po ba? May reviews?', 'tl', { must: [/4\.98|Airbnb/i] })] },
    { id: 'fu-discount-tl', group: 'followup', turns: [m('Hello po', 'en'), m('May discount po ba?', 'tl', { must: [LINK] })] },
    { id: 'fu-think-about-it-en', group: 'followup', turns: [m('Hi, how much per night for 2 guests?'), m('ok let me think about it first', 'en', { must: [LINK], mustNot: [/no pressure/i] })] },
    { id: 'fu-thanks-en', group: 'followup', turns: [m('Hi, do you have wifi?'), { say: 'thank you!', kind: 'code', lang: 'en' }] },
    { id: 'fu-ok-salamat-tl', group: 'followup', turns: [m('Hello po, may parking po ba?', 'tl'), { say: 'ok po salamat', kind: 'code', lang: 'tl' }] },
    { id: 'fu-two-closers-en', group: 'followup', turns: [m('Hi, do you have wifi?'), { say: 'thanks', kind: 'code', lang: 'en' }, { say: 'ok', kind: 'code', lang: 'en' }] },
    { id: 'fu-bot-en', group: 'followup', turns: [m('Hi'), { say: 'are you a bot?', kind: 'code', lang: 'en', must: [/digital concierge/i, /Marifel/] }] },
    { id: 'fu-pets-en', group: 'handoff', turns: [m('Hi'), { say: 'Can we bring our small dog?', kind: 'handoff', lang: 'en', noInvite: true }] },

    // ---- register: Taglish on the first Bisaya turn, Bislish from the second, never "po" in Bislish
    { id: 'reg-bisaya-three-turns', group: 'register', turns: [m('Maayong buntag, naa bay parking?', 'tl'), m('Pila ka tawo max?', 'bis', { must: [/3 adults/i] }), m('Naa bay wifi ug kitchen?', 'bis')] },
    { id: 'reg-bot-bis', group: 'register', turns: [m('Maayong gabii, naa bay wifi?', 'tl'), m('Pila ang rate kada gabii?', 'bis', { must: [/1,780/] }), { say: 'bot ba ni?', kind: 'code', lang: 'bis', must: [/digital concierge/i] }] },
    { id: 'reg-english-po', group: 'register', turns: [m('how far from SM po?', 'en', { must: [LINK, /km|kilomet|minute/i] })] },

    // ---- book flow: Lloyd's approved lines are frozen; the model's mid-flow answer is the answer only, the card once
    { id: 'flow-question-at-confirm-en', group: 'flow', turns: [
      { say: `I'd like to book ${d2} for 2 adults`, kind: 'flow', lang: 'en' },
      { say: 'yes', kind: 'flow', lang: 'en' },
      { say: 'Ben Munez 09171234567 ben@example.com', kind: 'flow', lang: 'en' },
      { say: 'Is there parking?', kind: 'midflow', lang: 'en', must: [/park/i], mustNot: [/(📅[\s\S]*){2}/] },
    ] },
    // SPEC-14 (D-184): the offer is answered yes, declined, or met by the 48-hour rule
    { id: 'flow-offer-yes-en', group: 'flow', turns: [
      { say: `Hi, is ${d2} available? 2 adults`, kind: 'flow', lang: 'en', must: [/thank you for reaching out/i, /1,691/, /set the dates aside/i], mustNot: [LINK] },
      { say: 'yes', kind: 'flow', lang: 'en', must: [/name for the reservation/i] },
      { say: 'ben munez', kind: 'flow', lang: 'en', must: [/mobile number/i] },
      { say: '09171234567 ben@example.com', kind: 'flow', lang: 'en', must: [/👤 Ben Munez/, /🔐/, /"fee" or "full"/] },
    ] },
    { id: 'flow-offer-no-en', group: 'flow', turns: [
      { say: `Hello, is ${d3} available? 2 adults`, kind: 'flow', lang: 'en', must: [/set the dates aside/i] },
      { say: 'not now', kind: 'flow', lang: 'en', must: [/send your dates again/i], mustNot: [LINK] },
    ] },
    { id: 'flow-cancel-tl', group: 'flow', turns: [{ say: `Pa-book po ${d1}, 2 po kami`, kind: 'flow', lang: 'tl' }, { say: 'cancel po', kind: 'flow', lang: 'tl', mustNot: [LINK] }] },

    // ---- handoffs: warmth and a person, nothing to click
    { id: 'handoff-complaint-en', group: 'handoff', turns: [{ say: 'Hi, we checked in yesterday and the aircon is not working', kind: 'handoff', lang: 'en', noInvite: true }] },
    { id: 'handoff-payment-en', group: 'handoff', turns: [{ say: 'I already sent the GCash payment, please confirm', kind: 'handoff', lang: 'en', noInvite: true }] },
    { id: 'handoff-refund-en', group: 'handoff', turns: [{ say: 'We need to cancel our booking next week, can we get a refund?', kind: 'handoff', lang: 'en', noInvite: true }] },
    ...paymentCases(d2, d3),
  ];
  // A taken range needs a night that is really booked: pass GOLDEN_BOOKED="Oct 3 to 5" from a read-only calendar query.
  if (bookedRange) cases.push({ id: 'first-avail-taken-en', group: 'first', turns: [m(`Hello, is ${bookedRange} available?`, 'en', { kind: 'code', // SPEC-28: code writes this reply
      must: [/reserved|booked|taken/i, /nearest open dates/i], mustNot: [new RegExp(`${bookedRange.split(' to ')[0]}[^.\\n]{0,40}\\bis (open|available)\\b`, 'i')] })] });
  // Lloyd 2026-09-17: on a day another guest checks out, the 12 noon check-in is never offered. Needs a real turnover day:
  // pass GOLDEN_TURNOVER="Oct 5" (a checkout_date from a read-only calendar query whose night is still open).
  // SPEC-14 (D-184) + the 2026-09-18 policy: the full-payment rule needs a stay that is REALLY open inside 5 days
  // (2026-09-18: tomorrow night was an airbnb booking). Pass GOLDEN_SOON="Sep 20 to 21"
  // from a read-only calendar query; without it the case is skipped and booking.test.ts carries the rule.
  if (soonRange) cases.push({ id: 'flow-offer-fullnow-en', group: 'flow', turns: [
    { say: `Hi, is ${soonRange} available? 2 adults`, kind: 'flow', lang: 'en', must: [/less than five days away/i] },
    { say: 'yes', kind: 'flow', lang: 'en', must: [/name for the reservation/i] },
    { say: 'Ben Munez 09171234567 ben@example.com', kind: 'flow', lang: 'en', must: [/full ₱/], mustNot: [/"fee" or "full"/] },
  ] });
  if (turnoverDay) cases.push({ id: 'first-noon-checkin-on-turnover-day-tl', group: 'first', turns: [m(`Hello po, available po ba ang ${turnoverDay}? Pwede po ba check in 12 noon?`, 'tl', { must: [/2(:00)? ?PM/i], mustNot: [/complimentary|no extra cost|free early|welcome to check in (from|at) 12/i] })] });
  return cases;
}
