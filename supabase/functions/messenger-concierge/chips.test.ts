// deno test --no-check -A messenger-concierge/chips.test.ts
// Session 59: one-tap next steps (DESIGN-quick-reply-next-steps-2026-09-28).
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { CHIP, chipsFor, isHello, quickReplyText, stripPassiveClose } from './chips.ts';
import { toneRules } from './voice.ts';

const on = { eligible: true, hello: false, place: false, amenity: false };
const titles = (c: { title: string }[]) => c.map((x) => x.title);

Deno.test('every chip title fits Messenger (20 characters) and every set is two or three chips', () => {
  for (const c of Object.values(CHIP)) assertEquals(c.title.length <= 20, true, c.title);
  for (const s of [{ ...on, hello: true }, { ...on, place: true }, { ...on, amenity: true }, on]) {
    const n = chipsFor(s).length; assertEquals(n >= 2 && n <= 3, true);
  }
});

Deno.test('the sets follow the design; an ineligible turn (handoff, host matter, flow, thanks) gets none', () => {
  assertEquals(titles(chipsFor({ ...on, hello: true })), ['Dates and rates', 'The neighbourhood', 'Comforts of the home']);
  assertEquals(titles(chipsFor({ ...on, place: true })), ['Check my dates', 'See the home', 'Comforts of the home']);
  assertEquals(titles(chipsFor({ ...on, amenity: true })), ['Check my dates', 'See the home', 'The neighbourhood']);
  assertEquals(titles(chipsFor(on)), ['Check my dates', 'See the home']);
  assertEquals(chipsFor({ ...on, eligible: false, place: true }), []);
});

Deno.test('a tap is the chip question; a code payload falls back', () => {
  assertEquals(quickReplyText({ text: 'Check my dates', quick_reply: { payload: CHIP.checkDates.payload } }), 'How much is it, and are my dates available?');
  assertEquals(quickReplyText({ text: 'x', quick_reply: { payload: 'SOME_CODE' } }), '');
  assertEquals(quickReplyText({ text: 'typed' }), '');
  assertEquals([isHello('Good evening po'), isHello('Hi'), isHello('hi, is Oct 3 available?'), isHello('how far is the mall')], [true, true, false, false]);
});

Deno.test('the passive close goes; a bare fact gets the warm line; a warm close stays', () => {
  const r = 'We are inside Bria Homes, a quiet gated subdivision.\n\nIf you have any dates in mind, please let us know, and we would be glad to check.';
  assertEquals(stripPassiveClose(r, 'en'), "We are inside Bria Homes, a quiet gated subdivision.\n\nWe'd be glad to have you here.");
  const warm = 'The mall is ten minutes away. We look forward to welcoming you. Just let us know your preferred dates 🌿';
  assertEquals(stripPassiveClose(warm, 'en'), 'The mall is ten minutes away. We look forward to welcoming you.');
  assertEquals(stripPassiveClose('Parking is free, right in front of the unit.', 'en'), 'Parking is free, right in front of the unit.');
});

Deno.test('the fallback closes pass the persona gate in every register', () => {
  for (const l of ['en', 'tl', 'bis'] as const) assertEquals(toneRules(stripPassiveClose('Fact. Let us know.', l), l), []);
});
