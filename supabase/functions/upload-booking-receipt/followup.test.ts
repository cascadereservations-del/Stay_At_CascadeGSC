// deno test --no-check upload-booking-receipt/followup.test.ts  (from supabase/functions)
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { guestFollowUp, verdictOf } from './followup.ts';
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
