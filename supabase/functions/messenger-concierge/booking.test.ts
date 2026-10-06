import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { answer, availabilityLine, dmRange, kidsIn, openWindows, parseDates, parseName, parsePax, parsePhone, prompt, rateLine, start, stayPayMessage, toneOf, trimWindow, type Flow } from './booking.ts';

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
  assertEquals(parsePax('2 adults and 1 kid'), 3); // SPEC-39 4.4: the child counts
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
  // live 2026-10-04: words after the name are not part of it
  // SPEC-39 3.7: "Ma." is kept as typed (the hot fix's "Can" exclusion still holds)
  assertEquals(parseName('Ma. Elizabeth Reyes.  09165331514. You can reach me at ab@example.com'), 'Ma. Elizabeth Reyes');
  assertEquals(parseName('Juan Dela Cruz and my email is juan@example.com'), 'Juan Dela Cruz');
});

Deno.test('dmRange: one month reads once, two months read twice', () => {
  assertEquals(dmRange('2026-11-17', '2026-11-19'), 'Nov 17 to 19');
  assertEquals(dmRange('2026-11-30', '2026-12-02'), 'Nov 30 to Dec 2');
  assertEquals(dmRange('2026-11-07', '2026-11-09'), 'Nov 7 to 9');
});

Deno.test('rateLine: the direct rate, the one-night rate, and the last-minute sentence', () => {
  const f = (a: string, z: string): Flow => ({ step: 'offer', checkin: a, checkout: z, pax: 2, lang: 'en', started_at: now.toISOString(), updated_at: now.toISOString() });
  assertEquals(rateLine(f('2026-11-17', '2026-11-19'), now), 'Booking directly with us brings your 2 nights to PHP 1,691 per night instead of the standard PHP 1,780 — PHP 3,382 for the stay.');
  assertEquals(rateLine(f('2026-11-17', '2026-11-18'), now), 'One night with us comes to PHP 1,780.'); // D-268 persona.ts
  assertEquals(rateLine(f('2026-11-17', '2026-11-22'), now), 'Booking directly with us brings your 5 nights to PHP 1,602 per night instead of the standard PHP 1,780 — PHP 8,010 for the stay.');
  // Lloyd 2026-09-18: inside 5 days of check-in the site asks for the full amount, so the offer says so first.
  assertEquals(rateLine(f('2026-09-18', '2026-09-20'), now).endsWith("As you're arriving within the next five days, the full amount confirms your stay right away."), true);
  assertEquals(rateLine(f('2026-09-21', '2026-09-23'), now).includes('within the next five days'), true);  // 4 days out
  assertEquals(rateLine(f('2026-09-22', '2026-09-24'), now).includes('within the next five days'), false); // 5 days out
  assertEquals(rateLine(f('2026-11-17', '2026-11-19'), now).includes('within the next five days'), false);
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
  // SPEC-39 3.6b: the last detail sends the request through - the hold opens and the card goes with the QR
  assertEquals([s.action, s.flow.step, s.flow.phone, s.flow.email], ['submit', 'confirm', '09475977727', 'ben@example.com']);
  // phone first: the name is still the first thing missing
  s = answer(atContact(), '09171234567', now);
  assertEquals([s.flow.step, s.flow.phone], ['contact', '09171234567']);
  assertEquals(s.reply!.includes('And the name for the reservation?'), true);
  // all three at once
  s = answer(atContact(), 'Ben Munez 09475977727 ben@example.com', now);
  assertEquals([s.action, s.flow.step, s.flow.name, s.flow.email], ['submit', 'confirm', 'Ben Munez', 'ben@example.com']);
  // a question mid-details still passes through to the model
  assertEquals(answer(atContact(), 'may parking po ba?', now).action, 'passthrough');
});

// SPEC-39 3.6b (D-300.3): the details complete -> submit at once; the card, the hold, the payment and the QR are one turn.
const held = (f: Flow, over: Partial<Flow> = {}): Flow => ({ ...f, step: 'await_receipt', booking_id: 'b1', ref: 'DIR-1', deposit: 1691, total: 3382, hold: true,
  hold_expires_at: '2026-09-18T06:00:00Z', receipt_token: 't', receipt_expires_at: '2026-09-18T06:00:00Z', ...over });
Deno.test('SPEC-39 3.6b: details complete -> submit; the fee 6+ days out, the full amount inside 5 days', () => {
  const far = answer(answer(start('book Nov 17 to 19 for 2', now), 'yes', now).flow, 'Ben Munez 09475977727 ben@example.com', now);
  assertEquals([far.action, far.flow.pay_full], ['submit', false]);
  const near = answer(answer(start('book Sep 18 to 20 for 2', now), 'yes', now).flow, 'Ben Munez 09475977727 ben@example.com', now);
  assertEquals([near.action, near.flow.pay_full], ['submit', true]);
});
Deno.test('SPEC-39 3.6b: one message carries the card, the 24-hour hold, the reference, GCash and the QR', () => {
  const f = held(answer(answer(start('book Nov 17 to 19 for 2', now), 'yes', now).flow, 'Ben Munez 09475977727 ben@example.com', now).flow);
  const m = stayPayMessage(f, 'Ben', now);
  for (const k of ['👤 Ben Munez', '📅 Nov 17 to 19 · 2 nights · 2 guests', '💰 Total ₱3,382 · reference DIR-1', '🔐 ₱1,000 refundable security deposit', '⏳ Held for you for 24 hours, until Sep 18 at 2:00 PM (tomorrow)', '0956 011 5744', 'QR below', '₱1,691 reservation fee', 'full ₱3,382', 'screenshot of the receipt'])
    assertEquals(m.includes(k), true, `${k}: ${m}`);
  assertEquals(/fee" or "full/.test(m), false); // "fee" is no longer a step
  assertEquals(prompt(f, 'Ben', false, now), m); // one renderer
  // inside five days: the full amount only, no hold line, no fee
  const n = stayPayMessage(held({ ...f, checkin: '2026-09-18', checkout: '2026-09-20' }, { deposit: 3382, hold: false, hold_expires_at: null, pay_full: true }), 'Ben', now);
  assertEquals([/check-in is near/.test(n), /reservation fee/.test(n), n.includes('⏳ Yours as soon as the payment arrives')], [true, false, true]);
});
Deno.test('SPEC-39 3.6b: after the QR - "full" swaps it, "fee" needs nothing more, a correction re-shows the card, new dates go to the host', () => {
  const f = held(start('book Nov 17 to 19 for 2', now), { name: 'Ben Munez', phone: '09475977727', email: 'ben@example.com' });
  const full = answer(f, 'full', now, 'Ben');
  assertEquals([full.action, full.flow.pay_full, full.flow.deposit], ['requote_full', true, 3382]);
  assertEquals(full.reply!.includes('QR for the full ₱3,382'), true);
  assertEquals(answer(f, 'Can I pay in full thru Gcash?', now).action, 'requote_full');
  assertEquals(answer(full.flow, 'full', now).action, 'ask'); // already full: acknowledged, no second QR
  const fee = answer(f, 'fee', now, 'Ben');
  assertEquals([fee.action, fee.flow.pay_full], ['ask', undefined]);
  assertEquals(/already carries the ₱1,691 fee/.test(fee.reply!), true);
  assertEquals(answer(f, 'ok', now).action, 'ask');
  const pax = answer(f, 'make it 3 guests', now, 'Ben');
  assertEquals([pax.action, pax.flow.pax], ['correct', 3]);
  assertEquals(pax.reply!.includes("Here's your stay") && !/QR below/.test(pax.reply!), true); // the card alone, no new QR
  assertEquals(answer(f, 'can we move it to Nov 20 to 22?', now).action, 'change');
  assertEquals(answer(f, 'is there parking?', now).action, 'passthrough');
  assertEquals(answer(f, 'is everything included?', now).action, 'passthrough'); // "everything" is not a full payment
});
Deno.test('SPEC-39 3.6b: a failed submit leaves the flow at confirm, and the next reply sends it again', () => {
  const f: Flow = { ...answer(answer(start('book Nov 17 to 19 for 2', now), 'yes', now).flow, 'Ben Munez 09475977727 ben@example.com', now).flow };
  assertEquals([answer(f, 'ok', now).action, answer(f, 'full na lang, 3 guests', now).flow.pax, answer(f, 'full na lang, 3 guests', now).flow.pay_full], ['submit', 3, true]);
  assertEquals(answer(f, 'is there parking?', now).action, 'passthrough');
  assertEquals(prompt(f, 'Ben', true, now).includes("Here's your stay"), true); // the card alone before a hold exists
});
Deno.test('SPEC-39 3.6b toneOf: brisk, warm, gentle', () => {
  const brisk = ['Oct 20-22, 2', 'yes', 'Maria Santos 09171234567 m@example.com'];
  assertEquals(toneOf(brisk, brisk, [], 'en'), 'brisk');
  assertEquals(toneOf(['Hi po', ...brisk], ['Hi po', ...brisk], [], 'en'), 'warm');
  assertEquals(toneOf(['first time ko po mag-book online, safe po ba?', ...brisk], brisk, [], 'en'), 'gentle');
  assertEquals(toneOf(['excited na kami', 'Oct 20-22', 'oo'], ['Oct 20-22', 'oo'], [], 'tl'), 'warm');
  assertEquals(toneOf(brisk, brisk, ['negotiation'], 'en'), 'gentle');
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
  assertEquals([s.action, s.flow.step], ['submit', 'confirm']);
  s = answer(s.flow, 'make it 2 guests', now); assertEquals([s.action, s.flow.pax, s.flow.step], ['submit', 2, 'confirm']); // a failed submit's retry
  s = answer(s.flow, 'cancel na lang', now); assertEquals(s.action, 'cancelled');
});

// Lloyd 2026-09-18, from the Taglish read-back: the name flipped the register to English mid-booking.
Deno.test('flow: a name is data, not language - a Taglish booking stays Taglish through the details', () => {
  const f = start('Available po ba ang Sep 24 to 26? 2 po kami', now);
  assertEquals(f.lang, 'tl');
  let s = answer(f, '2 po', now);
  assertEquals([s.flow.lang, s.flow.step], ['tl', 'offer']);
  assertEquals(prompt(s.flow, 'Ben', false, now).includes('I-hold na po ba namin ang dates na iyon para sa inyo?'), true);
  s = answer(s.flow, 'sige po', now);
  assertEquals([s.flow.lang, s.flow.step], ['tl', 'contact']);
  s = answer(s.flow, 'ben munez', now);
  assertEquals([s.flow.lang, s.flow.name], ['tl', 'Ben Munez']);          // was 'en' before the fix
  assertEquals(s.reply!.includes('At ang mobile number na matatawagan namin?'), true);
  s = answer(s.flow, '09171234567 ben@example.com', now);
  assertEquals([s.flow.lang, s.flow.step], ['tl', 'confirm']);
  assertEquals(stayPayMessage(held(s.flow), 'Ben', now).includes('Ito po ang details ng stay ninyo:'), true);
  // a real English sentence still switches the register back
  assertEquals(answer({ ...f, step: 'contact' }, 'my name is Ben and my number is 09171234567', now).flow.lang, 'en');
});

// Lloyd's yes, 2026-09-18, to the two findings the golden run surfaced.
Deno.test('parsePax: a courtesy particle between the count and the guest word still counts', () => {
  assertEquals(parsePax('2 po kami'), 2);
  assertEquals(parsePax('dalawa po kami'), 2);
  assertEquals(parsePax('3 pa kami'), 3);
  assertEquals(parsePax('2 adults'), 2);                     // unchanged
  const f = start('Available po ba ang Sep 24 to 26? 2 po kami', now);
  assertEquals([f.pax, f.step, f.asked], [2, 'offer', 'availability']); // the rate and the offer come at once
});

Deno.test('trimWindow: the offer is the stay they asked for, not the block up to the next booking', () => {
  const w = { start: '2026-10-09', end: '2026-10-28', nights: 19 };
  assertEquals(trimWindow(w, 2), { start: '2026-10-09', end: '2026-10-11', nights: 2 });
  assertEquals(trimWindow(w, 19), w);                        // exactly long enough: left alone
  assertEquals(trimWindow({ start: '2026-10-09', end: '2026-10-10', nights: 1 }, 2), { start: '2026-10-09', end: '2026-10-10', nights: 1 });
  assertEquals(availabilityLine({ ...start('book Oct 7 to 9 for 2', now), lang: 'en' }, new Set(['2026-10-07']), trimWindow(w, 2)),
    "I'm sorry, Oct 7 to 9 is already reserved. The nearest open dates are Oct 9 to 11, and we'd be delighted to welcome you then. If other dates suit you better, just share your check-in and check-out and we'll gladly check them for you.");
});

Deno.test('a date correction at the contact step is a correction, not the guest name', () => {
  // probe-matrix confirm-correction, 2026-09-18: "actually make it ..." was parsed as the NAME
  // ("Actually Make It To") and the flow kept the OLD dates, so the guest would have paid for the
  // wrong nights. Dates must win over parseName at this step.
  const now = new Date('2026-10-01T00:00:00Z');
  const atContact = answer(start('book Oct 20 to 22 for 2', now), 'yes', now).flow;
  assertEquals(atContact.step, 'contact');
  const s = answer(atContact, 'actually make it Oct 25 to 27', now);
  assertEquals(s.flow.checkin, '2026-10-25');
  assertEquals(s.flow.checkout, '2026-10-27');
  assertEquals(s.flow.name ?? null, null, 'the correction must not become the name');
  // A genuine name at the same step still lands.
  const s2 = answer(answer(start('book Oct 20 to 22 for 2', now), 'yes', now).flow, 'Ben Munez', now);
  assertEquals(s2.flow.name, 'Ben Munez');
});

import { overCapacity } from './booking.ts';
Deno.test('D-222 P0: one capacity rule (facts: up to 3 adults, 3+1 child, 2+2) at flow start and at the guest step', () => {
  const n = new Date('2026-09-24T01:00:00Z');
  const six = start('Is Oct 10 to 12 available for 6 adults?', n);
  assertEquals(six.pax, undefined, 'a party of 6 is not pre-filled into an offer');
  assertEquals(six.step, 'pax');
  const four = start('book Oct 10 to 12 for 4 adults', n);
  assertEquals(four.pax, undefined, '4 adults said outright is over the stated capacity');
  const two = start('book Oct 10 to 12 for 2', n);
  assertEquals([two.pax, two.step], [2, 'offer'], 'a party that fits still goes straight to the offer');
  assertEquals(overCapacity('2 adults and 2 kids', 4), false);
  assertEquals(overCapacity('4 adults', 4), true);
  assertEquals(overCapacity('we are 5', 5), true);
  const step = answer({ ...two, step: 'pax', pax: undefined }, '4 adults po kami', n);
  assertEquals(step.flow.pax, undefined, 'the guest step refuses 4 adults too');
});

import { needsCalendarCheck } from './booking.ts';
Deno.test('D-222 P0: both dates known at flow start means the calendar is read, "available" word or not', () => {
  const n = new Date('2026-09-24T01:00:00Z');
  assertEquals(needsCalendarCheck(start('book Oct 10 to 12 for 2', n)), true);       // was unchecked until submit
  assertEquals(needsCalendarCheck(start('is Oct 10 to 12 available?', n)), true);
  assertEquals(needsCalendarCheck(start('book Oct 10 po', n)), false);               // one date: nothing to check yet
  assertEquals(needsCalendarCheck(start('i want to book', n)), false);
});

import { bookingStart } from './booking.ts';
// Live 2026-09-24 14:13-14:15Z (Suzanne): the flow never started, and the model promised payment details nobody sent.
Deno.test('session 49: a dated "can I book" starts the flow; a yes to our chat offer starts it from the dated message', () => {
  const now = new Date('2026-09-24T14:15:00Z');
  assertEquals(bookingStart('Can i book Oct. 30', [], '', now), 'Can i book Oct. 30');
  const offer = "Suzanne, October 30 is available, and we'd be glad to welcome you then.\n\nWe can arrange the booking for you right here in the chat, or you may secure your reservation on our site, where direct bookings carry our best rates:";
  assertEquals(bookingStart('Yes please', ['With parking?', 'Can i book Oct. 30'], offer, now), 'Can i book Oct. 30');
  assertEquals(bookingStart('Sige po', ['Oct 30 po available?'], 'We can arrange everything dito sa chat, o puwede ninyong i-check ang home sa aming site:', now), 'Oct 30 po available?');
  assertEquals(bookingStart('Yes please', [], offer, now), 'Yes please', 'no dates yet: the flow starts and asks for them');
  assertEquals(start(bookingStart('Yes please', ['Can i book Oct. 30'], offer, now)!, now).checkin, '2026-10-30');
});

Deno.test('session 49: what must stay out of the flow still stays out', () => {
  const now = new Date('2026-09-24T14:15:00Z');
  assertEquals(bookingStart('how can i book?', [], '', now), null, 'how-to questions go to the model');
  assertEquals(bookingStart('Can I book?', [], '', now), null, 'a hedge with no date goes to the model');
  assertEquals(bookingStart('can i bring my dog?', [], '', now), null);
  assertEquals(bookingStart('Yes please', ['Oct 30?'], 'Yes, free parking is available right in front of the unit.', now), null, 'a yes to anything else is not a booking');
});

// ---- SPEC-39 (session 72): intent grasp (4.2 until / month-end, 4.4 children), the warm yes (3.6), the name (3.7) ----
import { opener, greetBlock } from './booking.ts';
import { first, SIGNATURE } from './persona.ts';
Deno.test('SPEC-39 4.2: "end of this month until November 30th" is Oct 31 to Nov 30, not a Nov 30 check-in', () => {
  const at = new Date('2026-10-04T03:00:00Z');
  assertEquals(parseDates('Is it available by end of this month until November 30th?', at), ['2026-10-31', '2026-11-30']);
  assertEquals(parseDates('katapusan ng buwan po', at), ['2026-10-31']);
  assertEquals(parseDates('from the end of November', at), ['2026-11-30']);
  const f = start('Is it available by end of this month until November 30th?', at);
  assertEquals([f.checkin, f.checkout, f.step, f.asked], ['2026-10-31', '2026-11-30', 'pax', 'availability']);
  assertEquals(availabilityLine(f, new Set(), null, at), 'Oct 31 to Nov 30 is available');
});
Deno.test('SPEC-39 4.2: a lone "until Nov 30" is the check-out; the check-in is asked and completes the pair', () => {
  const at = new Date('2026-10-04T03:00:00Z');
  const f = start('available until Nov 30?', at);
  assertEquals([f.checkin, f.checkout, f.step, f.asked], [undefined, '2026-11-30', 'dates', null]);
  assertEquals(prompt(f, 'Ben', false, at), 'Noted, until Nov 30. From which date would you like to check in?');
  const s = answer(f, 'Oct 31', at);
  assertEquals([s.flow.checkin, s.flow.checkout, s.flow.step], ['2026-10-31', '2026-11-30', 'pax']);
  assertEquals(availabilityLine(s.flow, new Set(), null, at).startsWith('Oct 31 to Nov 30'), true);
  // a check-in after the noted check-out starts over from the check-in
  assertEquals(answer(f, 'Dec 3', at).flow.step, 'checkout');
  // the first reply is a greeting and the check-in ask, no calendar claim, lint-clean
  const first = opener(f, 'Ben', '', false, true) + prompt(f, 'Ben', false, at);
  assertEquals(/available|reserved/.test(first), false);
});
Deno.test('SPEC-39 4.4: children count - "2 adults with 1 kid" is three, the card and the welcome say so', () => {
  assertEquals([parsePax('We are 2 adults with 1 kid only.'), kidsIn('We are 2 adults with 1 kid only.')], [3, 1]);
  assertEquals([parsePax('2 adults 2 children'), overCapacity('2 adults 2 children', 4)], [4, false]);
  assertEquals([parsePax('3 adults and 2 kids'), overCapacity('3 adults and 2 kids', 5)], [5, true]);
  assertEquals([parsePax('2 po kami'), kidsIn('2 po kami')], [2, 0]);
  const at = new Date('2026-10-04T03:00:00Z');
  const f: Flow = { ...start('Hi, is Nov 17 to 19 available?', at) };
  const s = answer(f, 'We are 2 adults with 1 kid only.', at);
  assertEquals([s.flow.step, s.flow.pax, s.flow.children], ['offer', 3, 1]);
  assertEquals(s.reply!.startsWith('Your family of three, then,'), true);
  assertEquals(s.reply!.includes('PHP 1,691'), true);
  const card = stayPayMessage({ ...s.flow, step: 'await_receipt', name: 'Ana Cruz', phone: '09171234567', email: 'a@example.com', ref: 'DIR-1', deposit: 1691, total: 3382, hold: true, hold_expires_at: '2026-10-05T06:00:00Z' }, 'Ana', at);
  assertEquals(card.includes('3 guests (2 adults, 1 child)'), true);
});
Deno.test('SPEC-39 3.6: the yes with a good night or a thank-you is returned before the details ask', () => {
  const f = start('Can I book Nov 17 to 19 for 2 adults?', now);
  assertEquals(answer(f, 'Yes and thank you for the discounts. Good night.', now, 'Maria').reply!.startsWith('Good night to you too, Maria, and thank you. To prepare your reservation'), true);
  assertEquals(answer(f, 'yes, thank you', now, 'Maria').reply!.startsWith("It's our pleasure, Maria. To prepare"), true);
  assertEquals(answer(f, 'yes', now, 'Maria').reply!.startsWith('Thank you, Maria. To prepare'), true);
});
Deno.test('SPEC-39 3.7: "Ma." is not the first name; the card keeps the name as typed', () => {
  assertEquals([first('Ma. Elizabeth Reyes'), first('Ben Munez'), first('Ma'), first(null)], ['Elizabeth', 'Ben', 'Ma', '']);
  const f: Flow = { ...start('book Nov 17 to 19 for 2', now), step: 'await_receipt', name: 'Ma. Elizabeth Reyes', phone: '09171234567', email: 'e@example.com', ref: 'DIR-1', deposit: 1691, total: 3382, hold: true, hold_expires_at: '2026-09-18T06:00:00Z' };
  const m = stayPayMessage(f, 'Maria', now);
  assertEquals(m.includes('👤 Ma. Elizabeth Reyes'), true);
  assertEquals(/\bMa,/.test(m), false);
  assertEquals(answer(f, 'full', now).reply!.startsWith('Of course, Elizabeth.'), true);
});
Deno.test('SPEC-39 3.6b: "I will pay tomorrow" after the QR is not a date change', () => {
  const f: Flow = { ...start('book Nov 17 to 19 for 2', now), step: 'await_receipt', ref: 'DIR-1', deposit: 1691, total: 3382, hold: true };
  assertEquals(answer(f, 'I will pay tomorrow po', now).action, 'passthrough');
  assertEquals(answer(f, 'bukas na lang po ako magbabayad', now).action, 'passthrough');
});
Deno.test('SPEC-39 3.1/3.2 (D-299.10, D-300.1): no Cassy sentence anywhere in the flow; only the initial message is signed', () => {
  const f = { ...start('Hi, is Nov 17 to 19 available? 2 adults', now), lang: 'en' as const };
  assertEquals(opener(f, 'Ben', availabilityLine(f, new Set()), false, true).includes('Cassy'), false);
  assertEquals(opener(f, 'Ben', availabilityLine(f, new Set()), false, false).includes('Cassy'), false); // a flow started inside 12 h
  assertEquals(greetBlock('Ben', 'en', false).includes('Cassy'), false);
  for (const step of ['dates', 'checkout', 'pax', 'offer', 'contact', 'confirm'] as const) {
    const p = prompt({ ...f, step, phone: '09171234567', email: 'b@example.com' }, 'Ben', false, now);
    assertEquals(p.includes('Cassy') || p.includes(SIGNATURE), false, step);
  }
});
