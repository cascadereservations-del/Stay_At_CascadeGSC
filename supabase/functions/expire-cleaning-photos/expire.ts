// expire-cleaning-photos: the decision and the run, with no Deno, Supabase or Telegram import so a test drives it whole.
// SPEC-15 phase 2 / SPEC-42 section 3. A cleaning session's photos leave Supabase Storage only when ALL of these hold:
//   1. the session is older than 90 days;
//   2. Code.gs recorded its Drive archive: session_folder_id is set and drive_files holds total_photo_count entries,
//      every one with a Drive file id, and total_photo_count > 0;
//   3. its meter photos are no longer needed: no meter reading, or a vision verdict that is neither empty nor 'error'
//      (the daily sweep retries 'error'; an unverified meter photo is never thrown away);
//   4. the session's own storage folder (property/user/submission) holds no MORE objects than the archive holds files.
//      A folder with extras (a retake, a photo from a page reload) holds something the archive may not have, so the
//      whole session is kept: nothing is deleted without a Drive record that can cover it.
// Photos filed before 2026-09-12 sit in date folders (YYYY-MM-DD/...) that cannot be tied to one session, so they are
// never touched here (about 335 objects, see the session 72 handoff).
// ponytail: the match is per session (counts), not per file: the archive names files photo_N.jpg and keeps no storage path.

export const RETENTION_DAYS = 90;
export const MAX_SESSIONS_PER_RUN = 10;
export const CANDIDATE_LIMIT = 300;
export const BUCKET = 'cleaning-photos';

export interface SessionRow {
  id: string;
  created_at: string;
  submission_id: string | null;
  property_id: string | null;
  submitted_by_user_id: string | null;
  session_folder_id: string | null;
  total_photo_count: number | null;
  drive_files: unknown;
  meter_readings: { vision_verdict: string | null }[] | { vision_verdict: string | null } | null;
}
export interface StoredObject { name: string; size: number | null; isFolder: boolean }

export type SkipReason =
  | 'too_young' | 'no_drive_folder' | 'archive_incomplete' | 'meter_unverified' | 'bad_path' | 'extra_objects' | 'unexpected_layout' | 'nothing_in_storage';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** How many Drive files the session's archive can vouch for: entries that carry a file id. */
export function archivedCount(driveFiles: unknown): number {
  if (!Array.isArray(driveFiles)) return 0;
  return driveFiles.filter((f) => typeof (f as { fileId?: unknown })?.fileId === 'string' && String((f as { fileId: string }).fileId).trim() !== '').length;
}

/** The cut-off for condition 1, as an ISO string. */
export const cutoffIso = (now: Date): string => new Date(now.getTime() - RETENTION_DAYS * 86_400_000).toISOString();

/** Conditions 1-3 and the folder path (4 needs the listing). Returns the reason a session is kept, or the folder prefix. */
export function gate(s: SessionRow, now: Date): { ok: true; prefix: string; archived: number } | { ok: false; reason: SkipReason } {
  if (!(Date.parse(s.created_at) < now.getTime() - RETENTION_DAYS * 86_400_000)) return { ok: false, reason: 'too_young' };
  if (!s.session_folder_id || !String(s.session_folder_id).trim()) return { ok: false, reason: 'no_drive_folder' };
  const total = Number(s.total_photo_count);
  const archived = archivedCount(s.drive_files);
  if (!Number.isInteger(total) || total <= 0 || !Array.isArray(s.drive_files) || s.drive_files.length !== total || archived !== total) {
    return { ok: false, reason: 'archive_incomplete' };
  }
  const readings = Array.isArray(s.meter_readings) ? s.meter_readings : s.meter_readings ? [s.meter_readings] : [];
  if (readings.some((r) => !r?.vision_verdict || r.vision_verdict === 'error')) return { ok: false, reason: 'meter_unverified' };
  if (!s.property_id || !s.submitted_by_user_id || !s.submission_id || !UUID.test(s.property_id) || !UUID.test(s.submitted_by_user_id) || !UUID.test(s.submission_id)) {
    return { ok: false, reason: 'bad_path' };
  }
  return { ok: true, prefix: `${s.property_id}/${s.submitted_by_user_id}/${s.submission_id}`, archived };
}

export interface Deps {
  now: Date;
  /** Sessions older than the cutoff that have a folder id, newest first, at most CANDIDATE_LIMIT. */
  fetchCandidates(cutoff: string, limit: number): Promise<SessionRow[]>;
  /** The objects directly inside a session's folder. Throws on a Storage error. */
  listObjects(prefix: string): Promise<StoredObject[]>;
  /** Deletes through the Storage API and returns the paths that really went. Throws on a Storage error. */
  removeObjects(paths: string[]): Promise<string[]>;
  /** The OPS line, sent once per real run that moved anything. */
  notify?(text: string): Promise<void>;
}
export interface RunResult {
  dry: boolean;
  considered: number;
  expired: { session: string; objects: number; bytes: number }[];   // dry: what WOULD go
  kept: { session: string; reason: SkipReason }[];
  failed: { session: string; error: string }[];
  freedBytes: number;
  opsLine: string | null;
}

const id8 = (id: string) => String(id).slice(0, 8);

/** Dry by default. A real delete needs `dry: false`, which the HTTP layer only passes for ?delete=1. */
export async function runExpiry(deps: Deps, opts: { dry?: boolean } = {}): Promise<RunResult> {
  const dry = opts.dry !== false;
  const out: RunResult = { dry, considered: 0, expired: [], kept: [], failed: [], freedBytes: 0, opsLine: null };
  const candidates = await deps.fetchCandidates(cutoffIso(deps.now), CANDIDATE_LIMIT);
  for (const s of candidates) {
    if (out.expired.length >= MAX_SESSIONS_PER_RUN) break;
    out.considered += 1;
    const g = gate(s, deps.now);
    if (!g.ok) { out.kept.push({ session: id8(s.id), reason: g.reason }); continue; }
    let objects: StoredObject[];
    try { objects = await deps.listObjects(g.prefix); } catch (e) { out.failed.push({ session: id8(s.id), error: `list: ${String(e).slice(0, 120)}` }); continue; }
    const files = objects.filter((o) => !o.isFolder);
    if (objects.length !== files.length || files.some((o) => !o.name || o.name.includes('/'))) { out.kept.push({ session: id8(s.id), reason: 'unexpected_layout' }); continue; }
    if (files.length === 0) { out.kept.push({ session: id8(s.id), reason: 'nothing_in_storage' }); continue; }
    if (files.length > g.archived) { out.kept.push({ session: id8(s.id), reason: 'extra_objects' }); continue; }
    const paths = files.map((o) => `${g.prefix}/${o.name}`);
    if (dry) {
      out.expired.push({ session: id8(s.id), objects: files.length, bytes: files.reduce((n, o) => n + (Number.isFinite(o.size) ? Number(o.size) : 0), 0) });
      continue;
    }
    let removed: string[];
    try { removed = await deps.removeObjects(paths); } catch (e) { out.failed.push({ session: id8(s.id), error: `remove: ${String(e).slice(0, 120)}` }); continue; }
    const gone = new Set(removed);
    const sizeOf = new Map(files.map((o) => [`${g.prefix}/${o.name}`, Number.isFinite(o.size) ? Number(o.size) : 0]));
    const bytes = [...gone].reduce((n, p) => n + (sizeOf.get(p) ?? 0), 0);
    out.freedBytes += bytes;
    // A partial delete is a failure to report, not a session to count as moved: its remaining objects are tried again next week.
    if (paths.some((p) => !gone.has(p))) { out.failed.push({ session: id8(s.id), error: `removed ${paths.filter((p) => gone.has(p)).length} of ${paths.length}` }); continue; }
    out.expired.push({ session: id8(s.id), objects: files.length, bytes });
  }
  if (dry) out.freedBytes = out.expired.reduce((n, e) => n + e.bytes, 0);
  if (!dry && out.expired.length > 0) {
    out.opsLine = opsLine(out.expired.length, out.freedBytes, deps.now);
    if (deps.notify) await deps.notify(out.opsLine);
  }
  return out;
}

const WEEKDAY = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const finiteOr0 = (v: unknown): number => { const n = typeof v === 'number' ? v : NaN; return Number.isFinite(n) && n >= 0 ? n : 0; };

/** The OPS line (SPEC-15 review, written for a person). Counts and megabytes only: it takes no free text, so a rate, total or
 *  fee cannot reach the OPS group through it (D-306). Anything that is not a plain non-negative number reads as 0. */
export function opsLine(sessions: number, bytes: number, now: Date): string {
  const n = Math.floor(finiteOr0(sessions));
  const mb = Math.round(finiteOr0(bytes) / 1e5) / 10;   // one decimal
  const day = WEEKDAY[new Date(now.getTime() + 8 * 3_600_000).getUTCDay()];   // Manila weekday
  const what = n === 1 ? '1 cleaning older than 90 days moved off Supabase (it was already in Drive).' : `${n} cleanings older than 90 days moved off Supabase (all ${n} already in Drive).`;
  return `📦 Photo archive tidy-up — ${day}. ${what} Freed ${mb.toFixed(1)} MB. Nothing else touched.`;
}
