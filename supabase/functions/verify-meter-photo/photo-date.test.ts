// deno test supabase/functions/verify-meter-photo/photo-date.test.ts
import { assertEquals } from 'jsr:@std/assert@1';
import { photoDateLines } from './photo-date.ts';

const files = (e?: string, w?: string) => [
  { section: 'section_afterclean', fileId: 'X', taken_at: '2026-01-01T00:00:00Z' },
  { section: 'Meter_Readings', fileId: 'E', ...(e ? { taken_at: e } : {}) },
  { section: 'Meter_Readings', fileId: 'W', ...(w ? { taken_at: w } : {}) },
];

Deno.test('checkout day -1..+1 (Manila dates) is silent; two days off is one line naming both dates', () => {
  // 2026-10-20T17:00Z is 21 Oct 01:00 in Manila
  assertEquals(photoDateLines(files('2026-10-20T17:00:00Z', '2026-10-21T20:00:00Z'), '2026-10-21'), []);
  assertEquals(photoDateLines(files('2026-10-23T02:00:00Z', '2026-10-22T02:00:00Z'), '2026-10-21'),
    ['Electric photo taken Oct 23, checkout Oct 21']);
  assertEquals(photoDateLines(files('2026-10-19T02:00:00Z', '2026-10-18T02:00:00Z'), '2026-10-21'),
    ['Electric photo taken Oct 19, checkout Oct 21', 'Water photo taken Oct 18, checkout Oct 21']);
});

Deno.test('unknown anything is silent: no taken_at, no archive, bad checkout', () => {
  assertEquals(photoDateLines(files(), '2026-10-21'), []);
  assertEquals(photoDateLines(null, '2026-10-21'), []);
  assertEquals(photoDateLines(files('2026-10-23T02:00:00Z'), null), []);
  assertEquals(photoDateLines(files('garbage'), '2026-10-21'), []);
});

Deno.test('s103 review: a lone water photo is labelled Water from its stored slot', () => {
  const only = [{ section: 'Meter_Readings', taken_at: '2026-10-23T02:00:00Z', meter: 'water' }];
  assertEquals(photoDateLines(only, '2026-10-21'), ['Water photo taken Oct 23, checkout Oct 21']);
});
