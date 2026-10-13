// telegram-cassy lane B (s81, fix round 1): an explicit notice signal (B_noticeSignal) becomes a pending notice card; nothing is saved until the Save tap.
// The tap is telegram-expense's existing llm_confirm handler (executeNoticeFromLLM inserts ops_notices from the params below, source included).
// The title is BUILT from what was read (kind, times, place), never copied from the post, so a phone number, e-mail or amount in the post cannot
// reach the notice. Pure functions: the clock is passed in.
//   water    -> notice_type water, source gscwd (the GSCWD Facebook page is the only water source)
//   brownout -> notice_type brownout, source staff: the same row a staff /brownout makes. power-watch adopts it on its next run (see docs/B_notice-sources.md).
// deno-lint-ignore-file no-explicit-any
import type { B_Signal } from '../_shared/B_notice-signal.ts';

const MONTHS: Record<string, number> = {
  jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, sept: 9, oct: 10, nov: 11, dec: 12,
  january: 1, february: 2, march: 3, april: 4, june: 6, july: 7, august: 8, september: 9, october: 10, november: 11, december: 12,
};
const MON = '(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)';
const DAY_MS = 86_400_000;

const manilaYmd = (ms: number) => new Date(ms).toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
const pad = (n: number) => String(n).padStart(2, '0');

/** A date in the text: ISO, "Month D[, YYYY]" or "D Month [YYYY]". A year-less date that is more than 180 days behind `todayYmd` is next year's
 *  (a December post about January saves next January); a recent past date stays in this year. */
export function B_findDate(text: string, todayYmd: string): string | null {
  const iso = /\b(20\d\d)-(\d\d)-(\d\d)\b/.exec(text);
  if (iso) { // 2026-13-45 is no date: the caller asks, a database error never happens
    const p = new Date(Date.UTC(+iso[1], +iso[2] - 1, +iso[3]));
    return p.getUTCMonth() === +iso[2] - 1 && p.getUTCDate() === +iso[3] ? iso[0] : null;
  }
  const md = new RegExp(`\\b${MON}\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:\\s*,?\\s*(20\\d\\d))?\\b`, 'i').exec(text);
  const dm = new RegExp(`\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?${MON}\\.?(?:\\s*,?\\s*(20\\d\\d))?\\b`, 'i').exec(text);
  const hit = md ? { m: md[1], d: md[2], y: md[3] } : dm ? { m: dm[2], d: dm[1], y: dm[3] } : null;
  if (!hit) return null;
  const month = MONTHS[hit.m.toLowerCase()], day = Number(hit.d);
  if (!month || day < 1 || day > 31) return null;
  const mk = (y: number) => { const p = new Date(Date.UTC(y, month - 1, day)); return p.getUTCMonth() === month - 1 ? p : null; };
  const thisYear = Number(todayYmd.slice(0, 4));
  let d = mk(hit.y ? Number(hit.y) : thisYear);
  if (!d) return null;
  if (!hit.y && Date.parse(todayYmd + 'T00:00:00Z') - d.getTime() > 180 * DAY_MS) d = mk(thisYear + 1) ?? d;
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
}

const to24 = (h: number, mer: string) => (mer === 'pm' ? (h % 12) + 12 : h % 12);
const merOf = (s: string) => (s.toLowerCase().startsWith('p') ? 'pm' : 'am');
const RANGE = /\b(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?\s*(?:to|-|–|—|until|hanggang|up to)\s*(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)/gi;
const AFTER_MONTH = new RegExp(`${MON}\\.?\\s*$`, 'i');

/** "8:00 AM to 5:00 PM", "8am-5pm", "8-5pm", "1:00 to 4:00 PM": start as HH:MM:00 and the hours long. A number that follows a month name is a day,
 *  not a time ("October 16 - 8:00 AM to 5:00 PM", "October 6 - 8:00 AM to 5 PM"): the scan skips it and retries from the next number. Null when no range. */
export function B_findTimes(text: string): { start: string; hours: number; label: string } | null {
  const re = new RegExp(RANGE.source, 'gi');
  let m: RegExpExecArray | null;
  while ((m = re.exec(text))) {
    if (AFTER_MONTH.test(text.slice(0, m.index))) { re.lastIndex = m.index + m[1].length; continue; }
    const h1 = Number(m[1]), m1 = Number(m[2] ?? 0), h2 = Number(m[4]), m2 = Number(m[5] ?? 0);
    if (h1 > 12 || h2 > 12 || m1 > 59 || m2 > 59 || h1 < 1 || h2 < 1) { re.lastIndex = m.index + m[1].length; continue; }
    const mer2 = merOf(m[6]);
    let s = to24(h1, m[3] ? merOf(m[3]) : mer2) * 60 + m1;
    const e = to24(h2, mer2) * 60 + m2;
    if (!m[3] && s >= e) s = to24(h1, 'am') * 60 + m1; // "8-5pm" reads 8 am to 5 pm
    const span = (e - s + 1440) % 1440;
    if (span === 0) { re.lastIndex = m.index + m[1].length; continue; }
    const f = (min: number) => { const h = Math.floor(min / 60) % 24; return `${h % 12 === 0 ? 12 : h % 12}:${pad(min % 60)} ${h >= 12 ? 'pm' : 'am'}`; };
    return { start: `${pad(Math.floor(s / 60))}:${pad(s % 60)}:00`, hours: Math.round((span / 60) * 10) / 10, label: `${f(s)} to ${f(e)}` };
  }
  return null;
}

export type B_NoticeParams = {
  notice_type: 'water' | 'brownout'; title: string; effective_date: string; effective_time: string | null; duration_hours: number | null; source: 'gscwd' | 'staff';
};
export type B_NoticeRead = { params: B_NoticeParams | null; dateFound: boolean; timeFound: boolean; namesUs: boolean; kind: 'water' | 'brownout' };

/** A bare Facebook link with no page name: which kind is it? Saves nothing. */
export const B_WHICH_CARD = 'Is this a water notice or a brownout notice? Reply with `water notice:` or `brownout notice:` and the date and time, for example `water notice: October 16, 8:00 AM to 5:00 PM`.';

/** Reads one signalled post. postedAtMs (frozen by the caller) gives today's Manila date and the year. params is null when the card cannot be built
 *  (no date at all, or a brownout with no time): the caller then asks for them. A water post with a date but no time is kept as an all-day notice. */
export function B_readNotice(sig0: B_Signal, postedAtMs: number): B_NoticeRead {
  const sig = { ...sig0, kind: sig0.kind === 'brownout' ? ('brownout' as const) : ('water' as const) }; // 'ask' never reaches here (the flow answers it first)
  const today = manilaYmd(postedAtMs);
  const date = B_findDate(sig.body, today);
  const t = B_findTimes(sig.body);
  const namesUs = /san\s+isidro/i.test(sig.body);
  const base = { dateFound: !!date, timeFound: !!t, namesUs, kind: sig.kind };
  if (!date || (sig.kind === 'brownout' && !t)) return { params: null, ...base };
  const title = (sig.kind === 'water' ? ['Water interruption', t?.label, namesUs ? 'in San Isidro' : ''] : ['Brownout', t?.label]).filter(Boolean).join(' ');
  return {
    params: { notice_type: sig.kind, title, effective_date: date, effective_time: t?.start ?? null, duration_hours: t?.hours ?? null, source: sig.kind === 'water' ? 'gscwd' : 'staff' },
    ...base,
  };
}

/** The reply asked for when the date (or a brownout's time) is missing: the exact message to send back. */
export function B_askCard(r: B_NoticeRead): string {
  const word = r.kind === 'water' ? 'water' : 'brownout';
  return [
    r.dateFound ? `I found the date but not the times for this ${word} notice.` : `I could not find the date${r.kind === 'brownout' ? ' and times' : ''} for this ${word} notice.`,
    `Copy the date and times from the page and send them like this:`,
    `${word} notice: October 16, 8:00 AM to 5:00 PM`,
  ].join('\n');
}

/** The confirm card text. Plain sentences; it says plainly what the post did not say. */
export function B_noticeCard(r: B_NoticeRead): string {
  const p = r.params!;
  const lines = [
    `Save a ${p.notice_type} notice on ${p.effective_date}${p.effective_time ? ' at ' + p.effective_time.slice(0, 5) : ''}${p.duration_hours ? ' for ' + p.duration_hours + 'h' : ''}?`,
    p.title,
  ];
  if (!r.timeFound) lines.push('No time was found, so it is saved for the whole day.');
  if (p.notice_type === 'water' && !r.namesUs) lines.push('The post does not name Brgy. San Isidro. Save it only if it affects us.');
  if (p.notice_type === 'brownout') lines.push('A brownout saved by hand blocks the affected nights on our booking site within about 15 minutes, like an automatic one.');
  return lines.join('\n');
}

type Send = (chatId: unknown, text: string, replyTo: number | undefined, keyboard: Array<Array<{ text: string; callback_data: string }>>) => Promise<boolean>;
/** Stores the pending notice (telegram_pending kind llm_notice, the row telegram-expense llm_confirm consumes) and sends the Save / Cancel card,
 *  or the ask card when the date (or a brownout's time) is missing. */
export async function B_noticeFlow(db: any, msg: any, sig: B_Signal, send: Send): Promise<void> {
  if (sig.kind === 'ask') { await send(msg.chat.id, B_WHICH_CARD, msg.message_id, []); return; }
  const r = B_readNotice(sig, Number(msg.date ?? 0) * 1000);
  if (!r.params) { await send(msg.chat.id, B_askCard(r), msg.message_id, []); return; }
  const { data, error } = await db.from('telegram_pending').insert({
    chat_id: msg.chat.id, kind: 'llm_notice',
    payload: { params: r.params, from: { first_name: msg.from?.first_name, username: msg.from?.username, id: msg.from?.id } },
  }).select('id').single();
  if (error || !data?.id) {
    console.error('cassy_notice_pending_failed', String(error?.message ?? 'no id').slice(0, 200));
    await send(msg.chat.id, 'I could not prepare that notice. Nothing was saved. Try again in a minute.', msg.message_id, []);
    return;
  }
  await send(msg.chat.id, B_noticeCard(r), msg.message_id, [[
    { text: '✅ Save it', callback_data: `llm_confirm:${data.id}` },
    { text: '❌ Cancel', callback_data: `llm_cancel:${data.id}` },
  ]]);
}
