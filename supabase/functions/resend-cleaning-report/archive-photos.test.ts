// deno test resend-cleaning-report/archive-photos.test.ts  (run from supabase/functions)
import { assertEquals } from 'jsr:@std/assert@1';
import { drivePhotos } from './archive-photos.ts';

Deno.test('stored Drive files become driveFileId photos, grouped by their original section', () => {
  const p = drivePhotos([
    { section: 'meterPhotos', name: 'photo_1.jpg', fileId: 'A1', url: 'https://drive.google.com/file/d/A1/view' },
    { section: 'meterPhotos', name: 'photo_2.jpg', fileId: 'A2', url: 'https://drive.google.com/file/d/A2/view' },
    { section: 'section_afterclean', name: 'photo_1.jpg', fileId: 'B1', url: 'https://drive.google.com/file/d/B1/view' },
  ]);
  assertEquals(Object.keys(p ?? {}), ['meterPhotos', 'section_afterclean']);
  assertEquals(p?.meterPhotos.map((x) => x.driveFileId), ['A1', 'A2']);
});

Deno.test('no stored list (null, [], not an array) falls back to Storage', () => {
  assertEquals(drivePhotos(null), null);
  assertEquals(drivePhotos([]), null);
  assertEquals(drivePhotos({ fileId: 'A1' }), null);
});

Deno.test('entries without a file id are skipped; all-bad means fall back', () => {
  assertEquals(drivePhotos([{ section: 'x', name: 'n' }, null]), null);
});

import { carryMeterTags } from './archive-photos.ts';
Deno.test('carryMeterTags keeps taken_at and meter by position when meter counts match', () => {
  const old = [
    { section: 'section_meter', taken_at: '2026-10-22T01:00:00.000Z', meter: 'water' },
    { section: 'section_meter', taken_at: null },
    { section: 'section_afterclean', taken_at: 'ignored' },
  ];
  const next = [{ section: 'section_afterclean' }, { section: 'section_meter' }, { section: 'section_meter' }] as Record<string, unknown>[];
  const out = carryMeterTags(old, next as never) as Record<string, unknown>[];
  assertEquals(out[1], { section: 'section_meter', taken_at: '2026-10-22T01:00:00.000Z', meter: 'water' });
  assertEquals(out[2], { section: 'section_meter', taken_at: null });
  assertEquals('taken_at' in out[0], false);
});

Deno.test('carryMeterTags leaves the list alone on a count mismatch, no old list, or null', () => {
  const next = [{ section: 'section_meter' }];
  assertEquals(carryMeterTags([{ section: 'section_meter', taken_at: 'x' }, { section: 'section_meter' }], next as never), [{ section: 'section_meter' }]);
  assertEquals(carryMeterTags(null, next as never), [{ section: 'section_meter' }]);
  assertEquals(carryMeterTags([], null), null);
});
