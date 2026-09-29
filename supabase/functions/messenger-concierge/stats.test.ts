// deno test messenger-concierge/stats.test.ts  (run from supabase/functions)
// D-285: one concierge_turn_stats row per guest turn - no psid, no name, no full text; a how-to question the house
// reference could not answer keeps up to three redacted content words (the Monday teach list).
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { missWords, turnStats } from './stats.ts';

const amenity = { intent: 'amenity', confidence: 0.95, needsHost: 0.1, lang: 'en' as const, langConfidence: 0.9, ms: 300 };
const base = { psid: '123', text: 'how do I use the washing machine?', replied: true, lint: [], jev: amenity, house: { rows: [], locked: null }, houseLocked: false, re: 'routine', up: false };

Deno.test('missWords: filler and short words go, content words stay, three at most', () => {
  assertEquals(missWords('Paano po gamitin ang washing machine?'), 'washing machine');
  assertEquals(missWords('how do I use the washing machine?'), 'washing machine');
  assertEquals(missWords('call me 0917 123 4567 about the gate'), 'call gate'); // no digits, no [number]
  assertEquals(missWords('write me at ana@example.com about the parking gate remote please'), 'write parking gate');
  assertEquals(missWords('?'), '');
});

Deno.test('an amenity turn with no HOUSE rows is a miss with its words', () => {
  assertEquals(turnStats(base), { probe: false, lint: [], house: 'miss', miss: 'washing machine', re: 'routine', jev: 'amenity', up: false });
});

Deno.test('a hit keeps no words; a locked turn is locked; a probe is marked', () => {
  assertEquals(turnStats({ ...base, house: { rows: [{}], locked: null } }).house, 'hit');
  assertEquals(turnStats({ ...base, house: { rows: [{}], locked: null } }).miss, null);
  const locked = turnStats({ ...base, psid: 'probe:h1', text: "what's the wifi password?", houseLocked: true, house: { rows: [], locked: {} } });
  assertEquals([locked.house, locked.miss, locked.probe], ['locked', null, true]);
});

Deno.test('a non-how-to turn, or a turn the bot did not answer, has no house reading', () => {
  const price = turnStats({ ...base, text: 'how much for 2 nights?', jev: { ...amenity, intent: 'price' }, lint: ['too_long'] });
  assertEquals([price.house, price.miss, price.lint], [null, null, ['too_long']]);
  assertEquals(turnStats({ ...base, replied: false }).house, null);
  // The regex alone makes it a how-to when Jev timed out or was unsure.
  assertEquals(turnStats({ ...base, jev: null }), { probe: false, lint: [], house: 'miss', miss: 'washing machine', re: 'routine', jev: null, up: false });
  assertEquals(turnStats({ ...base, text: 'is the pool open?', jev: { ...amenity, confidence: 0.6 } }).house, null);
});
