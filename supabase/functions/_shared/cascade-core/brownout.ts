// Brownout blocks (D-290, Lloyd 2026-10-02): a SOCOTECO interruption that touches our nights is blocked on OUR booking site
// and announced in Telegram, and nothing is written to Airbnb: Marifel blocks Airbnb by hand, which is why the card has to
// go out the moment the poster is read. This module is the part power-watch (writes, follow-ups) and telegram-expense
// (the card taps) share: the callback payloads, the per-notice state, and the one release path.
//
// State lives in app_settings, one key per outage date: power_watch_notice:<YYYY-MM-DD> (jsonb, see NoticeState).
// Both functions change it through patchNoticeState (read, merge, write), so a tap and a power-watch run cannot undo each other.
// The rows that hold the nights are calendar_events {uid 'brownout:<night>', source 'manual', status 'blocked',
// recon_status 'admin_block'}: availability reads status != 'cancelled', and source 'manual' keeps verifier V3 (direct rows) quiet.

// deno-lint-ignore no-explicit-any
type Db = any;

export const STATE_PREFIX = 'power_watch_notice:';
export const brownoutUid = (night: string) => `brownout:${night}`;
export const noticeKey = (date: string) => `${STATE_PREFIX}${date}`;

export type Guest = { night: string; name: string };
/** SPEC-41 Part 3: where a brownout notice came from decides whether power-watch checks it against SOCOTECO's current posts.
 *  socoteco = a SOCOTECO II notice (checked); ngcp = a grid outage and staff = a scheduled job (neither is checked). */
export type NoticeSource = 'socoteco' | 'ngcp' | 'staff';
export const noticeSource = (text: string | null | undefined): NoticeSource => /\bNGCP\b/i.test(text ?? '') ? 'ngcp' : /SOCOTECO/i.test(text ?? '') ? 'socoteco' : 'staff';
/** The word a card uses for who announced it ('Scheduled' for a staff-entered job). A state with no source reads as SOCOTECO. */
export const sourceWord = (s: NoticeSource | undefined) => (s === 'ngcp' ? 'NGCP' : s === 'staff' ? 'Scheduled' : 'SOCOTECO');
/** What power-watch has decided and done for one outage date. Every field after `status` is optional history. */
export type NoticeState = {
  date: string; noticeId: string | null; time: string | null; hours: number | null; postId: number; poster: string;
  url?: string;              // the SOCOTECO poster behind the latest card: the first one, or the one that changed, moved or cancelled it
  status: 'active' | 'undone' | 'released';
  nights: string[];          // every night the outage touches, today or later
  blocked: string[];         // nights we hold with brownout rows (the ones Marifel must block in Airbnb)
  already: string[];         // nights that were blocked before us (an Airbnb block, an admin block)
  guests: Guest[];           // nights with a guest in the house: never blocked
  card: null | { kind: 'new' | 'changed' | 'cancel'; prev?: { time: string | null; hours: number | null; blocked: string[] }; note?: string };
  cardAt?: string; doneAt?: string; doneBy?: string; seenAt?: string; remindedAt?: string;
  cardMsgId?: number; remindMsgId?: number; // OPS message ids, so the Done button can be taken off once the Airbnb calendar shows the block
  unverifiedAt?: string;     // Done was tapped but the Airbnb calendar still showed the nights open 3 hours later: warned once
  releasedAt?: string; releasedBy?: string; cancelAskedAt?: string;
  source?: NoticeSource;     // SPEC-41: absent reads as socoteco
  enteredBy?: string;        // posted_by_name of a hand-entered notice (postId 0)
  missRuns?: number;         // consecutive clean scrapes where SOCOTECO's current schedule no longer listed this date
};

// ── dates ────────────────────────────────────────────────────────────────────────────────────────────────────────────
export const validYmd = (s: unknown): s is string => {
  if (typeof s !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
  const d = new Date(`${s}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
};
export const addDays = (ymd: string, n: number) => new Date(Date.parse(`${ymd}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);
const mins = (t: string) => +t.slice(0, 2) * 60 + +t.slice(3, 5);

/**
 * Nights (YYYY-MM-DD) an outage on `date` touches. Unknown start counts as the whole morning (from 00:00), unknown
 * length as running to midnight, so a poster with no times blocks the night before and the night of: the safe side.
 * (Moved here from power-watch/plan.ts in SPEC-41 so calendar-sync reads the same rule.)
 */
export function touchedNights(date: string, time: string | null, hours: number | null): string[] {
  const s = time ? mins(time) : 0;
  const e = hours && hours > 0 ? s + Math.round(hours * 60) : Math.max(s, 1440);
  const out: string[] = [];
  for (let k = -1; k <= Math.ceil(e / 1440); k++) {
    const stayStart = k * 1440 + 14 * 60, stayEnd = (k + 1) * 1440 + 12 * 60;
    if (s < stayEnd && e > stayStart) out.push(addDays(date, k));
  }
  return out;
}
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
export const monthDay = (ymd: string) => `${MON[Number(ymd.slice(5, 7)) - 1]} ${Number(ymd.slice(8, 10))}`;
/** 'Oct 14', 'Oct 14 and Oct 15', 'Oct 14, Oct 15 and Oct 16'. */
export function nightsList(nights: string[]): string {
  const n = nights.map(monthDay);
  return n.length <= 1 ? (n[0] ?? '') : `${n.slice(0, -1).join(', ')} and ${n[n.length - 1]}`;
}
/** 'night of Oct 14' / 'nights of Oct 14 and Oct 15'. */
export const nightsPhrase = (nights: string[]) => `${nights.length === 1 ? 'night' : 'nights'} of ${nightsList(nights)}`;

// ── callback payloads (Telegram caps callback_data at 64 bytes; every one here is under 60) ─────────────────────────
export type PwTap = { kind: 'done' | 'undo' | 'unblock' | 'keep'; date: string };
export type TaskTap = { kind: 'stc' | 'crm'; date: string; ref: string; sourceKind: 'stay_continues' | 'guest_details'; sourceRef: string };

export function parsePwTap(data: string): PwTap | null {
  const m = /^pw:(done|undo|unblock|keep):(\d{4}-\d{2}-\d{2})$/.exec(String(data ?? ''));
  return m && validYmd(m[2]) ? { kind: m[1] as PwTap['kind'], date: m[2] } : null;
}
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** stc:done:<YYYY-MM-DD>:<CODE 6-12 of A-Z0-9> and crm:done:<YYYY-MM-DD>:<guest uuid>. Anything else is not ours to act on. */
export function parseTaskTap(data: string): TaskTap | null {
  const m = /^(stc|crm):done:(\d{4}-\d{2}-\d{2}):([A-Za-z0-9-]{6,40})$/.exec(String(data ?? ''));
  if (!m || !validYmd(m[2])) return null;
  if (m[1] === 'stc') return /^[A-Z0-9]{6,12}$/.test(m[3]) ? { kind: 'stc', date: m[2], ref: m[3], sourceKind: 'stay_continues', sourceRef: `${m[2]}:${m[3]}` } : null;
  return UUID_RE.test(m[3]) ? { kind: 'crm', date: m[2], ref: m[3].toLowerCase(), sourceKind: 'guest_details', sourceRef: `${m[2]}:${m[3].toLowerCase()}` } : null;
}
export const pwData = (kind: PwTap['kind'], date: string) => `pw:${kind}:${date}`;

/** The rpc is Lane A's SQL and may not be deployed when the first tap lands: a missing function is logged, not shown as a failure. */
export const rpcMissing = (e: { code?: string; message?: string } | null | undefined) =>
  !!e && (e.code === 'PGRST202' || e.code === '42883' || /could not find the function|does not exist/i.test(String(e.message ?? '')));

// ── state ────────────────────────────────────────────────────────────────────────────────────────────────────────────
export async function readNotice(db: Db, date: string): Promise<NoticeState | null> {
  const { data } = await db.from('app_settings').select('value').eq('key', noticeKey(date)).maybeSingle();
  return (data?.value as NoticeState | undefined) ?? null;
}
export async function listNotices(db: Db): Promise<NoticeState[]> {
  const { data, error } = await db.from('app_settings').select('value').like('key', `${STATE_PREFIX}%`);
  if (error) throw new Error(`notice_state: ${error.message}`);
  return (data ?? []).map((r: { value: NoticeState }) => r.value).filter((v: NoticeState | null) => !!v?.date);
}
/** Read, merge, write. Returns the merged state, or null when there is none to patch (and `create` is not given). */
export async function patchNoticeState(db: Db, date: string, patch: Partial<NoticeState>, create?: NoticeState): Promise<NoticeState | null> {
  const cur = (await readNotice(db, date)) ?? create ?? null;
  if (!cur) return null;
  const next = { ...cur, ...patch } as NoticeState;
  const { error } = await db.from('app_settings').upsert({ key: noticeKey(date), value: next, updated_at: new Date().toISOString() }, { onConflict: 'key' });
  if (error) throw new Error(`notice_state_write: ${error.message}`);
  return next;
}

/** Replace the whole state (power-watch, when it has just decided the notice afresh: a new one, or a changed one). */
export async function putNoticeState(db: Db, st: NoticeState): Promise<void> {
  const { error } = await db.from('app_settings').upsert({ key: noticeKey(st.date), value: st, updated_at: new Date().toISOString() }, { onConflict: 'key' });
  if (error) throw new Error(`notice_state_write: ${error.message}`);
}

/** Nights this state still needs held: only an active notice holds anything. */
export const holds = (n: NoticeState) => n.status === 'active';

/** Cancel the brownout rows for these nights. Returns an error string, or null. */
export async function cancelBrownoutRows(db: Db, propertyId: string, nights: string[]): Promise<string | null> {
  if (!nights.length) return null;
  const { error } = await db.from('calendar_events').update({ status: 'cancelled', updated_at: new Date().toISOString() })
    .eq('property_id', propertyId).eq('source', 'manual').in('uid', nights.map(brownoutUid)).neq('status', 'cancelled');
  return error ? String(error.message ?? error).slice(0, 120) : null;
}

/** Nights of this notice that no OTHER active notice still needs (Oct 14 can serve a 18:00 outage on the 14th and a 06:00 one on the 15th). */
export function releasable(state: NoticeState, all: NoticeState[]): string[] {
  const keep = new Set(all.filter((o) => o.date !== state.date && holds(o)).flatMap((o) => o.blocked));
  return state.blocked.filter((n) => !keep.has(n));
}

/**
 * The one release path, for the Undo and Unblock taps. Undo frees our nights (the notice stays on the board);
 * Unblock also takes the notice off the board (D-290: the outage is not happening). Returns what was freed.
 */
export async function releaseNotice(db: Db, propertyId: string, date: string, mode: 'undo' | 'unblock', by: string):
  Promise<{ ok: true; nights: string[]; already: boolean } | { ok: false; error: string }> {
  const st = await readNotice(db, date);
  if (!st) return { ok: false, error: 'There is no block on record for that outage.' };
  if (st.status === 'released' || (st.status === 'undone' && mode === 'undo')) return { ok: true, nights: [], already: true };
  const nights = releasable(st, await listNotices(db));
  const err = await cancelBrownoutRows(db, propertyId, nights);
  if (err) return { ok: false, error: err };
  if (mode === 'unblock') {
    const q = db.from('ops_notices').update({ is_active: false, updated_at: new Date().toISOString() });
    const { error } = await (st.noticeId ? q.eq('id', st.noticeId) : q.eq('property_id', propertyId).eq('notice_type', 'brownout').eq('effective_date', date));
    if (error) return { ok: false, error: String(error.message ?? error).slice(0, 120) };
  }
  const now = new Date().toISOString();
  await patchNoticeState(db, date, { status: mode === 'undo' ? 'undone' : 'released', blocked: [], releasedAt: now, releasedBy: by, card: null });
  return { ok: true, nights, already: false };
}

/**
 * The Keep it blocked tap on the auto-release card (SPEC-41 3.4): a person says SOCOTECO told them the outage is still on.
 * The notice goes back on the board as a staff notice (never checked against socoteco2.com again) and its state is deleted,
 * so power-watch's "notice on the board with no state" path adopts it within 15 minutes and re-blocks the free nights.
 */
export async function keepNotice(db: Db, propertyId: string, date: string): Promise<{ ok: true; already: boolean } | { ok: false; error: string }> {
  const st = await readNotice(db, date);
  if (st && st.status !== 'released') return { ok: true, already: true }; // still active (or undone): nothing to bring back
  const q = db.from('ops_notices').update({ is_active: true, source: 'staff', updated_at: new Date().toISOString() });
  const { data, error } = await (st?.noticeId ? q.eq('id', st.noticeId) : q.eq('property_id', propertyId).eq('notice_type', 'brownout').eq('effective_date', date)).select('id');
  if (error) return { ok: false, error: String(error.message ?? error).slice(0, 120) };
  if (!data?.length) return { ok: false, error: 'There is no notice on record for that outage.' };
  const { error: delErr } = await db.from('app_settings').delete().eq('key', noticeKey(date));
  if (delErr) return { ok: false, error: String(delErr.message ?? delErr).slice(0, 120) };
  return { ok: true, already: false };
}
