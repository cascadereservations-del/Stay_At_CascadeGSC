import { assertEquals } from 'jsr:@std/assert@1';
import { buildPrompt, decodeImage, gateAction, mapCategory, receiptPath, scrubMoney, shapeExtraction, validDate } from './logic.ts';

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
  const b64 = (...b: number[]) => btoa(String.fromCharCode(...b));
  const jpeg = b64(0xff, 0xd8, 0xff, 0xe0, 1, 2);
  const ok = decodeImage(jpeg, 'image/jpeg');
  assertEquals(ok.ok && ok.ext, 'jpg');
  assertEquals(decodeImage(b64(0x89, 0x50, 0x4e, 0x47, 1), 'image/png').ok, true);
  assertEquals(decodeImage(b64(0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50), 'image/webp').ok, true);
  // magic bytes must match the declared type
  assertEquals((decodeImage(b64(0x89, 0x50, 0x4e, 0x47, 1), 'image/jpeg') as { status: number }).status, 415);
  assertEquals((decodeImage(btoa('abc'), 'image/jpeg') as { status: number }).status, 415);
  assertEquals((decodeImage(jpeg, 'application/pdf') as { status: number }).status, 415);
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

Deno.test('supply mode needs report_supply; every other mode, a bad body and a missing mode keep approve_payment', () => {
  assertEquals(gateAction({ mode: 'supply' }), 'report_supply');
  for (const b of [{ mode: 'extract' }, {}, null, { mode: 'Supply' }]) assertEquals(gateAction(b), 'approve_payment');
});

Deno.test('index.ts gates on gateAction before any work, and still names approve_payment nowhere weaker', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertEquals(src.includes('requireStaffAccess(req, gateAction(body), PROPERTY_ID)'), true);
  assertEquals(src.indexOf('gateAction(body)') < src.indexOf("body.mode === 'supply'"), true);
  assertEquals(/requireStaffAccess\(req, 'report_supply'/.test(src), false);
});

Deno.test('scrubMoney strips prices from a description and keeps sizes (D-330)', () => {
  assertEquals(scrubMoney('TISSUE 12S ₱45.00'), 'TISSUE 12S');
  assertEquals(scrubMoney('NATURES SPRING 500ML 25.00'), 'NATURES SPRING 500ML');
  assertEquals(scrubMoney('SAFEGUARD WHT 135G P 52.75'), 'SAFEGUARD WHT 135G');
  assertEquals(scrubMoney('BATH TISSUE 2PLY PHP 1,234.50'), 'BATH TISSUE 2PLY');
  assertEquals(scrubMoney('1,234.50 BLEACH 1.5L'), 'BLEACH 1.5L');
  assertEquals(scrubMoney('P99 SOAP'), 'SOAP');
  assertEquals(scrubMoney('PANTENE SHAMPOO 12S'), 'PANTENE SHAMPOO 12S');
  assertEquals(scrubMoney('₱45.00'), 'Item');
});
