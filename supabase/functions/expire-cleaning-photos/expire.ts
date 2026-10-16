// expire-cleaning-photos: the decision and the run, with no Deno, Supabase or Telegram import so a test drives it whole.
// SPEC-15 phase 2 / SPEC-42 section 3. A cleaning session's photos leave Supabase Storage only when ALL of these hold:
//   1. the session is older than RETENTION_DAYS (180, six months: Lloyd's decision 2026-10-07; it was 90 in SPEC-15);
//   2. Code.gs recorded its Drive archive: session_folder_id is set and drive_files holds total_photo_count entries,
//      every one with a Drive file id, and total_photo_count > 0;
//   3. its meter photos are no longer needed: no meter reading, or a vision verdict that is neither empty nor 'error'
//      (the daily sweep retries 'error'; an unverified meter photo is never thrown away);
//   4. the session's own storage folder (property/user/submission) holds no MORE objects than the archive holds files,
//      and no MORE in any one section: each Storage object is mapped to a section by its filename (as resend-cleaning-report
//      does) and each archive entry by its section label. A section with extras, or an object that maps to no section, means
//      the archive may not hold that photo, so the whole session is kept: nothing is deleted without a Drive record that covers it.
// Photos filed before 2026-09-12 sit in date folders (YYYY-MM-DD/...) that cannot be tied to one session, so they are
// never touched here (about 335 objects, see the session 72 handoff).
// ponytail: the match is per session and per section (counts), not per file: the archive names files photo_N.jpg and keeps no storage path.

import { cronSecretMatches } from '../_shared/cron-auth.ts';

export const RETENTION_DAYS = 180;   // six months, Lloyd 2026-10-07 (SPEC-15 first said 90). Nothing here is deleted before this age.
export const MAX_SESSIONS_PER_RUN = 30;   // wall-clock guard (Edge 150 s); about 11 cleanings a week arrive, so this keeps up
export const MAX_OBJECTS_PER_RUN = 500;   // hard cap on photos removed in one run; hitting it is reported to OPS and the rest waits a week
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
  | 'too_young' | 'no_drive_folder' | 'archive_incomplete' | 'meter_unverified' | 'bad_path' | 'extra_objects' | 'section_not_archived' | 'unexpected_layout' | 'nothing_in_storage';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** How many Drive files the session's archive can vouch for: entries that carry a file id. */
export function archivedCount(driveFiles: unknown): number {
  if (!Array.isArray(driveFiles)) return 0;
  return driveFiles.filter((f) => typeof (f as { fileId?: unknown })?.fileId === 'string' && String((f as { fileId: string }).fileId).trim() !== '').length;
}

const FILE_SECTIONS: [string, string][] = [   // same needles, same order as resend-cleaning-report's sectionFor
  ['preclean', 'preclean'], ['afterclean', 'afterclean'], ['bedroom', 'bedroom'], ['kitchen', 'kitchen'],
  ['electric_meter', 'meter'], ['water_meter', 'meter'], ['issue_', 'issue'], ['condition', 'condition'],
];
/** The section a Storage object belongs to, from its filename (<uuid>-afterclean_<date>_<ts>.jpg). Anything unrecognised is 'other'. */
export function fileSection(name: string): string {
  for (const [needle, key] of FILE_SECTIONS) if (name.includes(needle)) return key;
  return 'other';
}
const LABEL_SECTIONS: [string, string][] = [['preclean', 'preclean'], ['afterclean', 'afterclean'], ['bedroom', 'bedroom'], ['kitchen', 'kitchen'], ['meter', 'meter'], ['issue', 'issue'], ['condition', 'condition']];
/** The same section keys from a drive_files label: section_afterclean, After-Clean, Meter_Readings, Unit_Condition, issue_check_* all normalise. */
export function labelSection(label: unknown): string {
  const k = String(label ?? '').toLowerCase().replace(/[^a-z0-9]+/g, '');
  for (const [needle, key] of LABEL_SECTIONS) if (k.includes(needle)) return key;
  return 'other';
}
/** Archive entries that carry a file id, counted per section key. */
export function archivedBySection(driveFiles: unknown): Map<string, number> {
  const m = new Map<string, number>();
  if (!Array.isArray(driveFiles)) return m;
  for (const f of driveFiles as { section?: unknown; fileId?: unknown }[]) {
    if (typeof f?.fileId !== 'string' || f.fileId.trim() === '') continue;
    const k = labelSection(f.section);
    m.set(k, (m.get(k) ?? 0) + 1);
  }
  return m;
}

/** POST auth and run mode, pure. A real delete needs the secret AND exactly ?delete=1; anything else that is authorised is a dry run. */
export function parseRunMode(url: string, header: string | null, secret: string): { ok: false; status: 401 } | { ok: true; dry: boolean } {
  if (!secret || !cronSecretMatches(secret, header)) return { ok: false, status: 401 };
  return { ok: true, dry: new URL(url).searchParams.get('delete') !== '1' };
}

/** The cut-off for condition 1, as an ISO string. */
export const cutoffIso = (now: Date): string => new Date(now.getTime() - RETENTION_DAYS * 86_400_000).toISOString();

/** Conditions 1-3 and the folder path (4 needs the listing). Returns the reason a session is kept, or the folder prefix. */
export function gate(s: SessionRow, now: Date): { ok: true; prefix: string; archived: number; sections: Map<string, number>; metered: boolean } | { ok: false; reason: SkipReason } {
  if (!(Date.parse(s.created_at) < now.getTime() - RETENTION_DAYS * 86_400_000)) return { ok: false, reason: 'too_young' };
  if (!s.session_folder_id || !String(s.session_folder_id).trim()) return { ok: false, reason: 'no_drive_folder' };
  const total = Number(s.total_photo_count);
  const archived = archivedCount(s.drive_files);
  if (!Number.isInteger(total) || total <= 0 || !Array.isArray(s.drive_files) || s.drive_files.length !== total || archived !== total) {
    return { ok: false, reason: 'archive_incomplete' };
  }
  const readings = Array.isArray(s.meter_readings) ? s.meter_readings : s.meter_readings ? [s.meter_readings] : [];
  // No reading row does NOT mean verified: submit-cleaning inserts one only when a number was typed. runExpiry keeps such a session if a meter photo is in Storage.
  if (readings.some((r) => !r?.vision_verdict || r.vision_verdict === 'error')) return { ok: false, reason: 'meter_unverified' };
  if (!s.property_id || !s.submitted_by_user_id || !s.submission_id || !UUID.test(s.property_id) || !UUID.test(s.submitted_by_user_id) || !UUID.test(s.submission_id)) {
    return { ok: false, reason: 'bad_path' };
  }
  return { ok: true, prefix: `${s.property_id}/${s.submitted_by_user_id}/${s.submission_id}`, archived, sections: archivedBySection(s.drive_files), metered: readings.length > 0 };
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
  keptReasons: Record<string, number>;   // kept, counted per reason, so a permanent keep shows in the response and the run log
  failed: { session: string; error: string }[];
  freedBytes: number;
  capHit: boolean;   // an eligible session was left for next week because the session or object cap was reached
  opsLine: string | null;
  capLine: string | null;
}

const id8 = (id: string) => String(id).slice(0, 8);

/** Dry by default. A real delete needs `dry: false`, which the HTTP layer only passes for ?delete=1. */
export async function runExpiry(deps: Deps, opts: { dry?: boolean } = {}): Promise<RunResult> {
  const dry = opts.dry !== false;
  const out: RunResult = { dry, considered: 0, expired: [], kept: [], keptReasons: {}, failed: [], freedBytes: 0, capHit: false, opsLine: null, capLine: null };
  let attempted = 0, planned = 0;   // sessions / objects that reached removeObjects (or would, on a dry run): moved, failed or short, all count against the caps
  const candidates = await deps.fetchCandidates(cutoffIso(deps.now), CANDIDATE_LIMIT);
  for (const s of candidates) {
    out.considered += 1;
    const g = gate(s, deps.now);
    if (!g.ok) { out.kept.push({ session: id8(s.id), reason: g.reason }); continue; }
    let objects: StoredObject[];
    try { objects = await deps.listObjects(g.prefix); } catch (e) { out.failed.push({ session: id8(s.id), error: `list: ${String(e).slice(0, 120)}` }); continue; }
    const files = objects.filter((o) => !o.isFolder);
    if (objects.length !== files.length || files.some((o) => !o.name || o.name.includes('/'))) { out.kept.push({ session: id8(s.id), reason: 'unexpected_layout' }); continue; }
    if (files.length === 0) { out.kept.push({ session: id8(s.id), reason: 'nothing_in_storage' }); continue; }
    if (files.length > g.archived) { out.kept.push({ session: id8(s.id), reason: 'extra_objects' }); continue; }
    const stored = new Map<string, number>();
    for (const o of files) { const k = fileSection(o.name); stored.set(k, (stored.get(k) ?? 0) + 1); }
    if (stored.has('meter') && !g.metered) { out.kept.push({ session: id8(s.id), reason: 'meter_unverified' }); continue; }   // meter photo with no reading row: never verified, never deleted (D-310)
    if (stored.has('other') || [...stored].some(([k, n]) => n > (g.sections.get(k) ?? 0))) { out.kept.push({ session: id8(s.id), reason: 'section_not_archived' }); continue; }
    // The cap is checked only for a session that WOULD go, so a pile of permanent keeps never raises the alert.
    if (attempted >= MAX_SESSIONS_PER_RUN || planned + files.length > MAX_OBJECTS_PER_RUN) { out.capHit = true; break; }
    attempted += 1; planned += files.length;
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
  for (const k of out.kept) out.keptReasons[k.reason] = (out.keptReasons[k.reason] ?? 0) + 1;
  if (dry) out.freedBytes = out.expired.reduce((n, e) => n + e.bytes, 0);
  if (!dry && out.expired.length > 0) {
    out.opsLine = opsLine(out.expired.length, out.freedBytes, deps.now);
    if (deps.notify) await deps.notify(out.opsLine);
  }
  if (!dry && out.capHit) {
    out.capLine = capLine();
    if (deps.notify) await deps.notify(out.capLine);
  }
  return out;
}

const WEEKDAY = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const finiteOr0 = (v: unknown): number => { const n = typeof v === 'number' ? v : NaN; return Number.isFinite(n) && n >= 0 ? n : 0; };

/** The OPS line (SPEC-15 review, written for a person). Counts and megabytes only: it takes no free text, so a rate, total or
 *  fee cannot reach the OPS group through it (D-306). Anything that is not a plain non-negative number reads as 0. */
export function opsLine(sessions: number, bytes: number, now: Date): string {
  const n = Math.floor(finiteOr0(sessions));
  const b = finiteOr0(bytes);
  // one decimal; 100.0 MB or more would read as money to ops-money (D-306), so from 99.95 MB it is GB
  const size = b >= 99_950_000 ? `${(Math.round(b / 1e8) / 10).toFixed(1)} GB` : `${(Math.round(b / 1e5) / 10).toFixed(1)} MB`;
  const day = WEEKDAY[new Date(now.getTime() + 8 * 3_600_000).getUTCDay()];   // Manila weekday
  const what = n === 1 ? '1 cleaning older than 6 months moved off Supabase (it was already in Drive).' : `${n} cleanings older than 6 months moved off Supabase (all ${n} already in Drive).`;
  return `📦 Photo archive tidy-up — ${day}. ${what} Freed ${size}. Nothing else touched.`;
}

/** The OPS line when a run stopped at its cap. No numbers at all: ops-money hides any 3+ digit number from OPS (D-306), so a count of 500 would read as money.
 *  The next Monday run carries on from where this one stopped. */
export const capLine = (): string =>
  '📦 Photo archive tidy-up reached its weekly limit. More old cleanings are waiting and go next Monday. Nothing is wrong; if this repeats for weeks, tell Lloyd.';

// ---- Orphan sweep (s89): uploads that never reached a submitted cleaning --------------------------------------------------
// upload-photo stores every photo at <property>/<user>/<submission>/<uuid>-<name> the moment it is picked; a cleaner who abandons the checklist leaves
// them behind with no cleaning_sessions row. A folder is an orphan only when ALL hold: its newest object is older than ORPHAN_AGE_DAYS; no session has
// that submission_id; the same user filed no session for that property between the folder's first upload and ORPHAN_GRACE_DAYS after its last (a page
// reload starts a new submission id but keeps the photos, so those photos belong to the session filed hours later: 11 of 14 id-less folders on prod
// 2026-10-16 were exactly that); and no payment-proof, expense-claim or guest-ID row points into the folder (folderReferenced). Dry unless `del`.
export const ORPHAN_AGE_DAYS = 7;
export const ORPHAN_GRACE_DAYS = 2;
export const MAX_ORPHAN_OBJECTS_PER_RUN = 100;   // far below MAX_OBJECTS_PER_RUN: the first real runs stay small
export interface UploadFolder { prefix: string; property: string; user: string; submission: string; objects: { name: string; size: number | null; createdAt: string }[] }
export interface OrphanDeps {
  now: Date;
  /** Every <property>/<user>/<submission> folder with its objects (UUID-shaped layout only; date folders are not listed). */
  listUploadFolders(): Promise<UploadFolder[]>;
  /** True when a cleaning session claims the folder (submission id, or the same user's session in the grace window). */
  folderHasSession(f: UploadFolder, firstAt: string, graceEndAt: string): Promise<boolean>;
  /** True when payment-proof / expense-claim / guest-ID rows point into the folder. */
  folderReferenced(prefix: string): Promise<boolean>;
  removeObjects(paths: string[]): Promise<string[]>;
}
export interface OrphanResult { del: boolean; folders: number; orphans: { folder: string; objects: number; bytes: number }[]; kept: Record<string, number>; failed: { folder: string; error: string }[]; capHit: boolean }

export async function runOrphanSweep(deps: OrphanDeps, opts: { del?: boolean } = {}): Promise<OrphanResult> {
  const del = opts.del === true;
  const out: OrphanResult = { del, folders: 0, orphans: [], kept: {}, failed: [], capHit: false };
  const keep = (r: string) => { out.kept[r] = (out.kept[r] ?? 0) + 1; };
  const cutoff = deps.now.getTime() - ORPHAN_AGE_DAYS * 86_400_000;
  let planned = 0;
  for (const f of await deps.listUploadFolders()) {
    out.folders += 1;
    const times = f.objects.map((o) => Date.parse(o.createdAt));
    if (f.objects.length === 0 || times.some((t) => !Number.isFinite(t))) { keep('unreadable'); continue; }
    const first = Math.min(...times), last = Math.max(...times);
    if (last >= cutoff) { keep('too_young'); continue; }
    const id = f.submission.slice(0, 8);
    try {
      if (await deps.folderHasSession(f, new Date(first).toISOString(), new Date(last + ORPHAN_GRACE_DAYS * 86_400_000).toISOString())) { keep('has_session'); continue; }
      if (await deps.folderReferenced(f.prefix)) { keep('referenced'); continue; }
    } catch (e) { out.failed.push({ folder: id, error: `check: ${String(e).slice(0, 120)}` }); continue; }
    if (planned + f.objects.length > MAX_ORPHAN_OBJECTS_PER_RUN) { out.capHit = true; break; }
    planned += f.objects.length;
    const bytes = f.objects.reduce((n, o) => n + (Number.isFinite(o.size) ? Number(o.size) : 0), 0);
    if (del) {
      const paths = f.objects.map((o) => `${f.prefix}/${o.name}`);
      try {
        const gone = new Set(await deps.removeObjects(paths));
        if (paths.some((x) => !gone.has(x))) { out.failed.push({ folder: id, error: `removed ${paths.filter((x) => gone.has(x)).length} of ${paths.length}` }); continue; }
      } catch (e) { out.failed.push({ folder: id, error: `remove: ${String(e).slice(0, 120)}` }); continue; }
    }
    out.orphans.push({ folder: id, objects: f.objects.length, bytes });
  }
  return out;
}
