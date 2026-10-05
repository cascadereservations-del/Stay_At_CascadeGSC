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


// D-306 round 5 (deny by default): every leak string from the four audits, in one table. Each must lose its digits.
const LEAKS: [string, string][] = [
  // forms of a currency amount
  ['P 1,780 per night', '1,780'], ['Php. 1,780 total', '1,780'], ['Php.1780', '1780'], ['about 1.8k a night', '1.8k'], ['2k pesos deposit', '2k'], ['USD 50 deposit', '50'], ['$50 only', '50'], ['US$50', '50'],
  ['1 780 pesos', '780'], ['2,000 pesos', '2,000'], ['PHP3560', '3560'], ['₱1k', 'k'], ['P1k only', 'k'], ['₱1,780.00', '1,780'], ['piso 500', '500'], ['2 libo', 'libo'], ['2libo po', 'libo'],
  ['isang libo', 'libo'], ['dalawang libo', 'libo'], ['limang libo', 'libo'], ['apat na libo', 'libo'], ['lima ng libo', 'libo'], ['limang daan', 'daan'],
  // bare numbers, no money word needed
  ['rate is 1780', '1780'], ['the total: 3,560', '3,560'], ['balance 1,780 due', '1,780'], ['1780 a night', '1780'], ['1,780 per night', '1,780'], ['I paid 2500 already', '2500'], ['sent 1000 to the number', '1000'],
  ['your budget is around 5000', '5000'], ['refund of 1,780 coming', '1,780'], ['dp 890', '890'], ['1780/night', '1780'], ['1,780/nyt', '1,780'], ['reservation fee 1,780', '1,780'],
  ['Revenue ₱50,000 and the rate is 1,780 a night', '50,000'], ['revenue 50000 this month', '50000'], ['income of 12000', '12000'], ['adr 1780', '1780'], ['payout 2,900', '2,900'],
  ['1,780.00 total', '1,780'], ['total 3,560.00', '3,560'], ['1780.50', '1780'], ['rate 1 780', '780'], ['rate 1.780', '780'], ['1500-2000 per night', '2000'], ['1500-2000 per night', '1500'],
  ['2 nights x 1,780 = 3,560', '3,560'], ['2 nights x 1,780 = 3,560', '1,780'], ['P1780 x2 = 3560', '3560'], ['3,560 = 2 x 1780', '1780'], ['1780 x 2', '1780'], ['x 1780 nights', '1780'], ['1780 night', '1780'],
  ['send the remaining 1,780', '1,780'], ['Kindly send the remaining 1,780 before check-in.', '1,780'], ['An extra bed is 500.', '500'], ['Extra guest is 500 po.', '500'], ['Extra guest 500', '500'], ['Extra bed: 500', '500'],
  ['extra 500 for early check-in', '500'], ['additional 1,000', '1,000'], ['2 gabi 3560', '3560'], ['Ana: 2 gabi, 3560', '3560'], ['1 gabi 1780', '1780'], ['Oct 15 gabi 1900', '1900'], ['kada gabi 1780', '1780'],
  ['per gabi 1780', '1780'], ['each 1780', '1780'], ['nyt 1780', '1780'], ['3 nights each 1780', '1780'], ['Maria ₱1,780, Ana 1780', '1780'], ['Maria paid ₱1,780; Ana 1780 cash', '1780'],
  ['Collected today: Maria ₱1,780, Ana 1,780', '1,780'], ['Weekday 1780, weekend 1980', '1980'], ['Weekday 1780, weekend 1980', '1780'], ['Ana: 1780', '1780'], ['Maria 3560', '3560'],
  ['Refunded 1,780', '1,780'], ['Refunded 1,780 to Maria', '1,780'], ['kulang pa po kayo ng 1,780', '1,780'], ['Nagpadala na po ako ng 1,780', '1,780'], ['kulang pa 1780', '1780'], ['kulang pa siya ng 1780', '1780'],
  ['bayad 2500', '2500'], ['singil 1780 kada gabi', '1780'], ['presyo 1,780', '1,780'], ['halaga 3560', '3560'], ['kabuuan 3560', '3560'], ['3560 lahat', '3560'], ['sukli 220', '220'], ['dagdag 300', '300'],
  ['gcash 1780', '1780'], ['send ko 1780 later', '1780'], ['200/hour', '200'], ['500 per hour', '500'], ['300 per head', '300'], ['1500 per pax', '1500'], ['sales 3200', '3200'], ['kita 3200', '3200'],
  ['benta 4500', '4500'], ['earned 1780', '1780'], ['transfer 2500', '2500'], ['owes 3560', '3560'], ['utang 3560', '3560'], ['booking 5200', '5200'], ['guest 5200', '5200'], ['stay 3560', '3560'], ['RevPAR 1300', '1300'],
  // times are never 4 digits, and a number beside a money word stays money
  ['Check-in 1400 for 2 nights', '1400'], ['checkout due 1100', '1100'], ['late checkout 1500 extra', '1500'], ['late checkout 1500 fee', '1500'], ['early check-in 1000 bayad', '1000'], ['check-in 1000 deposit', '1000'],
  ['Check-in tomorrow, 1500 balance pa', '1500'], ['checkout 1100, 2000 balance', '2000'], ['ETA 1400 paid', '1400'], ['Late checkout until 1500 costs 500; early check-in 1000 bayad.', '1500'],
  ['unit 1780 rate', '1780'], ['order 3560 total', '3560'], ['Code 1780, total', '1780'], ['Maria GCash ref 1780 sent', '1780'], ['rate 1780 pax', '1780'], ['rate 1780 pcs', '1780'], ['rate 1780 rolls', '1780'],
  ['total 3560 mins', '3560'], ['guest pays 1780 pcs', '1780'], ['guests x 1780', '1780'], ['1780x2', '1780'],
  // percents beside money, and the rest of the audit phrases
  ['refund 50%', '50%'], ['50% refund', '50%'], ['occupancy 73%', '73%'], ['occupancy is 73 percent', '73'], ['20% discount', '20%'], ['refund 100%', '100%'], ['deposit 50 percent', '50'],
  ['Airbnb paid out 5,200', '5,200'], ['Host earns 3,200', '3,200'], ['Monthly 25000', '25000'], ['Promo 1500 for weekdays', '1500'], ['Pet 300', '300'], ['Early check-in 500', '500'],
  ['Maria (2 nights) 3,560', '3,560'], ['Maria - 3,560 - Oct 15', '3,560'], ['Half now 1780, half on arrival 1780', '1780'], ['Downpayment niya 890', '890'], ['deposit daw 1000', '1000'],
];
Deno.test('D-306 round 5: every leak string from all four audits loses its amount (maskMoney and hasMoney)', () => {
  for (const [t, leak] of LEAKS) { const m = maskMoney(t); assert(hasMoney(t), `hasMoney ${t}`); assert(!m.includes(leak), `${t} -> ${m}`); }
});

Deno.test('D-306 round 5 keep-list: measures, counts, codes, hotlines, phones, refs, uuids, urls, dates and colon times survive', () => {
  for (const t of [
    'Charge the EcoFlow to 100%', 'Run the EcoFlow at 300 W, charge it to 100%', '300 W', '300 Wh', '1.2 kWh', 'Send 120 Rolls', 'Send 120 rolls', 'kulang ng 120 rolls', 'lahat ng 150 hangers', 'each 500 ML', '500 ml shampoo',
    'Restock 250 pcs, deposit the keys', 'Tissue 120 sheets per night', 'Room 203 extra towels', 'Room 203, 2 extra towels each', 'Door code 4829 sent', 'Door code 482913 sent to Ana', 'PIN 1234 sent', 'unit 101 is ready',
    'Police hotline 0998-598-7207; Bureau of Fire Protection 160. The nearest 24-hour emergency room is St. Elizabeth Hospital, (083) 552-3162.', 'BFP 160', 'Call 911 or 117', 'ID 1a2b3c4d, HMYDBYKYPC, 00A49C5E, HMA1234567, Booking #12345 paid',
    'Call 0917 123 4567 about the paid parking', 'Number +63 917 123 4567 sent for the night shift', 'Call 09171234567 tonight', 'Mail ana@example.com or see https://cascade.ph/b/1780?x=3560',
    'ref 3f2a9c1e-5b7d-4e21-9a0c-1d2e3f4a5b6c paid', 'Check-in 2026-10-05, 14:00, 2 pax, room 12', 'Oct 15, 2026', '15 Oct 2026', 'October 2026, 5 nights', '10/15', 'Arrives 2:30pm, leaves 1030am, back by 2pm', 'D-306 and SPEC-38',
    'Weather: showers 25-30C, 60% rain', 'Tue, Oct 20 → Thu, Oct 22 · 2 guests',
  ]) assertEquals(maskMoney(t), t, t);
});

Deno.test('D-306 round 5: maskTitle keeps one staff or expense amount whole and masks the rest', () => {
  for (const t of ['Pay Honey ₱500', 'Bili ng supplies ₱320', 'Laundry ₱320 for 120 towels', 'Bili ng supplies ₱320, 150 hangers', 'Cleaning fee ₱1,500', 'Bayad kay Honey ₱500', 'Sweldo ni Honey ₱500'])
    assertEquals(maskTitle(t), t, t);
  for (const [t, leak] of [['Collect ₱3,000 balance from guest', '3,000'], ['Pay Ana 1780', '1780'], ['Pay Honey 500; Ana paid 1780', '1780'], ['Linis 500, kita 3200', '3200'], ['supplies 320, sales 3200', '3200'],
    ['Linis ₱500 and Maria 3560', '3560'], ['Cleaning ₱500 + 1780', '1780'], ['Pay Maria ₱3,560 for 2 nights', '3,560'], ['Pay Maria ₱3,560 back', '3,560'], ['Pay Honey ₱500 stay 2 nights', '500'], ['Cleaning ₱500 cancelled booking', '500'],
    ['Cleaning ₱500 Oct 15 at 1400', '1400'], ['Late checkout 1500 fee for Maria', '1500'], ['Laundry deposit refund PHP 1,780', '1,780'], ['Pay Honey ₱3,560 balance', '3,560']]) assert(!maskTitle(t).includes(leak), `${t} -> ${maskTitle(t)}`);
  assert(!maskTitle('Pay Honey ₱500 to 0956 011 5744').includes('5744'));
  assertEquals(maskTitle('Property inspection 2026-10-05, call 0917 123 4567'), 'Property inspection 2026-10-05, call 0917 123 4567');
});
