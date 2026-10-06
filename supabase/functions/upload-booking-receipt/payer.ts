// deno test supabase/functions/upload-booking-receipt/payer.test.ts - SPEC-42 9a: the account a receipt was paid FROM is kept,
// so a later /refund can be checked against it (invariant I3: a refund goes only to the account that paid).

type Read = { sender_name: string | null; channel: string | null; amount: number | null; confidence: number } | null;

export function payerOf(read: Read): { name: string; channel: string | null } | null {
  const name = String(read?.sender_name ?? '').replace(/\s+/g, ' ').trim().slice(0, 80);
  if (!name) return null;
  const channel = String(read?.channel ?? '').replace(/\s+/g, ' ').trim().slice(0, 40);
  return { name, channel: channel || null };
}

// Only a proof-grade read (an amount found, confidence >= 0.5) is kept: the first write is permanent, so a screen-before-sending or a
// low-confidence guess must not claim the slot.
// First receipt wins: `.is('paid_from_name', null)` makes a second write a no-op. Never throws: this is a note beside the receipt,
// and the receipt itself (the Finance card) must never be lost to it.
// deno-lint-ignore no-explicit-any
export async function storePayer(db: any, bookingId: string, read: Read): Promise<boolean> {
  const payer = read && read.amount !== null && read.confidence >= 0.5 ? payerOf(read) : null;
  if (!payer) return false;
  try {
    const { error } = await db.from('booking_inquiries')
      .update({ paid_from_name: payer.name, paid_from_channel: payer.channel })
      .eq('id', bookingId).is('paid_from_name', null);
    if (error) { console.error('[upload-booking-receipt] payer not stored:', String(error.message ?? error).slice(0, 120)); return false; }
    return true;
  } catch (e) { console.error('[upload-booking-receipt] payer not stored:', String(e).slice(0, 120)); return false; }
}
