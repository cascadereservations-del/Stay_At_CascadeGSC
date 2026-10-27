// notify-cleaner-payment: the request body, checked once at the door. The database re-validates every id, amount and path
// (staff_pay_request_create_v2); this only keeps a malformed or oversized body from reaching it.
export type PayRequestBody = { key: string; sessions: unknown[]; claim_ids: unknown[]; extras: unknown[]; advance: Array<{ checkout_date: string; transport: boolean | null }> };

const ADVANCE_CAP = 20; // s99: the database caps all lines at 20, so more advance dates than that can never be valid
const CAP = 40; // the database refuses more than 20 lines; 40 leaves room to say too_many_lines instead of silently dropping

/** s99 (D-348): paid-ahead turnovers, strict: [{checkout_date:'YYYY-MM-DD', transport:boolean|null}], unique dates, at most 20. Anything else is bad_request. */
function parseAdvance(x: unknown): PayRequestBody['advance'] | null {
  if (x === undefined || x === null) return [];
  if (!Array.isArray(x) || x.length > ADVANCE_CAP) return null;
  const seen = new Set<string>(), out: PayRequestBody['advance'] = [];
  for (const a of x) {
    if (!a || typeof a !== 'object' || Array.isArray(a)) return null;
    const { checkout_date: d, transport: t } = a as Record<string, unknown>;
    if (typeof d !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(d) || new Date(d + 'T00:00:00Z').toISOString().slice(0, 10) !== d || seen.has(d)) return null;
    if (t !== undefined && t !== null && typeof t !== 'boolean') return null;
    seen.add(d); out.push({ checkout_date: d, transport: t ?? null });
  }
  return out;
}

export function parseRequest(body: unknown): { ok: true; value: PayRequestBody } | { ok: false; reason: 'bad_request' } {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { ok: false, reason: 'bad_request' };
  const b = body as Record<string, unknown>;
  const key = typeof b.idempotency_key === 'string' ? b.idempotency_key : '';
  if (key.length < 8 || key.length > 80) return { ok: false, reason: 'bad_request' };
  const list = (x: unknown): unknown[] | null => (x === undefined || x === null ? [] : Array.isArray(x) && x.length <= CAP ? x : null);
  const sessions = list(b.sessions), claim_ids = list(b.claim_ids), extras = list(b.extras);
  const advance = parseAdvance(b.advance);
  if (!sessions || !claim_ids || !extras || !advance) return { ok: false, reason: 'bad_request' };
  return { ok: true, value: { key, sessions, claim_ids, extras, advance } };
}
