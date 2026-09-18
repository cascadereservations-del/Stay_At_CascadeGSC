// Pins the meter-photo allowance. The rule it guards is Lloyd's: a cleaner may skip the meter photos
// once with a reason, never twice running. It shipped on the checklist on 2026-09-13 and the deployed
// function silently dropped the fields until 2026-09-18, so these assertions exist to make that
// impossible to repeat: if the codes or the consecutive check change, this fails.
import { assertEquals } from 'jsr:@std/assert';
import { meterReasons, parseMeterSkip } from './meter-skip.ts';

Deno.test('a skip counts only when declared AND carrying a reason', () => {
  assertEquals(parseMeterSkip(true, 'meter room locked').skipped, true);
  assertEquals(parseMeterSkip(true, '   ').skipped, false, 'blank note is not a reason');
  assertEquals(parseMeterSkip(true, 'ok').skipped, false, 'a two-character note is not a reason');
  assertEquals(parseMeterSkip(false, 'meter room locked').skipped, false, 'note without the flag');
  assertEquals(parseMeterSkip('true', 'meter room locked').skipped, false, 'the string "true" is not true');
  assertEquals(parseMeterSkip(true, undefined).skipped, false);
});

Deno.test('the note is trimmed and capped at 300 characters', () => {
  assertEquals(parseMeterSkip(true, '  locked  ').note, 'locked');
  assertEquals(parseMeterSkip(true, 'x'.repeat(400)).note.length, 300);
  assertEquals(parseMeterSkip(true, 42).note, '', 'a non-string note is no note');
});

Deno.test('two meter photos means no reason at all', () => {
  assertEquals(meterReasons(2, false, false), []);
  assertEquals(meterReasons(3, true, true), [], 'photos present beat any declaration');
});

Deno.test('a declared skip reads differently from photos simply missing', () => {
  assertEquals(meterReasons(0, false, false), ['meter_photos_0_of_2']);
  assertEquals(meterReasons(0, true, false), ['meter_photos_skipped_declared_0_of_2']);
  assertEquals(meterReasons(1, true, false), ['meter_photos_skipped_declared_1_of_2']);
});

Deno.test('never two in a row: the second consecutive declared skip is flagged', () => {
  assertEquals(meterReasons(0, true, true), [
    'meter_photos_skipped_declared_0_of_2',
    'meter_skip_consecutive_not_permitted',
  ]);
});

Deno.test('an undeclared shortfall after a skipped turnover is NOT a consecutive skip', () => {
  // Photos merely missing is not a claimed allowance, so it must not inherit the previous skip.
  assertEquals(meterReasons(0, false, true), ['meter_photos_0_of_2']);
});

Deno.test('a skip is always incomplete: it never returns an empty reason list', () => {
  for (const prev of [true, false]) {
    for (const count of [0, 1]) {
      const reasons = meterReasons(count, true, prev);
      assertEquals(reasons.length > 0, true, `count ${count}, previous ${prev}`);
    }
  }
});
