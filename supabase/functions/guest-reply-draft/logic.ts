// guest-reply-draft (s76): the admin dashboard and the staff app send a guest's message (text or a chat screenshot) and get Cassy's
// draft replies back. Drafting is telegram-cassy/draft.ts, not a copy: the wiring below is telegram-cassy's draft() for a screenshot
// (transcribeChat -> splitThread -> draftGuestReply with the thread behind it) and for pasted text. Nothing is ever sent to a guest.
// Owner and admin only: a draft carries prices and booking terms. All I/O comes in through Deps so the rules are tested without a network.
import { bearerToken, StaffAuthError } from '../_shared/staff-auth.ts';
import { draftPlatform, splitThread, type Line, type Platform, type Transcript } from '../telegram-cassy/draft.ts';

export const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
export const MAX_TEXT = 4000;
export const MAX_IMAGE_BYTES = 4_000_000;
const MAX_B64 = Math.ceil(MAX_IMAGE_BYTES / 3) * 4; // longest base64 string whose decoded size can still fit
const MIMES = ['image/jpeg', 'image/png', 'image/webp'];

export interface Deps {
  /** The caller's session -> an active owner/admin, or the HTTP status to refuse with. */
  authenticate(token: string): Promise<{ ok: true } | { ok: false; status: number; error: string }>;
  /** telegram-cassy draftGuestReply bound to the service client: [header card, main reply, optional short reply]. */
  draft(guestText: string, guestName: string | null, thread: { before?: Line[]; platform?: Platform }): Promise<string[]>;
  /** telegram-cassy transcribeChat. */
  transcribe(bytes: Uint8Array, mime: string): Promise<Transcript>;
  now(): number;
  log(line: string): void;
  logError(line: string): void;
}

export function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}
/** The header card is written for Telegram: the apps have no long-press and no "cassy reply" command, so those lines and phrases go. */
export function appHeader(header: string): string {
  return header.split('\n').filter((l) => !/\bcassy (?:reply|draft)\b/i.test(l)).join('\n')
    .replace(/\s*Long-press an option to copy it\.?/i, '').trim();
}
const fail = (error: string, status: number) => json({ ok: false, error }, status);

function decodeBase64(b64: string): Uint8Array | null {
  try {
    const bin = atob(b64);
    return Uint8Array.from(bin, (c) => c.charCodeAt(0));
  } catch { return null; }
}

export async function handleGuestReplyDraft(req: Request, deps: Deps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return fail('method_not_allowed', 405);

  let token: string;
  try { token = bearerToken(req); } catch (e) {
    if (e instanceof StaffAuthError) return fail(e.code, e.status);
    throw e;
  }
  const who = await deps.authenticate(token);
  if (!who.ok) return fail(who.error, who.status);

  const t0 = deps.now();
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return fail('bad_json', 400); }
  if (!body || typeof body !== 'object' || Array.isArray(body)) return fail('bad_json', 400);

  const hasText = body.text != null, hasImage = body.image != null;
  if (hasText && hasImage) return fail('both', 400);
  if (!hasText && !hasImage) return fail('empty', 400);
  if (body.platform != null && body.platform !== 'messenger' && body.platform !== 'airbnb') return fail('bad_json', 400);
  if (body.guest_name != null && typeof body.guest_name !== 'string') return fail('bad_json', 400);
  const label = body.platform as Platform | undefined;
  const nameIn = typeof body.guest_name === 'string' ? body.guest_name.trim().slice(0, 80) || null : null;

  let text = '';
  let bytes: Uint8Array | null = null, mime = '';
  if (hasText) {
    if (typeof body.text !== 'string') return fail('bad_json', 400);
    text = body.text.trim();
    // A bare "airbnb:" marker carries no guest message either.
    if (!draftPlatform(text, label).text.trim()) return fail('empty', 400);
    if (text.length > MAX_TEXT) return fail('too_long', 400);
  } else {
    const im = body.image as Record<string, unknown>;
    if (typeof im !== 'object' || Array.isArray(im) || typeof im.base64 !== 'string' || typeof im.mime !== 'string' || !MIMES.includes(im.mime)) return fail('bad_image', 400);
    // A data: URL prefix and any whitespace are what a browser FileReader hands over; neither counts toward the size or the decode.
    const raw = im.base64.replace(/^\s*data:[^;,]*;base64,/i, '').replace(/\s+/g, '');
    if (raw.length > MAX_B64) return fail('image_too_large', 413);
    bytes = decodeBase64(raw);
    if (!bytes || !bytes.length) return fail('bad_image', 400);
    if (bytes.length > MAX_IMAGE_BYTES) return fail('image_too_large', 413);
    mime = im.mime;
  }

  const input = hasText ? 'text' : 'image';
  try {
    let guestText = text, guestName = nameIn; // no "guest: Name" caption parsing: the page sends guest_name
    let thread: { before?: Line[]; platform?: Platform } = label ? { platform: label } : {};
    if (bytes) {
      // D-269: the whole visible thread, so the draft answers the newest guest messages with the conversation behind them.
      const t = await deps.transcribe(bytes, mime);
      const s = splitThread(t.messages);
      if (!s.latest) return fail('no_guest_message', 422);
      guestText = s.latest; guestName = nameIn ?? t.guest_name; thread = { before: s.before, platform: label ?? t.platform };
    }
    const src = draftPlatform(guestText, thread.platform);
    if (!src.text.trim()) return fail(bytes ? 'no_guest_message' : 'empty', bytes ? 422 : 400);
    const out = await deps.draft(guestText, guestName, thread);
    const header = out[0], replies = out.slice(1).filter((r) => typeof r === 'string' && r.trim());
    if (typeof header !== 'string' || !replies.length) throw new Error('no_replies');
    deps.log(JSON.stringify({ fn: 'guest_reply_draft', role: 'owner_or_admin', input, platform: src.platform, replies: replies.length, ms: deps.now() - t0 }));
    return json({ ok: true, guest_name: guestName, platform: src.platform, guest_text: src.text.trim(), header: appHeader(header), replies: replies.slice(0, 2) });
  } catch (e) {
    // The error class only: a message can quote the guest.
    deps.logError(JSON.stringify({ fn: 'guest_reply_draft_failed', role: 'owner_or_admin', input, error: e instanceof Error ? e.name : typeof e, ms: deps.now() - t0 }));
    return fail('draft_failed', 502);
  }
}
