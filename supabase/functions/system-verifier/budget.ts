// V13 model budget (D-227). Raised here, not in SQL: it needs one GET to OpenRouter, and
// run_system_verifier_v1 is `stable` and cannot call out. apply_verifier_run_v1 carries V13 in both scope
// arrays, so a V13 this function stops raising resolves itself.
//
// Replaces finance-watch's check, which ran at 00:30Z (thirty minutes after the daily limit resets) and
// divided the key's LIFETIME usage by its limit. limit_remaining is the current period's remainder.
import type { Finding } from './cards.ts';

export type KeyRead = { status: number; limit: number | null; remaining: number | null };

/** A red V13 when the key is refused or under 20% of its limit is left; otherwise null.
 *  The percentage is rounded down to 5% steps so an acknowledgement holds between runs (D-217.2).
 *  ponytail: an OpenRouter outage (5xx) reads as "nothing to say", which also resolves an open V13;
 *  if that ever flaps, carry the previous finding forward instead. */
export function budgetFinding(k: KeyRead): Finding | null {
  if (k.status === 401 || k.status === 403) {
    return { key: 'V13', check_id: 'V13', severity: 'red', title: 'Model key refused', detail: { refused: true, status: k.status } };
  }
  if (k.status !== 200 || !k.limit || k.limit <= 0 || k.remaining == null) return null;
  const left = k.remaining / k.limit;
  if (left >= 0.2) return null;
  return {
    key: 'V13', check_id: 'V13', severity: 'red', title: 'Model budget nearly used up',
    detail: { left_pct: Math.max(0, Math.floor(left * 20) * 5), limit: k.limit },
  };
}

/** GET /api/v1/key. Never throws: a failed read is status 0. */
export async function readKey(apiKey: string): Promise<KeyRead> {
  const r = await fetch('https://openrouter.ai/api/v1/key', {
    headers: { Authorization: `Bearer ${apiKey}` }, signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  const j = r?.ok ? await r.json().catch(() => null) : null;
  const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
  return { status: r?.status ?? 0, limit: num(j?.data?.limit), remaining: num(j?.data?.limit_remaining) };
}
