// SPEC-38 s8: the probe seed for a Cassy reply. deno test --no-check --allow-env messenger-concierge/probe-seed.test.ts
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { seedFlow } from './probe-seed.ts';

const good = { step: 'await_receipt', checkin: '2026-11-30', checkout: '2026-12-04', pax: 2, name: 'Ana', ref: '00A49C5E', lang: 'tl', deposit: 6200, total: 12400, pay_full: false, hold: true, hold_expires_at: '2026-10-06T14:40:00Z' };

Deno.test('seedFlow accepts await_receipt and receipt_sent with every known field', () => {
  assertEquals(seedFlow(good), good);
  assertEquals(seedFlow({ ...good, step: 'receipt_sent' })?.step, 'receipt_sent');
});

Deno.test('seedFlow drops every other step, and anything that is not an object', () => {
  for (const step of ['dates', 'checkout', 'pax', 'offer', 'contact', 'confirm', 'confirmed', 'cancelled', 'cancel_requested', 'receipt_declined', '', undefined]) assertEquals(seedFlow({ ...good, step }), null, String(step));
  for (const x of [null, undefined, 'await_receipt', 7, []]) assertEquals(seedFlow(x), null);
});

Deno.test('seedFlow drops unknown keys, a booking_id of any kind and a receipt token; bad values are skipped, not coerced', () => {
  const out = seedFlow({ ...good, booking_id: '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', receipt_token: 'secret', phone: '0917', extra: 1, lang: 'fr', pax: '2', checkin: 'tomorrow', hold_expires_at: 'soon' })!;
  assertEquals('booking_id' in out, false);
  assertEquals('receipt_token' in out, false);
  assertEquals('phone' in out, false);
  assertEquals('extra' in out, false);
  assertEquals('lang' in out, false);
  assertEquals('pax' in out, false);
  assertEquals(out.checkin, undefined);
  assertEquals('hold_expires_at' in out, false);
  assertEquals(out.step, 'await_receipt');
});
