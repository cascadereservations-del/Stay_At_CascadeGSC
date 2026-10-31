// deno test submit-cleaning/drive-archive.test.ts  (run from supabase/functions)
// SPEC-15 phase 1: the Drive ids Code.gs returns are stored, and nothing malformed is.
import { assertEquals } from 'jsr:@std/assert@1';
import { parseDriveArchive, archiveNotice } from './drive-archive.ts';

const FOLDER = '1j2MWMMB4amKHY3hGbtJllMxry3DKo5RM';
const FILE = '1AbCdEfGhIjKlMnOpQrStUvWxYz012345';
const ok = (extra: Record<string, unknown> = {}) => JSON.stringify({
  result: 'success', status: 'success', folderId: FOLDER,
  folderUrl: `https://drive.google.com/drive/folders/${FOLDER}`, ...extra,
});

Deno.test('v3.10 body: folder and every file are kept', () => {
  const r = parseDriveArchive(ok({ files: [
    { section: 'meterPhotos', name: 'photo_1.jpg', fileId: FILE, url: `https://drive.google.com/file/d/${FILE}/view` },
    { section: 'section_afterclean', name: 'photo_2.jpg', fileId: FILE + 'b', url: `https://drive.google.com/file/d/${FILE}b/view` },
  ] }));
  assertEquals(r?.folderId, FOLDER);
  assertEquals(r?.folderUrl, `https://drive.google.com/drive/folders/${FOLDER}`);
  assertEquals(r?.files?.length, 2);
  assertEquals(r?.files?.[0].section, 'meterPhotos');
});

Deno.test('v3.9 body (no files list): folder kept, files unknown not zero', () => {
  const r = parseDriveArchive(ok());
  assertEquals(r?.folderId, FOLDER);
  assertEquals(r?.files, null);
});

Deno.test('an empty files list is a real zero', () => {
  assertEquals(parseDriveArchive(ok({ files: [] }))?.files, []);
});

Deno.test('malformed files are dropped, not stored', () => {
  const r = parseDriveArchive(ok({ files: [
    { section: 'x', name: 'a', fileId: 'short', url: 'https://drive.google.com/file/d/short' },
    { section: 'x', name: 'b', fileId: FILE, url: 'https://evil.example.com/x' },
    null,
    { section: 'x', name: 'c', fileId: FILE, url: `https://drive.google.com/file/d/${FILE}/view` },
  ] }));
  assertEquals(r?.files?.map((f) => f.name), ['c']);
});

Deno.test('no usable folder id, an error body, or non-JSON: nothing stored', () => {
  assertEquals(parseDriveArchive(JSON.stringify({ result: 'success' })), null);
  assertEquals(parseDriveArchive(JSON.stringify({ result: 'success', folderId: 'bad id!' })), null);
  assertEquals(parseDriveArchive(JSON.stringify({ result: 'error', folderId: FOLDER })), null);
  assertEquals(parseDriveArchive('<html>nope</html>'), null);
});

Deno.test('a duplicate answer (no folder) stores nothing', () => {
  assertEquals(parseDriveArchive(JSON.stringify({ result: 'duplicate', status: 'duplicate', submissionId: 's1' })), null);
});

Deno.test('a non-Drive folder url is dropped but the id is kept', () => {
  assertEquals(parseDriveArchive(ok({ folderUrl: 'http://drive.google.com/x' }))?.folderUrl, null);
});

// D-204 finding 1: the OPS line that says photos reached Drive must count what Code.gs really sent.
Deno.test('the notice counts the files Code.gs returned, and links the folder', () => {
  const archive = parseDriveArchive(ok({ files: [
    { section: 'meterPhotos', name: 'a.jpg', fileId: FILE, url: `https://drive.google.com/file/d/${FILE}/view` },
    { section: 'section_afterclean', name: 'b.jpg', fileId: FILE + 'b', url: `https://drive.google.com/file/d/${FILE}b/view` },
  ] }))!;
  assertEquals(
    archiveNotice(archive, 'Cascade Bria', '2026-09-19'),
    `📸 2 photos archived to Drive — Cascade Bria · 2026-09-19\nhttps://drive.google.com/drive/folders/${FOLDER}`,
  );
});

Deno.test('one photo is singular; zero files says zero, not silence', () => {
  const one = parseDriveArchive(ok({ files: [
    { section: 'meterPhotos', name: 'a.jpg', fileId: FILE, url: `https://drive.google.com/file/d/${FILE}/view` },
  ] }))!;
  assertEquals(archiveNotice(one, 'Cascade Bria', '2026-09-19').startsWith('📸 1 photo archived'), true);
  const none = parseDriveArchive(ok({ files: [] }))!;
  assertEquals(archiveNotice(none, 'Cascade Bria', '2026-09-19').startsWith('📸 0 photos archived'), true);
});

Deno.test('an older Code.gs with no files list claims no count, and falls back to the folder id', () => {
  const archive = parseDriveArchive(ok({ folderUrl: 'http://drive.google.com/x' }))!;
  assertEquals(archive.files, null);
  assertEquals(
    archiveNotice(archive, 'Cascade Bria', '2026-09-19'),
    `📸 Photos archived to Drive — Cascade Bria · 2026-09-19\nhttps://drive.google.com/drive/folders/${FOLDER}`,
  );
});

// s103 W2: taken_at on the meter entries of drive_files
import { parseTakenAt, tagTakenAt, type DriveFile } from './drive-archive.ts';
const NOW = Date.parse('2026-10-31T00:00:00Z');
const df = (section: string, id: string): DriveFile => ({ section, name: 'photo_1.jpg', fileId: id, url: 'https://drive.google.com/x' });

Deno.test('parseTakenAt accepts an ISO date up to a day ahead, else null', () => {
  assertEquals(parseTakenAt('2026-10-21T04:00:00.000Z', NOW), '2026-10-21T04:00:00.000Z');
  assertEquals(parseTakenAt('2026-11-01T00:00:00Z', NOW), '2026-11-01T00:00:00.000Z');
  assertEquals(parseTakenAt('2026-11-02T00:00:00Z', NOW), null);
  for (const v of [null, undefined, 5, '', 'yesterday']) assertEquals(parseTakenAt(v, NOW), null);
});

Deno.test('tagTakenAt matches meter files by position and meta by fileId; other sections untouched', () => {
  const files = [df('section_afterclean', 'A'), df('Meter_Readings', 'E'), df('Meter_Readings', 'W')];
  const photos = [{ name: 'a.jpg', fileId: 'p/e' }, { name: 'b.jpg', fileId: 'p/w' }];
  // meta arrives in a different order and with a null: matching is by fileId, not index
  const meta = [{ fileId: 'p/w', takenAt: '2026-10-22T01:00:00Z' }, { fileId: 'p/e', takenAt: null }];
  const out = tagTakenAt(files, photos, meta, NOW)!;
  assertEquals(out[0].taken_at, undefined);
  assertEquals(out[1].taken_at, null);
  assertEquals(out[2].taken_at, '2026-10-22T01:00:00.000Z');
});

Deno.test('old client (no meterPhotoMeta) and a count mismatch add no key', () => {
  const mk = () => [df('Meter_Readings', 'E'), df('Meter_Readings', 'W')];
  const photos = [{ fileId: 'p/e' }, { fileId: 'p/w' }];
  assertEquals('taken_at' in tagTakenAt(mk(), photos, undefined, NOW)![0], false);
  assertEquals('taken_at' in tagTakenAt(mk(), photos, [{ fileId: 'p/e', takenAt: '2026-10-22T01:00:00Z' }], NOW)![0], true);
  assertEquals('taken_at' in tagTakenAt(mk(), [photos[0]], [{ fileId: 'p/e', takenAt: '2026-10-22T01:00:00Z' }], NOW)![0], false);
  assertEquals(tagTakenAt(null, photos, [], NOW), null);
});

Deno.test('s103 review: the meter slot is kept, and a null photo entry never throws', () => {
  const files = [df('Meter_Readings', 'W')];
  const out = tagTakenAt(files, [{ fileId: 'p/w' }], [{ fileId: 'p/w', meter: 'water', takenAt: '2026-10-22T01:00:00Z' }], NOW)!;
  assertEquals(out[0].meter, 'water');
  const bad = tagTakenAt([df('Meter_Readings', 'E')], [null as unknown as { fileId: string }], [{ fileId: 'x' }], NOW)!;
  assertEquals('taken_at' in bad[0], false);
});
