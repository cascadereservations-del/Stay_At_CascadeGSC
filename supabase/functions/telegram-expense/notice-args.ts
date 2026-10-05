// SPEC-41 / 1.4: the /brownout argument parser, moved out of index.ts unchanged so the blocked-date card's "Brownout" follow-up
// ("10-11 8am 8h NGCP") and the /brownout command read a reply the same way, and so it is unit-tested (notice-args.test.ts).
// Pure: the calendar date comes in as `today` (Manila). index.ts keeps the writing and the card.
import { noticeSource, type NoticeSource } from '../_shared/cascade-core/brownout.ts';

export function isDateLike(t: string) { return ['today', 'tomorrow', 'yesterday'].includes(t.toLowerCase()) || /^\d{4}-\d{2}-\d{2}$/.test(t) || /^\d{1,2}-\d{1,2}$/.test(t); }

export function resolveDateOn(token: string | undefined, today: string): string {
  if (!token) return today;
  const t = token.toLowerCase();
  if (t === 'today') return today;
  if (t === 'yesterday') { const d = new Date(today + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() - 1); return d.toISOString().slice(0, 10); }
  if (t === 'tomorrow') { const d = new Date(today + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + 1); return d.toISOString().slice(0, 10); }
  if (/^\d{4}-\d{2}-\d{2}$/.test(token)) return token;
  const m = token.match(/^(\d{1,2})-(\d{1,2})$/);
  if (m) return `${today.slice(0, 4)}-${m[1].padStart(2, '0')}-${m[2].padStart(2, '0')}`;
  return today;
}

export function resolveTime(token?: string): string | null {
  if (!token) return null;
  const t = token.toLowerCase();
  const ampm = t.match(/^(\d{1,2})(?::(\d{2}))?(am|pm)$/);
  if (ampm) { let h = Number(ampm[1]); const min = Number(ampm[2] ?? 0); if (ampm[3] === 'pm' && h < 12) h += 12; if (ampm[3] === 'am' && h === 12) h = 0; return `${String(h).padStart(2, '0')}:${String(min).padStart(2, '0')}:00`; }
  const hm = t.match(/^(\d{1,2}):(\d{2})$/);
  if (hm) { const h = Number(hm[1]), min = Number(hm[2]); if (h <= 23 && min <= 59) return `${String(h).padStart(2, '0')}:${String(min).padStart(2, '0')}:00`; }
  return null;
}

export function resolveDuration(token?: string): number | null {
  if (!token) return null;
  const m = token.match(/^(\d+(?:\.\d+)?)h?$/i);
  if (m) { const n = Number(m[1]); return isFinite(n) && n > 0 ? n : null; }
  return null;
}

/** `[date] [time] [hours] <title>` as /brownout reads it (time and hours only for a brownout; "8 am" is joined). */
export function parseNoticeArgs(noticeType: string, argsIn: string[], today: string): { effectiveDate: string; effectiveTime: string | null; durationHours: number | null; title: string; dateGiven: boolean } {
  const args = [...argsIn];
  let idx = 0, effectiveDate = today, effectiveTime: string | null = null, durationHours: number | null = null, dateGiven = false;
  if (args[idx] && isDateLike(args[idx])) { effectiveDate = resolveDateOn(args[idx++], today); dateGiven = true; }
  if (noticeType === 'brownout') {
    if (args[idx] && !resolveTime(args[idx]) && args[idx + 1] && ['am', 'pm'].includes(args[idx + 1].toLowerCase())) { args.splice(idx, 2, args[idx] + args[idx + 1]); }
    if (args[idx]) { const t = resolveTime(args[idx]); if (t) { effectiveTime = t; idx++; } }
    if (args[idx]) { const d = resolveDuration(args[idx]); if (d !== null) { durationHours = d; idx++; } }
  }
  return { effectiveDate, effectiveTime, durationHours, title: args.slice(idx).join(' ').trim(), dateGiven };
}

/** The feeder text stored with a brownout notice: SOCOTECO's feeder, or the grid when the title says NGCP (SPEC-41 1.4). */
export const feederFor = (title: string): string => (/\bNGCP\b/i.test(title) ? 'NGCP grid' : 'Feeder 14-3');

/** The reply to the blocked-date card's Brownout question: it must name a day and say who announced it, or it is not an answer. */
export function parseBrownoutReply(text: string, today: string): { effectiveDate: string; effectiveTime: string | null; durationHours: number | null; title: string; feeder: string; source: NoticeSource } | null {
  const p = parseNoticeArgs('brownout', String(text ?? '').trim().split(/\s+/).filter(Boolean), today);
  if (!p.dateGiven || !p.title) return null;
  return { effectiveDate: p.effectiveDate, effectiveTime: p.effectiveTime, durationHours: p.durationHours, title: p.title, feeder: feederFor(p.title), source: noticeSource(p.title) };
}
