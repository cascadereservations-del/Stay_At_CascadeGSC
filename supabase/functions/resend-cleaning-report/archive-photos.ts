// SPEC-15 phase 1: a resend prefers the Drive archive and falls back to Supabase Storage.
// Drive photos are sent as { driveFileId }, which Code.gs v3.10 links in place instead of downloading,
// so a resend never needs the Storage copy once drive_files is stored.

export type ResendPhoto = { name: string; url: string; fileId?: string; driveFileId?: string };

/** Photos grouped by the section Code.gs originally filed them under, or null when this session has
 *  no stored Drive list (older sessions, or the unmatched ones the backfill left alone). */
export function drivePhotos(driveFiles: unknown): Record<string, ResendPhoto[]> | null {
  if (!Array.isArray(driveFiles) || driveFiles.length === 0) return null;
  const photos: Record<string, ResendPhoto[]> = {};
  for (const f of driveFiles as Record<string, unknown>[]) {
    if (typeof f?.fileId !== 'string' || !f.fileId) continue;
    const section = typeof f.section === 'string' && f.section ? f.section : 'section_other';
    (photos[section] ??= []).push({
      name: typeof f.name === 'string' ? f.name : f.fileId,
      url: typeof f.url === 'string' ? f.url : '',
      driveFileId: f.fileId,
    });
  }
  return Object.keys(photos).length ? photos : null;
}

type Tagged = { section: string; taken_at?: string | null; meter?: 'electric' | 'water' };
const isMeter = (s: unknown) => typeof s === 'string' && /meter/i.test(s);

/** s104: a resend that re-files the photos must not drop the s103 keys. Carries taken_at/meter over from the previous
 *  drive_files to the new list by position within the meter section, only when both sides have the same meter count
 *  (same rule as submit-cleaning tagTakenAt); otherwise the new list is returned untouched. */
export function carryMeterTags<T extends Tagged>(oldFiles: unknown, next: T[] | null): T[] | null {
  if (!next || !Array.isArray(oldFiles)) return next;
  const prev = (oldFiles as Tagged[]).filter((f) => f && isMeter(f.section));
  const cur = next.filter((f) => isMeter(f.section));
  if (!cur.length || prev.length !== cur.length) return next;
  cur.forEach((f, k) => {
    if ('taken_at' in prev[k]) f.taken_at = prev[k].taken_at;
    if (prev[k].meter === 'electric' || prev[k].meter === 'water') f.meter = prev[k].meter;
  });
  return next;
}
