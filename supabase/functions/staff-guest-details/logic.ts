// staff-guest-details (s77): "Add guest details" on the staff app guest card. An owner or admin pastes the guest's chat text and/or
// adds screenshots and ID photos for ONE stay; the model reads them (action 'extract', nothing written), the page shows a review sheet,
// and 'save' writes what the person confirmed. Reuse, not rebuild:
//   reads   - telegram-expense/guest.ts (cleanName, normalizePhone, toIdType, sameName: D-291's guards) + the shared vision helper and
//             chatJson (paid route, every call one llm_usage row for the D-294 governor; never the free 'routine' tier: guest data).
//   writes  - the dashboard's own RPCs with the CALLER's JWT (save_guest_profile_v1, save_guest_companion_v1: they check
//             manage_operations and write the history rows), the guest-id-photos 'manage write' storage policy for the photo
//             (<companion id>/<uuid>.<ext>, metadata stripped by guest-intake/validate.ts), and guests.email only when it is empty
//             (guests_owner_admin_all RLS). The service key only maps the stay uid to its guest (staff_stay_guest_id_v1).
// Never read, stored or logged: ID numbers, birthdays, addresses. Screenshots are read once and dropped; only an ID photo the person
// keeps in the sheet is stored. No OPS message (D-306). Logs carry counts only, never a name or a number.
import { bearerToken, StaffAuthError } from '../_shared/staff-auth.ts';
import { normalizeEmail } from '../_shared/guest-identity.ts';
import { cleanName, normalizePhone, sameName, toIdType, type IdType } from '../telegram-expense/guest.ts';
import { sniffImage, stripMetadata } from '../guest-intake/validate.ts';

export const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
export const MAX_TEXT = 6000;
export const MAX_IMAGES = 4;
export const MAX_IMAGE_BYTES = 4_000_000;
const MAX_B64 = Math.ceil(MAX_IMAGE_BYTES / 3) * 4;
const MIMES = ['image/jpeg', 'image/png', 'image/webp'];
export const REASON = 'staff app: Add guest details';

export const READ_PROMPT = `You read guest details for a small guesthouse host in the Philippines. Return JSON only:
{"kind":"id"|"chat"|"other","name":string|null,"id_type":"passport"|"drivers_license"|"national_id"|"other"|null,"nationality":string|null,"names":[string],"phone":string|null,"email":string|null,"guests":number|null}
- kind "id": a photo of a passport, driver's licence, national ID or other government or professional ID card. Fill "name" with the holder's full name as given names then surname, "id_type", and "nationality" when the card shows it.
- kind "chat": a conversation or a message the guest wrote. Fill "names" with the full names of the people who will stay (not the host), "phone" and "email" with what the guest typed, exactly as written, "guests" with the number of people staying when it is stated, and "nationality" only when it is stated.
- kind "other": anything else, or not readable.
STRICT: never output an ID, passport, licence or card number, a birth date, an address or a signature. The only digits you may output are a phone number the guest typed and the number of guests. If you are unsure, use null.`;

export type Read =
  | { kind: 'id'; name: string; idType: IdType; nationality: string | null }
  | { kind: 'chat'; names: string[]; phone: string | null; email: string | null; guests: number | null; nationality: string | null }
  | { kind: 'other' };

export function cleanPhone(v: unknown): string | null {
  const ph = normalizePhone(v);
  if (ph) return ph;
  const s = String(v ?? '').replace(/[\s\-().]/g, '');
  return /^\+[1-9][0-9]{6,14}$/.test(s) ? s : null; // a guest from abroad: international form only
}
export function cleanNationality(v: unknown): string | null {
  const s = String(v ?? '').replace(/\s+/g, ' ').trim();
  if (!/^[\p{L}][\p{L} '-]{1,39}$/u.test(s)) return null;
  return s.toLowerCase().replace(/(^|[\s'-])(\p{L})/gu, (_m, a, b) => a + b.toUpperCase());
}
export function cleanGuests(v: unknown): number | null {
  const n = typeof v === 'number' ? v : Number(String(v ?? '').trim());
  return Number.isInteger(n) && n >= 1 && n <= 12 ? n : null;
}

/** The model's text as a Read. Anything unexpected is 'other': nothing is proposed from a guess. */
export function parseRead(raw: string): Read {
  // deno-lint-ignore no-explicit-any
  let j: any;
  try {
    const t = String(raw ?? '').replace(/^```(?:json)?\s*|\s*```$/g, '').trim();
    j = JSON.parse(t.slice(t.indexOf('{'), t.lastIndexOf('}') + 1));
  } catch { return { kind: 'other' }; }
  if (j?.kind === 'id') {
    const name = cleanName(j.name);
    return name ? { kind: 'id', name, idType: toIdType(j.id_type), nationality: cleanNationality(j.nationality) } : { kind: 'other' };
  }
  if (j?.kind === 'chat') {
    const names = [...new Set((Array.isArray(j.names) ? j.names : []).map(cleanName).filter((n: string | null): n is string => !!n))].slice(0, 12) as string[];
    const r = { kind: 'chat' as const, names, phone: cleanPhone(j.phone), email: normalizeEmail(j.email), guests: cleanGuests(j.guests), nationality: cleanNationality(j.nationality) };
    return names.length || r.phone || r.email || r.guests || r.nationality ? r : { kind: 'other' };
  }
  return { kind: 'other' };
}

export type OnFile = {
  guestId: string; name: string; email: string | null; phone: string | null; idOnFile: boolean; idType: string | null;
  notes: string | null; version: number | null; companions: Array<{ id: string; name: string; hasPhoto: boolean }>;
};
export type Stay = { uid: string; guestId: string | null; guestName: string | null; checkin: string; checkout: string; source: string | null };
export type Proposal = {
  phone: string | null; email: string | null; guests: number | null; nationality: string | null;
  companions: string[];                                   // new names, not the guest and not already a companion
  ids: Array<{ image: number; name: string; id_type: IdType; own: boolean }>; // which uploaded images are ID photos
  images: Array<'id' | 'chat' | 'other'>;
};

/** Every read for one stay merged into one proposal for the review sheet. The first value found wins; an ID's nationality beats a chat's. */
export function propose(reads: Array<{ image: number | null; read: Read }>, g: OnFile): Proposal {
  const p: Proposal = { phone: null, email: null, guests: null, nationality: null, companions: [], ids: [], images: [] };
  const known = (n: string) => sameName(n, g.name) || g.companions.some((c) => sameName(n, c.name)) || p.companions.some((c) => sameName(n, c));
  for (const { image, read } of reads) {
    if (image !== null) p.images[image] = read.kind;
    if (read.kind === 'id' && image !== null) {
      p.ids.push({ image, name: read.name, id_type: read.idType, own: sameName(read.name, g.name) });
      if (read.nationality) p.nationality = read.nationality;
      if (!known(read.name)) p.companions.push(read.name);
    } else if (read.kind === 'chat') {
      p.phone ??= read.phone; p.email ??= read.email; p.guests ??= read.guests; p.nationality ??= read.nationality;
      for (const n of read.names) if (!known(n)) p.companions.push(n);
    }
  }
  return p;
}

/** The note line the guest card shows: "<check-in>: 3 guests | Nationality Filipino". null when there is nothing to say. */
export function noteLine(checkin: string, guests: number | null, nationality: string | null): string | null {
  const bits = [guests ? `${guests} guest${guests === 1 ? '' : 's'}` : '', nationality ? `Nationality ${nationality}` : ''].filter(Boolean);
  return bits.length ? `${checkin}: ${bits.join(' | ')}` : null;
}
/** stay_preferences with the line appended once (' || ' is the group separator the staff card parses). */
export function appendNote(current: string | null, line: string | null): string | null {
  const cur = (current ?? '').trim();
  if (!line || cur.includes(line)) return null;
  return cur ? `${cur} || ${line}` : line;
}

export type RpcOut = { data: unknown; error: { message: string; code?: string } | null };
export interface Ops {
  /** The guest record as the caller sees it (RLS: manage_operations). */
  loadGuest(guestId: string): Promise<OnFile | null>;
  saveProfile(guestId: string, patch: Record<string, unknown>, version: number | null): Promise<RpcOut>;
  saveCompanion(guestId: string, companionId: string | null, patch: Record<string, unknown>): Promise<RpcOut>;
  setEmail(guestId: string, email: string): Promise<string | null>; // an error message, or null
  upload(path: string, bytes: Uint8Array, mime: string): Promise<string | null>;
  remove(path: string): Promise<void>;
}
export interface Deps {
  /** The caller's session -> an active owner/admin with ops bound to that session, or the HTTP status to refuse with. */
  authenticate(token: string): Promise<{ ok: true; ops: Ops } | { ok: false; status: number; error: string }>;
  /** Service key: the stay for a calendar uid and the guest it is linked to. */
  stay(uid: string): Promise<Stay | null>;
  readImage(bytes: Uint8Array, mime: string): Promise<string>;
  readText(text: string): Promise<string>;
  uuid(): string;
  log(line: string): void;
}

export function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}
const fail = (error: string, status: number) => json({ ok: false, error }, status);

function decodeImage(v: unknown): { bytes: Uint8Array; mime: string } | string {
  const im = v as Record<string, unknown>;
  if (!im || typeof im !== 'object' || typeof im.base64 !== 'string' || typeof im.mime !== 'string' || !MIMES.includes(im.mime)) return 'bad_image';
  const raw = im.base64.replace(/^\s*data:[^;,]*;base64,/i, '').replace(/\s+/g, '');
  if (raw.length > MAX_B64) return 'image_too_large';
  try {
    const bytes = Uint8Array.from(atob(raw), (c) => c.charCodeAt(0));
    if (!bytes.length) return 'bad_image';
    return bytes.length > MAX_IMAGE_BYTES ? 'image_too_large' : { bytes, mime: im.mime };
  } catch { return 'bad_image'; }
}
const view = (s: Stay, g: OnFile) => ({
  stay: { uid: s.uid, guest_name: s.guestName, checkin: s.checkin, checkout: s.checkout, source: s.source },
  on_file: { name: g.name, phone: g.phone, email: g.email, id_on_file: g.idOnFile, companions: g.companions.map((c) => ({ name: c.name, photo: c.hasPhoto })) },
});

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return fail('method_not_allowed', 405);
  let token: string;
  try { token = bearerToken(req); } catch (e) {
    if (e instanceof StaffAuthError) return fail(e.code, e.status);
    throw e;
  }
  const who = await deps.authenticate(token);
  if (!who.ok) return fail(who.error, who.status);
  const ops = who.ops;

  // deno-lint-ignore no-explicit-any
  let body: any;
  try { body = await req.json(); } catch { return fail('bad_json', 400); }
  if (!body || typeof body !== 'object' || Array.isArray(body)) return fail('bad_json', 400);
  const action = body.action;
  if (action !== 'context' && action !== 'extract' && action !== 'save') return fail('bad_action', 400);
  if (typeof body.uid !== 'string' || !body.uid.trim() || body.uid.length > 300) return fail('bad_stay', 400);

  const stay = await deps.stay(body.uid.trim());
  if (!stay) return fail('stay_not_found', 404);
  if (!stay.guestId) return fail('no_guest_record', 409);
  const g = await ops.loadGuest(stay.guestId);
  if (!g) return fail('staff_access_denied', 403); // RLS hid it: not owner/admin for this property
  if (action === 'context') return json({ ok: true, ...view(stay, g) });

  if (action === 'extract') {
    const text = typeof body.text === 'string' ? body.text.trim() : '';
    const imgs = Array.isArray(body.images) ? body.images : [];
    if (body.text != null && typeof body.text !== 'string') return fail('bad_json', 400);
    if (!text && !imgs.length) return fail('empty', 400);
    if (text.length > MAX_TEXT) return fail('too_long', 400);
    if (imgs.length > MAX_IMAGES) return fail('too_many_images', 400);
    const decoded = imgs.map(decodeImage);
    const bad = decoded.find((d: unknown) => typeof d === 'string') as string | undefined;
    if (bad) return fail(bad, bad === 'image_too_large' ? 413 : 400);
    try {
      const reads: Array<{ image: number | null; read: Read }> = [];
      // Images one after another: four parallel vision calls would trip the provider's rate limit for no gain on one phone.
      for (const [i, d] of (decoded as Array<{ bytes: Uint8Array; mime: string }>).entries()) reads.push({ image: i, read: parseRead(await deps.readImage(d.bytes, d.mime)) });
      if (text) reads.push({ image: null, read: parseRead(await deps.readText(text)) });
      const proposal = propose(reads, g);
      deps.log(JSON.stringify({ fn: 'staff_guest_details', action, text: !!text, images: decoded.length, ids: proposal.ids.length, companions: proposal.companions.length }));
      return json({ ok: true, ...view(stay, g), proposal });
    } catch (e) {
      deps.log(JSON.stringify({ fn: 'staff_guest_details_failed', action, error: e instanceof Error ? e.name : typeof e }));
      return fail('read_failed', 502);
    }
  }
  return save(body, stay, g, ops, deps);
}

type Saved = { what: string; ok: boolean; reason?: string };

// deno-lint-ignore no-explicit-any
async function save(body: any, stay: Stay, g: OnFile, ops: Ops, deps: Deps): Promise<Response> {
  // Every field is checked again here: the sheet is editable, so nothing from the client is trusted as the model's clean output.
  const phone = body.phone == null || body.phone === '' ? null : cleanPhone(body.phone);
  const email = body.email == null || body.email === '' ? null : normalizeEmail(body.email);
  const guests = body.guests == null || body.guests === '' ? null : cleanGuests(body.guests);
  const nationality = body.nationality == null || body.nationality === '' ? null : cleanNationality(body.nationality);
  if ((body.phone && !phone) || (body.email && !email) || (body.guests && !guests) || (body.nationality && !nationality)) return fail('bad_field', 400);
  const names = Array.isArray(body.companions) ? body.companions : [];
  const ids = Array.isArray(body.ids) ? body.ids : [];
  if (names.length > 12 || ids.length > MAX_IMAGES) return fail('too_many', 400);
  const companions = names.map(cleanName);
  if (companions.some((n: string | null) => !n)) return fail('bad_name', 400);
  const photos: Array<{ name: string; idType: IdType; bytes: Uint8Array; ext: 'jpg' | 'png' | 'webp'; mime: string }> = [];
  for (const it of ids) {
    const name = cleanName(it?.name), d = decodeImage(it?.image);
    if (!name) return fail('bad_name', 400);
    if (typeof d === 'string') return fail(d, d === 'image_too_large' ? 413 : 400);
    const kind = sniffImage(d.bytes), clean = kind ? stripMetadata(d.bytes, kind.ext) : null;
    if (!kind || !clean) return fail('bad_image', 400); // a file we cannot clean is never stored
    photos.push({ name, idType: toIdType(it?.id_type), bytes: clean, ext: kind.ext, mime: kind.mime });
  }
  if (!phone && !email && !guests && !nationality && !companions.length && !photos.length) return fail('empty', 400);

  const out: Saved[] = [];
  const err = (r: RpcOut) => r.error ? (r.error.code === '42501' ? 'denied' : r.error.code === '40001' ? 'changed' : 'save_failed') : null;
  const list = [...g.companions];
  const companionFor = async (name: string): Promise<{ id: string } | string> => {
    const hit = list.find((c) => sameName(name, c.name) || c.name.toLowerCase() === name.toLowerCase());
    if (hit) return { id: hit.id };
    const r = await ops.saveCompanion(g.guestId, null, { name });
    // deno-lint-ignore no-explicit-any
    const id = (r.data as any)?.id;
    if (err(r) || !id) return err(r) ?? 'save_failed';
    list.push({ id: String(id), name, hasPhoto: false });
    return { id: String(id) };
  };

  for (const n of companions as string[]) {
    if (sameName(n, g.name)) continue; // the guest is not their own companion
    const before = list.length, c = await companionFor(n);
    if (typeof c === 'string') out.push({ what: 'companion', ok: false, reason: c });
    else if (list.length > before) out.push({ what: 'companion', ok: true });
  }

  let ownType: IdType | null = null, anyPhoto = false;
  for (const p of photos) {
    const own = sameName(p.name, g.name);
    // The guest's own ID goes on a companion row named exactly as the guest record, so the staff card shows it first
    // (staff_primary_id_path_v1 orders an exact name match first).
    const c = await companionFor(own ? g.name : p.name);
    if (typeof c === 'string') { out.push({ what: 'id_photo', ok: false, reason: c }); continue; }
    const path = `${c.id}/${deps.uuid()}.${p.ext}`;
    if (await ops.upload(path, p.bytes, p.mime)) { out.push({ what: 'id_photo', ok: false, reason: 'upload_failed' }); continue; }
    const linked = await ops.saveCompanion(g.guestId, c.id, { id_photo_path: path, id_type: p.idType });
    if (err(linked)) { await ops.remove(path).catch(() => null); out.push({ what: 'id_photo', ok: false, reason: err(linked)! }); continue; }
    out.push({ what: 'id_photo', ok: true }); anyPhoto = true;
    if (own) ownType = p.idType;
  }

  const patch: Record<string, unknown> = {};
  if (phone && phone !== g.phone) patch.contact_number = phone;
  if (anyPhoto && !g.idOnFile) patch.id_on_file = true;
  if (ownType) patch.id_type = ownType;
  const notes = appendNote(g.notes, noteLine(stay.checkin, guests, nationality));
  if (notes) patch.stay_preferences = notes;
  if (Object.keys(patch).length) {
    const r = await ops.saveProfile(g.guestId, patch, g.version);
    out.push({ what: 'profile', ok: !err(r), ...(err(r) ? { reason: err(r)! } : {}) });
  }

  if (email) {
    // guests.email is the identity the booking resolver matches on: fill it when empty, never overwrite one on file.
    if (!g.email) { const e = await ops.setEmail(g.guestId, email); out.push(e ? { what: 'email', ok: false, reason: 'save_failed' } : { what: 'email', ok: true }); }
    else if (normalizeEmail(g.email) !== email) out.push({ what: 'email', ok: false, reason: 'email_kept' });
  }
  const ok = out.every((s) => s.ok || s.reason === 'email_kept');
  deps.log(JSON.stringify({ fn: 'staff_guest_details', action: 'save', saved: out.filter((s) => s.ok).length, failed: out.filter((s) => !s.ok).length }));
  return json({ ok, saved: out }, ok ? 200 : 207);
}
