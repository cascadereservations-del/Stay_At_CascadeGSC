// SPEC-34 (D-259, D-261, D-262): the ONE quote function. The rate card is stored in the database
// (get_rate_card_v1: base + length-of-stay tiers + dated promotions) and every module quotes through quote():
// submit-booking (authoritative for the stored amounts), the rate-card endpoint the booking site calls, and the
// concierge. Pure except loadCard. A promo night is the promo price (it replaces the tier); every other night is the
// tier chosen by the STAY length. s138 (D-428..D-430): every direct stay is paid in FULL to confirm, so the amount due
// to confirm (`deposit`, a name kept for the stored column and the live site) is always the stay total, in code, whatever
// the card's deposit_pct says. A separate refundable security deposit (SECURITY_DEPOSIT_PHP) is never part of the quote.

export type Promotion = { name: string; first_night: string; last_night: string; nightly_rate: number };
export type CardVersion = { effective_from: string; base: number; deposit_pct: number; tiers: { min_nights: number; pct: number }[]; version_id?: string | null };
export type RateCard = {
  base: number;
  deposit_pct: number;
  tiers: { min_nights: number; pct: number }[];
  promotions: Promotion[];
  version_id?: string | null;
  /** Versions published to start after today (release rate_card_upcoming_20260926). A stay is priced by the version in
   *  force on its CHECK-IN date; absent = none scheduled. */
  upcoming?: CardVersion[];
};
export type QuoteNight = { date: string; rate: number; source: 'promo' | 'tier'; promo?: string };
export type Quote = {
  nights: QuoteNight[];
  n: number;
  total: number;
  standard_total: number;
  tier_pct: number;
  tier_rate: number;
  deposit: number;
  last_minute: boolean;
  promo_nights: number;
  promo_name: string | null;
  promo_rate: number | null;
};

/** s138 (D-430): the refundable security deposit, paid with the booking or by the day before check-in. The ONE place
 *  for the amount and the refund window; every other file imports them. */
export const SECURITY_DEPOSIT_PHP = 800;
export const DEPOSIT_RETURN_BUSINESS_DAYS = 3;
/** s138 (D-429): a stay of this many nights or more is arranged by the host (first month to confirm, then monthly) and
 *  is never auto-quoted or auto-booked. */
export const LONG_STAY_NIGHTS = 28;
export const isLongStay = (nights: number) => nights >= LONG_STAY_NIGHTS;

/** s138 round 2 (R2-3): the amount due to confirm a long stay = the first 28 nights, ceil(total x 28 / nights). Shorter stays: the total. */
export const firstMonthDue = (total: number, nights: number) => isLongStay(nights) && nights > LONG_STAY_NIGHTS ? Math.ceil(total * LONG_STAY_NIGHTS / nights) : total;

/** s138 L2b (R3-1, rule 8): is a STORED row a new long stay? Only when nights >= 28 AND the amount due is exactly the first 28
 *  nights, ceil(total x 28 / nights). The stored amount decides, never the nights alone: the deployed code allowed 50% bookings of
 *  28 to 30 nights, and those are legacy. Unknown nights or amounts are never a long stay. The ONE predicate for every surface
 *  that renders an existing row. (A new request being quoted or submitted has no stored amount: it uses isLongStay.) */
export function isNewLongStay(total: unknown, deposit: unknown, nights: unknown): boolean {
  const t = Number(total), d = Number(deposit), n = Number(nights);
  if (total == null || deposit == null || nights == null || !Number.isFinite(t) || !Number.isFinite(d) || !Number.isFinite(n)) return false;
  return isLongStay(n) && t > 0 && d === firstMonthDue(t, n);
}

/** s138 round 2 (rule 8, R2-1): a booking made under the old rule has an amount due above 0 and below its total. Returns the
 *  balance (total minus amount due) then, else null. A row is NOT legacy only when it is a new long stay (isNewLongStay: 28+ nights
 *  and the amount due is exactly the first 28 nights); every other part payment is legacy whatever its length (R3-1). Unknown
 *  nights are read as a short stay. The ONE helper every surface that renders an existing booking uses (guest messages 1 and 2,
 *  host cards, Messenger replies, Telegram drafts). */
export function legacyBalance(b: { total: unknown; deposit: unknown; nights?: unknown }): number | null {
  const total = Number(b.total), due = Number(b.deposit);
  if (!(due > 0) || !(total > due)) return null;
  if (isNewLongStay(total, due, b.nights)) return null;
  return total - due;
}
/** Whole nights between two yyyy-mm-dd dates (NaN when either is not a date). */
export const nightsBetween = (checkin: unknown, checkout: unknown) =>
  Math.round((Date.parse(String(checkout).slice(0, 10) + 'T00:00:00Z') - Date.parse(String(checkin).slice(0, 10) + 'T00:00:00Z')) / 86_400_000);

/** submit-booking's night-count gate. A stay of 28+ nights is never refused (a guest may already have paid; the host card carries the
 *  long-stay line). Only a stay below the minimum, or above the maximum yet under 28 nights, is refused. null = accept. */
export function nightsRefusal(nights: number, minNights: number, maxNights: number): { error: string; min_nights?: number; max_nights?: number } | null {
  if (nights < minNights) return { error: 'below_minimum_nights', min_nights: minNights };
  if (nights > maxNights && !isLongStay(nights)) return { error: 'above_maximum_nights', max_nights: maxNights };
  return null;
}

/** Today's card (2026-09-26) and the Anniversary Promotion: the migration's seed, and the fallback when the read fails. */
export const SEED_CARD: RateCard = {
  base: 1780,
  deposit_pct: 100,
  tiers: [{ min_nights: 2, pct: 5 }, { min_nights: 5, pct: 10 }, { min_nights: 7, pct: 15 }, { min_nights: 14, pct: 20 }, { min_nights: 28, pct: 25 }],
  promotions: [{ name: 'Anniversary Promotion', first_night: '2026-10-11', last_night: '2026-10-17', nightly_rate: 1543 }],
  version_id: null,
};

const DAY = 86_400_000;
const addDays = (d: string, k: number) => new Date(Date.parse(d + 'T00:00:00Z') + k * DAY).toISOString().slice(0, 10);
const span = (a: string, b: string) => Math.round((Date.parse(b + 'T00:00:00Z') - Date.parse(a + 'T00:00:00Z')) / DAY);
export const manilaToday = (now = new Date()) => now.toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });

export function tierPct(card: RateCard, n: number): number {
  let pct = 0;
  for (const t of [...card.tiers].sort((a, b) => a.min_nights - b.min_nights)) if (n >= t.min_nights) pct = t.pct;
  return pct;
}
export const tierRate = (card: RateCard, n: number) => Math.round(card.base * (1 - tierPct(card, n) / 100));
export const promoOn = (card: RateCard, date: string) => card.promotions.find((p) => p.first_night <= date && date <= p.last_night) ?? null;

/** The card that prices a stay checking in on `checkin`: the latest upcoming version started by then, else today's.
 *  ponytail: a stay that straddles a version change is priced wholly by its check-in date's version. */
export function cardOn(card: RateCard, checkin: string): RateCard {
  const v = (card.upcoming ?? []).filter((u) => u.effective_from <= checkin).sort((a, b) => (a.effective_from < b.effective_from ? 1 : -1))[0];
  return v ? { ...card, base: v.base, deposit_pct: v.deposit_pct, tiers: v.tiers, version_id: v.version_id ?? null } : card;
}

export function quote(cardToday: RateCard, checkin: string, checkout: string, now = new Date()): Quote {
  const card = cardOn(cardToday, checkin);
  const n = Math.max(1, span(checkin, checkout));
  const pct = tierPct(card, n), rate = tierRate(card, n);
  const nights: QuoteNight[] = [];
  for (let i = 0; i < n; i++) {
    const date = addDays(checkin, i), p = promoOn(card, date);
    nights.push(p ? { date, rate: Number(p.nightly_rate), source: 'promo', promo: p.name } : { date, rate, source: 'tier' });
  }
  const total = nights.reduce((a, x) => a + x.rate, 0);
  const promo = nights.find((x) => x.source === 'promo');
  return {
    nights, n, total, standard_total: card.base * n, tier_pct: pct, tier_rate: rate,
    deposit: total, // s138: paid in full to confirm; independent of card.deposit_pct (see the header)
    last_minute: false, // s138: kept for the live site's reader; there is no last-minute rule any more
    promo_nights: nights.filter((x) => x.source === 'promo').length,
    promo_name: promo?.promo ?? null,
    promo_rate: promo?.rate ?? null,
  };
}

/** submit-booking's rule (D-262, s138): the server's quote is what is stored. The amount due to confirm is always the
 *  stay total. A client `pay_full` flag, `total` or `deposit` is accepted and harmless; a client total that differs is
 *  logged. `full` stays in the return so callers and the response shape do not change. */
export function serverAmounts(card: RateCard, checkin: string, checkout: string,
  client: { payFull?: unknown; total?: number; deposit?: number }, now = new Date()) {
  const q = quote(card, checkin, checkout, now);
  const ct = Number(client.total ?? 0);
  // R2-3: 28+ nights store the first 28 nights as the amount due (total stays the whole stay); everything else is paid in full.
  return { q, full: true, total: q.total, deposit: firstMonthDue(q.total, q.n), mismatch: ct > 0 && ct !== q.total };
}

/** A promotion that is running or still to come (last night today or later), for prose and banners. */
export const livePromos = (card: RateCard, now = new Date()) => card.promotions.filter((p) => p.last_night >= manilaToday(now));

function valid(c: unknown): c is RateCard {
  const x = c as RateCard | null;
  return !!x && Number(x.base) > 0 && Number(x.deposit_pct) > 0 && Number(x.deposit_pct) <= 100 && Array.isArray(x.tiers) && Array.isArray(x.promotions);
}
export function normalizeCard(c: RateCard): RateCard {
  return {
    base: Number(c.base), deposit_pct: Number(c.deposit_pct), version_id: c.version_id ?? null,
    tiers: c.tiers.map((t) => ({ min_nights: Number(t.min_nights), pct: Number(t.pct) })),
    promotions: c.promotions.map((p) => ({ name: String(p.name), first_night: String(p.first_night), last_night: String(p.last_night), nightly_rate: Number(p.nightly_rate) })),
    upcoming: (Array.isArray(c.upcoming) ? c.upcoming : []).filter((u) => Number(u.base) > 0 && Array.isArray(u.tiers)).map((u) => ({
      effective_from: String(u.effective_from), base: Number(u.base), deposit_pct: Number(u.deposit_pct) > 0 ? Number(u.deposit_pct) : 100,
      tiers: u.tiers.map((t) => ({ min_nights: Number(t.min_nights), pct: Number(t.pct) })), version_id: u.version_id ?? null })),
  };
}

// ponytail: 60 s per-instance cache, so a promo published in the last minute may quote the old price once.
let cached: { card: RateCard; at: number } | null = null;
let current: RateCard = SEED_CARD;
/** The card loaded last on this instance (the seed until loadCard runs). Code that has no db handle reads this. */
export const currentCard = () => current;

type Rpc = { rpc: (fn: string, args?: Record<string, unknown>) => PromiseLike<{ data: unknown; error: { message: string } | null }> };
/** Reads get_rate_card_v1. On any failure: the seed card and a `rate_card_fallback` log line - never zero, never silent. */
export async function loadCard(db: Rpc, nowMs = Date.now()): Promise<RateCard> {
  if (cached && nowMs - cached.at < 60_000) return (current = cached.card);
  try {
    const { data, error } = await db.rpc('get_rate_card_v1');
    if (error || !valid(data)) throw new Error(error?.message ?? 'invalid card');
    cached = { card: normalizeCard(data), at: nowMs };
    return (current = cached.card);
  } catch (e) {
    // Review 2026-09-26: `current` is shared by every request on this instance, so a failed read keeps the last card
    // read successfully (the one other in-flight turns already quoted from) and only falls to the seed without one.
    console.error(JSON.stringify({ event: 'rate_card_fallback', error: String((e as Error)?.message ?? e), kept: cached ? 'last_good' : 'seed' }));
    return (current = cached?.card ?? SEED_CARD);
  }
}
/** Tests only. */
export const _resetCardCache = () => { cached = null; current = SEED_CARD; };
