// deno test submit-cleaning/gas-response.test.ts  (run from supabase/functions)
// Covers the v28 fix: GAS always answers HTTP 200, even for its own caught
// internal errors, so `ok` alone can never detect a failed forward.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { EDGE_DEADLINE_MS, evaluateGasResponse, GAS_MIN_TIMEOUT_MS, GAS_TIMEOUT_MS, gasTimeoutMs } from './gas-response.ts';

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

Deno.test('the GAS forward gives up before the Edge worker is shut down at 150 s, leaving the alert time to send', () => {
  // 2026-09-29: the worker died at WallClockTime 150.0 s, 0.4 s after Apps Script answered with an HTML page,
  // so the Finance alert never had time to run. The timeout must leave at least 10 s.
  assertEquals(GAS_TIMEOUT_MS <= 140_000, true);
});

Deno.test('the GAS abort is a deadline from request start: time already spent comes off the wait and 10 s always remain before 150 s', () => {
  const t0 = 1_000_000;
  assertEquals(gasTimeoutMs(t0, t0), 130_000);
  for (const spent of [0, 5_000, 40_000, 120_000]) {
    const now = t0 + spent, abortAt = now + gasTimeoutMs(t0, now);
    assertEquals(abortAt - t0 <= EDGE_DEADLINE_MS - 10_000, true, `spent ${spent}`);   // leaves >= 10 s of the 140 s plan, 20 s of the real 150 s
    assertEquals(t0 + 150_000 - abortAt >= 10_000, true, `spent ${spent}`);
  }
  assertEquals(gasTimeoutMs(t0, t0 + 200_000), GAS_MIN_TIMEOUT_MS);   // already past the deadline: a small floor, never zero or negative
});
