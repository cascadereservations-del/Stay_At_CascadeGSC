// SPEC-38 s8 (session 70): Cassy's "reply to this guest" draft seeds the probe thread with the booking flow the guest is in,
// so the concierge answers through its SPEC-31 s4 path (answer only what they asked; never say confirmed; no invite).
// The probe path only: the guest path never reads this. Pure; only the two steps after a request are accepted, field by
// field, and `booking_id` is always 'probe' (runProbe adds it), so a seed can never point at a real booking.
export function seedFlow(x: unknown): Record<string, unknown> | null {
  if (!x || typeof x !== 'object') return null;
  const f = x as Record<string, unknown>;
  if (f.step !== 'await_receipt' && f.step !== 'receipt_sent') return null;
  const out: Record<string, unknown> = { step: f.step };
  for (const k of ['checkin', 'checkout']) if (typeof f[k] === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(f[k] as string)) out[k] = f[k];
  for (const k of ['pax', 'deposit', 'total']) if (typeof f[k] === 'number' && Number.isFinite(f[k])) out[k] = f[k];
  if (typeof f.name === 'string') out.name = f.name.slice(0, 80);
  if (typeof f.ref === 'string') out.ref = f.ref.slice(0, 20);
  if (f.lang === 'en' || f.lang === 'tl' || f.lang === 'bis') out.lang = f.lang;
  if (typeof f.pay_full === 'boolean') out.pay_full = f.pay_full;
  if (typeof f.hold === 'boolean') out.hold = f.hold;
  if (typeof f.hold_expires_at === 'string' && !Number.isNaN(Date.parse(f.hold_expires_at))) out.hold_expires_at = f.hold_expires_at;
  return out;
}
