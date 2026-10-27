// s99f (D-351): count by typed message or by photo of a handwritten count sheet. Pure parts only: read the text, read the vision
// JSON, match names to items, build the review card. No I/O, unit-tested in countsheet.test.ts. index.ts owns Telegram, vision and the RPC.
// deno-lint-ignore-file no-explicit-any
import { type Change, chunkLines, reviewLines } from './count.ts';
import { osa } from './T_nearmatch.ts';

export type StockItem = { id: string; name: string; unit: string; qty: number; reorder: number | null; controlled: boolean };
export type Row = { name: string; counted: number };

const T = String.raw`(?:\d+(?:\.\d+)?(?:\s+\d\/\d)?|\d\/\d)`;
const LINE_RE = new RegExp(String.raw`^(.*?[a-z)].*?)(?:\s*[:=]\s*|\s+[-–]\s*|\s+)(${T}(?:\s*\+\s*${T})*)$`, 'i');

/** "2", "1.5", "1/2", "1 1/2", "16+46". Halves and quarters only, two decimals at most. Anything else is null (unreadable), never a guess. */
export function parseNumber(s: unknown): number | null {
  let total = 0;
  for (const part of String(s ?? '').split('+')) {
    const m = /^\s*(?:(\d+(?:\.\d{1,2})?)(?:\s+(\d)\/(\d))?|(\d)\/(\d))\s*$/.exec(part);
    if (!m) return null;
    const num = m[3] ? Number(m[2]) : m[5] ? Number(m[4]) : 0;
    const den = m[3] ? Number(m[3]) : m[5] ? Number(m[5]) : 1;
    if ((m[3] || m[5]) && ((den !== 2 && den !== 4) || num >= den)) return null;
    total += (m[1] ? Number(m[1]) : 0) + num / den;
  }
  return Math.round(total * 100) / 100;
}

const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const DAY = 86_400_000;
const AS_OF_RE = /\bas\s+of\s+(?:(\d{1,2})\s+([a-z]{3,9})|([a-z]{3,9})\s+(\d{1,2}))(?:[ \t]*,?[ \t]*(\d{4}))?(?:[ \t]*,?[ \t]*(?:at[ \t]+)?(\d{1,2}):(\d{2})(?:[ \t]*([ap])\.?m\.?(?![a-z]))?)?/i;

/** Manila wall-clock parts to an ISO instant with +08:00, or null when it is not a real date. */
export function manilaIso(y: number, mo: number, d: number, h: number, mi: number): string | null {
  const c = new Date(Date.UTC(y, mo - 1, d, h, mi));
  if (c.getUTCFullYear() !== y || c.getUTCMonth() !== mo - 1 || c.getUTCDate() !== d || h > 23 || mi > 59) return null;
  const p = (n: number) => String(n).padStart(2, '0');
  return `${y}-${p(mo)}-${p(d)}T${p(h)}:${p(mi)}:00+08:00`;
}
/** The as-of window the database enforces: in the past, within 60 days. Returns the instant or null. */
export function inWindow(iso: string | null, nowMs: number): string | null {
  if (!iso) return null;
  const t = Date.parse(iso);
  return Number.isFinite(t) && t < nowMs && t >= nowMs - 60 * DAY ? iso : null;
}

/** "as of 16 Oct 8:21", "as of 16 Oct 2026, 08:21", "as of Oct 16 8:21pm". A missing year is this year, or last year when that would be in the future. */
export function parseAsOf(text: string, nowMs: number): { found: boolean; iso: string | null; rest: string } {
  const m = AS_OF_RE.exec(text);
  if (!m) return { found: false, iso: null, rest: text };
  const rest = text.slice(0, m.index) + ' ' + text.slice(m.index + m[0].length);
  const day = Number(m[1] ?? m[4]), mon = MONTHS.indexOf(String(m[2] ?? m[3]).slice(0, 3).toLowerCase()) + 1;
  if (!m[6] || mon < 1) return { found: true, iso: null, rest };
  let h = Number(m[6]);
  if (m[8]) { if (h < 1 || h > 12) return { found: true, iso: null, rest }; h = h % 12 + (m[8].toLowerCase() === 'p' ? 12 : 0); }
  const nowY = new Date(nowMs + 8 * 3_600_000).getUTCFullYear();
  let iso = manilaIso(m[5] ? Number(m[5]) : nowY, mon, day, h, Number(m[7]));
  if (iso && !m[5] && Date.parse(iso) >= nowMs) iso = manilaIso(nowY - 1, mon, day, h, Number(m[7]));
  return { found: true, iso: inWindow(iso, nowMs), rest };
}

export type ParsedText = { rows: Row[]; unreadable: string[]; asOf: string | null; asOfBad: boolean };

/** Does a Finance message start a typed count? "count ..." or "inventory ..." followed by something. */
export const isCountText = (t: string) => /^\s*(count|inventory)\b[\s:.\-]*\S/i.test(t);
export const isCountCaption = (c: unknown) => /^\s*(count|inventory)\b/i.test(String(c ?? ''));

export function parseCountText(text: string, nowMs: number): ParsedText {
  const a = parseAsOf(String(text ?? ''), nowMs);
  // a thousands comma (1,000) is part of the number, not a separator
  const body = a.rest.replace(/^\s*(count|inventory)\b[\s:.\-]*/i, '').replace(/(\d),(?=\d{3}\b)/g, '$1');
  const byName = new Map<string, Row>();
  const unreadable: string[] = [];
  for (const raw of body.split(/[\n;,]+/)) {
    const line = raw.trim();
    if (!line) continue;
    const m = LINE_RE.exec(line);
    const n = m ? parseNumber(m[2]) : null;
    if (!m || n === null) { unreadable.push(line.slice(0, 40)); continue; }
    byName.set(m[1].trim().toLowerCase(), { name: m[1].trim(), counted: n }); // a later line for the same name wins
  }
  return { rows: [...byName.values()], unreadable, asOf: a.iso, asOfBad: a.found && !a.iso };
}

// ---- the photo: the vision model's JSON ----
export const COUNT_CONF = 0.8;
export const countSheetPrompt = () =>
  'You are reading a photo of a hand-filled stock count sheet for a small guest house. Return ONLY a JSON object, no markdown:\n' +
  '{"is_count_sheet":boolean,"confidence":number,"printed_at":"YYYY-MM-DDTHH:MM"|null,"rows":[{"name":string,"counted":number|string|null,"confidence":number}]}\n' +
  'Rules:\n- is_count_sheet is true only for a list of item names with handwritten quantities. A shop receipt, an ID, a chat screenshot or any other photo is false. confidence is how sure you are of that true/false answer.\n' +
  '- One row per line item: name exactly as printed, and the HANDWRITTEN number beside it as "counted". Ignore printed stock figures.\n' +
  '- Fractions (1/2, 1 1/2) and sums written as a+b (16+46) may be returned as the text exactly as written. Use null when a number is blank or you cannot read it. Never guess.\n' +
  '- printed_at is any printed date and time on the sheet (for example "Printed 16 Oct 2026, 08:21") as 24-hour YYYY-MM-DDTHH:MM, else null.\n' +
  '- Each confidence is 0 to 1: how sure you are of that row number.';

export type SheetRead = { isSheet: boolean; confidence: number; asOf: string | null; asOfBad: boolean; rows: Row[]; notRead: string[] };
export function readSheet(j: any, nowMs: number): SheetRead {
  const conf = (x: unknown) => { const n = Number(x); return Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : 0; };
  const rows: Row[] = [], notRead: string[] = [];
  for (const r of Array.isArray(j?.rows) ? j.rows : []) {
    const name = String(r?.name ?? '').trim().slice(0, 80);
    if (!name) continue;
    const n = typeof r?.counted === 'number'
      ? (Number.isFinite(r.counted) && r.counted >= 0 && r.counted === Math.round(r.counted * 100) / 100 ? r.counted : null)
      : parseNumber(r?.counted);
    if (n === null || conf(r?.confidence) < COUNT_CONF) notRead.push(name); else rows.push({ name, counted: n });
  }
  const p = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})/.exec(String(j?.printed_at ?? ''));
  const asOf = inWindow(p ? manilaIso(+p[1], +p[2], +p[3], +p[4], +p[5]) : null, nowMs);
  return { isSheet: j?.is_count_sheet === true, confidence: conf(j?.confidence), asOf, asOfBad: !!j?.printed_at && !asOf, rows, notRead };
}
/** A photo goes to the count reader only with a "count"/"inventory" caption, or (autodetect on, no caption) when the reader says it is a sheet. */
export const photoRoute = (caption: unknown, autodetect: boolean): 'count' | 'detect' | 'receipt' =>
  isCountCaption(caption) ? 'count' : (autodetect && !String(caption ?? '').trim() ? 'detect' : 'receipt');
export const isCountSheet = (r: SheetRead) => r.isSheet && r.confidence >= COUNT_CONF;

// ---- matching ----
const norm = (s: string) => s.toLowerCase().replace(/&/g, ' and ').replace(/[^a-z0-9]+/g, ' ').trim();
export type Matched = { item: StockItem; counted: number };
export type MatchResult = { matched: Matched[]; unmatched: string[]; ambiguous: Array<{ name: string; options: string[] }>; blocked: string[] };

/** exact, then contains (all words of the typed name inside one item name), then a small edit distance. Never a guess: two candidates are listed back. */
export function matchItems(rows: Row[], items: StockItem[]): MatchResult {
  const out: MatchResult = { matched: [], unmatched: [], ambiguous: [], blocked: [] };
  const byId = new Map<string, Matched>();
  const named = items.map((it) => ({ it, n: norm(it.name) }));
  for (const r of rows) {
    const q = norm(r.name);
    if (!q) { out.unmatched.push(r.name); continue; }
    let hits = named.filter((x) => x.n === q);
    if (!hits.length) {
      const words = q.split(' ');
      hits = named.filter((x) => { const w = x.n.split(' '); return words.every((t) => w.includes(t)) || x.n.includes(q); });
    }
    if (!hits.length) {
      const max = q.length <= 5 ? 1 : 2;
      const scored = named.map((x) => ({ x, d: Math.min(osa(q, x.n), ...x.n.split(' ').map((w) => osa(q, w))) })).filter((s) => s.d <= max);
      const best = Math.min(...scored.map((s) => s.d));
      hits = scored.filter((s) => s.d === best).map((s) => s.x);
    }
    if (hits.length > 1) { out.ambiguous.push({ name: r.name, options: hits.slice(0, 4).map((h) => h.it.name) }); continue; }
    if (!hits.length) { out.unmatched.push(r.name); continue; }
    if (hits[0].it.controlled) { out.blocked.push(hits[0].it.name); continue; }
    byId.set(hits[0].it.id, { item: hits[0].it, counted: r.counted }); // the same item twice: the later line wins
  }
  out.matched = [...byId.values()];
  return out;
}

/** With no as-of time a row that equals today's figure changes nothing and is dropped, as /count does; with one, the final figure depends on usage since, so every row stays. */
export function toChanges(m: Matched[], asOf: string | null): Change[] {
  return m.filter((x) => asOf || x.item.qty !== x.counted)
    .map((x) => ({ item_id: x.item.id, name: x.item.name, unit: x.item.unit, before: x.item.qty, counted: x.counted, reorder: x.item.reorder }));
}

const MON3 = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
export const asOfLabel = (iso: string) => `${Number(iso.slice(8, 10))} ${MON3[Number(iso.slice(5, 7)) - 1]} ${iso.slice(11, 16)}`;

export type CardIn = { source: 'typed' | 'photo'; asOf: string | null; changes: Change[]; res: MatchResult; unreadable: string[]; notRead: string[] };
/** The review card as chunks of at most 3,500 characters; the caller puts the Confirm / Cancel buttons on the last one. */
export function countCard(i: CardIn, esc: (s: unknown) => string): { chunks: string[]; canConfirm: boolean } {
  const lines = [`📦 *${i.source === 'photo' ? 'Count from photo' : 'Count from message'}*${i.asOf ? ` · as of ${asOfLabel(i.asOf)}` : ''}`, ''];
  if (i.changes.length) {
    if (i.asOf) {
      lines.push('_Stock logged since then is kept: the new figure is the count plus that movement._');
      for (const c of i.changes) lines.push(`• ${esc(c.name)}: counted ${c.counted} ${esc(c.unit)}  (now ${c.before})`);
    } else lines.push(...reviewLines(i.changes.map((c) => ({ ...c, name: esc(c.name), unit: esc(c.unit) }))));
  } else lines.push('Nothing to change, so there is nothing to save.');
  const note = (title: string, xs: string[]) => { if (xs.length) lines.push('', title, ...xs.map((x) => `• ${esc(x)}`)); };
  note('Not read - type them:', i.notRead);
  note('Could not read:', i.unreadable);
  note('No item by that name:', i.res.unmatched);
  note('Counted through the ledger, not here:', i.res.blocked);
  note('Which one? Type the full name:', i.res.ambiguous.map((a) => `${a.name} (${a.options.join(' / ')})`));
  if (i.changes.length) lines.push('', 'Nothing is saved until you tap Confirm.');
  return { chunks: chunkLines(lines), canConfirm: i.changes.length > 0 && !i.unreadable.some((u) => /^[\d\s.\/+]+$/.test(u)) }; // a bare number with no name may be a count left out
}

/** The result lines after Confirm, from the database rows (counted, since_delta, clamped). */
export function appliedLines(rows: any[], esc: (s: unknown) => string): string[] {
  return rows.map((r) => {
    const d = Number(r?.since_delta ?? 0);
    const since = d ? `, ${d > 0 ? '+' : '−'}${Math.abs(d)} logged since` : '';
    return `• ${esc(r?.name)}: ${r?.after}  (counted ${r?.counted}${since}${r?.clamped ? ', set to 0' : ''})`;
  });
}

export type PhotoOutcome = { kind: 'receipt' } | { kind: 'sheet'; sheet: SheetRead } | { kind: 'failed'; why: 'unreadable' | 'no_rows' };
/** One vision call. 'detect' (no caption) hands a non-sheet back to the receipt path untouched; 'count' (caption) trusts the person and reads whatever rows it finds. */
export async function readCountPhoto(read: (prompt: string) => Promise<string>, mode: 'count' | 'detect', nowMs: number): Promise<PhotoOutcome> {
  let j: any;
  try { const t = await read(countSheetPrompt()); j = JSON.parse(t.slice(t.indexOf('{'), t.lastIndexOf('}') + 1)); } catch { return mode === 'detect' ? { kind: 'receipt' } : { kind: 'failed', why: 'unreadable' }; }
  const sheet = readSheet(j, nowMs);
  if (mode === 'detect') return isCountSheet(sheet) ? { kind: 'sheet', sheet } : { kind: 'receipt' };
  if (j?.is_count_sheet === false && sheet.confidence >= COUNT_CONF) return { kind: 'receipt' }; // a captioned photo the reader is sure is not a sheet (a receipt) takes the receipt path
  return sheet.rows.length || sheet.notRead.length ? { kind: 'sheet', sheet } : { kind: 'failed', why: 'no_rows' };
}

/** Which RPC a pending count confirms through, and its arguments. A typed or photo count (v2) carries its as-of time; /count (v1) is unchanged. */
export function countRpc(payload: any, tgUserId: unknown, note: string): { fn: string; args: Record<string, unknown> } {
  const p_rows = ((payload?.changes ?? []) as Change[]).map((c) => ({ item_id: c.item_id, counted: c.counted, expected_before: c.before }));
  const args: Record<string, unknown> = { p_telegram_user_id: tgUserId, p_rows, p_note: note };
  if (!payload?.v2) return { fn: 'telegram_apply_inventory_count_v1', args };
  return { fn: 'telegram_apply_inventory_count_v2', args: { ...args, p_as_of: payload.as_of ?? null } };
}
