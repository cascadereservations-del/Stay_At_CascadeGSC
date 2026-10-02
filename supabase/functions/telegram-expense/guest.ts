// Session 67b: Telegram /guest intake - the pure parts (no I/O, unit-tested in guest.test.ts). guest-flow.ts owns the calls.
// Scope (D-118, D-126, D-128): human-initiated, one photo at a time, confirm before save. The reader returns a NAME and an ID TYPE
// from an ID photo, or guest names and a mobile number from a chat screenshot. It never returns an ID number, birthday or
// address, and this file drops anything that looks like one even if the model sends it.
import { monthDay } from '../_shared/cascade-core/brownout.ts';

export type IdType = 'passport' | 'drivers_license' | 'national_id' | 'other';
export type GuestRead =
  | { kind: 'id'; name: string; idType: IdType }
  | { kind: 'chat'; names: string[]; phone: string | null }
  | { kind: 'other' };

/** What the picker knows about a guest (telegram_guest_candidates_v1). */
export type Candidate = {
  guest_id: string; name: string; checkin: string | null; checkout: string | null; last_stay: string | null;
  id_on_file: boolean; has_contact: boolean; companions: string[];
};

export const GUEST_PROMPT = `You read ONE photo for a small guesthouse host in the Philippines. Return JSON only:
{"kind":"id"|"chat"|"other","name":string|null,"id_type":"passport"|"drivers_license"|"national_id"|"other"|null,"names":[string],"phone":string|null}
- kind "id": a passport, driver's licence, national ID or other government or professional ID card. Fill "name" with the holder's full name written as given names then surname (for example "Maria Santos Cruz"), and "id_type".
- kind "chat": a screenshot of a message conversation. Fill "names" with the full names of the people the guest says will stay or are staying (not the host), and "phone" with a Philippine mobile number the guest typed, exactly as written.
- kind "other": anything else, or not readable.
STRICT: never output an ID, passport, licence or card number, a birth date, an address, a signature or any other digits. The only digits you may output are the phone number of a chat. If you are unsure, use kind "other".`;

const ID_TYPES = new Set<string>(['passport', 'drivers_license', 'national_id', 'other']);

/** Map whatever the model says to the four types the database accepts. */
export function toIdType(v: unknown): IdType {
  const s = String(v ?? '').toLowerCase().replace(/[^a-z]/g, '');
  if (ID_TYPES.has(s)) return s as IdType;
  if (s.includes('passport')) return 'passport';
  if (s.includes('driver') || s.includes('licen')) return 'drivers_license';
  if (s.includes('national') || s.includes('philsys') || s.includes('umid')) return 'national_id';
  return 'other';
}

const titleCase = (s: string) => s.toLowerCase().replace(/(^|[\s'-])(\p{L})/gu, (_m, a, b) => a + b.toUpperCase());

/** A person's name from the model, or null. Letters, spaces, . ' - only; 4+ digits in a row (an ID number) rejects the whole name;
 *  "CRUZ, MARIA SANTOS" becomes "Maria Santos Cruz"; all-caps becomes Title Case. */
export function cleanName(v: unknown): string | null {
  const raw = String(v ?? '');
  if (/\d{4,}/.test(raw)) return null;
  let s = raw.replace(/[^\p{L}\s.,'-]/gu, '').replace(/\s+/g, ' ').trim();
  const comma = /^([^,]+),\s*([^,]+)$/.exec(s);
  if (comma) s = `${comma[2].trim()} ${comma[1].trim()}`;
  s = s.replace(/,/g, '').replace(/\s+/g, ' ').trim();
  if (s.length < 2 || s.length > 80 || !/\p{L}{2}/u.test(s)) return null;
  return s === s.toUpperCase() || s === s.toLowerCase() ? titleCase(s) : s;
}

/** A Philippine mobile number as 09XXXXXXXXX, or null. Accepts 09.., 9.. (10 digits), 639.. and +639.. with spaces or dashes. */
export function normalizePhone(v: unknown): string | null {
  const d = String(v ?? '').replace(/[\s\-().]/g, '').replace(/^\+/, '');
  const m = /^(?:63|0)?(9\d{9})$/.exec(d);
  return m ? `0${m[1]}` : null;
}

/** Parse the model's text into a GuestRead. Anything unexpected is kind "other": nothing is saved from a guess. */
export function parseGuestRead(raw: string): GuestRead {
  let j: any;
  try {
    const t = String(raw ?? '').replace(/^```(?:json)?\s*|\s*```$/g, '').trim();
    j = JSON.parse(t.slice(t.indexOf('{'), t.lastIndexOf('}') + 1));
  } catch { return { kind: 'other' }; }
  if (j?.kind === 'id') {
    const name = cleanName(j.name);
    return name ? { kind: 'id', name, idType: toIdType(j.id_type) } : { kind: 'other' };
  }
  if (j?.kind === 'chat') {
    const names = [...new Set((Array.isArray(j.names) ? j.names : []).map(cleanName).filter((n: string | null): n is string => !!n))].slice(0, 6) as string[];
    const phone = normalizePhone(j.phone);
    return names.length || phone ? { kind: 'chat', names, phone } : { kind: 'other' };
  }
  return { kind: 'other' };
}

const tokens = (s: string) => s.toLowerCase().replace(/[.,']/g, ' ').split(/[\s-]+/).filter(Boolean);
/** The same person? Every full word (not an initial) of the shorter name appears in the longer one, and at least two do. */
export function sameName(a: string, b: string): boolean {
  const ta = tokens(a).filter((t) => t.length > 1), tb = tokens(b).filter((t) => t.length > 1);
  const [s, l] = ta.length <= tb.length ? [ta, tb] : [tb, ta];
  return s.length >= 2 && s.every((t) => l.includes(t));
}

export const idLabel = (t: IdType) => ({ passport: 'passport', drivers_license: "driver's license", national_id: 'national ID', other: 'ID' })[t];
const poss = (n: string) => (/s$/i.test(n) ? `${n}'` : `${n}'s`);

/** What Save will do, decided once at the confirm card and replayed at the tap. */
export type Plan =
  | { kind: 'id'; guestId: string; guestName: string; name: string; idType: IdType; own: boolean; existing: boolean; companionName: string }
  | { kind: 'chat'; guestId: string; guestName: string; phone: string | null; replacesPhone: boolean; newNames: string[]; knownNames: string[] };

/** The decision from a read and the guest it is for; null when there is nothing to save. */
export function planFor(read: GuestRead, g: Candidate): Plan | null {
  if (read.kind === 'id') {
    const own = sameName(read.name, g.name);
    const known = g.companions.find((c) => sameName(read.name, c));
    return { kind: 'id', guestId: g.guest_id, guestName: g.name, name: read.name, idType: read.idType, own, existing: !!known, companionName: known ?? read.name };
  }
  if (read.kind === 'chat') {
    const knownNames: string[] = [], newNames: string[] = [];
    for (const n of read.names) (sameName(n, g.name) || g.companions.some((c) => sameName(n, c)) ? knownNames : newNames).push(n);
    if (!read.phone && !newNames.length) return null;
    return { kind: 'chat', guestId: g.guest_id, guestName: g.name, phone: read.phone, replacesPhone: !!read.phone && g.has_contact, newNames, knownNames };
  }
  return null;
}

/** The body of the confirm card. Plain sentences, what will change first, who must act, then the detail lines. */
export function confirmBody(p: Plan, esc: (s: string) => string = (s) => s): string[] {
  if (p.kind === 'id') {
    const what = p.own
      ? `${esc(poss(p.guestName))} own ${idLabel(p.idType)} photo to their guest record`
      : `${esc(poss(p.name))} ${idLabel(p.idType)} photo as a companion of ${esc(p.guestName)}`;
    const extra = p.existing ? `• ${esc(p.companionName)} is already a companion, so the photo is added to that entry.` : p.own ? '• It shows in the dashboard under Companions.' : null;
    return [`Nothing is saved yet. Save ${what} and mark ID on file?`, '', '• The photo goes into the private ID store, not into this chat.', '• No ID number is read or saved.',
      ...(extra ? [extra] : []), '', 'Do: tap Save if this is right.'];
  }
  const lines: string[] = [];
  if (p.phone) lines.push(`• Phone ${p.phone}${p.replacesPhone ? ' (replaces the number on file)' : ''}`);
  if (p.newNames.length) lines.push(`• Add as companions: ${p.newNames.map(esc).join(', ')}`);
  if (p.knownNames.length) lines.push(`• Already on the record, left as they are: ${p.knownNames.map(esc).join(', ')}`);
  return [`Nothing is saved yet. Save these for ${esc(p.guestName)} from the chat screenshot?`, '', ...lines, '', 'Do: tap Save if this is right.'];
}

/** One line per label for the picker button: name and the stay it belongs to. */
export function pickLabel(c: Candidate, today: string): string {
  const stay = c.checkin && c.checkout
    ? (c.checkin <= today && today < c.checkout ? 'in house' : `${monthDay(c.checkin)}-${monthDay(c.checkout)}`)
    : c.last_stay ? `last stay ${monthDay(c.last_stay)}` : '';
  const flag = c.id_on_file ? ' ✓ID' : '';
  return `${c.name}${stay ? ` · ${stay}` : ''}${flag}`.slice(0, 60);
}

/** The first bytes decide the type; Telegram photos are JPEG, but the bucket accepts only these three. */
export function sniffImage(b: Uint8Array): { ext: 'jpg' | 'png' | 'webp'; mime: string } | null {
  if (b.length > 10 * 1024 * 1024 || b.length < 12) return null;
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return { ext: 'jpg', mime: 'image/jpeg' };
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return { ext: 'png', mime: 'image/png' };
  if (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) return { ext: 'webp', mime: 'image/webp' };
  return null;
}

/** Callback data: gst:<pick|other|save|cancel>:<pending uuid>[:<index>]. Under 64 bytes (the longest is 47). */
export function parseGuestTap(data: string): { act: 'pick' | 'other' | 'save' | 'cancel'; pid: string; i: number } | null {
  const m = /^gst:(pick|other|save|cancel):([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?::(\d{1,2}))?$/i.exec(String(data ?? ''));
  if (!m || (m[1] === 'pick') !== (m[3] !== undefined)) return null;
  return { act: m[1] as 'pick' | 'other' | 'save' | 'cancel', pid: m[2].toLowerCase(), i: m[3] ? Number(m[3]) : -1 };
}
