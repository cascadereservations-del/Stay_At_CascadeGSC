// Cassy's voice for the booking flow (D-268, Lloyd 2026-09-28: "separate the tone check vs flow and structure, so the tone
// of replies is unaffected and remains constant regardless of the changes in the structure or sequence").
//
// The contract: booking.ts decides WHAT happens (which move, which facts); this file alone decides HOW it is said.
//   - Facts arrive as sealed parameters (prices, dates, party) computed by code; nothing here computes or invents one.
//   - REQUIRED disclosures (capacity, the last-minute full-payment rule) are named constants a warmth change cannot drop.
//   - Every move is written to the same shape (Lloyd's protocol: answer, acknowledge, advance) and passes voice.ts
//     lintReply in all three registers (persona.test.ts).
//   - Persuasion lives in what is surfaced and in what order - reciprocity (answer fully first), one easy next step,
//     an honest nearest alternative, small yeses - never in urgency words or adjectives.
//   - No live model rewrite: deterministic, instant, free, and a price can never drift.
// Phase 2 (D-269): every guest-facing line of booking.ts lives here. Lines Lloyd approved word for word are marked
// APPROVED and moved unchanged (greeting, Cassy's introduction, the bot answer, the payment message and promise, the
// D-258 payment-path lines); reword them only with Lloyd.
// Session 58 (roadmap 1, the persona gate): the fixed guest lines index.ts used to keep inline (handoffs, closers, the
// dates-first answer, the nudges, the submit and receipt lines) live here too, so persona.test.ts holds every one.
import type { Lang } from './booking.ts';
import type { RiskCode } from './policy.ts';
import { SITE_URL } from '../_shared/cascade-core/facts.ts';
import { currentContact, type Contact } from '../_shared/cascade-core/contact.ts';

export const pick = (lang: Lang | undefined, t: { en: string; tl: string; bis: string }): string => t[lang ?? 'en'];
const by = pick;
const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
const first = (name: string | null | undefined) => (name ?? '').trim().split(/\s+/)[0] ?? '';

/** REQUIRED: the capacity, said before any booking commitment (D-222). */
export const CAPACITY: Record<Lang, string> = {
  en: 'The home is most comfortable for up to 3 adults, or 2 adults with 2 children.',
  tl: 'Most comfortable ang home for up to 3 adults, or 2 adults with 2 kids.',
  bis: 'Most comfortable ang home for up to 3 adults, or 2 adults with 2 kids.',
};
/** REQUIRED: inside five days the full amount confirms the stay (D-166 / D-184); English in every register (D-258). */
export const LAST_MINUTE = `As you're arriving within the next five days, the full amount confirms your stay right away.`;

// ---- Greeting and introduction (APPROVED) ----

/** D-173 / SPEC-01: the direct answer to "are you a bot?", approved wording, all three registers.
 *  The first name and its comma are added by the caller. */
export const BOT_REPLY: Record<Lang, string> = {
  en: `I'm Cassy, Cascade Hideaway's digital concierge, an AI assistant looked after by our team. I'm glad to help with rates, dates, directions and anything about your stay, and whenever you'd like a person, our host Marifel is one message away.`,
  tl: `ako po si Cassy, ang digital concierge ng Cascade Hideaway, isang AI assistant na inaalagaan ng aming team. I'm glad to help with rates, dates, directions at anything about your stay, and kapag gusto ninyong makausap ang isang person, si Marifel, ang host namin, ay one message away lang po.`,
  bis: `ako si Cassy, ang digital concierge sa Cascade Hideaway, usa ka AI assistant nga giatiman sa among team. Glad ko to help with rates, dates, directions ug anything about your stay, ug kung gusto mo makig-istorya og person, si Marifel, among host, one message away ra.`,
};
/** D-173 / SPEC-01: said once, in the first message only, directly after the greeting's
 *  "thank you for reaching out" sentence and before the answer. Approved wording - do not reword.
 *  No "po" in tl or bis on purpose: the canned first message already carries three (protocol 07
 *  section 4 asks for one or two) and Bisaya takes none (protocol 09 section 3). */
export const CASSY_INTRO: Record<Lang, string> = {
  // D-244 (Lloyd 2026-09-25, "shorten cassy introduction, minimal yet invokes trust"): name, the disclosure (digital),
  // and a named human with the team - nothing else. Was 91/96/96 characters.
  en: `I'm Cassy, the home's digital concierge, here with Marifel and our team. `,
  tl: `Ako si Cassy, ang digital concierge ng Cascade, kasama si Marifel at ang team. `,
  bis: `Ako si Cassy, ang digital concierge sa Cascade, kauban si Marifel ug ang team. `,
};
/** APPROVED (Lloyd's first reply, 2026-09-18). `intro` defaults to false, not true as SPEC-01 sketched: every caller that
 *  knows whether the guest has already met Cassy passes it explicitly, and a call site missed later should fall back
 *  to saying nothing rather than to repeating the introduction, which is the one thing D-173 forbids. */
export const greeting = (name: string | null, lang: Lang = 'en', intro = false) => by(lang, {
  en: `${name ? `Hi ${name.split(' ')[0]},` : 'Hello,'} thank you for reaching out to Cascade Hideaway. `,
  tl: `${name ? `Hi ${name.split(' ')[0]}!` : 'Hello po!'} Salamat sa pag-message sa Cascade Hideaway. `,
  bis: `${name ? `Hi ${name.split(' ')[0]}!` : 'Hello!'} Salamat sa pag-message sa Cascade Hideaway. `,
}) + (intro ? CASSY_INTRO[lang ?? 'en'] : '');
/** SPEC-28 section 3: with the Cassy sentence the greeting is long, so the answer goes on its own paragraph (golden
 *  first-avail-taken-en read as one block). Without it the greeting and the answer stay one paragraph: that is Lloyd's
 *  approved first reply (2026-09-18) and the lint wants the answer in the first paragraph. */
export const greetBlock = (name: string | null, lang: Lang = 'en', intro = false) => intro ? greeting(name, lang, true).trimEnd() + '\n\n' : greeting(name, lang, false);

// ---- The party ----

const TL_COUNT: Record<number, string> = { 2: 'dalawa', 3: 'tatlo', 4: 'apat' };
const BIS_COUNT: Record<number, string> = { 2: 'duha', 3: 'tulo', 4: 'upat' };
/** The party as a host names it: "the two of you" / "kayong dalawa" (Taglish never "the two of you"). */
export function partyName(pax: number | undefined, lang?: Lang): string {
  if (!pax || pax === 1) return 'you';
  if (lang === 'tl') return `kayong ${TL_COUNT[pax] ?? pax}`;
  return pax === 2 ? 'the two of you' : `your party of ${pax}`;
}
/** The welcome that follows an answer ("..., and we'd be glad to welcome the two of you."). */
const welcomeParty = (who: string, lang?: Lang) => by(lang, {
  en: `we'd be glad to welcome ${who}.`, tl: `we'd be glad to have ${who}.`, bis: `looking forward mi to have ${who}.`,
});

// ---- Availability ----

/** The calendar answered: open. `dates` is stayLabel's ("tonight (Sep 26)", "the night of Oct 5", "Oct 20 to 22"). */
export const datesOpen = (dates: string, lang?: Lang) => by(lang, { en: `${cap(dates)} is available`, tl: `Available po ang ${dates}`, bis: `Available ang ${dates}` });
/** The calendar could not be read: never claim the dates are open (session 30). */
export const datesChecking = (dates: string, lang?: Lang) => by(lang, {
  en: `We're checking ${dates} on our calendar and will confirm shortly`,
  tl: `Iche-check po namin ang ${dates} sa calendar and we'll confirm shortly`,
  bis: `Amo i-check ang ${dates} sa calendar and we'll confirm shortly`,
});
/** Taken, nothing near to offer: the honest reason and one easy way on. index.ts matches "already reserved" / "reserved na". */
export const datesReserved = (dates: string, lang?: Lang) => by(lang, {
  en: `I'm sorry, ${dates} is already reserved, as the home welcomes one party at a time. If other dates suit you, just share your check-in and check-out and we'll gladly check them for you.`,
  tl: `Pasensya na po, reserved na ang ${dates} — one party lang ang tinatanggap namin per stay. If may ibang dates kayong gusto, share lang po ang check-in and check-out and iche-check namin agad.`,
  bis: `Pasensya, reserved na ang ${dates} — one party ra ang ma-accommodate namo per stay. If naa moy other dates, share lang ang check-in and check-out and amo dayon i-check.`,
});
/** Taken, with the nearest open window (`when`: "Oct 2", "Oct 2 to 4", "Oct 2 onwards"). `ask`: offered as the same
 *  one-yes question the price path uses (holdOffer), so a guest is one "yes" from the next step whichever way they came. */
export function datesReservedNearest(dates: string, when: string, one: boolean, ask: boolean, lang?: Lang): string {
  const near = by(lang, {
    en: one ? `The nearest open night is ${when}` : `The nearest open dates are ${when}`,
    tl: `Ang nearest open ${one ? 'night' : 'dates'} ay ${when}`,
    bis: `Ang nearest open ${one ? 'night' : 'dates'} kay ${when}`,
  });
  if (ask) return by(lang, {
    en: `I'm sorry, ${dates} is already reserved. ${near}.\n\n${holdOffer(one, lang)} If other dates work better, just share them and we'll gladly check.`,
    tl: `Pasensya na po, reserved na ang ${dates}. ${near}.\n\n${holdOffer(one, lang)} If may ibang dates kayong gusto, share lang and iche-check namin agad.`,
    bis: `Pasensya, reserved na ang ${dates}. ${near}.\n\n${holdOffer(one, lang)} If naa moy lain nga dates, share lang ug amo dayon i-check.`,
  });
  return by(lang, {
    en: `I'm sorry, ${dates} is already reserved. ${near}, and we'd be glad to welcome you then. If other dates suit you better, just share your check-in and check-out and we'll gladly check them for you.`,
    tl: `Pasensya na po, reserved na ang ${dates}. ${near}, and we'd be glad to have you then. If may ibang dates kayong gusto, share lang po ang check-in at check-out and iche-check namin agad.`,
    bis: `Pasensya, reserved na ang ${dates}. ${near}, ug looking forward mi to have you then. If naa moy lain nga dates, share lang ang check-in ug check-out ug amo dayon i-check.`,
  });
}
/** Mid-flow, new dates are open: the answer, then the welcome (protocol rule 1, live 2026-09-17 10:57). */
export const openAck = (openLine: string, pax: number | undefined, lang?: Lang) => `${openLine}, and ${welcomeParty(partyName(pax, lang), lang)}`;

// ---- The first reply of a flow ----

/** Both dates given but not yet checked: noted, and checked as we go. */
const datesNoted = (checkin: string, checkout: string, lang?: Lang) => by(lang, {
  en: `${checkin} to ${checkout} is noted, and we'll check those dates for you as we go. `,
  tl: `Noted po ang ${checkin} to ${checkout} — iche-check namin ang dates as we go. `,
  bis: `Noted ang ${checkin} to ${checkout} — amo i-check ang dates as we go. `,
});
/** A host's welcome that acknowledges what the guest already told us (session 28 - "Your mobile number po?" as an opener
 *  read as a form). `greet` is the greeting already built (or ''); `answer` the calendar's line; `dates` the check-in and
 *  check-out when both are known and not yet answered. */
export function openerText(greet: string, answer: string, dates: [string, string] | null, pax: number | undefined, lang?: Lang): string {
  const welcome = welcomeParty(partyName(pax, lang), lang);
  if (answer) return `${greet}${answer}, and ${welcome}\n\n`;
  return `${greet}${dates ? datesNoted(dates[0], dates[1], lang) : ''}${cap(welcome)}\n\n`;
}

// ---- The slot asks ----

/** The dates, with an example a week out. `name` is the first name or ''. */
export const datesAsk = (name: string, example: string, lang?: Lang) => {
  const n = name ? `${name}, ` : '';
  return by(lang, {
    en: `${n ? `${n}which` : 'Which'} dates would you like to stay with us? Your check-in and check-out will do (for example, "${example}").`,
    tl: `${n}kailan po ninyo gustong mag-stay? Check-in and check-out lang po (halimbawa, "${example}").`,
    bis: `${n}kanus-a mo gusto mag-stay? Check-in and check-out lang (pananglitan, "${example}").`,
  });
};
/** Live 2026-09-26 (Suzanne): a host asks for nights; "2 nights", "tomorrow" or a date all answer it. */
export const nightsAsk = (checkin: string, tonight: boolean, lang?: Lang) => by(lang, {
  en: `How many nights would you like to stay with us from ${tonight ? 'tonight' : checkin}? A check-out date works just as well.`,
  tl: `Ilang nights po ang stay ninyo from ${checkin}? Puwede rin ang check-out date.`,
  bis: `Pila ka nights ang stay ninyo from ${checkin}? Pwede pud ang check-out date.`,
});
/** A check-out on or before the check-in: the earliest one, and the nights ask again. */
export const earliestCheckout = (checkin: string, earliest: string, lang?: Lang) => by(lang, {
  en: `Of course. With check-in on ${checkin}, the earliest check-out is ${earliest}. How many nights would you like to stay with us?`,
  tl: `Sige po. With check-in on ${checkin}, ang earliest check-out ay ${earliest}. Ilang nights ang stay ninyo?`,
  bis: `Sige. With check-in on ${checkin}, ang earliest check-out kay ${earliest}. Pila ka nights ang stay ninyo?`,
});
export const pastDate = (lang?: Lang) => by(lang, {
  en: `That date has already passed. Which upcoming dates would suit you?`,
  tl: `Lumipas na po ang date na iyon. Aling upcoming dates po ang gusto ninyo?`,
  bis: `Lapas na ang date nga na. Unsang upcoming dates ang gusto ninyo?`,
});
export type RetryWhat = 'dates' | 'checkout' | 'guests' | 'details' | 'that';
const RETRY: Record<RetryWhat, { en: string; tl: string; bis: string }> = {
  dates: { en: 'the dates', tl: 'ang dates', bis: 'ang dates' },
  checkout: { en: 'the check-out date', tl: 'ang check-out date', bis: 'ang check-out date' },
  guests: { en: 'the number of guests', tl: 'kung ilan kayo', bis: 'pila mo' },
  details: { en: 'those details', tl: 'iyon', bis: 'to' },
  that: { en: 'that', tl: 'iyon', bis: 'to' },
};
/** The answer could not be read: an apology, then the same ask again (`again`, from the flow). */
export const retryLine = (what: RetryWhat, again: string, lang?: Lang) => {
  const w = by(lang, RETRY[what]);
  return by(lang, { en: `Sorry, I couldn't quite make out ${w}. ${again}`, tl: `Sorry po, hindi ko nakuha ${w}. ${again}`, bis: `Sorry, wala nako nakuha ${w}. ${again}` });
};

/** The guest count, asked as a host would, with the REQUIRED capacity after it. */
export const partyAsk = (lang?: Lang) => by(lang, {
  en: `How many of you will be staying? ${CAPACITY.en}`,
  tl: `Ilan po kayong magse-stay? ${CAPACITY.tl}`,
  bis: `Pila mo ka tawo ang mo-stay? ${CAPACITY.bis}`,
});
/** More than the home holds (D-222): warmth first, the REQUIRED capacity, an honest suggestion, and room to correct. */
export const overCapacityLine = (pax: number, lang?: Lang) => by(lang, {
  en: `As much as we'd love to host everyone, we want your stay to be comfortable. ${CAPACITY.en} For a party of ${pax}, a larger place would give you more room to rest. If your group is smaller, just let us know the count.`,
  tl: `Gusto po sana namin kayong ma-host lahat, pero comfort ninyo ang una. ${CAPACITY.tl} For ${pax}, mas maganda ang mas malaking place para mas may space kayo. If mas kaunti ang group ninyo, sabihin lang po ang count.`,
  bis: `Ganahan unta mi ma-host mo tanan, pero ang inyong comfort ang una. ${CAPACITY.bis} For ${pax}, mas maayo ang mas dako nga place para mas naa moy space. If mas gamay ang group ninyo, ingna lang mi pila mo.`,
});
/** After the guest count, when the guest already heard the price: welcome the party instead of quoting it twice. */
export const partyWelcome = (pax: number | undefined, lang?: Lang) => {
  const solo = !pax || pax === 1;
  return by(lang, {
    en: solo ? `Noted, and we're already looking forward to welcoming you.` : `${cap(partyName(pax, 'en'))}, then, and we're already looking forward to it.`,
    tl: solo ? `Noted po, and we're looking forward to welcoming you.` : `Noted po, ${TL_COUNT[pax!] ?? pax} kayo. We're looking forward to welcoming you.`,
    bis: solo ? `Noted, and looking forward mi to welcome you.` : `Noted, ${BIS_COUNT[pax!] ?? pax} mo. Looking forward mi to welcome you.`,
  });
};

// ---- Price and the offer ----

/** One night's price, as a host says it (was "For 1 night the direct rate is PHP 1,780."). */
export const oneNight = (price: string, lang?: Lang) => by(lang, {
  en: `One night with us comes to ${price}.`,
  tl: `${price} po ang isang gabi sa amin.`,
  bis: `${price} ang usa ka gabii sa amo.`,
});
/** Two nights or more on the tier rate: the direct rate anchored on the standard. */
export const nightsPrice = (n: number, rate: string, std: string, total: string, lang?: Lang) => by(lang, {
  en: `Booking directly with us brings your ${n} nights to ${rate} per night instead of the standard ${std} — ${total} for the stay.`,
  tl: `Kapag direct booking po sa amin, ang ${n} nights ninyo ay nasa ${rate} per night imbes na ang standard na ${std} — ${total} for the stay.`,
  bis: `Kung direct booking sa amo, ang inyong ${n} nights kay ${rate} per night imbes sa standard nga ${std} — ${total} for the stay.`,
});
/** D-262: promo nights anchored on the standard rate (never a "was" price). One night, all of it on the promotion. */
export const promoOneNight = (rate: string, name: string, std: string, lang?: Lang) => by(lang, {
  en: `One night with us comes to ${rate} with our ${name}, instead of our standard ${std}.`,
  tl: `${rate} po ang isang gabi sa amin with our ${name}, imbes na ang standard na ${std}.`,
  bis: `${rate} ang usa ka gabii sa amo with our ${name}, imbes sa standard nga ${std}.`,
});
/** Every night of the stay inside the promotion. */
export const promoAllNights = (n: number, name: string, rate: string, std: string, total: string, lang?: Lang) => by(lang, {
  en: `Your ${n} nights fall inside our ${name}, so booking directly brings them to ${rate} per night instead of the standard ${std} — ${total} for the stay.`,
  tl: `Pasok po ang ${n} nights ninyo sa ${name} namin, kaya sa direct booking ay ${rate} per night imbes na ang standard na ${std} — ${total} for the stay.`,
  bis: `Sulod sa among ${name} ang inyong ${n} nights, so sa direct booking kay ${rate} per night imbes sa standard nga ${std} — ${total} for the stay.`,
});
/** A mixed stay names both parts. `when` is the promotion's nights ("Oct 11", "Oct 11 to 13"). */
export function promoMixed(p: { n: number; total: string; promoNights: number; when: string; name: string; promoRate: string; rest: number; restRate: string; std: string }, lang?: Lang): string {
  const s = (k: number) => (k === 1 ? '' : 's');
  return by(lang, {
    en: `Booking directly with us, your ${p.n} nights come to ${p.total}: ${p.promoNights} night${s(p.promoNights)} (${p.when}) at our ${p.name} rate of ${p.promoRate}, and ${p.rest} night${s(p.rest)} at ${p.restRate}, instead of the standard ${p.std} a night.`,
    tl: `Kapag direct booking po sa amin, ang ${p.n} nights ninyo ay ${p.total}: ${p.promoNights} night${s(p.promoNights)} (${p.when}) sa ${p.name} rate na ${p.promoRate}, at ${p.rest} night${s(p.rest)} sa ${p.restRate}, imbes na ang standard na ${p.std} per night.`,
    bis: `Kung direct booking sa amo, ang inyong ${p.n} nights kay ${p.total}: ${p.promoNights} night${s(p.promoNights)} (${p.when}) sa ${p.name} rate nga ${p.promoRate}, ug ${p.rest} night${s(p.rest)} sa ${p.restRate}, imbes sa standard nga ${p.std} per night.`,
  });
}
/** After the price: one easy yes, and room to say no. `warm` false when a welcome already sits above it in the same
 *  message (the first reply's opener), so "glad" is not said twice. */
export const holdOffer = (one: boolean, lang?: Lang, warm = true) => by(lang, {
  en: `Shall we hold ${one ? 'that night' : 'those dates'} for you?${warm ? ` We'd be so glad to have you with us.` : ''}`,
  tl: `I-hold na po ba namin ang ${one ? 'night' : 'dates'} na iyon para sa inyo?${warm ? ` We'd be so glad to have you.` : ''}`,
  bis: `I-hold na ba namo ang ${one ? 'night' : 'dates'} nga to para ninyo?${warm ? ` Looking forward mi to have you.` : ''}`,
});
/** The guest just said yes to the window: acknowledge the choice, never restate it as news ("Oct 2 is available"). */
export const choiceAck = (dates: string, lang?: Lang) => by(lang, {
  en: `${dates} it is, and we're glad to have you.`,
  tl: `Sige po, ${dates}. We're glad to have you.`,
  bis: `Sige, ${dates}. Looking forward mi to have you.`,
});

// ---- The details ----

/** The details, asked once for all three so one reply can finish them (protocol: fewer steps beat more). `thank` false
 *  when a line above already acknowledged the guest (the price or the party welcome). */
export const detailsAsk = (name: string, lang?: Lang, thank = true) => by(lang, {
  en: `${name && thank ? `Thank you, ${name}. ` : ''}To prepare your reservation, may we have your full name, a mobile number we can reach you on, and an email for the confirmation? All three in one message is easiest.`,
  tl: `${!thank ? '' : name ? `Salamat, ${name}. ` : 'Salamat po. '}Para ma-prepare ang reservation ninyo, maaari po ba naming makuha ang full name, mobile number, at email para sa confirmation? Okay lang na sabay-sabay sa isang message.`,
  bis: `${!thank ? '' : name ? `Salamat, ${name}. ` : 'Salamat. '}Para ma-prepare ang inyong reservation, pwede namo makuha ang full name, mobile number, ug email for the confirmation? Okay ra nga usa ra ka message.`,
});
/** SPEC-14 (D-184): after a partial answer, only the first missing item is asked for. `who` is the reservation name. */
export function nextDetail(missing: 'name' | 'phone' | 'email', who: string, lang?: Lang): string {
  if (missing === 'name') return by(lang, { en: `Thank you. And the name for the reservation?`, tl: `Salamat po. At ang pangalan para sa reservation?`, bis: `Salamat. Ug ang name for the reservation?` });
  if (missing === 'phone') return by(lang, { en: `Thank you, ${who}. And a mobile number we can reach you on?`, tl: `Salamat po, ${who}. At ang mobile number na matatawagan namin?`, bis: `Salamat, ${who}. Ug ang mobile number nga ma-contact namo?` });
  return by(lang, { en: `Thank you, ${who}. And an email address for your confirmation?`, tl: `Salamat po, ${who}. At ang email address para sa confirmation?`, bis: `Salamat, ${who}. Ug ang email address for your confirmation?` });
}

// ---- The confirm card ----

export type CardFacts = { resume: boolean; who: string | null; range: string; nights: number; pax: number | undefined; phone: string | undefined; email: string | null | undefined; total: string; promo: { name: string; nights: number; rate: string } | null };
/** The stay at a glance, one fact per line; `resume` after a mid-flow question (Lloyd 2026-09-17: nudge subtly). */
export function stayCard(c: CardFacts, lang?: Lang): string {
  const s = (k: number | undefined) => (k === 1 ? '' : 's');
  return [
    c.resume
      ? by(lang, { en: `Here's your stay, ready whenever you are:`, tl: `Ito po ang stay ninyo, ready whenever you are:`, bis: `Mao ni ang inyong stay, ready whenever you are:` })
      : by(lang, { en: `Here are your stay details:`, tl: `Ito po ang details ng stay ninyo:`, bis: `Mao ni ang details sa stay ninyo:` }),
    ...(c.who ? [`👤 ${c.who}`] : []),
    `📅 ${c.range} · ${c.nights} night${s(c.nights)} · ${c.pax} guest${s(c.pax)}`,
    `📞 ${c.phone}${c.email ? ` · ${c.email}` : ''}`,
    `💰 Total ${c.total}`,
    ...(c.promo ? [`🏷️ ${c.promo.name}: ${c.promo.nights} night${s(c.promo.nights)} at ${c.promo.rate}`] : []),
    by(lang, { en: `🔐 ₱1,000 refundable security deposit, returned after check-out`, tl: `🔐 ₱1,000 refundable security deposit, ibabalik after check-out`, bis: `🔐 ₱1,000 refundable security deposit, i-uli after check-out` }),
  ].join('\n');
}
/** SPEC-14 (D-184): the card's payment sentence - the fee-or-full choice, or the full-only sentence inside five days. */
export const payChoiceLine = (fullOnly: boolean, total: string, deposit: string, lang?: Lang) => fullOnly
  ? by(lang, {
      en: `As your check-in is near, the full ${total} secures your stay, with the ₱1,000 refundable deposit due before you arrive. You may reply FULL to send your request through, or let us know if anything needs changing.`,
      tl: `Malapit na po ang check-in, kaya ang full ${total} ang magse-secure ng stay, and the ₱1,000 refundable deposit is due before you arrive. You may reply FULL to send the request through, or sabihin lang if may kailangang baguhin.`, // one po: the card head above carries the other
      bis: `Duol na ang check-in, so ang full ${total} ang mag-secure sa stay, and the ₱1,000 refundable deposit is due before you arrive. Pwede mo mu-reply og FULL para ma-send ang request, or ingna lang mi if naa may changes.` })
  : by(lang, {
      en: `A reservation fee of ${deposit} holds the dates. The balance and the ₱1,000 refundable deposit are due at least a day before check-in; or you may settle the full ${total} now. Just tell us "fee" or "full", whichever suits you.`,
      tl: `Ang reservation fee na ${deposit} ang magho-hold ng dates. The balance and the ₱1,000 refundable deposit are due at least a day before check-in; o puwede rin pong bayaran ang full ${total} ngayon. Sabihin lang po "fee" o "full", kung alin ang mas okay sa inyo.`,
      bis: `Ang reservation fee nga ${deposit} ang mo-hold sa dates. The balance and the ₱1,000 refundable deposit are due at least a day before check-in; o pwede pud bayran ang full ${total} karon. Ingna lang mi og "fee" o "full", kung asa ang mas okay ninyo.` });

/** D-269 (live 2026-09-27, Suzanne "Is party allowed?" got only "That's a request our host would love to consider"): a
 *  house-rule question is answered from FACTS first; the host still hears it, and the guest is told so once. */
export const houseRule = (kind: 'party' | 'pets' | 'guests', lang?: Lang) => {
  const host = by(lang, {
    en: `we've shared your message with our host, who will reply here personally.`,
    tl: `na-share na namin ang message ninyo sa host, and they'll reply here personally.`,
    bis: `na-share na namo ang inyong message sa among host, and they'll reply here personally.`,
  });
  if (kind === 'party') return by(lang, {
    en: `We're a quiet private retreat for registered guests, suited to rest and work rather than parties or events, and quiet hours run from 10 PM to 6 AM. If you have a small occasion in mind, ${host}`,
    tl: `Ang Cascade po ay tahimik na private retreat for registered guests, suited to rest and work rather than parties or events, at quiet hours mula 10 PM hanggang 6 AM. If may small occasion kayong naiisip, ${host}`,
    bis: `Ang Cascade kay hilom nga private retreat for registered guests, suited to rest and work rather than parties or events, ug quiet hours from 10 PM to 6 AM. If naa moy gamay nga occasion nga gi-plano, ${host}`,
  });
  if (kind === 'pets') return by(lang, {
    en: `We're a pet-free home, which keeps it fresh and allergy-friendly for every guest. If you'd like to ask about your pet, ${host}`,
    tl: `Pet-free po ang Cascade, para fresh and allergy-friendly para sa lahat ng guests. If gusto ninyong i-ask ang tungkol sa pet ninyo, ${host}`,
    bis: `Pet-free ang Cascade, para fresh ug allergy-friendly para sa tanang guests. If gusto mo mangutana bahin sa inyong pet, ${host}`,
  });
  return by(lang, {
    en: `${CAPACITY.en} Overnight stays are for the guests on the booking, and day visitors are welcome with advance notice. For anything beyond that, ${host}`,
    tl: `${CAPACITY.tl} Ang overnight ay para sa guests sa booking, at welcome ang day visitors basta may advance notice po. For anything beyond that, ${host}`,
    bis: `${CAPACITY.bis} Ang overnight para sa guests sa booking, ug welcome ang day visitors basta naay advance notice. For anything beyond that, ${host}`,
  });
};
/** D-269: a discount turn still reaches the host (Lloyd 2026-09-13), said once per thread and as part of the answer -
 *  not "That's a request our host would love to consider", which read as a form letter twice in one chat. */
export const discountHostLine = (lang?: Lang) => by(lang, {
  en: `Our host also looks at special requests personally, so we've shared your message with them.`,
  tl: `Personal ding tinitingnan ng host ang special requests, kaya na-share na namin ang message ninyo.`,
  bis: `Personal pud nga gitan-aw sa among host ang special requests, so na-share na namo ang inyong message.`,
});

/** SPEC-14 (D-184): the cancel / "not now" reply. Nothing is committed, and the dates alone reopen the flow. */
export const cancelReply = (lang: Lang | undefined) => by(lang, {
  en: `Of course, and there's no rush at all. Nothing has been sent, so nothing is committed. Whenever you'd like to continue, just send your dates again and we'll pick up right where we left off. 🌿`,
  tl: `No problem po, take your time. Wala pong na-send, so nothing is committed. Whenever you're ready, i-send lang po ulit ang dates ninyo and we'll pick up right where we left off. 🌿`,
  bis: `Walay problema, take your time. Walay na-send, so nothing is committed. Whenever you're ready, i-send lang balik ang inyong dates and we'll pick up right where we left off. 🌿`,
});

// ---- After the booking exists (APPROVED, D-258: English in every register, Taglish keeps one courtesy "po") ----

const withName = (name: string | null) => { const n = first(name); return n ? `, ${n}` : ''; };
/** SPEC-31 s1 (REVIEW F1): "cancel po" while the hold is open; `kind` 'receipt' after a receipt ("nothing is charged"
 *  would be false), 'change' when the message carries new dates. */
export function holdCancelLine(kind: 'cancel' | 'receipt' | 'change', name: string | null, dates: string, lang: Lang): string {
  const c = withName(name), ok = by(lang, { en: `Understood${c}.`, tl: `Noted po${c}.`, bis: `Noted${c}.` });
  if (kind === 'receipt') return `${ok} We've let our host know and they'll release the hold on ${dates} for you; they'll go over your payment with you here. 🌿`;
  if (kind === 'change') return `${by(lang, { en: `Noted${c}`, tl: `Noted po${c}`, bis: `Noted${c}` })} - we can look at that. We've passed the change to our host, and they'll confirm the new dates and the hold here. 🌿`;
  return `${ok} We've let our host know and they'll release the hold on ${dates} for you; nothing is charged. If your plans change again, your dates are one message away. 🌿`;
}
/** SPEC-31 s2 (REVIEW F2): "paid na po?" - answered from what we hold. No timing promise: nothing measures the host. */
export function paidClaimLine(received: boolean, name: string | null, ref: string | undefined, lang: Lang): string {
  const c = withName(name);
  return received
    ? `${by(lang, { en: `Yes${c}`, tl: `Yes po${c}`, bis: `Yes${c}` })}, your receipt is with us and our host is reviewing it now. You'll hear the confirmation here.`
    : `${by(lang, { en: `Thank you${c}`, tl: `Thank you po${c}`, bis: `Thank you${c}` })}. We don't have the receipt yet on our side - a screenshot of the GCash confirmation sent here is all we need, and our host will match it to ${ref}.`;
}
/** SPEC-31 s3 (REVIEW F3): a photo with no live upload - never promises the dates are still free. */
export const strayReceiptLine = (name: string | null, lang: Lang) =>
  `${by(lang, { en: `Thank you${withName(name)}`, tl: `Thank you po${withName(name)}`, bis: `Thank you${withName(name)}` })}. We have your photo. Our host will match it to your booking and confirm here; if the hold had lapsed, they'll check the dates are still open and set them up again. 🌿`;
/** D-258: "how do I pay?" - the GCash QR goes with this line, the name once. `hasDates` false: the static QR, and the dates
 *  ask; true: the amount-set QR follows after the details (the caller appends the flow's next ask). */
export function payHow(name: string | null, lang: Lang, hasDates: boolean): string {
  const n = first(name), y = n ? `${n}, you` : 'You', po = lang === 'tl' ? ' po' : '';
  return hasDates
    ? `${y} may pay${po} by GCash with the QR below. Whenever you're ready, we'll finish your booking details and send it again with the exact amount already set, so there's nothing to type.`
    : `${y} may pay${po} by GCash with the QR below. Whenever you're ready, share your check-in and check-out dates and we'll send it again with the exact amount already set, so there's nothing to type; a screenshot of the payment here is all we need after.`;
}

// ---- The payment message (APPROVED, D-168/D-169 and SPEC-10 control 6) ----

/** "today" / "tomorrow" beside the hold's end, in the register. */
export const relDayWord = (diff: 0 | 1, lang: Lang | undefined) => diff === 0
  ? by(lang, { en: 'today', tl: 'ngayong araw', bis: 'karon' })
  : by(lang, { en: 'tomorrow', tl: 'bukas', bis: 'ugma' });
/** SPEC-10 control 6, the payment promise. Lloyd approved these three sentences on 2026-09-20; the only addition is the
 *  registered-holder clause. Sent as its OWN message straight after the QR image (merging it breaks too_long). Both
 *  names on purpose: the QR's confirm screen shows `Cascades`, the booking site shows `Marifel Suzanne Boncales`. */
export function paymentPromise(_lang: Lang | undefined): string {
  // D-258: English in every register, no "po" here: it rides under a line that already carries one (golden R6 caps it at 2).
  return `For your peace of mind: we only ever ask for payment here in this chat or on our site, through the GCash QR we send, and the account name you'll see is Cascades, registered to Marifel Suzanne Boncales.`;
}
export type PaymentFacts = { name: string; dates: string; ref: string | undefined; until: string | null; rel: string; hold: boolean; near: boolean; deposit: string; balance: string; full: boolean };
/** D-168/D-169: Lloyd's section-24 (Filipino), section-30 balanced Bislish (Bisaya) and section-6 (English) targets, with
 *  the 24-hour hold and the relative day. Order: status -> next step -> convenience -> confirmation -> balance -> close. */
export function paymentMessage(p: PaymentFacts, L: Lang | undefined): string {
  const n = p.name, nm = n ? `, ${n}` : '', what = p.full ? 'payment' : 'initial payment';
  const head = p.hold && p.until
    ? by(L, {
        en: `${n ? `${n}, we've` : `We've`} set aside ${p.dates} for you for 24 hours, until ${p.until} (${p.rel}). Your booking reference is ${p.ref}.`,
        tl: `${n ? `${n}, na-hold` : `Na-hold`} na po namin ang ${p.dates} for you for 24 hours — until ${p.until} (${p.rel}). Ang booking reference ninyo po ay ${p.ref}.`,
        bis: `${n ? `${n}, na-hold` : `Na-hold`} na namo ang ${p.dates} for you for 24 hours — until ${p.until} (${p.rel}). Your booking reference is ${p.ref}.` })
    // SPEC-31 s6 (F16): a full payment far ahead opens no hold; "as your stay is near" was false 40 days out.
    : !p.near ? by(L, {
        en: `${n ? `${n}, we've` : `We've`} received your request for ${p.dates}, and it is yours as soon as your payment arrives. Your booking reference is ${p.ref}.`,
        tl: `${n ? `${n}, received` : `Received`} na po namin ang request ninyo for ${p.dates}, at sa inyo na ito once dumating ang payment. Ang booking reference ninyo po ay ${p.ref}.`,
        bis: `${n ? `${n}, na-receive` : `Na-receive`} na namo ang request ninyo for ${p.dates}, ug inyo na ni once muabot ang payment. Your booking reference is ${p.ref}.` })
    : by(L, {
        en: `${n ? `${n}, we've` : `We've`} received your request for ${p.dates}. Your booking reference is ${p.ref}. As your stay is near, we'll confirm as soon as your payment arrives.`,
        tl: `${n ? `${n}, received` : `Received`} na po namin ang request ninyo for ${p.dates}. Ang booking reference ninyo po ay ${p.ref}. Malapit na ang stay, kaya iko-confirm namin as soon as dumating ang payment.`,
        bis: `${n ? `${n}, na-receive` : `Na-receive`} na namo ang request ninyo for ${p.dates}. Your booking reference is ${p.ref}. Duol na ang stay, so amo dayon i-confirm once muabot ang payment.` });
  // SPEC-31 s5 (F10): one receipt sentence, and the whole message inside 560 characters (voice.test.ts pins it).
  const pay = by(L, {
    en: `To secure the stay, you may send the ${p.deposit} ${what} through GCash (0956 011 5744) with the QR below - the exact amount is already set. Once done, a screenshot of the receipt here is all we need.`,
    tl: `Para ma-secure ang stay, you may send the ${p.deposit} ${what} through GCash (0956 011 5744) gamit ang QR below - naka-set na ang exact amount. Once done, screenshot lang ng receipt dito ang kailangan namin.`,
    bis: `Para ma-secure ang stay, pwede na ma-send ang ${p.deposit} ${what} through GCash (0956 011 5744) gamit ang QR below - naka-set na daan ang exact amount. Once done, screenshot ra sa receipt diri ang among kinahanglan.` });
  const later = p.full
    ? by(L, { en: `Only the ₱1,000 refundable security deposit remains, and it is due before you arrive.`, tl: `Ang ₱1,000 refundable security deposit na lang po ang natitira, and it is due before you arrive.`, bis: `Ang ₱1,000 refundable security deposit na lang ang nabilin, and it is due before you arrive.` })
    : by(L, { en: `The remaining ${p.balance} balance and the ₱1,000 refundable security deposit are due at least a day before check-in.`, tl: `Ang natitirang ${p.balance} balance at ang ₱1,000 refundable security deposit ay due at least a day before check-in.`, bis: `The remaining ${p.balance} balance and the ₱1,000 refundable security deposit are due at least a day before check-in.` });
  const close = by(L, { en: `Thank you${nm}. We look forward to welcoming you to Cascade Hideaway. 🌿`, tl: `Salamat po${nm}. We look forward to welcoming you to Cascade Hideaway. 🌿`, bis: `Salamat${nm}. Looking forward mi sa inyong stay at Cascade Hideaway. 🌿` });
  return [head, '', pay, '', later, '', close].join('\n');
}

// ---- The fixed turns index.ts sends (session 58: moved from index.ts unchanged unless noted) ----

/** APPROVED (voice questionnaire, group 8): warm, "we" not "I", no "po" - these go out in English. No booking link:
 *  everyone who sees these already has a booking. */
export const HANDOFF: Record<RiskCode, string> = {
  routine:          '',
  payment:          "Thank you. Our host will personally verify your payment and send your confirmation shortly, so everything is properly recorded.\n\nWe're looking forward to welcoming you to Cascade Hideaway, and we'll have everything ready for your stay.",
  refund:           "Thank you for letting us know. Refunds are reviewed personally by our host, and we've passed this along for their attention right away. We'll make sure it is followed through.",
  cancellation:     "Thank you for letting us know about the change in your plans. Our host has already been notified and will personally assist you with your booking.\n\nWe'll keep the next steps as smooth as possible for you.",
  complaint:        "Thank you for letting us know right away. Our host has already been alerted, and our service partners have been notified so they can attend to this as soon as possible.\n\nYour comfort matters to us, and we'll make sure this is followed through promptly.",
  safety:           "Your safety comes first. Our host has been alerted immediately. If anyone is in danger, please call 911 right away.",
  access:           "For your security, access details are shared personally by our host. We've alerted them and they'll message you directly.",
  priority:         "Our host has been alerted and will answer you here first.",
  policy_exception: "That's a request our host would love to consider personally. We've passed it along, and you can expect a reply soon.",
  uncertain:        "Let us bring in our host for this one so you receive a complete answer. They'll be with you shortly.",
};
/** DESIGN-guest-case-catalogue G2 (Lloyd 2026-09-28: forward at once, reassure warmly; the host's number is +63 991 853
 *  8269, "prioritize this"): the door ask. Replaces HANDOFF.access as the guest line - the host shares the code, the guest
 *  gives what the host needs to match the stay, and a phone route if nobody answers in minutes. */
export const accessVerify = (lang: Lang, c: Contact = currentContact()) => by(lang, {
  en: `We're on it. For everyone's security the door code is shared only by our host, and your message is with them now. So they can match your stay quickly, may we have the name on the booking and your check-in date?\n\nIf you don't hear back within a few minutes, you may also call or text our on-ground partner ${c.name} at ${c.phone}.`,
  tl: `Naiintindihan po namin. For everyone's security, ang host lang ang nagbibigay ng door code, at nasa kanila na po ang message ninyo. Para mabilis nilang ma-match ang stay ninyo, ano ang name sa booking at ang check-in date?\n\nIf wala pang reply after a few minutes, you may also call or text our on-ground partner ${c.name} at ${c.phone}.`,
  bis: `Sabot mi. For everyone's security, ang host ra ang naghatag sa door code, ug naa na nila ang inyong message. Para dali nila ma-match ang inyong stay, unsa ang name sa booking ug ang check-in date?\n\nIf walay reply after a few minutes, pwede pud mo mo-call or text sa among on-ground partner nga si ${c.name} sa ${c.phone}.`,
});
/** Session 59 (Lloyd 2026-09-28): priority help for a guest staying now (menu button, ice breaker or the welcome guide's
 *  link). The ask is the welcome guide's own check - check-in date and the name on the booking. */
export const priorityAsk = (lang: Lang) => by(lang, {
  en: `Of course, we're right here for you. May we have your check-in date and the name on your booking, so we can bring your host in first? For example: Sept 27, Ana.`,
  tl: `Sige po, nandito lang kami para sa inyo. Ano ang check-in date ninyo at ang name sa booking, para ma-una namin kayo sa host? Halimbawa: Sept 27, Ana.`,
  bis: `Sige, naa ra mi diri para ninyo. Unsa ang inyong check-in date ug ang name sa booking, para ma-una namo mo sa host? Pananglitan: Sept 27, Ana.`,
});
export const priorityRetry = (lang: Lang) => by(lang, {
  en: `Thank you. We couldn't quite find today's stay under those details. Could you share the check-in date and the name on your booking once more? For example: Sept 27, Ana.`,
  tl: `Salamat po. Hindi pa namin mahanap ang stay ngayong araw sa details na iyon. Pakishare ulit ang check-in date at ang name sa booking? Halimbawa: Sept 27, Ana.`,
  bis: `Salamat. Wala pa namo makit-i ang stay karong adlawa sa maong details. Palihug i-share usab ang check-in date ug ang name sa booking? Pananglitan: Sept 27, Ana.`,
});
/** Verified and staying now: the host card and the urgent alert are already out; the guest says what they need next.
 *  Lloyd 2026-09-28: warm and unhurried, "residence" and "a call away" carry the luxury note. */
export const priorityVerified = (first: string | null, lang: Lang, c: Contact = currentContact()) => {
  const who = first && first !== 'Guest' ? `, ${first}` : '';
  return by(lang, {
    en: `Thank you${who}. Your host has been told and will be with you here shortly. Whenever you're ready, share what you need and it goes straight to them.

Should you need someone at the residence sooner, our on-ground partner ${c.name} is a call or text away at ${c.phone}.`,
    tl: `Salamat po${who}. Alam na ng host at makakausap ninyo sila dito shortly. Whenever you're ready, sabihin lang kung ano ang kailangan ninyo at diretso ito sa kanila.

If kailangan ninyo ng tao sa residence sooner, our on-ground partner ${c.name} is a call or text away at ${c.phone}.`,
    bis: `Salamat${who}. Nahibal-an na sa host ug makig-istorya sila ninyo diri shortly. Whenever you're ready, isulti lang kung unsa ang inyong kinahanglan ug diretso ni sa ila.

If kinahanglan mo og tawo sa residence sooner, ang among on-ground partner nga si ${c.name} is a call or text away sa ${c.phone}.`,
  });
};
/** Not matched after two tries (or a repeat within a day): still forwarded to the host, with the phone route. */
export const priorityUnmatched = (lang: Lang, c: Contact = currentContact()) => by(lang, {
  en: `Thank you. Your message is with your host, who will reply to you here. Should you need someone at the residence sooner, our on-ground partner ${c.name} is a call or text away at ${c.phone}.`,
  tl: `Salamat po. Nasa host na ang message ninyo, at dito sila magre-reply. If kailangan ninyo ng tao sa residence sooner, our on-ground partner ${c.name} is a call or text away at ${c.phone}.`,
  bis: `Salamat. Naa na sa host ang inyong message, ug diri sila mo-reply. If kinahanglan mo og tawo sa residence sooner, ang among on-ground partner nga si ${c.name} is a call or text away sa ${c.phone}.`,
});
/** Session 58 (live lockout 2026-09-28): the guest's next message while an access or safety handoff is open (a callback
 *  number, their name). It goes to the host as its own card, so "passed on" is true; no booking close, no link. */
export const handoffFollowUp = (lang: Lang) => by(lang, {
  en: `Thank you. We've passed this on to our host together with your earlier message, and they'll reach you directly.`,
  tl: `Salamat po. Na-pass na namin ito sa host kasama ng nauna ninyong message, and they'll reach you directly.`,
  bis: `Salamat. Na-pass na namo ni sa host uban sa inyong nauna nga message, and they'll reach you directly.`,
});
/** DESIGN-guest-case-catalogue G5: a photo or file from a guest with an open host matter or a booking - never the prospect
 *  reply with the site link. */
export const attachmentNoted = (lang: Lang) => by(lang, {
  en: `Thank you, we have your file and it is with our host together with your earlier message. If it is urgent, a few words typed here reach them fastest.`,
  tl: `Salamat po, received na namin ang file at nasa host na ito kasama ng nauna ninyong message. If urgent, a few words typed here ang pinakamabilis na paraan.`,
  bis: `Salamat, na-receive na namo ang file ug naa na ni sa host uban sa inyong nauna nga message. If urgent, a few words typed here ang pinakapaspas nga paagi.`,
});
/** G5: a voice note (common on a borrowed phone) - the host reads the chat as text. */
export const voiceNote = (lang: Lang) => by(lang, {
  en: `Thank you for the voice note. Our host reads this chat as text, so a few typed words about what you need will reach them right away.`,
  tl: `Salamat po sa voice note. Text ang nababasa ng host dito, so a few typed words about what you need will reach them right away.`,
  bis: `Salamat sa voice note. Text ang mabasa sa among host diri, so a few typed words about what you need will reach them right away.`,
});
/** A sticker, photo or reaction with no text: a prospect, so the link rather than a handoff line. */
export const ATTACHMENT_REPLY = `Thank you for your message. If you have dates in mind, share them here and we'll check the calendar for you, or you may see the home, live availability and our direct rates on our site:\n\n👉 ${SITE_URL}`;
/** Suggest mode: the guest hears this while the host picks a reply. */
export const ACK_SUGGEST = `Thank you for your message. Our host will reply personally very shortly.\n\nIn the meantime, you may check live availability and rates here:\n👉 ${SITE_URL}`;

/** Early/late check-in-out before the dates are known (policy.ts needsDatesFirst). No greeting on a follow-up, two "po"
 *  at most, both routes, never a bare link. Session 58: a settled Bisaya thread used to get the Taglish line with its
 *  "po"; it has its own now. */
export function datesFirstLine(name: string | null, lang: Lang, followUp: boolean): string {
  const open = followUp ? (name ? `${name}, ` : '') : `${name ? `Hi ${name}.` : 'Hello.'} `;
  const c = (s: string) => (open.endsWith(', ') ? s[0].toLowerCase() + s.slice(1) : s);
  if (lang === 'bis') return `${open}${c('Salamat')} sa pagpangutana. We'd be glad to arrange that for you: depende ni sa calendar anang adlawa, and kung walay laing guest nga moabot o mobiya that day, sayon ra ma-arrange.

Share lang diri ang inyong dates and we'll check right away, or pwede pud i-check ang live availability sa among site:

👉 ${SITE_URL}`;
  if (lang === 'tl') return `${open}${c('Salamat')} po sa pagtanong. We'd be glad to arrange that for you: depende ito sa calendar ng araw na iyon, and kapag walang ibang guest na dumarating o umaalis that day, madali pong ma-arrange.

Share lang dito ang dates ninyo and we'll check right away, o puwede ninyong i-check ang live availability sa aming site:

👉 ${SITE_URL}`;
  return `${open}${c('We')}'d be glad to arrange that for you. It depends on the calendar for that day: when no other guest arrives or leaves the same day, it's easy to arrange.

If you share your dates here, we'll check right away and arrange it in this chat, or you may see live availability on our site:

👉 ${SITE_URL}`;
}

/** "salamat po" / "ok, bye": the caller picks one line (not the one it sent last). */
export function closers(name: string | null, lang: Lang, thanks: boolean): string[] {
  const n = name ? `, ${name}` : '';
  return ({
    en: thanks
      ? [`It's our pleasure${n}. We're here whenever you need us.`, `You're most welcome${n}. Message us anytime and we'll take care of it.`, `Our pleasure${n}. If anything else comes to mind, we're one message away.`]
      : [`Thank you${n}. We're here whenever you need us.`, `Noted with thanks${n}. Take care, and message us anytime.`, `Thank you${n}. We'll be right here whenever you're ready.`],
    tl: thanks
      ? [`It's our pleasure po${n}. Nandito lang kami anytime.`, `Walang anuman po${n}. Message lang anytime and we'll take care of it.`, `Salamat din po${n}. Kung may maisip pa kayo, one message away lang kami.`]
      : [`Salamat po${n}. Nandito lang kami kapag kailangan ninyo.`, `Sige po${n}, ingat kayo. Message lang anytime.`, `Noted po${n}. Nandito lang kami kapag ready na kayo.`],
    bis: thanks
      ? [`Walay sapayan${n}. Naa ra mi diri anytime.`, `Salamat pud${n}. Message lang if naa moy need and we'll take care of it.`]
      : [`Salamat${n}. Naa ra mi diri kung naa moy need.`, `Noted${n}. Amping, ug message lang anytime.`],
  })[lang];
}
/** The open door under a closer when our last reply did not carry the link. */
export const readyInvite = (lang: Lang) => by(lang, {
  en: `Whenever you're ready, we can arrange the booking right here in the chat, or you may secure your dates on our site:`,
  tl: `Kapag ready po kayo, we can arrange the booking dito sa chat, o puwede ninyong i-secure ang dates sa aming site:`,
  bis: `Kung ready na mo, we can arrange the booking diri sa chat, or pwede pud i-secure ang dates sa among site:`,
}) + `\n\n👉 ${SITE_URL}`;

// bookingNudge (Lloyd 2026-09-13: one soft next step). Session 58: a Bisaya thread used to get the Taglish lines, "po"
// and all; it now has its own (the gate's no-po-in-Bislish rule found it).
/** The site part alone, when the model already closed on dates. */
export const nudgeSite = (lang: Lang) => by(lang, {
  en: `We can arrange the booking right here in the chat, or you may secure your dates on our site, where direct bookings carry our best rates:`,
  tl: `We can arrange the booking dito sa chat, o puwede ninyong i-secure ang dates sa aming site, where direct bookings carry our best rates:`,
  bis: `We can arrange the booking diri sa chat, or pwede pud i-secure ang dates sa among site, where direct bookings carry our best rates:`,
}) + `\n\n👉 ${SITE_URL}`;
/** Dates not known yet. */
export const nudgeDates = (lang: Lang) => by(lang, {
  en: `Just let us know your preferred dates, and we'll gladly check our availability for you.`,
  tl: `Sabihin lang po ang preferred dates ninyo at gladly po naming iche-check ang availability para sa inyo.`,
  bis: `Share lang ang inyong preferred dates, and amo dayon i-check ang availability para ninyo.`,
});
/** Dates known, no link in our last two replies. */
export const nudgeReady = (lang: Lang) => by(lang, {
  en: `Whenever you feel ready, we can arrange the booking right here in the chat, or you may secure your dates on our site, where direct bookings carry our best rates:`,
  tl: `Kapag ready po kayo, we can arrange the booking dito sa chat, o puwede ninyong i-secure ang dates sa aming site, where direct bookings carry our best rates:`,
  bis: `Kung ready na mo, we can arrange the booking diri sa chat, or pwede pud i-secure ang dates sa among site, where direct bookings carry our best rates:`,
}) + `\n\n👉 ${SITE_URL}`;
/** Lloyd 2026-09-17: the site once, under a resumed confirm card. */
export const confirmSiteInvite = (lang: Lang) => by(lang, {
  en: `If you'd like to see more of the home first, everything is on our site, where direct bookings enjoy our best rates:`,
  tl: `If you'd like to see more of the home first, nasa site namin po ang lahat, with our best rates for direct bookings:`,
  bis: `If you'd like to see more of the home first, naa sa among site ang tanan, with our best rates for direct bookings:`,
}) + `\n\n👉 ${SITE_URL}`;

// ---- Submit and receipt turns. Session 58: no error code reaches the guest (it is in the log), and no "Thank you, po."
// when the name is unknown. ----

/** submit-booking said 409 / dates_unavailable. */
export const datesTaken = (lang: Lang | undefined) => by(lang, {
  en: `Sorry — those dates were reserved just moments ago. If other dates suit you, just share your check-in and check-out and we'll gladly check them for you.`,
  tl: `Sorry po, kaka-reserve lang ng dates na iyon. If may ibang dates kayong gusto, share lang po ang check-in and check-out and iche-check namin agad.`,
  bis: `Sorry, kaka-reserve lang sa dates nga na. If naa moy other dates, share lang ang check-in and check-out and amo dayon i-check.`,
});
/** submit-booking failed or refused the request: the flow stays where it was. */
export const submitFailed = (lang: Lang | undefined) => by(lang, {
  en: `Sorry, that request didn't go through on our side. You may try again in a minute, or secure the dates on our site:`,
  tl: `Sorry po, hindi natuloy ang request sa side namin. You may try again in a minute, o i-secure ang dates sa aming site:`,
  bis: `Sorry, wala natuloy ang request sa among side. You may try again in a minute, or i-secure ang dates sa among site:`,
}) + `\n\n👉 ${SITE_URL}`;
export const receiptThanks = (name: string | null, lang: Lang | undefined) => by(lang, {
  en: `Thank you${withName(name)}. We've received your receipt and we'll confirm the reservation as soon as it's reviewed. You'll hear from us here.`,
  tl: `Salamat po${withName(name)}. Received na namin ang receipt — iko-confirm namin ang reservation once na-review na. Dito po namin kayo iu-update.`,
  bis: `Salamat${withName(name)}. Na-receive na namo ang receipt — amo dayon i-confirm ang reservation once na-review na. Diri ra namo mo i-update.`,
});
export const receiptAlready = (lang: Lang | undefined) => by(lang, {
  en: `Your receipt is already with us and it's being reviewed.`,
  tl: `Nasa amin na po ang receipt ninyo — nire-review na.`,
  bis: `Naa na sa amo ang receipt — gi-review na.`,
});
/** The hold ('hold') or the receipt upload link ('link') has lapsed. */
export const receiptLapsed = (what: 'hold' | 'link', lang: Lang | undefined) => by(lang, what === 'hold' ? {
  en: `Thank you. That hold has since expired — just say "book" and we'll set the dates up again.`,
  tl: `Salamat po. Nag-expire na ang hold na iyon — message lang po "book" and we'll set the dates up again.`,
  bis: `Salamat. Na-expire na ang hold — message lang "book" and amo i-set up ang dates again.`,
} : {
  en: `Thank you. That upload link has since expired — just say "book" and we'll set the dates up again.`,
  tl: `Salamat po. Nag-expire na ang upload link — message lang po "book" and we'll set the dates up again.`,
  bis: `Salamat. Na-expire na ang upload link — message lang "book" and amo i-set up ang dates again.`,
});
/** airbnb-email-sync (session 28): the welcome-back line a host sends a returning Airbnb guest from the new-booking card.
 *  Session 58: it lived in that function with an "!" and ISO dates ("2026-10-02 to 2026-10-04"); `dates` is dmRange's
 *  "Oct 2 to 4", or '' when unknown. English: the host sends it on Airbnb. */
export const welcomeBack = (first: string, dates: string) =>
  `Hi ${first}, welcome back to Cascade Hideaway. We're glad to have you with us again${dates ? ` on ${dates}` : ''}. Everything will be ready the way you like it; just message us if there's anything you need before you arrive. 🌿`;
/** The image would not open, or the upload failed for another reason: the guest sends it again. */
export const receiptRetry = (lang: Lang | undefined) => by(lang, {
  en: `Sorry, I couldn't open that image. Could you send it once more?`,
  tl: `Sorry po, hindi ko ma-open ang image. Puwede po bang i-send ulit?`,
  bis: `Sorry, wala nako ma-open ang image. Pwede i-send usab?`,
});
