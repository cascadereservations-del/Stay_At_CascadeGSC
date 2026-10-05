// power-watch, the orchestration (D-290): what one run does with the notices it found, the ones already on the board, and the
// ones it holds blocks for. IO goes through `Deps` (a database, a Telegram sender, a mailer), so watch.test.ts runs every
// path against an in-memory database. Nothing here writes to Airbnb or sends anything to a guest.
import { cancelBrownoutRows, brownoutUid, holds, listNotices, patchNoticeState, putNoticeState, readNotice, releasable, releaseNotice, type NoticeSource, type NoticeState } from '../_shared/cascade-core/brownout.ts';
import { alertText, dayLabel, FEEDER, posterFor, type Notice } from './poster.ts';
import { AIRBNB_CAL, airbnbBlocks, bookingCard, cancelCard, changedCard, classifyNights, extraGuestCards, heldBookings, newCard, nightsLine, noSupersede, releasedCard, reminderCard, reminderDue, seenCard, seenDue, staleNotices, touchedNights, unverifiedCard, unverifiedDue, windowLabel, type Built, type Row, type Schedule, type Superseded, type WatchState } from './plan.ts';

// deno-lint-ignore no-explicit-any
type Db = any;
export type Deps = {
  db: Db; propertyId: string; today: string; now: Date;
  send: (card: Built) => Promise<boolean | number>; // a number = the OPS message id (kept so the Done button can be taken off later)
  edit?: (messageId: number, markup: unknown) => Promise<boolean>; // replace the buttons on a card already in OPS
  mail: (subject: string, body: string) => Promise<boolean>;
  log: (event: string, data: unknown) => void;
  posters?: string[]; // poster URLs already read (power_watch_state.images): the link for a notice that has none of its own
  schedule?: Schedule; // SPEC-41: what SOCOTECO's current posts say (plan.ts scheduleFrom); absent or null = unknown, nothing is ever released
  sendFinance?: (card: Built) => Promise<boolean | number>; // the same card to the Finance chat (the auto-release card goes to OPS and Finance)
  superseded?: Superseded; // Lloyd 2026-10-05 (plan.ts supersededBy): dates and posters a newer same-substation, same-kind post moved; absent = none
};
export type Found = Notice & { postId: number; postedAt?: string | null }; // postedAt: when its SOCOTECO post was published
/** The posted_by_name power-watch writes on the notices it inserts itself. Only those are ever auto-released (a dashboard entry, a staff photo, an NGCP or Cassy notice never is). */
export const POWER_WATCH_NAME = 'Power watch (socoteco2.com)';
type NoticeRow = { id: string; effective_date: string; effective_time: string | null; duration_hours: number | string | null; source?: string | null; posted_by_name?: string | null };
type Base = { date: string; noticeId: string | null; time: string | null; hours: number | null; postId: number; poster: string; url: string; source?: NoticeSource; enteredBy?: string; postedAt?: string };
/** A row with no source (written before the SPEC-41 release, or by an old writer) reads as SOCOTECO, like a state with none. For DISPLAY only: release is decided by POWER_WATCH_NAME. */
const srcOf = (r: { source?: string | null } | undefined): NoticeSource => (r?.source === 'ngcp' || r?.source === 'staff' ? r.source : 'socoteco');

const hhmm = (t: string | null) => (t ? t.slice(0, 5) : null);
const num = (v: unknown) => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v)) ? null : Number(v));
/** The same outage: a missing time or length on either side is not a difference (the old rule: an untimed notice matches). */
const sameWindow = (a: { time: string | null; hours: number | null }, b: { time: string | null; hours: number | null }) =>
  !a.time || !b.time || (hhmm(a.time) === hhmm(b.time) && (a.hours === null || b.hours === null || Math.abs(a.hours - b.hours) < 0.01));

export async function reconcile(d: Deps, foundAll: Found[]): Promise<string[]> {
  const { db, propertyId: pid, today, now } = d;
  const nowIso = now.toISOString();
  const res: string[] = [];
  const sup = d.superseded ?? noSupersede();
  // Lloyd 2026-10-05: a poster a newer post of the same substation and kind has replaced (the Oct 8 one, after the Oct 15 one) is never announced again.
  const found = foundAll.filter((n) => {
    const mv = sup.urls.get(n.url);
    if (mv) res.push(`${n.date}: superseded by the newer SOCOTECO post for ${mv.to}, not announced`);
    return !mv;
  });

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
      ...((prev as WatchState | undefined)?.bookingAlerts ? { bookingAlerts: (prev as WatchState).bookingAlerts } : {}), // D-308.3: a changed time must not re-announce a booking OPS already heard about
      ...(prev && !added.length ? { cardAt: prev.cardAt, doneAt: prev.doneAt, doneBy: prev.doneBy, seenAt: prev.seenAt, remindedAt: prev.remindedAt, cardMsgId: prev.cardMsgId, remindMsgId: prev.remindMsgId, unverifiedAt: prev.unverifiedAt } : {}),
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
  async function cancel(date: string, note: string, url: string, postId: number) {
    const row = noticeRows.find((r) => r.effective_date === date);
    let st = states.get(date);
    if (st && (st.status !== 'active' || st.cancelAskedAt || st.postId > postId)) return; // a newer poster set this date: an old cancelled or moved poster read again must not ask to unblock it
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
    if (n.status === 'cancelled') { await cancel(n.date, 'cancelled', n.url, n.postId); continue; }
    if (n.originalDate) await cancel(n.originalDate, `moved to ${dayLabel(n.date)}`, n.url, n.postId);
    let st = states.get(n.date);
    let row = noticeRows.find((r) => r.effective_date === n.date);
    const base: Base = { date: n.date, noticeId: row?.id ?? null, time: n.time, hours: n.hours, postId: n.postId, poster: n.poster, url: n.url, source: st?.source ?? (row ? srcOf(row) : 'socoteco'), ...(n.postedAt ? { postedAt: n.postedAt } : {}) };
    if (st?.status === 'released') {
      // 2026-10-05 (Lloyd, D-299): a released outage stays released when the SAME poster is read again (a deploy re-read the Oct 8 poster
      // and re-blocked Oct 7-8 after it had moved). Only a different poster for the date is "posted again".
      // Audit 4fb64e0: cancel() overwrites st.url with the poster that moved it, so also ignore any poster from the same or an older post.
      if ((n.url && st.url === n.url) || (st.postId > 0 && n.postId <= st.postId)) { res.push(`${n.date}: released, same poster ignored`); continue; }
      st = undefined; row = undefined; base.noticeId = null; // it was cancelled and now it is posted again
    }
    const insert = async () => {
      const { data, error } = await db.from('ops_notices').insert({
        property_id: pid, notice_type: 'brownout', title: n.title, description: `${n.purpose ? n.purpose + ' | ' : ''}poster ${n.poster}`,
        effective_date: n.date, effective_time: n.time, duration_hours: n.hours, feeder: `Feeder ${FEEDER}`, posted_by_name: POWER_WATCH_NAME, source: 'socoteco',
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
    // equal postId with a different poster URL = a corrected poster added to a post we already hold: newer, not ignored (a live state may carry no url: same poster)
    if (st && (n.postId < st.postId || (n.postId === st.postId && (!st.url || n.url === st.url)))) { res.push(`${n.date}: older poster ignored`); continue; }
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
  // Auto-release is for the notices power-watch inserted itself (POWER_WATCH_NAME, a SOCOTECO source). Every other notice (a dashboard entry with no source,
  // a staff photo or text, Cassy) is never released by a scrape: after two clean misses it is ASKED once instead (the cancel card, one Unblock tap), so a stale
  // hand entry is still re-checked (D-299.1) without a false release. An NGCP or staff-source notice is not checked against SOCOTECO at all (plan.ts).
  const ours = (r: NoticeRow) => r.posted_by_name === POWER_WATCH_NAME && srcOf(r) === 'socoteco';
  const autoDates = new Set(noticeRows.filter(ours).map((r) => r.effective_date));
  for (const r of noticeRows) if (!ours(r)) autoDates.delete(r.effective_date);
  const protectedDates = new Set([...states.keys()].filter((date) => !autoDates.has(date)));
  // Lloyd 2026-10-05 (overrides the audit-L5a "no supersede" rule): a newer SOCOTECO post of the same substation and kind for ANOTHER date moved the older
  // one. Judged only on a known schedule (every poster decided), never over a guest, and only for SOCOTECO-source notices (NGCP/staff are never checked, and
  // Keep it blocked makes a notice staff, so a tap is final). A notice power-watch inserted and no guest stays on is released with the existing card
  // (Keep it blocked is the way back); a hand-entered one, or one with a guest on a held night, is asked once (the cancel card, one Unblock tap).
  if (d.schedule) for (const [date, mv] of sup.dates) {
    const st = states.get(date);
    if (!st || !holds(st) || date < today || (st.source ?? 'socoteco') !== 'socoteco' || st.cancelAskedAt || st.card?.kind === 'cancel') continue;
    // (supersededBy only yields moves of MAX_AUTO_MOVE_DAYS or less: a later one may be a second job and is never a supersede)
    if (protectedDates.has(date) || classifyNights(st.blocked, rows, today).guests.length) { await cancel(date, `moved to ${dayLabel(mv.to)}`, mv.url, Number.MAX_SAFE_INTEGER); continue; }
    const r = await releaseNotice(db, pid, date, 'unblock', `auto: moved to ${mv.to} (newer SOCOTECO post)`);
    if (!r.ok) { d.log('power_watch_release_failed', { date, error: r.error }); continue; } // the next run tries again
    const done = await readNotice(db, date);
    if (done) states.set(date, done);
    res.push(`${date}: released (moved to ${dayLabel(mv.to)} by a newer SOCOTECO post)`);
    if (r.nights.length && done) {
      const card = releasedCard(done, r.nights, mv);
      if (!(await d.send(card))) d.log('power_watch_card_failed', { date, kind: 'released', chat: 'ops' });
      if (d.sendFinance && !(await d.sendFinance(card))) d.log('power_watch_card_failed', { date, kind: 'released', chat: 'finance' });
    }
  }
  const stale = staleNotices([...states.values()], d.schedule ?? null, rows, today, protectedDates);
  for (const date of [...stale.hit, ...stale.unknown]) { // a listed or an unjudgeable run breaks the streak: release needs two CONSECUTIVE clean misses
    if ((states.get(date)?.missRuns ?? 0) > 0) { const n = await patchNoticeState(db, date, { missRuns: 0 }); if (n) states.set(date, n); }
  }
  for (const date of stale.miss) {
    const n = await patchNoticeState(db, date, { missRuns: (states.get(date)?.missRuns ?? 0) + 1 });
    if (n) states.set(date, n);
    res.push(`${date}: not on the SOCOTECO schedule (clean scrape 1 of 2)`);
  }
  for (const date of stale.ask) await cancel(date, 'no longer lists', states.get(date)?.url ?? '', Number.MAX_SAFE_INTEGER); // a guest is in: asked once, nothing released without a tap
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
  const msgId = (r: boolean | number) => (typeof r === 'number' && r > 0 ? r : undefined);
  for (const s of [...states.values()].filter((x) => x.card).map(linked)) {
    const kind = s.card!.kind;
    // 2026-10-05 (Lloyd): if the Airbnb calendar already shows every night we hold, the job is done before it is asked: the card says so, no Done button, no reminder.
    const auto = kind !== 'cancel' && !s.doneAt && s.blocked.length > 0 && airbnbBlocks(s.blocked, rows);
    const st: NoticeState = auto ? { ...s, doneAt: nowIso, doneBy: AIRBNB_CAL, seenAt: nowIso } : s;
    const card = kind === 'new' ? newCard(st) : kind === 'changed' ? changedCard(st) : cancelCard(st);
    const sent = await d.send(card);
    if (!sent) { d.log('power_watch_card_failed', { date: st.date, kind }); continue; }
    const next = await patchNoticeState(db, st.date, {
      card: null, ...(kind === 'cancel' ? { cancelAskedAt: nowIso } : { cardAt: nowIso, cardMsgId: msgId(sent) }),
      ...(auto ? { doneAt: nowIso, doneBy: AIRBNB_CAL, seenAt: nowIso } : {}),
    });
    if (next) states.set(st.date, next);
    if (auto) res.push(`${st.date}: airbnb already blocked, closed`);
    if (kind !== 'cancel') for (const extra of extraGuestCards(st, kind === 'changed')) await d.send(extra);
  }

  // Follow-ups on what we hold.
  for (const st of [...states.values()].filter((x) => noticeRows.some((r) => r.effective_date === x.date))) { // a notice taken off the board is not chased
    if (seenDue(st, rows)) {
      // The Airbnb calendar now shows the block: mark it done (a tap is no longer needed) and take the Done button off the card and the reminder.
      if (await d.send(seenCard(st))) {
        const n = await patchNoticeState(db, st.date, { seenAt: nowIso, ...(st.doneAt ? {} : { doneAt: nowIso, doneBy: AIRBNB_CAL }) });
        if (n) states.set(st.date, n);
        // the card's own keyboard rebuilt with Done gone, so a 📨 guest-draft row stays (audit 656fee7)
        const kept = newCard({ ...st, doneBy: AIRBNB_CAL }).markup ?? { inline_keyboard: [] };
        if (d.edit && st.cardMsgId && !(await d.edit(st.cardMsgId, kept))) d.log('power_watch_edit_failed', { date: st.date, what: 'card' });
        if (d.edit && st.remindMsgId && !(await d.edit(st.remindMsgId, { inline_keyboard: [] }))) d.log('power_watch_edit_failed', { date: st.date, what: 'reminder' });
        res.push(`${st.date}: airbnb block seen`);
      }
    } else if (reminderDue(st, rows, now, today)) {
      const sent = await d.send(reminderCard(linked(st)));
      if (sent) { const n = await patchNoticeState(db, st.date, { remindedAt: nowIso, remindMsgId: msgId(sent) }); if (n) states.set(st.date, n); res.push(`${st.date}: reminder`); }
    } else if (unverifiedDue(st, rows, now, today)) {
      if (await d.send(unverifiedCard(linked(st)))) { const n = await patchNoticeState(db, st.date, { unverifiedAt: nowIso }); if (n) states.set(st.date, n); res.push(`${st.date}: done tapped, airbnb still open`); }
    }
  }

  // D-308.3 (Lloyd 2026-10-06): a guest booked a night we hold for an active brownout. ONE OPS card per (notice date, booking), remembered on the notice state
  // (bookingAlerts) so a re-run never repeats it. Skipped for a released, undone or taken-off-board notice and for a cancelled or moved one (a pending or asked cancel card).
  // Nothing is sent to the guest; Marifel reads the card and writes to them herself.
  for (const st of [...states.values()].filter((x) => noticeRows.some((r) => r.effective_date === x.date))) {
    if (!holds(st) || st.date < today || st.card || st.cancelAskedAt) continue;
    const told = new Set((st as WatchState).bookingAlerts ?? []);
    for (const b of heldBookings(st, rows, today).filter((x) => !told.has(x.uid))) {
      if (!(await d.send(bookingCard(linked(st), b)))) { d.log('power_watch_card_failed', { date: st.date, kind: 'booking', chat: 'ops' }); continue; } // the next run tries again
      told.add(b.uid);
      const n = await patchNoticeState(db, st.date, { bookingAlerts: [...told] } as Partial<NoticeState>);
      if (n) states.set(st.date, n);
      res.push(`${st.date}: a guest booked a held night, OPS told`);
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
