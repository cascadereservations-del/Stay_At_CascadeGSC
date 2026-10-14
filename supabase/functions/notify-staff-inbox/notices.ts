// Lane XS2 (s84): the notice kinds of notify-staff-inbox. Pure: no clock, no network (callers pass nowMs).
//   notice          a scheduled brownout or water interruption was added (any source: socoteco, gscwd, manual, system). Sent once per notice.
//   rain            rain is likely at the house within the next 3 hours (Lloyd 2026-10-14: whenever, brownout or not; during a brownout the sentence says so).
//                   One claim per rain episode: rain:<Manila date>:<hour the window starts>. rain-alert keeps it to one push per 3 hours.
// Only today or later counts, never a past notice. The lock-screen text is plain: the day, the hours, nothing else (no money, no guest data, no free text).
export const NOTICE_URL = './#calendar/notices'; // the Notices tab of the Calendar screen in the Staff shell
export const NOTICE_TAG = 'notices';
export type NoticeKind = 'notice' | 'rain';
export const HOUSE_PROPERTY_ID = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
export type NoticeEvent =
  | { kind: 'notice'; noticeId: string }
  | { kind: 'rain'; from: string; peakPct: number; brownoutNoticeId: string | null }; // from = "YYYY-MM-DDTHH:MM", Manila local time

export type NoticeRow = {
  id: string; property_id: string; notice_type: string; effective_date: string; effective_time: string | null;
  duration_hours: number | string | null; is_active: boolean;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function parseNoticeEvent(b: Record<string, unknown>): { ok: true; value: NoticeEvent } | { ok: false; reason: string } {
  if (b.kind === 'notice') {
    if (typeof b.notice_id !== 'string' || !UUID.test(b.notice_id)) return { ok: false, reason: 'bad_notice_id' };
    return { ok: true, value: { kind: 'notice', noticeId: b.notice_id.toLowerCase() } };
  }
  const peak = Number(b.peak_pct);
  if (typeof b.peak_pct === 'boolean' || b.peak_pct === null || !Number.isInteger(peak) || peak < 0 || peak > 100) return { ok: false, reason: 'bad_peak_pct' };
  if (typeof b.from !== 'string' || !/^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d/.test(b.from)) return { ok: false, reason: 'bad_from' };
  const bn = b.brownout_notice_id;
  if (bn != null && (typeof bn !== 'string' || !UUID.test(bn))) return { ok: false, reason: 'bad_notice_id' };
  return { ok: true, value: { kind: 'rain', from: b.from.slice(0, 16), peakPct: peak, brownoutNoticeId: typeof bn === 'string' ? bn.toLowerCase() : null } };
}

/** One claim per rain episode: the Manila date and the hour the rain window starts. */
export const rainKey = (from: string): string => `rain:${from.slice(0, 10)}:${from.slice(11, 13)}`;

export const manilaDate = (nowMs: number): string => new Date(nowMs + 8 * 3_600_000).toISOString().slice(0, 10);

/** A brownout or a water notice, still active, dated today (Manila) or later. */
export function isImportant(n: NoticeRow, nowMs: number): boolean {
  return (n.notice_type === 'brownout' || n.notice_type === 'water') && n.is_active === true && /^\d{4}-\d{2}-\d{2}$/.test(n.effective_date) && n.effective_date >= manilaDate(nowMs);
}

const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** "2026-10-16" -> "Thu 16 Oct". */
export function dayLabel(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  return `${DOW[new Date(Date.UTC(y, m - 1, d)).getUTCDay()]} ${d} ${MON[m - 1]}`;
}
const clock = (min: number): { h: number; m: string; ap: string } => {
  const x = ((min % 1440) + 1440) % 1440, h = Math.floor(x / 60);
  return { h: h % 12 === 0 ? 12 : h % 12, m: String(x % 60).padStart(2, '0'), ap: h >= 12 ? 'pm' : 'am' };
};
/** "13:00:00" + 3 hours -> "1:00 to 4:00 pm"; across noon "11:00 am to 2:00 pm"; no hours -> "". */
export function hoursLabel(time: string | null, hours: number | string | null): string {
  const mm = /^(\d{1,2}):(\d{2})/.exec(String(time ?? ''));
  if (!mm) return '';
  const start = Number(mm[1]) * 60 + Number(mm[2]);
  const a = clock(start), len = Number(hours);
  if (!Number.isFinite(len) || len <= 0) return `from ${a.h}:${a.m} ${a.ap}`;
  const b = clock(start + Math.round(len * 60));
  return a.ap === b.ap ? `${a.h}:${a.m} to ${b.h}:${b.m} ${b.ap}` : `${a.h}:${a.m} ${a.ap} to ${b.h}:${b.m} ${b.ap}`;
}

/** "2026-10-14T15:00" -> "3 pm". */
const hourWord = (from: string): string => { const c = clock(Number(from.slice(11, 13)) * 60 + Number(from.slice(14, 16))); return `${c.h}${c.m === '00' ? '' : ':' + c.m} ${c.ap}`; };

/** The rain sentence. A window that has already begun reads "in the next 3 hours"; one still ahead reads "from about 3 pm". */
export function rainBody(e: Extract<NoticeEvent, { kind: 'rain' }>, duringBrownout: boolean, nowMs: number): string {
  const started = e.from <= new Date(nowMs + 8 * 3_600_000).toISOString().slice(0, 16);
  const when = started ? 'in the next 3 hours' : `from about ${hourWord(e.from)}`;
  return duringBrownout ? `Rain likely ${when} during the brownout.` : `Rain likely ${when} (${e.peakPct}%).`;
}

/** The lock-screen sentence for a new notice. Plain English, no exclamation mark, no title or description of the notice (free text stays in the app). */
export function noticeBody(_e: Extract<NoticeEvent, { kind: 'notice' }>, n: NoticeRow): string {
  const what = n.notice_type === 'water' ? 'Water interruption' : 'Brownout';
  const hrs = hoursLabel(n.effective_time, n.duration_hours);
  return `${what} scheduled ${dayLabel(n.effective_date)}${hrs ? `, ${hrs}` : ''}`;
}
