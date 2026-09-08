import { assertEquals, assertThrows } from 'jsr:@std/assert@1';
import { addDays, manilaDate, turnoverWindow } from './manila-dates.ts';

Deno.test('manilaDate returns a parseable YYYY-MM-DD, not an Invalid Date (v9 regression)', () => {
  // 2026-09-07 23:30 UTC is already 2026-09-08 in Manila (UTC+8).
  assertEquals(manilaDate(new Date('2026-09-07T23:30:00Z')), '2026-09-08');
  assertEquals(manilaDate(new Date('2026-09-07T15:59:00Z')), '2026-09-07');
});

Deno.test('the v9 expression this replaces really did produce an Invalid Date', () => {
  const broken = new Date(new Date('2026-09-07T16:00:00Z').toLocaleString('en-CA', { timeZone: 'Asia/Manila' }));
  assertEquals(Number.isNaN(broken.getTime()), true);
  assertThrows(() => broken.toISOString(), RangeError);
});

Deno.test('addDays crosses month and year boundaries', () => {
  assertEquals(addDays('2026-09-08', -1), '2026-09-07');
  assertEquals(addDays('2026-03-01', -1), '2026-02-28');
  assertEquals(addDays('2026-01-01', -2), '2025-12-30');
  assertEquals(addDays('2024-03-01', -1), '2024-02-29');
});

Deno.test('addDays rejects a malformed date instead of silently returning NaN', () => {
  assertThrows(() => addDays('not-a-date', -1), Error, 'invalid_date');
});

Deno.test('turnoverWindow yields the T-1 and T-2 checkout dates the cron run inspects', () => {
  // The real 00:00 UTC cron moment, which is 08:00 Manila the same day.
  assertEquals(turnoverWindow(new Date('2026-09-08T00:00:00Z')), {
    today: '2026-09-08',
    yesterday: '2026-09-07',
    twoDaysAgo: '2026-09-06',
  });
});
