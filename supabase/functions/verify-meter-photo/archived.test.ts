// deno test supabase/functions/verify-meter-photo/archived.test.ts
import { assertEquals } from 'jsr:@std/assert@1';
import { meterPhotosArchived } from './archived.ts';

const NONE = { electric: null, water: null };
const archived = { session_folder_id: 'FOLDER0000001', drive_files: [
  { section: 'section_afterclean', fileId: 'F000000001', name: 'photo_1.jpg' },
  { section: 'Meter_Readings', fileId: 'F000000002', name: 'photo_1.jpg' },
] };

Deno.test('expired session: no meter photo in Storage and one in the Drive archive is answered as archived', () => {
  assertEquals(meterPhotosArchived(archived, NONE), true);
  assertEquals(meterPhotosArchived({ ...archived, drive_files: [{ section: 'section_meter', fileId: 'F000000009' }] }, NONE), true);
});

Deno.test('a meter photo still in Storage is checked as before, archive or not', () => {
  assertEquals(meterPhotosArchived(archived, { electric: 'p/u/s/a.jpg', water: null }), false);
  assertEquals(meterPhotosArchived(archived, { electric: null, water: 'p/u/s/b.jpg' }), false);
});

Deno.test('no archive, no folder, or no meter photo in the archive is NOT "archived" (a missing photo stays a finding)', () => {
  assertEquals(meterPhotosArchived(null, NONE), false);
  assertEquals(meterPhotosArchived({ session_folder_id: null, drive_files: archived.drive_files }, NONE), false);
  assertEquals(meterPhotosArchived({ session_folder_id: 'F', drive_files: null }, NONE), false);
  assertEquals(meterPhotosArchived({ session_folder_id: 'F', drive_files: [{ section: 'section_afterclean', fileId: 'F000000001' }] }, NONE), false);
  assertEquals(meterPhotosArchived({ session_folder_id: 'F', drive_files: [{ section: 'Meter_Readings' }, { section: 'Meter_Readings', fileId: ' ' }] }, NONE), false);
});
