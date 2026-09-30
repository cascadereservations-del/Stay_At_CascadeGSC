// deno test --no-check -A messenger-concierge/d269.test.ts
// D-269 (Lloyd's live sample, 2026-09-27): a house-rule question is answered, the discount host line is part of the answer
// and said once, a month is priced by code, and a 🌿 only ever closes a message.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { houseRuleKind } from './policy.ts';
import { leafAtClose, lintReply } from './voice.ts';
import { discountHostLine, houseRule } from './persona.ts';
import { SITE_URL } from '../_shared/cascade-core/facts.ts';

(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { stayAnchor } = await import('./index.ts');

Deno.test('houseRuleKind: party, pets and extra guests have a rule to state; haggling does not', () => {
  assertEquals(houseRuleKind('Is party allowed?'), 'party');
  assertEquals(houseRuleKind('can we bring our dog?'), 'pets');
  assertEquals(houseRuleKind('ok lang ba overnight visitors?'), 'guests');
  assertEquals(houseRuleKind('tawad po, 1500 na lang'), null);
});

Deno.test('houseRule answers first: the rule from FACTS, then the host, and passes the lint for the question asked', () => {
  const r = houseRule('party', 'en');
  assert(/^We're a quiet private retreat/.test(r) && /parties or events/.test(r) && /10 PM to 6 AM/.test(r), r);
  assertEquals(lintReply(r, 'Is party allowed?'), []);
  assert(!/That's a request/.test(r));
});


Deno.test('leafAtClose keeps one closing 🌿 and drops a mid-message one', () => {
  assertEquals(leafAtClose('We are glad to help. 🌿\n\nJust let us know your dates.'), 'We are glad to help.\n\nJust let us know your dates.');
  assertEquals(leafAtClose('One. 🌿\n\nTwo. 🌿'), 'One.\n\nTwo. 🌿');
  assertEquals(leafAtClose('No leaf.'), 'No leaf.');
});

Deno.test('stayAnchor: "a month" is 30 nights and "2 weeks" 14, priced by code (live: the month total was left to the site)', () => {
  const m = stayAnchor('If I book for a month, how much?');
  assert(/for 30 nights/.test(m) && /PHP 40,050/.test(m) && /PHP 53,400/.test(m), m);
  assert(/for 14 nights/.test(stayAnchor('2 weeks po magkano?')));
  assertEquals(stayAnchor('how much per night?'), '');
});


Deno.test('D-270 risk gaps the Jev bench found: smoke, Bisaya complaints and "move our dates" escalate; "can we smoke?" does not', async () => {
  const { classify } = await import('./policy.ts');
  assertEquals(classify("There's smoke coming from the kitchen"), 'safety');
  assertEquals(classify('I smell gas near the stove'), 'safety');
  assertEquals(classify('walay tubig diri sa unit'), 'complaint');
  assertEquals(classify('Can we move our dates to Nov 2?'), 'cancellation');
  assertEquals(classify('Can we smoke on the porch?'), 'routine');
});
