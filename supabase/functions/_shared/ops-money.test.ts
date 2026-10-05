// deno test --no-check -A _shared/ops-money.test.ts
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { hasMoney, maskMoney, maskTitle } from './ops-money.ts';

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

Deno.test('D-306 audit: totals after = or x, decimals, English and Taglish money words, percents, libo', () => {
  const table: [string, string][] = [
    ['2 nights x 1,780 = 3,560', '3,560'], ['2 nights x 1,780 = 3,560', '1,780'], ['P1780 x2 = 3560', '3560'], ['3,560 = 2 x 1780', '1780'],
    ['1,780.00 total', '1,780'], ['total 3,560.00', '3,560'], ['the amount is 4500', '4500'], ['due 1780 tomorrow', '1780'], ['payout 2,900', '2,900'],
    ['revenue 50000 this month', '50000'], ['income of 12000', '12000'], ['adr 1780', '1780'], ['1780 each', '1780'], ['1500 per pax', '1500'], ['300 per head', '300'],
    ['500 per hour', '500'], ['extra 500 for early check-in', '500'], ['additional 1,000', '1,000'], ['1500-2000 per night', '2000'],
    ['refund 50%', '50%'], ['50% refund', '50%'], ['occupancy 73%', '73%'], ['occupancy is 73 percent', '73'], ['20% discount', '20%'],
    ['bayad 2500', '2500'], ['singil 1780 kada gabi', '1780'], ['presyo 1,780', '1,780'], ['halaga 3560', '3560'], ['kabuuan 3560', '3560'], ['3560 lahat', '3560'],
    ['kulang 500', '500'], ['sukli 220', '220'], ['dagdag 300', '300'], ['gcash 1780', '1780'], ['send ko 1780 later', '1780'], ['1,780/nyt', '1,780'],
    ['2 libo', 'libo'], ['2libo po', 'libo'], ['isang libo', 'libo'], ['dalawang libo', 'libo'], ['limang libo', 'libo'], ['apat na libo', 'libo'], ['lima ng libo', 'libo'],
    ['₱1k', 'k'], ['P1k only', 'k'],
  ];
  for (const [t, leak] of table) { const m = maskMoney(t); assert(hasMoney(t), t); assert(!m.includes(leak) || leak === 'k' && !/\dk|\sk\b/.test(m), `${t} -> ${m}`); }
  assertEquals(maskMoney('₱1k'), '[amount hidden]');
});

Deno.test('D-306 audit keep-list: ids, uuids, order numbers and confirmation codes survive next to a money word', () => {
  for (const t of [
    'HMA1234567 paid', '00A49123 paid', 'Booking #12345 paid', 'HMYDBYKYPC paid', 'code 00A49C5E deposit', 'ref 3f2a9c1e-5b7d-4e21-9a0c-1d2e3f4a5b6c paid',
    'Check-in 2026-10-05, 14:00, 2 pax, room 12', 'Weather: showers 25-30C, 60% rain',
  ]) assertEquals(maskMoney(t), t, t);
});

Deno.test('D-306 audit: a title about cleaning pay or an expense stays whole in OPS, booking income does not, the payment number never does', () => {
  assertEquals(maskTitle('Pay Honey ₱500'), 'Pay Honey ₱500');
  assertEquals(maskTitle('Bili ng supplies ₱320'), 'Bili ng supplies ₱320');
  assertEquals(maskTitle('Cleaning pay 2 sessions ₱1,200'), 'Cleaning pay 2 sessions ₱1,200');
  assertEquals(maskTitle('Collect ₱3,000 balance from guest'), 'Collect [amount hidden] balance from guest');
  assertEquals(maskTitle('Pay Honey ₱3,560 balance'), 'Pay Honey [amount hidden] balance');
  assertEquals(maskTitle('Laundry deposit refund PHP 1,780'), 'Laundry deposit refund [amount hidden]');
  assert(!maskTitle('Pay Honey ₱500 to 0956 011 5744').includes('5744'));
});

Deno.test('D-306 round 3 keep-list: counts, measures, times and codes next to a Taglish or English money word are not money', () => {
  for (const t of [
    'Oct 15 gabi 1900', 'Room 203 extra towels', 'Send 120 rolls', 'kulang ng 120 rolls', 'lahat ng 150 hangers', 'each 500 ml', 'towels x 120',
    'Door code 4829 sent', 'bagong code 4829 po, 2 gabi', 'Charge the EcoFlow to 100%', 'Run the EcoFlow at 300 W, charge it to 100%',
    'Send 120 rolls of towels x 120', 'Restock 250 pcs, deposit the keys',
  ]) assertEquals(maskMoney(t), t, t);
});

Deno.test('D-306 round 3: sales, kita, benta, earned, transfer and per-hour amounts mask; a time or code does not hide a price beside it', () => {
  for (const [t, leak] of [
    ['200/hour', '200'], ['sales 3200', '3200'], ['kita 3200', '3200'], ['benta 4500', '4500'], ['earned 1780', '1780'], ['transfer 2500', '2500'], ['1500 sent', '1500'],
    ['Check-in rate 1400', '1400'], ['code 4829, rate 1780', '1780'], ['x 1780 per night', '1780'], ['extra 500 for early check-in', '500'], ['3560 lahat', '3560'],
    ['refund 100%', '100%'], ['100% refund', '100%'], ['Charge 1780 per night', '1780'],
  ]) { const m = maskMoney(t); assert(hasMoney(t) && !m.includes(leak), `${t} -> ${m}`); }
});

Deno.test('D-306 round 3: a staff-pay title with a second amount, a guest-looking bare amount or an income word is masked; Taglish pay stays whole', () => {
  for (const t of ['Pay Ana 1780', 'Pay Honey 500; Ana paid 1780', 'Linis 500, kita 3200', 'supplies 320, sales 3200', 'Pay Honey ₱500 and Ana ₱1,780']) assert(!/\d{3}/.test(maskTitle(t)), `${t} -> ${maskTitle(t)}`);
  for (const t of ['Pay Honey ₱500 for 2 nights', 'Bayad kay Honey ₱500', 'Sweldo ni Honey ₱500', 'Sahod ₱500 Honey', 'Bili ng supplies ₱320', 'Pay Honey ₱500']) assertEquals(maskTitle(t), t, t);
});

Deno.test('D-306 round 4: a 4-digit number is never a time; the orchestrator probes all mask', () => {
  for (const [t, leak] of [
    ['Check-in 1400 for 2 nights', '1400'], ['checkout due 1100', '1100'], ['late checkout 1500 extra', '1500'], ['late checkout 1500 fee', '1500'], ['early check-in 1000 bayad', '1000'],
    ['check-in 1000 deposit', '1000'], ['Check-in tomorrow, 1500 balance pa', '1500'], ['checkout 1100, 2000 balance', '2000'], ['ETA 1400 paid', '1400'],
    ['kada gabi 1780', '1780'], ['per gabi 1780', '1780'], ['each 1780', '1780'], ['nyt 1780', '1780'], ['3 nights each 1780', '1780'],
    ['kulang pa 1780', '1780'], ['kulang pa siya ng 1780', '1780'], ['kulang daw 1780', '1780'],
    ['unit 1780 rate', '1780'], ['order 3560 total', '3560'], ['Code 1780, total', '1780'], ['room 1780, deposit', '1780'],
    ['rate 1780 pax', '1780'], ['rate 1780 pcs', '1780'], ['rate 1780 rolls', '1780'], ['total 3560 mins', '3560'], ['rate 1,780 W', '1,780'], ['guests x 1780', '1780'], ['pax x 1780', '1780'],
    ['rate 1 780', '780'], ['rate 1.780', '780'], ['nightly 1780', '1780'], ['owes 3560', '3560'], ['utang 3560', '3560'], ['booking 5200', '5200'], ['stay 3560', '3560'], ['RevPAR 1300', '1300'],
  ]) { const m = maskMoney(t); assert(hasMoney(t) && !m.includes(leak), `${t} -> ${m}`); }
});

Deno.test('D-306 round 4: the placeholder never makes a count look like money, and a count beside a masked amount stays', () => {
  assertEquals(maskMoney('Laundry ₱320 for 120 towels'), 'Laundry [amount hidden] for 120 towels');
  assertEquals(maskMoney('Bili ng supplies ₱320, 150 hangers'), 'Bili ng supplies [amount hidden], 150 hangers');
  assertEquals(maskTitle('Laundry ₱320 for 120 towels'), 'Laundry ₱320 for 120 towels');
  assertEquals(maskTitle('Bili ng supplies ₱320, 150 hangers'), 'Bili ng supplies ₱320, 150 hangers');
  assertEquals(maskMoney('Door code 4829 sent'), 'Door code 4829 sent');
  assertEquals(maskMoney('already [amount hidden] for 120 towels'), 'already [amount hidden] for 120 towels'); // idempotent
  assertEquals(maskMoney(maskMoney('rate 1780 a night')), maskMoney('rate 1780 a night'));
});

Deno.test('D-306 round 4: stay and cancel in a title, a second bare amount beside a staff amount, and the audit title probes', () => {
  for (const [t, leak] of [['Pay Honey ₱500 stay 2 nights', '500'], ['Cleaning ₱500 cancelled booking', '500'], ['Linis ₱500 and Maria 3560', '3560'], ['Cleaning ₱500 + 1780', '1780'],
    ['Transport ₱150 Maria 3560', '3560'], ['Pay Maria ₱3,560 back', '3,560'], ['Sweldo ₱500 utang 3560', '3560']]) assert(!maskTitle(t).includes(leak), `${t} -> ${maskTitle(t)}`);
  assertEquals(maskTitle('Cleaning fee ₱1,500'), 'Cleaning fee ₱1,500');
});
