import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { answer, dmRange, openWindows, parseDates, parseName, parsePax, parsePhone, prompt, rateLine, start, type Flow } from './booking.ts';

const now = new Date('2026-09-17T00:00:00Z');

Deno.test('parseDates: month-name ranges, day-first, slash, iso, year rollover', () => {
  assertEquals(parseDates('Sep 24 to 26', now), ['2026-09-24', '2026-09-26']);
  assertEquals(parseDates('sept 24-26 po', now), ['2026-09-24', '2026-09-26']);
  assertEquals(parseDates('Dec 30 to Jan 2', now), ['2026-12-30', '2027-01-02']);
  assertEquals(parseDates('24-26 September', now), ['2026-09-24', '2026-09-26']);
  assertEquals(parseDates('9/24-9/26', now), ['2026-09-24', '2026-09-26']);
  assertEquals(parseDates('2026-10-01 to 2026-10-03', now), ['2026-10-01', '2026-10-03']);
  assertEquals(parseDates('Jan 5', now), ['2027-01-05']);
  assertEquals(parseDates('no dates here', now), []);
});

Deno.test('parsePax / parsePhone', () => {
  assertEquals(parsePax('2 adults and 1 kid'), 2);
  assertEquals(parsePax('tatlo kami'), 3);
  assertEquals(parsePhone('0917 123 4567'), '09171234567');
  assertEquals(parsePhone('+63 917 123 4567'), '09171234567');
  assertEquals(parsePhone('call me'), null);
});

// ---- SPEC-14 (D-184) ------------------------------------------------------------------------
Deno.test('parseName: the message minus phone and e-mail; courtesy words are not names', () => {
  assertEquals(parseName('ben munez'), 'Ben Munez');
  assertEquals(parseName('BEN MUNEZ 09475977727 ben@example.com'), 'Ben Munez');
  assertEquals(parseName('my name is Maria Cristina Reyes'), 'Maria Cristina Reyes');
  assertEquals(parseName('09475977727'), null);
  assertEquals(parseName('ben@example.com'), null);
  assertEquals(parseName('yes po'), null);
  assertEquals(parseName('skip'), null);
});

Deno.test('dmRange: one month reads once, two months read twice', () => {
  assertEquals(dmRange('2026-11-17', '2026-11-19'), 'Nov 17 to 19');
  assertEquals(dmRange('2026-11-30', '2026-12-02'), 'Nov 30 to Dec 2');
  assertEquals(dmRange('2026-11-07', '2026-11-09'), 'Nov 7 to 9');
});

Deno.test('rateLine: the direct rate, the one-night rate, and the 48-hour sentence', () => {
  const f = (a: string, z: string): Flow => ({ step: 'offer', checkin: a, checkout: z, pax: 2, lang: 'en', started_at: now.toISOString(), updated_at: now.toISOString() });
  assertEquals(rateLine(f('2026-11-17', '2026-11-19'), now), 'Booking directly with us brings your 2 nights to PHP 1,691 per night instead of the standard PHP 1,780 — PHP 3,382 for the stay.');
  assertEquals(rateLine(f('2026-11-17', '2026-11-18'), now), 'For 1 night the direct rate is PHP 1,780.');
  assertEquals(rateLine(f('2026-11-17', '2026-11-22'), now), 'Booking directly with us brings your 5 nights to PHP 1,602 per night instead of the standard PHP 1,780 — PHP 8,010 for the stay.');
  // Inside 48 hours the site asks for the full amount, so the offer says so before the card does.
  assertEquals(rateLine(f('2026-09-18', '2026-09-20'), now).endsWith('As your check-in is within 48 hours, the full amount secures the stay.'), true);
  assertEquals(rateLine(f('2026-11-17', '2026-11-19'), now).includes('within 48 hours'), false);
});

Deno.test('openWindows: runs of open nights, the last one open-ended', () => {
  const booked = new Set(['2026-10-07', '2026-10-08']);
  const w = openWindows(booked, '2026-10-05', '2026-10-12');
  assertEquals(w.length, 2);
  assertEquals([w[0].start, w[0].end, w[0].nights, w[0].open_ended], ['2026-10-05', '2026-10-07', 2, undefined]);
  assertEquals([w[1].start, w[1].end, w[1].open_ended], ['2026-10-09', '2026-10-12', true]);
});

Deno.test('flow: the offer is answered yes, no, or with a question', () => {
  const f = start('is Oct 10 to 12 available? 2 adults', now);
  assertEquals([f.step, f.asked, f.pax], ['offer', 'availability', 2]);
  assertEquals(answer(f, 'yes', now).flow.step, 'contact');
  assertEquals(answer(f, 'sige po', now).flow.step, 'contact');
  const no = answer(f, 'no', now);
  assertEquals([no.action, no.flow.step], ['cancelled', 'cancelled']);
  assertEquals(no.reply!.includes('just send your dates again'), true);
  const later = answer(f, 'not now', now); // CANCEL_RE catches this one first - the same reply
  assertEquals([later.action, later.reply!.includes('just send your dates again')], ['cancelled', true]);
  assertEquals(answer(f, 'is there parking?', now).action, 'passthrough');
});

Deno.test('flow: the details are taken progressively, in any order', () => {
  const atContact = () => answer(start('book Sep 24 to 26 for 2', now), 'yes', now).flow;
  // name first
  let s = answer(atContact(), 'ben munez', now);
  assertEquals([s.flow.step, s.flow.name], ['contact', 'Ben Munez']);
  assertEquals(s.reply!.includes('And a mobile number we can reach you on?'), true);
  s = answer(s.flow, '09475977727', now);
  assertEquals(s.reply!.includes('And an email address for your confirmation?'), true);
  s = answer(s.flow, 'ben@example.com', now);
  assertEquals([s.flow.step, s.flow.phone, s.flow.email], ['confirm', '09475977727', 'ben@example.com']);
  // phone first: the name is still the first thing missing
  s = answer(atContact(), '09171234567', now);
  assertEquals([s.flow.step, s.flow.phone], ['contact', '09171234567']);
  assertEquals(s.reply!.includes('And the name for the reservation?'), true);
  // all three at once
  s = answer(atContact(), 'Ben Munez 09475977727 ben@example.com', now);
  assertEquals([s.action, s.flow.step, s.flow.name, s.flow.email], ['ask', 'confirm', 'Ben Munez', 'ben@example.com']);
  // a question mid-details still passes through to the model
  assertEquals(answer(atContact(), 'may parking po ba?', now).action, 'passthrough');
});

Deno.test('flow: the card carries the name, the deposit and the fee-or-full choice', () => {
  const f = answer(answer(start('book Nov 17 to 19 for 2', now), 'yes', now).flow, 'Ben Munez 09475977727 ben@example.com', now).flow;
  const card = prompt(f, 'Ben', false, now);
  assertEquals(card.includes('👤 Ben Munez'), true);
  assertEquals(card.includes('📅 Nov 17 to 19 · 2 nights · 2 guests'), true);
  assertEquals(card.includes('🔐 ₱1,000 refundable security deposit at check-in, returned after check-out'), true);
  assertEquals(card.includes('A reservation fee of ₱1,691 holds the dates'), true);
  assertEquals(card.includes('Just tell us "fee" or "full", whichever suits you.'), true);
  // "fee" and "full" both send the request through
  assertEquals(answer(f, 'fee', now).action, 'submit');
  assertEquals(answer(f, 'fee', now).flow.pay_full, false);
  assertEquals(answer(f, 'full', now).flow.pay_full, true);
});

Deno.test('flow: inside 48 hours the fee is never offered, and a "fee" reply is answered, not accepted', () => {
  const f = answer(answer(start('book Sep 18 to 20 for 2', now), 'yes', now).flow, 'Ben Munez 09475977727 ben@example.com', now).flow;
  assertEquals(f.pay_full, true);
  const card = prompt(f, 'Ben', false, now);
  assertEquals(card.includes('secures your stay'), true);
  assertEquals(card.includes('reservation fee'), false);
  const fee = answer(f, 'fee', now);
  assertEquals([fee.action, fee.flow.step], ['ask', 'confirm']);
  assertEquals(fee.reply!.includes('secures your stay'), true);
  assertEquals(answer(f, 'full', now).action, 'submit');
});

Deno.test('flow: prefilled start -> offer -> details -> confirm (the payment choice sends it)', () => {
  const f = start('Can I book Sep 24 to 26 for 2 adults?', now);
  assertEquals([f.step, f.checkin, f.checkout, f.pax], ['offer', '2026-09-24', '2026-09-26', 2]);
  let s = answer(f, 'yes', now); assertEquals([s.action, s.flow.step], ['ask', 'contact']);
  s = answer(s.flow, 'Ben Munez 0917 123 4567 me@example.com', now); assertEquals([s.action, s.flow.step, s.flow.phone, s.flow.email], ['ask', 'confirm', '09171234567', 'me@example.com']);
  s = answer(s.flow, 'full na lang', now); assertEquals([s.action, s.flow.pay_full], ['submit', true]);
  const d = answer({ ...s.flow, step: 'confirm', pay_full: undefined }, 'deposit', now); assertEquals([d.action, d.flow.pay_full], ['submit', false]);
  const y = answer({ ...s.flow, step: 'confirm', pay_full: undefined }, 'yes po', now); assertEquals([y.action, y.flow.pay_full], ['submit', false]);
  // mixed replies at confirm (Lloyd 11:05): corrections ride along with the choice; a date change re-shows the card
  const m1 = answer({ ...s.flow, step: 'confirm', email: null, pay_full: undefined }, 'deposit, my email is ben@example.com', now); assertEquals([m1.action, m1.flow.email, m1.flow.pay_full], ['submit', 'ben@example.com', false]);
  const m2 = answer({ ...s.flow, step: 'confirm', pay_full: undefined }, 'full na lang, 3 guests', now); assertEquals([m2.action, m2.flow.pax, m2.flow.pay_full], ['submit', 3, true]);
  const m3 = answer({ ...s.flow, step: 'confirm', pay_full: undefined }, 'deposit but make it Sep 27 to 29', now); assertEquals([m3.action, m3.flow.step, m3.flow.checkin], ['ask', 'confirm', '2026-09-27']);
  assertEquals(f.asked, null); // "Can I book …?" is booking intent, not a question to answer first
  assertEquals(start('Hello is Oct 3 to 4 available. i would like to book for 2 adults', now).asked, 'availability');
  assertEquals(start('is Oct 10 to 12 available? book for 2', now).pax, 2); // live 2026-09-17: asked for the count again
  assertEquals(start('book Oct 10 to 12 for 3 nights', now).pax, undefined);
});

Deno.test('flow: question passes through, correction at confirm, cancel', () => {
  const f = start('book', now);
  assertEquals(f.step, 'dates');
  let s = answer(f, 'may pool po?', now); assertEquals(s.action, 'passthrough');
  s = answer(f, 'Sep 24', now); assertEquals([s.flow.step, s.flow.checkin], ['checkout', '2026-09-24']);
  s = answer(s.flow, 'Sep 23', now); assertEquals(s.flow.step, 'checkout');
  s = answer(s.flow, 'until Sep 26', now); assertEquals(s.flow.step, 'pax');
  s = answer(s.flow, '5 adults', now); assertEquals(s.flow.step, 'pax');
  s = answer(s.flow, '3', now); assertEquals(s.flow.step, 'offer');
  s = answer(s.flow, 'sige', now); assertEquals(s.flow.step, 'contact');
  s = answer(s.flow, 'Ben Munez 09171234567 ben@example.com', now);
  assertEquals(s.flow.step, 'confirm');
  s = answer(s.flow, 'make it 2 guests', now); assertEquals([s.action, s.flow.pax, s.flow.step], ['ask', 2, 'confirm']);
  s = answer(s.flow, 'cancel na lang', now); assertEquals(s.action, 'cancelled');
});
