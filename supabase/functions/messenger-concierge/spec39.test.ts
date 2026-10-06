// deno test --no-check -A messenger-concierge/spec39.test.ts
// SPEC-39 (session 72): the pure index.ts pieces - when the site link is applicable (D-300.2), the router's intent told to the
// model (4.3), the thanks-and-blessing closer (3.8), the stay figures for "two months" and the objection's total (4.1, 3.3).
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { SITE_URL } from '../_shared/cascade-core/facts.ts';
import type { JevRoute } from './jev.ts';

// index.ts serves on import; the tests only need its pure exports.
(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { anchorTotal, closingReply, intentHint, linkTurn, stayAnchor, THANKS_RE } = await import('./index.ts');

const jev = (intent: string, confidence = 0.9): JevRoute => ({ intent, confidence, needsHost: 0.1, lang: 'en', langConfidence: 0.9, ms: 300 });
const now = new Date('2026-10-04T03:00:00Z');

Deno.test('SPEC-39 D-300.2 linkTurn: the site only when the guest asks for what it answers', () => {
  for (const t of ['how do I book?', 'may pictures po ba?', 'legit ba kayo?', 'can I see photos of the home?', 'Do you have reviews?', 'what is your website?', 'paano po mag-book?'])
    assertEquals(linkTurn(t, null, now), true, t);
  for (const t of ['is there parking?', 'how much po?', 'thanks', 'Oct 20 to 22 po', 'is there wifi?', 'medyo mahal po'])
    assertEquals(linkTurn(t, null, now), false, t);
  assertEquals(linkTurn('I want to reserve', jev('booking'), now), true);             // Jev sure: booking, no dates
  assertEquals(linkTurn('book Oct 20 to 22', jev('booking'), now), false);           // dated: the flow starts instead
  assertEquals(linkTurn('is this for real', jev('trust'), now), true);
  assertEquals(linkTurn('is this for real', jev('trust', 0.5), now), false);         // unsure: no link
  assertEquals(linkTurn('is there wifi?', jev('amenity'), now), false);              // an amenity alone is a fact
});

Deno.test('SPEC-39 4.3 intentHint: the sure intent is named; an unclear one asks for one warm sentence; else nothing', () => {
  assert(intentHint(jev('price')).includes('Intent read by our router: price'));
  assert(intentHint(jev('other', 0.34)).includes('intent is unclear'));
  assert(intentHint(jev('availability', 0.4)).includes('intent is unclear'));
  assertEquals(intentHint(jev('availability', 0.7)), '');
  assertEquals(intentHint(null), '');
});

Deno.test('SPEC-39 3.8: "Thanks and God bless" is a closer, answered in code with no link', () => {
  for (const t of ['Thanks and God bless', 'ok po salamat, ingat', 'thank you, good night', 'salamat po', 'thanks!']) assertEquals(THANKS_RE.test(t), true, t);
  for (const t of ['thanks, is there parking?', 'thank you for the info, how about Oct 3?']) assertEquals(THANKS_RE.test(t), false, t);
  for (const lang of ['english', 'taglish', 'bisaya']) {
    const r = closingReply('Maria', lang, true, 'Earlier reply with no link.');
    assert(!r.includes(SITE_URL) && !/preferred dates|which dates/i.test(r), `${lang}: ${r}`);
  }
});

Deno.test('SPEC-39 4.1: "two months" gets the code-computed 60-night total; three months goes to the host', () => {
  const two = stayAnchor('Hello, can I ask for details regarding our booking good for two months?');
  assert(two.includes('PHP 1,335') && two.includes('PHP 80,100') && two.includes('PHP 106,800') && two.includes('60 nights'), two);
  assert(stayAnchor('para sa dalawang buwan po', 'taglish').includes('PHP 80,100'));
  assertEquals(stayAnchor('3 months'), '');
  assertEquals(stayAnchor('three months'), '');
  assert(stayAnchor('a week').includes('7 nights'));
  assert(stayAnchor('If I book for a month, how much?').includes('30 nights')); // D-269 unchanged
});

Deno.test('SPEC-39 3.3: the objection hint carries the stay total only - no per-night rate, no standard, no saving', () => {
  const t = anchorTotal('two months po, medyo mahal');
  assert(t.includes('PHP 80,100') && !/1,335|1,780|per night|%/.test(t), t);
  assertEquals(anchorTotal('medyo mahal po'), '');
});

Deno.test('SPEC-39 audit: "hindi naman mahal" and "not expensive at all" are not price objections (no hostAsk, no host card)', async () => {
  const { priceObjection } = await import('./index.ts');
  for (const t of ['hindi naman mahal po', 'not expensive at all', 'dili man mahal', 'wala namang mahal']) assertEquals(priceObjection(t), false, t);
  for (const t of ['medyo mahal po', 'a bit expensive for us', 'any discount?', 'May discount po ba?', 'can you do cheaper?']) assertEquals(priceObjection(t), true, t);
});
