// SPEC-42 s4b: guest-intake, the pure parts (no I/O). The guest form posts one multipart request: `token`, `people` (a JSON array) and
// `photo_<i>` for the i-th person. Rules mirror the staff side: names as in telegram-expense/guest.ts and photos as in telegram-expense
// sniffImage / admin-dashboard guests/validation.ts (parity test in validate.test.ts): JPEG/PNG/WebP by magic bytes, <= 10 MB, never SVG.
// No ID number, birthday or address is read, asked for or stored: the form has no such field and the RPC whitelist would refuse one.

export type IdType = 'passport' | 'drivers_license' | 'national_id' | 'other';
export const ID_TYPES: readonly IdType[] = ['passport', 'drivers_license', 'national_id', 'other'];
export const MAX_PHOTO_BYTES = 10 * 1024 * 1024;
export const MAX_BODY_BYTES = 32 * 1024 * 1024;
export const MAX_PEOPLE = 12;
export const DAILY_PHOTOS = 12;
export const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;

const titleCase = (s: string) => s.toLowerCase().replace(/(^|[\s'-])(\p{L})/gu, (_m, a, b) => a + b.toUpperCase());

/** A person's name, or null. Letters, spaces, . ' - only; 4+ digits in a row (an ID number) rejects it; all-caps or all-lower becomes Title Case. */
export function cleanName(v: unknown): string | null {
  const raw = String(v ?? '');
  if (/\d{4,}/.test(raw)) return null;
  const s = raw.replace(/[^\p{L}\s.'-]/gu, '').replace(/\s+/g, ' ').trim();
  if (s.length < 2 || s.length > 80 || !/\p{L}{2}/u.test(s)) return null;
  return s === s.toUpperCase() || s === s.toLowerCase() ? titleCase(s) : s;
}

/** A mobile number as digits with an optional leading +, 7-15 digits (a guest may be from anywhere); empty is no number; junk is false. */
export function cleanContact(v: unknown): string | null | false {
  const s = String(v ?? '').replace(/[\s\-().]/g, '');
  if (!s) return null;
  return /^[+]?[0-9]{7,15}$/.test(s) ? s : false;
}

/** The first bytes decide the type; the bucket accepts only these three. Same rule as telegram-expense/guest.ts sniffImage. */
export function sniffImage(b: Uint8Array): { ext: 'jpg' | 'png' | 'webp'; mime: string } | null {
  if (b.length > MAX_PHOTO_BYTES || b.length < 12) return null;
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return { ext: 'jpg', mime: 'image/jpeg' };
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return { ext: 'png', mime: 'image/png' };
  if (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) return { ext: 'webp', mime: 'image/webp' };
  return null;
}

export type Person = { name: string; idType: IdType | null; contact: string | null; self: boolean; photo: Uint8Array | null };
export type Parsed = { ok: true; token: string; people: Person[] } | { ok: false; error: 'bad_request' | 'invalid_people' | 'photo_too_large' };

/** The multipart body to people. Anything off is refused whole: a half-read form is never saved. */
export async function parseSubmission(form: FormData): Promise<Parsed> {
  const token = form.get('token');
  if (typeof token !== 'string' || !TOKEN_RE.test(token)) return { ok: false, error: 'bad_request' };
  let raw: unknown;
  try { raw = JSON.parse(String(form.get('people') ?? '')); } catch { return { ok: false, error: 'invalid_people' }; }
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > MAX_PEOPLE) return { ok: false, error: 'invalid_people' };
  const people: Person[] = [];
  let selves = 0;
  for (let i = 0; i < raw.length; i++) {
    const p = (raw[i] ?? {}) as Record<string, unknown>;
    const name = cleanName(p.name);
    const contact = cleanContact(p.contact);
    const blank = p.id_type === undefined || p.id_type === null || p.id_type === '';
    const idType = blank ? null : (ID_TYPES as readonly unknown[]).includes(p.id_type) ? p.id_type as IdType : false;
    if (!name || contact === false || idType === false) return { ok: false, error: 'invalid_people' };
    if (p.self === true) selves++;
    const file = form.get(`photo_${i}`);
    let photo: Uint8Array | null = null;
    if (file && typeof file !== 'string') {
      if (file.size > MAX_PHOTO_BYTES) return { ok: false, error: 'photo_too_large' };
      if (file.size > 0) photo = new Uint8Array(await file.arrayBuffer());
    }
    people.push({ name, idType, contact, self: p.self === true, photo });
  }
  if (selves > 1) return { ok: false, error: 'invalid_people' };
  return { ok: true, token, people };
}
