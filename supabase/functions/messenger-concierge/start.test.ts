// deno test --no-check messenger-concierge/start.test.ts
// Session 49 (Lloyd 2026-09-24): every wording that should or should not start the in-chat booking flow. Real guest
// wordings from concierge_threads plus English, Taglish and Bisaya variants. Add a line here before changing bookingStart.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { bookingStart, parseDates } from './booking.ts';
const now = new Date('2026-09-24T14:15:00Z');
const OFFER = 'We can arrange the booking for you right here in the chat, or you may secure your reservation on our site:';
const prior = ['Can i book Oct. 30'];
const cold: Array<[string, boolean]> = [
 ['Can i book Oct. 30', true], ['can I book oct 30-31?', true], ['Can we book Oct 30 to Nov 1 for 3 pax', true], ['I want to book Oct 30', true],
 ['Hi, I\'d like to book Sep 29 to 30 for 2', true], ['pa book po Oct 30', true], ['pa-reserve po Oct 30-31', true], ['pwede po ba mag book Oct 30?', true],
 ['possible to book on the 30th of October?', true], ['book ko po sana Oct 30', true], ['reserve 10/30 to 10/31', true], ['magpa book po ako Nov 5', true],
 ['Available today?', true], ['hello available tonight?', true], ['available tomorrow po?', true], ['avail po ba Oct 30?', true], ['vacant po ba Oct 30?', true], ['bakante pa ba Oct 30?', true],
 ['how to book po', true], ['how can i book?', false], ['Can I book?', false], ['can i bring my dog?', false], ['how much', false], ['how much per night po', false],
 ['Mag inquire po sana', false], ['Payment link', false], ['what is the payment method?', false], ['is the rate per night?', false], ['bukas po ba kayo sa weekend?', false], ['available po ba ang Oct 5? Pwede po ba check in 12 noon?', false],
];
const afterOffer: Array<[string, boolean]> = [
 ['Yes please', true], ['Yes pls', true], ['yes plz', true], ['yes po', true], ['Yes!', true], ['sure', true], ['sige po', true], ['sige', true], ['opo', true], ['oo', true], ['go', true], ['go na po', true], ['g', false],
 ['okay sige', true], ['ok book it', true], ['book na po', true], ['proceed po', true], ['yes, please arrange it', true], ['yes here po', true], ['dito na lang po', true],
 ['ok po salamat', false], ['ok let me think about it first', false], ['ok', false], ['thanks', false], ['no thanks', false], ['how much?', false],
];
const pay: Array<[string, boolean]> = [['Payment link', true], ['how can i pay?', true], ['paano po magbayad', true], ['send me the qr code', true], ['gcash number po', true], ['what is the payment method?', true], ['with parking?', false]];
Deno.test('relative and spelled-out dates', () => {
  assertEquals(parseDates('Available today?', now), ['2026-09-24']);
  assertEquals(parseDates('tonight until tomorrow po', now), ['2026-09-24', '2026-09-25']);
  assertEquals(parseDates('bukas po available?', now), ['2026-09-25']);
  assertEquals(parseDates('the 30th of October', now), ['2026-10-30']);
});
let bad = 0;
for (const [t, want] of pay) { const got = bookingStart(t, prior, '', now); if ((got !== null) !== want || (want && got !== 'Can i book Oct. 30')) { bad++; console.log('PAY', want ? 'MISS' : 'FALSE+', JSON.stringify(t), got); } }
for (const [t, want] of cold) { const got = bookingStart(t, [], '', now) !== null; if (got !== want) { bad++; console.log('COLD', want ? 'MISS' : 'FALSE+', JSON.stringify(t), parseDates(t, now)); } }
for (const [t, want] of afterOffer) { const got = bookingStart(t, prior, OFFER, now) !== null; if (got !== want) { bad++; console.log('YES ', want ? 'MISS' : 'FALSE+', JSON.stringify(t)); } }
Deno.test("the phrase matrix starts the flow exactly where a person would", () => assertEquals(bad, 0));
