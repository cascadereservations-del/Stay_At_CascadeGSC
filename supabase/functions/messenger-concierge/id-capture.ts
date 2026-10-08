// SPEC-45 (D-320.6): a guest's ID photo sent in Messenger is saved to the guest record by itself. The pure parts (no I/O, unit-tested
// in id-capture.test.ts); index.ts owns the download, the one vision read, the upload and the RPC. Privacy (D-291): the reader is
// telegram-expense's GUEST_PROMPT - name and ID type only, never a number. The read name never reaches the guest or OPS (D-319).
import { type GuestRead, type IdType, idLabel, sameName } from '../telegram-expense/guest.ts';

/** At most this many ID reads per thread per Manila day (one vision call each). Stored on booking_flow.id_reads. */
export const ID_READS_PER_DAY = 3;
export type IdReads = { day: string; n: number };
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const manilaDay = (now: Date) => new Date(now.getTime() + 8 * 3_600_000).toISOString().slice(0, 10);

/** The booking a thread's ID belongs to: booking_flow.booking_id at any age (an ID often comes days after the 8-day lastRef window,
 *  near check-in); the RPC refuses a booking that is not confirmed. 'probe' only on the probe path (its effects never touch the DB). */
export function bookingIdOf(flow: { booking_id?: string } | null | undefined): string | null {
  const id = flow?.booking_id ?? '';
  return UUID_RE.test(id) || id === 'probe' ? id : null;
}

/** May this photo be read as an ID? Never without a booking (nothing could be saved), never past the day's cap. */
export function mayRead(bookingId: string | null, reads: IdReads | null | undefined, now: Date): { ok: true; next: IdReads } | { ok: false; reason: 'no_booking' | 'cap' } {
  if (!bookingId) return { ok: false, reason: 'no_booking' };
  const day = manilaDay(now), n = reads?.day === day ? reads.n : 0;
  return n >= ID_READS_PER_DAY ? { ok: false, reason: 'cap' } : { ok: true, next: { day, n: n + 1 } };
}

export type IdPlan =
  | { act: 'none'; reason: 'not_id' | 'no_booking' }
  /** own: the read name is the booking's guest - p_mark_id_on_file. Otherwise a companion only. guestLine: false when a host holds
   *  the chat (D-317) - the ID is still saved. */
  | { act: 'save'; bookingId: string; name: string; idType: IdType; own: boolean; guestLine: boolean };

/** The decision from a read: save as the guest's own ID, as a companion on a name mismatch, or nothing. */
export function planId(read: GuestRead, ctx: { bookingId: string | null; bookingName: string | null; hostHeld: boolean }): IdPlan {
  if (read.kind !== 'id') return { act: 'none', reason: 'not_id' };
  if (!ctx.bookingId) return { act: 'none', reason: 'no_booking' };
  return { act: 'save', bookingId: ctx.bookingId, name: read.name, idType: read.idType, own: !!ctx.bookingName && sameName(read.name, ctx.bookingName), guestLine: !ctx.hostHeld };
}

const REASON: Record<string, string> = {
  no_booking: 'the booking could not be found', not_confirmed: 'the booking is not confirmed yet', too_many: 'the guest already has the most companions allowed',
  bad_id_type: 'the ID type was not accepted', bad_path: 'the photo could not be stored', photo_missing: 'the photo could not be stored', upload_failed: 'the photo could not be stored',
};
const withArticle = (t: IdType) => `${t === 'other' ? 'an' : 'a'} ${idLabel(t)}`;

/** The OPS host notice: what happened first, text only - no image, no money (D-306), no contact data, no name from the ID (D-319). */
export function idOpsLine(guest: string | null, plan: Extract<IdPlan, { act: 'save' }>, saved: { ok: boolean; reason?: string }, link: string): string {
  const who = guest || 'A guest';
  const head = !saved.ok
    ? `${who} sent an ID in Messenger; it was not saved (${REASON[saved.reason ?? ''] ?? 'the save was refused'}). Do: save it by hand with /guest in Telegram.`
    : plan.own
    ? `${who} sent an ID in Messenger; saved to the guest record as ${withArticle(plan.idType)}. The name on it matches the booking, so ID on file is marked.`
    : `${who} sent an ID in Messenger; saved to the guest record as a companion (${withArticle(plan.idType)}). The name on it does not match the booking name, so ID on file is not marked.`;
  return `${head}${plan.guestLine ? '' : '\nYou are handling this chat, so Cassy sent the guest nothing.'}\n\nMessenger: ${link}`;
}
