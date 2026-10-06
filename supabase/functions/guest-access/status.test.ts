// deno test --allow-read guest-access/status.test.ts
// SPEC-42 s6: the state mapping, the fields the status page may show, and the source-level guards on guest-access/index.ts.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { bookingState, SECURITY_DEPOSIT, statusView, type StatusFacts } from './status.ts';

const NOW = Date.parse('2026-10-06T00:00:00Z');
const base: StatusFacts = {
  ref: 'ABCD1234', status: 'pending', checkin_date: '2026-10-16', checkout_date: '2026-10-18', pax: 2,
  total_amount: '4000.00', deposit_amount: '2000.00', has_receipt: false, hold_status: null, hold_expires_at: null,
};
const held = (over: Partial<StatusFacts> = {}): StatusFacts => ({ ...base, hold_status: 'active', hold_expires_at: '2026-10-06T10:00:00Z', ...over });

Deno.test('each state maps from its facts', () => {
  assertEquals(bookingState(held(), NOW), 'held');
  assertEquals(bookingState(base, NOW), 'awaiting_payment');
  assertEquals(bookingState(held({ has_receipt: true }), NOW), 'under_review');
  assertEquals(bookingState({ ...base, status: 'confirmed', has_receipt: true }, NOW), 'confirmed');
  assertEquals(bookingState({ ...base, status: 'expired' }, NOW), 'released');
  assertEquals(bookingState(held({ hold_expires_at: '2026-10-05T10:00:00Z' }), NOW), 'released');
  assertEquals(bookingState(held({ hold_status: 'expired' }), NOW), 'released');
  assertEquals(bookingState({ ...base, status: 'cancelled' }, NOW), 'cancelled');
});

Deno.test('a receipt on file beats an expired hold clock; an unknown status or an unreadable deadline is never held', () => {
  assertEquals(bookingState(held({ has_receipt: true, hold_expires_at: '2026-10-05T10:00:00Z' }), NOW), 'under_review');
  assertEquals(bookingState({ ...base, status: 'mystery' }, NOW), null);
  assertEquals(statusView({ ...base, status: 'mystery' }, NOW), null);
  assertEquals(bookingState(held({ hold_expires_at: null }), NOW), 'released');
  assertEquals(bookingState(held({ hold_expires_at: 'garbage' }), NOW), 'released');
});

Deno.test('a held request shows the deadline, the amounts and an upload button', () => {
  const v = statusView(held(), NOW)!;
  assertEquals(v.state, 'held');
  assertEquals(v.hold_expires_at, '2026-10-06T10:00:00Z');
  assertEquals(v.money, { total: 4000, reservation_payment: 2000, balance_due_date: '2026-10-15', security_deposit: SECURITY_DEPOSIT });
  assertEquals(v.nights, 2);
  assertEquals(v.can_upload_receipt, true);
  assertEquals(v.checkin_time, '2:00 PM');
  assertEquals(v.checkout_time, '12:00 PM');
});

Deno.test('under review: no upload button, paid step done', () => {
  const v = statusView(held({ has_receipt: true }), NOW)!;
  assertEquals(v.can_upload_receipt, false);
  assertEquals(v.hold_expires_at, null);
  assertEquals(v.timeline!.map((s) => s.done), [true, true, false, false]);
});

Deno.test('confirmed: the money carries total and reservation payment only (the page works out the balance), a pay-in-full booking has fee = total', () => {
  const v = statusView({ ...base, status: 'confirmed', has_receipt: true }, NOW)!;
  assertEquals(v.money!.total, 4000);
  assertEquals(v.money!.reservation_payment, 2000);
  assertEquals(v.timeline!.map((s) => s.done), [true, true, true, false]);
  const full = statusView({ ...base, status: 'confirmed', has_receipt: true, deposit_amount: '4000' }, NOW)!;
  assertEquals(full.money!.reservation_payment, full.money!.total);
  assertEquals(Object.keys(v.money!).sort(), ['balance_due_date', 'reservation_payment', 'security_deposit', 'total']);
});

Deno.test('cancelled and released show no money and no timeline', () => {
  for (const f of [{ ...base, status: 'cancelled' }, { ...base, status: 'expired' }, held({ hold_expires_at: '2026-10-05T00:00:00Z' })]) {
    const v = statusView(f, NOW)!;
    assertEquals(v.money, null);
    assertEquals(v.timeline, null);
    assertEquals(v.can_upload_receipt, false);
    assertEquals(v.hold_expires_at, null);
    assert(!JSON.stringify(v).includes('4000') && !JSON.stringify(v).includes('2000'), 'no amount leaks on a closed booking');
  }
});

Deno.test('unknown amounts are null, never 0', () => {
  const v = statusView(held({ total_amount: null, deposit_amount: 'abc', pax: undefined }), NOW)!;
  assertEquals(v.money!.total, null);
  assertEquals(v.money!.reservation_payment, null);
  assertEquals(v.pax, null);
});

Deno.test('the view carries only allowed fields: no name, contact, address, door code or receipt path', () => {
  const allowed = ['state', 'ref', 'checkin_date', 'checkout_date', 'nights', 'pax', 'checkin_time', 'checkout_time', 'hold_expires_at', 'money', 'timeline', 'can_upload_receipt'].sort();
  assertEquals(Object.keys(statusView(held(), NOW)!).sort(), allowed);
  const hostile = { ...held(), guest_name: 'Zz Synthetic', guest_phone: '0000000000', guest_email: 'zz@example.invalid', receipt_image_path: 'x/y.jpg', door_code: '0000' } as unknown as StatusFacts;
  const text = JSON.stringify(statusView(hostile, NOW));
  for (const leak of ['Zz Synthetic', '0000000000', 'example.invalid', 'x/y.jpg', 'door_code']) assert(!text.includes(leak), leak);
});

Deno.test('guest-access/index.ts: the status branch reads through the RPC with the hash only, before any table read, and never logs', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  const status = src.indexOf("view === 'status'"), table = src.indexOf(".from('guest_access_tokens')");
  assert(status > 0 && table > status, 'status branch comes before the guide branch table reads');
  assert(src.includes("rpc('guest_booking_status_v1', { p_token_hash: tokenHash })"), 'RPC gets the hash, not the token');
  assert(!/console\.(log|error|warn|info|debug)/.test(src), 'no logging in guest-access');
  assert(src.includes('if (!facts) return invalid();'), 'invalid token gets the neutral 404');
});
