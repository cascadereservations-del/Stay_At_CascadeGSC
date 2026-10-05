// host-reply (SPEC-42 section 7): the Conversations panel's Send button. One owner or admin, one explicit tap, one Messenger reply.
// It does exactly what messenger-concierge's sendHostReply does (sign-off, HUMAN_AGENT send, handoff -> sent, history turn, a refused
// send marks nothing) but is a separate function: SPEC-39 owns messenger-concierge this session. All I/O comes in through Deps so the
// authorisation, the explicit-action rule, the reply window and the refused-send rule are tested without a network.
import { bearerToken, StaffAuthError } from '../_shared/staff-auth.ts';

export const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
/** Meta's HUMAN_AGENT tag delivers up to 7 days after the guest's last message; the dashboard shows the same countdown. */
export const WINDOW_MS = 7 * 24 * 3_600_000;
export const MAX_TEXT = 1900; // Messenger allows 2000 characters; the sign-off takes the rest
export const HISTORY_CAP = 32; // messenger-concierge keeps HISTORY_KEEP * 2 = 32 entries
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type Turn = { role: 'guest' | 'bot'; text: string; at: string; route?: Record<string, unknown> };
export type Staff = { name: string };
export type Handoff = { id: string; psid: string; status: string };
export type Recorded = { thread: boolean; handoff: boolean };

export interface Deps {
  /** The caller's session -> an active owner/admin, or the HTTP status to refuse with. */
  authenticate(token: string): Promise<{ ok: true; staff: Staff } | { ok: false; status: number; error: string }>;
  loadThread(psid: string): Promise<{ psid: string; history: Turn[] } | null>;
  loadHandoff(id: string): Promise<Handoff | null>;
  /** The Messenger Send API with the HUMAN_AGENT tag. false = Meta did not accept it. */
  send(psid: string, text: string): Promise<boolean>;
  /** After an accepted send: append the host turn, mark the handoff sent. */
  record(a: { psid: string; final: string; name: string; handoffId: string | null; nowIso: string }): Promise<Recorded>;
  now(): Date;
}

export function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

/** The latest guest turn decides whether the HUMAN_AGENT window is open. A turn with an unreadable time does not count. */
export function replyWindow(history: Turn[], now: Date): { open: boolean; lastGuestAt: string | null; closesAt: string | null } {
  let last = 0;
  for (const t of history ?? []) {
    if (t?.role !== 'guest') continue;
    const ms = Date.parse(t.at);
    if (Number.isFinite(ms) && ms > last) last = ms;
  }
  if (!last) return { open: false, lastGuestAt: null, closesAt: null };
  return { open: now.getTime() - last < WINDOW_MS, lastGuestAt: new Date(last).toISOString(), closesAt: new Date(last + WINDOW_MS).toISOString() };
}

/** The first name of the signed-in staff member, as the host card signs ("— Lloyd, Cascade Hideaway"). */
export function signOffName(displayName: string | null | undefined): string {
  const first = String(displayName ?? '').trim().split(/\s+/)[0];
  return first || 'Cascade host';
}
export const withSignOff = (text: string, name: string): string => `${text.trim()}\n\n— ${name}, Cascade Hideaway`;

export function appendHostTurn(history: Turn[], final: string, nowIso: string): Turn[] {
  return [...(Array.isArray(history) ? history : []), { role: 'bot' as const, text: final, at: nowIso }].slice(-HISTORY_CAP);
}

export async function handleHostReply(req: Request, deps: Deps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'method_not_allowed' }, 405);

  let token: string;
  try { token = bearerToken(req); } catch (e) {
    if (e instanceof StaffAuthError) return json({ ok: false, error: e.code }, e.status);
    throw e;
  }
  const who = await deps.authenticate(token);
  if (!who.ok) return json({ ok: false, error: who.error }, who.status);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'invalid_json' }, 400); }
  if (!body || typeof body !== 'object') return json({ ok: false, error: 'invalid_json' }, 400);
  // Nothing reaches a guest unless the page said so in words. A missing or different action is refused before any lookup or send.
  if (body.action !== 'send') return json({ ok: false, error: 'explicit_send_required' }, 400);

  const psid = typeof body.psid === 'string' ? body.psid.trim() : '';
  if (!psid || psid.length > 64) return json({ ok: false, error: 'invalid_psid' }, 400);
  const text = typeof body.text === 'string' ? body.text.trim() : '';
  if (!text) return json({ ok: false, error: 'invalid_text' }, 400);
  if (text.length > MAX_TEXT) return json({ ok: false, error: 'text_too_long' }, 400);
  const handoffId = body.handoff_id == null || body.handoff_id === '' ? null : String(body.handoff_id);
  if (handoffId !== null && !UUID_RE.test(handoffId)) return json({ ok: false, error: 'invalid_handoff_id' }, 400);

  const thread = await deps.loadThread(psid);
  if (!thread) return json({ ok: false, error: 'thread_not_found' }, 404);
  const now = deps.now();
  const win = replyWindow(thread.history, now);
  if (!win.open) return json({ ok: false, error: 'reply_window_closed', last_guest_at: win.lastGuestAt }, 409);

  if (handoffId) {
    const h = await deps.loadHandoff(handoffId);
    if (!h || h.psid !== psid) return json({ ok: false, error: 'handoff_not_found' }, 404);
    // Someone already answered it (a Telegram tap, or another admin): the same "already handled" the card gives. Nothing is sent.
    if (h.status !== 'open') return json({ ok: false, error: 'handoff_not_open' }, 409);
  }

  const final = withSignOff(text, who.staff.name);
  // SPEC-17 (D-212): a send Messenger did not accept marks nothing, so the handoff stays open and the host can tap again.
  if (!(await deps.send(psid, final))) return json({ ok: false, error: 'messenger_refused' }, 502);

  const recorded = await deps.record({ psid, final, name: who.staff.name, handoffId, nowIso: now.toISOString() });
  return json({ ok: true, sent_text: final, recorded: recorded.thread, handoff_marked: handoffId ? recorded.handoff : false });
}
