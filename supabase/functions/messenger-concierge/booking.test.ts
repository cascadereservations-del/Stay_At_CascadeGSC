import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { answer, parseDates, parsePax, parsePhone, start } from './booking.ts';

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

Deno.test('flow: prefilled start, then contact -> confirm (the payment choice sends it)', () => {
  const f = start('Can I book Sep 24 to 26 for 2 adults?', now);
  assertEquals([f.step, f.checkin, f.checkout, f.pax], ['contact', '2026-09-24', '2026-09-26', 2]);
  let s = answer(f, '0917 123 4567 me@example.com', now); assertEquals([s.action, s.flow.step, s.flow.phone, s.flow.email], ['ask', 'confirm', '09171234567', 'me@example.com']);
  s = answer(s.flow, 'full na lang', now); assertEquals([s.action, s.flow.pay_full], ['submit', true]);
  const d = answer({ ...s.flow, step: 'confirm', pay_full: undefined }, 'deposit', now); assertEquals([d.action, d.flow.pay_full], ['submit', false]);
  const y = answer({ ...s.flow, step: 'confirm', pay_full: undefined }, 'yes po', now); assertEquals([y.action, y.flow.pay_full], ['submit', false]);
  // mixed replies at confirm (Lloyd 11:05): corrections ride along with the choice; a date change re-shows the card
  const m1 = answer({ ...s.flow, step: 'confirm', email: null, pay_full: undefined }, 'deposit, my email is ben@example.com', now); assertEquals([m1.action, m1.flow.email, m1.flow.pay_full], ['submit', 'ben@example.com', false]);
  const m2 = answer({ ...s.flow, step: 'confirm', pay_full: undefined }, 'full na lang, 3 guests', now); assertEquals([m2.action, m2.flow.pax, m2.flow.pay_full], ['submit', 3, true]);
  const m3 = answer({ ...s.flow, step: 'confirm', pay_full: undefined }, 'deposit but make it Sep 27 to 29', now); assertEquals([m3.action, m3.flow.step, m3.flow.checkin], ['ask', 'confirm', '2026-09-27']);
  const m4 = answer(start('book Sep 24 to 26 for 2', now), 'ben@example.com 09475977727 deposit', now); assertEquals([m4.action, m4.flow.step, m4.flow.email], ['ask', 'confirm', 'ben@example.com']); // the card (with the total) still asks the choice
  const p = answer(start('book Sep 24 to 26 for 2', now), '09171234567', now); assertEquals([p.flow.step, p.flow.email], ['confirm', null]);
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
  s = answer(s.flow, '3', now); assertEquals(s.flow.step, 'contact');
  s = answer(s.flow, '09171234567', now);
  assertEquals(s.flow.step, 'confirm');
  s = answer(s.flow, 'make it 2 guests', now); assertEquals([s.action, s.flow.pax, s.flow.step], ['ask', 2, 'confirm']);
  s = answer(s.flow, 'cancel na lang', now); assertEquals(s.action, 'cancelled');
});
