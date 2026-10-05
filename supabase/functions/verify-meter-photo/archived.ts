// Session 72 (SPEC-42 section 3 step 3): expire-cleaning-photos removes a session's Supabase copies once Drive holds them.
// A manual re-check of such a session finds no meter photo in Storage; it must say so, not write 'unreadable' or 'error' over a
// verdict the sweep already recorded. True only when BOTH meter photos are missing from Storage AND the stored Drive archive
// holds a meter photo (a section named like "Meter_Readings" / "section_meter" with a file id).
export interface ArchiveInfo { session_folder_id?: string | null; drive_files?: unknown }

export function meterPhotosArchived(
  info: ArchiveInfo | null | undefined,
  paths: { electric: string | null; water: string | null },
): boolean {
  if (paths.electric || paths.water) return false;
  if (!info?.session_folder_id || !Array.isArray(info.drive_files)) return false;
  return info.drive_files.some((f) => {
    const x = f as { section?: unknown; fileId?: unknown } | null;
    return typeof x?.fileId === 'string' && x.fileId.trim() !== '' && typeof x.section === 'string' && /meter/i.test(x.section);
  });
}

export const ARCHIVED_NOTE = 'photos archived to Drive';
