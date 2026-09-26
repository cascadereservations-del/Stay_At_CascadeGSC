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

/** The Messenger thread a direct booking came from (SPEC-33 s2), or null when it came from the site. */
// deno-lint-ignore no-explicit-any
export async function threadForBooking(db: any, bookingId: string): Promise<{ psid: string; guest_name: string | null; booking_flow: any; history: any[] } | null> {
  const { data: t } = await db.from('concierge_threads').select('psid, guest_name, booking_flow, history').eq('booking_flow->>booking_id', bookingId).maybeSingle();
  return t?.psid ? t : null;
}

/** SPEC-33 s2: a declined receipt reaches the guest (English; one "po" for a Taglish flow, D-258) and the flow waits at
 *  `receipt_declined`, where a "paid na po?" gets the await_receipt line. HUMAN_AGENT: a person just tapped Decline. */
export function declineLine(name: string | null, ref: string, lang: string | undefined): string {
  const n = String(name ?? '').trim().split(/\s+/)[0], c = n ? `${n}, ` : '';
  // D-258: English in every register; Taglish keeps one courtesy "po".
  return `${c}our host reviewed the payment for ${ref} and could not match it to the amount. Nothing is confirmed yet${lang === 'tl' ? ' po' : ''}; they'll message you here to sort it out.`;
}
// deno-lint-ignore no-explicit-any
export async function notifyMessengerBookingDeclined(db: any, bookingId: string): Promise<boolean> {
  const t = await threadForBooking(db, bookingId);
  if (!t) return false;
  const f = t.booking_flow ?? {};
  const ok = await fbSendText(t.psid, declineLine(f.name ?? t.guest_name, f.ref ?? 'DIR-' + bookingId.slice(0, 8).toUpperCase(), f.lang), true);
  if (ok) await db.from('concierge_threads').update({ booking_flow: { ...f, step: 'receipt_declined', updated_at: new Date().toISOString() }, updated_at: new Date().toISOString() }).eq('psid', t.psid);
  return ok;
}
// Session 56: notifyMessengerBookingConfirmed deleted (unused since session 54; guest-messages sends message 1).
