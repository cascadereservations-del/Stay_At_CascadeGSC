import { assertEquals, assertNotEquals } from 'jsr:@std/assert@1';
import { manilaWeekday, sweepShouldNotify, sweepSignature } from './sweep-notify.ts';

Deno.test('a new or changed set of problem rows is reported', () => {
  assertEquals(sweepShouldNotify(3, 'abc', null, 3), true);
  assertEquals(sweepShouldNotify(3, 'abc', 'xyz', 3), true);
});

Deno.test('the same set is silent on weekdays and reported again on Monday', () => {
  assertEquals(sweepShouldNotify(3, 'abc', 'abc', 3), false);
  assertEquals(sweepShouldNotify(3, 'abc', 'abc', 1), true);
});

Deno.test('a clean sweep never reports', () => {
  assertEquals(sweepShouldNotify(0, '', 'abc', 1), false);
});

Deno.test('the fingerprint ignores order and changes with the set', async () => {
  assertEquals(await sweepSignature(['b', 'a']), await sweepSignature(['a', 'b']));
  assertNotEquals(await sweepSignature(['a']), await sweepSignature(['a', 'b']));
});

Deno.test('Monday is a Manila Monday', () => {
  // 2026-09-27 17:00Z is Monday 2026-09-28 01:00 in Manila.
  assertEquals(manilaWeekday(new Date('2026-09-27T17:00:00Z')), 1);
});
