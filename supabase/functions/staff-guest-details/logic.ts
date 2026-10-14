// staff-guest-details (s77): "Add guest details" on the staff app guest card. An owner or admin pastes the guest's chat text and/or
// adds screenshots and ID photos for ONE stay; the model reads them (action 'extract', nothing written), the page shows a review sheet,
// and 'save' writes what the person confirmed. Reuse, not rebuild:
//   reads   - telegram-expense/guest.ts (cleanName, normalizePhone, toIdType, sameName: D-291's guards) + the shared vision helper and
//             chatJson (paid route, every call one llm_usage row for the D-294 governor; never the free 'routine' tier: guest data).
//   writes  - the dashboard's own RPCs with the CALLER's JWT (save_guest_profile_v1, save_guest_companion_v1: they check
//             manage_operations and write the history rows), the guest-id-photos 'manage write' storage policy for the photo
//             (<companion id>/<uuid>.<ext>, metadata stripped by guest-intake/validate.ts), and guests.email only when it is empty
//             (guests_owner_admin_all RLS). The service key only maps the stay uid to its guest (staff_stay_guest_id_v1).
// s82 lane G (Staff 3.2): the same function now also serves the staff app's native Guests screen. A request names the guest directly
//   (guest_id) instead of a stay (uid); 'extract' also proposes stay_preferences, birthday and tags from a guest's CHAT only (never from an
//   ID, and only when the text states them); 'save' writes those three, an optional reason and an optional expected_version through
//   save_guest_profile_v1 with the caller's JWT; 'replace_id' and 'remove_id' swap or clear one ID photo through the companion RPC and leave
//   the old object to the existing purge queue (guest_companions_release_photo trigger). Every new key is optional: old clients keep working.
// Never read, stored or logged: ID numbers, addresses. A birthday is read only from a chat the guest wrote, shown for review, and written
// only after the person confirmed it; it is never logged. Screenshots are read once and dropped; only an ID photo the person
// keeps in the sheet is stored. No OPS message (D-306). Logs carry counts only, never a name or a number.
import { bearerToken, StaffAuthError } from '../_shared/staff-auth.ts';
import { normalizeEmail } from '../_shared/guest-identity.ts';
import { cleanName, normalizePhone, sameName, toIdType, type IdType } from '../telegram-expense/guest.ts';
import { sniffImage, stripMetadata } from '../guest-intake/validate.ts';

export const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version, x-supabase-api-version',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
export const MAX_TEXT = 6000;
export const MAX_IMAGES = 4;
export const MAX_IMAGE_BYTES = 4_000_000;
// ponytail: one extract holds up to 4 x 4 MB decoded (plus their base64) in memory, ~40 MB peak; the page shrinks photos to 1600 px
// JPEG first, so real requests are ~1 MB. Stream or lower MAX_IMAGES if the worker memory limit is ever hit.
export const MAX_READS_PER_HOUR = 40; // llm_usage has no actor column, so this counts all callers together, not one user
const MAX_B64 = Math.ceil(MAX_IMAGE_BYTES / 3) * 4;
const MIMES = ['image/jpeg', 'image/png', 'image/webp'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const REASON = 'staff app: Add guest details';

export const READ_PROMPT = `You read guest details for a small guesthouse host in the Philippines. Return JSON only:
{"kind":"id"|"chat"|"other","name":string|null,"id_type":"passport"|"drivers_license"|"national_id"|"other"|null,"nationality":string|null,"names":[string],"phone":string|null,"email":string|null,"guests":number|null,"stay_preferences":string|null,"birthday":string|null,"tags":[string]}
- kind "id": a photo of a passport, driver's licence, national ID or other government or professional ID card. Fill "name" with the holder's full name as given names then surname, and "id_type". Leave "nationality" null for an ID. Never fill "stay_preferences", "birthday" or "tags" for an ID: leave them null and [].
- kind "chat": a conversation or a message the guest wrote. Fill "names" with the full names of the people who will stay (not the host), "phone" and "email" with what the guest typed, exactly as written, "guests" with the number of people staying when it is stated, and "nationality" only when it is stated.
  "stay_preferences": one or two short sentences with the preferences or requests the guest states for the stay (for example an allergy, a quiet room, a late arrival, a celebration), staying close to what the guest wrote; null when the guest states none.
  "birthday": a full date as YYYY-MM-DD, only when the guest states their own birth date including the year; a month and day without a year is null; never a stay date, a booking date or another person's birthday.
  "tags": up to 5 short lower-case labels of one to three words for facts the guest states about themselves or the group (such as "anniversary", "vegetarian", "traveling with a baby"); [] when none is stated.
- kind "other": anything else, or not readable.
STRICT: never invent. Fill "stay_preferences", "birthday" and "tags" only from words the guest actually wrote; when the text does not state it, use null or []. Never output an ID, passport, licence or card number, an address or a signature, and never read a birth date from an ID. The only digits you may output are a phone number the guest typed, the number of guests and a birth date the guest typed in a chat. If you are unsure, use null.`;

export type Read =
  | { kind: 'id'; name: string; idType: IdType }
  | { kind: 'chat'; names: string[]; phone: string | null; email: string | null; guests: number | null; nationality: string | null; stayPreferences: string | null; birthday: string | null; tags: string[] }
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

/** Today in Manila (UTC+8, no daylight saving) as YYYY-MM-DD; `now` is injectable so tests freeze the clock. */
export function manilaToday(now: number = Date.now()): string { return new Date(now + 8 * 3600_000).toISOString().slice(0, 10); }
/** A real calendar date as YYYY-MM-DD, year 1900 or later, not after today; otherwise null. A date without a year is null. */
export function cleanBirthday(v: unknown, now: number = Date.now()): string | null {
  const s = String(v ?? '').trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return null;
  const d = new Date(`${s}T00:00:00Z`);
  if (!Number.isFinite(d.getTime()) || d.toISOString().slice(0, 10) !== s || d.getUTCFullYear() < 1900 || s > manilaToday(now)) return null;
  return s;
}
const CTRL = /[\u0000-\u0008\u000b-\u001f\u007f\u2028\u2029]/g;
/** What the reader proposes as stay preferences: short, plain text, no long digit run (an ID or card number). Otherwise null. */
export function cleanPreferences(v: unknown): string | null {
  const s = String(v ?? '').replace(CTRL, ' ').replace(/\s+/g, ' ').trim().slice(0, 600);
  return s.length >= 3 && !/\d{7,}/.test(s.replace(/[\s-]/g, '')) ? s : null;
}
/** A preferences text the person edited in the sheet: up to the database's own 4000 characters, line breaks kept. */
export function cleanPreferencesSave(v: unknown): string | null {
  const s = String(v ?? '').replace(CTRL, ' ').replace(/[ \t]+/g, ' ').trim();
  return s.length >= 1 && s.length <= 4000 ? s : null;
}
/** Short lower-case labels: letters, digits, spaces and hyphens, 2 to 30 characters, no repeats. `max` caps the list. */
export function cleanTags(v: unknown, max = 5, maxLen = 30): string[] {
  const out: string[] = [];
  for (const t of Array.isArray(v) ? v : []) {
    const s = String(t ?? '').replace(/\s+/g, ' ').trim().toLowerCase();
    if (s.length >= 2 && s.length <= maxLen && /^[\p{L}\p{N}][\p{L}\p{N} '-]*$/u.test(s) && !/\d{5,}/.test(s) && !out.includes(s)) out.push(s);
    if (out.length >= max) break;
  }
  return out;
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
    return name ? { kind: 'id', name, idType: toIdType(j.id_type) } : { kind: 'other' }; // D-291: name + ID type only from an ID
  }
  if (j?.kind === 'chat') {
    const names = [...new Set((Array.isArray(j.names) ? j.names : []).map(cleanName).filter((n: string | null): n is string => !!n))].slice(0, 12) as string[];
    const r = { kind: 'chat' as const, names, phone: cleanPhone(j.phone), email: normalizeEmail(j.email), guests: cleanGuests(j.guests), nationality: cleanNationality(j.nationality),
      stayPreferences: cleanPreferences(j.stay_preferences), birthday: cleanBirthday(j.birthday), tags: cleanTags(j.tags) }; // nothing is kept that the text did not state in a clean form
    return names.length || r.phone || r.email || r.guests || r.nationality || r.stayPreferences || r.birthday || r.tags.length ? r : { kind: 'other' };
  }
  return { kind: 'other' };
}

export type OnFile = {
  guestId: string; name: string; email: string | null; phone: string | null; idOnFile: boolean; idType: string | null;
  version: number | null; companions: Array<{ id: string; name: string; hasPhoto: boolean; idType?: string | null }>;
  // s82 G, all optional (an older loader leaves them out): what is on file, so a proposal never repeats it.
  stayPreferences?: string | null; tags?: string[]; birthday?: string | null;
};
export type Stay = { uid: string; propertyId: string; guestId: string | null; guestName: string | null; checkin: string; checkout: string; source: string | null };
export type Proposal = {
  phone: string | null; email: string | null; guests: number | null; nationality: string | null;
  stay_preferences: string | null; birthday: string | null; tags: string[];   // s82 G: from a chat only, never repeating what is on file
  companions: string[];                                 // new names, not the guest and not already a companion
  ids: Array<{ image: number; name: string; id_type: IdType; own: boolean }>; // which uploaded images are ID photos
  images: Array<'id' | 'chat' | 'other'>;
};

/** Every read for one stay merged into one proposal for the review sheet. The first value found wins. Guest count and nationality
 *  come from the guest's own text only and are shown, never saved (no safe column or write path; s77 orchestrator ruling). */
export function propose(reads: Array<{ image: number | null; read: Read }>, g: OnFile): Proposal {
  const p: Proposal = { phone: null, email: null, guests: null, nationality: null, stay_preferences: null, birthday: null, tags: [], companions: [], ids: [], images: [] };
  const known = (n: string) => sameName(n, g.name) || g.companions.some((c) => sameName(n, c.name)) || p.companions.some((c) => sameName(n, c));
  for (const { image, read } of reads) {
    if (image !== null) p.images[image] = read.kind;
    if (read.kind === 'id' && image !== null) {
      p.ids.push({ image, name: read.name, id_type: read.idType, own: sameName(read.name, g.name) });
      if (!known(read.name)) p.companions.push(read.name);
    } else if (read.kind === 'chat') {
      p.phone ??= read.phone; p.email ??= read.email; p.guests ??= read.guests; p.nationality ??= read.nationality;
      for (const n of read.names) if (!known(n)) p.companions.push(n);
      // Several screenshots of one chat add up; the same sentence twice is kept once.
      if (read.stayPreferences && !(p.stay_preferences ?? '').includes(read.stayPreferences)) p.stay_preferences = cleanPreferences(`${p.stay_preferences ?? ''} ${read.stayPreferences}`);
      p.birthday ??= read.birthday;
      for (const t of read.tags) if (!p.tags.includes(t) && p.tags.length < 8) p.tags.push(t);
    }
  }
  // Nothing is proposed that is already on file: an equal birthday, text already in the preferences, tags already held.
  if (p.birthday && p.birthday === g.birthday) p.birthday = null;
  if (p.stay_preferences && (g.stayPreferences ?? '').toLowerCase().includes(p.stay_preferences.toLowerCase())) p.stay_preferences = null;
  p.tags = p.tags.filter((t) => !(g.tags ?? []).some((x) => x.trim().toLowerCase() === t));
  return p;
}


export type RpcOut = { data: unknown; error: { message: string; code?: string } | null };
export interface Ops {
  /** The guest record as the caller sees it (RLS: manage_operations). */
  loadGuest(guestId: string): Promise<OnFile | null>;
  saveProfile(guestId: string, patch: Record<string, unknown>, version: number | null, reason: string): Promise<RpcOut>;
  saveCompanion(guestId: string, companionId: string | null, patch: Record<string, unknown>, reason: string): Promise<RpcOut>;
  setEmail(guestId: string, email: string): Promise<string | null>; // an error message, or null
  upload(path: string, bytes: Uint8Array, mime: string): Promise<string | null>;
  remove(path: string): Promise<void>;
  /** current_staff_authorized('manage_operations', property) with the caller's JWT. */
  canManage(propertyId: string): Promise<boolean>;
}
export interface Deps {
  /** The caller's session -> an active owner/admin with ops bound to that session, or the HTTP status to refuse with. */
  authenticate(token: string): Promise<{ ok: true; ops: Ops } | { ok: false; status: number; error: string }>;
  /** Service key: the stay for a calendar uid and the guest it is linked to. */
  stay(uid: string): Promise<Stay | null>;
  /** Service key (s82 G): the property a guest belongs to, for a request that names the guest instead of a stay. */
  guestProperty(guestId: string): Promise<string | null>;
  /** llm_usage rows this function wrote in the last hour (its X-Title), all callers. */
  recentReads(): Promise<number>;
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
// s82 G: `features` tells a newer client which keys this deployed version understands (an older one leaves it out, so the client hides the feature).
export const FEATURES = { guest_id: true, preferences: true, replace_id: true, remove_id: true };
const view = (s: Stay | null, g: OnFile) => ({
  features: FEATURES,
  stay: s ? { uid: s.uid, guest_name: s.guestName, checkin: s.checkin, checkout: s.checkout, source: s.source } : null,
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
  if (action !== 'context' && action !== 'extract' && action !== 'save' && action !== 'replace_id' && action !== 'remove_id') return fail('bad_action', 400);
  // A request names a stay (uid, the staff app's guest card) or, from s82, the guest directly (guest_id, the Guests screen).
  let stay: Stay | null = null, guestId: string | null, propertyId: string;
  if (body.guest_id != null) {
    if (typeof body.guest_id !== 'string' || !UUID.test(body.guest_id)) return fail('bad_guest', 400);
    const gid: string = body.guest_id.toLowerCase();
    guestId = gid;
    const prop = await deps.guestProperty(gid);
    if (!prop) return fail('guest_not_found', 404);
    propertyId = prop;
  } else {
    if (typeof body.uid !== 'string' || !body.uid.trim() || body.uid.length > 300) return fail('bad_stay', 400);
    stay = await deps.stay(body.uid.trim());
    if (!stay) return fail('stay_not_found', 404);
    guestId = stay.guestId; propertyId = stay.propertyId;
  }
  if (!(await ops.canManage(propertyId))) return fail('staff_access_denied', 403); // owner/admin of THIS property, every action
  if (!guestId) return fail('no_guest_record', 409);
  const g = await ops.loadGuest(guestId);
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
    // A runaway page or a shared login cannot run the paid model in a loop. Fails closed when the count cannot be read.
    const used = await deps.recentReads().catch(() => Infinity);
    if (used + decoded.length + (text ? 1 : 0) > MAX_READS_PER_HOUR) return fail('too_many_reads', 429);
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
  if (action === 'replace_id' || action === 'remove_id') return photo(action, body, g, ops, deps);
  return save(body, g, ops, deps);
}

type Saved = { what: string; ok: boolean; reason?: string };

/** The reason written to the history rows: the person's own (3 to 500 characters) or the default. Anything else is null (refused). */
export function cleanReason(v: unknown): string | null {
  if (v == null || v === '') return REASON;
  const s = String(v).replace(CTRL, ' ').replace(/\s+/g, ' ').trim();
  return typeof v === 'string' && s.length >= 3 && s.length <= 500 ? s : null;
}
const asVersion = (v: unknown): number | null | 'bad' => v == null ? null : Number.isInteger(v) && (v as number) >= 1 ? (v as number) : 'bad';

// deno-lint-ignore no-explicit-any
async function save(body: any, g: OnFile, ops: Ops, deps: Deps): Promise<Response> {
  // Every field is checked again here: the sheet is editable, so nothing from the client is trusted as the model's clean output.
  const phone = body.phone == null || body.phone === '' ? null : cleanPhone(body.phone);
  const email = body.email == null || body.email === '' ? null : normalizeEmail(body.email);
  // Guest count and nationality are display-only in the sheet: no safe existing write path, so they are never saved (s77 ruling).
  if (body.guests != null || body.nationality != null) return fail('not_saved_field', 400);
  if ((body.phone && !phone) || (body.email && !email)) return fail('bad_field', 400);
  // s82 G, all optional. Absent, null or empty means "not sent". Preferences are ADDED to what is on file and tags are merged in; a
  // removal or a rewrite goes through the profile editor (save_guest_profile_v1 with a version), never through this reader's save.
  const reason = cleanReason(body.reason), ver = asVersion(body.expected_version);
  if (!reason) return fail('bad_reason', 400);
  if (ver === 'bad') return fail('bad_field', 400);
  const sent = (v: unknown) => v != null && v !== '' && !(Array.isArray(v) && !v.length);
  const prefs = sent(body.stay_preferences) ? (typeof body.stay_preferences === 'string' ? cleanPreferencesSave(body.stay_preferences) : null) : null;
  const birthday = sent(body.birthday) ? cleanBirthday(body.birthday) : null;
  const tagList = sent(body.tags) ? (Array.isArray(body.tags) && body.tags.length <= 20 ? cleanTags(body.tags, 20) : null) : [];
  if ((sent(body.stay_preferences) && !prefs) || (sent(body.birthday) && !birthday) || !tagList || (sent(body.tags) && tagList.length !== new Set((body.tags as unknown[]).map((t) => String(t ?? '').replace(/\s+/g, ' ').trim().toLowerCase())).size)) return fail('bad_field', 400);
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
  if (!phone && !email && !companions.length && !photos.length && !prefs && !birthday && !tagList.length) return fail('empty', 400);

  const out: Saved[] = [];
  const err = (r: RpcOut) => r.error ? (r.error.code === '42501' ? 'denied' : r.error.code === '40001' ? 'changed' : 'save_failed') : null;
  const list = [...g.companions];
  const exact = (a: string, b: string) => a.trim().replace(/\s+/g, ' ').toLowerCase() === b.trim().replace(/\s+/g, ' ').toLowerCase();
  // loose: a companion's own ID may match a slightly different spelling. The guest's OWN ID never does: a loose match such as
  // "Ana Reyes" for "Ana Maria Reyes" could be another person, and staff_primary_id_path_v1 would then show that person's photo
  // as the guest's. Known limit: an exact namesake on the same guest (father and son, both "Jose Cruz") shares the row, the same
  // way the database's own name match does; staff fix that in the dashboard.
  const companionFor = async (name: string, loose = true): Promise<{ id: string } | string> => {
    const hit = list.find((c) => exact(name, c.name) || (loose && sameName(name, c.name)));
    if (hit) return { id: hit.id };
    const r = await ops.saveCompanion(g.guestId, null, { name }, reason);
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
    // The guest's own ID goes on a companion row named exactly as the guest record (exact match or a new row, never a loose
    // match), so the staff card shows it first (staff_primary_id_path_v1 orders an exact name match first).
    const c = own ? await companionFor(g.name, false) : await companionFor(p.name);
    if (typeof c === 'string') { out.push({ what: 'id_photo', ok: false, reason: c }); continue; }
    const path = `${c.id}/${deps.uuid()}.${p.ext}`;
    if (await ops.upload(path, p.bytes, p.mime)) { out.push({ what: 'id_photo', ok: false, reason: 'upload_failed' }); continue; }
    const linked = await ops.saveCompanion(g.guestId, c.id, { id_photo_path: path, id_type: p.idType }, reason);
    if (err(linked)) { await ops.remove(path).catch(() => null); out.push({ what: 'id_photo', ok: false, reason: err(linked)! }); continue; }
    out.push({ what: 'id_photo', ok: true }); anyPhoto = true;
    if (own) ownType = p.idType;
  }

  const patch: Record<string, unknown> = {};
  if (phone && phone !== g.phone) patch.contact_number = phone;
  if (anyPhoto && !g.idOnFile) patch.id_on_file = true;
  if (ownType) patch.id_type = ownType;
  if (prefs) {
    const have = (g.stayPreferences ?? '').trim();
    const next = have && have.toLowerCase().includes(prefs.toLowerCase()) ? have : have ? `${have}
${prefs}` : prefs;
    if (next !== have) { if (next.length > 4000) return fail('bad_field', 400); patch.stay_preferences = next; }
  }
  if (birthday && birthday !== g.birthday) patch.birthday = birthday;
  if (tagList.length) {
    const have = (g.tags ?? []).map((t) => t.trim().toLowerCase()), merged = [...(g.tags ?? []), ...tagList.filter((t) => !have.includes(t))];
    if (merged.length > have.length) patch.tags = merged;
  }
  if (Object.keys(patch).length) {
    const r = await ops.saveProfile(g.guestId, patch, ver ?? g.version, reason);
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

/** Replace or remove ONE companion's ID photo (s82 G). The old object is not deleted here: the database's own release trigger queues it
 *  for the existing purge job (guest_companions_release_photo), so a failed step can never leave a row pointing at a missing file. */
// deno-lint-ignore no-explicit-any
async function photo(action: 'replace_id' | 'remove_id', body: any, g: OnFile, ops: Ops, deps: Deps): Promise<Response> {
  const reason = cleanReason(body.reason);
  if (!reason) return fail('bad_reason', 400);
  if (typeof body.companion_id !== 'string' || !UUID.test(body.companion_id)) return fail('bad_companion', 400);
  const comp = g.companions.find((c) => c.id.toLowerCase() === body.companion_id.toLowerCase());
  if (!comp) return fail('companion_not_found', 404); // not a person on THIS guest's record
  const err = (r: RpcOut) => r.error ? (r.error.code === '42501' ? 'denied' : r.error.code === '40001' ? 'changed' : 'save_failed') : null;
  if (action === 'remove_id') {
    if (!comp.hasPhoto) return json({ ok: true, saved: [{ what: 'id_photo_removed', ok: true }] }); // already gone: nothing to do
    const r = await ops.saveCompanion(g.guestId, comp.id, { id_photo_path: null }, reason);
    const e = err(r);
    deps.log(JSON.stringify({ fn: 'staff_guest_details', action, ok: !e }));
    return e ? json({ ok: false, saved: [{ what: 'id_photo_removed', ok: false, reason: e }] }, 207) : json({ ok: true, saved: [{ what: 'id_photo_removed', ok: true }] });
  }
  const d = decodeImage(body.image);
  if (typeof d === 'string') return fail(d, d === 'image_too_large' ? 413 : 400);
  const kind = sniffImage(d.bytes), clean = kind ? stripMetadata(d.bytes, kind.ext) : null;
  if (!kind || !clean) return fail('bad_image', 400);
  const path = `${comp.id}/${deps.uuid()}.${kind.ext}`;
  if (await ops.upload(path, clean, kind.mime)) return json({ ok: false, saved: [{ what: 'id_photo', ok: false, reason: 'upload_failed' }] }, 207);
  const patch: Record<string, unknown> = { id_photo_path: path };
  if (body.id_type != null) patch.id_type = toIdType(body.id_type);
  const linked = await ops.saveCompanion(g.guestId, comp.id, patch, reason);
  if (err(linked)) { await ops.remove(path).catch(() => null); deps.log(JSON.stringify({ fn: 'staff_guest_details', action, ok: false })); return json({ ok: false, saved: [{ what: 'id_photo', ok: false, reason: err(linked)! }] }, 207); }
  const out: Saved[] = [{ what: 'id_photo', ok: true }];
  if (!g.idOnFile) { const r = await ops.saveProfile(g.guestId, { id_on_file: true }, g.version, reason); out.push({ what: 'profile', ok: !err(r), ...(err(r) ? { reason: err(r)! } : {}) }); }
  deps.log(JSON.stringify({ fn: 'staff_guest_details', action, ok: out.every((x) => x.ok) }));
  return json({ ok: out.every((x) => x.ok), saved: out }, out.every((x) => x.ok) ? 200 : 207);
}
