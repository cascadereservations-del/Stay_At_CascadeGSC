// deno test supabase/functions/upload-booking-receipt/payer.test.ts - SPEC-42 9a: the payer of a receipt is kept, first receipt wins.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { payerOf, storePayer } from './payer.ts';

function fakeDb(result: { error: unknown } | 'throw') {
  const calls: Record<string, unknown>[] = [];
  const q = {
    update(patch: Record<string, unknown>) { calls.push({ update: patch }); return q; },
    eq(col: string, v: unknown) { calls.push({ eq: [col, v] }); return q; },
    is(col: string, v: unknown) { calls.push({ is: [col, v] }); return result === 'throw' ? Promise.reject(new Error('boom')) : Promise.resolve(result); },
  };
  return { calls, db: { from: (t: string) => { calls.push({ from: t }); return q; } } };
}

Deno.test('payerOf: trims, collapses spaces, caps length; no name means no payer', () => {
  assertEquals(payerOf({ sender_name: '  Synthetic   Payer ', channel: ' GCash ' }), { name: 'Synthetic Payer', channel: 'GCash' });
  assertEquals(payerOf({ sender_name: 'Synthetic Payer', channel: null }), { name: 'Synthetic Payer', channel: null });
  assertEquals(payerOf({ sender_name: null, channel: 'GCash' }), null);
  assertEquals(payerOf({ sender_name: '   ', channel: 'GCash' }), null);
  assertEquals(payerOf(null), null);
  const long = payerOf({ sender_name: 'x'.repeat(200), channel: 'y'.repeat(99) })!;
  assertEquals(long.name.length, 80);
  assertEquals(long.channel!.length, 40);
});

Deno.test('storePayer writes only while paid_from_name is still null (first receipt wins, never overwritten)', async () => {
  const { db, calls } = fakeDb({ error: null });
  assertEquals(await storePayer(db, 'b1', { sender_name: 'Synthetic Payer', channel: 'GCash' }), true);
  assertEquals(calls, [{ from: 'booking_inquiries' }, { update: { paid_from_name: 'Synthetic Payer', paid_from_channel: 'GCash' } }, { eq: ['id', 'b1'] }, { is: ['paid_from_name', null] }]);
});

Deno.test('storePayer does nothing when the read has no sender name', async () => {
  const { db, calls } = fakeDb({ error: null });
  assertEquals(await storePayer(db, 'b1', { sender_name: null, channel: 'GCash' }), false);
  assertEquals(calls.length, 0);
});

Deno.test('storePayer never throws: a database error or a rejected call leaves the receipt flow intact', async () => {
  assertEquals(await storePayer(fakeDb({ error: { message: 'denied' } }).db, 'b1', { sender_name: 'A B', channel: null }), false);
  assertEquals(await storePayer(fakeDb('throw').db, 'b1', { sender_name: 'A B', channel: null }), false);
});
