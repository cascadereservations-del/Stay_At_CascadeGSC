// SPEC-15 phase 1: where Code.gs put the photos, as a pure function so it can be tested.
//
// Until this, the Drive folder id and every file id lived only in the sent e-mail
// (session_folder_id was null on 41 of 41 rows, 2026-09-19), so nothing could find the archive.
// Code.gs v3.10 returns { folderId, folderUrl, files: [{ section, name, fileId, url }] }; older
// versions return folderId/folderUrl only, and anything malformed is dropped rather than stored.

export interface DriveFile { section: string; name: string; fileId: string; url: string }
export interface DriveArchive { folderId: string; folderUrl: string | null; files: DriveFile[] | null }

const ID = /^[A-Za-z0-9_-]{10,200}$/;
const isDriveUrl = (u: unknown): u is string =>
  typeof u === 'string' && /^https:\/\/(drive|docs)\.google\.com\//.test(u) && u.length <= 500;
const str = (v: unknown, max: number) => (typeof v === 'string' && v.trim() ? v.trim().slice(0, max) : null);

/** null when the body carries no usable folder id: nothing is written then, and the Storage copy
 *  stays the only copy, which is today's behaviour. `files` is null (not []) for an older Code.gs
 *  that sends no list, so "unknown" is never stored as "zero photos". */
export function parseDriveArchive(bodyText: string): DriveArchive | null {
  let body: Record<string, unknown>;
  try { body = JSON.parse(bodyText); } catch { return null; }
  if (!body || typeof body !== 'object' || body.result === 'error') return null;
  const folderId = str(body.folderId, 200);
  if (!folderId || !ID.test(folderId)) return null;
  const folderUrl = isDriveUrl(body.folderUrl) ? body.folderUrl : null;
  if (!Array.isArray(body.files)) return { folderId, folderUrl, files: null };
  const files: DriveFile[] = [];
  for (const f of body.files as Record<string, unknown>[]) {
    const fileId = str(f?.fileId, 200);
    if (!fileId || !ID.test(fileId) || !isDriveUrl(f.url)) continue;
    files.push({ section: str(f.section, 60) ?? 'other', name: str(f.name, 200) ?? fileId, fileId, url: f.url });
  }
  return { folderId, folderUrl, files };
}

/** The OPS follow-up, sent only once Code.gs has actually answered with the ids (D-204 finding 1).
 *  `files: null` is an older Code.gs that sends no list, so no count is claimed for it — an empty
 *  list IS a real zero and says so. */
export function archiveNotice(archive: DriveArchive, unitName: string, cleaningDate: string): string {
  const n = archive.files?.length;
  const what = typeof n === 'number'
    ? `📸 ${n} photo${n === 1 ? '' : 's'} archived to Drive`
    : `📸 Photos archived to Drive`;
  const link = archive.folderUrl ?? `https://drive.google.com/drive/folders/${archive.folderId}`;
  return `${what} — ${unitName} · ${cleaningDate}\n${link}`;
}
