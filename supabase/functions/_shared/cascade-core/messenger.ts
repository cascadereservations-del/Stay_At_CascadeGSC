// cascade-core messenger (session 27, booking PRD §A/§D): the Page send used outside
// messenger-concierge — an image (the GCash QR) from the book flow and the guest's booking
// confirmation from whoever confirms (telegram-expense tap today). Edge secrets are project-wide,
// so META_PAGE_TOKEN is readable from any function.
const GRAPH = 'https://graph.facebook.com/v21.0';
const PAGE_ID = '699640026568720'; // Cascades Hideaway
const env = (k: string) => Deno.env.get(k) ?? '';

async function post(payload: unknown): Promise<boolean> {
  const token = env('META_PAGE_TOKEN');
  if (!token) return false;
  const r = await fetch(`${GRAPH}/${PAGE_ID}/messages?access_token=${token}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload), signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  if (r && !r.ok) console.error('fb_send_failed', r.status, (await r.text().catch(() => '')).slice(0, 200));
  return !!r?.ok;
}

// HUMAN_AGENT tag: delivers up to 7 days after the guest's last message (a confirmation often
// comes hours after the receipt); plain RESPONSE only works inside 24 h.
export function fbSendText(psid: string, text: string, humanAgent = false): Promise<boolean> {
  const envelope = humanAgent ? { messaging_type: 'MESSAGE_TAG', tag: 'HUMAN_AGENT' } : { messaging_type: 'RESPONSE' };
  return post({ recipient: { id: psid }, ...envelope, message: { text } });
}
/** Upload image bytes straight to the Send API (multipart `filedata`), so a generated QR needs no storage or URL. */
export async function fbSendImageBytes(psid: string, bytes: Uint8Array, filename = 'image.png', mime = 'image/png'): Promise<boolean> {
  const token = env('META_PAGE_TOKEN'); if (!token) return false;
  const form = new FormData();
  form.append('recipient', JSON.stringify({ id: psid }));
  form.append('messaging_type', 'RESPONSE');
  form.append('message', JSON.stringify({ attachment: { type: 'image', payload: { is_reusable: false } } }));
  form.append('filedata', new Blob([bytes as unknown as BlobPart], { type: mime }), filename);
  const r = await fetch(`${GRAPH}/${PAGE_ID}/messages?access_token=${token}`, { method: 'POST', body: form, signal: AbortSignal.timeout(20_000) }).catch(() => null);
  if (r && !r.ok) console.error('fb_send_bytes_failed', r.status, (await r.text().catch(() => '')).slice(0, 200));
  return !!r?.ok;
}
export function fbSendImage(psid: string, url: string): Promise<boolean> {
  return post({ recipient: { id: psid }, messaging_type: 'RESPONSE', message: { attachment: { type: 'image', payload: { url, is_reusable: true } } } });
}

const dm = (d: string) => { const x = new Date(String(d).slice(0, 10) + 'T00:00:00Z'); return `${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][x.getUTCMonth()]} ${x.getUTCDate()}`; };

/** Tell the guest on Messenger that their direct booking is confirmed; no-op when the booking did not come through a Messenger thread. */
// deno-lint-ignore no-explicit-any
export async function notifyMessengerBookingConfirmed(db: any, bookingId: string): Promise<boolean> {
  const { data: t } = await db.from('concierge_threads').select('psid, guest_name, booking_flow').eq('booking_flow->>booking_id', bookingId).maybeSingle();
  if (!t?.psid) return false;
  const { data: b } = await db.from('booking_inquiries').select('checkin_date, checkout_date, id').eq('id', bookingId).maybeSingle();
  const ref = bookingId.slice(0, 8).toUpperCase();
  const first = t.guest_name ? String(t.guest_name).split(' ')[0] : 'there';
  const text = b
    ? `Confirmed po, ${first}! 🎉 Your stay ${dm(b.checkin_date)} → ${dm(b.checkout_date)} at Cascade Hideaway is booked (ref ${ref}). We'll send the address and check-in details here closer to your date. Salamat, and see you soon!`
    : `Confirmed po, ${first}! 🎉 Your booking (ref ${ref}) at Cascade Hideaway is set. We'll send the check-in details here closer to your date.`;
  const ok = await fbSendText(t.psid, text, true);
  if (ok) await db.from('concierge_threads').update({ booking_flow: { ...(t.booking_flow ?? {}), step: 'confirmed', updated_at: new Date().toISOString() }, updated_at: new Date().toISOString() }).eq('psid', t.psid);
  return ok;
}
