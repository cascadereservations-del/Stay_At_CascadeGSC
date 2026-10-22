// deno test -A airbnb-email-sync/tier.test.ts
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { tierBadge } from './tier.ts';

Deno.test('tierBadge: each tier has its own wording', () => {
  assertEquals(tierBadge('vip', 12), '⭐ VIP Guest (12 stays)');
  assertEquals(tierBadge('regular', 4), '🌟 Regular Guest (4 stays)');
  assertEquals(tierBadge('returning', 2), '🔄 Returning Guest (2 stays)');
});
Deno.test('tierBadge: null or unknown tier reads as new', () => {
  assertEquals(tierBadge(null, 1), '🆕 New Guest');
  assertEquals(tierBadge('bogus', 3), '🆕 New Guest');
});
Deno.test('tierBadge: null tier falls back to the stays count', () => {
  assertEquals(tierBadge(null, 2), '🔄 Returning Guest (2 stays)');
  assertEquals(tierBadge(null, 1), '🆕 New Guest');
  assertEquals(tierBadge('regular', 5), '🌟 Regular Guest (5 stays)');
});
