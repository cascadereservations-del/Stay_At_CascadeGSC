// deno test --no-check -A _shared/ops-money.test.ts
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { hasMoney, maskMoney } from './ops-money.ts';

const LEAK = /₱|\bPHP\b|\bP\d|pesos?\b|0956|9560115744|\b09\d{9}\b/i;

Deno.test('amounts and the payment number are hidden in every form a guest or a draft writes them', () => {
  for (const t of [
    'Hi, I sent PHP 1,780 to 0956 011 5744 already', 'the ₱3,560 balance', 'P1000 deposit', 'php 2000.50 total', '2,000 pesos', '3560 PHP',
    'GCash to +63 956 011 5744', 'send to gcash 09560115744', 'Maya number 0917 123 4567 please', 'account no. 1234-5678-90',
  ]) { const m = maskMoney(t); assert(hasMoney(t), t); assert(!LEAK.test(m), `${t} -> ${m}`); assert(!/\d{4}[\s-]?\d{3,}/.test(m), `${t} -> ${m}`); }
});

Deno.test('text with no money passes through untouched, dates and counts included', () => {
  for (const t of ['Tue, Oct 20 → Thu, Oct 22 · 2 guests', 'Check-in from 2:00 PM, check-out 12:00 noon', 'Work order #1a2b3c4d raised', 'https://www.facebook.com/messages/t/1234567890123456']) {
    assertEquals(maskMoney(t), t); assert(!hasMoney(t));
  }
});

Deno.test('D-306: every other way a guest or a draft writes an amount is hidden', () => {
  const table: [string, RegExp][] = [
    ['P 1,780 per night', /1,?780/], ['Php. 1,780 total', /1,?780/], ['Php.1780', /1780/], ['about 1.8k a night', /1\.8k/i], ['2k pesos deposit', /2k/i],
    ['USD 50 deposit', /50/], ['$50 only', /50/], ['US$50', /50/], ['1 780 pesos', /780/], ['rate is 1780', /1780/], ['the total: 3,560', /3,?560/],
    ['balance 1,780 due', /1,?780/], ['1780 a night', /1780/], ['1,780 per night', /1,?780/], ['I paid 2500 already', /2500/], ['sent 1000 to the number', /1000/],
    ['your budget is around 5000', /5000/], ['refund of 1,780 coming', /1,?780/], ['dp 890', /890/], ['downpayment is 890', /890/], ['1780/night', /1780/],
    ['reservation fee 1,780', /1,?780/], ['Revenue ₱50,000 and the rate is 1,780 a night', /50,000|1,780/], ['PHP3560', /3560/], ['3,560 pesos total', /3,?560/],
  ];
  for (const [t, leak] of table) { const m = maskMoney(t); assert(hasMoney(t), t); assert(!leak.test(m), `${t} -> ${m}`); }
});

Deno.test('D-306 keep-list: dates, times, counts, room numbers and phone numbers are not money', () => {
  for (const t of [
    'Check-in 2026-10-05, check-out 2026-10-07', 'Arrives Oct 15, 2026 for 2 nights', 'Stays October 2026, 5 nights', 'Check-in 14:00, check-out 12:00', '2 pax, 1 pull-out bed',
    'Room 12 is ready', 'Call 0917 123 4567 about the paid parking', 'Number +63 917 123 4567 sent for the night shift', 'Call 09171234567 tonight', 'Oct 15 to Oct 17 (2 nights)',
    'Booked on 2026-10-05 for 2 nights', 'Ref 1a2b3c4d night shift', 'https://www.facebook.com/messages/t/1234567890123456 fee',
  ]) assertEquals(maskMoney(t), t, t);
});
