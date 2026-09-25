// SPEC-28 (D-231): the Taglish rate answer is measured, a first message with dates AND a question gets both answered,
// the taken reply with the Cassy sentence has paragraphs, one language detector, example dates never in the past.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { availabilityLine, detectLang, exampleDates, greetBlock, guestLang, opener, otherQuestions, prompt, start } from './booking.ts';
import { lintReply, offRegister } from './voice.ts';
import { rollExampleDates, VOICE } from '../_shared/cascade-core/facts.ts';

const now = new Date('2026-09-25T00:00:00Z');

Deno.test('SPEC-28 s1: English with one "po" is off-register for a Taglish turn; the new example is not', () => {
  // The old facts.ts example, which the live 2026-09-24 reply copied almost verbatim.
  const live = 'Ben, for 3 nights po, the direct rate comes down to PHP 1,691 per night from PHP 1,780, so about PHP 5,073 for the whole stay.';
  assertEquals(offRegister(live, 'tl'), true);
  const example = VOICE.split('Q: magkano po kung 3 nights?')[1].split('\nQ:')[0];
  assertEquals(offRegister(example, 'tl'), false);
  assertEquals(/1,691/.test(example) && /5,073/.test(example), true);
  // An English turn with a courtesy "po" is judged as English, where one "po" is fine.
  assertEquals(offRegister('Yes po, there is free parking right in front of the unit, inside the gated community, with an outdoor camera watching the area.', 'en'), false);
});

Deno.test('SPEC-28 s2: a first message with dates and another question records both', () => {
  const both = start('Hi, is Oct 26 to 28 open? Is there wifi?', now);
  assertEquals([both.asked, both.question], ['availability', true]);
  assertEquals(start('is Oct 26 to 28 open?', now).question, false);
  assertEquals(start('is Oct 26 to 28 open? Oct 27?', now).question, false); // a bare "?" is not a second question
  assertEquals(start('Available po ba ang Oct 26 to 28? May parking po ba?', now).question, true);
  // The model is handed only the other question: the calendar line answers the dates (golden 2026-09-25).
  assertEquals(otherQuestions('Hi, is Oct 26 to 28 open? Is there wifi?'), 'Is there wifi?');
  // The flow's part that follows the model's answer carries no greeting of its own (the double greeting).
  const f = both;
  const follow = opener(f, 'Ben', availabilityLine(f, new Set()), false, false);
  assertEquals(/thank you for reaching out|^Hi /i.test(follow), false);
  assertEquals(follow.startsWith('Oct 26 to 28 is'), true);
});

Deno.test('SPEC-28 s3: the first reply with the Cassy sentence puts the answer on its own paragraph', () => {
  const f = { ...start('Hello, is Oct 26 to 28 available?', now), lang: 'en' as const };
  const taken = availabilityLine(f, new Set(['2026-10-26']), { start: '2026-11-01', end: '2026-11-06', nights: 5 });
  const reply = greetBlock('Ben', 'en', true) + taken;
  const paras = reply.split(/\n\s*\n/);
  assertEquals(paras.length >= 2, true);
  assertEquals(paras[0].length < 320, true);
  assertEquals(lintReply(reply, 'Hello, is Oct 26 to 28 available?', { firstTurn: true, name: 'Ben' }), []);
  // Without the Cassy sentence the greeting and the answer stay Lloyd's approved one paragraph.
  assertEquals(greetBlock('Ben', 'en', false).includes('\n'), false);
});

Deno.test('SPEC-28 s4: one detector - "pwede ba" is Taglish everywhere; the example dates are always ahead', () => {
  assertEquals(guestLang('pwede ba mag early check-in?'), 'taglish');
  assertEquals(detectLang('pwede ba mag early check-in?'), 'tl');
  assertEquals(detectLang('naa moy parking?'), 'bis');
  assertEquals(detectLang('how far from SM po'), 'en');
  assertEquals(exampleDates(now), 'Oct 2 to 4');
  const ask = prompt({ step: 'dates', started_at: '', updated_at: '', lang: 'en' }, null, false, now);
  assertEquals(ask.includes('"Oct 2 to 4"'), true);
  assertEquals(ask.includes('Sep 24'), false);
});

Deno.test('D-241.5: the prompt examples roll forward in whole weeks and keep the live quotes', () => {
  const ex = 'Oct 26-28 (taken; Nov 1-6 open). Available Oct 30? stay through Nov 1. Oct 27 to 29. live: "is Oct 3 to 4 available?"';
  assertEquals(rollExampleDates(ex, new Date('2026-09-25T00:00:00Z')), ex); // Oct 26 is still 31 days out
  const later = rollExampleDates(ex, new Date('2026-10-20T00:00:00Z'));  // 24 days past the trigger -> 4 weeks
  assertEquals(later, 'Nov 23-25 (taken; Nov 29-Dec 4 open). Available Nov 27? stay through Nov 29. Nov 24 to 26. live: "is Oct 3 to 4 available?"');
});
