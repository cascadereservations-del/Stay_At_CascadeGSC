// deno test client-error/report.test.ts
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { alertable, card, fingerprint, parseReport, redact } from './report.ts';

const live = { app: 'checklist', kind: 'http', message: 'submit-cleaning 400 invalid_photo_scope',
  detail: { fn: 'submit-cleaning', status: 400, code: 'invalid_photo_scope', path: '/CH-Cleaners-Checklist/' } };

Deno.test('D-240: the 2026-09-25 checklist failure becomes one readable OPS card', () => {
  const r = parseReport(live)!;
  const t = card(r, 1, true);
  assert(t.includes('The cleaning checklist showed someone an error - a server reply failed: submit-cleaning answered 400 (invalid_photo_scope).'), t);
  assert(t.includes('First time this error has been seen.'));
  assertEquals(t.match(/^Do: /gm)?.length, 1);
});

Deno.test('D-240: only our two pages and three kinds are accepted', () => {
  assertEquals(parseReport({ ...live, app: 'elsewhere' }), null);
  assertEquals(parseReport({ ...live, kind: 'spam' }), null);
  assertEquals(parseReport({ ...live, message: '   ' }), null);
});

Deno.test('D-240: e-mails, phone numbers and tokens never reach the log or the card', () => {
  assertEquals(redact('failed for ana@example.com 0917 123 4567 eyJhbGci.eyJzdWIi.sig', 200), 'failed for [email] [number] [token]');
});

Deno.test('D-240: the same error from two devices is one fingerprint; a different code is another', async () => {
  const a = await fingerprint(parseReport(live)!);
  const b = await fingerprint(parseReport({ ...live })!);
  const c = await fingerprint(parseReport({ ...live, detail: { ...live.detail, code: 'meter_backwards', status: 409 } })!);
  assertEquals(a, b);
  assert(a !== c);
});

Deno.test('D-240: an expected 409 is recorded but never alerts', () => {
  assertEquals(alertable(parseReport({ ...live, detail: { ...live.detail, status: 409 } })!), false);
  assertEquals(alertable(parseReport(live)!), true);
});
