// Session 72, SPEC-42 section 2 (D-290 item 5): Airbnb guest-message e-mails -> a phone number and companion names for the /guest review card.
// Pure parts only (no I/O, unit-tested in message.test.ts); index.ts owns the calls. The guest's text is read in memory and NEVER stored or logged:
// the event log keeps counts and a match flag. Nothing here replies to a guest.
// ponytail: deterministic parser only. SPEC-42 allows one routine-tier model call when the lines do not parse; add it after a real e-mail shows a miss
// (it would send the guest's text to a provider, so it needs Lloyd's yes first).
import { withHeader } from '../_shared/cascade-core/format.ts';
import { maskMoney } from '../_shared/ops-money.ts'; // D-306: nothing in the OPS card is money; the masker is the backstop
import { type Candidate, cleanName, confirmBody, normalizePhone, type Plan, planFor } from '../telegram-expense/guest.ts';

export const MAX_TEXT = 2000;
const MAX_NAMES = 6;

/** The guest's own words: quoted history, "On ... wrote:" tails and signatures cut off, capped at MAX_TEXT. */
export function stripQuoted(raw: unknown): string {
  const out: string[] = [];
  for (const line of String(raw ?? '').slice(0, MAX_TEXT * 4).split(/\r?\n/)) {
    if (/^\s*>/.test(line)) continue;
    if (/^\s*(?:on .{5,80} wrote:|-{2,}\s*(?:original message|forwarded)|from:\s.+@|sent from my )/i.test(line)) break;
    out.push(line);
  }
  return out.join('\n').trim().slice(0, MAX_TEXT);
}

const PHONE = /(?<![\d+])(?:\+?63|0)[\s-]?9\d{2}[\s-]?\d{3}[\s-]?\d{4}(?!\d)/g;
const PHONE_CUE = /\b(?:contact|cp|cell|mobile|phone|number|no\.?|viber|whatsapp|whats\s?app|call|text|reach)\b[^\n\d+]{0,25}$/i;
const PAY_CUE = /\b(?:gcash|maya|account|acct)\b/i; // a payment account number is not the guest's contact, unless a contact cue sits beside it
const HOST_PHONES = new Set(['09560115744']); // the property's payment number (the one ops-money.ts hides): a guest quoting it is not giving theirs

/** The guest's Philippine mobile as 09XXXXXXXXX. Two different numbers: only one with a "my number" style cue before it counts, else none. */
export function findPhone(text: string): string | null {
  const found: Array<{ n: string; cued: boolean }> = [];
  for (const m of text.matchAll(PHONE)) {
    const n = normalizePhone(m[0]);
    if (!n || HOST_PHONES.has(n)) continue;
    const before = text.slice(Math.max(0, (m.index ?? 0) - 40), m.index ?? 0), cued = PHONE_CUE.test(before);
    if (PAY_CUE.test(before) && !cued) continue;
    found.push({ n, cued });
  }
  const distinct = [...new Set(found.map((f) => f.n))];
  if (distinct.length <= 1) return distinct[0] ?? null;
  const cued = [...new Set(found.filter((f) => f.cued).map((f) => f.n))];
  return cued.length === 1 ? cued[0] : null;
}

// A name list needs a cue: "companions: ...", "kasama ko si ...", "guests are ...", or two or more numbered / bulleted lines that each look like a name.
const CUE = /\b(?:companions?|kasama(?:ng|n)?(?:\s+(?:ko|namin))?|kasamahan|names?(?:\s+of\s+(?:my\s+|the\s+)?(?:guests?|companions?|kasama))?|(?:other\s+)?guests?\s+(?:are|will\s+be|po\s+ay)|with\s+me(?:\s+(?:are|is))?|bisita)\b[\s:,-]*(?:(?:are|is|ay|si|sina|na\s+sina|ni)\b[\s:,-]*)?(.*)$/i;
const SPLIT = /\s*(?:,|;|&|\/|\+|\band\b|\bat\b|\bsi\b|\bsina\b|\bni\b)\s*/i;
const BULLET = /^\s*(?:\d{1,2}[.)]|[-•*])\s*(.+)$/;
const STOP = new Set(['and', 'at', 'the', 'my', 'our', 'we', 'us', 'is', 'are', 'will', 'be', 'wife', 'husband', 'kids', 'kid', 'son', 'daughter', 'friends', 'friend', 'family', 'mom', 'dad', 'mother', 'father', 'adults', 'adult', 'children', 'child', 'baby', 'guests', 'guest', 'total', 'pax', 'persons', 'people', 'check', 'in', 'out', 'arrive', 'arrival', 'around', 'time', 'am', 'pm', 'her', 'his', 'their', 'sister', 'brother', 'cousin', 'partner', 'asawa', 'anak', 'lola', 'lolo', 'tita', 'tito', 'kuya', 'ate', 'ako', 'kami', 'sila', 'po', 'opo', 'thank', 'thanks', 'you', 'hello', 'hi', 'to', 'of', 'for', 'with', 'also', 'may', 'ang', 'ng', 'mga']);

/** One person's name or null: 2-4 words of letters (. ' - allowed), none a stop word, via the same cleaner the /guest reader uses. */
function asName(s: string): string | null {
  const t = s.replace(/\([^)]*\)/g, ' ').replace(/\s+/g, ' ').trim().replace(/[.!?:]+$/, '');
  if (!/^[\p{L}][\p{L}.'-]*(?: [\p{L}][\p{L}.'-]*){1,3}$/u.test(t)) return null;
  const words = t.toLowerCase().split(' ');
  if (words.some((w) => STOP.has(w.replace(/[.]/g, ''))) || words.filter((w) => w.replace(/[.]/g, '').length >= 2).length < 2) return null;
  return cleanName(t);
}

export function findNames(text: string): string[] {
  const names: string[] = [];
  const add = (chunk: string) => { for (const p of chunk.replace(/\([^)]*\)/g, ' ').split(SPLIT)) { const n = asName(p); if (n) names.push(n); } };
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const cue = CUE.exec(lines[i]);
    if (cue) {
      if (cue[1].trim()) add(cue[1].split(/[!?]|(?<=\p{L}{2})\.(?:\s|$)/u)[0]); // the list ends where the sentence does ("D." initials stay)
      else for (let j = i + 1; j < lines.length; j++) { const b = BULLET.exec(lines[j]) ?? (lines[j].trim() && j === i + 1 ? [lines[j], lines[j]] : null); if (!b) break; add(b[1]); }
    }
  }
  if (!names.length) { // no header cue: two or more bullet lines that are all names
    const run = lines.map((l) => BULLET.exec(l)?.[1]).filter((x): x is string => !!x).map(asName);
    if (run.length >= 2 && run.every(Boolean)) names.push(...(run as string[]));
  }
  return [...new Set(names)].slice(0, MAX_NAMES);
}

export function extract(text: string): { phone: string | null; names: string[] } {
  const t = stripQuoted(text);
  return { phone: findPhone(t), names: findNames(t) };
}

// ---- matching ---------------------------------------------------------------------------------------------------------------------------------
export type Stay = { guest_id: string | null; guest_name: string | null; confirmation_code: string; checkin_date: string | null; checkout_date: string | null };

export const fold = (s: unknown) => String(s ?? '').normalize('NFD').replace(/\p{M}/gu, '').toLowerCase().trim();
const firstWord = (s: unknown) => fold(s).split(/\s+/)[0] ?? '';
/** The booker's own name (folded first + last word): a guest listing themselves is not a companion. */
const isOwn = (n: string, own: string) => { const a = fold(n).split(/\s+/), b = fold(own).split(/\s+/); return a[0] === b[0] && a[a.length - 1] === b[b.length - 1]; };

/** The one confirmed stay this e-mail is about, or null (none, or more than one: no card). `stays` are confirmed rows from [today-2, today+120] days. */
export function matchStay(stays: Stay[], ev: { confirmation_code?: string; guest_first_name?: string; checkin_date?: string; checkout_date?: string }): Stay | null {
  const code = String(ev.confirmation_code ?? '').trim().toUpperCase();
  if (code) { const hit = stays.filter((s) => s.confirmation_code.toUpperCase() === code); return hit.length === 1 && hit[0].guest_id ? hit[0] : null; }
  const first = firstWord(ev.guest_first_name);
  if (!first) return null;
  const hit = stays.filter((s) => firstWord(s.guest_name) === first
    && (!ev.checkin_date || s.checkin_date === ev.checkin_date) && (!ev.checkout_date || s.checkout_date === ev.checkout_date));
  return hit.length === 1 && hit[0].guest_id ? hit[0] : null;
}

/** What Save would do: phone dropped when it equals the one on file, names already on the record move to "left as they are". Null = nothing new, no card. */
export function buildPlan(read: { phone: string | null; names: string[] }, g: Candidate, phoneOnFile: string | null): Plan | null {
  const phone = read.phone && normalizePhone(phoneOnFile) === read.phone ? null : read.phone;
  const plan = planFor({ kind: 'chat', names: read.names.filter((n) => !isOwn(n, g.name)), phone }, g);
  if (!plan || plan.kind !== 'chat') return null;
  return { ...plan, via: 'airbnb' };
}

// ---- the card and the handler -----------------------------------------------------------------------------------------------------------------
export type MessageEvent = {
  gmail_message_id: string; email_date: string; guest_first_name?: string; confirmation_code?: string;
  checkin_date?: string; checkout_date?: string; text?: string;
};
export type MessageDeps = {
  db: any; propertyId: string; opsChatId: number | null; today: string;
  /** Post the card; true when Telegram accepted it. */
  post: (chatId: number, text: string, replyMarkup: unknown) => Promise<boolean>;
  esc: (s: string) => string;
};
/** What goes in the event log: counts and a match flag only. */
export type MessageLog = { guest_first_name: string | null; confirmation_code: string | null; matched: boolean; has_phone: boolean; names_count: number; carded: boolean };

/** The event-log row for a message event: who it names and when, never the text or the subject. Null (event skipped) when it carries no text. */
export function logRow(ev: MessageEvent, propertyId: string) {
  if (typeof ev.text !== 'string') return null;
  return { property_id: propertyId, gmail_message_id: ev.gmail_message_id, email_type: 'message', email_date: ev.email_date, subject: null,
    raw_payload: { guest_first_name: ev.guest_first_name ?? null, confirmation_code: ev.confirmation_code ?? null } };
}

/** Constant-time compare of the shared secret. An unset or empty expected value never matches. */
export function secretMatches(given: string | null, expected: string | null | undefined): boolean {
  if (!expected || !given) return false;
  const enc = new TextEncoder(), a = enc.encode(given), b = enc.encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

/** Message events need the shared secret; the three old types pass untouched. `refused` counts the message events dropped. */
export function gateMessages<T extends { email_type?: string }>(events: T[], given: string | null, expected: string | null | undefined): { events: T[]; refused: number } {
  if (secretMatches(given, expected)) return { events, refused: 0 };
  const kept = events.filter((e) => e?.email_type !== 'message');
  return { events: kept, refused: events.length - kept.length };
}

const DAY = 86_400_000;
const addDays = (d: string, n: number) => new Date(Date.parse(`${d}T00:00:00Z`) + n * DAY).toISOString().slice(0, 10);
const CARD_TTL_H = 72;

/** The OPS card text. Every line goes through maskMoney: a card for a phone number and names has no business showing an amount. */
export function cardText(plan: Plan, emailDate: string, esc: (s: string) => string): string {
  const b = confirmBody(plan, esc);
  b.splice(b.lastIndexOf(''), 0, `From the Airbnb message of ${String(emailDate).slice(0, 10)}.`);
  return withHeader('guest', 'details from Airbnb chat', b.map(maskMoney).join('\n'));
}

/** Read one message event; post at most one review card. Never writes guest data (the Save tap does) and never contacts the guest. */
export async function handleMessage(d: MessageDeps, ev: MessageEvent): Promise<MessageLog> {
  const read = extract(ev.text ?? '');
  const log: MessageLog = { guest_first_name: ev.guest_first_name ?? null, confirmation_code: ev.confirmation_code ?? null, matched: false, has_phone: !!read.phone, names_count: read.names.length, carded: false };
  if (!read.phone && !read.names.length) return log;

  let q = d.db.from('airbnb_reservations').select('guest_id,guest_name,confirmation_code,checkin_date,checkout_date')
    .eq('property_id', d.propertyId).eq('status', 'confirmed');
  q = ev.confirmation_code ? q.eq('confirmation_code', String(ev.confirmation_code).trim().toUpperCase()) : q.gte('checkin_date', addDays(d.today, -2)).lte('checkin_date', addDays(d.today, 120));
  const { data: stays } = await q;
  const stay = matchStay((stays ?? []) as Stay[], ev);
  if (!stay?.guest_id) return log;
  log.matched = true;

  const [{ data: g }, { data: prof }, { data: comps }] = await Promise.all([
    d.db.from('guests').select('name').eq('id', stay.guest_id).maybeSingle(),
    d.db.from('guest_profile_details').select('contact_number').eq('guest_id', stay.guest_id).maybeSingle(),
    d.db.from('guest_companions').select('name').eq('guest_id', stay.guest_id),
  ]);
  if (!g?.name) return log;
  const cand: Candidate = { guest_id: stay.guest_id, name: g.name, checkin: stay.checkin_date, checkout: stay.checkout_date, last_stay: null, id_on_file: false,
    has_contact: String(prof?.contact_number ?? '').trim() !== '', companions: ((comps ?? []) as Array<{ name: string }>).map((c) => c.name) };
  const plan = buildPlan(read, cand, prof?.contact_number ?? null);
  if (!plan || !d.opsChatId) return log;

  // One open card per guest per 24 h: an unanswered card already says it.
  const { data: open } = await d.db.from('telegram_pending').select('id').eq('chat_id', d.opsChatId).eq('kind', 'guest_save')
    .eq('payload->plan->>guestId', stay.guest_id).gt('created_at', new Date(Date.now() - DAY).toISOString()).gt('expires_at', new Date().toISOString()).limit(1);
  if ((open ?? []).length) return log;

  const { data: row } = await d.db.from('telegram_pending').insert({
    chat_id: d.opsChatId, kind: 'guest_save', payload: { from_id: null, from_name: 'Airbnb e-mail', file_id: '', plan },
    expires_at: new Date(Date.now() + CARD_TTL_H * 3_600_000).toISOString(),
  }).select('id').single();
  if (!row?.id) return log;
  const ok = await d.post(d.opsChatId, cardText(plan, ev.email_date, d.esc), { inline_keyboard: [[
    { text: '✅ Save', callback_data: `gst:save:${row.id}` }, { text: '❌ Cancel', callback_data: `gst:cancel:${row.id}` }]] });
  if (!ok) await d.db.from('telegram_pending').delete().eq('id', row.id); // a card nobody saw must not block the next one
  log.carded = ok;
  return log;
}
