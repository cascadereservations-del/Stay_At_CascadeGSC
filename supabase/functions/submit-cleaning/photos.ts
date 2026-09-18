// The photo half of a cleaning submission. Split out of index.ts on 2026-09-18 so it can be tested
// without booting Deno.serve, after a three-week silent failure a unit test would have caught.

export interface PhotoEntry {
  name?: string;
  url?: string;
  fileUrl?: string;
  fileId?: string;
  data?: string;
}

/* The app's own upload URL is signed for 900 s and a turnover runs for hours, so every link is stale
 * by submit time. This re-signs each photo from its fileId for an hour, just before the payload goes
 * to Telegram and to Apps Script.
 *
 * `url` is written as well as `fileUrl`, and that is not redundancy. Code.gs picks a photo source in
 * this order:
 *     photo.data  ->  photo.url  ->  return     (a silent skip: muteHttpExceptions, then return)
 * This function used to set only `fileUrl` and delete `url`, so every photo hit that skip and every
 * cleaning report produced Drive folders with nothing in them.
 *
 * The dating is the lesson. The change was committed on 2026-08-30 (f89caaa) but did nothing until
 * submit-cleaning was REDEPLOYED for v28/v30 on 2026-09-16/17 - a redeploy carries every older
 * committed change with it, not just the one you meant. Lloyd's own reports bracket it: the
 * 2026-09-06 e-mail carries 25 Drive links, the 2026-09-17 one says "No photos were attached."
 *
 * Keep the two fields in step, or teach Code.gs to read `fileUrl` in the same breath - they are one
 * contract across two runtimes, and only one of them is in this repo.
 */
// deno-lint-ignore no-explicit-any
export async function refreshSignedPhotoUrls(supabase: any, photos: Record<string, PhotoEntry[]>): Promise<void> {
  const entries = Object.values(photos).flat();
  await Promise.all(entries.map(async (photo) => {
    const { data, error } = await supabase.storage
      .from('cleaning-photos')
      .createSignedUrl(String(photo.fileId), 3600);
    if (error || !data?.signedUrl) throw new Error('photo_access_refresh_failed');
    photo.fileUrl = data.signedUrl;
    photo.url = data.signedUrl;
    delete photo.data;
  }));
}

export function photoUrl(p: PhotoEntry): string | null {
  const u = p.fileUrl ?? p.url ?? null;
  return u && u.startsWith('http') ? u : null;
}

export function countUploaded(photos: Record<string, PhotoEntry[]> | undefined, key: string): number {
  if (!photos || !Array.isArray(photos[key])) return 0;
  return photos[key].map(photoUrl).filter((u): u is string => u !== null).length;
}
