import { assertEquals } from 'jsr:@std/assert@1';
import { manilaDateDaysAgo, missedCleaningStep } from './cadence.ts';

Deno.test('day 1 alerts, day 3 reminds, day 2 is silent', () => {
  assertEquals(missedCleaningStep(0), 'alert');
  assertEquals(missedCleaningStep(1), 'alert');
  assertEquals(missedCleaningStep(2), 'silent');
  assertEquals(missedCleaningStep(3), 'remind');
});

Deno.test('from day 4 it is a task, never another message', () => {
  for (const d of [4, 5, 9, 13, 14]) assertEquals(missedCleaningStep(d), 'task');
});

Deno.test('the window start is a Manila date', () => {
  // 2026-09-22 20:00Z is already 2026-09-23 in Manila.
  assertEquals(manilaDateDaysAgo(0, new Date('2026-09-22T20:00:00Z')), '2026-09-23');
  assertEquals(manilaDateDaysAgo(13, new Date('2026-09-22T20:00:00Z')), '2026-09-10');
});
