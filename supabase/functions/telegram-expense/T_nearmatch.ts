// s83 lane T: a notice typed slightly wrong in the OPS / Finance group used to get no reply at all (Telegram update 287881812, 2026-10-13).
// This file decides, purely, what to do with a text that looks like a notice but is not the exact "water notice:" / "brownout notice:" form
// (the exact form is B_noticeRoute's, unchanged): forward a cleaned-up copy to Cassy, answer once with a short hint, or stay silent.
// Also decides an edited_message: only a notice that now parses is acted on, once per message (T_claimMessage), never an expense.
// Pure apart from T_claimMessage (one upsert). The clock comes in as nowMs. Nothing here prints a text, a name, a phone or an amount.
// deno-lint-ignore-file no-explicit-any
import { B_findDate, B_findTimes, B_readNotice } from '../telegram-cassy/B_notice.ts';
import { B_noticeSignal } from '../_shared/B_notice-signal.ts';

export type T_Kind = 'water' | 'brownout';

const MON3 = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const manilaYmd = (ms: number) => new Date(ms).toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
const addDays = (ymd: string, n: number) => { const d = new Date(ymd + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const monthDay = (ymd: string) => `${MON3[Number(ymd.slice(5, 7)) - 1]} ${Number(ymd.slice(8, 10))}`;

// Optimal string alignment distance: Levenshtein plus one adjacent swap ("wtaer" is 1 from "water").
function osa(a: string, b: string): number {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++) for (let j = 1; j <= b.length; j++) {
    d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) d[i][j] = Math.min(d[i][j], d[i - 2][j - 2] + 1);
  }
  return d[a.length][b.length];
}
// Same first letter, within `max` edits: later, gate, meter, nice, note, voice are NOT water / notice (review F1).
const near = (w: string, t: string, max: number) => w[0] === t[0] && w.length >= t.length - 1 && osa(w, t) <= max;
function kindOf(w: string): T_Kind | null {
  w = w.toLowerCase();
  if (w === 'power' || w === 'blackout' || w === 'brownouts') return 'brownout';
  if (near(w, 'water', 1)) return 'water';
  if (near(w, 'brownout', 2)) return 'brownout';
  return null;
}
const isNoticeWord = (w: string) => { w = w.toLowerCase(); return w === 'notices' || (w !== 'noticed' && near(w, 'notice', 1)); };

/** The kind word and the notice word at the very start ("water notice", "Notice - water", "waternotice", "watr notise"), and where the rest begins. */
function head(text: string): { kind: T_Kind; end: number } | null {
  const m = /^(\s*)([a-z]+)(?:([\s\-–—_]+)([a-z]+))?/i.exec(text);
  if (!m) return null;
  const [all, lead, a, sep, b] = m;
  if (b) {
    // "Notice water pressure low" is a maintenance report: with notice first, the kind word needs a dash before it or a colon / dash after it.
    const k = (isNoticeWord(b) && kindOf(a)) || (isNoticeWord(a) && (/[-–—]/.test(sep) || /^\s*[:\-–—]/.test(text.slice(all.length))) && kindOf(b));
    if (k) return { kind: k, end: all.length };
  }
  for (let i = 3; i <= a.length - 3; i++) { // "waternotice", "noticewater"
    const x = a.slice(0, i), y = a.slice(i);
    const k = (isNoticeWord(y) && kindOf(x)) || (isNoticeWord(x) && kindOf(y));
    if (k) return { kind: k, end: lead.length + a.length };
  }
  return null;
}

const upper = (s: string) => s.replace(/\b(am|pm)\b/g, (x) => x.toUpperCase());

export type T_Near = { kind: 'forward'; text: string; notice: T_Kind } | { kind: 'hint'; text: string } | null;

/** null = not notice-like (stay silent) or the exact form (the existing route owns it). */
export function T_nearNotice(text: unknown, nowMs: number): T_Near {
  const t = typeof text === 'string' ? text : '';
  if (!t || /^\s*(?:@?cassy\b|\/)/i.test(t) || B_noticeSignal(t)) return null;
  const h = head(t);
  if (!h) return null;
  const today = manilaYmd(nowMs);
  const rest = t.slice(h.end).replace(/^[\s:\-–—]+/, '').trim()
    .replace(/\b(\d{1,2})\/(\d{1,2})(?:\/\d{2,4})?\b/g, (s, a, b) => (+a >= 1 && +a <= 12 ? `${MON3[+a - 1]} ${+b}` : s)) // 10/16 reads month first, as /brownout does
    .replace(/\b(today)\b/gi, monthDay(today))
    .replace(/\b(tomorrow|bukas)\b/gi, monthDay(addDays(today, 1)));
  const date = B_findDate(rest, today), times = B_findTimes(rest);
  const word = h.kind === 'water' ? 'water' : 'brownout';
  if (date && (h.kind === 'water' || times)) return { kind: 'forward', text: `${word} notice: ${rest}`, notice: h.kind };
  if (!date && !times && !/^\s*(?:water|brownout|power)[\s\-–—_]*notices?\b/i.test(t)) return null; // nothing read and not the command words: chatter, stay silent
  const found = date ? (times ? '' : `I found the date, ${monthDay(date)}, but not the times.`)
    : times ? `I found the times, ${upper(times.label)}, but not the date.` : 'I did not find a date or times.';
  const eg = `${word} notice: ${date ? monthDay(date) : monthDay(addDays(today, 1))} ${times ? upper(times.label) : '8:00 AM to 5:00 PM'}`;
  return { kind: 'hint', text: `I could not read that ${word} notice. ${found} Send it like this: ${eg}`.replace('  ', ' ') };
}

export type T_Log = { update_type: string; allowed: boolean; route: string; text_len: number };
/** The one structured log line. Fields only: never the text, a name, a phone or an amount. */
export const T_logLine = (l: T_Log) => JSON.stringify({ evt: 'ops_update_routed', ...l });

export type T_Decision =
  | { act: 'pass' }
  | { act: 'ignore'; log: T_Log }
  | { act: 'reply'; chatId: unknown; replyTo: number | undefined; text: string; log: T_Log }
  | { act: 'forward'; update: any; claim: any; log: T_Log };

/** What to do with an update BEFORE the older paths. 'pass' = not ours (exact notice forms, commands, photos, callbacks, everything else). */
export function T_decide(update: any, isAllowed: (chatId: unknown) => boolean): T_Decision {
  const edit = update?.edited_message, m = edit ?? update?.message;
  if (!m) return { act: 'pass' };
  const text = typeof m.text === 'string' ? m.text : '';
  const base = (route: string): T_Log => ({ update_type: edit ? 'edited_message' : 'message', allowed: isAllowed(m.chat?.id), route, text_len: text.length });
  if (edit) {
    if (!isAllowed(m.chat?.id) || m.from?.is_bot || !text) return { act: 'ignore', log: base('edit_ignored') };
    const nowMs = Number(m.edit_date ?? m.date ?? 0) * 1000;
    const body = B_noticeSignal(text) && !/^\s*(?:@?cassy\b|\/)/i.test(text) ? text : (() => { const n = T_nearNotice(text, nowMs); return n?.kind === 'forward' ? n.text : null; })();
    if (body === null) return { act: 'ignore', log: base('edit_not_a_notice') };
    return { act: 'forward', update: { update_id: update.update_id, message: { ...m, text: body } }, claim: m, log: base('edit_notice') };
  }
  if (!text || m.from?.is_bot || m.reply_to_message?.from?.is_bot) return { act: 'pass' };
  const n = T_nearNotice(text, Number(m.date ?? 0) * 1000);
  if (!n) return { act: 'pass' };
  if (!isAllowed(m.chat?.id)) return { act: 'ignore', log: base('near_notice_disallowed_chat') };
  if (n.kind === 'forward') return { act: 'forward', update: { ...update, message: { ...m, text: n.text } }, claim: m, log: base('near_notice_forwarded') };
  return { act: 'reply', chatId: m.chat.id, replyTo: m.message_id, text: n.text, log: base('near_notice_hint') };
}

/** One notice per message id, edits included. Uses the existing dedupe table with a negative synthetic key (real update ids are positive).
 *  true = this message already produced a notice card, so do nothing. Fails open on a database error (as alreadyProcessed does). The row is purged after 2 days. */
const claimKey = (msg: any) => -((Math.abs(Number(msg?.chat?.id)) % 1e8) * 1e7 + Number(msg?.message_id));
export async function T_claimMessage(db: any, msg: any): Promise<boolean> {
  const key = claimKey(msg);
  if (!Number.isFinite(key)) return false;
  const { data, error } = await db.from('telegram_processed_updates').upsert({ update_id: key }, { onConflict: 'update_id', ignoreDuplicates: true }).select('update_id');
  if (error) return false;
  return !data || data.length === 0;
}

/** True when Cassy will build a Save card from this text (a signal whose date, and times for a brownout, can be read). Only then is the message claimed. */
export function T_willCard(m: any, text: string): boolean {
  const sig = B_noticeSignal(text);
  return !!sig && sig.kind !== 'ask' && !!B_readNotice(sig, Number(m?.date ?? 0) * 1000).params;
}

export type T_Deps = {
  isAllowed: (chatId: unknown) => boolean;
  hasAwaiting: (chatId: unknown, userId: unknown) => Promise<boolean>;
  reply: (chatId: unknown, replyTo: number, text: string) => Promise<unknown>;
  forward: (update: any) => Promise<{ ok: boolean }>;
  log: (line: string) => void;
};

/** Claim (only when a card will be built), forward, and give the claim back if the forward fails so a fixing edit can still make the card (review F4, F5).
 *  true = already handled, nothing forwarded. */
async function claimAndForward(db: any, d: Pick<T_Deps, 'forward'>, update: any, claimMsg: any, text: string): Promise<boolean> {
  const claimed = T_willCard(claimMsg, text);
  if (claimed && await T_claimMessage(db, claimMsg)) return true;
  let ok = false;
  try { ok = !!(await d.forward(update))?.ok; } catch { ok = false; }
  if (!ok && claimed) await db.from('telegram_processed_updates').delete().eq('update_id', claimKey(claimMsg)).then(() => null, () => null);
  return false;
}

/** The T block of the webhook, lifted out of index.ts so it can be tested. true = the update is handled, stop; false = carry on with the older paths. */
export async function T_handle(db: any, update: any, d: T_Deps): Promise<boolean> {
  const td = T_decide(update, d.isAllowed);
  if (td.act === 'ignore') { d.log(T_logLine(td.log)); return true; }
  if (td.act === 'pass') return false;
  const tm = update.edited_message ?? update.message;
  // An answer is awaited from this person: a plain message goes on to the expense flow, an edit is dropped (review F3).
  if (await d.hasAwaiting(tm?.chat?.id, tm?.from?.id)) return !!update.edited_message;
  d.log(T_logLine(td.log));
  if (td.act === 'reply') { await d.reply(td.chatId, td.replyTo as number, td.text); return true; }
  if (await claimAndForward(db, d, td.update, td.claim, String(td.update.message.text ?? ''))) d.log(T_logLine({ ...td.log, route: 'notice_already_handled' }));
  return true;
}

/** The exact-form path (B_noticeRoute): claim the message when a card will be built, then forward the raw update to Cassy. */
export async function T_handleExact(db: any, update: any, d: Pick<T_Deps, 'forward'>): Promise<void> {
  await claimAndForward(db, d, update, update.message, String(update.message?.text ?? update.message?.caption ?? ''));
}
