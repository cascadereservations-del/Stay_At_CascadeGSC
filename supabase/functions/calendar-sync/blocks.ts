// D-236 / SPEC-41 (D-296.2): an Airbnb "Not available" block is explained by the system before anyone is asked.
// Pure, so blocks.test.ts can read every decision. index.ts does the talking and the writing.
//
// The order, per block with a night still ahead:
//   1. a brownout: any active ops_notices brownout notice (SOCOTECO, NGCP, a poster photo, a /brownout) whose touched nights cover EVERY
//      night of the block, or the brownout:<night> rows power-watch holds -> label 'brownout', source 'auto';
//   2. a direct booking, hold or inquiry on any night -> label 'direct', source 'auto';
//   3. neither -> saved as 'maintenance' with source 'assumed' and ONE card in Telegram OPS (never Finance) with four taps.
// A confirmed Airbnb stay overlapping the block keeps D-236's behaviour: not asked, not labelled.
// The answer lives on calendar_events (block_reason, block_reason_source ...); recon_status stays the single "is it explained" flag. The sync
// upsert never writes these columns. A 'staff' answer is never overwritten by the system; an 'auto' label whose evidence has gone is reset.
// Airbnb's feed carries no note on a block (all 20 live rows had a null description on 2026-09-24); if one ever does, it is quoted.
import { withHeader } from '../_shared/cascade-core/format.ts';
import { nightsPhrase, touchedNights } from '../_shared/cascade-core/brownout.ts';

export type CalRow = {
  uid: string;
  source: string;
  status: string;
  checkin_date: string;
  checkout_date: string;
  recon_status: string | null;
  recon_alerted_at: string | null;
  raw_description?: string | null;
  block_reason?: string | null;
  block_reason_source?: string | null;
  block_note?: string | null;
};
/** An active brownout row of ops_notices. `source` is socoteco | ngcp | staff (null before the SPEC-41 release); duration_hours may arrive as a numeric string. */
export type Notice = { id: string; title: string; effective_date: string; effective_time: string | null; duration_hours: number | string | null; source?: string | null };
/** A direct booking, an active hold or a live inquiry, as the block step reads them (v_direct_bookings gives the ref). */
export type DirectEvidence = { ref: string; status: string; checkin_date: string; checkout_date: string };

const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** '2026-09-30' -> 'Sep 30'. */
export const monthDay = (d: string) => `${MON[Number(d.slice(5, 7)) - 1]} ${Number(d.slice(8, 10))}`;

const isPending = (r: CalRow) => (r.recon_status ?? 'pending') === 'pending';
const isBlock = (r: CalRow) => r.source === 'airbnb' && r.status === 'blocked';

const nextDay = (ymd: string) => new Date(Date.parse(`${ymd}T00:00:00Z`) + 86_400_000).toISOString().slice(0, 10);
const nightsOf = (b: CalRow): string[] => { const out: string[] = []; for (let n = b.checkin_date; n < b.checkout_date; n = nextDay(n)) out.push(n); return out; };
const num = (v: unknown) => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v)) ? null : Number(v));

/** Nights a notice touches (power-watch's own rule), with the first notice that touches each night, for the note. */
function noticeNights(notices: Notice[]): Map<string, Notice> {
  const out = new Map<string, Notice>();
  for (const n of notices) for (const night of touchedNights(n.effective_date, n.effective_time, num(n.duration_hours))) if (!out.has(night)) out.set(night, n);
  return out;
}
/** D-290: the brownout:<night> manual rows power-watch holds. */
const heldNights = (rows: CalRow[]) => new Set(rows.filter((o) => o.source === 'manual' && o.status !== 'cancelled' && o.uid.startsWith('brownout:')).map((o) => o.checkin_date));

const hhmm = (t: string | null) => (t ? ` ${t.slice(0, 5)}` : '');
/** 'NGCP grid interruption Oct 11 08:00 for 8h' - the title and window of the notice. */
const noticeLine = (n: Notice) => { const h = num(n.duration_hours); return `${n.title.trim()} ${monthDay(n.effective_date)}${hhmm(n.effective_time)}${h ? ` for ${h}h` : ''}`.slice(0, 200); };

/** Rule 1 and 2 of the order above. null = nothing explains it (or an Airbnb stay does, which the caller treats as covered). */
export function explain(b: CalRow, rows: CalRow[], notices: Notice[], direct: DirectEvidence[]): { reason: 'brownout' | 'direct'; note: string } | null {
  const nights = nightsOf(b);
  if (nights.length) {
    const byNotice = noticeNights(notices), held = heldNights(rows);
    if (nights.every((n) => byNotice.has(n) || held.has(n))) {
      const first = byNotice.get(nights[0]) ?? nights.map((n) => byNotice.get(n)).find(Boolean);
      return { reason: 'brownout', note: first ? noticeLine(first) : 'Brownout blocked on our booking site (power-watch)' };
    }
  }
  const overlaps = (a: { checkin_date: string; checkout_date: string }) => a.checkin_date < b.checkout_date && b.checkin_date < a.checkout_date;
  const d = direct.find(overlaps);
  if (d) return { reason: 'direct', note: `DIR ${d.ref} ${d.status}`.slice(0, 200) };
  const row = rows.find((o) => o !== b && o.source === 'direct' && o.status !== 'cancelled' && overlaps(o));
  if (row) return { reason: 'direct', note: `DIR ${row.uid.replace(/^(?:direct:|cascade-direct-)/, '').slice(0, 8).toUpperCase()} ${row.status}` };
  return null;
}

/** A confirmed Airbnb stay on any night is its own explanation (D-236.4): the block is neither asked nor labelled. */
const stayCovers = (b: CalRow, rows: CalRow[]) => rows.some((o) =>
  o !== b && o.status !== 'cancelled' && o.source === 'airbnb' && o.status === 'confirmed' && o.checkin_date < b.checkout_date && b.checkin_date < o.checkout_date);

const futureBlock = (r: CalRow, today: string, horizonGuard: string | null) => isBlock(r) && r.checkout_date > today && (!horizonGuard || r.checkin_date < horizonGuard);

/**
 * Blocks the system may label: still pending, or only assumed, or answered the old way (admin_block with no reason yet), or already
 * labelled auto (so a label whose evidence has gone is reset). Never a 'staff' answer. Not the rolling tail at the feed's horizon (a fresh
 * uid every day, calendar-sync v13).
 */
export function blocksToTriage(rows: CalRow[], today: string, horizonGuard: string | null): CalRow[] {
  return rows.filter((r) => futureBlock(r, today, horizonGuard) && r.block_reason_source !== 'staff' && !stayCovers(r, rows) &&
    (isPending(r) || r.block_reason_source === 'assumed' || r.block_reason_source === 'auto' || (r.recon_status === 'admin_block' && !r.block_reason)));
}

/**
 * Blocks worth one OPS question now: still pending (nobody has said what it is, and the system has not either), nothing explains it, no
 * Airbnb stay overlaps, oldest first, at most five. A card asked in Finance before SPEC-41 and never answered is asked once more here.
 */
export function blocksToAsk(rows: CalRow[], today: string, horizonGuard: string | null, notices: Notice[] = [], direct: DirectEvidence[] = [], cap = 5): CalRow[] {
  return rows
    .filter((r) => futureBlock(r, today, horizonGuard) && isPending(r) && !r.block_reason_source && !stayCovers(r, rows) && !explain(r, rows, notices, direct))
    .sort((a, b) => a.checkin_date.localeCompare(b.checkin_date))
    .slice(0, cap);
}

/** Saved as maintenance by the system and asked in OPS more than seven days ago, still unanswered: one Follow-ups task each (D-218). */
export function blocksOverdue(rows: CalRow[], today: string, now: Date, notices: Notice[] = [], direct: DirectEvidence[] = []): CalRow[] {
  const weekAgo = now.getTime() - 7 * 86_400_000;
  return rows.filter((r) => isBlock(r) && r.checkout_date > today && r.block_reason_source === 'assumed' &&
    !!r.recon_alerted_at && Date.parse(r.recon_alerted_at) < weekAgo && !explain(r, rows, notices, direct));
}

export const BLOCK_ANSWERS = [
  { code: 'brownout', label: '⚡ Brownout' },
  { code: 'maint', label: '🔧 Maintenance' },
  { code: 'owner', label: '🏠 Owner use' },
  { code: 'other', label: '✏️ Something else' },
] as const;

/** 'The SOCOTECO notice for Oct 15 covers the night of Oct 14. Nothing explains the night of Oct 16.' - only when a notice covers some of the nights. */
export function partialLine(b: CalRow, rows: CalRow[], notices: Notice[]): string | null {
  const nights = nightsOf(b), by = noticeNights(notices), held = heldNights(rows);
  const covered = nights.filter((n) => by.has(n) || held.has(n)), rest = nights.filter((n) => !by.has(n) && !held.has(n));
  if (!covered.length || !rest.length) return null;
  const n = by.get(covered[0]);
  const who = !n ? 'brownout' : n.source === 'ngcp' || /\bNGCP\b/i.test(n.title) ? 'NGCP' : n.source === 'staff' ? 'scheduled' : 'SOCOTECO';
  return `The ${who} notice${n ? ` for ${monthDay(n.effective_date)}` : ''} covers the ${nightsPhrase(covered)}. Nothing explains the ${nightsPhrase(rest)}.`;
}

/** The OPS card, for a person: what is blocked, that nothing explains it, what is saved for now, and the question. No money, no guest names (D-289). */
export function blockCardText(r: CalRow, partial?: string | null): string {
  const note = (r.raw_description ?? '').trim();
  const lines = [`Airbnb shows ${monthDay(r.checkin_date)} to ${monthDay(r.checkout_date)} as blocked (the ${nightsPhrase(nightsOf(r))}). Cascade has no booking, hold, inquiry or brownout notice for ${nightsOf(r).length === 1 ? 'that night' : 'those nights'}, so it is saved as maintenance for now.`];
  if (note) lines.push(`Airbnb's note: "${note.slice(0, 200)}"`);
  if (partial) lines.push('', partial);
  lines.push('', 'Whoever blocked it on Airbnb: please tap what it is. It is asked once.');
  return withHeader('attention', 'blocked date', lines.join('\n'));
}
