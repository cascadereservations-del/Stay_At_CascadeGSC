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
