// SPEC-34 2.2 pins. Run: deno test _shared/cascade-core/pricing.test.ts
import { assertEquals } from 'jsr:@std/assert@1';
import { DEPOSIT_RETURN_BUSINESS_DAYS, LONG_STAY_NIGHTS, SECURITY_DEPOSIT_PHP, SEED_CARD, loadCard, quote, serverAmounts, isLongStay, _resetCardCache, currentCard } from './pricing.ts';

const NOW = new Date('2026-09-26T08:00:00Z');
// The card before SPEC-34, as submit-booking and facts.ts hard-coded it.
const OLD = [[1, 1780], [2, 1691], [5, 1602], [7, 1513], [14, 1424], [28, 1335]];
const oldRate = (n: number) => OLD.filter(([min]) => n >= min).pop()![1];
const plus = (d: string, k: number) => new Date(Date.parse(d + 'T00:00:00Z') + k * 86_400_000).toISOString().slice(0, 10);

Deno.test('a stay with no promo night costs what it cost before, n = 1..30', () => {
  for (let n = 1; n <= 30; n++) {
    const q = quote(SEED_CARD, '2026-11-02', plus('2026-11-02', n), NOW);
    assertEquals(q.total, oldRate(n) * n, `n=${n}`);
    assertEquals(q.deposit, q.total, `s138: the amount due to confirm is the whole stay, n=${n}`);
    assertEquals(q.promo_nights, 0);
  }
});

Deno.test('Anniversary pins: Oct 16-19 = 4,777; Oct 11-18 = 10,801; Oct 9-12 = 4,925', () => {
  const a = quote(SEED_CARD, '2026-10-16', '2026-10-19', NOW);
  assertEquals([a.total, a.promo_nights, a.nights.map((x) => x.rate)], [4777, 2, [1543, 1543, 1691]]);
  assertEquals(a.deposit, 4777); // s138: the whole stay (was the 50% fee, 2,389)
  assertEquals(a.standard_total, 5340);
  assertEquals(quote(SEED_CARD, '2026-10-11', '2026-10-18', NOW).total, 10801);
  const c = quote(SEED_CARD, '2026-10-09', '2026-10-12', NOW);
  assertEquals([c.total, c.nights.map((x) => x.source)], [4925, ['tier', 'tier', 'promo']]);
  assertEquals(quote(SEED_CARD, '2026-10-18', '2026-10-19', NOW).total, 1780, 'checkout day of the promo is a normal night');
});

Deno.test('a card scheduled for later prices the stays that check in on or after its start (review finding 1)', () => {
  const card = { ...SEED_CARD, promotions: [], upcoming: [{ effective_from: '2026-12-01', base: 2000, deposit_pct: 40, tiers: [{ min_nights: 3, pct: 10 }] }] };
  assertEquals(quote(card, '2026-11-27', '2026-11-30', NOW).total, 5073, 'before the start: today\'s card');
  const d = quote(card, '2026-12-05', '2026-12-08', NOW);
  assertEquals([d.total, d.deposit, d.standard_total, d.tier_rate], [5400, 5400, 6000, 1800], 'from the start: the new card; s138: deposit_pct no longer matters, the whole stay is due');
  assertEquals(quote(card, '2026-11-30', '2026-12-02', NOW).total, 2 * 1691, 'a stay straddling the start is priced by its check-in date');
  assertEquals(quote({ ...card, upcoming: undefined }, '2026-12-05', '2026-12-08', NOW).total, 5073, 'a card without upcoming behaves as before');
});

Deno.test('s138 (D-428): there is no last-minute rule - the quote never says so, whatever the days to check-in', () => {
  assertEquals(quote(SEED_CARD, '2026-09-30', '2026-10-01', NOW).last_minute, false);
  assertEquals(quote(SEED_CARD, '2026-10-01', '2026-10-02', NOW).last_minute, false);
});

Deno.test('s138 (D-429, D-430): the shared constants - P800 deposit, 3 business days to return it, 28 nights is a long stay', () => {
  assertEquals([SECURITY_DEPOSIT_PHP, DEPOSIT_RETURN_BUSINESS_DAYS, LONG_STAY_NIGHTS], [800, 3, 28]);
  assertEquals([isLongStay(27), isLongStay(28), isLongStay(60)], [false, true, true]);
});

Deno.test('submit-booking authority: the card total is stored, whatever the client sent, and the amount due is always the whole stay (s138)', () => {
  const low = serverAmounts(SEED_CARD, '2026-11-02', '2026-11-05', { total: 4566, deposit: 2283 }, NOW); // 10% under 5,073
  assertEquals([low.total, low.deposit, low.full, low.mismatch], [5073, 5073, true, true]);
  const promo = serverAmounts(SEED_CARD, '2026-10-16', '2026-10-19', { total: 5073, deposit: 2537 }, NOW);
  assertEquals([promo.total, promo.deposit], [4777, 4777]);
  // a client pay_full flag or a 50% deposit is accepted and harmless: same result
  const full = serverAmounts(SEED_CARD, '2026-11-02', '2026-11-05', { payFull: true, total: 5073, deposit: 2537 }, NOW);
  assertEquals([full.full, full.deposit, full.mismatch], [true, 5073, false]);
  const half = serverAmounts(SEED_CARD, '2026-11-02', '2026-11-05', { total: 5073, deposit: 2537 }, NOW);
  assertEquals([half.full, half.deposit, half.mismatch], [true, 5073, false]);
  const near = serverAmounts(SEED_CARD, '2026-09-28', '2026-09-30', { total: 3382, deposit: 1691 }, NOW);
  assertEquals([near.full, near.deposit], [true, 3382]);
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

// ---- s138 fix round 2 ----
import { firstMonthDue, legacyBalance, nightsBetween, nightsRefusal } from './pricing.ts';
Deno.test('R2-1 legacyBalance: due above 0 and below total is legacy under 28 nights; never at 28+; unknown nights read as short', () => {
  assertEquals(legacyBalance({ total: 3382, deposit: 1691, nights: 2 }), 1691);
  assertEquals(legacyBalance({ total: 3382, deposit: 3382, nights: 2 }), null);
  assertEquals(legacyBalance({ total: 3382, deposit: 0, nights: 2 }), null);
  assertEquals(legacyBalance({ total: 3382, deposit: null, nights: 2 }), null);
  assertEquals(legacyBalance({ total: 40050, deposit: 37380, nights: 30 }), null);
  assertEquals(legacyBalance({ total: 40050, deposit: 20025, nights: 27 }), 20025);
  assertEquals(legacyBalance({ total: 3382, deposit: 1691 }), 1691);
  assertEquals(nightsBetween('2026-12-10', '2026-12-12'), 2);
});
Deno.test('R2-3: a 30-night and a 45-night stay are accepted; the amount due is the first 28 nights, ceil(total x 28 / nights); the total is the whole stay', () => {
  const a30 = serverAmounts(SEED_CARD, '2027-01-10', '2027-02-09', {}, NOW), a45 = serverAmounts(SEED_CARD, '2027-01-10', '2027-02-24', {}, NOW), a28 = serverAmounts(SEED_CARD, '2027-01-10', '2027-02-07', {}, NOW);
  assertEquals([a30.total, a30.deposit], [40050, 37380]); // 30 x 1,335 = 40,050; ceil(40,050 x 28 / 30) = 37,380
  assertEquals([a45.total, a45.deposit], [60075, 37380]); // 45 x 1,335 = 60,075; ceil(60,075 x 28 / 45) = 37,380
  assertEquals([a28.total, a28.deposit], [37380, 37380]);
  assertEquals(firstMonthDue(100, 29), Math.ceil(100 * 28 / 29));
  assertEquals(nightsRefusal(30, 1, 30), null); assertEquals(nightsRefusal(31, 1, 30), null); assertEquals(nightsRefusal(45, 1, 30), null); assertEquals(nightsRefusal(120, 1, 30), null);
  assertEquals(nightsRefusal(0, 1, 30)?.error, 'below_minimum_nights');
  assertEquals(nightsRefusal(12, 1, 10)?.error, 'above_maximum_nights');
});

// ---- s138 L2b (R3-1, rule 8): legacy versus new long stay is decided by the stored amount, never by nights alone ----
import { isNewLongStay } from './pricing.ts';
Deno.test('R3-1 legacyBalance: a 29-night row at 50% is legacy; only a row whose amount due is exactly the first 28 nights is a new long stay', () => {
  assertEquals(legacyBalance({ total: 40000, deposit: 20000, nights: 29 }), 20000);
  assertEquals(legacyBalance({ total: 40050, deposit: Math.ceil(40050 * 28 / 30), nights: 30 }), null); // 37,380: new long stay
  assertEquals(isNewLongStay(40050, 37380, 30), true);
  assertEquals(legacyBalance({ total: 60075, deposit: 37380, nights: 45 }), null); // 45 nights, exact first-28 amount
  assertEquals(isNewLongStay(60075, 37380, 45), true);
  assertEquals(legacyBalance({ total: 60075, deposit: 30000, nights: 45 }), 30075); // 45 nights, any other part amount
  assertEquals(isNewLongStay(60075, 30000, 45), false);
  assertEquals(legacyBalance({ total: 37380, deposit: 37380, nights: 28 }), null); // 28 nights, full amount: not legacy
  assertEquals(legacyBalance({ total: 3382, deposit: 1691, nights: 2 }), 1691);
  assertEquals(legacyBalance({ total: 3382, deposit: 1691, nights: null }), 1691);
  assertEquals(legacyBalance({ total: 3382, deposit: 1691 }), 1691);
  assertEquals(legacyBalance({ total: 40000, deposit: 0, nights: 29 }), null);
  assertEquals(legacyBalance({ total: 40000, deposit: null, nights: 29 }), null);
  assertEquals(isNewLongStay(40000, 20000, 29), false);
  assertEquals(isNewLongStay(3382, 1691, null), false);
  assertEquals(isNewLongStay(40000, null, 29), false);
  assertEquals(isNewLongStay(3382, 3382, 2), false); // under 28 nights is never a long stay
});
