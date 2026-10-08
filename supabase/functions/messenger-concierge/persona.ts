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
import { ALWAYS_CLOSE_RE, answerOnly, ASKING_RE, asksDates, asksHeld, capName, DATES_NUDGE_RE, CLOSE_START_RE, CLOSER_RE, decisionInvite, fitParagraphs, INVITE_RE, sentencesOf, thinPo } from './voice.ts';

export const pick = (lang: Lang | undefined, t: { en: string; tl: string; bis: string }): string => t[lang ?? 'en'];
const by = pick;
const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
/** The first name a host would use. SPEC-39 3.7 (live 2026-10-04, "Thank you, Ma."): a leading abbreviation or initial
 *  ("Ma.", "Jr.", one or two letters) is not the first name - "Ma. Elizabeth Reyes" is Elizabeth. */
export function first(name: string | null | undefined): string {
  const toks = (name ?? '').trim().split(/\s+/).filter(Boolean);
  return toks.find((t) => !/\.$/.test(t) && t.replace(/[^\p{L}]/gu, '').length > 2) ?? toks[0] ?? '';
}
/** s78 G8 (Maria Cleofe, profile name "Ma."): the name Cassy addresses the guest by, or null when the profile holds only an
 *  abbreviation ("Ma.", "Ma", "Jr.") - "Hi Ma., thank you" read as "Hi Mom". "Ma. Cleofe" is Cleofe (first()). */
export function addressName(name: string | null | undefined): string | null {
  const abbr = (t: string) => /^(?:ma|mª|mr|mrs|ms|dr|jr|sr|sir|maam|ma'am)\.?$/i.test(t) || /^\p{L}\.$/u.test(t);
  const toks = (name ?? '').trim().split(/\s+/).filter(Boolean);
  if (!toks.length) return null;
  if (!abbr(toks[0])) return toks.join(' '); // a plain name stays as the profile gives it
  const n = first(name);
  return n && !abbr(n) ? n : null;
}

/** REQUIRED: the capacity, said before any booking commitment (D-222). */
export const CAPACITY: Record<Lang, string> = {
  en: 'The home is most comfortable for up to 3 adults, or 2 adults with 2 children.',
  tl: 'Most comfortable ang home for up to 3 adults, or 2 adults with 2 kids.',
  bis: 'Most comfortable ang home for up to 3 adults, or 2 adults with 2 kids.',
};
/** REQUIRED: inside five days the full amount confirms the stay (D-166 / D-184); English in every register (D-258). */
export const LAST_MINUTE = `As you're arriving within the next five days, the full amount confirms your stay right away.`;

// ---- Greeting and introduction (APPROVED) ----

/** D-173 / SPEC-01, shortened by D-300.5 (Lloyd 2026-10-05): the direct answer to "are you a bot?" - the honest yes, the
 *  disclosure in one clause, and the reassurance that people see every conversation. The whole line, the name included. */
export function botReply(name: string | null, lang: Lang = 'en'): string {
  const n = first(name), c = n ? `, ${n}` : '';
  return by(lang, {
    en: `Yes${c}. I'm Cassy, Cascade's digital concierge, an AI assistant. Every conversation here is seen by Marifel and the team, and they're on top of it whenever you'd like a person.`,
    tl: `Opo${c}. Ako si Cassy, ang digital concierge ng Cascade, isang AI assistant. Lahat ng conversation dito ay nababasa ni Marifel at ng team, and they're on top of it kapag gusto ninyong makausap ang isang tao.`,
    bis: `Oo${c}. Ako si Cassy, ang digital concierge sa Cascade, usa ka AI assistant. Tanan nga conversation diri nakita ni Marifel ug sa team, ug naa ra sila kung gusto mo makig-istorya og tawo.`,
  });
}
/** D-299.10 (Lloyd 2026-10-05): no longer said - the initial message is signed instead (SIGNATURE). Kept because telegram-cassy
 *  forHost strips it from older history. Was (D-173 / SPEC-01): said once, in the first message only, directly after the greeting's
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
  en: `${name ? `Hi ${first(name)},` : 'Hello,'} thank you for reaching out to Cascade Hideaway. `,
  tl: `${name ? `Hi ${first(name)}!` : 'Hello po!'} Salamat sa pag-message sa Cascade Hideaway. `,
  bis: `${name ? `Hi ${first(name)}!` : 'Hello!'} Salamat sa pag-message sa Cascade Hideaway. `,
}) + (intro ? CASSY_INTRO[lang ?? 'en'] : '');
/** SPEC-28 section 3: with the Cassy sentence the greeting is long, so the answer goes on its own paragraph (golden
 *  first-avail-taken-en read as one block). Without it the greeting and the answer stay one paragraph: that is Lloyd's
 *  approved first reply (2026-09-18) and the lint wants the answer in the first paragraph. */
export const greetBlock = (name: string | null, lang: Lang = 'en', intro = false) => intro ? greeting(name, lang, true).trimEnd() + '\n\n' : greeting(name, lang, false);

/** D-299.10 / D-300.1 (Lloyd 2026-10-05): the initial message of a conversation is signed as a person signs - Lloyd's words,
 *  every register. Never on a flow reply inside 12 h, a card, a payment message, a handoff or any follow-up. */
export const SIGNATURE = 'Cassy, Cascade Concierge';
/** The one place the signature is added. `greetNow` (index.ts: no bot reply in this thread for 12 h) is the only input. */
export const signFirst = (reply: string, greetNow: boolean): string =>
  !greetNow || !reply.trim() || reply.trimEnd().endsWith(SIGNATURE) ? reply : `${reply.trimEnd()}\n\n${SIGNATURE}`;
/** D-297.3 / D-299.10: the first reply's one question - their dates, gently, and no link (the conversation stays here). */
export const firstDatesNudge = (lang: Lang = 'en') => by(lang, {
  en: `We'd be delighted to have you with us. Which dates are you looking at? Share your check-in and check-out here and we'll check the calendar for you right away.`,
  tl: `We'd be delighted po to have you. Kailan po ninyo gustong mag-stay? Share lang dito ang check-in at check-out and iche-check namin agad.`,
  bis: `Delighted mi to have you. Kanus-a mo gusto mag-stay? Share lang diri ang check-in ug check-out and amo dayon i-check.`,
});
/** D-300.2 trigger 2, mid-booking: the guest asked to see the home - the site link once, the photos named. */
export const seeHomeLine = (name: string | null, lang: Lang = 'en') => {
  const n = first(name), c = n ? `, ${n}` : '';
  return by(lang, {
    en: `Of course${c}. The photos of the whole home are on our site, with the live availability:`,
    tl: `Of course po${c}. Nasa site namin ang photos ng buong home, pati ang live availability:`,
    bis: `Sige${c}. Naa sa among site ang photos sa tibuok home, apil ang live availability:`,
  }) + `\n👉 ${SITE_URL}`;
};

// ---- The party ----

const TL_COUNT: Record<number, string> = { 2: 'dalawa', 3: 'tatlo', 4: 'apat' };
const BIS_COUNT: Record<number, string> = { 2: 'duha', 3: 'tulo', 4: 'upat' };
const EN_COUNT: Record<number, string> = { 2: 'two', 3: 'three', 4: 'four' };
/** The party as a host names it: "the two of you" / "kayong dalawa" (Taglish never "the two of you"). SPEC-39 4.4: with a
 *  child in it the party is a family ("your family of three", "kamong tulo"). */
export function partyName(pax: number | undefined, lang?: Lang, children = 0): string {
  if (!pax || pax === 1) return 'you';
  if (lang === 'tl') return `kayong ${TL_COUNT[pax] ?? pax}`;
  if (children > 0) return lang === 'bis' ? `kamong ${BIS_COUNT[pax] ?? pax}` : `your family of ${EN_COUNT[pax] ?? pax}`;
  return pax === 2 ? 'the two of you' : `your party of ${pax}`;
}
/** The welcome that follows an answer ("..., and we'd be delighted to welcome the two of you."). D-297.3: "delighted". */
const welcomeParty = (who: string, lang?: Lang) => by(lang, {
  en: `we'd be delighted to welcome ${who}.`, tl: `we'd be delighted to have ${who}.`, bis: `looking forward mi to have ${who}.`,
});

// ---- Availability ----

/** The calendar answered: open. `dates` is stayLabel's ("tonight (Sep 26)", "the night of Oct 5", "Oct 20 to 22"). */
export const datesOpen = (dates: string, lang?: Lang) => by(lang, { en: `${cap(dates)} is available`, tl: `Available po ang ${dates}`, bis: `Available ang ${dates}` });
/** Incident 2026-10-07 (Angel, Oct 8 to 11 confirmed with "as soon as you arrive" while another guest checked out Oct 8): an
 *  open stay whose check-in day is another guest's check-out says so once - check-in from 2:00 PM, no earlier time promised.
 *  `day` is "Oct 8". D-311.8: a Bisaya guest reads the English line. */
export const turnoverNotice = (day: string, lang?: Lang) => by(lang, {
  en: `A guest checks out that morning, so check-in on ${day} is from 2:00 PM; if the unit is ready earlier, we'll gladly let you know.`,
  tl: `May guest pong magche-check out nang umaga ng ${day}, kaya ang check-in ay from 2:00 PM; kung ready na ang unit nang mas maaga, ia-update namin kayo agad.`,
  bis: `A guest checks out that morning, so check-in on ${day} is from 2:00 PM; if the unit is ready earlier, we'll gladly let you know.`,
});
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
    en: `I'm sorry, ${dates} is already reserved. ${near}, and we'd be delighted to welcome you then. If other dates suit you better, just share your check-in and check-out and we'll gladly check them for you.`,
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
/** s74 G1: a past stay told about with a price asked ("last time we stayed Sep 5 to 7, how much now?") - nothing is quoted or held;
 *  the new dates are asked. */
export const pastStayAsk = (lang?: Lang) => by(lang, {
  en: `Happy to check that for you. Which dates would you like this time? Share them here and we'll check the calendar and the rate.`,
  tl: `Sige po, i-check namin. Aling dates ang gusto ninyo ngayon? I-share lang po dito and we'll check the calendar at ang rate.`,
  bis: `Sige, atong i-check. Unsang dates ang gusto ninyo karon? Share lang diri and we'll check ang calendar ug ang rate.`,
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
export const partyWelcome = (pax: number | undefined, lang?: Lang, children = 0) => {
  const solo = !pax || pax === 1;
  return by(lang, {
    en: solo ? `Noted, and we're already looking forward to welcoming you.` : `${cap(partyName(pax, 'en', children))}, then, and we're already looking forward to it.`,
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

/** SPEC-39 3.6: what the guest said beside their yes, returned as a host would ("Yes and thank you. Good night.").
 *  Chosen by code from the guest's words: a good night, a thank-you, or nothing. */
export type Echo = 'night' | 'thanks' | null;
export const echoOf = (text: string): Echo => /\b(good ?night|gabi)\b/i.test(text) ? 'night' : /\b(thank|salamat)/i.test(text) ? 'thanks' : null;
/** The details, asked once for all three so one reply can finish them (protocol: fewer steps beat more). `thank` false
 *  when a line above already acknowledged the guest (the price or the party welcome). */
export const detailsAsk = (name: string, lang?: Lang, thank = true, echo: Echo = null) => {
  const n = name ? `, ${name}` : '';
  const lead = !thank ? '' : echo === 'night'
    ? by(lang, { en: `Good night to you too${n}, and thank you. `, tl: `Good night din po${n}, at salamat. `, bis: `Good night pud${n}, ug salamat. ` })
    : echo === 'thanks'
    ? by(lang, { en: `It's our pleasure${n}. `, tl: `Walang anuman po${n}. `, bis: `Walay sapayan${n}. ` })
    : by(lang, { en: name ? `Thank you, ${name}. ` : '', tl: name ? `Salamat, ${name}. ` : 'Salamat po. ', bis: name ? `Salamat, ${name}. ` : 'Salamat. ' });
  return lead + by(lang, {
    en: `To prepare your reservation, may we have your full name, a mobile number we can reach you on, and an email for the confirmation? All three in one message is easiest.`,
    tl: `Para ma-prepare ang reservation ninyo, maaari po ba naming makuha ang full name, mobile number, at email para sa confirmation? Okay lang na sabay-sabay sa isang message.`,
    bis: `Para ma-prepare ang inyong reservation, pwede namo makuha ang full name, mobile number, ug email for the confirmation? Okay ra nga usa ra ka message.`,
  });
};
/** SPEC-14 (D-184): after a partial answer, only the first missing item is asked for. `who` is the reservation name. */
export function nextDetail(missing: 'name' | 'phone' | 'email', who: string, lang?: Lang): string {
  if (missing === 'name') return by(lang, { en: `Thank you. And the name for the reservation?`, tl: `Salamat po. At ang pangalan para sa reservation?`, bis: `Salamat. Ug ang name for the reservation?` });
  if (missing === 'phone') return by(lang, { en: `Thank you, ${who}. And a mobile number we can reach you on?`, tl: `Salamat po, ${who}. At ang mobile number na matatawagan namin?`, bis: `Salamat, ${who}. Ug ang mobile number nga ma-contact namo?` });
  return by(lang, { en: `Thank you, ${who}. And an email address for your confirmation?`, tl: `Salamat po, ${who}. At ang email address para sa confirmation?`, bis: `Salamat, ${who}. Ug ang email address for your confirmation?` });
}

// ---- The confirm card ----

export type CardFacts = { resume: boolean; who: string | null; range: string; nights: number; pax: number | undefined; phone: string | undefined; email: string | null | undefined; total: string; promo: { name: string; nights: number; rate: string } | null;
  /** SPEC-39 4.4: children in the party (pax is the total) */
  children?: number;
  /** SPEC-39 3.6b: the booking exists - its reference, and the 24-hour hold (until/rel) or none (full payment) */
  ref?: string; hold?: boolean; until?: string | null; rel?: string };
/** The stay at a glance, one fact per line; `resume` after a mid-flow question (Lloyd 2026-09-17: nudge subtly). */
export function stayCard(c: CardFacts, lang?: Lang): string {
  const s = (k: number | undefined) => (k === 1 ? '' : 's');
  const kids = c.children && c.pax && c.pax > c.children ? ` (${c.pax - c.children} adult${s(c.pax - c.children)}, ${c.children} ${c.children === 1 ? 'child' : 'children'})` : '';
  return [
    c.resume
      ? by(lang, { en: `Here's your stay, ready whenever you are:`, tl: `Ito po ang stay ninyo, ready whenever you are:`, bis: `Mao ni ang inyong stay, ready whenever you are:` })
      : by(lang, { en: `Here are your stay details:`, tl: `Ito po ang details ng stay ninyo:`, bis: `Mao ni ang details sa stay ninyo:` }),
    ...(c.who ? [`👤 ${c.who}`] : []),
    `📅 ${c.range} · ${c.nights} night${s(c.nights)} · ${c.pax} guest${s(c.pax)}${kids}`,
    `📞 ${c.phone}${c.email ? ` · ${c.email}` : ''}`,
    `💰 Total ${c.total}${c.ref ? ` · reference ${c.ref}` : ''}`,
    ...(c.promo ? [`🏷️ ${c.promo.name}: ${c.promo.nights} night${s(c.promo.nights)} at ${c.promo.rate}`] : []),
    by(lang, { en: `🔐 ₱1,000 refundable security deposit, returned after check-out`, tl: `🔐 ₱1,000 refundable security deposit, ibabalik after check-out`, bis: `🔐 ₱1,000 refundable security deposit, i-uli after check-out` }),
    ...(!c.ref ? [] : c.hold && c.until
      ? [by(lang, { en: `⏳ Held for you for 24 hours, until ${c.until} (${c.rel})`, tl: `⏳ Naka-hold na para sa inyo for 24 hours, until ${c.until} (${c.rel})`, bis: `⏳ Naka-hold na para ninyo for 24 hours, until ${c.until} (${c.rel})` })]
      : [by(lang, { en: `⏳ Yours as soon as the payment arrives`, tl: `⏳ Sa inyo na ito once dumating ang payment`, bis: `⏳ Inyo na ni once muabot ang payment` })]),
  ].join('\n');
}

// ---- SPEC-39 3.6b (D-300.3): the stay details and the payment in ONE message, the nudge in the guest's own tone ----

/** Read from the guest by booking.ts toneOf: brisk (short, plain), warm (the default), gentle (hesitant or first-timer). */
export type Tone = 'brisk' | 'warm' | 'gentle';
/** `fullOnly`: only the full amount is due now (inside five days, or the guest chose it); `near`: inside five days. */
export type PayFacts = { deposit: string; total: string; fullOnly: boolean; near?: boolean; dates: string; name: string; party?: string };
const GCASH = '0956 011 5744';
/** The payment paragraph and the receipt line, after the stay card. Facts in every variant: the 50% reservation fee holds
 *  the dates; the balance and the ₱1,000 refundable deposit at least a day before check-in; or the full amount now; inside
 *  five days only the full amount. The amount-set QR is the image of the same turn. */
export function payNudge(p: PayFacts, tone: Tone, lang?: Lang): string {
  const L = lang ?? 'en', n = p.name, c = n ? `, ${n}` : '';
  const pay = p.fullOnly
    ? by(L, {
        // D-322 (Lloyd 2026-10-08, the booking site's Pay in Full line): the deposit is handed over on arrival on this path.
        en: `${p.near ? 'As your check-in is near, the' : 'The'} full ${p.total} secures your stay: the QR below carries the exact amount, or GCash ${GCASH}. You arrive with only the ₱1,000 refundable deposit to hand over.`,
        tl: `${p.near ? 'Malapit na po ang check-in, kaya ang' : 'Ang'} full ${p.total} ang magse-secure ng stay: naka-set na ang exact amount sa QR below, o GCash ${GCASH}. Pagdating ninyo, ang ₱1,000 refundable deposit na lang ang iaabot.`,
        bis: `${p.near ? 'Duol na ang check-in, so ang' : 'Ang'} full ${p.total} ang mag-secure sa stay: naka-set na ang exact amount sa QR below, o GCash ${GCASH}. You arrive with only the ₱1,000 refundable deposit to hand over.` })
    : tone === 'brisk' ? by(L, {
        en: `The ${p.deposit} reservation fee holds these dates: the QR below carries the exact amount, or GCash ${GCASH}. The balance and the ₱1,000 deposit follow at least a day before check-in. If you'd rather settle the full ${p.total} now, a quick "full" here brings that QR instead.`,
        tl: `Ang ${p.deposit} reservation fee ang magho-hold ng dates: naka-set na ang exact amount sa QR below, o GCash ${GCASH}. Ang balance at ang ₱1,000 deposit ay due at least a day before check-in. Kung mas gusto ninyo ang full ${p.total} ngayon, "full" lang dito at ipapadala namin ang QR na iyon.`,
        bis: `Ang ${p.deposit} reservation fee ang mo-hold sa dates: naka-set na ang exact amount sa QR below, o GCash ${GCASH}. Ang balance ug ang ₱1,000 deposit kay due at least a day before check-in. Kung mas gusto ninyo ang full ${p.total} karon, "full" lang diri ug i-send namo ang QR para didto.` })
    : tone === 'gentle' ? by(L, {
        en: `No rush at all${c}, and nothing is charged until you decide. When you're ready, the ${p.deposit} reservation fee holds ${p.dates} for you: the QR below carries the exact amount, or GCash ${GCASH}, so there's nothing to type.\n\nThe balance and the ₱1,000 refundable deposit follow at least a day before check-in; or, if you'd prefer, the full ${p.total} now, and a "full" here brings that QR.`,
        tl: `Walang rush po${c}, at wala pang babayaran hangga't hindi pa kayo decided. Kapag ready na kayo, ang ${p.deposit} reservation fee ang magho-hold ng ${p.dates} para sa inyo: naka-set na ang exact amount sa QR below, o GCash ${GCASH}, so wala nang ita-type.\n\nAng balance at ang ₱1,000 refundable deposit ay due at least a day before check-in; o kung mas gusto ninyo, ang full ${p.total} ngayon, "full" lang dito at ipapadala namin ang QR na iyon.`,
        bis: `Walay rush${c}, ug wala pay bayranan hangtod dili pa mo decided. Kung ready na mo, ang ${p.deposit} reservation fee ang mo-hold sa ${p.dates} para ninyo: naka-set na ang exact amount sa QR below, o GCash ${GCASH}, so wala nay i-type.\n\nAng balance ug ang ₱1,000 refundable deposit kay due at least a day before check-in; o kung mas gusto ninyo, ang full ${p.total} karon, "full" lang diri ug i-send namo ang QR para didto.` })
    : by(L, {
        en: `We'd be delighted to have ${p.party ?? 'you'}. The ${p.deposit} reservation fee holds these dates: the QR below carries the exact amount, or GCash ${GCASH}. The balance and the ₱1,000 refundable deposit are due at least a day before check-in; or you may settle the full ${p.total} now, and a "full" here brings that QR instead.`,
        tl: `Para ma-secure ang dates, ang ${p.deposit} reservation fee lang ang kailangan ngayon: naka-set na ang exact amount sa QR below, o GCash ${GCASH}. Ang balance at ang ₱1,000 refundable deposit ay due at least a day before check-in. Kung mas gusto ninyong bayaran na ang full ${p.total} ngayon, sabihin lang "full" at ipapadala namin ang QR para doon.`,
        bis: `Para ma-secure ang dates, ang ${p.deposit} reservation fee ra ang kinahanglan karon: naka-set na ang exact amount sa QR below, o GCash ${GCASH}. Ang balance ug ang ₱1,000 refundable deposit kay due at least a day before check-in. Kung mas gusto ninyo bayran na ang full ${p.total} karon, ingna lang mi og "full" ug i-send namo ang QR para didto.` });
  const receipt = tone === 'brisk' ? by(L, {
      en: `A screenshot of the receipt here is all we need, and we'll confirm right away.`,
      tl: `Screenshot lang po ng receipt dito, at iko-confirm namin agad.`,
      bis: `Screenshot ra sa receipt diri, ug i-confirm dayon namo.` })
    : tone === 'gentle' ? by(L, {
      en: `A screenshot of the receipt here is all we need; Marifel and the team then confirm it personally, and we take care of the rest.`,
      tl: `Screenshot lang po ng receipt dito; si Marifel at ang team mismo ang magko-confirm, and we take care of the rest.`,
      bis: `Screenshot ra sa receipt diri; si Marifel ug ang team mismo ang mo-confirm, ug amo nang atimanon ang uban.` })
    : by(L, {
      en: `Once done, a screenshot of the receipt here is all we need, and we'll confirm right away. 🌿`,
      tl: `Once done, screenshot lang po ng receipt dito, and iko-confirm na namin ang stay ninyo. Excited na rin kaming i-welcome kayo. 🌿`,
      bis: `Once done, screenshot ra sa receipt diri, ug i-confirm na namo ang inyong stay. Excited na pud mi mo-welcome ninyo. 🌿` });
  return `${splitLong(pay)}\n\n${receipt}`; // a paragraph over 320 splits at a sentence (protocol rule 4)
}
/** D-300.3: "full" after the hold - the QR for the full amount follows this line; no second card. */
export const fullSwitchLine = (name: string, total: string, lang?: Lang) => {
  const n = first(name), c = n ? `, ${n}` : '';
  return by(lang, {
    // D-322: on the Pay in Full path the deposit is handed over on arrival (the booking site's line).
    en: `Of course${c}. Here is the QR for the full ${total}; you then arrive with only the ₱1,000 refundable deposit to hand over.`,
    tl: `Sige po${c}. Ito ang QR para sa full ${total}; pagdating ninyo, ang ₱1,000 refundable deposit na lang ang iaabot.`,
    bis: `Sige${c}. Mao ni ang QR para sa full ${total}; you then arrive with only the ₱1,000 refundable deposit to hand over.`,
  });
};
/** D-300.3: "fee" / "yes" / "ok" after the QR - nothing left to choose, and no second QR. `full`: the QR carries the full amount. */
export const feeAckLine = (name: string, amount: string, full: boolean, lang?: Lang) => {
  const n = first(name), c = n ? `, ${n}` : '', what = full ? 'payment' : 'fee';
  return by(lang, {
    en: `Thank you${c}. The QR above already carries the ${amount} ${what}, so there's nothing more to choose; whenever it's done, a screenshot here is all we need.`,
    tl: `Salamat po${c}. Nasa QR above na ang ${amount} ${what}, so wala na pong pipiliin; kapag tapos na, screenshot lang dito.`,
    bis: `Salamat${c}. Naa na sa QR above ang ${amount} ${what}, so wala nay pilionon; kung human na, screenshot ra diri.`,
  });
};
/** SPEC-39 4.2: "until Nov 30" with no check-in yet - the check-out is noted and the check-in asked. */
export const checkinAsk = (checkout: string, lang?: Lang) => by(lang, {
  en: `Noted, until ${checkout}. From which date would you like to check in?`,
  tl: `Noted po, hanggang ${checkout}. Kailan po ang check-in ninyo?`,
  bis: `Noted, hangtod ${checkout}. Kanus-a ang inyong check-in?`,
});

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
/** D-300.4 (Lloyd 2026-10-05: the forced Tagalog host line read worse than English): English in every register. */
export const discountHostLine = (_lang?: Lang) => DISCOUNT_HOST_PAST.en;
/** Every wording the host line has had, so index.ts still finds it in older history (said once per thread). */
export const DISCOUNT_HOST_PAST: Record<Lang, string> = {
  en: `Our host also looks at special requests personally, so we've shared your message with them.`,
  tl: `Personal ding tinitingnan ng host ang special requests, kaya na-share na namin ang message ninyo.`,
  bis: `Personal pud nga gitan-aw sa among host ang special requests, so na-share na namo ang inyong message.`,
};

/** D-311.6 (Lloyd 2026-10-07): every discount or haggle request ("can you do 1,500 a night?", "may discount po ba?", "medyo
 *  mahal po") is met simply - we understand and will do our best - with NO rate explanation; the host line and the hold
 *  question follow. "completely understand" is allowed again (it had been banned in the checker). */
export const haggleLine = (lang?: Lang) => by(lang, {
  en: `We completely understand, and we'll do our best to accommodate your request.`,
  tl: `We completely understand po, and we'll do our best to accommodate your request.`,
  bis: `We completely understand, and we'll do our best to accommodate your request.`, // D-311.8: a Bisaya guest gets English
});
/** The hold question after the host line: the stay's dates when we know them and they are open, else the dates asked. */
export const haggleHold = (dates: string | null, lang?: Lang) => dates ? by(lang, {
  en: `Would you like us to hold ${dates} for you in the meantime?`,
  tl: `Gusto po ba ninyong i-hold muna namin ang ${dates} para sa inyo in the meantime?`,
  bis: `Would you like us to hold ${dates} for you in the meantime?`,
}) : by(lang, {
  en: `May we know your dates, so we can hold them for you in the meantime?`,
  tl: `Maaari po ba naming malaman ang dates ninyo, para ma-hold namin ang mga ito para sa inyo in the meantime?`,
  bis: `May we know your dates, so we can hold them for you in the meantime?`,
});

/** D-311.1 (golden promo-ask-en: the TL reply named the Anniversary Promotion, the EN reply did not): a promo question names
 *  the live promotions from the rate card in its first paragraph, AND says booking direct is itself the better price. */
export const directBetter = (lang?: Lang) => by(lang, {
  en: `Booking direct is itself the better price, too: our direct rates are lower than on Airbnb and the other booking apps.`,
  tl: `Mas mababa rin po ang direct rates namin kaysa sa Airbnb at sa ibang booking apps, kaya booking direct is itself the better price.`,
  bis: `Booking direct is itself the better price, too: our direct rates are lower than on Airbnb and the other booking apps.`,
});
export const DIRECT_BETTER_RE = /lower than (?:on )?airbnb|kaysa sa airbnb|other booking apps|ibang booking apps/i;
export type PromoFacts = { name: string; when: string; rate: string; base: string };
/** Facts sealed by index.ts (the live card): name, nights ("Oct 11 to 17"), the promo rate and the standard, as "PHP 1,543". */
export function promoLine(ps: PromoFacts[], lang?: Lang): string {
  if (!ps.length) return directBetter(lang);
  const each = ps.map((p) => by(lang, {
    en: `our ${p.name} brings the nights of ${p.when} to ${p.rate} per night instead of our standard ${p.base}`,
    tl: `ang ${p.name} namin ay ${p.rate} per night para sa nights ng ${p.when}, imbes na ang standard ${p.base}`,
    bis: `our ${p.name} brings the nights of ${p.when} to ${p.rate} per night instead of our standard ${p.base}`,
  })).join('; ');
  return `${by(lang, { en: 'Yes, ', tl: 'Opo, ', bis: 'Yes, ' })}${each}. ${directBetter(lang)}`;
}
/** The promo answer leads with the promotions and the direct-price point: the model's answer is kept when its first paragraph
 *  already names every promo rate (the direct sentence joins it if missing); otherwise code's line opens the answer and only
 *  the model's last sentence follows - its sentence of care (OUTPUT_ANSWER) - so nothing is said twice and the message stays
 *  under 700 characters (a first try kept every other sentence: 757). */
export function promoFirst(answer: string, ps: PromoFacts[], lang?: Lang): string {
  const paras = answer.split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean);
  const nums = ps.map((p) => p.rate.replace(/^\D+/, ''));
  if (paras[0] && nums.every((n) => paras[0].includes(n))) {
    return DIRECT_BETTER_RE.test(answer) ? paras.join('\n\n') : [`${paras[0]} ${directBetter(lang)}`, ...paras.slice(1)].join('\n\n');
  }
  const care = paras.flatMap((p) => sentencesOf(p)).map((s) => s.trim()).filter((s) => s && !nums.some((n) => s.includes(n)) && !DIRECT_BETTER_RE.test(s)).pop();
  return [promoLine(ps, lang), care ?? ''].filter(Boolean).join('\n\n');
}

/** D-311.8 (golden reg-bot-bis: "Pila ang rate kada gabii?" got a bare rate and a question): a short rate answer with no
 *  marker of care still cold after the one rewrite gets this clause (R3). */
export const warmClause = (lang?: Lang, booked = false) => booked ? by(lang, {
  // s78 (Angel replay turn 17: "free drinking water?" on a booked stay closed on "exact total ... once may dates na kayo"): a guest
  // with a booking is never sent a booking-flow line.
  en: `We'll have everything ready for your stay.`,
  tl: `Ihahanda po namin ang lahat para sa stay ninyo.`,
  bis: `We'll have everything ready for your stay.`,
}) : by(lang, {
  en: `We'd be glad to work out the exact total for you once your dates are set.`,
  tl: `Iche-check namin agad ang exact total para sa inyo once may dates na kayo.`,
  bis: `We'd be glad to work out the exact total for you once your dates are set.`,
});
/** s78 (TASKS #6, Angel turns 13 and 19): the stay card's payment terms, said back when a booked guest proposes another timing
 *  ("pay the deposit pag nasa area na", "we will send the deposit tomorrow"). The booking site is the policy source: the ₱1,000
 *  deposit is due with the balance at least a day before check-in; inside five days the full amount is paid now. `balance` ''
 *  when the full amount is the payment. Never agrees to pay on arrival. */
export function payTermsLine(name: string | null, lang: Lang, f: { total: string; balance: string; paid: boolean; accept?: boolean }): string {
  const c = withName(name);
  // F2 (Fable audit f3c4126; the booking site, Pay in Full: "covers the whole stay, and you arrive with only the ₱1,000 refundable
  // deposit to hand over"): on the full-payment path a deposit handed over on arrival IS the term - agreed warmly, no lecture.
  if (f.accept) return by(lang, {
    en: `Yes, that's right${c}. With the full ${f.total} covering the whole stay, you arrive with only the ₱1,000 refundable security deposit to hand over, and it's returned after check-out. 🌿`,
    tl: `Opo, tama po${c}. Since covered na ng full ${f.total} ang buong stay, ang ₱1,000 refundable security deposit na lang ang iaabot ninyo pagdating, at ibabalik ito after check-out. 🌿`,
    bis: `Yes, that's right${c}. With the full ${f.total} covering the whole stay, you arrive with only the ₱1,000 refundable security deposit to hand over, and it's returned after check-out. 🌿` });
  const terms = f.balance
    ? by(lang, {
        en: `as on your stay card, the remaining ${f.balance} balance and the ₱1,000 refundable security deposit are due at least a day before check-in, so everything is settled before you arrive.`,
        tl: `gaya ng nasa stay card ninyo, ang natitirang ${f.balance} balance at ang ₱1,000 refundable security deposit ay due at least a day before check-in, para settled na ang lahat bago kayo dumating.`,
        bis: `as on your stay card, the remaining ${f.balance} balance and the ₱1,000 refundable security deposit are due at least a day before check-in, so everything is settled before you arrive.` })
    : by(lang, {
        en: `the full ${f.total} covers the whole stay and confirms it, and you arrive with only the ₱1,000 refundable security deposit to hand over.`,
        tl: `ang full ${f.total} ang sumasaklaw sa buong stay at nagko-confirm nito, at ang ₱1,000 refundable security deposit na lang ang iaabot ninyo pagdating.`,
        bis: `the full ${f.total} covers the whole stay and confirms it, and you arrive with only the ₱1,000 refundable security deposit to hand over.` });
  const head = by(lang, { en: `Noted${c}, thank you. Just so it's clear, `, tl: `Noted po${c}, salamat. Para malinaw, `, bis: `Noted${c}, thank you. Just so it's clear, ` });
  const tail = f.paid
    ? by(lang, { en: `Our host is reviewing what you've sent and will confirm everything here.`, tl: `Nire-review na ng host ang na-send ninyo, and they'll confirm everything here.`, bis: `Our host is reviewing what you've sent and will confirm everything here.` })
    : by(lang, { en: `Once it's sent, a screenshot here is all we need. 🌿`, tl: `Once na-send na, screenshot lang dito ang kailangan namin. 🌿`, bis: `Once it's sent, a screenshot here is all we need. 🌿` });
  return `${head}${terms}\n\n${tail}`;
}

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
    // D-322: the Pay in Full path - the deposit is handed over on arrival (the booking site's line).
    ? by(L, { en: `You arrive with only the ₱1,000 refundable security deposit to hand over.`, tl: `Pagdating ninyo, ang ₱1,000 refundable security deposit na lang po ang iaabot.`, bis: `You arrive with only the ₱1,000 refundable security deposit to hand over.` })
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
// D-282: a guest-tier house fact (Wi-Fi password, door entry, key card) asked by a thread not yet verified. Never says
// what the fact is; the answer is parsed like the priority ask, then the original question is answered.
export const houseVerifyAsk = (lang: Lang) => by(lang, {
  en: `That detail is kept for guests staying with us. May we have your check-in date and the name on your booking? For example: Sept 27, Ana.`,
  tl: `Para po sa mga guest na naka-stay sa amin ang detail na iyan. Ano ang check-in date ninyo at ang name sa booking? Halimbawa: Sept 27, Ana.`,
  bis: `Para sa mga guest nga naka-stay karon namo ang maong detail. Unsa ang inyong check-in date ug ang name sa booking? Pananglitan: Sept 27, Ana.`,
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
  // D-300.2: no link here - the guest asked about a time, not how to book or to see the home.
  if (lang === 'bis') return `${open}${c('Salamat')} sa pagpangutana. We'd be glad to arrange that for you: depende ni sa calendar anang adlawa, and kung walay laing guest nga moabot o mobiya that day, sayon ra ma-arrange.

Share lang diri ang inyong dates and we'll check right away.`;
  if (lang === 'tl') return `${open}${c('Salamat')} po sa pagtanong. We'd be glad to arrange that for you: depende ito sa calendar ng araw na iyon, and kapag walang ibang guest na dumarating o umaalis that day, madali pong ma-arrange.

Share lang dito ang dates ninyo and we'll check right away.`;
  return `${open}${c('We')}'d be glad to arrange that for you. It depends on the calendar for that day: when no other guest arrives or leaves the same day, it's easy to arrange.

If you share your dates here, we'll check right away and arrange it in this chat.`;
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

// ---- D-286: the model writes only the answer; code composes the message around it ----
// DESIGN-model-answers-code-composes-2026-09-30. The model returns {answer, ask}; this writes the greeting and Cassy's
// introduction (their own paragraph), the ONE next step, and a close only after a link. The frame used to be written twice
// - by the model and by seventeen repairs in index.ts - and every new fault was a combination nobody had tested.

export type ComposeCtx = {
  lang: Lang;
  name: string | null;
  /** the first reply in the thread (nothing answered yet): greeted, the dates asked, signed, no link (D-299.10) */
  greet: boolean;
  /** D-300.1: the initial message of a conversation (no bot reply in 12 h) - the one signed message, whoever wrote it */
  greetNow: boolean;
  /** our last reply was under 6 hours ago */
  followUp: boolean;
  /** mid-booking: the flow's own card and ask follow the answer, and nothing else does */
  flowFollowUp: string | null;
  /** D-300.2 mid-booking: the guest asked to see the home - seeHomeLine's block before the flow's ask ('' otherwise) */
  seeHome?: string;
  /** D-269: the discount host line, once per thread ('' otherwise) */
  hostLine: string;
  /** a pay hold, a staying guest, an open host matter: the answer only */
  quiet: boolean;
  /** lookNudge's block ('' when none) */
  look: string;
  /** "think about it", "how do I book" on a follow-up */
  decision: boolean;
  /** D-300.2: the guest asked for something the site answers - how to book, the site itself, photos, reviews (index.ts linkTurn) */
  linkTurn: boolean;
  /** the link is in one of our last four replies: never repeated in one stretch of conversation */
  siteShown: boolean;
  datesKnown: boolean;
  held: { dates: boolean; pax: boolean; name: boolean };
  /** our previous reply, so the close is never the same twice (R8) */
  prevBot: string;
};

/** SPEC-13 / D-176: the look block with the chat route in front of it - both routes, one invitation. */
const LOOK_LEAD: Record<Lang, string> = {
  en: `When you have dates in mind, just tell us here and we'll arrange the booking in this chat.`,
  tl: `Kapag may dates na kayo, sabihin lang dito and we'll arrange the booking sa chat.`,
  bis: `Kung naa na moy dates, ingna lang mi diri and we'll arrange the booking sa chat.`,
};
function lookStep(look: string, c: ComposeCtx): string {
  const [sentence, ...links] = look.split(/\n\s*\n/);
  const block = `${sentence.trim().replace(/[.\s]*$/, ':')}\n${links.join('\n').trim()}`;
  return look.includes(SITE_URL) ? `${LOOK_LEAD[c.lang]} ${block}` : block; // reviews only: the reviews line alone
}

const unpo = (s: string) => s.replace(/ po\b/g, ''); // thinPo may have taken a "po" out of the line we sent
/** D-286: the one next step (design section 1, first match wins). '' = nothing. SPEC-39: the first reply asks for the dates
 *  and carries no link (D-299.10); after it the site comes only when the guest asks for what it answers (D-300.2). */
export function nextStep(c: ComposeCtx, ask: string | null): string {
  if (c.flowFollowUp || c.quiet) return '';                                   // 1-2: the flow's card, or the answer alone
  if (c.greet) return c.datesKnown ? '' : firstDatesNudge(c.lang);            // 6: first contact - their dates, no link
  if (c.look) return lookStep(c.look, c);                                     // 3: look before you book (photos, reviews)
  // D-311.4 (golden fu-howtobook-en: a follow-up "How do I book?" got the model's dates question and no link): the guest asked
  // for the ways to book, so the two ways - this chat or the site - come before any question of the model's.
  if (c.linkTurn && !c.siteShown) return c.datesKnown ? nudgeReady(c.lang) : nudgeSite(c.lang); // 6b: the site, asked for
  if (ask && !asksHeld(ask, c.held)) return ask.trim();                       // 4: the model's one question
  if (c.decision) return decisionInvite(c.lang, SITE_URL);                    // 5: a decision moment
  // 7 - their dates, never the same dates line twice in a row (golden AFTER 2026-09-30, R8); no unprompted link
  if (!c.datesKnown) return unpo(c.prevBot).trimEnd().endsWith(unpo(nudgeDates(c.lang))) ? '' : nudgeDates(c.lang);
  return '';
}

/** The prospect closes, one 🌿 each (the Oct 27 example's "prepared before you arrive" was said to guests with no booking). */
const CLOSES: Record<Lang, string[]> = {
  en: [`We'd be delighted to welcome you. 🌿`, `We look forward to welcoming you to Cascade. 🌿`, `We'd love to have you with us. 🌿`],
  tl: [`We'd be glad to have you dito sa Cascade. 🌿`, `We're looking forward to welcoming you. 🌿`],
  bis: [`Looking forward mi to have you. 🌿`, `Looking forward mi sa inyong stay sa Cascade. 🌿`],
};
/** The close under a link, never the one our previous reply ended on. */
export function closeLine(lang: Lang, prevBot: string): string {
  const last = prevBot.trim().split('\n').pop()?.trim() ?? '';
  return CLOSES[lang].find((x) => x !== last) ?? CLOSES[lang][0];
}

const THANKED_SENTENCE_RE = /thank you for (reaching out|messaging|checking|asking)|welcome to cascade|salamat(?: po)? sa pag-?(?:message|mensahe|reach out)/i;
const TO_YOU_TOO_RE = /^(?:and\s+)?(?:good (?:morning|afternoon|evening|day)\s+)?to you(?: too| as well)?(?:\s+po)?[,.!]?\s*/i;
const FOLLOW_LINE_RE = /^\s*(hello|hi|hey|good (morning|afternoon|evening)|kumusta|kamusta|maayong \w+)[^\n]{0,60}?[!.,]?\s*\n+/i;
const FOLLOW_INLINE_RE = /^\s*(hello|hi|hey|maayong \p{L}+|magandang \p{L}+|good (?:morning|afternoon|evening)|kumusta|kamusta)( po)?,?\s+((?:sir|ma'?am)\s+)?(\p{Lu}[\p{L}'-]*[,!.])/iu;
const URL_LINE_RE = /https?:\/\/|^\s*👉\s*$/;
const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** D-286: the one guard over the model's frame. Drops a leading salutation (when code greets, or on a follow-up - "Hi Ben,"
 *  becomes "Ben,"), the greeting's thank-you and Cassy sentences when code greets, every link line and the ":" sentence
 *  that introduced it, invitation and closing sentences, and every 🌿. `stripped` is logged as frame_stripped, so we can
 *  measure how often the model still writes a frame. May return '' (an answer that was all frame). */
export function cleanAnswer(answer: string, o: { greeted: boolean; followUp: boolean; name?: string | null; codeCloses?: boolean; datesAsked?: boolean }): { text: string; stripped: string[] } {
  const stripped: string[] = [];
  let t = answer.trim();
  if (t.includes('🌿')) { stripped.push('🌿'); t = t.replace(/[ \t]*🌿/gu, ''); }
  if (o.greeted) {
    const who = `(?:${o.name ? esc(first(o.name)) + '|' : ''}there)?`;
    const m = new RegExp(`^\\s*(?:hi|hello|hey|good (?:morning|afternoon|evening)|kumusta|kamusta|maayong \\p{L}+|magandang \\p{L}+)(?: po)?[ ,]*${who}[,.!]?\\s*`, 'iu').exec(t);
    if (m && m[0].trim()) { stripped.push(m[0].trim()); t = t.slice(m[0].length).replace(TO_YOU_TOO_RE, ''); }
  } else if (o.followUp) {
    const before = t;
    t = t.replace(FOLLOW_LINE_RE, '').replace(FOLLOW_INLINE_RE, (_m, _a, _b, s: string | undefined, n: string) => `${s ? s[0].toUpperCase() + s.slice(1) : ''}${n}`.replace(/!$/, ','));
    if (t !== before) stripped.push('salutation');
  }
  const kept: string[] = [];
  for (const line of t.split('\n')) {
    if (URL_LINE_RE.test(line)) { // the link line goes, and the ":" sentence above it
      stripped.push(line.trim());
      for (let i = kept.length - 1; i >= 0; i--) {
        if (!kept[i].trim()) continue;
        if (/:\s*$/.test(kept[i])) { const ss = sentencesOf(kept[i]); stripped.push(ss.pop()!.trim()); kept[i] = ss.join('').trimEnd(); }
        break;
      }
      continue;
    }
    kept.push(sentencesOf(line).filter((s) => {
      const drop = (INVITE_RE.test(s) && ASKING_RE.test(s)) || s.search(CLOSER_RE) >= 0 || ALWAYS_CLOSE_RE.test(s) || (!!o.codeCloses && CLOSE_START_RE.test(s))
        || (!!o.datesAsked && DATES_NUDGE_RE.test(s) && !/\?\s*$/.test(s)) // the ask or the next step already asks for dates
        || (o.greeted && (THANKED_SENTENCE_RE.test(s) || /\bCassy\b/.test(s)));
      if (drop && s.trim()) stripped.push(s.trim());
      return !drop;
    }).join('').trimEnd());
  }
  const text = kept.join('\n').split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean).join('\n\n').replace(/^\p{Ll}/u, (c) => c.toUpperCase());
  return { text, stripped };
}

/** Golden AFTER #2 (R10): the code's stay figures plus the sentence of care made one answer paragraph of 330-360 characters.
 *  A paragraph over 320 splits at the sentence boundary nearest its middle. */
const splitLong = (answer: string) => answer.split(/\n\s*\n/).flatMap((p) => {
  const ss = p.length > 320 ? sentencesOf(p) : [];
  if (ss.length < 2) return [p];
  let best = 1, cost = Infinity;
  for (let k = 1; k < ss.length; k++) { const a = ss.slice(0, k).join('').length, m = Math.max(a, p.length - a); if (m < cost) { cost = m; best = k; } }
  return [ss.slice(0, best).join('').trim(), ss.slice(best).join('').trim()];
}).join('\n\n');
/** A sentence that belongs to the answer (the host line, a first reply's ask) closes its last paragraph when it fits. */
const joinLast = (answer: string, s: string) => {
  if (!answer) return s;
  const ps = answer.split(/\n\s*\n/);
  if (ps[ps.length - 1].length + s.length < 320) ps[ps.length - 1] = `${ps[ps.length - 1]} ${s}`; else ps.push(s);
  return ps.join('\n\n');
};

/** D-286: the whole message from the model's answer. `fitted` is true when the answer had to be joined into two
 *  paragraphs (logged as frame_fit; the golden pass bar is zero). */
export function compose(m: { answer: string; ask: string | null }, c: ComposeCtx): { reply: string; stripped: string[]; fitted: boolean } {
  // SPEC-39 3.1 (Q2: the dates alone): on a first reply with no dates, code asks for them - the model's own question (dates or
  // name) would be a second one, and two read like a form.
  const ask = c.greet && !c.datesKnown ? null : m.ask?.trim() || null;
  // A first reply with dates known asks inside the answer; a quiet turn's own question stays.
  const askInAnswer = !!ask && !c.flowFollowUp && (c.greet || c.quiet) && !asksHeld(ask, c.held);
  const step = nextStep(c, askInAnswer ? null : ask);
  const close = !c.greet && /https?:\/\/\S+\s*$/.test(step) ? closeLine(c.lang, c.prevBot) : '';
  // The model's sentence of care stays unless code closes the message (golden AFTER 2026-09-30: stripped, replies read cold).
  const datesAsked = (!!ask && !asksHeld(ask, c.held) && asksDates(ask)) || asksDates(step);
  const clean = cleanAnswer(m.answer, { greeted: c.greet, followUp: c.followUp, name: c.name, codeCloses: !!close, datesAsked });
  let answer = splitLong(c.flowFollowUp ? answerOnly(clean.text) : clean.text);
  if (c.hostLine) answer = joinLast(answer, c.hostLine);
  if (askInAnswer) answer = joinLast(answer, ask!);
  const fit = fitParagraphs(answer, 2);
  // D-299.10: no introduction sentence. SPEC-39 3.1 (s73 F3, golden s63-month: a stay quote shared the greeting's paragraph and
  // the reply read as one block): the greeting is its own paragraph - greeting, answer (at most two), next step = four at most.
  const g = c.greet ? greeting(c.name, c.lang).trim() : '';
  const head = !g ? fit : !fit ? g : `${g}\n\n${fit}`;
  let reply = [head.trim(), step, close].filter(Boolean).join('\n\n');
  // D-311.5 (golden first-two-months-tl: four "po" once the flow's ask followed the answer): three at most in a Taglish message.
  // Audit of 3bd0e1b (D3): the flow's own lines are frozen, so the cap is taken from the head (the answer) and they stay whole.
  const flowPo = c.flowFollowUp ? (`${c.seeHome ?? ''}\n${c.flowFollowUp}`.match(/ po\b/g) ?? []).length : 0;
  reply = thinPo(reply, c.lang === 'bis' ? 0 : c.lang === 'tl' ? Math.max(0, Math.min(2, 3 - flowPo)) : 2);
  if (c.flowFollowUp) reply = [reply, c.seeHome ?? '', c.flowFollowUp].filter(Boolean).join('\n\n');
  reply = capName(reply, c.name, c.greet && !c.flowFollowUp ? 1 : 2);
  // Nothing left (an answer that was all frame, and no step): the model's words without links or leaves, never silence.
  if (!reply.trim()) reply = m.answer.split('\n').filter((l) => !URL_LINE_RE.test(l)).join('\n').replace(/[ \t]*🌿/gu, '').trim();
  // D-300.1: the initial message of a conversation (greetNow, 12 h) is the one signed message - a returning guest's too.
  return { reply: signFirst(reply, c.greetNow), stripped: clean.stripped, fitted: fit !== answer };
}
