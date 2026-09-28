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
import type { Lang } from './booking.ts';

const by = (lang: Lang | undefined, t: { en: string; tl: string; bis: string }) => t[lang ?? 'en'];

/** REQUIRED: the capacity, said before any booking commitment (D-222). */
export const CAPACITY: Record<Lang, string> = {
  en: 'The home is most comfortable for up to 3 adults, or 2 adults with 2 children.',
  tl: 'Most comfortable ang home for up to 3 adults, or 2 adults with 2 kids.',
  bis: 'Most comfortable ang home for up to 3 adults, or 2 adults with 2 kids.',
};
/** REQUIRED: inside five days the full amount confirms the stay (D-166 / D-184); English in every register (D-258). */
export const LAST_MINUTE = `As you're arriving within the next five days, the full amount confirms your stay right away.`;

/** One night's price, as a host says it (was "For 1 night the direct rate is PHP 1,780."). */
export const oneNight = (price: string, lang?: Lang) => by(lang, {
  en: `One night with us comes to ${price}.`,
  tl: `${price} po ang isang gabi sa amin.`,
  bis: `${price} ang usa ka gabii sa amo.`,
});

/** After the price of the window we offered: one easy yes, and room to say no. */
export const holdOffer = (one: boolean, lang?: Lang) => by(lang, {
  en: `Shall we hold ${one ? 'that night' : 'those dates'} for you? We'd be so glad to have you with us.`,
  tl: `I-hold na po ba namin ang ${one ? 'night' : 'dates'} na iyon para sa inyo? We'd be so glad to have you.`,
  bis: `I-hold na ba namo ang ${one ? 'night' : 'dates'} nga to para ninyo? Looking forward mi to have you.`,
});

/** The guest just said yes to the window: acknowledge the choice, never restate it as news ("Oct 2 is available"). */
export const choiceAck = (dates: string, lang?: Lang) => by(lang, {
  en: `${dates} it is, and we're glad to have you.`,
  tl: `Sige po, ${dates}. We're glad to have you.`,
  bis: `Sige, ${dates}. Looking forward mi to have you.`,
});

/** The guest count, asked as a host would, with the REQUIRED capacity after it. */
export const partyAsk = (lang?: Lang) => by(lang, {
  en: `How many of you will be staying? ${CAPACITY.en}`,
  tl: `Ilan po kayong magse-stay? ${CAPACITY.tl}`,
  bis: `Pila mo ka tawo ang mo-stay? ${CAPACITY.bis}`,
});

/** After the guest count, when the guest already heard the price: welcome the party instead of quoting it twice. */
export const partyWelcome = (party: string, lang?: Lang) => by(lang, {
  en: party === 'you' ? `Noted, and we're already looking forward to welcoming you.` : `${party.charAt(0).toUpperCase() + party.slice(1)}, then, and we're already looking forward to it.`,
  tl: party === 'you' ? `Noted po, and we're looking forward to welcoming you.` : `Noted po, ${party}. We're looking forward to it.`,
  bis: party === 'you' ? `Noted, and looking forward mi to welcome you.` : `Noted, ${party}. Looking forward mi.`,
});

/** The details, asked once for all three so one reply can finish them (protocol: fewer steps beat more). */
export const detailsAsk = (name: string, lang?: Lang) => by(lang, {
  en: `${name ? `Thank you, ${name}. ` : ''}To prepare your reservation, may we have your full name, a mobile number we can reach you on, and an email for the confirmation? All three in one message is easiest.`,
  tl: `${name ? `Salamat, ${name}. ` : 'Salamat po. '}Para ma-prepare ang reservation ninyo, maaari po ba naming makuha ang full name, mobile number, at email para sa confirmation? Okay lang na sabay-sabay sa isang message.`,
  bis: `${name ? `Salamat, ${name}. ` : 'Salamat. '}Para ma-prepare ang inyong reservation, pwede namo makuha ang full name, mobile number, ug email for the confirmation? Okay ra nga usa ra ka message.`,
});
