// notify-cleaner-payment: the request body, checked once at the door. The database re-validates every id, amount and path
// (staff_pay_request_create_v1); this only keeps a malformed or oversized body from reaching it.
export type PayRequestBody = { key: string; sessions: unknown[]; claim_ids: unknown[]; extras: unknown[] };

const CAP = 40; // the database refuses more than 20 lines; 40 leaves room to say too_many_lines instead of silently dropping

export function parseRequest(body: unknown): { ok: true; value: PayRequestBody } | { ok: false; reason: 'bad_request' } {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { ok: false, reason: 'bad_request' };
  const b = body as Record<string, unknown>;
  const key = typeof b.idempotency_key === 'string' ? b.idempotency_key : '';
  if (key.length < 8 || key.length > 80) return { ok: false, reason: 'bad_request' };
  const list = (x: unknown): unknown[] | null => (x === undefined || x === null ? [] : Array.isArray(x) && x.length <= CAP ? x : null);
  const sessions = list(b.sessions), claim_ids = list(b.claim_ids), extras = list(b.extras);
  if (!sessions || !claim_ids || !extras) return { ok: false, reason: 'bad_request' };
  return { ok: true, value: { key, sessions, claim_ids, extras } };
}
