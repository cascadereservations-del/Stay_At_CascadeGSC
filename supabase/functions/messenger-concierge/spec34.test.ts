// deno test --allow-read messenger-concierge/spec34.test.ts
// SPEC-34 (D-262): the concierge quotes from the stored rate card; promo nights are anchored on the standard rate;
// FACTS/VOICE follow the card and carry a live promotion; PHP 1,929 appears nowhere.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { rateLine, quoteTotal, type Flow } from './booking.ts';
import { dropNameAsk, lintReply } from './voice.ts';
import { allowedPesos, pesosIn } from './golden-score.ts';
import { FACTS, VOICE, factsFor, tierLine, voiceFor } from '../_shared/cascade-core/facts.ts';
import { SEED_CARD, type RateCard } from '../_shared/cascade-core/pricing.ts';

const now = new Date('2026-09-26T08:00:00Z');
const f = (a: string, z: string, lang: 'en' | 'tl' | 'bis' = 'en'): Flow => ({ step: 'offer', checkin: a, checkout: z, pax: 2, lang, started_at: now.toISOString(), updated_at: now.toISOString() });
const noPromo: RateCard = { ...SEED_CARD, promotions: [] };

Deno.test('rateLine: a stay straddling the promotion names both parts, anchored on PHP 1,780', () => {
  assertEquals(rateLine(f('2026-10-16', '2026-10-19'), now),
    'Booking directly with us, your 3 nights come to PHP 4,777: 2 nights (Oct 16 to 17) at our Anniversary Promotion rate of PHP 1,543, and 1 night at PHP 1,691, instead of the standard PHP 1,780 a night.');
  assertEquals(rateLine(f('2026-10-12', '2026-10-15', 'tl'), now),
    'Pasok po ang 3 nights ninyo sa Anniversary Promotion namin, kaya sa direct booking ay PHP 1,543 per night imbes na ang standard na PHP 1,780 — PHP 4,629 for the stay.');
  assertEquals(rateLine(f('2026-10-17', '2026-10-18'), now), 'For 1 night the direct rate is PHP 1,543 with our Anniversary Promotion (our standard is PHP 1,780).');
  assertEquals(rateLine(f('2026-10-09', '2026-10-12', 'bis'), now).includes('1 night (Oct 11) sa Anniversary Promotion rate nga PHP 1,543'), true);
});

Deno.test('rateLine promo lines are lint-clean in en, tl and bis and quote only allowed pesos', () => {
  const ok = allowedPesos();
  for (const lang of ['en', 'tl', 'bis'] as const) for (const [a, z] of [['2026-10-16', '2026-10-19'], ['2026-10-12', '2026-10-15'], ['2026-10-17', '2026-10-18']]) {
    const line = rateLine(f(a, z, lang), now);
    assertEquals(lintReply(line), [], `${lang} ${a}: ${line}`);
    for (const p of pesosIn(line)) assert(ok.has(p), `${p} not allowed in: ${line}`);
    assert(!line.includes('1,929'));
  }
});

Deno.test('dropNameAsk removes a compound name ask that ends in a full stop (golden first-rate-tl, 2026-09-26)', () => {
  const r = dropNameAsk('Our direct rate po starts at PHP 1,780 per night.\n\nMay we know your name po, and if you have dates in mind, share lang dito, pati ilan kayo, and we\'ll check the calendar and the best rate for you right away.\n\nWe can arrange the booking dito sa chat.');
  assertEquals(/your name/i.test(r), false, r);
  assert(r.includes('If you have dates in mind, share lang dito, pati ilan kayo'), r);
  assertEquals(dropNameAsk('May we know your name?\n\nThanks.'), 'Thanks.');
  assertEquals(dropNameAsk('Our rate is PHP 1,780.'), 'Our rate is PHP 1,780.');
});

Deno.test('a plain stay is quoted exactly as before', () => {
  assertEquals(quoteTotal('2026-11-17', '2026-11-20').total, 5073);
  assertEquals(rateLine(f('2026-11-17', '2026-11-19'), now), 'Booking directly with us brings your 2 nights to PHP 1,691 per night instead of the standard PHP 1,780 — PHP 3,382 for the stay.');
});

Deno.test('FACTS and VOICE follow the card; the seed card leaves them byte-identical', () => {
  assert(FACTS.includes(tierLine(SEED_CARD)), 'the generated tier line matches the written one');
  assertEquals(factsFor(noPromo, now), FACTS);
  assertEquals(voiceFor(SEED_CARD), VOICE);
  const live = factsFor(SEED_CARD, now);
  assert(live.includes('Anniversary Promotion: PHP 1,543 per night for the nights of Oct 11 to Oct 17, 2026 (check-out by Oct 18), instead of our standard PHP 1,780'));
  assert(live.includes('Never say there is no promotion'));
  assert(!live.includes('1,929'));
  assertEquals(factsFor(SEED_CARD, new Date('2026-10-18T08:00:00Z')), FACTS, 'an ended promotion leaves FACTS');
  const up: RateCard = { ...noPromo, base: 1900 };
  assert(factsFor(up, now).includes('1 night 1,900 - 2-4 nights 1,805 (5% off)'));
  assert(factsFor(up, now).includes('PHP 1,900 per night') && !factsFor(up, now).includes('PHP 1,780'));
  assert(voiceFor(up).includes('PHP 1,900') && !voiceFor(up).includes('PHP 1,780'));
});
