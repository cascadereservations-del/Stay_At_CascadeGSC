// deno test --allow-env messenger-concierge/voice.test.ts  (from supabase/functions)
// The communication protocol's build gate: every canned line the book flow can send passes lintReply().
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { answerOnly, lintReply, thinPo, tidyReply } from './voice.ts';
import { answer, availabilityAck, availabilityLine, detectLang, opener, parsePax, paymentReply, prompt, start, type Flow } from './booking.ts';
import { GCASH_QRPH_BASE, crc16, qrphWithAmount } from '../_shared/cascade-core/qrph.ts';

const now = new Date('2026-09-17T01:00:00Z');
const base: Flow = { step: 'dates', started_at: now.toISOString(), updated_at: now.toISOString(), checkin: '2026-10-03', checkout: '2026-10-04', pax: 2, phone: '09171234567', email: null };

Deno.test('every canned prompt passes the voice lint', () => {
  for (const step of ['dates', 'checkout', 'pax', 'contact', 'confirm'] as const) {
    assertEquals(lintReply(prompt({ ...base, step }, 'Ben')), [], step);
  }
  assertEquals(lintReply(opener(start('book Oct 3 to 4 for 2', now), 'Ben') + prompt({ ...base, step: 'contact' }, 'Ben'), 'book Oct 3 to 4 for 2', { firstTurn: true }), []);
  const enPay = paymentReply({ ...base, step: 'await_receipt', ref: 'DIR-1', deposit: 890, total: 1780, hold: true, hold_expires_at: '2026-09-18T00:00:00Z' }, 'Ben', 'https://x', now);
  assertEquals(lintReply(enPay), []);
  assertEquals(enPay.startsWith('Hi Ben, 🌿\nWe\'ve set aside Oct 3–4 for you for 24 hours, until Sep 18 at 8:00 AM (tomorrow). Your booking reference is DIR-1.'), true);
  for (const t of ['cancel', 'Sep 1', 'zzz']) { const s = answer({ ...base, step: 'contact' }, t, now); if (s.reply) assertEquals(lintReply(s.reply), [], t); }
});

Deno.test('the question is answered before the ask (live failure of 2026-09-17)', () => {
  const guest = 'Hello is Oct 3 to 4 available. i would like to book for 2 adults';
  const f = start(guest, now);
  const cold = opener(f, 'Ben') + prompt({ ...f, step: 'phone' }, 'Ben');           // what shipped at 08:53
  assertEquals(lintReply(cold, guest, { firstTurn: true }), ['no_answer']);
  const warm = opener(f, 'Ben', availabilityLine(f, new Set())) + prompt({ ...f, step: 'phone' }, 'Ben');
  assertEquals(lintReply(warm, guest, { firstTurn: true }), []);
  assertEquals(availabilityLine(f, new Set(['2026-10-03'])).startsWith('Oct 3 to Oct 4 is already reserved'), true);
  assertEquals(warm.startsWith("Hi Ben, thank you for reaching out to Cascade Hideaway. Oct 3 to Oct 4 is available, and we'd be glad to welcome the two of you."), true);
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
  assertEquals(first.startsWith("Hi Ben! Salamat sa pag-message sa Cascade Hideaway. Available po ang Oct 20 to Oct 22, and we'd be glad to have the two of you."), true);
  assertEquals(lintReply(first, guest, { firstTurn: true }), []);
  let s = answer(f, '09171234567', now); assertEquals(s.flow.lang, 'tl'); // a bare number keeps the register
  assertEquals(answer(f, '09171234567 ben@example.com', now).flow.lang, 'tl'); // an e-mail is not English (live render 11:35)
  assertEquals(answer(f, 'thanks', now).flow.lang, 'tl'); // one English word does not flip the register
  assertEquals(lintReply(prompt(s.flow, 'Ben')), []);
  s = answer(s.flow, 'Can I change it to 3 guests?', now); assertEquals(s.flow.lang, 'en'); // plain English switches back
  const tlPay = paymentReply({ ...base, lang: 'tl', step: 'await_receipt', ref: 'DIR-1', deposit: 1691, total: 3382, hold: true, hold_expires_at: '2026-09-18T02:00:00Z' }, 'Ben', 'https://x', now);
  assertEquals(tlPay.startsWith('Hi Ben! 🌿\nNa-hold na po namin ang Oct 3–4 for you for 24 hours — until Sep 18 at 10:00 AM (bukas). Ang booking reference ninyo po ay DIR-1.'), true);
  assertEquals(tlPay.includes('through GCash (0956 011 5744) using the QR below. Naka-set na po ang exact amount for convenience. Once done, send lang po the receipt screenshot here'), true);
  assertEquals((tlPay.match(/\bpo\b/g) ?? []).length <= 6, true); // section 4: purposeful markers, never every sentence
  assertEquals(lintReply('Rest assured po, lubos kaming nagagalak.'), ['exclaim', 'boilerplate']);
  assertEquals(lintReply(tlPay), []);
  for (const step of ['dates', 'checkout', 'pax', 'contact', 'confirm'] as const) assertEquals(lintReply(prompt({ ...base, lang: 'tl', step }, 'Ben')), [], step);
  assertEquals(lintReply(availabilityLine({ ...base, lang: 'tl' }, new Set(['2026-10-03'])), 'available pa po ba'), []);
  const mid = availabilityAck({ ...base, lang: 'tl' }, availabilityLine({ ...base, lang: 'tl' }, new Set())) + '\n\n' + prompt({ ...base, lang: 'tl', step: 'contact' }, 'Ben');
  assertEquals(mid.startsWith("Available po ang Oct 3 to Oct 4, and we'd be glad to have the two of you."), true);
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
  assertEquals(first.startsWith('Hi Ben! Salamat sa pag-message sa Cascade Hideaway. Available ang Oct 20 to Oct 22, and looking forward mi to have the two of you.'), true);
  assertEquals(lintReply(first, guest, { firstTurn: true }), []);
  const pay = paymentReply({ ...base, lang: 'bis', step: 'await_receipt', ref: 'DIR-1', deposit: 1691, total: 3382, hold: true, hold_expires_at: '2026-09-18T02:00:00Z' }, 'Ben', 'https://x', now);
  assertEquals(pay.startsWith('Hi Ben! 🌿\nNa-hold na namo ang Oct 3–4 for you for 24 hours — until Sep 18 at 10:00 AM (ugma). Your booking reference is DIR-1.'), true);
  assertEquals(pay.endsWith('Salamat, Ben. Looking forward mi sa inyong stay at Cascade Hideaway. 🌿'), true);
  assertEquals(lintReply(pay), []);
  const lines = [pay, first, availabilityLine({ ...base, lang: 'bis' }, new Set(['2026-10-03'])), ...(['dates', 'checkout', 'pax', 'contact', 'confirm'] as const).map((step) => prompt({ ...base, lang: 'bis', step }, 'Ben'))];
  for (const l of lines) { assertEquals(/\b(po|opo)\b/i.test(l), false, 'no Tagalog po in Bisaya: ' + l.slice(0, 40)); assertEquals(lintReply(l), [], l.slice(0, 40)); }
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
    assertEquals(/(is available|available po|available ang|reserved)/i.test(line), false);
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
