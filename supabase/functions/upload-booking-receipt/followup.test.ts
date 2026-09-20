// deno test --no-check upload-booking-receipt/followup.test.ts  (from supabase/functions)
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { CAPTION_MAX, guestFollowUp, hostDoLine, overpaymentLines, priorUseLines, verdictOf, type PriorUse } from './followup.ts';
import { groups, doSend } from '../_shared/cascade-core/format.ts';
import { lintReply } from '../messenger-concierge/voice.ts';
import { templateOf, TEMPLATE_MARK } from '../_shared/cascade-core/format.ts';

Deno.test('verdict: the Maya pre-send screen (amount null) is not a proof; short and match by amount', () => {
  assertEquals(verdictOf(null, 1691), 'unread');
  assertEquals(verdictOf({ amount: null }, 1691), 'not_proof');
  assertEquals(verdictOf({ amount: 1691 }, 1691), 'match');
  assertEquals(verdictOf({ amount: 1000 }, 1691), 'short');
  assertEquals(verdictOf({ amount: 3382 }, 1691), 'over');
});

Deno.test('sample replies: one paragraph, pass the voice lint, no po in Bisaya, exact amounts', () => {
  for (const lang of ['en', 'tl', 'bis'] as const) for (const v of ['not_proof', 'short'] as const) {
    const m = guestFollowUp(v, lang, 'Ben Cruz', 1691, 1000);
    assertEquals(lintReply(m), [], `${lang}/${v}`);
    assertEquals(/\n/.test(m), false);
    assertEquals(m.startsWith('Hi Ben'), true);
    assertEquals(m.includes('₱1,691'), true);
    if (v === 'short') assertEquals(m.includes('₱691'), true);
    if (lang === 'bis') assertEquals(/\b(po|opo)\b/i.test(m), false);
    assertEquals(templateOf(`card\n\nDo: send\n${TEMPLATE_MARK}${m}`), m); // the Copy tap reads it back whole
  }
  assertEquals(guestFollowUp('match', 'en', 'Ben', 1691, 1691), '');
});

// --- SPEC-10 fraud lines (host-facing, English) --------------------------------------------

const HIT = (over: Partial<PriorUse> = {}): PriorUse => ({
  booking_id: '9f3c1a2b-4d5e-4f60-8a71-b2c3d4e5f607',
  guest_name: 'Mia Santos',
  seen_at: '2026-09-12T04:05:06Z',
  match: 'image',
  ...over,
});

Deno.test('control 3: no prior use means no group at all, so the ordinary card is unchanged', () => {
  assertEquals(priorUseLines([]), []);
});

Deno.test('control 3: a reused image names the other booking, its guest and the date', () => {
  assertEquals(priorUseLines([HIT()]), [
    "⚠️ This receipt's image was already used for DIR-9F3C1A2B (Mia, 2026-09-12).",
    'It may be an honest resend. Check before confirming.',
  ]);
});

Deno.test('control 3: a reference match says so, and extra hits are counted not listed', () => {
  const lines = priorUseLines([HIT({ match: 'reference' }), HIT(), HIT()]);
  assertEquals(lines[0], "⚠️ This receipt's reference number was already used for DIR-9F3C1A2B (Mia, 2026-09-12) and 2 others.");
  assertEquals(lines.length, 2); // never more than the group cap, however many hits there are
  assertEquals(priorUseLines([HIT({ match: 'reference' }), HIT()])[0].endsWith('and 1 other.'), true);
  assertEquals(priorUseLines([HIT({ guest_name: null })])[0].includes('(another guest, '), true);
});

Deno.test('control 2: the Do line sends the host to the wallet, and stays silent when there is no amount', () => {
  assertEquals(
    hostDoLine('match', 1691, 'ABC12345'),
    'Do: open GCash / Maya and find ₱1,691 from the guest, ref ABC12345, BEFORE confirming. A screenshot is not money.',
  );
  assertEquals(hostDoLine('short', 1000, null), 'Do: open GCash / Maya and find ₱1,000 from the guest, BEFORE confirming. A screenshot is not money.');
  assertEquals(hostDoLine('over', 3382, 'X1')?.includes('A screenshot is not money.'), true);
  // not_proof and unread keep the caller's own wording: there is no amount to go and find.
  assertEquals(hostDoLine('not_proof', null, null), null);
  assertEquals(hostDoLine('unread', null, null), null);
  assertEquals(hostDoLine('match', null, 'ABC12345'), null);
});

Deno.test('control 4: an overpayment is named as the refund-scam opening it usually is', () => {
  assertEquals(overpaymentLines(3382, 1691), [
    '⚠️ Paid MORE than asked (₱3,382 vs ₱1,691).',
    'A common scam is a fake overpayment followed by a refund request.',
    'Refund only to the sending account, only after the money is visibly in the wallet.',
  ]);
});

// notifyFinance sends the card as a photo caption, which Telegram caps at CAPTION_MAX and used to
// truncate with .slice(). The 📨 line the Copy / Revise taps read back sits at the very END of the
// card, so a truncation would take exactly that. These two pin which cards fit and which must be
// sent as their own message instead.
const LINK = '🔗 https://cascadereservations-del.github.io/cascade-admin-dashboard/#/bookings/direct/9f3c1a2b-4d5e-4f60-8a71-b2c3d4e5f607';
const card = (first: string[], over: string[], doLine: string, sample: string) =>
  '💰 FINANCE · receipt 9F3C1A2B\n\n' + groups(
    first,
    ['📎 Receipt uploaded — Bernadette Villanueva', '📅 2026-10-01 → 2026-10-09 · status pending_payment'],
    ['💳 Expected: ₱16,910 of ₱33,820', '🔍 Read: ₱33,820 via GCash · ref ABC12345678 · 2026-09-20 · 97 %', '⚖️ ₱16,910 over — expected ₱16,910'],
    over,
    [doLine, LINK],
    sample ? doSend('the guest', sample) : [],
  );

Deno.test('the ordinary card - no duplicate, no overpayment - still fits one photo caption', () => {
  const c = card([], [], hostDoLine('short', 1000, 'ABC12345678')!, guestFollowUp('short', 'tl', 'Bernadette Villanueva', 16910, 1000));
  assertEquals(c.length <= CAPTION_MAX, true, `ordinary card is ${c.length} characters and must not need splitting`);
});

Deno.test('the worst card overflows the caption, which is why it is sent as its own message', () => {
  const c = card(
    priorUseLines([HIT({ match: 'reference' }), HIT(), HIT()]),
    overpaymentLines(33820, 16910),
    hostDoLine('over', 33820, 'ABC12345678')!,
    guestFollowUp('short', 'tl', 'Bernadette Villanueva', 16910, 1000),
  );
  // If this ever stops overflowing the split branch is dead code, so assert the reason it exists.
  assertEquals(c.length > CAPTION_MAX, true, `worst card is ${c.length} characters; the split branch assumes it exceeds ${CAPTION_MAX}`);
  assertEquals(c.trimEnd().endsWith(guestFollowUp('short', 'tl', 'Bernadette Villanueva', 16910, 1000)), true,
    'the sample reply is last, so a truncated caption would lose exactly the line the Copy tap reads');
});
