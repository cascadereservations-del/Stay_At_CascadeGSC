// SPEC-38 s6 (session 70): the one place a Telegram decision reaches the guest. Messenger first (the thread the request came from),
// e-mail through the relay otherwise, and "card only" when there is neither: the host then sends the text by hand from the card.
// Every attempt is written to the booking's lifecycle (telegram_inquiry_message_logged_v1), delivered or not. Messages are unsigned;
// the audit row records who tapped. All I/O is injected (SendIO) so the plan is tested without a network.
import { threadForBooking } from '../_shared/cascade-core/messenger.ts';
import { channelPlan, lastGuestAt, type InquiryView } from '../_shared/cascade-core/inquiry.ts';

export type Delivery = { channel: 'messenger' | 'email' | 'card_only'; delivered: boolean; detail: string };
export type Thread = { psid: string; guest_name: string | null; booking_flow: any; history: any[] };
export type SendIO = {
  // deno-lint-ignore no-explicit-any
  db: any;
  thread: (bookingId: string) => Promise<Thread | null>;
  fbSend: (psid: string, text: string, humanAgent: boolean) => Promise<boolean>;
  /** true only when the relay answered result === 'success' */
  relay: (m: { ref: string; guest_name: string; guest_email: string; subject: string; message: string }) => Promise<boolean>;
  /** a fresh receipt upload token for a hold that now ends later than the one issued at submit time; null when there is no secret */
  token: (bookingId: string, expiresAtMs: number) => Promise<string | null>;
  now: () => number;
};

export type Purpose = 'hold' | 'decline' | 'reply';

/** The default I/O: the real Messenger Page send, the e-mail relay and the receipt-token signer. */
// deno-lint-ignore no-explicit-any
export function liveSendIO(db: any, fbSend: SendIO['fbSend'], env: (k: string) => string, issue: (c: { bookingId: string; nonce: string; expiresAt: number }, secret: string) => Promise<string>): SendIO {
  return {
    db, fbSend,
    thread: (id) => threadForBooking(db, id),
    relay: async (m) => {
      const url = env('EMAIL_RELAY_URL'), token = env('EMAIL_RELAY_TOKEN');
      if (!url || !token) return false;
      const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(30_000),
        body: JSON.stringify({ action: 'guestMessage', token, ref: m.ref, guest_name: m.guest_name, guest_email: m.guest_email, subject: m.subject, message: m.message }) }).catch((e) => { console.error('inquiry_relay', String(e).slice(0, 120)); return null; });
      const j = r ? await r.json().catch(() => null) : null;
      return !!r?.ok && j?.result === 'success';
    },
    token: async (bookingId, expiresAt) => { const s = env('BOOKING_RECEIPT_UPLOAD_SECRET'); return s ? await issue({ bookingId, nonce: crypto.randomUUID(), expiresAt }, s) : null; },
    now: () => Date.now(),
  };
}

export const SUBJECT = (ref: string) => `Your Cascade Hideaway request ${ref}`;

/** What a Messenger thread's booking_flow becomes after the message: a hold moves its expiry and token, a decline ends the flow. */
export async function patchFlow(io: SendIO, t: Thread, purpose: Purpose, holdExpiresAt: string | null, bookingId: string): Promise<void> {
  if (purpose === 'reply') return;
  const at = new Date(io.now()).toISOString(), f = t.booking_flow ?? {};
  let next: Record<string, unknown> | null = null;
  if (purpose === 'decline') next = { ...f, step: 'cancelled', updated_at: at };
  else if (holdExpiresAt) {
    const token = await io.token(bookingId, Date.parse(holdExpiresAt));
    next = { ...f, hold: true, hold_expires_at: holdExpiresAt, ...(token ? { receipt_token: token, receipt_expires_at: new Date(holdExpiresAt).toISOString() } : {}), updated_at: at };
  }
  if (next) await io.db.from('concierge_threads').update({ booking_flow: next, updated_at: at }).eq('psid', t.psid);
}

/** Send `text` to the guest on the best channel. Never throws: a failure is a Delivery with delivered:false. */
export async function deliverToGuest(io: SendIO, view: InquiryView, text: string, o: { purpose: Purpose; holdExpiresAt?: string | null }): Promise<Delivery> {
  const t = await io.thread(view.id).catch(() => null);
  const plan = channelPlan({ hasThread: !!t, lastGuestAt: lastGuestAt(t?.history), hasEmail: !!view.guest_email, now: io.now() });
  let out: Delivery = { channel: plan.channel, delivered: false, detail: plan.channel === 'card_only' ? 'no channel' : '' };
  if (plan.channel === 'messenger' && t) {
    const ok = await io.fbSend(t.psid, text, plan.humanAgent).catch(() => false);
    if (ok) {
      const at = new Date(io.now()).toISOString();
      // The sendHostReply precedent: Cassy reads this thread next, so she must know what was said.
      try { await io.db.from('concierge_threads').update({ history: [...(t.history ?? []), { role: 'bot', text, at }].slice(-40), updated_at: at }).eq('psid', t.psid); } catch (e) { console.error('inquiry_history', String(e).slice(0, 120)); } // supabase-js builders have no .catch
      out = { channel: 'messenger', delivered: true, detail: plan.humanAgent ? 'human agent tag' : 'response' };
    } else if (view.guest_email) {
      out = { channel: 'email', delivered: false, detail: '' }; // Messenger refused: the e-mail below is the fallback (the guest-messages rule)
    } else out = { channel: 'messenger', delivered: false, detail: 'Messenger refused and there is no e-mail' };
  }
  if (out.channel === 'email' && !out.delivered && view.guest_email) {
    const ok = await io.relay({ ref: view.ref, guest_name: view.guest_name, guest_email: view.guest_email, subject: SUBJECT(view.ref), message: text }).catch(() => false);
    out = { channel: 'email', delivered: ok, detail: ok ? 'relay success' : 'e-mail relay did not accept it' };
  }
  // The flow follows the booking whatever happened to the message: a held request must accept a receipt on the new expiry.
  if (t) await patchFlow(io, t, o.purpose, o.holdExpiresAt ?? null, view.id).catch((e) => console.error('inquiry_patch_flow', String(e).slice(0, 120)));
  return out;
}

/** The audit row, always: delivered or not, and who tapped. Returns false when the RPC itself failed (logged). */
export async function logMessage(io: SendIO, view: InquiryView, d: Delivery, o: { purpose: Purpose; text: string; tgUserId: unknown; actorName: string; key: string }): Promise<boolean> {
  const { data, error } = await io.db.rpc('telegram_inquiry_message_logged_v1', {
    p_booking_id: view.id, p_telegram_user_id: o.tgUserId ?? null, p_actor_name: o.actorName, p_purpose: o.purpose, p_channel: d.channel,
    p_delivered: d.delivered, p_text: o.text, p_idempotency_key: o.key,
  });
  if (error || data?.ok === false) { console.error('inquiry_log_failed', JSON.stringify({ purpose: o.purpose, error: String(error?.message ?? data?.reason ?? '').slice(0, 160) })); return false; }
  return true;
}

/** deliverToGuest, then logMessage. The one call a tap handler makes. */
export async function sendAndLog(io: SendIO, view: InquiryView, text: string, o: { purpose: Purpose; holdExpiresAt?: string | null; tgUserId: unknown; actorName: string; key: string }): Promise<Delivery> {
  const d = await deliverToGuest(io, view, text, o);
  await logMessage(io, view, d, { purpose: o.purpose, text, tgUserId: o.tgUserId, actorName: o.actorName, key: o.key });
  return d;
}
