// deno test finance-watch/watch.test.ts  (run from supabase/functions)
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { renderReport } from '../_shared/cascade-core/format.ts';
import { watchReport, due } from './watch.ts';

Deno.test('cadence: day 2, day 5, then weekly; quiet in between', () => {
  assertEquals([1, 2, 3, 4, 5, 6, 11, 12, 13, 19, 26].map(due), [false, true, false, false, true, false, false, true, false, true, true]);
});

const today = '2026-09-14';
const paid = { confirmation_code: 'HMPAID0001', guest_name: 'Ana', checkin_date: '2026-09-10', host_payout: 3000, payout_email_message_id: 'abc', status: 'confirmed' };
const fresh = { confirmation_code: 'HMFRESH001', guest_name: 'Ben', checkin_date: '2026-09-13', host_payout: 3000, payout_email_message_id: null, status: 'confirmed' };
const late = { confirmation_code: 'HMLATE0001', guest_name: 'Cara', checkin_date: '2026-09-11', host_payout: 4517.1, payout_email_message_id: null, status: 'confirmed' };
const cancelled = { ...late, confirmation_code: 'HMCANC0001', status: 'cancelled' };
const dirOk = { id: '92f94d0e-008c-4439-9c94-6d48684629da', guest_name: 'Lo', checkin_date: '2026-09-20', deposit_amount: 890, submitted_at: '2026-09-10T02:00:00Z', receipt_image_path: 'r.jpg', status: 'pending' };
const dirNew = { ...dirOk, id: '11111111-0000-0000-0000-000000000000', receipt_image_path: null, submitted_at: '2026-09-14T01:00:00Z' };
const dirLate = { ...dirOk, id: '22222222-0000-0000-0000-000000000000', guest_name: 'Mia', receipt_image_path: null, submitted_at: '2026-09-11T10:00:00Z' };
const dirPast = { ...dirLate, id: '33333333-0000-0000-0000-000000000000', checkin_date: '2026-09-12' };

Deno.test('nothing overdue is null: paid, fresh, cancelled, receipted, same-day and past check-in rows are all quiet', () => {
  assertEquals(watchReport(today, [paid, fresh, cancelled], [dirOk, dirNew, dirPast]), null);
});

Deno.test('overdue rows are listed oldest first, the oldest owns the action, and the render has no model line', () => {
  const r = watchReport(today, [late, fresh], [dirLate])!;
  assertEquals(r.decision, '2 payments overdue, ₱5,407.1 in total.');
  assertEquals(r.lines, [
    'Airbnb HMLATE0001 Cara: checked in 11 Sep, ₱4,517.1 payout not received (3 days)',
    'Direct DIR-22222222 Mia: check-in 20 Sep, ₱890 reservation fee unpaid (3 days)',
  ]);
  assertEquals(r.action, 'Check Airbnb → Earnings for HMLATE0001 (Cara); if it was paid, forward the payout email so the sync records it.');
  const onlyDirect = watchReport(today, [], [dirLate])!;
  assertEquals(onlyDirect.action, 'Message Mia for the ₱890 reservation fee, or cancel DIR-22222222 if the dates should be released.');
  assertEquals(renderReport(r).includes('— '), false);
});
