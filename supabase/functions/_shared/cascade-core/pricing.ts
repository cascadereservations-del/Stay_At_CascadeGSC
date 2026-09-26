// SPEC-34 (D-259, D-261, D-262): the ONE quote function. The rate card is stored in the database
// (get_rate_card_v1: base + length-of-stay tiers + dated promotions) and every module quotes through quote():
// submit-booking (authoritative for the stored amounts), the rate-card endpoint the booking site calls, and the
// concierge. Pure except loadCard. A promo night is the promo price (it replaces the tier); every other night is the
// tier chosen by the STAY length. Deposit (the reservation fee) = ceil(total * deposit_pct / 100); full = total.

export type Promotion = { name: string; first_night: string; last_night: string; nightly_rate: number };
export type RateCard = {
  base: number;
  deposit_pct: number;
  tiers: { min_nights: number; pct: number }[];
  promotions: Promotion[];
  version_id?: string | null;
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

/** Today's card (2026-09-26) and the Anniversary Promotion: the migration's seed, and the fallback when the read fails. */
export const SEED_CARD: RateCard = {
  base: 1780,
  deposit_pct: 50,
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

export function quote(card: RateCard, checkin: string, checkout: string, now = new Date()): Quote {
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
    deposit: Math.ceil(total * card.deposit_pct / 100),
    last_minute: span(manilaToday(now), checkin) <= 4,
    promo_nights: nights.filter((x) => x.source === 'promo').length,
    promo_name: promo?.promo ?? null,
    promo_rate: promo?.rate ?? null,
  };
}

/** submit-booking's rule (D-262): the server's quote is what is stored; the client only chooses fee or full.
 *  Full when the client says pay_full, when check-in is 4 days or fewer away (the site's rule), or - for a client
 *  that predates pay_full - when its deposit is within 10% of its own total. A client total that differs is logged. */
export function serverAmounts(card: RateCard, checkin: string, checkout: string,
  client: { payFull?: unknown; total?: number; deposit?: number }, now = new Date()) {
  const q = quote(card, checkin, checkout, now);
  const ct = Number(client.total ?? 0), cd = Number(client.deposit ?? 0);
  const full = client.payFull === true || q.last_minute || (ct > 0 && cd > 0 && Math.abs(cd - ct) / ct <= 0.10);
  return { q, full, total: q.total, deposit: full ? q.total : q.deposit, mismatch: ct > 0 && ct !== q.total };
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
    console.error(JSON.stringify({ event: 'rate_card_fallback', error: String((e as Error)?.message ?? e) }));
    return (current = SEED_CARD);
  }
}
/** Tests only. */
export const _resetCardCache = () => { cached = null; current = SEED_CARD; };
