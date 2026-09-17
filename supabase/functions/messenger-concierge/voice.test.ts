// deno test --allow-env messenger-concierge/voice.test.ts  (from supabase/functions)
// The communication protocol's build gate: every canned line the book flow can send passes lintReply().
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { lintReply } from './voice.ts';
import { answer, availabilityAck, availabilityLine, detectLang, opener, paymentReply, prompt, start, type Flow } from './booking.ts';
import { GCASH_QRPH_BASE, crc16, qrphWithAmount } from '../_shared/cascade-core/qrph.ts';

const now = new Date('2026-09-17T01:00:00Z');
const base: Flow = { step: 'dates', started_at: now.toISOString(), updated_at: now.toISOString(), checkin: '2026-10-03', checkout: '2026-10-04', pax: 2, phone: '09171234567', email: null };

Deno.test('every canned prompt passes the voice lint', () => {
  for (const step of ['dates', 'checkout', 'pax', 'contact', 'confirm'] as const) {
    assertEquals(lintReply(prompt({ ...base, step }, 'Ben')), [], step);
  }
  assertEquals(lintReply(opener(start('book Oct 3 to 4 for 2', now), 'Ben') + prompt({ ...base, step: 'contact' }, 'Ben'), 'book Oct 3 to 4 for 2', { firstTurn: true }), []);
  assertEquals(lintReply(paymentReply({ ...base, step: 'await_receipt', ref: 'DIR-1', deposit: 890, total: 1780, hold: true, hold_expires_at: '2026-09-18T00:00:00Z' }, 'Ben', 'https://x')), []);
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
  assertEquals(warm.startsWith("Hi Ben. Thank you for reaching out to Cascade Hideaway. Oct 3 to Oct 4 is available, and we would be glad to welcome the two of you."), true);
  assertEquals(lintReply('Your mobile number po?', '', { firstTurn: true }), ['form_speak', 'cold_opener']);
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
  assertEquals(first.startsWith('Hi Ben. Maraming salamat po sa pag-message sa Cascade Hideaway. Available po ang Oct 20 to Oct 22, at masaya po kaming i-welcome kayong dalawa.'), true);
  assertEquals(lintReply(first, guest, { firstTurn: true }), []);
  let s = answer(f, '09171234567', now); assertEquals(s.flow.lang, 'tl'); // a bare number keeps the register
  assertEquals(answer(f, '09171234567 ben@example.com', now).flow.lang, 'tl'); // an e-mail is not English (live render 11:35)
  assertEquals(answer(f, 'thanks', now).flow.lang, 'tl'); // one English word does not flip the register
  assertEquals(lintReply(prompt(s.flow, 'Ben')), []);
  s = answer(s.flow, 'Can I change it to 3 guests?', now); assertEquals(s.flow.lang, 'en'); // plain English switches back
  const tlPay = paymentReply({ ...base, lang: 'tl', step: 'await_receipt', ref: 'DIR-1', deposit: 1691, total: 3382, hold: true, hold_expires_at: '2026-09-18T02:00:00Z' }, 'Ben', 'https://x');
  assertEquals(tlPay.startsWith('Salamat po, Ben. Naka-reserve na po para sa inyo ang Oct 3 to Oct 4'), true);
  assertEquals(lintReply(tlPay), []);
  for (const step of ['dates', 'checkout', 'pax', 'contact', 'confirm'] as const) assertEquals(lintReply(prompt({ ...base, lang: 'tl', step }, 'Ben')), [], step);
  assertEquals(lintReply(availabilityLine({ ...base, lang: 'tl' }, new Set(['2026-10-03'])), 'available pa po ba'), []);
  const mid = availabilityAck({ ...base, lang: 'tl' }, availabilityLine({ ...base, lang: 'tl' }, new Set())) + '\n\n' + prompt({ ...base, lang: 'tl', step: 'contact' }, 'Ben');
  assertEquals(mid.startsWith('Available po ang Oct 3 to Oct 4, at masaya po kaming i-welcome kayong dalawa.'), true);
  assertEquals(lintReply(mid, 'Oct 3 to 4 po, available pa po ba?'), []);
});
