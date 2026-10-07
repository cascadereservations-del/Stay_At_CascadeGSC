// Voice close-out (2026-09-17): the golden conversations. DATA ONLY. Each one runs on a fresh probe: thread (a long
// thread poisons itself: the model copies its own earlier turns), is scored by golden-score.ts on every reply, and
// passes when three runs out of three pass. Dates are computed from today, so the set does not rot.
// A wording wish after the freeze becomes ONE new case here plus one example in facts.ts (protocol 10 section 8).
import type { Kind, Reg } from './golden-score.ts';
import { quote, SEED_CARD, type RateCard } from '../_shared/cascade-core/pricing.ts';

export type GoldenTurn = { say: string; kind: Kind; lang: Reg; noInvite?: boolean; must?: RegExp[]; mustNot?: RegExp[]; image?: boolean;
  /** SPEC-32 s7: minutes the probe clock moves before this turn (default 1), and the effects it must record. */
  advance_minutes?: number; effects?: RegExp[] };
export type GoldenCase = { id: string; group: 'first' | 'followup' | 'register' | 'flow' | 'handoff' | 'payment' | 'promo'; turns: GoldenTurn[] };

/** SPEC-34 (D-262): while a promotion is at least 5 days out (so no case meets the full-payment rule), a stay fully
 *  inside it and one straddling its last night, as a flow and as a free question, en and tl. PHP 1,929 never appears. */
/** s73 F8 (golden 2026-10-06: the promo nights filled with real bookings, so both flow cases tested the reserved path): with
 *  `booked` (the calendar's taken nights, golden-run.ts reads them) the inside case takes the first open three nights of the
 *  promotion, and a flow case with no open window is left out. Without it the windows stay as before. */
export function promoCases(card: RateCard, now = new Date(), booked: Set<string> | null = null): GoldenCase[] {
  const out: GoldenCase[] = [];
  const day = (d: string, k: number) => new Date(Date.parse(d + 'T00:00:00Z') + k * 86_400_000);
  const iso = (d: Date) => d.toISOString().slice(0, 10);
  const open = (from: Date) => [0, 1, 2].every((k) => !booked?.has(iso(day(iso(from), k))));
  for (const p of card.promotions) {
    if (day(p.first_night, 1).getTime() < now.getTime() + 5 * 86_400_000) continue;
    let k = 1;
    while (day(p.first_night, k + 2) <= day(p.last_night, 0) && !open(day(p.first_night, k))) k++;
    const inStart = day(p.first_night, k), inOpen = day(p.first_night, k + 2) <= day(p.last_night, 0) && open(inStart), stOpen = open(day(p.last_night, -1));
    const inside = range(inStart, 0, 3), straddle = range(day(p.last_night, -1), 0, 3);
    const inQ = quote(card, iso(inStart), iso(day(iso(inStart), 3)));
    const stQ = quote(card, day(p.last_night, -1).toISOString().slice(0, 10), day(p.last_night, 2).toISOString().slice(0, 10));
    const pr = new RegExp(p.nightly_rate.toLocaleString('en-US')), base = new RegExp(card.base.toLocaleString('en-US')), no = [/1,929/];
    const tot = (v: number) => new RegExp(v.toLocaleString('en-US'));
    if (inOpen) out.push({ id: 'promo-inside-flow-en', group: 'promo', turns: [{ say: `Hi, is ${inside} available? 2 adults`, kind: 'flow', lang: 'en', must: [new RegExp(p.name), pr, base, tot(inQ.total), /hold (that night|those dates) for you/i], mustNot: no }] });
    if (stOpen) out.push({ id: 'promo-straddle-flow-tl', group: 'promo', turns: [{ say: `Available po ba ang ${straddle}? 2 kami`, kind: 'flow', lang: 'tl', must: [pr, tot(stQ.total), tot(stQ.tier_rate)], mustNot: no }] });
    if (stOpen) out.push({ id: 'promo-rate-dated-en', group: 'promo', turns: [m(`How much would ${straddle} cost?`, 'en', { must: [tot(stQ.total), pr], mustNot: no })] }); // R2-8: same nights
    out.push(
      // D-311.1 / D-311.7 (Lloyd 2026-10-07): the live promotion AND "booking direct is the better price", every language; a plain
      // promo question is never forwarded to the host, and the Taglish reply never says "automated".
      { id: 'promo-ask-en', group: 'promo', turns: [m('Do you have any promo this month or next?', 'en', { must: [pr, new RegExp(p.name, 'i'), DIRECT], mustNot: [...no, /\bno (current |ongoing )?promo/i, HOST] })] },
      { id: 'promo-ask-tl', group: 'promo', turns: [m('May promo po ba kayo ngayong October?', 'tl', { must: [pr, DIRECT], mustNot: [...no, /walang promo/i, HOST, /\bautomat(ed|ic)/i] })] },
    );
  }
  return out;
}

const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** "Oct 27 to 29" / "Oct 30 to Nov 1", `offset` days from `now`, `nights` long. */
export function range(now: Date, offset: number, nights: number): string {
  const a = new Date(now.getTime() + offset * 86_400_000), b = new Date(a.getTime() + nights * 86_400_000);
  const left = `${MON[a.getUTCMonth()]} ${a.getUTCDate()}`;
  return a.getUTCMonth() === b.getUTCMonth() ? `${left} to ${b.getUTCDate()}` : `${left} to ${MON[b.getUTCMonth()]} ${b.getUTCDate()}`;
}

const LINK = /tinyurl\.com\/Stay-at-Cascade/;
/** D-311.1: booking direct is itself the better price; D-311.6/.7: the host line, which a plain promo question never gets. */
const DIRECT = /lower than (?:on )?Airbnb|kaysa sa Airbnb|other booking apps|ibang booking apps/i, HOST = /Our host also looks/;
// SPEC-39 (D-299.10, D-300.1-5): the first message is signed and carries no link or introduction; the site comes only when asked for.
const AIRBNB_LINK = /airbnb\.com\/h\/cascadesgsc/, SIG = /Cassy, Cascade Concierge$/m, NO_SIG = /Cassy, Cascade Concierge/, TWO_Q = /(\?[\s\S]*){2}/;
const DATES_Q = /which dates|dates are you looking at/i, INTRO = /\bI'?m Cassy\b|digital concierge/i;
/** A first reply to a prospect (D-299.10): signed, the dates asked once, "delighted", no link, no introduction. */
const FIRST = { must: [SIG, DATES_Q, /delighted/i], mustNot: [LINK, TWO_Q, INTRO] };
const first = (say: string, lang: Reg, must: RegExp[] = [], mustNot: RegExp[] = []): GoldenTurn => m(say, lang, { must: [...FIRST.must, ...must], mustNot: [...FIRST.mustNot, ...mustNot] });
const m = (say: string, lang: Reg = 'en', extra: Partial<GoldenTurn> = {}): GoldenTurn => ({ say, kind: 'model', lang, ...extra });

// Golden run 6: today + 40 had filled up with a real booking, so the open-date cases tested the reserved path. Pass
// GOLDEN_OPEN_FROM="2026-11-02" (the first day of 15 open nights, from a read-only calendar query) to pin them.
// ---- SPEC-32 s7 (REVIEW-bot-2026-09-26): the payment path after the QR. Flow lines are Lloyd's, frozen: only R2/R9 and
// the case's own checks apply to them. `effects` is what the probe recorded - a card raised, a QR with the amount.
const PAY = 'Ben Munez 09171234567 ben@example.com';
const f = (say: string, lang: Reg, extra: Partial<GoldenTurn> = {}): GoldenTurn => ({ say, kind: 'flow', lang, ...extra });
const img = (kind: Kind, lang: Reg, extra: Partial<GoldenTurn> = {}): GoldenTurn => ({ say: '', image: true, kind, lang, ...extra });
export function paymentCases(d2: string, d3: string): GoldenCase[] {
  // SPEC-39 3.6b (D-300.3): the details turn opens the hold and sends the card, the payment and the amount QR together;
  // "fee" is no longer a step (no second QR), "full" swaps the QR and shows no second card.
  const NO_QR = /^(?![\s\S]*"qr")/;
  const fee = (): GoldenTurn[] => [f(`Hi, is ${d2} available? 2 adults`, 'en'), f('yes', 'en'),
    f(PAY, 'en', { must: [/0956 011 5744/, /24 hours/, /receipt/, /reference/, /₱1,691/], mustNot: [LINK, /fee" or "full/, /(?:receipt[\s\S]*){2}/], effects: [/"fx":"submit"/, /"qr"[^}]*1691/] }),
    f('fee', 'en', { must: [/already carries|nothing more to choose/], mustNot: [LINK], effects: [NO_QR] })];
  const full = (): GoldenTurn[] => [f(`Available po ba ang ${d3}? 2 kami`, 'tl'), f('opo', 'tl'),
    f(PAY, 'tl', { mustNot: [LINK, /fee" o "full/], effects: [/"fx":"submit"/, /"qr"[^}]*2537/] }),
    f('full', 'tl', { must: [/₱5,073/, /₱1,000/, /\bpo\b/], mustNot: [LINK, /balance/, /near|Malapit na|Duol na/, /Ito po ang details/], effects: [/"qr"[^}]*5073/] })];
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
    // SPEC-39 3.6b: the nudge follows the guest's tone - brisk (short, plain turns), gentle (a first-timer, a trust question)
    ['pay-brisk-en', [f(`${d2} available? 2`, 'en'), f('yes', 'en'), f('Maria Santos 09171234567 m@example.com', 'en', { must: [/holds these dates/, /quick "full"/], mustNot: [/delighted|No rush/, LINK], effects: [/"fx":"submit"/, /"qr"/] })]],
    ['pay-gentle-en', [{ say: `Hi, is ${d2} available for 2? first time booking online, is it safe?`, kind: 'midflow', lang: 'en' }, f('yes', 'en'),
      f(PAY, 'en', { must: [/No rush at all/, /Marifel and the team/], mustNot: [/quick "full"/, LINK], effects: [/"fx":"submit"/, /"qr"/] })]],
  ];
  return cases.map(([id, turns]) => ({ id, group: 'payment', turns }));
}

/** D-286 (live read 2026-09-30, Suzanne's three questions): the frame faults - intro and answer in one paragraph, the name
 *  twice, two closes, a "prepared before you arrive" close to a prospect - in en, tl and bis. D-311.8 (Lloyd 2026-10-07):
 *  a Bisaya guest gets ENGLISH on every turn (it was Taglish, then Bislish - D-172 retired), so the bis cases are scored as
 *  English. The month total accepts 28 or 30 nights at PHP 1,335: the design read 28, stayAnchor (D-269) says a month is 30. */
export function s63Cases(): GoldenCase[] {
  const MONTH = [/1,335/, /37,380|40,050/], ONCE = /(\bBen\b[\s\S]*){2}/, DIGIT_P1 = /^(?:(?!\n\s*\n)[\s\S])*\d/;
  const CLOSE_TWICE = /we'?re here[\s\S]*(preferred dates|we'?d be glad)|(preferred dates|we'?d be glad)[\s\S]*we'?re here/i, PREPARED = /prepared (for|before) (you |your )?arriv/i;
  const party = (say: string, lang: Reg): GoldenTurn => ({ say, kind: 'handoff', lang, noInvite: true, must: [/quiet/i], effects: [/"handoff"[^}]*policy_exception/] });
  const bisOpen = m('Maayong buntag, naa bay parking?', 'en', { mustNot: [/\bpo\b/] });
  return [
    { id: 's63-month-en', group: 'followup', turns: [m('How much for a month-long stay?', 'en', { must: MONTH, mustNot: [DIGIT_P1, ONCE] })] },
    { id: 's63-month-tl', group: 'followup', turns: [m('Magkano po for a month-long stay?', 'tl', { must: MONTH, mustNot: [DIGIT_P1, ONCE] })] },
    { id: 's63-month-bis', group: 'followup', turns: [bisOpen, m('Pila ang bayad kung usa ka bulan mi mag-stay?', 'en', { must: MONTH })] },
    { id: 's63-deposit-en', group: 'followup', turns: [m('How much for a month-long stay?', 'en', { must: MONTH }), m('No security deposit for a month stay?', 'en', { must: [/1,000/], mustNot: [PREPARED, CLOSE_TWICE] })] },
    { id: 's63-deposit-tl', group: 'followup', turns: [m('Magkano po for a month-long stay?', 'tl', { must: MONTH }), m('Wala po bang security deposit pag isang buwan?', 'tl', { must: [/1,000/], mustNot: [PREPARED, CLOSE_TWICE] })] },
    { id: 's63-deposit-bis', group: 'followup', turns: [bisOpen, m('Pila ang bayad kung usa ka bulan mi mag-stay?', 'en', { must: MONTH }), m('Wala bay security deposit kung usa ka bulan?', 'en', { must: [/1,000/], mustNot: [PREPARED, CLOSE_TWICE] })] },
    { id: 's63-party-en', group: 'handoff', turns: [party('Is party allowed?', 'en')] },
    { id: 's63-party-tl', group: 'handoff', turns: [party('Pwede po ba mag-party?', 'tl')] },
    { id: 's63-party-bis', group: 'handoff', turns: [bisOpen, party('Pwede ba mi mag-party diri?', 'en')] },
  ];
}

export function goldenCases(now = new Date(), bookedRange: string | null = null, turnoverDay: string | null = null, openFrom: Date | null = null, soonRange: string | null = null, bookedNights: Set<string> | null = null): GoldenCase[] {
  const base = openFrom ?? now, o = openFrom ? 0 : 40;
  // SPEC-39 first-until-en: this month's end in Manila, and a check-out 30 nights after it (computed, so the case never rots)
  const manila = new Date(now.getTime() + 8 * 3_600_000), monthEnd = new Date(Date.UTC(manila.getUTCFullYear(), manila.getUTCMonth() + 1, 0));
  const untilEnd = new Date(monthEnd.getTime() + 30 * 86_400_000);
  const d2 = range(base, o, 2), d3 = range(base, o + 7, 3), d1 = range(base, o + 14, 1);
  const cases: GoldenCase[] = [
    // ---- first contact: the link is there, under a both-routes sentence; greeting once; answer first
    // SPEC-39 (D-299.10): the first reply carries NO link and no introduction; it asks for the dates and is signed. The
    // turn-1 link assertions of SPEC-14 are flipped here on purpose (record the flip case by case in the AFTER note).
    { id: 'first-greeting-en', group: 'first', turns: [first('Good evening', 'en', [/thank you for reaching out/i])] },
    { id: 'first-greeting-tl', group: 'first', turns: [m('Hello po, good evening', 'en', { must: [SIG], mustNot: [LINK] })] }, // an English greeting with a courtesy "po" is English (Lloyd 2026-09-13)
    { id: 'first-rate-en', group: 'first', turns: [first('How much per night?', 'en', [/1,780/, /thank you for reaching out/i])] },
    { id: 'first-rate-tl', group: 'first', turns: [m('Hm po per night?', 'tl', { must: [/1,780/, SIG], mustNot: [LINK] })] },
    { id: 'first-avail-en', group: 'first', turns: [{ say: `Hi, is ${d2} available? We're 2 adults`, kind: 'flow', lang: 'en', must: [/thank you for reaching out/i, /1,691/, /hold (that night|those dates) for you/i, /delighted/i, SIG], mustNot: [LINK, /reservation fee|50%/i, /digital concierge/i] }] },
    { id: 'first-avail-tl', group: 'first', turns: [{ say: `Available po ba ang ${d2}? 2 po kami`, kind: 'flow', lang: 'tl', must: [/Salamat sa pag-message/i, /1,691/, /I-hold na po/i, /delighted/i, SIG], mustNot: [LINK, /reservation fee|50%/i, /digital concierge/i] }] },
    { id: 'first-location-en', group: 'first', turns: [first('location', 'en', [/Bria Homes/i, /thank you for reaching out/i])] },
    // D-311.3 (Lloyd 2026-10-07): asking for the dates and guests IS the answer here (golden-score R1 accepts it); the link answers on turn 2 (fu-howtobook-en)
    { id: 'first-howtobook-en', group: 'first', turns: [first('How do I book?', 'en', [/thank you for reaching out/i])] },
    // SPEC-39 4.1 / 3.1: a two-month inquiry gets the code's 60-night total and the dates question (live 2026-10-04, T1)
    { id: 'first-two-months-en', group: 'first', turns: [m('Hello, can I ask for details regarding our booking good for two months?', 'en', { must: [/1,335/, /80,100/, /106,800/, DATES_Q, SIG], mustNot: [LINK, /\bper night\b[\s\S]*\bper night\b/] })] },
    { id: 'first-two-months-tl', group: 'first', turns: [m('Hello po, pwede po magtanong about sa booking for two months?', 'tl', { must: [/1,335/, /80,100/, /kailan|dates/i, SIG], mustNot: [LINK] })] },
    // SPEC-39 3.4: a vague first message - one warm sentence and the dates question
    { id: 'first-vague-en', group: 'first', turns: [m('Hi, inquire', 'en', { must: [DATES_Q, SIG], mustNot: [LINK, TWO_Q] })] },
    // SPEC-39 4.2 (live T3): "end of this month until <date>" is that month-end to the date, never "the night of <date>"
    { id: 'first-until-en', group: 'first', turns: [{ say: `Is it available by end of this month until ${MON[untilEnd.getUTCMonth()]} ${untilEnd.getUTCDate()}?`, kind: 'flow', lang: 'en', must: [new RegExp(`${MON[monthEnd.getUTCMonth()]} ${monthEnd.getUTCDate()} to`), /(open|available|reserved)/i, SIG], mustNot: [/night of/i, /how many nights/i, LINK] }] },
    // SPEC-28 section 2: dates AND a question in the first message - both answered, one greeting (R7)
    { id: 'first-avail-and-amenity-en', group: 'first', turns: [{ say: `Hi, is ${range(base, o + 2, 2)} open? Is there wifi?`, kind: 'midflow', lang: 'en', must: [/wi-?fi/i, /(open|available|free)/i], mustNot: [new RegExp(`${range(base, o + 2, 2)}[\\s\\S]*${range(base, o + 2, 2)}`), /\b(those|the|your) dates (are|is) (open|available|free)\b/i] }] }, // the dates once (golden 2026-09-25 said them twice)
    // D-311.8 (Lloyd 2026-10-07): renamed from first-bisaya-gets-taglish - a Bisaya guest now gets the English flow lines.
    { id: 'first-bisaya-gets-english', group: 'register', turns: [{ say: `Naa bay bakante ${d2}?`, kind: 'flow', lang: 'en', must: [/thank you for reaching out/i], mustNot: [LINK, /Salamat sa pag-message/i, /\bpo\b/] }] },

    // ---- follow-ups: warm, no greeting, no re-ask, at most one invitation
    { id: 'fu-amenity-en', group: 'followup', turns: [m('Hi, do you have wifi?'), m('Is there a kitchen too?', 'en', { must: [/induction|kitchen/i], mustNot: [LINK] })] },
    // SPEC-39 4.4 (live T5): "2 adults with 1 kid" is three guests
    { id: 'flow-family-en', group: 'flow', turns: [{ say: `Hi, is ${d2} available?`, kind: 'flow', lang: 'en' }, { say: 'We are 2 adults with 1 kid only.', kind: 'flow', lang: 'en', must: [/3 guests|family of three/i, /1,691/] },
      { say: 'yes', kind: 'flow', lang: 'en', must: [/full name|name for the reservation/i] }] },
    // SPEC-39 3.8 (live T2): a thanks with a blessing is closed in code - no dates nudge, no link
    { id: 'fu-thanks-bless-en', group: 'followup', turns: [m('How much per night?', 'en', { mustNot: [LINK] }), { say: 'Thanks and God bless', kind: 'code', lang: 'en', must: [/pleasure|welcome/i], mustNot: [LINK, /preferred dates|which dates/i, NO_SIG] }] },
    // SPEC-39 3.8 (guest S, Sep 24): a yes to our own offer starts the flow; a flow started on turn 2 is not signed (D-300.1)
    { id: 'fu-chat-yes-en', group: 'followup', turns: [m(`Hi, how much for ${d2}?`), { say: 'Yes please', kind: 'flow', lang: 'en', must: [/hold (those dates|that night)|name for the reservation|full name|how many of you/i], mustNot: [NO_SIG] }] }, // s73 F5: no party given yet, so the flow's next ask is the guest count (SPEC-14)
    // D-311.6 (Lloyd 2026-10-07, replaces D-300.4's stay total): every discount or haggle request - we completely understand and
    // will do our best, NO rate explanation, then the host line and the hold question; no link
    { id: 'fu-objection-dated-en', group: 'followup', turns: [{ say: `Hi, is ${d3} available? 2 adults`, kind: 'flow', lang: 'en' },
      { say: 'can you do 1,500 a night?', kind: 'handoff', lang: 'en', must: [/completely understand/, /do our best to accommodate/, /Our host also looks/, new RegExp(`hold ${d3}[^?]*\\?`)], mustNot: [LINK, /PHP|₱|%/], effects: [/"handoff"[^}]*policy_exception/] }] },
    { id: 'fu-mahal-tl', group: 'followup', turns: [{ say: `Available po ba ${d3}? 2 kami`, kind: 'flow', lang: 'tl' },
      { say: 'medyo mahal po', kind: 'handoff', lang: 'tl', must: [/completely understand/, /Our host also looks/, /\?/, /\bpo\b/], mustNot: [LINK, /PHP|₱|%/], effects: [/"handoff"[^}]*policy_exception/] }] },
    // SPEC-39 D-300.2: the site only when asked for - never for a fact, once when asked to see the home, how to book, or reviews
    { id: 'fu-second-link-en', group: 'followup', turns: [m('Good evening', 'en', { mustNot: [LINK] }), m('Is there parking?', 'en', { must: [/parking/i], mustNot: [LINK, NO_SIG, /\bpo\b/] })] }, // D-311.5: no "po" in English
    { id: 'fu-photos-tl', group: 'followup', turns: [m('Hello po, available pa po ba this weekend?', 'tl', { mustNot: [LINK] }), m('may pictures po ba? gusto ko lang makita muna', 'tl', { must: [LINK, /photos|pictures/i], mustNot: [NO_SIG, TWO_Q] })] },
    // D-311.4: warmth and the two ways - this chat or the site link
    { id: 'fu-howtobook-en', group: 'followup', turns: [m('How much per night?', 'en', { mustNot: [LINK] }), m('How do I book?', 'en', { must: [LINK, /right here|in this chat|dito sa chat/i, /delighted|glad|welcom|look forward/i], mustNot: [NO_SIG] })] },
    { id: 'fu-reviews-en', group: 'followup', turns: [m('Hi, do you have wifi?', 'en', { mustNot: [LINK] }), m('Do you have reviews?', 'en', { must: [AIRBNB_LINK], mustNot: [NO_SIG] })] },
    { id: 'fu-amenity-with-dates-en', group: 'followup', turns: [{ say: `Hi! Is ${d2} open? 2 guests`, kind: 'flow', lang: 'en' }, { say: 'and is there wifi?', kind: 'midflow', lang: 'en', must: [/wi-?fi/i] }] },
    { id: 'fu-rate-3-nights-tl', group: 'followup', turns: [m('Hello po', 'en'), m('magkano po kung 3 nights?', 'tl', { must: [/1,691/, /5,073/] })] }, // D-245: English or Taglish both pass
    { id: 'fu-parking-en', group: 'followup', turns: [{ say: `Hello, is ${d3} available?`, kind: 'flow', lang: 'en' }, { say: 'Is there parking?', kind: 'midflow', lang: 'en', must: [/parking|park/i, /gated|camera|CCTV/i] }] },
    { id: 'fu-early-no-dates-en', group: 'followup', turns: [m('Hi there'), { say: 'Can we check in early, around 9am?', kind: 'code', lang: 'en', mustNot: [/complimentary|confirmed|free of charge/i] }] },
    { id: 'fu-early-with-dates-en', group: 'followup', turns: [{ say: `Hi, is ${d2} available for 2?`, kind: 'flow', lang: 'en' }, { say: 'Can we check in at 10am on the first day?', kind: 'midflow', lang: 'en' }] },
    // SPEC-41 2b (D-296.3): "leave the key card with the remotes" is a written check-out step.
    { id: 'fu-checkout-steps-en', group: 'followup', turns: [m('Hi'), m('What do I need to do before check out?', 'en', { must: [/key card/i, /remote/i, /12/], mustNot: [/!/] })] },
    { id: 'fu-checkout-steps-tl', group: 'followup', turns: [m('Hello po', 'en'), m('Ano po gagawin bago mag check out?', 'tl', { must: [/key card/i, /remote/i, /12/], mustNot: [/!/] })] },
    { id: 'fu-capacity-4-adults-en', group: 'followup', turns: [m('Hello'), m('Can 4 adults stay?', 'en', { must: [/3 adults/i] })] },
    { id: 'fu-transactional-en', group: 'followup', turns: [m('Hi'), m('GCash ok?', 'en', { must: [/gcash/i] })] },
    { id: 'fu-reviews-tl', group: 'followup', turns: [m('Hi po', 'en'), m('Legit po ba? May reviews?', 'tl', { must: [/4\.98|Airbnb/i] })] },
    { id: 'fu-discount-tl', group: 'followup', turns: [m('Hello po', 'en'), m('May discount po ba?', 'tl', { must: [/completely understand/, /host/i, /\?/], mustNot: [LINK, TWO_Q, /%|per night|PHP|₱|nakakatipid|makatipid/i] })] }, // SPEC-39 3.3: flipped from must LINK; D-311.6
    { id: 'fu-think-about-it-en', group: 'followup', turns: [m('Hi, how much per night for 2 guests?'), m('ok let me think about it first', 'en', { must: [LINK], mustNot: [/no pressure/i] })] },
    { id: 'fu-thanks-en', group: 'followup', turns: [m('Hi, do you have wifi?', 'en', { mustNot: [LINK] }), { say: 'thank you!', kind: 'code', lang: 'en', mustNot: [LINK] }] },
    { id: 'fu-ok-salamat-tl', group: 'followup', turns: [m('Hello po, may parking po ba?', 'tl', { mustNot: [LINK] }), { say: 'ok po salamat', kind: 'code', lang: 'tl', mustNot: [LINK] }] },
    { id: 'fu-two-closers-en', group: 'followup', turns: [m('Hi, do you have wifi?', 'en', { mustNot: [LINK] }), { say: 'thanks', kind: 'code', lang: 'en', mustNot: [LINK] }, { say: 'ok', kind: 'code', lang: 'en', mustNot: [LINK] }] },
    // D-300.5: short, honest, the people named
    { id: 'fu-bot-en', group: 'followup', turns: [m('Hi'), { say: 'are you a bot?', kind: 'code', lang: 'en', must: [/digital concierge/i, /AI assistant/, /Marifel/], mustNot: [/rates, dates, directions/, LINK] }] },
    { id: 'fu-pets-en', group: 'handoff', turns: [m('Hi'), { say: 'Can we bring our small dog?', kind: 'handoff', lang: 'en', noInvite: true }] },

    // ---- register: D-311.8 (Lloyd 2026-10-07) - a Bisaya guest gets English on every turn, never "po" (was Taglish, then Bislish)
    { id: 'reg-bisaya-three-turns', group: 'register', turns: [m('Maayong buntag, naa bay parking?', 'en'), m('Pila ka tawo max?', 'en', { must: [/3 adults/i] }), m('Naa bay wifi ug kitchen?', 'en')] },
    // R3: the short rate answer carries one warm clause (index.ts warmClause after the cold rewrite)
    { id: 'reg-bot-bis', group: 'register', turns: [m('Maayong gabii, naa bay wifi?', 'en'), m('Pila ang rate kada gabii?', 'en', { must: [/1,780/] }), { say: 'bot ba ni?', kind: 'code', lang: 'en', must: [/digital concierge/i, /AI assistant/, /Marifel/], mustNot: [/rates, dates, directions/, LINK] }] },
    { id: 'reg-english-po', group: 'register', turns: [first('how far from SM po?', 'en', [/km|kilomet|minute/i])] },

    // ---- book flow: Lloyd's approved lines are frozen; the model's mid-flow answer is the answer only, the card once
    { id: 'flow-question-at-confirm-en', group: 'flow', turns: [
      { say: `I'd like to book ${d2} for 2 adults`, kind: 'flow', lang: 'en' },
      { say: 'yes', kind: 'flow', lang: 'en' },
      { say: 'Ben Munez 09171234567 ben@example.com', kind: 'flow', lang: 'en' },
      { say: 'Is there parking?', kind: 'midflow', lang: 'en', must: [/park/i], mustNot: [/(📅[\s\S]*){2}/] },
    ] },
    // SPEC-14 (D-184): the offer is answered yes, declined, or met by the under-5-days full-payment rule
    // SPEC-39 3.6 / 3.7 (live T6, T7): the good night returned; "Ma." kept as typed and never the first name; "Can" never a name
    { id: 'flow-offer-yes-en', group: 'flow', turns: [
      { say: `Hi, is ${d2} available? 2 adults`, kind: 'flow', lang: 'en', must: [/thank you for reaching out/i, /1,691/, /hold (that night|those dates) for you/i, /delighted/i, SIG], mustNot: [LINK, /digital concierge/i] },
      { say: 'Yes and thank you, good night', kind: 'flow', lang: 'en', must: [/good night/i, /name for the reservation|full name/i], mustNot: [NO_SIG] },
      { say: 'Ma. Elizabeth Reyes 09171234567 You can reach me at ben@example.com', kind: 'flow', lang: 'en', must: [/👤 Ma\. Elizabeth Reyes/, /🔐/], mustNot: [/\bCan\b/, /\bMa,/, /fee" or "full/, NO_SIG], effects: [/"fx":"submit"/] },
    ] },
    { id: 'flow-offer-no-en', group: 'flow', turns: [
      { say: `Hello, is ${d3} available? 2 adults`, kind: 'flow', lang: 'en', must: [/hold (that night|those dates) for you/i] },
      { say: 'not now', kind: 'flow', lang: 'en', must: [/send your dates again/i], mustNot: [LINK] },
    ] },
    { id: 'flow-cancel-tl', group: 'flow', turns: [{ say: `Pa-book po ${d1}, 2 po kami`, kind: 'flow', lang: 'tl' }, { say: 'cancel po', kind: 'flow', lang: 'tl', mustNot: [LINK] }] },

    // ---- handoffs: warmth and a person, nothing to click
    { id: 'handoff-complaint-en', group: 'handoff', turns: [{ say: 'Hi, we checked in yesterday and the aircon is not working', kind: 'handoff', lang: 'en', noInvite: true }] },
    { id: 'handoff-payment-en', group: 'handoff', turns: [{ say: 'I already sent the GCash payment, please confirm', kind: 'handoff', lang: 'en', noInvite: true }] },
    { id: 'handoff-refund-en', group: 'handoff', turns: [{ say: 'We need to cancel our booking next week, can we get a refund?', kind: 'handoff', lang: 'en', noInvite: true }] },
    ...paymentCases(d2, d3),
    ...promoCases(SEED_CARD, now, bookedNights),
    ...s63Cases(),
  ];
  // A taken range needs a night that is really booked: pass GOLDEN_BOOKED="Oct 3 to 5" from a read-only calendar query.
  if (bookedRange) cases.push({ id: 'first-avail-taken-en', group: 'first', turns: [m(`Hello, is ${bookedRange} available?`, 'en', { kind: 'code', // SPEC-28: code writes this reply
      must: [/reserved|booked|taken/i, /nearest open (dates|night)/i, SIG], mustNot: [new RegExp(`${bookedRange.split(' to ')[0]}[^.\\n]{0,40}\\bis (open|available)\\b`, 'i'), LINK, /digital concierge/i] })] });
  // Lloyd 2026-09-17: on a day another guest checks out, the 12 noon check-in is never offered. Needs a real turnover day:
  // pass GOLDEN_TURNOVER="Oct 5" (a checkout_date from a read-only calendar query whose night is still open).
  // SPEC-14 (D-184) + the 2026-09-18 policy: the full-payment rule needs a stay that is REALLY open inside 5 days
  // (2026-09-18: tomorrow night was an airbnb booking). Pass GOLDEN_SOON="Sep 20 to 21"
  // from a read-only calendar query; without it the case is skipped and booking.test.ts carries the rule.
  // SPEC-39 3.6b: inside five days the one-step message asks the full amount only, and the QR carries it.
  if (soonRange) cases.push({ id: 'pay-near-en', group: 'payment', turns: [f(`${soonRange} available? 2 adults`, 'en'), f('yes', 'en'),
    f(PAY, 'en', { must: [/check-in is near/, /full ₱/], mustNot: [/reservation fee holds/, LINK], effects: [/"fx":"submit"/, /"qr"/] })] });
  if (soonRange) cases.push({ id: 'flow-offer-fullnow-en', group: 'flow', turns: [
    // s73 F8: persona.ts LAST_MINUTE says "arriving within the next five days" and the details ask asks for "your full name"
    // (SPEC-39 3.6); the old wordings ("less than five days away", "name for the reservation") are no longer said.
    { say: `Hi, is ${soonRange} available? 2 adults`, kind: 'flow', lang: 'en', must: [/within the next five days/i] },
    { say: 'yes', kind: 'flow', lang: 'en', must: [/full name/i] },
    { say: 'Ben Munez 09171234567 ben@example.com', kind: 'flow', lang: 'en', must: [/full ₱/], mustNot: [/"fee" or "full"/], effects: [/"fx":"submit"/] },
  ] });
  // D-311.2 (Lloyd 2026-10-07): 12 NN or 1 PM only if the unit is ready - never a promised time, the standard 2:00 PM named.
  if (turnoverDay) cases.push({ id: 'first-noon-checkin-on-turnover-day-tl', group: 'first', turns: [m(`Hello po, available po ba ang ${turnoverDay}? Pwede po ba check in 12 noon?`, 'tl', { must: [/2(:00)? ?PM/i], mustNot: [/complimentary|no extra cost|free early|welcome to check in (from|at) 12|(you can|pwede po kayong) check in (at|ng) 12/i] })] });
  // Incident 2026-10-07 (Angel): a misspelt availability ask after the rate answer starts the flow (the party ask), and a stay that
  // starts on another guest's check-out day says so - check-in from 2:00 PM, no "as soon as you arrive". Three nights from the turnover day.
  if (turnoverDay) {
    const [mo, dd] = turnoverDay.split(' '), y = now.getUTCFullYear(), t = new Date(Date.UTC(y, MON.indexOf(mo), +dd));
    const stay = range(t.getTime() < now.getTime() - 86_400_000 ? new Date(Date.UTC(y + 1, MON.indexOf(mo), +dd)) : t, 0, 3);
    cases.push({ id: 'avail-typo-turnover-tl', group: 'flow', turns: [m('Hi po hm per night', 'tl'),
      f(`Avajlable po ${stay}?`, 'en', { must: [/is available/i, /checks out that morning/i, /2:00 PM/, /How many/i], mustNot: [/as soon as you arrive/i, /unfortunately/i] })] });
  }
  return cases;
}
