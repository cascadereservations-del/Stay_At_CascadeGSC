// The one-time meter-photo allowance, as pure functions so it can be tested.
//
// The checklist has been sending meterPhotosSkipped and meterPhotoSkipNote since 2026-09-13 and the
// DEPLOYED function dropped both, so cleaning_sessions.meter_photos_skipped stayed false on every row
// (0 of 42, read 2026-09-18) and can_skip_meter_photos would have answered "allowed" forever: the
// never-two-in-a-row rule existed on screen and nowhere else. Written for the never-deployed stay-site
// v28 (aae44a4), ported here 2026-09-18 because this copy is the one that ships (B78).
//
// It lives in its own file for the same reason photos.ts does: importing index.ts boots Deno.serve,
// which is exactly how this logic went untested and unshipped for weeks.

/** A skip counts only when it is DECLARED and carries a reason. "Skipped, reason unknown" is worth
 *  less than no claim at all, so a missing or trivial note means no skip was declared. */
export function parseMeterSkip(
  skippedFlag: unknown,
  noteField: unknown,
): { skipped: boolean; note: string } {
  const note = typeof noteField === 'string' ? noteField.trim().slice(0, 300) : '';
  // "....": four characters and no reason. Needs at least one letter or digit.
  return { skipped: skippedFlag === true && note.length >= 4 && /[\p{L}\p{N}]/u.test(note), note };
}

/** Incomplete-reason codes for the meter photos on a turnover or deep clean.
 *  A declared skip is a different FACT from photos simply missing, and the report should say which.
 *  Either way the report is still incomplete, because it genuinely lacks its evidence. Whether a
 *  declared skip should withhold the completeness flag is a policy question for Lloyd, not something
 *  to change quietly here. */
export function meterReasons(
  meterCount: number,
  skipped: boolean,
  previousSkipped: boolean,
): string[] {
  if (meterCount >= 2) return [];
  const out = [skipped ? `meter_photos_skipped_declared_${meterCount}_of_2` : `meter_photos_${meterCount}_of_2`];
  if (skipped && previousSkipped) out.push('meter_skip_consecutive_not_permitted');
  return out;
}

/** Which cleaning types have a meter reading that needs a photo (a declared skip on one is flagged estimate_pending). */
export const METER_BLOCKING_TYPES = new Set(['turnover', 'deep_clean']);

/** Flags that mean a stored reading's NUMBERS are wrong, so it must never be the "previous reading" a new
 *  one is compared with (D-219). first_reading and under_review are real numbers and still count. */
import { stayKey, type MeterRow } from '../_shared/meter-order.ts';
export { METER_WRONG_NUMBER_FLAGS } from '../_shared/meter-order.ts';

/** A meter does not run backwards (D-219, Lloyd 2026-09-23: block, not nudge). The refusal, or null.
 *  A missing number or a missing previous reading never blocks: there is nothing to compare. */
export function meterBackwardsMessage(
  elec: number | null, prevElec: number | null,
  water: number | null, prevWater: number | null,
): string | null {
  const back: string[] = [];
  if (elec !== null && Number.isFinite(elec) && prevElec !== null && elec < prevElec) {
    back.push(`electric ${elec} kWh is lower than the last reading (${prevElec})`);
  }
  if (water !== null && Number.isFinite(water) && prevWater !== null && water < prevWater) {
    back.push(`water ${water} m³ is lower than the last reading (${prevWater})`);
  }
  if (back.length === 0) return null;
  return [
    `The ${back.join(', and the ')}. A meter does not run backwards, so this report was not sent.`,
    `Read the meter again and type the number exactly as it shows. If the meter really shows this number, take a photo of it and message Lloyd - the last reading on file is the one that is wrong.`,
  ].join(' ');
}

/* ── "No meter photo was taken" (D-352, 2026-10-29) ───────────────────────────
   The never-two-in-a-row rule now follows STAY order (can_skip_meter_photos_v2),
   and a declared skip stores its typed reading as estimate_pending. Pure here
   so the branches are tested; index.ts only runs the queries. */

/** Reads the v2 answer: true = refused (the neighbouring stay also had no photos), false = allowed, null = the
 *  answer is unusable, so the caller falls back to the old latest-by-filing-order query. */
export function skipRefusedFromV2(data: unknown): boolean | null {
  if (!data || typeof data !== 'object' || Array.isArray(data)) return null;
  const allowed = (data as { allowed?: unknown }).allowed;
  return typeof allowed === 'boolean' ? !allowed : null;
}

/** The meter_flag a new reading is written with. Only a declared skip on a turnover or deep clean has no photo
 *  behind it; everything else keeps the column's default (null). */
export function meterFlagForSkip(skipped: boolean, cleaningType: string): 'estimate_pending' | null {
  return skipped && METER_BLOCKING_TYPES.has(cleaningType) ? 'estimate_pending' : null;
}

/** The one Finance line for a declared skip: what happened, who looks, what happens to the number. No amounts,
 *  no key=value, no row ids (D-197, Telegram wording rules). Plain text, no Markdown, so a stray underscore in a
 *  guest's name or the cleaner's note cannot break the send. */
export function meterNoPhotoNotice(
  cleaner: string, guest: string, checkOutDate: string | null, note: string, refused = false,
): string {
  const who = cleaner && cleaner !== '—' ? cleaner : 'The cleaner';
  const stay = guest && guest !== '—' ? `the stay of ${guest}` : 'the latest stay';
  const when = checkOutDate && /^\d{4}-\d{2}-\d{2}$/.test(checkOutDate)
    ? ` (checked out ${new Date(`${checkOutDate}T00:00:00+08:00`).toLocaleDateString('en-PH', { timeZone: 'Asia/Manila', month: 'short', day: 'numeric' })})`
    : '';
  return [
    `${who} reports that no meter photo was taken for ${stay}${when}.`,
    `Reason given: ${note.replace(/[.!?\s]+$/, '') || note}.`,
    refused
      ? `The stay next to it also has no meter photo, so the report is marked incomplete and Lloyd needs to decide what to do. The typed readings are kept for now. The follow-up is in the admin app for Lloyd and Marifel.`
      : `Nothing to do now. The typed readings are kept until the next verified reading, then checked and averaged if they do not fit. The follow-up is in the admin app for Lloyd and Marifel.`,
  ].join('\n');
}

/** D-352: a typed number with no photo is kept and averaged later, so a pending reading is never refused for being
 *  out of order. Anything else keeps the D-219 refusal. */
export function backwardsRefusal(orderMessage: string | null, meterFlag: string | null): string | null {
  return meterFlag === 'estimate_pending' ? null : orderMessage;
}

/** F5: a pending reading accepted out of order (backwards) is stored without deltas or per-night usage; the settle
 *  step recomputes them, and a negative delta would otherwise show in get_data_integrity_report. */
export function keepDeltas(orderMessage: string | null, meterFlag: string | null): boolean {
  return !(meterFlag && orderMessage);
}

/** True when an estimate_pending row sits strictly between two stay keys: usage measured across it spans a gap the
 *  pending stay hides, so the 2x anomaly check would raise a false alert. */
export function pendingBetween(
  rows: MeterRow[] | null | undefined,
  fromKey: string | null | undefined, toKey: string,
): boolean {
  if (!fromKey) return false;
  return (rows ?? []).some(r => {
    if (r.meter_flag !== 'estimate_pending') return false;
    const k = stayKey(r);
    return k > fromKey && k < toKey;
  });
}
