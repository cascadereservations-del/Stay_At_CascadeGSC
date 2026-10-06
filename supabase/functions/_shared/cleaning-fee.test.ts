// deno test --no-check --allow-env _shared/cleaning-fee.test.ts
// D-301: the cleaning fee is the schedule row or nothing. Synthetic numbers only.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { cleaningFeeFromRow, manilaDate, RATE_MISSING } from './cleaning-fee.ts';

const D301 = { regular_rate: 500, general_rate: 1000 };

Deno.test('the D-301 row pays 500 regular and 1,000 deep clean', () => {
  assertEquals(cleaningFeeFromRow(D301, 'turnover'), 500);
  assertEquals(cleaningFeeFromRow(D301, null), 500);
  assertEquals(cleaningFeeFromRow(D301, 'deep_clean'), 1000);
});

Deno.test('no row, or an unreadable row, is null: never a guessed 500', () => {
  assertEquals(cleaningFeeFromRow(null, 'turnover'), null);
  assertEquals(cleaningFeeFromRow(undefined, 'deep_clean'), null);
  assertEquals(cleaningFeeFromRow({}, 'turnover'), null);
  assertEquals(cleaningFeeFromRow({ regular_rate: null, general_rate: null }, 'deep_clean'), null);
  assertEquals(cleaningFeeFromRow({ regular_rate: 0, general_rate: 0 }, 'turnover'), null);
  assertEquals(cleaningFeeFromRow({ regular_rate: 'abc' }, 'turnover'), null);
});

Deno.test('a deep clean on a row with no deep rate takes the regular rate, as staff_pay_rate_v1 does; never 500 by default', () => {
  assertEquals(cleaningFeeFromRow({ regular_rate: 650, general_rate: null }, 'deep_clean'), 650);
  assertEquals(cleaningFeeFromRow({ regular_rate: null, general_rate: 1000 }, 'turnover'), null);
});

Deno.test('numeric strings from PostgREST (numeric columns) are read as numbers', () => {
  assertEquals(cleaningFeeFromRow({ regular_rate: '500.00', general_rate: '1000.00' }, 'deep_clean'), 1000);
});

Deno.test('the pay day of a clean is the Manila date: 23:30Z is already tomorrow in Manila', () => {
  assertEquals(manilaDate('2026-10-05T23:30:00+00:00', 'x'), '2026-10-06');
  assertEquals(manilaDate('2026-10-06T15:59:00Z', 'x'), '2026-10-06');
  assertEquals(manilaDate('2026-10-06T16:00:00Z', 'x'), '2026-10-07');
  assertEquals(manilaDate(null, '2026-10-07'), '2026-10-07');
  assertEquals(manilaDate('not a date', '2026-10-07'), '2026-10-07');
});

Deno.test('the rate-missing line names the day and offers the two ways out', () => {
  const t = RATE_MISSING('2026-10-06');
  assertEquals(t.includes('2026-10-06') && t.includes('Pay rates') && t.includes('Edit amount'), true);
});

Deno.test('the Finance fee line shows the rate or says it is missing, never 500', async () => {
  const { feeDueText } = await import('./cleaning-fee.ts');
  assertEquals(feeDueText(1000), '₱1000');
  assertEquals(feeDueText(null).startsWith('rate missing'), true);
  assertEquals(feeDueText(null).includes('500'), false);
});
