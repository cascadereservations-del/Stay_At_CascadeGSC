import { assertEquals } from 'jsr:@std/assert@1';
import { buildPrompt, decodeImage, mapCategory, receiptPath, shapeExtraction, validDate } from './logic.ts';

Deno.test('buildPrompt swaps the hardcoded category list for the live slugs and ignores odd ones', () => {
  const base = 'x ONE of: supplies, utilities, cleaning, maintenance, repairs, platform_fees, other y';
  assertEquals(buildPrompt(base, ['supplies', 'loan', 'Bad Slug', 'other']), 'x ONE of: supplies, loan, other y');
  assertEquals(buildPrompt(base, []), base);
});

Deno.test('mapCategory only returns a slug on the canonical list', () => {
  const valid = new Set(['supplies', 'loan', 'other']);
  assertEquals(mapCategory(' Loan ', valid), 'loan');
  assertEquals(mapCategory('platform_fees', valid), 'other');
  assertEquals(mapCategory(null, valid), 'other');
});

Deno.test('decodeImage refuses wrong type, empty, oversized and bad base64; accepts a small jpeg', () => {
  const ok = decodeImage(btoa('abc'), 'image/jpeg');
  assertEquals(ok.ok && ok.ext, 'jpg');
  assertEquals((decodeImage(btoa('abc'), 'application/pdf') as { status: number }).status, 415);
  assertEquals((decodeImage('', 'image/png') as { status: number }).status, 400);
  assertEquals((decodeImage('%%%', 'image/png') as { status: number }).status, 400);
  assertEquals((decodeImage('A'.repeat(8_000_001), 'image/webp') as { status: number }).status, 413);
});

Deno.test('receiptPath sits under the property folder the SQL accepts', () => {
  assertEquals(receiptPath('P', 'U', 'jpg', 'I'), 'P/U/I.jpg');
});

Deno.test('validDate rejects the future, ancient and malformed dates', () => {
  const now = Date.parse('2026-10-16T00:00:00Z');
  assertEquals(validDate('2026-10-15', now), '2026-10-15');
  assertEquals(validDate('2026-12-01', now), null);
  assertEquals(validDate('2019-01-01', now), null);
  assertEquals(validDate('10/15/2026', now), null);
});

Deno.test('shapeExtraction maps the hint, clamps confidence, nulls a zero amount, keeps structured items', () => {
  const r = shapeExtraction({ amount: 0, date: '2026-10-15', vendor: 'Zz', category_hint: 'loan', confidence: 4, line_items: ['soap', { description: 'bleach', qty: 2, unit_cost: 30 }] },
    new Set(['loan', 'other']), Date.parse('2026-10-16T00:00:00Z'));
  assertEquals(r.amount, null);
  assertEquals(r.category, 'loan');
  assertEquals(r.confidence, 1);
  assertEquals(r.line_items, [{ description: 'soap', qty: null, unit_cost: null }, { description: 'bleach', qty: 2, unit_cost: 30 }]);
});
