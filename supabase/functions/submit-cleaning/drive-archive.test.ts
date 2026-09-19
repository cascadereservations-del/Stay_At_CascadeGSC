// deno test submit-cleaning/drive-archive.test.ts  (run from supabase/functions)
// SPEC-15 phase 1: the Drive ids Code.gs returns are stored, and nothing malformed is.
import { assertEquals } from 'jsr:@std/assert@1';
import { parseDriveArchive } from './drive-archive.ts';

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
