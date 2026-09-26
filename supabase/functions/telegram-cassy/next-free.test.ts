// deno test --no-check -A telegram-cassy/next-free.test.ts
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { firstOpenNight } from '../_shared/cascade-core/tools.ts';

Deno.test('first_open_night: the live 2026-09-26 calendar is free from Fri 2 Oct, not Mon 29 Sep', () => {
  const rows = [
    { checkin: '2026-09-25', checkout: '2026-09-27', status: 'confirmed' },
    { checkin: '2026-09-27', checkout: '2026-09-28', status: 'confirmed' },
    { checkin: '2026-09-28', checkout: '2026-10-02', status: 'confirmed' },
  ];
  assertEquals(firstOpenNight(rows, '2026-09-26', '2026-10-26'), '2026-10-02');
  assertEquals(firstOpenNight(rows, '2026-09-26', '2026-10-01'), null);                                    // all taken in the window
  assertEquals(firstOpenNight([{ ...rows[2], status: 'cancelled' }], '2026-09-28', '2026-10-26'), '2026-09-28'); // a cancelled stay frees its nights
});
