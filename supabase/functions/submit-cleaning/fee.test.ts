// deno test --no-check --allow-env submit-cleaning/fee.test.ts
// D-301: the fee in the Finance message is the schedule row of the clean's pay day, for its property, or an honest "missing" / "unreadable".
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { resolveFee } from './fee.ts';
import { feeDueText, payDay } from '../_shared/cleaning-fee.ts';

// A fake PostgREST client that records the filters and answers a fixed result.
function fake(result: unknown, throws = false) {
  const calls: Record<string, unknown> = {};
  const q: any = {
    select: () => q,
    eq: (c: string, v: unknown) => { calls['eq:' + c] = v; return q; },
    lte: (c: string, v: unknown) => { calls['lte:' + c] = v; return q; },
    order: () => q,
    limit: () => q,
    maybeSingle: () => { if (throws) throw new Error('boom'); return Promise.resolve(result); },
  };
  return { db: { from: (t: string) => { calls.table = t; return q; } }, calls };
}
const P = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';

Deno.test('the D-301 row: 500 regular, 1,000 deep clean, looked up by property and pay day', async () => {
  const f = fake({ data: { regular_rate: 500, general_rate: 1000 }, error: null });
  assertEquals(await resolveFee(f.db, P, 'turnover', '2026-10-06'), { fee: 500, error: false });
  assertEquals(f.calls['eq:property_id'], P);
  assertEquals(f.calls['lte:effective_from'], '2026-10-06');
  assertEquals((await resolveFee(fake({ data: { regular_rate: 500, general_rate: 1000 }, error: null }).db, P, 'deep_clean', '2026-10-06')).fee, 1000);
});

Deno.test('no row is a real gap: fee null, not an error, never 500', async () => {
  assertEquals(await resolveFee(fake({ data: null, error: null }).db, P, 'turnover', '2026-10-06'), { fee: null, error: false });
  assertEquals(await resolveFee(fake({ data: { regular_rate: 0 }, error: null }).db, P, 'turnover', '2026-10-06'), { fee: null, error: false });
});

Deno.test('a failed read is its own state, not "rate missing"', async () => {
  assertEquals(await resolveFee(fake({ data: null, error: { message: 'timeout' } }).db, P, 'turnover', '2026-10-06'), { fee: null, error: true });
  assertEquals(await resolveFee(fake(null, true).db, P, 'turnover', '2026-10-06'), { fee: null, error: true });
});

Deno.test('no property: no query at all, the error state', async () => {
  const f = fake({ data: { regular_rate: 500 }, error: null });
  assertEquals(await resolveFee(f.db, null, 'turnover', '2026-10-06'), { fee: null, error: true });
  assertEquals(await resolveFee(f.db, '', 'turnover', '2026-10-06'), { fee: null, error: true });
  assertEquals(f.calls.table, undefined);
});

Deno.test('the pay day is checkout, else check-in, else the Manila date of the clean', () => {
  assertEquals(payDay({ checkout_date: '2026-10-02', checkin_date: '2026-09-30', cleaned_at: '2026-10-05T23:30:00Z' }, 'x'), '2026-10-02');
  assertEquals(payDay({ checkout_date: null, checkin_date: '2026-09-30', cleaned_at: '2026-10-05T23:30:00Z' }, 'x'), '2026-09-30');
  assertEquals(payDay({ checkout_date: '', checkin_date: null, cleaned_at: '2026-10-05T23:30:00Z' }, 'x'), '2026-10-06');
  assertEquals(payDay({}, '2026-10-07'), '2026-10-07');
});

Deno.test('the Finance line: amount, rate missing (set it) and rate unreadable (try again) are three different lines', () => {
  assertEquals(feeDueText({ fee: 500, error: false }), '₱500');
  assertEquals(feeDueText({ fee: null, error: false }), 'rate missing, set it in Settings, Pay rates');
  assertEquals(feeDueText({ fee: null, error: true }), 'rate could not be read, try again');
});
