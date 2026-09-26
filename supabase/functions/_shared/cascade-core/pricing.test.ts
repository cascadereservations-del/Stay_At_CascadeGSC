// SPEC-34 2.2 pins. Run: deno test _shared/cascade-core/pricing.test.ts
import { assertEquals } from 'jsr:@std/assert@1';
import { SEED_CARD, loadCard, quote, serverAmounts, _resetCardCache, currentCard } from './pricing.ts';

const NOW = new Date('2026-09-26T08:00:00Z');
// The card before SPEC-34, as submit-booking and facts.ts hard-coded it.
const OLD = [[1, 1780], [2, 1691], [5, 1602], [7, 1513], [14, 1424], [28, 1335]];
const oldRate = (n: number) => OLD.filter(([min]) => n >= min).pop()![1];
const plus = (d: string, k: number) => new Date(Date.parse(d + 'T00:00:00Z') + k * 86_400_000).toISOString().slice(0, 10);

Deno.test('a stay with no promo night costs what it cost before, n = 1..30', () => {
  for (let n = 1; n <= 30; n++) {
    const q = quote(SEED_CARD, '2026-11-02', plus('2026-11-02', n), NOW);
    assertEquals(q.total, oldRate(n) * n, `n=${n}`);
    assertEquals(q.deposit, Math.ceil(oldRate(n) * n / 2), `deposit n=${n}`);
    assertEquals(q.promo_nights, 0);
  }
});

Deno.test('Anniversary pins: Oct 16-19 = 4,777; Oct 11-18 = 10,801; Oct 9-12 = 4,925', () => {
  const a = quote(SEED_CARD, '2026-10-16', '2026-10-19', NOW);
  assertEquals([a.total, a.promo_nights, a.nights.map((x) => x.rate)], [4777, 2, [1543, 1543, 1691]]);
  assertEquals(a.deposit, 2389);
  assertEquals(a.standard_total, 5340);
  assertEquals(quote(SEED_CARD, '2026-10-11', '2026-10-18', NOW).total, 10801);
  const c = quote(SEED_CARD, '2026-10-09', '2026-10-12', NOW);
  assertEquals([c.total, c.nights.map((x) => x.source)], [4925, ['tier', 'tier', 'promo']]);
  assertEquals(quote(SEED_CARD, '2026-10-18', '2026-10-19', NOW).total, 1780, 'checkout day of the promo is a normal night');
});

Deno.test('last minute is 4 Manila days or fewer', () => {
  assertEquals(quote(SEED_CARD, '2026-09-30', '2026-10-01', NOW).last_minute, true);
  assertEquals(quote(SEED_CARD, '2026-10-01', '2026-10-02', NOW).last_minute, false);
});

Deno.test('submit-booking authority: the card total is stored, whatever the client sent', () => {
  const low = serverAmounts(SEED_CARD, '2026-11-02', '2026-11-05', { total: 4566, deposit: 2283 }, NOW); // 10% under 5,073
  assertEquals([low.total, low.deposit, low.full, low.mismatch], [5073, 2537, false, true]);
  const promo = serverAmounts(SEED_CARD, '2026-10-16', '2026-10-19', { total: 5073, deposit: 2537 }, NOW);
  assertEquals([promo.total, promo.deposit], [4777, 2389]);
  const full = serverAmounts(SEED_CARD, '2026-11-02', '2026-11-05', { payFull: true, total: 5073, deposit: 2537 }, NOW);
  assertEquals([full.full, full.deposit], [true, 5073]);
  const legacyFull = serverAmounts(SEED_CARD, '2026-11-02', '2026-11-05', { total: 5073, deposit: 5073 }, NOW);
  assertEquals([legacyFull.full, legacyFull.deposit, legacyFull.mismatch], [true, 5073, false]);
  const near = serverAmounts(SEED_CARD, '2026-09-28', '2026-09-30', { total: 3382, deposit: 1691 }, NOW);
  assertEquals([near.full, near.deposit], [true, 3382], 'inside 5 days the full amount is due');
});

Deno.test('loadCard: a failed read falls back to the seed card (never zero), a good read is used', async () => {
  _resetCardCache();
  const card = await loadCard({ rpc: () => Promise.resolve({ data: null, error: { message: 'boom' } }) }, 1);
  assertEquals(card, SEED_CARD);
  const good = { ...SEED_CARD, base: '1800', tiers: [], promotions: [] };
  _resetCardCache();
  const c2 = await loadCard({ rpc: () => Promise.resolve({ data: good, error: null }) }, 2);
  assertEquals([c2.base, currentCard().base, quote(c2, '2026-11-02', '2026-11-05', NOW).total], [1800, 1800, 5400]);
  // a later failed read (cache expired) keeps the last good card, not the seed
  const c3 = await loadCard({ rpc: () => Promise.resolve({ data: null, error: { message: 'blip' } }) }, 2 + 61_000);
  assertEquals([c3.base, currentCard().base], [1800, 1800]);
  _resetCardCache();
});
