// SPEC-42 s4b: guest-intake, the pure parts (no I/O). The guest form posts one multipart request: `people` (a JSON array; the token is the x-guest-token header) and
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

/** Drops location and camera metadata without re-encoding: JPEG APP1-APP15 (except APP14, the Adobe colour transform) and COM segments and anything after the end of the image, PNG eXIf/tEXt/zTXt/iTXt chunks, WebP EXIF and
 *  XMP chunks (RIFF size and the VP8X flags fixed). null when the structure does not parse, so a file we cannot clean is never stored. */
export function stripMetadata(b: Uint8Array, kind: 'jpg' | 'png' | 'webp'): Uint8Array | null {
  const out: number[] = [];
  const push = (from: number, to: number) => { for (let i = from; i < to; i++) out.push(b[i]); };
  if (kind === 'jpg') {
    if (b[0] !== 0xff || b[1] !== 0xd8) return null;
    out.push(0xff, 0xd8);
    let i = 2;
    while (i < b.length) {
      if (b[i] !== 0xff) return null;
      while (b[i + 1] === 0xff) i++; // fill bytes
      const m = b[i + 1];
      if (m === undefined) return null;
      if (m === 0xda) { // scan data: copy through the first FF D9 (it cannot occur inside entropy-coded data); trailers after it are dropped
        let e = i + 2;
        while (e + 1 < b.length && !(b[e] === 0xff && b[e + 1] === 0xd9)) e++;
        if (e + 1 >= b.length) return null;
        push(i, e + 2);
        return Uint8Array.from(out);
      }
      if (m === 0xd9) { out.push(0xff, 0xd9); return Uint8Array.from(out); }
      if (m === 0x01 || (m >= 0xd0 && m <= 0xd8)) { push(i, i + 2); i += 2; continue; }
      if (i + 4 > b.length) return null;
      const len = (b[i + 2] << 8) | b[i + 3];
      if (len < 2 || i + 2 + len > b.length) return null;
      if (!((m >= 0xe1 && m <= 0xef && m !== 0xee) || m === 0xfe)) push(i, i + 2 + len); // APP14 (Adobe colour transform) stays
      i += 2 + len;
    }
    return null; // no scan: not a whole image
  }
  if (kind === 'png') {
    push(0, 8);
    let i = 8;
    while (i + 12 <= b.length) {
      const len = ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) >>> 0;
      const type = String.fromCharCode(b[i + 4], b[i + 5], b[i + 6], b[i + 7]);
      if (i + 12 + len > b.length) return null;
      if (!['eXIf', 'tEXt', 'zTXt', 'iTXt'].includes(type)) push(i, i + 12 + len);
      i += 12 + len;
      if (type === 'IEND') return Uint8Array.from(out);
    }
    return null;
  }
  push(0, 12);
  let i = 12;
  while (i + 8 <= b.length) {
    const cc = String.fromCharCode(b[i], b[i + 1], b[i + 2], b[i + 3]);
    const len = (b[i + 4] | (b[i + 5] << 8) | (b[i + 6] << 16) | (b[i + 7] << 24)) >>> 0;
    const end = i + 8 + len + (len & 1);
    if (i + 8 + len > b.length) return null;
    if (cc !== 'EXIF' && cc !== 'XMP ') {
      const start = out.length;
      push(i, Math.min(end, b.length));
      if (cc === 'VP8X' && len >= 1) out[start + 8] &= ~0x0c; // no EXIF (0x08) or XMP (0x04) flag
    }
    i = end;
  }
  const size = out.length - 8;
  out[4] = size & 0xff; out[5] = (size >>> 8) & 0xff; out[6] = (size >>> 16) & 0xff; out[7] = (size >>> 24) & 0xff;
  return Uint8Array.from(out);
}

export type Person = { name: string; idType: IdType | null; contact: string | null; self: boolean; photo: Uint8Array | null };
export type Parsed = { ok: true; people: Person[] } | { ok: false; error: 'invalid_people' | 'photo_too_large' };

/** The multipart body to people. Anything off is refused whole: a half-read form is never saved. */
export async function parseSubmission(form: FormData): Promise<Parsed> {
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
  return { ok: true, people };
}
