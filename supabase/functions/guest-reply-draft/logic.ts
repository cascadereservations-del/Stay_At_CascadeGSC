// guest-reply-draft (s76): the admin dashboard and the staff app send a guest's message (text or a chat screenshot) and get Cassy's
// draft replies back. Drafting is telegram-cassy/draft.ts, not a copy: the wiring below is telegram-cassy's draft() for a screenshot
// (transcribeChat -> splitThread -> draftGuestReply with the thread behind it) and for pasted text. Nothing is ever sent to a guest.
// s82: every active staff role may draft; owner/admin get the full draft (booking context, rates), everyone else a context-free one (R_draft.ts). All I/O comes in through Deps so the rules are tested without a network.
import { bearerToken, StaffAuthError } from '../_shared/staff-auth.ts';
import { draftPlatform, splitThread, type Line, type Platform, type Transcript } from '../telegram-cassy/draft.ts';
import type { Access, DraftOut, Option } from './R_draft.ts';
import type { ReadResult } from './R_transcribe.ts';

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
  /** The caller's session -> an active staff member (`access` absent = 'limited', fail closed), or the HTTP status to refuse with. */
  authenticate(token: string): Promise<{ ok: true; access?: Access } | { ok: false; status: number; error: string }>;
  /** Either the legacy [header card, main reply, optional short reply] or { header, options } (R_draft.draftOptions). */
  draft(guestText: string, guestName: string | null, thread: { before?: Line[]; platform?: Platform }, access: Access): Promise<string[] | DraftOut>;
  /** The screenshot reader. pass 2 = the stronger prompt; `malformed` = the model's JSON could not be read. */
  transcribe(bytes: Uint8Array, mime: string, pass?: 1 | 2): Promise<ReadResult>;
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

const hasGuest = (t: Transcript) => t.messages.some((m) => m.from === 'guest' && m.text.trim());
const NOTE_HOST_LAST = "The last message in the screenshot is yours; this answers the guest's last message.";

/** The newest run of guest messages and the thread before it, wherever the host spoke last. */
export function lastGuestRun(lines: Line[]): { latest: string; before: Line[] } {
  let end = lines.length - 1;
  while (end >= 0 && lines[end].from !== 'guest') end--;
  if (end < 0) return { latest: '', before: lines };
  let start = end;
  while (start > 0 && lines[start - 1].from === 'guest') start--;
  return { latest: lines.slice(start, end + 1).map((l) => l.text).join('\n'), before: lines.slice(0, start) };
}

/** One read, one retry when the model's JSON was unreadable, then ONE stronger second pass when there is still no guest message. */
async function readScreenshot(deps: Deps, bytes: Uint8Array, mime: string): Promise<ReadResult> {
  let t = await deps.transcribe(bytes, mime, 1);
  if (t.malformed) t = await deps.transcribe(bytes, mime, 1);
  if (!hasGuest(t)) { const t2 = await deps.transcribe(bytes, mime, 2); if (hasGuest(t2)) t = t2; }
  return t;
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
  const access: Access = who.access === 'full' ? 'full' : 'limited';

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
    let hostLast = false;
    if (bytes) {
      // D-269: the whole visible thread, so the draft answers the newest guest messages with the conversation behind them.
      const t = await readScreenshot(deps, bytes, mime);
      let s = splitThread(t.messages);
      if (!s.latest) { s = lastGuestRun(t.messages); hostLast = !!s.latest; } // the host spoke last: answer the guest's last message, and say so
      if (!s.latest) return fail('no_guest_message', 422);
      guestText = s.latest; guestName = nameIn ?? t.guest_name; thread = { before: s.before, platform: label ?? t.platform };
    }
    const src = draftPlatform(guestText, thread.platform);
    if (!src.text.trim()) return fail(bytes ? 'no_guest_message' : 'empty', bytes ? 422 : 400);
    const out = await deps.draft(guestText, guestName, thread, access);
    let header: unknown, options: Option[];
    if (Array.isArray(out)) { // legacy shape: [header, main, short?]
      header = out[0];
      options = out.slice(1).filter((r) => typeof r === 'string' && r.trim()).slice(0, 2).map((text, i) => ({ label: i ? 'Short' : 'Warm', text }));
    } else { header = out?.header; options = (out?.options ?? []).filter((o) => o && typeof o.text === 'string' && o.text.trim()).slice(0, 3); }
    if (typeof header !== 'string' || !options.length) throw new Error('no_replies');
    deps.log(JSON.stringify({ fn: 'guest_reply_draft', role: access === 'full' ? 'owner_or_admin' : 'staff_limited', input, platform: src.platform, replies: options.length, ms: deps.now() - t0 }));
    const head = appHeader(header) + (hostLast ? `\n${NOTE_HOST_LAST}` : '');
    return json({ ok: true, guest_name: guestName, platform: src.platform, guest_text: src.text.trim(), header: head, replies: options.map((o) => o.text), options });
  } catch (e) {
    // The error class only: a message can quote the guest.
    deps.logError(JSON.stringify({ fn: 'guest_reply_draft_failed', role: access === 'full' ? 'owner_or_admin' : 'staff_limited', input, error: e instanceof Error ? e.name : typeof e, ms: deps.now() - t0 }));
    return fail('draft_failed', 502);
  }
}
