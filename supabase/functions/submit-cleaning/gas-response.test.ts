// deno test submit-cleaning/gas-response.test.ts  (run from supabase/functions)
// Covers the v28 fix: GAS always answers HTTP 200, even for its own caught
// internal errors, so `ok` alone can never detect a failed forward.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { evaluateGasResponse, GAS_TIMEOUT_MS } from './gas-response.ts';

Deno.test('a real success body is not a failure', () => {
  const r = evaluateGasResponse(true, 200, JSON.stringify({ result: 'success', status: 'success' }));
  assertEquals(r.failed, false);
});

Deno.test('GAS caught its own error and still answered 200 -- must still count as failed', () => {
  const r = evaluateGasResponse(true, 200, JSON.stringify({ result: 'error', message: 'MailApp quota exceeded for today' }));
  assertEquals(r.failed, true);
  assertEquals(r.reason, 'MailApp quota exceeded for today');
});

Deno.test('a non-JSON body (stale URL -> HTML error page) is a failure', () => {
  const r = evaluateGasResponse(false, 404, '<html>Page not found</html>');
  assertEquals(r.failed, true);
  assertEquals(r.reason.includes('HTTP 404') || r.reason.includes('html'), true);
});

Deno.test('an empty body is a failure', () => {
  const r = evaluateGasResponse(true, 200, '');
  assertEquals(r.failed, true);
  assertEquals(r.reason, 'HTTP 200');
});

Deno.test('the GAS forward outlives a real turnover', () => {
  // 27 photos had not finished archiving 81 s in on 2026-09-19; anything at or
  // below that reintroduces the abort that lost SPEC-15's file ids.
  assertEquals(GAS_TIMEOUT_MS > 120_000, true);
});
