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

Deno.test('flow: prefilled start, then pax -> phone -> email -> confirm -> submit', () => {
  const f = start('Can I book Sep 24 to 26 for 2 adults?', now);
  assertEquals([f.step, f.checkin, f.checkout, f.pax], ['phone', '2026-09-24', '2026-09-26', 2]);
  let s = answer(f, '0917 123 4567', now); assertEquals([s.action, s.flow.step], ['ask', 'email']);
  s = answer(s.flow, 'skip', now); assertEquals([s.action, s.flow.step, s.flow.email], ['ask', 'pay', null]);
  s = answer(s.flow, 'full na lang', now); assertEquals([s.flow.step, s.flow.pay_full], ['confirm', true]);
  s = answer(s.flow, 'deposit muna', now); assertEquals([s.flow.step, s.flow.pay_full], ['confirm', false]);
  s = answer(s.flow, 'yes po', now); assertEquals(s.action, 'submit');
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
  s = answer(s.flow, '3', now); assertEquals(s.flow.step, 'phone');
  s = answer(s.flow, '09171234567', now); s = answer(s.flow, 'me@example.com', now);
  assertEquals(s.flow.step, 'pay'); s = answer(s.flow, 'the 50%', now);
  assertEquals(s.flow.step, 'confirm');
  s = answer(s.flow, 'make it 2 guests', now); assertEquals([s.action, s.flow.pax, s.flow.step], ['ask', 2, 'confirm']);
  s = answer(s.flow, 'cancel na lang', now); assertEquals(s.action, 'cancelled');
});
