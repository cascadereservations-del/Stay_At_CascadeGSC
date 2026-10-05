// deno test _shared/guest-access-mint.test.ts
// SPEC-42 s6: the status-token mint used by submit-booking, and its expiry.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { hashGuestAccessToken, mintStatusToken, statusTokenExpiry } from './guest-access-token.ts';

const booking = { propertyId: 'p1', bookingId: 'b1', checkoutDate: '2026-10-18' };

Deno.test('status token expires 7 days after the Manila midnight of check-out', () => {
  assertEquals(statusTokenExpiry('2026-10-18').toISOString(), '2026-10-24T16:00:00.000Z');
  let threw = false;
  try { statusTokenExpiry('not-a-date'); } catch { threw = true; }
  assertEquals(threw, true);
});

Deno.test('mint stores only the hash, a 7-day expiry and a direct booking type, and returns the raw token once', async () => {
  const rows: Record<string, unknown>[] = [];
  const token = await mintStatusToken({ insert: (row) => { rows.push(row); return Promise.resolve({ error: null }); } }, booking);
  assertEquals(/^[A-Za-z0-9_-]{43}$/.test(token ?? ''), true);
  assertEquals(rows.length, 1);
  assertEquals(rows[0].token_hash, await hashGuestAccessToken(token!));
  assertEquals(JSON.stringify(rows[0]).includes(token!), false);
  assertEquals(rows[0].booking_type, 'direct');
  assertEquals(rows[0].booking_id, 'b1');
  assertEquals(rows[0].expires_at, '2026-10-24T16:00:00.000Z');
});

Deno.test('two mints never repeat, and a failed insert yields no link', async () => {
  const sink = { insert: () => Promise.resolve({ error: null }) };
  const a = await mintStatusToken(sink, booking);
  const b = await mintStatusToken(sink, booking);
  assertEquals(a === b, false);
  assertEquals(await mintStatusToken({ insert: () => Promise.resolve({ error: { message: 'boom' } }) }, booking), null);
});
