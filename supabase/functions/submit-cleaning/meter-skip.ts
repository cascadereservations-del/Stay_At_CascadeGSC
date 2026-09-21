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
  return { skipped: skippedFlag === true && note.length >= 4, note };
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

/* ── The graduated meter-mismatch alert, server half (2026-09-21) ────────────
   Lloyd, 2026-09-20: mirror the alert to Finance, ask for a re-upload, and
   block only if it is still unresolved. The asking already existed
   (get_meter_photo_followups has raised 'mismatch' at sign-in since
   2026-09-13); the mirror is in verify-meter-photo; this is the block.

   It lives here, next to the other meter policy, and stays pure: the query is
   in index.ts and only its answer arrives. */

/** Which cleaning types a mismatch may block. A mid-stay happens with the guest
 *  still in the unit and an emergency clean is an incident; neither reads the
 *  meter, and neither is the moment to hold a cleaner up over an older report. */
export const METER_BLOCKING_TYPES = new Set(['turnover', 'deep_clean']);

/** How far back an unresolved mismatch still counts: the same 14 days the
 *  sign-in card uses (get_meter_photo_followups' p_lookback), so the app and the
 *  server can never disagree about whether someone is blocked. */
export const METER_BLOCK_LOOKBACK_DAYS = 14;

export type PriorMismatch = { recorded_at?: string | null };

/** The refusal to show her, or null when nothing blocks.
 *  Written for a person holding a phone in the unit: what is wrong, what to do,
 *  in that order, and no row id anywhere (D-197's standing rule). */
export function meterBlockMessage(
  cleaningType: string,
  rows: PriorMismatch[] | null | undefined,
): string | null {
  if (!METER_BLOCKING_TYPES.has(cleaningType)) return null;
  const first = (rows ?? [])[0];
  if (!first) return null;
  const when = first.recorded_at
    ? new Date(first.recorded_at).toLocaleDateString('en-PH', {
        timeZone: 'Asia/Manila', month: 'short', day: 'numeric',
      })
    : 'an earlier report';
  return [
    `The meter photo from ${when} does not match the reading that was typed, and nobody has answered for it yet.`,
    `Open the checklist again: there is a notice at the top about it. Say what you did about the photo, and this report will go straight through.`,
  ].join(' ');
}
