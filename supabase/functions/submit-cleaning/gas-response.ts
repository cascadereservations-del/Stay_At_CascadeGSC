// Pure so it can be unit-tested without mocking fetch/Supabase/Deno.serve.
// Apps Script web apps always return HTTP 200, even for a caught internal
// error (Code.gs's own doPost try/catch returns {result:'error', message}),
// so `ok` alone can never detect a GAS-side failure — the body has to be
// parsed too.
export function evaluateGasResponse(ok: boolean, status: number, bodyText: string): { failed: boolean; reason: string; stack?: string } {
  let parsed: { result?: string; message?: string; stack?: string } | null = null;
  try { parsed = JSON.parse(bodyText); } catch { /* GAS returned non-JSON, e.g. an HTML error page */ }
  const failed = !ok || !parsed || parsed.result === 'error';
  const reason = parsed?.message || bodyText.slice(0, 300) || `HTTP ${status}`;
  return { failed, reason, stack: parsed?.stack || undefined };
}
