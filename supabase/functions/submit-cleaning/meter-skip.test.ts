// Pins the meter-photo allowance. The rule it guards is Lloyd's: a cleaner may skip the meter photos
// once with a reason, never twice running. It shipped on the checklist on 2026-09-13 and the deployed
// function silently dropped the fields until 2026-09-18, so these assertions exist to make that
// impossible to repeat: if the codes or the consecutive check change, this fails.
import { assertEquals } from 'jsr:@std/assert@1';
import {
  meterReasons, parseMeterSkip,
  METER_BLOCKING_TYPES, METER_BLOCK_LOOKBACK_DAYS, meterBlockMessage,
  meterBackwardsMessage, METER_WRONG_NUMBER_FLAGS,
} from './meter-skip.ts';

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

/* The block half (2026-09-21). What can go wrong here is not arithmetic: it is
   blocking someone who should not be blocked, and letting through someone who
   should not be. Both are pinned. */

Deno.test('only a turnover or a deep clean can be blocked', () => {
  const rows = [{ recorded_at: '2026-09-15T22:10:00Z' }];
  for (const t of ['turnover', 'deep_clean']) {
    assertEquals(typeof meterBlockMessage(t, rows), 'string', `${t} is blocked`);
  }
  for (const t of ['mid_stay', 'emergency', 'regular', '']) {
    assertEquals(meterBlockMessage(t, rows), null, `${t} is never blocked`);
  }
  assertEquals(METER_BLOCKING_TYPES.has('mid_stay'), false, 'a guest is still in the unit');
});

Deno.test('nothing unresolved means nothing blocked', () => {
  assertEquals(meterBlockMessage('turnover', []), null);
  assertEquals(meterBlockMessage('turnover', null), null);
  assertEquals(meterBlockMessage('turnover', undefined), null);
});

Deno.test('the refusal names the day in Manila and tells her what to do', () => {
  // 2026-09-15 22:10Z is already the 16th in Manila. A cleaner looking for
  // "Sep 15" on her phone would not find the report she is being asked about.
  const msg = meterBlockMessage('turnover', [{ recorded_at: '2026-09-15T22:10:00Z' }])!;
  assertEquals(msg.includes('Sep 16'), true, 'the date is the Manila date');
  assertEquals(msg.includes('Open the checklist again'), true, 'it says what to do');
  assertEquals(/[0-9a-f]{8}-[0-9a-f]{4}/.test(msg), false, 'no row id is ever shown to her');
});

Deno.test('a mismatch with no timestamp still refuses, and still reads as a sentence', () => {
  const msg = meterBlockMessage('turnover', [{ recorded_at: null }])!;
  assertEquals(msg.includes('an earlier report'), true);
  assertEquals(msg.includes('undefined'), false);
  assertEquals(msg.includes('Invalid Date'), false);
});

Deno.test('the lookback matches the sign-in card, or the two can disagree', () => {
  assertEquals(METER_BLOCK_LOOKBACK_DAYS, 14, 'get_meter_photo_followups p_lookback default');
});

// D-219 (Lloyd 2026-09-23): a backwards reading is refused, not nudged. The 2026-07-01 row re-typed the
// 2026-06-21 numbers (3003 -> 2931 kWh, 57.547 -> 56.598 m3) and nothing stopped it.
Deno.test('a reading below the last one is refused, naming the meter and the last number', () => {
  const m = meterBackwardsMessage(2931, 3003, 56.598, 57.547);
  assertEquals(typeof m, 'string');
  assertEquals(m!.includes('electric 2931 kWh is lower than the last reading (3003)'), true);
  assertEquals(m!.includes('water 56.598 m³ is lower than the last reading (57.547)'), true);
  assertEquals(m!.includes('message Lloyd'), true);
  assertEquals(meterBackwardsMessage(39.675, null, 39.675, 39.782)!.startsWith('The water 39.675'), true);
});

Deno.test('a forward, equal, missing or first reading is never refused', () => {
  assertEquals(meterBackwardsMessage(3163, 2931, 59.474, 56.598), null);
  assertEquals(meterBackwardsMessage(3003, 3003, 57.547, 57.547), null);   // same number is a nudge, not a block
  assertEquals(meterBackwardsMessage(null, 3003, null, 57.547), null);
  assertEquals(meterBackwardsMessage(NaN, 3003, NaN, 57.547), null);
  assertEquals(meterBackwardsMessage(1636, null, 36.871, null), null);
});

Deno.test('only flags that mean wrong numbers are skipped as the previous reading', () => {
  assertEquals([...METER_WRONG_NUMBER_FLAGS].sort(), ['duplicate', 'misread', 're_entry']);
  assertEquals(METER_WRONG_NUMBER_FLAGS.includes('first_reading'), false);
});
