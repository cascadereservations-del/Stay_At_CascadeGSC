// deno test --no-check messenger-concierge/suzanne.test.ts
// Live 2026-09-26 13:01-13:16Z (Suzanne): "Available today?" got "Thank you. Check-in on Sep 26 is noted. Until which date
// would you like to stay?", "So is it available today?" got "Check-out would need to fall after Sep 26", and only
// "Tomorrow" reached the calendar - which said the night was taken. Lloyd: warmer, and optimised for conversion.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { answer, availabilityLine, nightsIn, opener, prompt, start, type Flow } from './booking.ts';
import { isCold, lintReply } from './voice.ts';
const now = new Date('2026-09-26T13:01:10Z'); // 21:01 Manila
const tonight = (f: Flow): Flow => ({ ...f, checkout: '2026-09-27' }); // index.ts's one-night probe
const alt = { start: '2026-10-02', end: '2026-10-03', nights: 1 };

Deno.test('Suzanne: "Available today?" is answered in the first reply, open or taken', () => {
  const f = start('Available today?', now);
  assertEquals([f.step, f.checkin, f.asked], ['checkout', '2026-09-26', 'availability']);
  const open = opener(f, 'Suzanne Ligason Boncales', availabilityLine(tonight(f), new Set(), null, now)) + prompt(f, null, false, now);
  assertEquals(open, "Hi Suzanne, thank you for reaching out to Cascade Hideaway. Tonight (Sep 26) is available, and we'd be glad to welcome you.\n\nHow many nights would you like to stay with us from tonight? A check-out date works just as well.");
  assertEquals((open.match(/thank you/gi) ?? []).length, 1); // thanked once
  assertEquals(lintReply(open, 'Available today?', { firstTurn: true }), []);
  const taken = availabilityLine(tonight(f), new Set(['2026-09-26']), alt, now, true);
  assertEquals(taken, "I'm sorry, tonight (Sep 26) is already reserved. The nearest open night is Oct 2, and we'd be glad to welcome you then.\n\nWould that night suit you? If other dates work better, just share them and we'll gladly check.");
  assertEquals(isCold(taken), false);
  for (const lang of ['en', 'tl', 'bis'] as const) {
    const line = availabilityLine({ ...tonight(f), lang }, new Set(['2026-09-26']), alt, now, true);
    assertEquals(lintReply(line, 'Available today?'), [], `${lang}: ${line}`);
    assertEquals(/already reserved|reserved na/i.test(line), true, lang); // index.ts RESERVED_RE resets the flow on it
    if (lang === 'bis') assertEquals(/\bpo\b/i.test(line), false, line);
    assertEquals(lintReply(prompt({ ...f, lang }, null, false, now)), [], lang);
  }
  // Without `offer` (the model-rewrite path, no flow to keep the window) there is no yes/no question to strand.
  assertEquals(availabilityLine(tonight(f), new Set(['2026-09-26']), alt, now).includes('suit you?'), false);
});

Deno.test('Suzanne: a yes to the offered night takes it; a maybe does not; a no closes gently', () => {
  const f: Flow = { step: 'dates', lang: 'en', alt, started_at: '', updated_at: '' };
  const yes = answer(f, 'Yes please', now);
  assertEquals([yes.action, yes.flow.checkin, yes.flow.checkout, yes.flow.step, yes.flow.alt], ['ask', '2026-10-02', '2026-10-03', 'pax', undefined]);
  assertEquals(answer(f, 'ok let me think', now).flow.checkin, undefined);
  assertEquals(answer(f, 'no thanks', now).action, 'cancelled');
  const other = answer(f, 'Oct 10 to 12 instead', now);
  assertEquals([other.flow.checkin, other.flow.checkout, other.flow.alt], ['2026-10-10', '2026-10-12', undefined]);
});

Deno.test('Suzanne: the check-out step takes nights, "tomorrow", and a repeated "available today?"', () => {
  const f = start('Available today?', now);
  assertEquals(answer(f, 'Tomorrow', now).flow.checkout, '2026-09-27');
  assertEquals(answer(f, '2 nights po', now).flow.checkout, '2026-09-28');
  assertEquals(answer(f, 'just one night', now).flow.checkout, '2026-09-27');
  const again = answer(f, 'So is it available today?', now);
  assertEquals([again.action, again.flow.checkout, again.flow.step], ['ask', '2026-09-27', 'pax']); // index.ts checks it on the calendar
  const same = answer(f, 'Sep 26', now); // not a question: the earliest check-out, warmly
  assertEquals(same.reply, 'Of course. With check-in on Sep 26, the earliest check-out is Sep 27. How many nights would you like to stay with us?');
  assertEquals(lintReply(same.reply!), []);
  assertEquals([nightsIn('3 nights'), nightsIn('isang gabi'), nightsIn('duha ka gabii'), nightsIn('Oct 5 please')], [3, 1, 2, null]);
});
