// power-watch, pure part (D-284, Lloyd 2026-09-29 "A"): which SOCOTECO II advisory posters are ours, what the notice
// says, and the alert. Replaces the never-installed Apps Script "SOCOTECO II NOTICE" (Feeder Watch v1.0.0), keeping its
// feeder rule and fixing what would have missed the Oct 8 2026 outage: our feeder 14-3 is served by LEON LLIDO
// substation, and a poster that names only the substation is ours.

export const FEEDER = '14-3';
// 14-3, 14–3, F14-3, FEEDER 14 - 3, 14.3; not 114-3, not 14-30 (from the Apps Script, same tests).
export const FEEDER_RE = /(?:^|[^0-9])(?:f(?:eeder)?\s*)?14\s*[-–—.\s]\s*3(?![0-9])/i;
const OUR_SUBSTATION = /leon[\s_-]*llido/i;
const AREA_RE = /\b(bria homes|conel|san isidro|katangawan|all areas|all feeders|system-?wide|city-?wide)\b/i; // katangawan: the neighbouring barangay, kept from the Apps Script

const strip = (html: string) => String(html ?? '').replace(/<[^>]+>/g, ' ').replace(/&#0?38;|&amp;/g, '&').replace(/\s+/g, ' ').trim();

/** An advisory post (the site also carries plebiscite results and billing notices). */
export const isPowerPost = (p: { title?: { rendered?: string } }) => /power\s+(interruption|advisory|update)/i.test(strip(p.title?.rendered ?? ''));

/** Full-size poster URLs in a post body (WordPress also embeds -WxH thumbnails and partner logos). */
export function posterUrls(html: string): string[] {
  const urls = [...String(html).matchAll(/https:\/\/www\.socoteco2\.com\/wp-content\/uploads\/[^"' )]+?\.(?:jpe?g|png|webp)/gi)]
    .map((m) => m[0].replace(/-\d+x\d+(\.[a-z]+)$/i, '$1'))
    .filter((u) => !/logo|FB-PAGE|doe-|erc-|nea-|philreca|ecmco|ecnetwork/i.test(u));
  return [...new Set(urls)];
}

/** The filename decides most posters for free: SPI-09252026-F13-3.jpg, SPI-PMS-10082026-LEON-LLIDO-SS.jpg.
 *  'hit' = ours (read it only for the times), 'miss' = another feeder or substation, 'read' = an area name, read it. */
export function classifyFile(url: string): 'hit' | 'miss' | 'read' {
  const f = decodeURIComponent(url.split('/').pop() ?? '').replace(/_/g, '-');
  if (OUR_SUBSTATION.test(f) || FEEDER_RE.test(f)) return 'hit';
  if (/-SS\.[a-z]+$/i.test(f)) return 'miss';               // another substation (ours is Leon Llido)
  if (/(^|-)F\d{1,2}-\d(?=[-.])/i.test(f)) return 'miss';   // names a different feeder
  return 'read';
}

/** The SOCOTECO poster for a date among the ones already read (power_watch_state.images): its filename carries MMDDYYYY
 *  (SPI-PMS-10082026-LEON-LLIDO-SS.jpg). Another substation's or feeder's poster is never it; the newest wins. Lloyd 2026-10-03:
 *  every card links the actual notice so staff can open it and check. Notices seeded from the board have no poster of their own. */
export function posterFor(date: string, images: string[]): string {
  const key = `${date.slice(5, 7)}${date.slice(8, 10)}${date.slice(0, 4)}`;
  return [...images].reverse().find((u) => classifyFile(u) !== 'miss' && decodeURIComponent(u.split('/').pop() ?? '').includes(key)) ?? '';
}

// D-290: the wording about rescheduled and cancelled schedules is the advisory prompt telegram-expense already uses for
// photos, plus the two fields that let a cancellation or a move be acted on (status, original_date).
export const OCR_PROMPT = 'This is a SOCOTECO II (Philippines) power interruption advisory poster. Read all of it. Return ONLY minified JSON: ' +
  '{"date":"YYYY-MM-DD","start":"HH:MM" (24-hour),"end":"HH:MM" (24-hour),"hours":number,"substation":string,"feeders":[strings as printed, e.g. "14-3"],' +
  '"areas":[strings],"purpose":string,"kind":"SCHEDULED" or "UNSCHEDULED","status":"ACTIVE" or "CANCELLED","original_date":"YYYY-MM-DD"}. ' +
  'Ignore any schedule marked RESCHEDULED, struck-through, or cancelled: return only the ACTIVE schedule. ' +
  'If the poster as a whole announces that an interruption is cancelled, called off or postponed, return status CANCELLED and the date that was cancelled. ' +
  'If it moves an interruption to a new date, return the NEW date in date and the date it was moved from in original_date. ' +
  'Use null for anything the poster does not show.';

export type Ocr = { date?: string | null; start?: string | null; end?: string | null; hours?: number | null; substation?: string | null; feeders?: string[] | null; areas?: string[] | null; purpose?: string | null; kind?: string | null; status?: string | null; original_date?: string | null };
export type Notice = { date: string; time: string | null; hours: number | null; title: string; purpose: string; poster: string; url: string; status: 'active' | 'cancelled'; originalDate: string | null };

/** Ours when the filename said so, or the poster names feeder 14-3, Leon Llido, our area, or all areas. */
export function affectsUs(o: Ocr, fileHit: boolean): boolean {
  if (fileHit) return true;
  const blob = [o.substation ?? '', ...(o.feeders ?? []), ...(o.areas ?? [])].join(' | ');
  return FEEDER_RE.test(blob) || OUR_SUBSTATION.test(blob) || AREA_RE.test(blob);
}

const hhmm = (s: unknown) => { const m = /^(\d{1,2}):(\d{2})/.exec(String(s ?? '')); return m ? `${m[1].padStart(2, '0')}:${m[2]}` : null; };

/** The ops_notices row for an advisory that is ours, or null. The date falls back to the filename (MMDDYYYY). */
export function noticeFrom(o: Ocr, fileHit: boolean, url: string): Notice | null {
  if (!affectsUs(o, fileHit)) return null;
  const poster = decodeURIComponent(url.split('/').pop() ?? '');
  const fm = /(\d{2})(\d{2})(20\d{2})/.exec(poster);
  const date = /^\d{4}-\d{2}-\d{2}$/.test(String(o.date ?? '')) ? String(o.date) : fm ? `${fm[3]}-${fm[1]}-${fm[2]}` : '';
  if (!date) return null;
  const start = hhmm(o.start), end = hhmm(o.end);
  const span = start && end ? ((+end.slice(0, 2) * 60 + +end.slice(3)) - (+start.slice(0, 2) * 60 + +start.slice(3))) / 60 : null;
  const hours = Number(o.hours) > 0 ? Number(o.hours) : span && span > 0 ? span : null;
  const where = [o.substation, (o.feeders ?? []).length ? `Feeders ${(o.feeders ?? []).join(', ')}` : '', !o.substation && !(o.feeders ?? []).length ? (o.areas ?? []).slice(0, 3).join(', ') : '']
    .filter(Boolean).join(', ');
  const kind = /unscheduled|emergency/i.test(String(o.kind ?? '')) ? 'unscheduled' : 'scheduled';
  const status = /cancel|postpone|called off/i.test(String(o.status ?? '')) ? 'cancelled' : 'active';
  const originalDate = /^\d{4}-\d{2}-\d{2}$/.test(String(o.original_date ?? '')) && o.original_date !== date ? String(o.original_date) : null;
  return { date, time: start ? `${start}:00` : null, hours, title: `SOCOTECO II ${kind} interruption${where ? ` - ${where}` : ''} (ours is ${FEEDER})`, purpose: String(o.purpose ?? '').trim(), poster, url, status, originalDate };
}

const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'], MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** 'HH:MM' the outage ends, from a start 'HH:MM[:SS]' and a length in hours; null when either is missing. Wraps past midnight. */
export function endOf(time: string | null, hours: number | null): string | null {
  if (!time || !hours) return null;
  const mins = +time.slice(0, 2) * 60 + +time.slice(3, 5) + Math.round(hours * 60);
  return `${String(Math.floor(mins / 60) % 24).padStart(2, '0')}:${String(mins % 60).padStart(2, '0')}`;
}
export const dayLabel = (ymd: string) => { const d = new Date(ymd + 'T00:00:00Z'); return `${DOW[d.getUTCDay()]} ${d.getUTCDate()} ${MON[d.getUTCMonth()]}`; };
export const clock = (t: string | null) => { if (!t) return ''; const h = +t.slice(0, 2), m = t.slice(3, 5); return `${h % 12 || 12}:${m} ${h < 12 ? 'AM' : 'PM'}`; };

/** Telegram and e-mail wording: what happens and what staff do first, the source last (Lloyd: notices are for people).
 *  D-290: a guest in the house that night gets a heads-up draft in Telegram; other guests hear only if they ask.
 *  `nightsLine` is the blocking result from the Telegram card (which nights are held on our site). */
export function alertText(n: Notice, nightsLine = ''): { subject: string; body: string } {
  const endT = endOf(n.time, n.hours);
  const when = `${dayLabel(n.date)}${n.time ? `, ${clock(n.time)}${endT ? ` to ${clock(endT)}` : ''}` : ''}${n.hours ? ` (${n.hours} h)` : ''}`;
  const body = [
    `Power will be off at the residence on ${when}.`,
    `${n.title}.${n.purpose ? ` Purpose: ${n.purpose}.` : ''}`,
    ...(nightsLine ? [nightsLine] : []),
    'Staff: charge the EcoFlow the day before and keep the emergency light on the fridge ready. A guest staying that night gets a heads-up draft in Telegram; other guests are told only if they ask about power.',
    'It is on the operations board, so the daily digest carries it.',
    `Poster: ${n.url}`,
  ].join('\n\n');
  return { subject: `Brownout at Cascade: ${when}`, body };
}
