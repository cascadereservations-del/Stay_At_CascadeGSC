// Pure so it can be unit-tested without mocking fetch/Supabase/Deno.serve.
// Apps Script web apps always return HTTP 200, even for a caught internal
// error (Code.gs's own doPost try/catch returns {result:'error', message}),
// so `ok` alone can never detect a GAS-side failure — the body has to be
// parsed too.
/** How long to wait for Code.gs before giving up on the GAS forward.
 *
 *  This was 25_000 until 2026-09-20 and that was only ever survivable because
 *  D-190 had the photo loop silently skipping every photo, so Code.gs finished
 *  in a couple of seconds. Once D-190 was fixed (session 33), a real turnover
 *  fetches every photo back out of Storage and creates it in Drive one at a
 *  time: Honey's 27-photo turnover on 2026-09-19 had still not reached its
 *  `_logToSheet` call 81 s in (Cleaning Report Log modifiedTime 12:21:41.940Z
 *  vs. submission 12:20:20.598Z), and the response comes after that plus the
 *  e-mail and the calendar event. So the fetch aborted every time: SPEC-15's
 *  `files[]` was never read (D-199), and Finance got an e-mail-FAILED alert
 *  for an e-mail that had in fact been sent.
 *
 *  The ceiling that matters is the Edge worker's own: it is shut down 150 s after it booted
 *  (Shutdown reason WallClockTime), however long waitUntil was told to wait. 2026-09-29 13:46Z showed
 *  it: Code.gs was still working at 150 s, the worker died the same instant the fetch returned an
 *  Apps Script HTML page, 0.4 s before the shutdown, so the Finance alert that follows had no time to
 *  send. The turnover has no session_folder_id / drive_files (finding F2, session 72). The old
 *  300_000 here sat above that ceiling, so the abort and its alert could never run in time. This now
 *  sits under it: the abort is derived from a deadline at request start (gasTimeoutMs), so the alert always has at least 10 s. The whole fetch still runs inside
 *  `waitUntil` after the checklist already has its 200, so waiting costs the cleaner nothing. */
export const EDGE_DEADLINE_MS = 140_000;     // from request start: the worker is shut down at 150 s, so plan for 140
export const GAS_ALERT_RESERVE_MS = 10_000;  // the Finance alert after an abort needs this long to send
export const GAS_MIN_TIMEOUT_MS = 1_000;
/** The longest a GAS wait can be from a standing start; resend-cleaning-report, which forwards within a second or two of its own start, uses it as is. */
export const GAS_TIMEOUT_MS = EDGE_DEADLINE_MS - GAS_ALERT_RESERVE_MS;

/** Abort budget for the GAS fetch, taken from a deadline set at request start (t0), so time already spent on
 *  the checklist, Storage and Telegram comes off the wait instead of pushing the abort past the worker's 150 s. */
export const gasTimeoutMs = (t0: number, now: number = Date.now()): number =>
  Math.max(GAS_MIN_TIMEOUT_MS, t0 + EDGE_DEADLINE_MS - now - GAS_ALERT_RESERVE_MS);

export function evaluateGasResponse(ok: boolean, status: number, bodyText: string): { failed: boolean; reason: string; stack?: string } {
  let parsed: { result?: string; message?: string; stack?: string } | null = null;
  try { parsed = JSON.parse(bodyText); } catch { /* GAS returned non-JSON, e.g. an HTML error page */ }
  const failed = !ok || !parsed || parsed.result === 'error';
  const reason = parsed?.message || bodyText.slice(0, 300) || `HTTP ${status}`;
  return { failed, reason, stack: parsed?.stack || undefined };
}
