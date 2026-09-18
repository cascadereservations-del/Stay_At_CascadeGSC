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
