// deno test --allow-env messenger-concierge/voice.test.ts  (from supabase/functions)
// The communication protocol's build gate: every canned line the book flow can send passes lintReply().
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { answerOnly, dropPaxAsk, isCold, lintReply, thinPo, tidyReply } from './voice.ts';
import { VOICE, voiceCompact } from '../_shared/cascade-core/facts.ts';
import { BOOK_RE } from './booking.ts';
import { claimsOpen, earlyFeeFor, fixEarlyFee, setAvailability } from './voice.ts';
import { addChatRoute, beforeClose, decisionInvite, ensureGreeting, withIntro } from './voice.ts';
import { AMENITY_RE, lookNudge, TRUST_RE } from './voice.ts';
import { AIRBNB_URL, SITE_URL } from '../_shared/cascade-core/facts.ts';
import { BOT_REPLY, CASSY_INTRO, greeting } from './booking.ts';

// Session 30, live 19:19 and 19:20 Manila: the model kept its older site-only invite, and "let me think about it" got a
// bare link tacked on after the warm close.
Deno.test('the chat route is guaranteed beside the site, and a decision moment never gets a bare link', () => {
  const url = 'https://tinyurl.com/Stay-at-Cascade';
  const live = `Ben, yes, the unit is well-suited for remote work.\n\nWhenever you're ready, you may secure your preferred dates on our site, where direct bookings carry our best rates:\n\n👉 ${url}\n\nWe look forward to making your work and stay comfortable.`;
  const out = addChatRoute(live, url, 'en');
  assertEquals(out.includes(`👉 ${url}\nOr simply tell us here, and we'll arrange the booking for you in this chat.\n\nWe look forward`), true); // same paragraph as the link
  assertEquals(addChatRoute(out, url, 'en'), out);                                   // once
  assertEquals(addChatRoute('Yes, parking is free.', url, 'en'), 'Yes, parking is free.'); // no site offered, nothing added
  assertEquals(/ po\b/.test(addChatRoute(live, url, 'bis')), false);                  // no Tagalog po in Bisaya
  assertEquals(lintReply(out, 'is the place good for working remotely?'), []);
  const think = "That's perfectly fine, Ben. Take all the time you need.\n\nWe're here to assist you whenever you're ready. 🌿";
  const t = beforeClose(think, decisionInvite('en', url));
  assertEquals(t.endsWith("We're here to assist you whenever you're ready. 🌿"), true);  // the warm close stays last
  assertEquals(t.includes(`or you may secure the dates on our site:\n\n👉 ${url}`), true);
  assertEquals(/in this chat/.test(t), true);
  assertEquals(lintReply(t, 'ok thanks, let me think about it first'), []);
  for (const l of ['en', 'tl', 'bis'] as const) assertEquals(lintReply(decisionInvite(l, url)), [], l);
});

// Lloyd 2026-09-17: an invitation offers BOTH routes - settle the booking here in the chat, or the site.
Deno.test('invitations offer the chat route as well as the site, and its answers start the flow', () => {
  const ex = VOICE.split('MID-CONVERSATION EXAMPLES')[1].split('REFERENCE REPLIES')[0];
  assertEquals((ex.match(/in (the|this) chat/g) ?? []).length >= 3, true);
  assertEquals(voiceCompact().includes('offer BOTH routes'), true);
  for (const t of ['yes please arrange it here', 'ok dito po sa chat', 'let us settle it here', 'can you book it for me']) assertEquals(BOOK_RE.test(t), true, t);
  assertEquals(BOOK_RE.test('is there wifi?'), false);
});

// Session 30 (Lloyd: "what happened to the warmth… it would always revert back to blunt transactional responses").
// Root cause: follow-ups ran on a prompt with no examples, a rule asked for "1-3 short sentences", code stripped warm
// closes, and nothing measured warmth. These tests hold all four in place.
Deno.test('warmth: the live blunt replies are cold, the protocol-voice examples are not', () => {
  const blunt1834 = 'Ben, yes, October 27 to 29 is open for your stay. We also provide fiber Wi-Fi in the unit, which is suitable for remote work, video calls, and streaming.\n\nOr you may check and secure your dates directly on our site:\n\n👉 https://tinyurl.com/Stay-at-Cascade\n\nDirect bookings enjoy our best rates, with savings that grow the longer you stay.';
  assertEquals(isCold(blunt1834), true);
  const examples = VOICE.split('MID-CONVERSATION EXAMPLES')[1].split('REFERENCE REPLIES')[0].split(/\nQ: /).slice(1).map((b) => b.slice(b.indexOf('\nA: ') + 4).trim());
  assertEquals(examples.length, 4);
  for (const a of examples) { assertEquals(isCold(a), false); assertEquals(lintReply(a), []); }
  assertEquals(isCold('Yes, parking is available in front of the unit.'), false); // a short direct answer is fine (protocol 08 section 23)
});
Deno.test('warmth: the follow-up (compact) prompt keeps the reply shape and the examples', () => {
  const compact = voiceCompact(); // exactly what index.ts sends on a follow-up
  assertEquals(compact.includes('THE SHAPE OF EVERY REPLY'), true);
  assertEquals(compact.includes('MID-CONVERSATION EXAMPLES'), true);
  // THE regression of 2026-09-13 to 17: the cut landed in VOICE's first paragraph and follow-ups lost the whole voice.
  for (const must of ['PERSONA - CASSY', 'NATIVE ENGLISH CONCIERGE RULE', 'NATIVE FILIPINO CONCIERGE LANGUAGE RULE', 'NATIVE BISAYA/CEBUANO CONCIERGE RULE', 'HARD LINES', 'OUTPUT: JSON only']) assertEquals(compact.includes(must), true, must);
  assertEquals(compact.length > 15_000, true);
  assertEquals(compact.includes('Q: Good evening'), false); // first-contact replies stay out of follow-ups
  assertEquals(/1-3 short sentences/.test(VOICE), false);
});

// Session 30, live 18:34 Manila: the chat already held "2 guests" and the model asked again despite the hint.
Deno.test('dropPaxAsk: a repeated guest-count question goes, the site line no longer opens with "Or"', () => {
  const url = 'https://tinyurl.com/Stay-at-Cascade';
  const live = `Ben, yes, October 27 to 29 is open for your stay. We also provide fiber Wi-Fi in the unit.\n\nMay we know how many guests will be staying with you, please?\n\nOr you may check and secure your dates directly on our site:\n\n👉 ${url}\n\nDirect bookings enjoy our best rates, with savings that grow the longer you stay.`;
  const out = dropPaxAsk(live);
  assertEquals(/how many guests/.test(out), false);
  assertEquals(out.includes('\n\nYou may check and secure your dates directly on our site:'), true);
  assertEquals(lintReply(out, 'hi, is Oct 27 to 29 open? and is there wifi?'), []);
  assertEquals(dropPaxAsk('How many guests will be staying?'), 'How many guests will be staying?'); // never empties a reply
  assertEquals(dropPaxAsk('Yes, the home fits up to 3 adults.'), 'Yes, the home fits up to 3 adults.');
});
import { answer, availabilityAck, availabilityLine, cancelReply, detectLang, nextAsk, opener, parsePax, paymentPromise, paymentReply, prompt, start, type Flow } from './booking.ts';
import { GCASH_QRPH_BASE, crc16, qrphWithAmount } from '../_shared/cascade-core/qrph.ts';

const now = new Date('2026-09-17T01:00:00Z');
const base: Flow = { step: 'dates', started_at: now.toISOString(), updated_at: now.toISOString(), checkin: '2026-10-03', checkout: '2026-10-04', pax: 2, phone: '09171234567', email: null };

Deno.test('every canned prompt passes the voice lint', () => {
  for (const step of ['dates', 'checkout', 'pax', 'offer', 'contact', 'confirm'] as const) {
    assertEquals(lintReply(prompt({ ...base, step }, 'Ben')), [], step);
  }
  assertEquals(lintReply(opener(start('book Oct 3 to 4 for 2', now), 'Ben') + prompt({ ...base, step: 'contact' }, 'Ben'), 'book Oct 3 to 4 for 2', { firstTurn: true }), []);
  const enPay = paymentReply({ ...base, step: 'await_receipt', ref: 'DIR-1', deposit: 890, total: 1780, hold: true, hold_expires_at: '2026-09-18T00:00:00Z' }, 'Ben', 'https://x', now);
  assertEquals(lintReply(enPay), []);
  assertEquals(enPay.startsWith("Ben, we've set aside Oct 3 to 4 for you for 24 hours, until Sep 18 at 8:00 AM (tomorrow). Your booking reference is DIR-1."), true);
  for (const t of ['cancel', 'Sep 1', 'zzz']) { const s = answer({ ...base, step: 'contact' }, t, now); if (s.reply) assertEquals(lintReply(s.reply), [], t); }
});

Deno.test('the question is answered before the ask (live failure of 2026-09-17)', () => {
  const guest = 'Hello is Oct 3 to 4 available. i would like to book for 2 adults';
  const f = start(guest, now);
  // 'phone' was the contact step's name before SPEC-14 merged the asks into 'contact'. What this test
  // guards is the SHAPE - an ask with no answer in front of it - not the step's old name.
  const cold = opener(f, 'Ben') + prompt({ ...f, step: 'contact' }, 'Ben');         // what shipped at 08:53
  assertEquals(lintReply(cold, guest, { firstTurn: true }), ['no_answer']);
  const warm = opener(f, 'Ben', availabilityLine(f, new Set())) + prompt({ ...f, step: 'contact' }, 'Ben');
  assertEquals(lintReply(warm, guest, { firstTurn: true }), []);
  assertEquals(availabilityLine(f, new Set(['2026-10-03'])).startsWith('Oct 3 to 4 is already reserved'), true);
  assertEquals(warm.startsWith("Hi Ben, thank you for reaching out to Cascade Hideaway. Oct 3 to 4 is available, and we'd be glad to welcome the two of you."), true);
  assertEquals(lintReply('Your mobile number po?', '', { firstTurn: true }), ['form_speak', 'cold_opener']);
  assertEquals(lintReply('Kindly send the receipt at your earliest convenience.'), ['boilerplate']); // English protocol sections 8 and 18
  assertEquals(lintReply('Wonderful, Ben! Send ₱890 now.'), ['command_tone', 'exclaim']); // the persona's two forbidden moves
  assertEquals(lintReply('Opo, Ben, may libreng roadside parking po kami sa tapat mismo ng unit.', 'may parking po ba?'), []); // a Tagalog answer counts (live T6)
});

Deno.test('QR Ph amount payload keeps the CRC valid', () => {
  assertEquals(crc16(GCASH_QRPH_BASE.slice(0, -4)), GCASH_QRPH_BASE.slice(-4));
  const q = qrphWithAmount(GCASH_QRPH_BASE, 890);
  assertEquals(q.includes('5406890.00'), true);
  assertEquals(q.startsWith('000201010212'), true);
  assertEquals(crc16(q.slice(0, -4)), q.slice(-4));
  assertEquals(q, '00020101021227830012com.p2pqrpay0111GXCHPHM2XXX02089996440303152170200000006560417DWQM4TK3JDNWCFOT15204601653036085406890.005802PH5909Cascades 6005CONEL610412346304D23D'); // round-tripped through a QR decoder 2026-09-17
});

Deno.test('Taglish register mirrors the guest and passes the lint (Lloyd 11:15)', () => {
  const guest = 'Hello po, available pa po ba ang Oct 20 to 22? Gusto ko po mag-book para sa 2';
  assertEquals(detectLang(guest), 'tl');
  assertEquals(detectLang('is Oct 20 to 22 available? book for 2'), 'en');
  assertEquals(detectLang('how far from SM po'), 'en'); // one courtesy po stays English
  const f = start(guest, now);
  assertEquals([f.lang, f.pax, f.asked], ['tl', 2, 'availability']);
  const first = opener(f, 'Ben', availabilityLine(f, new Set())) + prompt(f, 'Ben');
  assertEquals(first.startsWith("Hi Ben! Salamat sa pag-message sa Cascade Hideaway. Available po ang Oct 20 to 22, and we'd be glad to have the two of you."), true);
  assertEquals(lintReply(first, guest, { firstTurn: true }), []);
  let s = answer(f, '09171234567', now); assertEquals(s.flow.lang, 'tl'); // a bare number keeps the register
  assertEquals(answer(f, '09171234567 ben@example.com', now).flow.lang, 'tl'); // an e-mail is not English (live render 11:35)
  assertEquals(answer(f, 'thanks', now).flow.lang, 'tl'); // one English word does not flip the register
  assertEquals(lintReply(prompt(s.flow, 'Ben')), []);
  s = answer(s.flow, 'Can I change it to 3 guests?', now); assertEquals(s.flow.lang, 'en'); // plain English switches back
  const tlPay = paymentReply({ ...base, lang: 'tl', step: 'await_receipt', ref: 'DIR-1', deposit: 1691, total: 3382, hold: true, hold_expires_at: '2026-09-18T02:00:00Z' }, 'Ben', 'https://x', now);
  assertEquals(tlPay.startsWith('Ben, na-hold na po namin ang Oct 3 to 4 for you for 24 hours — until Sep 18 at 10:00 AM (bukas). Ang booking reference ninyo po ay DIR-1.'), true);
  // Lloyd 2026-09-18 ("both, keep the old sentence too"): the GCash paragraph keeps its own closing sentence, and the
  // approved review-and-confirm sentence opens the warm close - side by side they broke the 320-character rule in Taglish.
  assertEquals(tlPay.includes('through GCash (0956 011 5744) using the QR below. Naka-set na po ang exact amount for convenience. Once done, send lang po the receipt screenshot here at iko-confirm na namin ang reservation.'), true);
  assertEquals(tlPay.includes('Kapag na-send na po ninyo ang receipt dito, ire-review at iko-confirm namin ang reservation ninyo. Salamat po, Ben.'), true);
  assertEquals((tlPay.match(/\bpo\b/g) ?? []).length <= 6, true); // section 4: purposeful markers, never every sentence
  assertEquals(lintReply('Rest assured po, lubos kaming nagagalak.'), ['exclaim', 'boilerplate']);
  assertEquals(lintReply(tlPay), []);
  for (const step of ['dates', 'checkout', 'pax', 'offer', 'contact', 'confirm'] as const) assertEquals(lintReply(prompt({ ...base, lang: 'tl', step }, 'Ben')), [], step);
  assertEquals(lintReply(availabilityLine({ ...base, lang: 'tl' }, new Set(['2026-10-03'])), 'available pa po ba'), []);
  const mid = availabilityAck({ ...base, lang: 'tl' }, availabilityLine({ ...base, lang: 'tl' }, new Set())) + '\n\n' + prompt({ ...base, lang: 'tl', step: 'contact' }, 'Ben');
  assertEquals(mid.startsWith("Available po ang Oct 3 to 4, and we'd be glad to have the two of you."), true);
  assertEquals(lintReply(mid, 'Oct 3 to 4 po, available pa po ba?'), []);
});

Deno.test('Bisaya register: Bislish, no po, passes the lint (Lloyd 12:15, D-169)', () => {
  const guest = 'Available pa ba ang Oct 20 to 22? Gusto namo mag-book, duha mi';
  assertEquals(detectLang(guest), 'bis');
  assertEquals(detectLang('naa moy parking?'), 'bis');
  // Lloyd 2026-09-17 14:40: English and Taglish first; Bislish only once the guest KEEPS replying in Bisaya.
  const f0 = start('Available pa ba ang Oct 20 to 22? Gusto namo mag-book para sa 2', now);
  assertEquals([f0.lang, f0.bis_turns, f0.pax, f0.asked], ['tl', 1, 2, 'availability']); // first Bisaya turn: Taglish
  assertEquals(answer(f0, '09171234567 ben@example.com', now).flow.lang, 'tl');           // a neutral turn changes nothing
  assertEquals(answer(f0, 'naa moy parking?', now).flow.lang, 'bis');                     // second Bisaya turn: Bislish
  assertEquals(answer(f0, 'may parking po ba?', now).flow.bis_turns, 0);                  // a Tagalog turn resets the count
  const f = { ...f0, lang: 'bis' as const, bis_turns: 2 };
  const first =opener(f, 'Ben', availabilityLine(f, new Set())) + prompt(f, 'Ben');
  assertEquals(first.startsWith('Hi Ben! Salamat sa pag-message sa Cascade Hideaway. Available ang Oct 20 to 22, and looking forward mi to have the two of you.'), true);
  assertEquals(lintReply(first, guest, { firstTurn: true }), []);
  const pay = paymentReply({ ...base, lang: 'bis', step: 'await_receipt', ref: 'DIR-1', deposit: 1691, total: 3382, hold: true, hold_expires_at: '2026-09-18T02:00:00Z' }, 'Ben', 'https://x', now);
  assertEquals(pay.startsWith('Ben, na-hold na namo ang Oct 3 to 4 for you for 24 hours — until Sep 18 at 10:00 AM (ugma). Your booking reference is DIR-1.'), true);
  assertEquals(pay.endsWith('Salamat, Ben. Looking forward mi sa inyong stay at Cascade Hideaway. 🌿'), true);
  assertEquals(lintReply(pay), []);
  const lines = [pay, first, availabilityLine({ ...base, lang: 'bis' }, new Set(['2026-10-03'])), ...(['dates', 'checkout', 'pax', 'offer', 'contact', 'confirm'] as const).map((step) => prompt({ ...base, lang: 'bis', step }, 'Ben'))];
  for (const l of lines) { assertEquals(/\b(po|opo)\b/i.test(l), false, 'no Tagalog po in Bisaya: ' + l.slice(0, 40)); assertEquals(lintReply(l), [], l.slice(0, 40)); }
  for (const l of ['en', 'tl', 'bis'] as const) {
    // SPEC-10 control 6: the promise is its own message under the QR, so it carries the register on
    // its own and must pass the lint on its own.
    const promise = paymentPromise(l);
    assertEquals(lintReply(promise), [], 'promise lint ' + l);
    assertEquals(promise.startsWith('For your peace of mind:'), true, l);
    assertEquals(promise.includes('Cascades, registered'), true, 'both names, never just the QR one: ' + l);
    assertEquals(promise.includes('Marifel Suzanne Boncales'), true, l);
    if (l === 'bis') assertEquals(/\b(po|opo)\b/i.test(promise), false, 'no Tagalog po in Bisaya');
    // It must stay OUT of paymentReply: merged in, the reply breaks the 700-character too_long cap.
    const reply = paymentReply({ ...base, lang: l, step: 'await_receipt', ref: 'DIR-1', deposit: 1691, total: 3382, hold: true, hold_expires_at: '2026-09-18T02:00:00Z' }, 'Ben', 'https://x', now);
    assertEquals(reply.includes('For your peace of mind'), false, 'promise is a separate message: ' + l);
    assertEquals(lintReply(reply + '\n\n' + promise).includes('too_long'), true, 'merging it would break the lint: ' + l);
  }
  assertEquals(answer(f, '09171234567', now).flow.lang, 'bis'); // a bare number keeps the register
  assertEquals(answer(f, 'Can I change it to 3 guests?', now).flow.lang, 'en');
});

Deno.test('mid-flow answer: echoed card, site invite and closer are dropped (live 2026-09-17 12:08, session 29)', () => {
  const live = "Yes, Ben, we offer complimentary roadside parking right in front of the unit. It is CCTV-monitored and can accommodate one vehicle. This is shared with residents, so it is on a first-come, first-served basis. Please let us know if you have any other questions.\n\nHere are your stay details:\n\n📅 Oct 25 to Oct 27 · 2 nights · 3 guests\n\nTo secure your stay, you may reply DEPOSIT to reserve with ₱1,691 now.\n\nAlternatively, you may check and secure your dates directly on our site:\n\n👉 https://tinyurl.com/Stay-at-Cascade\n\nOur direct booking rates are often more favorable, with discounts increasing for longer stays.";
  assertEquals(answerOnly(live), 'Yes, Ben, we offer complimentary roadside parking right in front of the unit. It is CCTV-monitored and can accommodate one vehicle. This is shared with residents, so it is on a first-come, first-served basis.');
  const tl = 'Opo, Ben, may libreng roadside parking po kami sa tapat mismo ng unit. Kung may iba pa po kayong katanungan, huwag po kayong mag-atubiling magtanong.\n\nO maaari rin po kayong mag-check at mag-secure ng dates directly sa site namin:';
  assertEquals(answerOnly(tl), 'Opo, Ben, may libreng roadside parking po kami sa tapat mismo ng unit.');
  assertEquals(answerOnly('Yes, parking is available in front of the unit.'), 'Yes, parking is available in front of the unit.');
  // live 12:29, after the first fix: a reworded closer and six po in one answer
  const po = 'Yes, Ben, may parking po kami. May libreng roadside parking sa harap mismo ng unit, at may CCTV po ito. Kasya po ang isang sasakyan. Shared po ito sa mga residente, kaya first come, first served po. Let us know po if may iba pa kayong tanong.';
  assertEquals(thinPo(answerOnly(po)), 'Yes, Ben, may parking po kami. May libreng roadside parking sa harap mismo ng unit, at may CCTV po ito. Kasya ang isang sasakyan. Shared ito sa mga residente, kaya first come, first served.');
  assertEquals(thinPo('Opo, puwede pong i-settle sa check-in.'), 'Opo, puwede pong i-settle sa check-in.');
  // live 12:58 (Bisaya run): the card came back under a new heading, with Tagalog po in a Bisaya answer
  const bis = "Yes, Ben, naa mi parking. Naa'y libreng roadside parking atubangan mismo sa unit, ug naay CCTV po kini. Let us know if naa pa mo'y ubang pangutana.\n\nKini ang details sa stay ninyo:\n\nOct 25 to Oct 27 · 2 nights · 3 guests\n\n09475977727 · ben@example.com\n\nTotal ₱3,382";
  assertEquals(thinPo(answerOnly(bis), 0), "Yes, Ben, naa mi parking. Naa'y libreng roadside parking atubangan mismo sa unit, ug naay CCTV kini.");
  assertEquals(detectLang('Pwede usbon sa Oct 25 to 27? 3 mi'), 'bis'); // was read as Tagalog -> a po-laden Taglish card
  assertEquals(parsePax('Pwede usbon sa Oct 25 to 27? 3 mi'), 3);
  assertEquals(parsePax('3 ka tawo'), 3);
  // Lloyd 14:30: the cancel line read too casual; the resumed card nudges softly. All registers stay lint-clean.
  for (const lang of ['en', 'tl', 'bis'] as const) {
    const c = answer({ ...base, lang, step: 'confirm', total: 3382, deposit: 1691 }, 'cancel', now);
    assertEquals([c.action, lintReply(c.reply!)], ['cancelled', []]);
    assertEquals(/^sige/i.test(c.reply!), false);
    const card = prompt({ ...base, lang, step: 'confirm', total: 3382, deposit: 1691 }, 'Ben', true);
    assertEquals(card.includes('ready whenever you are'), true);
    assertEquals(answerOnly('Yes, parking is right in front.\n\n' + card), 'Yes, parking is right in front.');
  }
  // live 13:12, second Bisaya run: parsePax read it, the confirm step's guest-word gate did not
  const atConfirm = answer({ ...base, lang: 'bis', step: 'confirm', total: 3382, deposit: 1691 }, 'Pwede usbon sa Oct 25 to 27? 3 mi', now).flow;
  assertEquals([atConfirm.pax, atConfirm.checkin, atConfirm.lang], [3, '2026-10-25', 'bis']);
});

// Session 30: a FAILED calendar read (null) must never read as available, in any register, and stays lint-clean.
Deno.test("calendar unknown: no availability claim, three registers", () => {
  for (const lang of ["en", "tl", "bis"] as const) {
    const f = { ...start("book Oct 20 to 22 for 2, is it available?", now), lang } as Flow;
    const line = availabilityLine(f, null);
    assertEquals(/\b(is available|available po|available ang|reserved)\b/i.test(line), false);
    assertEquals(/confirm shortly/.test(line), true);
    assertEquals(lintReply(opener(f, "Ben", line) + prompt(f, "Ben"), "", { firstTurn: true }), []);
  }
});

// Session 30, live 18:25 Manila: the exact reply Lloyd called worse and awkward.
Deno.test('tidyReply: a dangling site invite gets its link, one invitation, contractions', () => {
  const url = 'https://tinyurl.com/Stay-at-Cascade';
  const bad = [
    'Ben, yes, the unit is available from October 20 to 22. We would be pleased to welcome you.',
    'Alternatively, you may check and secure your dates directly on our site:',
    'Direct bookings offer our best rates, with savings that increase the longer you stay.',
    'No pressure at all; we are here whenever you would like to secure those dates.',
  ].join('\n\n');
  const out = tidyReply(bad, url, true);
  assertEquals(out.includes(`on our site:\n\n👉 ${url}`), true);
  assertEquals(/No pressure/.test(out), false);
  assertEquals(out.includes("We'd be pleased"), true);
  assertEquals(out.split(url).length - 1, 1);
  assertEquals(lintReply(out, 'hello, available Oct 20 to 22?'), []);
  // a colon already followed by its link is left alone; Taglish is not contracted; a non-site colon becomes a full stop
  assertEquals(tidyReply(`Our site has the details:\n\n👉 ${url}`, url, false), `Our site has the details:\n\n👉 ${url}`);
  assertEquals(tidyReply('We are ready po.', url, false), 'We are ready po.');
  assertEquals(tidyReply('A few things to note:\n\nQuiet hours run 10 PM to 6 AM.', url, true), 'A few things to note.\n\nQuiet hours run 10 PM to 6 AM.');
});

// K18 (D-182): the golden run 4 replies, verbatim. Oct 7-9 is an airbnb block (nights of Oct 7 and 8).
Deno.test('a booked range is never called open, and the early check-in fee is computed in code', () => {
  const f: Flow = { step: 'dates', checkin: '2026-10-07', checkout: '2026-10-09', lang: 'en', started_at: '', updated_at: '' };
  const line = availabilityLine(f, new Set(['2026-10-07', '2026-10-08']));
  const taken = `Hello Ben. Thank you for reaching out to Cascade Hideaway. Oct 7 to 9 is available, and we'd be glad to welcome you.\n\nWe'll have everything prepared for your arrival, so you can settle in without a second thought.`;
  assertEquals(claimsOpen(taken), true);
  const fixed = setAvailability(taken, line);
  assertEquals(fixed.startsWith('Hello Ben. Thank you for reaching out to Cascade Hideaway. Oct 7 to 9 is already reserved'), true);
  assertEquals(/is available|are open/.test(fixed), false);
  assertEquals(fixed.endsWith(`We'll have everything prepared for your arrival, so you can settle in without a second thought.`), true);
  const partial = `Hello, Ben. Thank you for reaching out to Cascade Hideaway.\n\nFor Oct 7 to 9, the night of Oct 7 is already reserved. However, Oct 8 and 9 are open, and we'd be glad to welcome you then.`;
  const p = setAvailability(partial, line);
  assertEquals((p.match(/already reserved/g) ?? []).length, 1);
  assertEquals(/are open/.test(p), false);
  assertEquals(setAvailability(taken, availabilityLine(f, null)).includes(`We're checking Oct 7 to 9 on our calendar and will confirm shortly.`), true);
  assertEquals(claimsOpen('Oct 7 to 9 is not available.'), false);
  assertEquals(claimsOpen('You may see live availability on our site.'), false);
  assertEquals(claimsOpen('Yes po, available po ang Oct 20 to 22.'), true);
  // golden run 6: an amenity that is 'available for your dates' is not a date claim, and it is never replaced
  const wifi = `Yes, Ben, fiber Wi-Fi is available for your dates. It's steady enough for video calls.`;
  assertEquals(claimsOpen(wifi), false);
  assertEquals(claimsOpen('Yes, Ben, fast fiber Wi-Fi is available for the nights you stay.'), false);
  assertEquals(setAvailability(`Oct 7 to 9 is open. ${wifi}`, line).includes('fiber Wi-Fi is available for your dates'), true);
  // golden run 5: 'the unit is open from Oct 9' is a claim; 'not available on Oct 7' is not
  assertEquals(claimsOpen('For Oct 7 to 9, the night of Oct 7 is already reserved, and the unit is open from Oct 9 onwards.'), true);
  assertEquals(claimsOpen('The unit is not available on Oct 7.'), false);
  // golden run 8: a reply that already carries the line is left as it is (the last sentence was doubled)
  assertEquals(setAvailability(`Hello, Ben.

${line}

We'd be glad to welcome you.`, line), `Hello, Ben.

${line}

We'd be glad to welcome you.`);

  assertEquals(earlyFeeFor('Can we check in at 10am on the first day?'), 200);
  assertEquals(earlyFeeFor('Can we check in early, around 9am?'), 300); // facts.ts: "9 AM would be PHP 300 total"
  assertEquals(earlyFeeFor('check in 11:30 am po?'), 100);
  assertEquals(earlyFeeFor('Is there parking?'), null);
  const r1 = `Ben, we can arrange for an early check-in at 10 AM on October 27. There's a fee of PHP 100 per hour for arrivals before noon, so that would be PHP 400 for a 10 AM check-in.`;
  assertEquals(fixEarlyFee(r1, 'Can we check in at 10am on the first day?'), r1.replace('PHP 400', 'PHP 200'));
  const r2 = 'Early check-in before noon is PHP 100 per hour, so arriving at 10 AM would be PHP 400 total. The PHP 1,000 deposit is settled at check-in.';
  assertEquals(fixEarlyFee(r2, 'Can we check in at 10am?'), r2.replace('PHP 400', 'PHP 200'));
  assertEquals(fixEarlyFee(r2, 'Is there wifi?'), r2);
});

// ---- SPEC-14 (D-184) ------------------------------------------------------------------------
Deno.test('ensureGreeting: first contact always opens with the approved greeting', () => {
  const thanked = 'Hi Ben, thank you for reaching out to Cascade Hideaway. Nov 17 to 19 is available.';
  assertEquals(ensureGreeting(thanked, 'Ben', 'en'), thanked);                                   // already thanked: untouched
  assertEquals(ensureGreeting('Hi Ben! Yes, Nov 17 to 19 is open.', 'Ben', 'en'), 'Hi Ben, thank you for reaching out to Cascade Hideaway. Yes, Nov 17 to 19 is open.');
  assertEquals(ensureGreeting('Yes, Nov 17 to 19 is open.', 'Ben', 'en'), 'Hi Ben, thank you for reaching out to Cascade Hideaway. Yes, Nov 17 to 19 is open.');
  assertEquals(ensureGreeting("Hi there! I'm Cassy.", 'Ben', 'en'), "Hi Ben, thank you for reaching out to Cascade Hideaway. I'm Cassy."); // golden run 2026-09-24: no stray "there!"
  assertEquals(ensureGreeting("Hello there, I'm Cassy.", null, 'en'), "Hello, thank you for reaching out to Cascade Hideaway. I'm Cassy.");
  assertEquals(ensureGreeting('Hello po! Available po ang Nov 17.', null, 'tl'), 'Hello po! Salamat sa pag-message sa Cascade Hideaway. Available po ang Nov 17.');
  assertEquals(ensureGreeting('Maayong buntag! Available ang Nov 17.', 'Ben', 'bis'), 'Hi Ben! Salamat sa pag-message sa Cascade Hideaway. Available ang Nov 17.');
  assertEquals(ensureGreeting('', 'Ben', 'en'), '');
});

Deno.test('SPEC-14: the offer, the details asks, the card and the reserved line pass the lint in three registers', () => {
  const f: Flow = { ...base, checkin: '2026-11-17', checkout: '2026-11-19', step: 'offer' };
  // Lloyd's approved first reply, verbatim (2026-09-18)
  const en = opener(f, 'Ben', availabilityLine(f, new Set())) + prompt(f, 'Ben', false, now);
  assertEquals(en, "Hi Ben, thank you for reaching out to Cascade Hideaway. Nov 17 to 19 is available, and we'd be glad to welcome the two of you.\n\nBooking directly with us brings your 2 nights to PHP 1,691 per night instead of the standard PHP 1,780 \u2014 PHP 3,382 for the stay.\n\nShall we set the dates aside for you?");
  assertEquals(en.length < 700, true);
  const taken = availabilityLine(f, new Set(['2026-11-17']), { start: '2026-11-20', end: '2026-11-23', nights: 3 });
  assertEquals(taken, "Nov 17 to 19 is already reserved. The nearest open dates are Nov 20 to 23, and we'd be glad to check any others for you \u2014 just share your check-in and check-out.");
  for (const lang of ['en', 'tl', 'bis'] as const) {
    const first = opener({ ...f, lang }, 'Ben', availabilityLine({ ...f, lang }, new Set())) + prompt({ ...f, lang }, 'Ben', false, now);
    const card = prompt({ ...f, lang, step: 'confirm', name: 'Ben Munez', email: 'ben@example.com' }, 'Ben', false, now);
    const reserved = availabilityLine({ ...f, lang }, new Set(['2026-11-17']), { start: '2026-11-20', end: '2026-11-23', nights: 3 });
    const asks = [{}, { name: 'Ben Munez' }, { name: 'Ben Munez', phone: '09171234567' }]
      .map((partial) => nextAsk({ ...f, lang, step: 'contact', phone: undefined, email: undefined, ...partial }));
    assertEquals(lintReply(first, 'is Nov 17 to 19 available? 2 adults', { firstTurn: true }), [], lang);
    assertEquals(lintReply(reserved, 'is Nov 17 to 19 available?'), [], lang);
    for (const l of [card, cancelReply(lang), ...asks]) assertEquals(lintReply(l), [], `${lang}: ${l.slice(0, 40)}`);
    if (lang === 'bis') for (const l of [first, card, reserved, cancelReply(lang), ...asks]) assertEquals(/\b(po|opo)\b/i.test(l), false, 'no Tagalog po in Bisaya: ' + l.slice(0, 40));
  }
  // the card carries the name, the deposit and the choice; the hold message no longer greets a second time
  const card = prompt({ ...f, step: 'confirm', name: 'Ben Munez', email: 'ben@example.com' }, 'Ben', false, now);
  assertEquals(card.includes('\u{1F464} Ben Munez'), true);
  assertEquals(card.includes('\u{1F510} \u20B11,000 refundable security deposit, returned after check-out'), true);
  assertEquals(card.includes('A reservation fee of \u20B11,691 holds the dates. The balance and the \u20B11,000 refundable deposit are due at least a day before check-in; or you may settle the full \u20B13,382 now.'), true);
  const hold = paymentReply({ ...f, step: 'await_receipt', name: 'Ben Munez', ref: 'DIR-1', deposit: 1691, total: 3382, hold: true, hold_expires_at: '2026-09-18T00:00:00Z' }, 'Ben Munez', 'https://x', now);
  assertEquals(hold.startsWith("Ben, we've set aside Nov 17 to 19 for you for 24 hours"), true);
  assertEquals(hold.includes("Once you've sent the receipt here, we'll review and confirm your reservation."), true);
  assertEquals(lintReply(hold), []);
});

// D-173 / SPEC-01: Cassy introduces herself once, in the first message, and never again.
Deno.test('SPEC-01: the opener carries the Cassy sentence exactly once, in every register', () => {
  const guest = 'Hello is Oct 3 to 4 available. i would like to book for 2 adults';
  for (const [l3, lang] of [['en', 'en'], ['tl', 'tl'], ['bis', 'bis']] as const) {
    const f = { ...start(guest, now), lang };
    const first = opener(f, 'Ben', availabilityLine(f, new Set()), true) + prompt({ ...f, step: 'contact' }, 'Ben');
    assertEquals(first.split('Cassy').length - 1, 1, l3);                       // said, and said once
    assertEquals(first.includes(CASSY_INTRO[l3].trimEnd()), true, l3);          // the approved sentence, verbatim (SPEC-28: its trailing space became the paragraph break)
    assertEquals(lintReply(first, guest, { firstTurn: true }), [], l3);         // still passes the protocol
  }
});

Deno.test('SPEC-01: nothing is introduced when the guest has already met her', () => {
  assertEquals(greeting('Ben', 'en').includes('Cassy'), false);                 // default is silence
  assertEquals(greeting('Ben', 'en', false).includes('Cassy'), false);
  assertEquals(greeting('Ben', 'en', true).includes(CASSY_INTRO.en), true);
  const f = start('book Oct 3 to 4 for 2', now);
  assertEquals(opener(f, 'Ben').includes('Cassy'), false);                      // a resumed card never carries it
});

Deno.test('SPEC-01: withIntro guarantees the sentence the model may have dropped', () => {
  const plain = 'Hi Ben, thank you for reaching out to Cascade Hideaway. Oct 3 to 4 is available.';
  const out = withIntro(plain, 'en');
  assertEquals(out.startsWith('Hi Ben, thank you for reaching out to Cascade Hideaway. ' + CASSY_INTRO.en.trimEnd() + '\n\n'), true); // one paragraph -> the answer gets its own (2026-09-24)
  assertEquals(out.endsWith('Oct 3 to 4 is available.'), true);                 // inserted, nothing lost
  assertEquals(withIntro(out, 'en'), out);                                      // never twice
  assertEquals(withIntro('Ben, I am Cassy and yes it is open.', 'en'), 'Ben, I am Cassy and yes it is open.');
  const noStop = 'Oct 3 to 4 is open';                                          // no sentence end to insert after
  assertEquals(withIntro(noStop, 'en'), CASSY_INTRO.en.trimEnd() + '\n\n' + noStop);
});

Deno.test('SPEC-01: the are-you-a-bot answer is clean in all three registers', () => {
  for (const l3 of ['en', 'tl', 'bis'] as const) {
    assertEquals(lintReply('Ben, ' + BOT_REPLY[l3], 'are you a bot?'), [], l3);
    assertEquals(BOT_REPLY[l3].includes('Cassy'), true, l3);
  }
});

// SPEC-13 / D-176: look before you book.
Deno.test('SPEC-13: an amenity question gets both links, a trust question only the reviews', () => {
  const fresh = { site: false, reviews: false };
  const both = lookNudge('may wifi po ba?', 'tl', fresh);
  assertEquals(both.includes(`🏡 Amenities and photos: ${SITE_URL}`), true);
  assertEquals(both.includes(`⭐ Guest reviews: ${AIRBNB_URL}`), true);
  const trust = lookNudge('legit ba ni?', 'bis', fresh);
  assertEquals(trust.includes(SITE_URL), false);                       // reviews only
  assertEquals(trust.includes(`⭐ Guest reviews: ${AIRBNB_URL}`), true);
  assertEquals(lookNudge('how do I pay?', 'en', fresh), '');           // a payment turn earns nothing
  assertEquals(lookNudge('is Oct 3 to 4 available?', 'en', fresh), ''); // a dates question is not an amenity question
});

Deno.test('SPEC-13: each link is offered at most once in a conversation', () => {
  assertEquals(lookNudge('what amenities are included?', 'en', { site: true, reviews: false }).includes(SITE_URL), false);
  assertEquals(lookNudge('what amenities are included?', 'en', { site: true, reviews: false }).includes(AIRBNB_URL), true);
  assertEquals(lookNudge('what amenities are included?', 'en', { site: true, reviews: true }), '');
  assertEquals(lookNudge('is there a review page?', 'en', { site: false, reviews: true }), '');
});

Deno.test('SPEC-13: every one of the six strings passes the protocol lint', () => {
  const answer = 'Yes, the unit has fast fibre Wi-Fi throughout, and the kitchen is fully equipped.';
  for (const l3 of ['en', 'tl', 'bis'] as const) {
    for (const has of [{ site: false, reviews: false }, { site: true, reviews: false }]) {
      const block = lookNudge('what amenities are included?', l3, has);
      assertEquals(lintReply(`${answer}\n\n${block}`, 'what amenities are included?'), [], `${l3} ${has.site}`);
    }
  }
});

Deno.test('SPEC-13: the nudge stays occasional, not chatty', () => {
  // The spec's own gate: it must not fire on more than one probe turn in three.
  const probes = ['is Oct 3 to 4 available?', 'how do I pay?', 'magkano po for 2 nights?', 'may wifi po ba?',
    'can I check in early?', 'where exactly is the unit?', 'legit ba ni?', 'do you accept GCash?',
    'is the balcony safe for a toddler?', 'what time is check-out?', 'can I cancel?', 'salamat po!'];
  const fired = probes.filter((t) => lookNudge(t, 'en', { site: false, reviews: false }) !== '');
  assertEquals(fired.length <= Math.floor(probes.length / 3), true, `fired on ${fired.join(' | ')}`);
  assertEquals(AMENITY_RE.test('may wifi po ba?'), true);
  assertEquals(TRUST_RE.test('legit ba ni?'), true);
  assertEquals(AMENITY_RE.test('is Oct 3 to 4 available?'), false);
});

Deno.test('SPEC-21: the intro lands on a follow-up-shaped reply too, once, after the first sentence', () => {
  const followUp = 'Ben, yes po, Oct 3 to 4 is open. We can hold it for you.';
  const out = withIntro(followUp, 'en');
  assertEquals(out.startsWith('Ben, yes po, Oct 3 to 4 is open. ' + CASSY_INTRO.en.trimEnd() + '\n\n'), true);
  assertEquals(out.endsWith('We can hold it for you.'), true);
  assertEquals(withIntro(out, 'en'), out);
  assertEquals(out.includes('thank you for reaching out'), false);
});

Deno.test('session 46: a check-in alone is acknowledged once, not by both the opener and the checkout ask (live 2026-09-23 19:58)', () => {
  const notes = { en: 'Check-in on Oct 17 is noted', tl: 'Noted po, check-in on Oct 17', bis: 'Noted, check-in on Oct 17' };
  for (const lang of ['en', 'tl', 'bis'] as const) {
    const f: Flow = { ...base, lang, checkin: '2026-10-17', checkout: undefined, pax: undefined, step: 'checkout' };
    for (const reply of [opener(f, 'Ben', '', true) + prompt(f, 'Ben'), opener(f, 'Ben').trim() + '\n\n' + prompt(f, 'Ben')]) {
      assertEquals(reply.split(notes[lang]).length - 1, 1, `${lang}: ${reply}`);
    }
  }
});

import { dropSoloLink } from './voice.ts';
Deno.test('session 46: when the look block carries the site, the solo link goes and its lead-in does not dangle (live 2026-09-23 19:57)', () => {
  const lead = `If you have dates in mind, you may share them here and we'll check the calendar for you, or you may see the home, live availability, and our direct rates on our site:`;
  const reply = `Yes, the unit has both fiber Wi-Fi and air-conditioning.\n\n${lead}\n\n👉 ${SITE_URL}\n\nWe'd be glad to welcome you.`;
  const out = dropSoloLink(reply, SITE_URL);
  assertEquals(out.includes(SITE_URL), false);
  assertEquals(/:\s*$/m.test(out), false, out);
  assertEquals(out.includes(lead.replace(/:$/, '.')), true, out);
  assertEquals(dropSoloLink('No link here.', SITE_URL), 'No link here.');
});

// ---- golden run 2026-09-24: the look block made a second invitation (5 of 9 failures) ----------------------------------
import { appendLook, dropSiteInvite } from './voice.ts';
import { scoreReply } from './golden-score.ts';
Deno.test('golden run 2026-09-24: with the look block, the reply keeps one invitation, the chat route and the close', () => {
  const pre = `Hi Ben, thank you for reaching out to Cascade Hideaway. Yes, we do have Wi-Fi.\n\nThe home has fiber Wi-Fi, steady enough for video calls.\n\nIf you have dates in mind, share them here and we'll check the calendar for you. We can also arrange the booking right here in the chat, or you may see the home and live availability on our site:\n\n👉 ${SITE_URL}\n\nWe'd be glad to welcome you.`;
  const out = appendLook(dropSiteInvite(dropSoloLink(pre, SITE_URL)), lookNudge('Hi, do you have wifi?', 'en', { site: false, reviews: false }));
  assertEquals(out.split(SITE_URL).length - 1, 1, out);                      // the site once, on the labelled line
  assertEquals(out.includes('share them here'), true, out);                    // the chat route stays
  assertEquals(out.endsWith("We'd be glad to welcome you."), true, out);      // the close stays last
  assertEquals(/:\n🏡 Amenities and photos: /.test(out), true, out);          // the lines sit directly under their sentence
  const s = scoreReply({ guest: 'Hi, do you have wifi?', reply: out, prevReply: null, kind: 'model', lang: 'en', firstTurn: true, siteUrl: SITE_URL, name: 'Ben' });
  assertEquals(s.R4, null, out); assertEquals(s.R10, null, out);
});
Deno.test('dropSiteInvite keeps the chat half when it is the only chat route, and never empties a reply', () => {
  assertEquals(dropSiteInvite('Yes, there is parking. We can arrange everything right here in the chat, or you may see the home on our site.'), 'Yes, there is parking. We can arrange everything right here in the chat.');
  assertEquals(dropSiteInvite('See everything on our site.'), 'See everything on our site.');
  assertEquals(dropSiteInvite('Parking is free.'), 'Parking is free.');
});

Deno.test('golden run 2026-09-24: a one-paragraph first reply gets its answer on its own paragraph after the intro', () => {
  const one = 'Hi Ben, thank you for reaching out to Cascade Hideaway. Sep 28 to Oct 2 is already reserved. The nearest open dates are Oct 3 to 7.';
  const out = withIntro(one, 'en');
  assertEquals(out, 'Hi Ben, thank you for reaching out to Cascade Hideaway. ' + CASSY_INTRO.en.trimEnd() + '\n\nSep 28 to Oct 2 is already reserved. The nearest open dates are Oct 3 to 7.');
  const two = 'Hi Ben, thank you for reaching out.\n\nYes, we have Wi-Fi.';
  assertEquals(withIntro(two, 'en'), 'Hi Ben, thank you for reaching out. ' + CASSY_INTRO.en.trimEnd() + '\n\nYes, we have Wi-Fi.'); // the break is kept, not swallowed
});

// Golden run 2026-09-25: Oct 2 is a real check-out day, and the reply offered 12 noon at no extra cost (Lloyd 2026-09-17: never).
import { offersEarlyCheckin, setTurnoverCheckin, turnoverCheckinLine } from './voice.ts';
Deno.test('turnover day: a noon or free early check-in offer is replaced by the 2 PM line', () => {
  const live = 'Salamat sa pag-message sa Cascade Hideaway. yes po, available ang Oct 2. You\'re welcome to check in from 12:00 noon that day at no extra cost.\n\nMay I confirm lang po ilan kayo?';
  assertEquals(offersEarlyCheckin(live), true);
  const line = turnoverCheckinLine('Oct 2', 'tl');
  const fixed = setTurnoverCheckin(live, line);
  assertEquals(fixed.includes('12:00 noon'), false);
  assertEquals(fixed.includes(line), true);
  assertEquals(fixed.includes('available ang Oct 2'), true);
  assertEquals(fixed.endsWith('May I confirm lang po ilan kayo?'), true);
  assertEquals(setTurnoverCheckin(fixed, line), fixed);
  // Left alone: the 2 PM answer, a check-out time, and a paid early check-in quoted with its fee.
  assertEquals(offersEarlyCheckin('Check-in is from 2:00 PM on Oct 2.'), false);
  assertEquals(offersEarlyCheckin('Check-out is at 12 noon, and we will have everything ready.'), false);
  assertEquals(offersEarlyCheckin('Complimentary early check-in from 12 noon works on Oct 9, as no guest checks out that day.'), true);
});

// Golden run 2026-09-25 (R10): intro written by the model and run on into a long answer; one paragraph over 320 characters.
import { breakAfterIntro } from './voice.ts';
Deno.test('a first paragraph over 320 characters breaks after the Cassy sentence', () => {
  const live = "Hi Ben, thank you for reaching out to Cascade Hideaway. I'm Cassy, the home's digital concierge, and Marifel and our team are right here with me. We're located inside Bria Homes along Conel Road, Barangay San Isidro, General Santos City. It's a quiet, gated residential community, about 10 to 15 minutes from SM, KCC, and Veranza, so you can settle in calmly after your day.\n\nFor our guests' privacy, the exact house details are shared once a booking is confirmed.";
  const out = breakAfterIntro(live);
  const paras = out.split('\n\n');
  assertEquals(paras.length, 3);
  assertEquals(paras[0].endsWith('right here with me.'), true);
  assertEquals(paras[1].startsWith("We're located inside Bria Homes"), true);
  assertEquals(paras.every((p) => p.length <= 320), true);
  assertEquals(breakAfterIntro(out), out);
  assertEquals(breakAfterIntro('Short first paragraph. I am Cassy.\n\nRest.'), 'Short first paragraph. I am Cassy.\n\nRest.');
});

// Golden run 2026-09-25, fu-reviews-tl: R3 read a warm reply as cold because the warmth shared a paragraph with the links;
// R2 flagged "happy to help" (boilerplate) where the approved replies say "glad to help".
import { gladNotHappy } from './voice.ts';
Deno.test('warmth beside the look block still counts; "happy to help" becomes "glad to help"', () => {
  const live = "Yes, Ben, legit po kami. We are a verified Airbnb Guest Favorite, so you can be confident in your stay with us.\n\nOur guests often share how much they appreciate the quiet comfort and the thoughtful touches we provide.\n\nIf you have any dates in mind, please feel free to share them here, and we'll gladly check our calendar for you. 🌿 If you'd like to read what past guests have shared, nasa aming Airbnb listing po ang reviews:\n⭐ Guest reviews: https://airbnb.com/h/cascadesgsc";
  assertEquals(isCold(live), false);
  assertEquals(isCold('The unit has fiber Wi-Fi at 200 Mbps and a smart TV with Netflix, and the kitchen has a fridge, an induction cooker, a rice cooker and basic cookware and utensils.\n\n👉 https://tinyurl.com/Stay-at-Cascade'), true);
  assertEquals(gladNotHappy("We'd be happy to help you plan your stay."), "We'd be glad to help you plan your stay.");
  assertEquals(gladNotHappy('We are happy to host you.'), 'We are happy to host you.');
});

// Golden run 2026-09-25: the model's "Hi Ben," was replaced by the approved greeting and the answer began in lower case.
Deno.test('the answer after a replaced salutation starts with a capital', () => {
  const out = ensureGreeting('Hi Ben, yes po, available ang Oct 2.', 'Ben', 'tl');
  assertEquals(out.includes('Cascade Hideaway. Yes po, available ang Oct 2.'), true);
});

// Golden run 2026-09-25 (R4, fu-amenity-en x3): a short reply put the first-contact invitation in the middle, and its kept
// chat half stood alone beside the model's own "share them here" paragraph - two invitations.
Deno.test('the chat half of a dropped site invitation goes when another paragraph already offers the chat', () => {
  const r = "Yes, Ben, the home has fiber Wi-Fi.\n\nWe can arrange everything right here in the chat, or you may see the home and live availability on our site.\n\nIf you have dates in mind, share them here and we'll check the calendar for you right away.";
  const out = dropSiteInvite(r);
  assertEquals(out, "Yes, Ben, the home has fiber Wi-Fi.\n\nIf you have dates in mind, share them here and we'll check the calendar for you right away.");
  // Alone, the chat half is kept (the only chat route in the reply).
  assertEquals(dropSiteInvite("Yes, we have Wi-Fi.\n\nWe can arrange everything right here in the chat, or you may see the home on our site."), "Yes, we have Wi-Fi.\n\nWe can arrange everything right here in the chat.");
});

// Golden run 2026-09-25, first-greeting-tl: "To you too." left after the salutation swap, and R3 counted code's own
// greeting and Cassy sentence as the model's (cold) words.
Deno.test('greeting echo goes with the salutation; code lines do not make a reply cold', () => {
  const out = ensureGreeting('Good evening to you too, Ben. How may we assist you tonight, po?', 'Ben', 'en');
  assertEquals(out.includes('To you too'), false);
  assertEquals(out.endsWith('Cascade Hideaway. How may we assist you tonight, po?'), true);
  const live = "Hi Ben, thank you for reaching out to Cascade Hideaway. I'm Cassy, the home's digital concierge, here with Marifel and our team. How may we assist you tonight, po?\n\nWe can arrange everything right here in the chat, or you may see the home and live availability on our site:\n\n👉 https://tinyurl.com/Stay-at-Cascade";
  assertEquals(isCold(live), false);
});

// Golden run 2026-09-25, fu-ok-salamat-tl: the intro sat between "Hi Ben!" and the thank-you sentence.
Deno.test('the intro follows the thank-you sentence even when a short salutation comes first', () => {
  const out = withIntro('Hi Ben! Salamat sa pag-message sa Cascade Hideaway. Yes po, may libreng parking.', 'tl');
  assertEquals(out.startsWith('Hi Ben! Salamat sa pag-message sa Cascade Hideaway. ' + CASSY_INTRO.tl.trimEnd()), true);
  assertEquals(withIntro('Hi Ben, thank you for reaching out to Cascade Hideaway. Yes, we have Wi-Fi.', 'en').startsWith('Hi Ben, thank you for reaching out to Cascade Hideaway. ' + CASSY_INTRO.en.trimEnd()), true);
});

// Golden run 2026-09-25, reg-bot-bis (R10, 719 characters): a bare "sa site" invitation survived beside the look block.
Deno.test('a bare "sa site" invitation is dropped when the look block carries the site', () => {
  const r = 'Kung may dates na kayo in mind, i-share lang dito at iche-check namin agad. Puwede rin ninyong i-check ang live availability at ang aming direct rates sa site.';
  assertEquals(dropSiteInvite(r), 'Kung may dates na kayo in mind, i-share lang dito at iche-check namin agad.');
});

// Golden run 2026-09-25, first-rate-tl (R10 "5 paragraphs").
import { fitFourParagraphs } from './voice.ts';
Deno.test('five text paragraphs: the greeting joins the next one; a link line never counts', () => {
  const live = 'Hi Ben! Salamat sa pag-message sa Cascade Hideaway. Ako si Cassy, ang digital concierge ng Cascade, kasama si Marifel at ang team.\n\nOur direct rate po starts at PHP 1,780 per night, and the nightly rate goes lower the longer you stay with us.\n\nIf you have dates in mind, share lang dito, pati ilan kayo, and we\'ll check the calendar and the best rate for you right away.\n\nWe can arrange the booking dito sa chat, o puwede rin ninyong i-check ang live availability sa aming site:\n\n👉 https://tinyurl.com/Stay-at-Cascade\n\nSalamat. Looking forward kami sa stay ninyo. 🌿';
  const out = fitFourParagraphs(live);
  const text = out.split('\n\n').filter((p) => !p.startsWith('👉'));
  assertEquals(text.length, 4);
  assertEquals(out.includes('site:\n\n👉 https://tinyurl.com/Stay-at-Cascade'), true);
  assertEquals(text.every((p) => p.length <= 320), true);
  assertEquals(fitFourParagraphs(out), out);
});

// Golden run 2026-09-25, reg-bot-bis: the 🌿 shared a sentence with the site and was dropped with it (R3).
Deno.test('a care emoji in a site sentence still counts as care', () => {
  const live = "Hi Ben! Salamat sa pag-message sa Cascade Hideaway. Ako si Cassy, ang digital concierge ng Cascade, kasama si Marifel at ang team. Yes, Ben, may fiber Wi-Fi po kami, steady enough for video calls and streaming.\n\nKung may dates na po kayo in mind, i-share lang dito para ma-check namin ang availability for you. 🌿 Nasa aming site ang photos at full amenities, at nasa Airbnb listing namin ang reviews ng past guests:\n🏡 Amenities and photos: https://tinyurl.com/Stay-at-Cascade\n⭐ Guest reviews: https://airbnb.com/h/cascadesgsc";
  assertEquals(isCold(live), false);
});

// Golden run 2026-09-25, reg-bot-bis (R7): the name three times.
import { capName } from './voice.ts';
Deno.test('the name at most twice; extra vocatives go from the end', () => {
  const r = 'Hi Ben! Salamat sa pag-message. Yes, Ben, may fiber Wi-Fi po kami.\n\nSalamat, Ben. Looking forward kami sa stay ninyo. 🌿';
  const out = capName(r, 'Ben');
  assertEquals((out.match(/\bBen\b/g) ?? []).length, 2);
  assertEquals(out.includes('Salamat. Looking forward'), true);
  assertEquals(out.startsWith('Hi Ben!'), true);
  assertEquals(capName('Hi Ben, yes. Thanks, Ben.', 'Ben'), 'Hi Ben, yes. Thanks, Ben.');
  assertEquals(capName(r, null), r);
});

// Golden 2026-09-25, first-noon-checkin-on-turnover-day-tl run 2: greeting + answer did not fit in 320.
Deno.test('five paragraphs: the shortest adjacent text pair that fits is joined, never across a link', () => {
  const live = "Hi Ben! Salamat sa pag-message sa Cascade Hideaway. Ako si Cassy, ang digital concierge ng Cascade, kasama si Marifel at ang team.\n\nYes po, available ang Oct 2. Another guest is checking out that day, so check-in stays at 2:00 PM while we prepare the unit to the same standard for you. If the home is ready earlier, we'll message you right away.\n\nFor 1 night, the direct rate is PHP 1,780. May I confirm lang po ilan kayo, so we can prepare the unit?\n\nWe can arrange the booking dito sa chat right away, o puwede ninyong i-secure ang stay sa aming site:\n\n👉 https://tinyurl.com/Stay-at-Cascade\n\nWe'll have everything ready for you. 🌿";
  const out = fitFourParagraphs(live);
  const paras = out.split('\n\n');
  assertEquals(paras.filter((p) => !p.startsWith('👉')).length, 4);
  assertEquals(paras.every((p) => p.length <= 320), true);
  assertEquals(out.includes('site:\n\n👉 https://tinyurl.com/Stay-at-Cascade'), true);
  assertEquals(fitFourParagraphs(out), out);
});

// Live 2026-09-25 14:47Z: malformed draft JSON handed guests to the host (draft_failed x3).
import { parseDraftJson } from './voice.ts';
Deno.test('draft JSON: fences, raw newlines and single-quoted keys still yield the reply', () => {
  assertEquals(parseDraftJson('{"reply":"Hi","uncertain":false}').reply, 'Hi');
  assertEquals(parseDraftJson('```json\n{"reply":"Hi po"}\n```').reply, 'Hi po');
  const rawNl = '{"reply": "Line one.\n\nLine two with a \\"quote\\".", "uncertain": true, "guest_name": "Ben"}';
  const a = parseDraftJson(rawNl);
  assertEquals(a.reply, 'Line one.\n\nLine two with a "quote".');
  assertEquals(a.uncertain, true);
  assertEquals(a.guest_name, 'Ben');
  assertEquals(parseDraftJson("{'reply': \"Yes po, available.\"}").reply, 'Yes po, available.');
  let threw = false; try { parseDraftJson('not json at all'); } catch (e) { threw = e instanceof SyntaxError; }
  assertEquals(threw, true);
});

// Golden 2026-09-25 reg-bot-bis: "para makapag-relax kayo nang husto" is care.
Deno.test('"relax" counts as care', () => {
  assertEquals(isCold('Yes po, may fiber Wi-Fi ang unit, steady enough for video calls and streaming, para makapag-relax kayo nang husto habang nandito kayo sa amin.'), false);
});
