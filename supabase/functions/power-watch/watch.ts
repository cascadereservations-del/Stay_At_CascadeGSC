// power-watch, the orchestration (D-290): what one run does with the notices it found, the ones already on the board, and the
// ones it holds blocks for. IO goes through `Deps` (a database, a Telegram sender, a mailer), so watch.test.ts runs every
// path against an in-memory database. Nothing here writes to Airbnb or sends anything to a guest.
import { cancelBrownoutRows, brownoutUid, listNotices, patchNoticeState, putNoticeState, readNotice, releasable, releaseNotice, type NoticeSource, type NoticeState } from '../_shared/cascade-core/brownout.ts';
import { alertText, dayLabel, FEEDER, posterFor, type Notice } from './poster.ts';
import { cancelCard, changedCard, classifyNights, extraGuestCards, newCard, nightsLine, releasedCard, reminderCard, reminderDue, seenCard, seenDue, staleNotices, touchedNights, windowLabel, type Built, type Row, type Schedule } from './plan.ts';

// deno-lint-ignore no-explicit-any
type Db = any;
export type Deps = {
  db: Db; propertyId: string; today: string; now: Date;
  send: (card: Built) => Promise<boolean>;
  mail: (subject: string, body: string) => Promise<boolean>;
  log: (event: string, data: unknown) => void;
  posters?: string[]; // poster URLs already read (power_watch_state.images): the link for a notice that has none of its own
  schedule?: Schedule; // SPEC-41: what SOCOTECO's current posts say (plan.ts scheduleFrom); absent or null = unknown, nothing is ever released
  sendFinance?: (card: Built) => Promise<boolean>; // the same card to the Finance chat (the auto-release card goes to OPS and Finance)
};
export type Found = Notice & { postId: number };
type NoticeRow = { id: string; effective_date: string; effective_time: string | null; duration_hours: number | string | null; source?: string | null; posted_by_name?: string | null };
type Base = { date: string; noticeId: string | null; time: string | null; hours: number | null; postId: number; poster: string; url: string; source?: NoticeSource; enteredBy?: string };
/** A row with no source (written before the SPEC-41 release, or by an old writer) reads as SOCOTECO, like a state with none. */
const srcOf = (r: { source?: string | null } | undefined): NoticeSource => (r?.source === 'ngcp' || r?.source === 'staff' ? r.source : 'socoteco');

const hhmm = (t: string | null) => (t ? t.slice(0, 5) : null);
const num = (v: unknown) => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v)) ? null : Number(v));
/** The same outage: a missing time or length on either side is not a difference (the old rule: an untimed notice matches). */
const sameWindow = (a: { time: string | null; hours: number | null }, b: { time: string | null; hours: number | null }) =>
  !a.time || !b.time || (hhmm(a.time) === hhmm(b.time) && (a.hours === null || b.hours === null || Math.abs(a.hours - b.hours) < 0.01));

export async function reconcile(d: Deps, found: Found[]): Promise<string[]> {
  const { db, propertyId: pid, today, now } = d;
  const nowIso = now.toISOString();
  const res: string[] = [];

  const cal = await db.from('calendar_events').select('uid,source,status,checkin_date,checkout_date,guest_name')
    .eq('property_id', pid).neq('status', 'cancelled').gt('checkout_date', today).limit(1000);
  if (cal.error) throw new Error(`calendar_events: ${cal.error.message}`);
  const rows: Row[] = [...(cal.data ?? [])];
  const states = new Map<string, NoticeState>((await listNotices(db)).map((s) => [s.date, s]));
  const nq = await db.from('ops_notices').select('id,effective_date,effective_time,duration_hours,source,posted_by_name')
    .eq('property_id', pid).eq('notice_type', 'brownout').eq('is_active', true).gte('effective_date', today).order('created_at');
  if (nq.error) throw new Error(`ops_notices: ${nq.error.message}`);
  const noticeRows: NoticeRow[] = nq.data ?? [];

  /** Decide the nights, write the free ones as brownout rows, drop the ones a changed time no longer touches, and queue the card. */
  async function announce(kind: 'new' | 'changed', base: Base, prev?: NoticeState, mailFor?: Notice): Promise<NoticeState> {
    const cls = classifyNights(touchedNights(base.date, base.time, base.hours), rows, today);
    const blocked = [...cls.held, ...cls.toBlock].sort();
    if (cls.toBlock.length) {
      const summary = `SOCOTECO power interruption ${windowLabel(base.date, base.time, base.hours)} (Feeder ${FEEDER})`;
      const { error } = await db.from('calendar_events').upsert(cls.toBlock.map((night) => ({
        property_id: pid, uid: brownoutUid(night), source: 'manual', status: 'blocked', recon_status: 'admin_block',
        checkin_date: night, checkout_date: nextDay(night), raw_summary: summary, // nights is a generated column
      })), { onConflict: 'uid,property_id' });
      if (error) throw new Error(`brownout_rows: ${error.message}`);
      for (const night of cls.toBlock) rows.push({ uid: brownoutUid(night), source: 'manual', status: 'blocked', checkin_date: night, checkout_date: nextDay(night) });
    }
    const dropped = (prev?.blocked ?? []).filter((n) => !blocked.includes(n));
    if (dropped.length) {
      const free = releasable({ ...(prev as NoticeState), blocked: dropped }, [...states.values()]);
      const err = await cancelBrownoutRows(db, pid, free);
      if (err) throw new Error(`brownout_release: ${err}`);
      for (const n of free) { const i = rows.findIndex((r) => r.uid === brownoutUid(n)); if (i >= 0) rows.splice(i, 1); }
    }
    const added = blocked.filter((n) => !(prev?.blocked ?? []).includes(n));
    const st: NoticeState = {
      ...base, url: base.url || prev?.url || '', status: 'active', source: base.source ?? prev?.source ?? 'socoteco',
      ...(base.enteredBy ?? prev?.enteredBy ? { enteredBy: base.enteredBy ?? prev?.enteredBy } : {}), nights: touchedNights(base.date, base.time, base.hours).filter((n) => n >= today),
      blocked, already: cls.already, guests: cls.guests,
      card: { kind, ...(prev ? { prev: { time: prev.time, hours: prev.hours, blocked: prev.blocked } } : {}) },
      // A change that adds nights is a new job for Marifel; one that only moves the hours leaves what she did standing.
      ...(prev && !added.length ? { cardAt: prev.cardAt, doneAt: prev.doneAt, doneBy: prev.doneBy, seenAt: prev.seenAt, remindedAt: prev.remindedAt } : {}),
    };
    await putNoticeState(db, st);
    states.set(st.date, st);
    if (kind === 'new' && mailFor) {
      const a = alertText(mailFor, nightsLine(st));
      d.log('power_watch_mail', { date: st.date, email: await d.mail(a.subject, a.body) });
    }
    return st;
  }

  const baseFromRow = (r: NoticeRow): Base => ({ date: r.effective_date, noticeId: r.id, time: r.effective_time, hours: num(r.duration_hours), postId: 0, poster: '', url: '', source: srcOf(r), ...(r.posted_by_name ? { enteredBy: r.posted_by_name } : {}) });

  /** SOCOTECO cancelled an outage, or moved it: ask before anything is released, because Airbnb is Marifel's to unblock. */
  async function cancel(date: string, note: string, url: string) {
    const row = noticeRows.find((r) => r.effective_date === date);
    let st = states.get(date);
    if (st && (st.status !== 'active' || st.cancelAskedAt)) return;
    if (!st && !row) return;
    if (!st) {
      st = { ...baseFromRow(row!), status: 'active', nights: [], blocked: [], already: [], guests: [], card: null };
    }
    st = { ...st, url: url || st.url, card: { kind: 'cancel', note } }; // the card links the poster that cancelled or moved it
    await putNoticeState(db, st);
    states.set(date, st);
    res.push(`${date}: ${note}`);
  }

  // One notice per date: the newest poster wins.
  const byDate = new Map<string, Found>();
  for (const n of found) if (!byDate.has(n.date) || n.postId > byDate.get(n.date)!.postId) byDate.set(n.date, n);

  for (const n of byDate.values()) {
    if (n.status === 'cancelled') { await cancel(n.date, 'cancelled', n.url); continue; }
    if (n.originalDate) await cancel(n.originalDate, `moved to ${dayLabel(n.date)}`, n.url);
    let st = states.get(n.date);
    let row = noticeRows.find((r) => r.effective_date === n.date);
    const base: Base = { date: n.date, noticeId: row?.id ?? null, time: n.time, hours: n.hours, postId: n.postId, poster: n.poster, url: n.url, source: st?.source ?? (row ? srcOf(row) : 'socoteco') };
    if (st?.status === 'released') { st = undefined; row = undefined; base.noticeId = null; } // it was cancelled and now it is posted again
    const insert = async () => {
      const { data, error } = await db.from('ops_notices').insert({
        property_id: pid, notice_type: 'brownout', title: n.title, description: `${n.purpose ? n.purpose + ' | ' : ''}poster ${n.poster}`,
        effective_date: n.date, effective_time: n.time, duration_hours: n.hours, feeder: `Feeder ${FEEDER}`, posted_by_name: 'Power watch (socoteco2.com)', source: 'socoteco',
      }).select('id').single();
      if (error) throw new Error(`ops_notices: ${error.message}`);
      base.noticeId = data?.id ?? null;
      noticeRows.push({ id: String(base.noticeId), effective_date: n.date, effective_time: n.time, duration_hours: n.hours, source: 'socoteco' });
    };
    const update = async () => {
      const { error } = await db.from('ops_notices').update({
        title: n.title, description: `${n.purpose ? n.purpose + ' | ' : ''}poster ${n.poster}`, effective_time: n.time, duration_hours: n.hours, updated_at: nowIso,
      }).eq('id', row!.id);
      if (error) throw new Error(`ops_notices: ${error.message}`);
    };

    if (!st && !row) { await insert(); await announce('new', base, undefined, n); res.push(`${n.date}: new`); continue; }
    const cur = st ? { time: st.time, hours: st.hours } : { time: row!.effective_time, hours: num(row!.duration_hours) };
    if (sameWindow(cur, n)) {
      if (!st) { await announce('new', baseFromRow(row!), undefined, undefined); res.push(`${n.date}: adopted`); } else res.push(`${n.date}: known`);
      continue;
    }
    if (st && n.postId <= st.postId) { res.push(`${n.date}: older poster ignored`); continue; }
    if (row) await update(); else await insert();
    if (st) { await announce('changed', base, st); res.push(`${n.date}: changed`); }
    else { await announce('new', base, undefined, n); res.push(`${n.date}: adopted with the poster's times`); }
  }

  // Notices already on the board that this module has never seen (a photo saved in Telegram, the ones before v2).
  for (const r of noticeRows.filter((x) => !states.has(x.effective_date)).slice(0, 5)) {
    await announce('new', baseFromRow(r)); res.push(`${r.effective_date}: adopted`);
  }

  // SPEC-41 Part 3 (D-299.1): a brownout block stays only while SOCOTECO's current schedule still lists the outage. Runs before the cards
  // go out, so a guest-night question (the cancel card) is asked in this run. Unknown or a failed scrape never reaches here as "gone".
  const stale = staleNotices([...states.values()], d.schedule ?? null, rows, today);
  for (const date of stale.hit) {
    if ((states.get(date)?.missRuns ?? 0) > 0) { const n = await patchNoticeState(db, date, { missRuns: 0 }); if (n) states.set(date, n); }
  }
  for (const date of stale.miss) {
    const n = await patchNoticeState(db, date, { missRuns: (states.get(date)?.missRuns ?? 0) + 1 });
    if (n) states.set(date, n);
    res.push(`${date}: not on the SOCOTECO schedule (clean scrape 1 of 2)`);
  }
  for (const date of stale.ask) await cancel(date, 'no longer lists', states.get(date)?.url ?? ''); // a guest is in: asked once, nothing released without a tap
  for (const date of stale.release) {
    const r = await releaseNotice(db, pid, date, 'unblock', 'auto: not on SOCOTECO schedule'); // respects releasable(): a night another active notice needs stays held
    if (!r.ok) { d.log('power_watch_release_failed', { date, error: r.error }); continue; } // the miss count stays, so the next run tries again
    const done = await readNotice(db, date);
    if (done) states.set(date, done);
    res.push(`${date}: released (not on SOCOTECO schedule)`);
    if (r.nights.length && done) { // nothing freed (every night already free or needed elsewhere) = nothing to say
      const card = releasedCard(done, r.nights);
      if (!(await d.send(card))) d.log('power_watch_card_failed', { date, kind: 'released', chat: 'ops' });
      if (d.sendFinance && !(await d.sendFinance(card))) d.log('power_watch_card_failed', { date, kind: 'released', chat: 'finance' });
    }
  }

  // Cards that are waiting to go out, including any a failed Telegram send left behind last run.
  const linked = (s: NoticeState): NoticeState => (s.url ? s : { ...s, url: posterFor(s.date, d.posters ?? []) });
  for (const st of [...states.values()].filter((s) => s.card).map(linked)) {
    const kind = st.card!.kind;
    const card = kind === 'new' ? newCard(st) : kind === 'changed' ? changedCard(st) : cancelCard(st);
    if (!(await d.send(card))) { d.log('power_watch_card_failed', { date: st.date, kind }); continue; }
    const next = await patchNoticeState(db, st.date, { card: null, ...(kind === 'cancel' ? { cancelAskedAt: nowIso } : { cardAt: nowIso }) });
    if (next) states.set(st.date, next);
    if (kind !== 'cancel') for (const extra of extraGuestCards(st, kind === 'changed')) await d.send(extra);
  }

  // Follow-ups on what we hold.
  for (const st of [...states.values()].filter((x) => noticeRows.some((r) => r.effective_date === x.date))) { // a notice taken off the board is not chased
    if (seenDue(st, rows)) {
      if (await d.send(seenCard(st))) { const n = await patchNoticeState(db, st.date, { seenAt: nowIso }); if (n) states.set(st.date, n); res.push(`${st.date}: airbnb block seen`); }
    } else if (reminderDue(st, rows, now, today)) {
      if (await d.send(reminderCard(linked(st)))) { const n = await patchNoticeState(db, st.date, { remindedAt: nowIso }); if (n) states.set(st.date, n); res.push(`${st.date}: reminder`); }
    }
  }
  return res;
}

const nextDay = (ymd: string) => new Date(Date.parse(`${ymd}T00:00:00Z`) + 86_400_000).toISOString().slice(0, 10);

/** Drop the state of outages over for a week, so the keys do not pile up. */
export async function pruneStates(db: Db, today: string): Promise<number> {
  const old = (await listNotices(db)).filter((s) => s.date < new Date(Date.parse(`${today}T00:00:00Z`) - 7 * 86_400_000).toISOString().slice(0, 10));
  for (const s of old) await db.from('app_settings').delete().eq('key', `power_watch_notice:${s.date}`);
  return old.length;
}
