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
 *  The ceiling that matters is Apps Script's own: a consumer-account web app
 *  is killed at 6 minutes, so past that there is no response to wait for.
 *  This sits just under it, and the whole fetch runs inside `waitUntil` after
 *  the checklist already has its 200, so waiting costs the cleaner nothing. */
export const GAS_TIMEOUT_MS = 300_000;

export function evaluateGasResponse(ok: boolean, status: number, bodyText: string): { failed: boolean; reason: string; stack?: string } {
  let parsed: { result?: string; message?: string; stack?: string } | null = null;
  try { parsed = JSON.parse(bodyText); } catch { /* GAS returned non-JSON, e.g. an HTML error page */ }
  const failed = !ok || !parsed || parsed.result === 'error';
  const reason = parsed?.message || bodyText.slice(0, 300) || `HTTP ${status}`;
  return { failed, reason, stack: parsed?.stack || undefined };
}
