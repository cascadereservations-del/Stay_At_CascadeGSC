// D-236: an Airbnb "Not available" block with no booking behind it is asked about ONCE in Finance.
// Pure, so blocks.test.ts can read every decision. index.ts does the talking and the writing.
//
// The answer lives in calendar_events.recon_status (admin_block / skipped), which the sync upsert never
// writes, and recon_alerted_at stamps the question, so nothing is asked twice. Airbnb's feed carries no
// note on a block (all 20 live rows had a null description on 2026-09-24); if one ever does, it is quoted.
//
// ponytail: no backfill card. D-236 planned one for "20 existing blocks", but 17 of those are in the
// past and 2 are the one-night horizon tails Airbnb re-issues daily (skipped below), which leaves one
// real future block. The ordinary card covers it; the per-run cap of five is the flood guard.
import { withHeader } from '../_shared/cascade-core/format.ts';

export type CalRow = {
  uid: string;
  source: string;
  status: string;
  checkin_date: string;
  checkout_date: string;
  recon_status: string | null;
  recon_alerted_at: string | null;
  raw_description?: string | null;
};

const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** '2026-09-30' -> 'Sep 30'. */
export const monthDay = (d: string) => `${MON[Number(d.slice(5, 7)) - 1]} ${Number(d.slice(8, 10))}`;

const isPending = (r: CalRow) => (r.recon_status ?? 'pending') === 'pending';
const isBlock = (r: CalRow) => r.source === 'airbnb' && r.status === 'blocked';

const nextDay = (ymd: string) => new Date(Date.parse(`${ymd}T00:00:00Z`) + 86_400_000).toISOString().slice(0, 10);

/** D-290: every night of an Airbnb block is a night power-watch blocked for a SOCOTECO interruption (a manual row, uid brownout:<night>).
 *  Marifel's Airbnb block for it comes back through this feed, and it is explained; one night more than the outage is not. */
function brownoutExplains(b: CalRow, rows: CalRow[]): boolean {
  const held = new Set(rows.filter((o) => o.source === 'manual' && o.status !== 'cancelled' && o.uid.startsWith('brownout:')).map((o) => o.checkin_date));
  if (!held.size || b.checkin_date >= b.checkout_date) return false;
  for (let n = b.checkin_date; n < b.checkout_date; n = nextDay(n)) if (!held.has(n)) return false;
  return true;
}

/** A direct booking or an Airbnb stay on any of the block's nights is the explanation (D-236.4), and so is a brownout block on all of them (D-290). */
function covered(b: CalRow, rows: CalRow[]): boolean {
  return rows.some((o) =>
    o !== b && o.status !== 'cancelled' &&
    (o.source === 'direct' || (o.source === 'airbnb' && o.status === 'confirmed')) &&
    o.checkin_date < b.checkout_date && b.checkin_date < o.checkout_date) || brownoutExplains(b, rows);
}

/**
 * Blocks worth one question now: unexplained, never asked, with a night still ahead, not the rolling
 * tail at the feed's horizon (a fresh uid every day, calendar-sync v13), oldest first, at most five.
 */
export function blocksToAsk(rows: CalRow[], today: string, horizonGuard: string | null, cap = 5): CalRow[] {
  return rows
    .filter((r) => isBlock(r) && isPending(r) && !r.recon_alerted_at && r.checkout_date > today &&
      (!horizonGuard || r.checkin_date < horizonGuard) && !covered(r, rows))
    .sort((a, b) => a.checkin_date.localeCompare(b.checkin_date))
    .slice(0, cap);
}

/** Asked more than seven days ago and still unanswered: one Follow-ups task each (D-218). */
export function blocksOverdue(rows: CalRow[], today: string, now: Date): CalRow[] {
  const weekAgo = now.getTime() - 7 * 86_400_000;
  return rows.filter((r) => isBlock(r) && isPending(r) && r.checkout_date > today &&
    !!r.recon_alerted_at && Date.parse(r.recon_alerted_at) < weekAgo && !covered(r, rows));
}

export const BLOCK_ANSWERS = [
  { code: 'maint', label: 'Maintenance or owner use' },
  { code: 'direct', label: 'A direct booking - I will add it' },
  { code: 'unblock', label: 'Unblock it on Airbnb' },
] as const;

/** The card, for a person: what is blocked, that nothing explains it, and the question. */
export function blockCardText(r: CalRow): string {
  const note = (r.raw_description ?? '').trim();
  const lines = [`${monthDay(r.checkin_date)} to ${monthDay(r.checkout_date)} is blocked on Airbnb and Cascade has no booking for it. What is it?`];
  if (note) lines.push(`Airbnb's note: "${note.slice(0, 200)}"`);
  lines.push('', 'Tap one answer. It is asked once.');
  return withHeader('attention', 'blocked date', lines.join('\n'));
}
