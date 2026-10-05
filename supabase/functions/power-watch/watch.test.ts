// deno test supabase/functions/power-watch/watch.test.ts - whole runs against an in-memory database. Synthetic data only.
import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { keepNotice, listNotices, patchNoticeState, readNotice, releaseNotice } from '../_shared/cascade-core/brownout.ts';
import { FakeDb } from './fake-db.ts';
import { scheduleFrom, type Built, type Schedule } from './plan.ts';
import { POWER_WATCH_NAME, pruneStates, reconcile, type Found } from './watch.ts';

const PID = 'prop-1', URL0 = 'https://www.socoteco2.com/wp-content/uploads/2026/10/SPI-TEST.jpg';
const found = (date: string, time: string | null, hours: number | null, postId: number, extra: Partial<Found> = {}): Found => ({
  date, time, hours, title: 'SOCOTECO II scheduled interruption - TEST SUBSTATION (ours is 14-3)', purpose: 'Maintenance', poster: 'SPI-TEST.jpg', url: URL0,
  status: 'active', originalDate: null, postId, ...extra,
});
function world(tables: Record<string, Record<string, unknown>[]> = {}, posters: string[] = []) {
  const db = new FakeDb({ calendar_events: [], ops_notices: [], app_settings: [], ...tables });
  const sent: Built[] = [], fin: Built[] = [], mails: string[] = [], logs: string[] = [];
  let up = true;
  const run = (f: Found[], nowIso = '2026-10-02T01:00:00Z', schedule?: Schedule) => reconcile({
    db, propertyId: PID, today: '2026-10-02', now: new Date(nowIso),
    send: async (c) => { if (up) sent.push(c); return up; }, sendFinance: async (c) => { fin.push(c); return true; },
    mail: async (s) => { mails.push(s); return true; }, log: (e) => logs.push(e), posters, schedule,
  }, f);
  return { db, sent, fin, mails, logs, run, telegram: (ok: boolean) => { up = ok; } };
}
const brownoutRows = (db: FakeDb) => db.tables.calendar_events.filter((r) => String(r.uid).startsWith('brownout:'));
const live = (db: FakeDb) => brownoutRows(db).filter((r) => r.status === 'blocked').map((r) => r.checkin_date as string).sort();

Deno.test('a new outage: notice on the board, free nights blocked as manual rows, ONE card at once, one e-mail; the next run repeats nothing', async () => {
  const w = world();
  assertEquals(await w.run([found('2026-10-15', '06:00:00', 11, 100)]), ['2026-10-15: new']);
  assertEquals(w.db.tables.ops_notices.length, 1);
  assertEquals(w.db.tables.ops_notices[0].notice_type, 'brownout');
  assertEquals(live(w.db), ['2026-10-14', '2026-10-15']);
  const r = brownoutRows(w.db).find((x) => x.checkin_date === '2026-10-14')!;
  assertEquals([r.source, r.status, r.recon_status, r.checkout_date, r.property_id, r.uid], ['manual', 'blocked', 'admin_block', '2026-10-15', PID, 'brownout:2026-10-14']);
  assertStringIncludes(String(r.raw_summary), 'SOCOTECO power interruption Thu 15 Oct, 06:00-17:00');
  assertEquals(w.sent.length, 1);
  assertStringIncludes(w.sent[0].text, 'Blocked on our booking site: nights of Oct 14 and Oct 15.');
  assertStringIncludes(w.sent[0].text, `SOCOTECO notice: ${URL0}`, 'the card links the poster it was read from');
  assertEquals(w.mails.length, 1);
  assertEquals(w.mails[0], 'Brownout at Cascade: Thu 15 Oct, 6:00 AM to 5:00 PM (11 h)');
  const st = (await readNotice(w.db, '2026-10-15'))!;
  assertEquals([st.status, st.blocked, st.card, !!st.cardAt], ['active', ['2026-10-14', '2026-10-15'], null, true]);
  assertEquals(await w.run([found('2026-10-15', '06:00:00', 11, 100)]), ['2026-10-15: known']);
  assertEquals([w.sent.length, w.mails.length, w.db.tables.ops_notices.length, brownoutRows(w.db).length], [1, 1, 1, 2]);
});

Deno.test('a guest in the house that night is never blocked: the card carries prep and the draft', async () => {
  const w = world({ calendar_events: [{ uid: 'direct:g1', source: 'direct', status: 'confirmed', checkin_date: '2026-10-13', checkout_date: '2026-10-15', guest_name: 'Test Guest', property_id: PID }] });
  await w.run([found('2026-10-15', '06:00:00', 11, 100)]);
  assertEquals(live(w.db), ['2026-10-15'], 'night 14 has the guest');
  const t = w.sent[0].text;
  assertStringIncludes(t, 'Not blocked, a guest is in the house: night of Oct 14.');
  assertStringIncludes(t, 'Test Guest is staying the night of Oct 14.');
  assertStringIncludes(t, '📨 Hi Test, a quick heads-up:');
});

Deno.test('a night already blocked in Airbnb is said, not blocked again', async () => {
  const w = world({ calendar_events: [{ uid: 'ab1', source: 'airbnb', status: 'blocked', checkin_date: '2026-10-14', checkout_date: '2026-10-16', property_id: PID }] });
  await w.run([found('2026-10-15', '06:00:00', 11, 100)]);
  assertEquals(brownoutRows(w.db).length, 0);
  assertStringIncludes(w.sent[0].text, 'Already blocked, so nothing was added: nights of Oct 14 and Oct 15.');
  assertEquals(w.sent[0].markup, undefined);
});

Deno.test('a notice already on the board with no state (a photo saved in Telegram, or one from before v2) is adopted once', async () => {
  const ours = 'https://www.socoteco2.com/wp-content/uploads/2026/09/SPI-PMS-10082026-LEON-LLIDO-SS.jpg', other = 'https://www.socoteco2.com/wp-content/uploads/2026/09/SPI-PMS-10082026-MAASIM-A-SS.jpg';
  const w = world({ ops_notices: [{ id: 'n-old', property_id: PID, notice_type: 'brownout', is_active: true, effective_date: '2026-10-08', effective_time: '06:00:00', duration_hours: '11.0' }] }, [ours, other]);
  assertEquals(await w.run([]), ['2026-10-08: adopted']);
  assertEquals(live(w.db), ['2026-10-07', '2026-10-08']);
  assertEquals(w.sent.length, 1);
  assertEquals(w.mails.length, 0, 'adopted notices were already e-mailed or typed by a person');
  assertStringIncludes(w.sent[0].text, `SOCOTECO notice: ${ours}`, 'a typed notice gets its poster from the ones already read, never another substation');
  assertEquals(await w.run([]), []);
  assertEquals(w.sent.length, 1);
  // the same poster arrives: same times, so it is the known outage and the board keeps ONE row
  assertEquals(await w.run([found('2026-10-08', '06:00:00', 11, 90)]), ['2026-10-08: known']);
  assertEquals(w.db.tables.ops_notices.length, 1);
});

Deno.test('Telegram down: the blocks hold, the card waits and goes out next run exactly once', async () => {
  const w = world();
  w.telegram(false);
  await w.run([found('2026-10-15', '06:00:00', 11, 100)]);
  assertEquals([w.sent.length, live(w.db).length, (await readNotice(w.db, '2026-10-15'))!.card?.kind], [0, 2, 'new']);
  w.telegram(true);
  await w.run([]);
  await w.run([]);
  assertEquals(w.sent.length, 1);
  assertEquals((await readNotice(w.db, '2026-10-15'))!.card, null);
});

Deno.test('follow-ups: Airbnb block seen is said once; with no block one reminder after 3 hours; Done silences it', async () => {
  const seen = world();
  await seen.run([found('2026-10-15', '06:00:00', 11, 100)]);
  seen.db.tables.calendar_events.push({ uid: 'ab9', source: 'airbnb', status: 'blocked', checkin_date: '2026-10-14', checkout_date: '2026-10-16', property_id: PID });
  assertEquals(await seen.run([], '2026-10-02T01:15:00Z'), ['2026-10-15: airbnb block seen']);
  assertStringIncludes(seen.sent[1].text, '✅ Airbnb block seen for nights of Oct 14 and Oct 15');
  assertEquals(await seen.run([], '2026-10-02T09:00:00Z'), []);

  const quiet = world();
  await quiet.run([found('2026-10-15', '06:00:00', 11, 100)]);
  assertEquals(await quiet.run([], '2026-10-02T03:00:00Z'), []);
  assertEquals(await quiet.run([], '2026-10-02T04:00:00Z'), ['2026-10-15: reminder']);
  assertEquals(await quiet.run([], '2026-10-02T12:00:00Z'), [], 'one reminder only');
  assertStringIncludes(quiet.sent[1].text, 'Reminder: Airbnb is not blocked yet');

  const done = world();
  await done.run([found('2026-10-15', '06:00:00', 11, 100)]);
  await patchNoticeState(done.db, '2026-10-15', { doneAt: '2026-10-02T01:30:00Z', doneBy: 'Marifel' });
  assertEquals(await done.run([], '2026-10-02T04:00:00Z'), [], 'Done silences the reminder');
  assertEquals(done.sent.length, 1);
  // 2026-10-05: a Done tap is not proof. Three hours on, the Airbnb calendar still shows the nights open: one warning, never two.
  assertEquals(await done.run([], '2026-10-02T04:30:00Z'), ['2026-10-15: done tapped, airbnb still open']);
  assertStringIncludes(done.sent[1].text, '⚠ Airbnb still shows nights of Oct 14 and Oct 15 open');
  assertStringIncludes(done.sent[1].text, 'marked blocked by Marifel');
  assertEquals(await done.run([], '2026-10-02T09:00:00Z'), [], 'warned once');
  // then the block shows up in the feed: seen, and nothing more
  done.db.tables.calendar_events.push({ uid: 'ab7', source: 'airbnb', status: 'blocked', checkin_date: '2026-10-14', checkout_date: '2026-10-16', property_id: PID });
  assertEquals(await done.run([], '2026-10-02T09:15:00Z'), ['2026-10-15: airbnb block seen']);
  assertEquals((await readNotice(done.db, '2026-10-15'))!.doneBy, 'Marifel', 'a person who tapped stays on record');
});

Deno.test('2026-10-05: Airbnb already blocked when the card goes out: the card says so, no Done button, done by the Airbnb calendar, no reminder or seen card', async () => {
  const w = world();
  // our site holds the nights (a re-posted outage), and Marifel's Airbnb block is already in the feed
  w.db.tables.calendar_events.push({ uid: 'ab2', source: 'airbnb', status: 'blocked', checkin_date: '2026-10-14', checkout_date: '2026-10-16', property_id: PID });
  w.db.tables.calendar_events.push({ uid: 'brownout:2026-10-14', source: 'manual', status: 'blocked', checkin_date: '2026-10-14', checkout_date: '2026-10-15', property_id: PID });
  w.db.tables.calendar_events.push({ uid: 'brownout:2026-10-15', source: 'manual', status: 'blocked', checkin_date: '2026-10-15', checkout_date: '2026-10-16', property_id: PID });
  const r = await w.run([found('2026-10-15', '06:00:00', 11, 100)]);
  assertEquals(r, ['2026-10-15: new', '2026-10-15: airbnb already blocked, closed']);
  const t = w.sent[0].text;
  assertStringIncludes(t, 'Airbnb already shows these nights blocked (seen in the Airbnb calendar)');
  assert(!t.includes('Marifel: block'), 'no job for Marifel');
  const buttons = JSON.stringify(w.sent[0].markup);
  assert(!buttons.includes('pw:done'), 'no Done button');
  assertStringIncludes(buttons, 'pw:undo');
  const st = (await readNotice(w.db, '2026-10-15'))!;
  assertEquals([st.doneBy, !!st.doneAt, !!st.seenAt], ['Airbnb calendar', true, true]);
  assertEquals(await w.run([], '2026-10-02T09:00:00Z'), [], 'no reminder, no seen card, no warning');
  assertEquals(w.sent.length, 1);
});

Deno.test('2026-10-05: the card goes out first, Marifel blocks Airbnb later: done by the Airbnb calendar and the Done button comes off the card and the reminder', async () => {
  const db = new FakeDb({ calendar_events: [], ops_notices: [], app_settings: [] });
  const sent: Built[] = [], edits: Array<[number, string]> = [];
  let id = 500;
  const run = (f: Found[], nowIso: string) => reconcile({
    db, propertyId: PID, today: '2026-10-02', now: new Date(nowIso),
    send: async (c) => { sent.push(c); return ++id; }, edit: async (m, mk) => { edits.push([m, JSON.stringify(mk)]); return true; },
    mail: async () => true, log: () => {},
  }, f);
  await run([found('2026-10-15', '06:00:00', 11, 100)], '2026-10-02T01:00:00Z');
  assertEquals(await run([], '2026-10-02T04:00:00Z'), ['2026-10-15: reminder']);
  const before = (await readNotice(db, '2026-10-15'))!;
  assertEquals([before.cardMsgId, before.remindMsgId], [501, 502]);
  db.tables.calendar_events.push({ uid: 'ab3', source: 'airbnb', status: 'blocked', checkin_date: '2026-10-14', checkout_date: '2026-10-16', property_id: PID });
  assertEquals(await run([], '2026-10-02T04:15:00Z'), ['2026-10-15: airbnb block seen']);
  const after = (await readNotice(db, '2026-10-15'))!;
  assertEquals([after.doneBy, !!after.doneAt, !!after.seenAt], ['Airbnb calendar', true, true]);
  assertEquals(edits.map(([m]) => m), [501, 502]);
  assert(!edits[0][1].includes('pw:done') && edits[0][1].includes('pw:undo'), 'the card keeps Undo only');
  assertEquals(edits[1][1], '{"inline_keyboard":[]}', 'the reminder loses its button');
  assertEquals(await run([], '2026-10-02T09:00:00Z'), [], 'nothing more');
});

Deno.test('2026-10-05 (D-299): a released outage is not re-announced when the same poster is read again; a different poster still is', async () => {
  const w = world();
  await w.run([found('2026-10-08', '06:00:00', 11, 100)]);
  const r = await releaseNotice(w.db, PID, '2026-10-08', 'unblock', 'Lloyd');
  assert(r.ok);
  assertEquals(live(w.db), []);
  assertEquals(await w.run([found('2026-10-08', '06:00:00', 11, 100)]), ['2026-10-08: released, same poster ignored']);
  assertEquals([live(w.db), w.sent.length], [[], 1], 'no block, no new card');
  const other = 'https://www.socoteco2.com/wp-content/uploads/2026/10/SPI-PMS-10082026-LEON-LLIDO-SS-2.jpg';
  assertEquals(await w.run([found('2026-10-08', '06:00:00', 11, 120, { url: other, poster: 'SPI-PMS-10082026-LEON-LLIDO-SS-2.jpg' })]), ['2026-10-08: new']);
  assertEquals(live(w.db), ['2026-10-07', '2026-10-08']);
});

Deno.test('audit 656fee7: a guest reservation on a held night is not an Airbnb block - never "seen", never closed by the calendar', async () => {
  const w = world();
  await w.run([found('2026-10-15', '06:00:00', 11, 100)]);
  w.db.tables.calendar_events.push({ uid: 'res1', source: 'airbnb', status: 'confirmed', checkin_date: '2026-10-14', checkout_date: '2026-10-16', guest_name: 'Reserved', property_id: PID });
  const r = await w.run([], '2026-10-02T01:15:00Z');
  assert(!r.includes('2026-10-15: airbnb block seen'), 'a reservation is not a block');
  const st = (await readNotice(w.db, '2026-10-15'))!;
  assertEquals([st.doneAt, st.seenAt], [undefined, undefined]);
});

Deno.test('a newer poster with new times updates the notice and the blocks, and an older poster does not undo it', async () => {
  const w = world();
  await w.run([found('2026-10-15', '06:00:00', 11, 100)]);
  const moved = 'https://www.socoteco2.com/wp-content/uploads/2026/10/SPI-PMS-10152026-LEON-LLIDO-SS-REVISED.jpg';
  assertEquals(await w.run([found('2026-10-15', '08:00:00', 3, 110, { url: moved })], '2026-10-02T02:00:00Z'), ['2026-10-15: changed']);
  assertEquals(live(w.db), ['2026-10-14'], 'night 15 released on our site');
  assertEquals(brownoutRows(w.db).find((r) => r.checkin_date === '2026-10-15')!.status, 'cancelled');
  assertEquals(w.db.tables.ops_notices.length, 1, 'updated, not a second row');
  assertEquals([w.db.tables.ops_notices[0].effective_time, w.db.tables.ops_notices[0].duration_hours], ['08:00:00', 3]);
  assertStringIncludes(w.sent[1].text, 'SOCOTECO changed the power interruption on Thu 15 Oct');
  assertStringIncludes(w.sent[1].text, 'Released on our booking site: night of Oct 15.');
  assertStringIncludes(w.sent[1].text, `SOCOTECO notice: ${moved}`, 'a changed card links the NEW poster');
  assertEquals(await w.run([found('2026-10-15', '06:00:00', 11, 100)], '2026-10-02T03:00:00Z'), ['2026-10-15: older poster ignored']);
  assertEquals(live(w.db), ['2026-10-14']);
  // later still, it grows again: night 15 comes back (the cancelled row is re-used, not duplicated)
  await w.run([found('2026-10-15', '13:00:00', 4, 120)], '2026-10-02T04:00:00Z');
  assertEquals(live(w.db), ['2026-10-15']);
  assertEquals(brownoutRows(w.db).length, 2);
});

Deno.test('a cancellation asks first; the Unblock tap frees the nights and takes the notice off the board; no reminder chases it', async () => {
  const w = world();
  await w.run([found('2026-10-15', '06:00:00', 11, 100)]);
  const off = 'https://www.socoteco2.com/wp-content/uploads/2026/10/SPI-CANCELLED-10152026-LEON-LLIDO-SS.jpg';
  assertEquals(await w.run([found('2026-10-15', null, null, 120, { status: 'cancelled', url: off })], '2026-10-02T02:00:00Z'), ['2026-10-15: cancelled']);
  assertStringIncludes(w.sent[1].text, `SOCOTECO notice: ${off}`, 'the cancel card links the cancellation poster');
  assertStringIncludes(w.sent[1].text, 'SOCOTECO cancelled the power interruption on Thu 15 Oct');
  assertStringIncludes(w.sent[1].text, 'Unblock nights of Oct 14 and Oct 15 on our booking site and in Airbnb?');
  assertEquals(live(w.db), ['2026-10-14', '2026-10-15'], 'nothing released before the tap');
  assertEquals(await w.run([], '2026-10-02T09:00:00Z'), [], 'asked once, no reminder');
  const r = await releaseNotice(w.db, PID, '2026-10-15', 'unblock', 'Marifel');
  assertEquals(r.ok && r.nights, ['2026-10-14', '2026-10-15']);
  assertEquals(live(w.db), []);
  assertEquals(w.db.tables.ops_notices[0].is_active, false);
  assertEquals((await readNotice(w.db, '2026-10-15'))!.status, 'released');
  const again = await releaseNotice(w.db, PID, '2026-10-15', 'unblock', 'Marifel');
  assertEquals(again.ok && again.already, true, 'a second tap changes nothing');
});

Deno.test('a poster that moves an outage asks to unblock the old date and announces the new one', async () => {
  const w = world();
  await w.run([found('2026-10-15', '06:00:00', 11, 100)]);
  const resched = 'https://www.socoteco2.com/wp-content/uploads/2026/10/SPI-PMS-10222026-LEON-LLIDO-SS.jpg';
  await w.run([found('2026-10-22', '06:00:00', 11, 130, { originalDate: '2026-10-15', url: resched })], '2026-10-02T02:00:00Z');
  assertEquals(w.sent.length, 3);
  assertStringIncludes(w.sent[1].text, 'SOCOTECO moved to Thu 22 Oct the power interruption on Thu 15 Oct');
  assertStringIncludes(w.sent[2].text, 'Blocked on our booking site: nights of Oct 21 and Oct 22.');
  assertStringIncludes(w.sent[1].text, `SOCOTECO notice: ${resched}`, 'the old date links the poster that moved it');
  assertStringIncludes(w.sent[2].text, `SOCOTECO notice: ${resched}`);
  assertEquals(live(w.db), ['2026-10-14', '2026-10-15', '2026-10-21', '2026-10-22']);
});

Deno.test('two outages that touch the same night: undoing one keeps the night the other still needs', async () => {
  const w = world();
  await w.run([found('2026-10-14', '18:00:00', 2, 100), found('2026-10-15', '06:00:00', 11, 101)]);
  assertEquals(live(w.db), ['2026-10-14', '2026-10-15'], 'night 14 is one row for both');
  const r = await releaseNotice(w.db, PID, '2026-10-15', 'undo', 'Marifel');
  assertEquals(r.ok && r.nights, ['2026-10-15']);
  assertEquals(live(w.db), ['2026-10-14']);
  assertEquals((await readNotice(w.db, '2026-10-15'))!.status, 'undone');
});

Deno.test('undo / unblock on a notice with no state, and old states are pruned', async () => {
  const w = world();
  const r = await releaseNotice(w.db, PID, '2026-10-15', 'undo', 'Marifel');
  assertEquals(r.ok, false);
  await w.run([found('2026-10-02', '13:00:00', 4, 1)]);
  await patchNoticeState(w.db, '2026-10-02', { date: '2026-10-02' });
  assertEquals((await listNotices(w.db)).length, 1);
  assertEquals(await pruneStates(w.db, '2026-10-09'), 0);
  assertEquals(await pruneStates(w.db, '2026-10-10'), 1);
  assert((await listNotices(w.db)).length === 0);
});

// ---- SPEC-41 Part 3: a brownout block must be backed by a live notice ---------------------------------------------------------
const P = 'https://www.socoteco2.com/wp-content/uploads/2026/10/';
/** The live shape of 2026-10-05: post 22013 (Oct 10-25) carries the same substation posters as 21945 (Oct 3-18), shifted a week. */
const MOVED = () => scheduleFrom([
  { id: 22013, posters: [P + 'SPI-PMS-10102026-DAMALERIO-SS.jpg', P + 'SPI-PMS-10152026-LEON-LLIDO-SS.jpg', P + 'SPI-PMS-10252026-TUPI-B-SS.jpg'] },
  { id: 21945, posters: [P + 'SPI-PMS-10032026-PENTAGON-SS.jpg', P + 'SPI-PMS-10082026-LEON-LLIDO-SS.jpg', P + 'SPI-PMS-10182026-TUPI-B-SS.jpg'] },
], {}, () => true);
/** A notice power-watch itself inserted for an earlier poster (postId 0 in its state, no poster url). Typed, staff and dashboard rows override posted_by_name and source. */
const hand = (date: string, o: Record<string, unknown> = {}) => ({
  id: `n-${date}`, property_id: PID, notice_type: 'brownout', is_active: true, effective_date: date, effective_time: '06:00:00', duration_hours: '11.0',
  source: 'socoteco', posted_by_name: POWER_WATCH_NAME, ...o,
});
/** Three quick runs, all inside the 3-hour reminder grace. */
const at = (i: number) => `2026-10-02T01:${15 * (i + 1)}:00Z`;
const sched = (listed: string[], from = '2026-10-01', to = '2026-10-31'): Schedule => ({ listed: new Set(listed), covered: (d) => d >= from && d <= to });

Deno.test('SPEC-41 3.5-1: the moved series. Oct 12 is a miss, then released on the second run; Oct 15 is a hit and untouched; one card to OPS and one to Finance', async () => {
  const sc = MOVED()!;
  assertEquals([...sc.listed].sort(), ['2026-10-08', '2026-10-15'], 'no supersede: the older post is still in the feed, so Oct 8 stays listed');
  assertEquals([sc.covered('2026-10-12'), sc.covered('2026-10-15'), sc.covered('2026-11-20')], [true, true, false]);
  const w = world({ ops_notices: [hand('2026-10-12')] });
  await w.run([found('2026-10-15', '06:00:00', 11, 22013, { url: P + 'SPI-PMS-10152026-LEON-LLIDO-SS.jpg' })]); // adopts Oct 8, announces Oct 15
  assertEquals(live(w.db), ['2026-10-11', '2026-10-12', '2026-10-14', '2026-10-15']);
  const cards = w.sent.length;
  assertEquals(await w.run([], '2026-10-02T01:15:00Z', sc), ['2026-10-12: not on the SOCOTECO schedule (clean scrape 1 of 2)']);
  assertEquals((await readNotice(w.db, '2026-10-12'))!.missRuns, 1);
  assertEquals(live(w.db), ['2026-10-11', '2026-10-12', '2026-10-14', '2026-10-15'], 'nothing released on the first miss');
  assertEquals(await w.run([], '2026-10-02T01:30:00Z', sc), ['2026-10-12: released (not on SOCOTECO schedule)']);
  assertEquals(live(w.db), ['2026-10-14', '2026-10-15']);
  const st = (await readNotice(w.db, '2026-10-12'))!;
  assertEquals([st.status, st.releasedBy, st.blocked], ['released', 'auto: not on SOCOTECO schedule', []]);
  assertEquals(w.db.tables.ops_notices.find((r) => r.effective_date === '2026-10-12')!.is_active, false);
  assertEquals(w.db.tables.ops_notices.find((r) => r.effective_date === '2026-10-15')!.is_active, true);
  assertEquals((await readNotice(w.db, '2026-10-15'))!.status, 'active', 'Oct 15 is a hit');
  assertEquals([w.sent.length - cards, w.fin.length], [1, 1], 'one card to OPS and one to Finance');
  assertEquals(w.sent[w.sent.length - 1], w.fin[0]);
  const t = w.fin[0].text;
  assertStringIncludes(t, 'The nights of Oct 11 and Oct 12 are open again on our booking site. SOCOTECO no longer lists the Mon 12 Oct power interruption for Feeder 14-3 on its current schedule.');
  assertStringIncludes(t, 'Marifel: if Airbnb is still blocked for those nights, unblock them there.');
  assertStringIncludes(t, 'If SOCOTECO told you directly that it is still on, tap Keep it blocked.');
  assertEquals(w.fin[0].markup?.inline_keyboard, [[{ text: '🔒 Keep it blocked', callback_data: 'pw:keep:2026-10-12' }]]);
  assertEquals(await w.run([], '2026-10-02T01:45:00Z', sc), [], 'a released notice is not chased again');
});

Deno.test('SPEC-41 3.5-2: a notice power-watch inserted that is not on the schedule: run 1 counts, run 2 releases; a listing in between resets the count', async () => {
  const w = world({ ops_notices: [hand('2026-10-08')] });
  await w.run([]);
  const st0 = (await readNotice(w.db, '2026-10-08'))!;
  assertEquals([st0.postId, st0.poster, st0.source, st0.enteredBy], [0, '', 'socoteco', POWER_WATCH_NAME]);
  await w.run([], '2026-10-02T01:15:00Z', sched([]));
  assertEquals([(await readNotice(w.db, '2026-10-08'))!.missRuns, live(w.db).length], [1, 2]);
  assertEquals(await w.run([], '2026-10-02T01:30:00Z', sched(['2026-10-08'])), [], 'listed again');
  assertEquals((await readNotice(w.db, '2026-10-08'))!.missRuns, 0);
  await w.run([], '2026-10-02T01:45:00Z', sched([]));
  assertEquals([(await readNotice(w.db, '2026-10-08'))!.missRuns, live(w.db).length], [1, 2], 'the count started again, nothing released');
  assertEquals(await w.run([], '2026-10-02T02:00:00Z', sched([])), ['2026-10-08: released (not on SOCOTECO schedule)']);
  assertEquals(live(w.db), []);
});

Deno.test('SPEC-41 3.5-3: unknown is never gone. No schedule, a null schedule, no posts and an undecided poster release nothing and change no count', async () => {
  const w = world({ ops_notices: [hand('2026-10-08')] });
  await w.run([]);
  for (const s of [undefined, null]) assertEquals(await w.run([], '2026-10-02T01:15:00Z', s as Schedule), []);
  assertEquals(scheduleFrom([], {}, () => true), null, 'an empty power-post list is unknown');
  assertEquals(scheduleFrom([{ id: 1, posters: [P + 'SPI-PMS-10082026-LEON-LLIDO-SS.jpg'] }], {}, () => false), null, 'one undecided poster makes the whole feed unknown');
  assertEquals(scheduleFrom([{ id: 1, posters: [] }], {}, () => true), null, 'posts with no posters are unknown too');
  for (let i = 0; i < 3; i++) await w.run([], at(i), null);
  assertEquals([(await readNotice(w.db, '2026-10-08'))!.missRuns, live(w.db).length], [undefined, 2]);
  // a failed feed fetch throws before reconcile (index.ts run()), so reconcile is simply not called: the states stay as they were
});

Deno.test('SPEC-41 3.5-4: a guest on a night we hold turns the second miss into the guest-safe question; nothing is released without a tap', async () => {
  const w = world({ ops_notices: [hand('2026-10-08')] });
  await w.run([]);
  w.db.tables.calendar_events.push({ uid: 'ab-stay', source: 'airbnb', status: 'confirmed', checkin_date: '2026-10-06', checkout_date: '2026-10-08', guest_name: 'Test Guest', property_id: PID });
  const before = w.sent.length;
  await w.run([], '2026-10-02T01:15:00Z', sched([]));
  assertEquals(await w.run([], '2026-10-02T01:30:00Z', sched([])), ['2026-10-08: no longer lists']);
  assertEquals(live(w.db), ['2026-10-07', '2026-10-08'], 'no row cancelled');
  assertEquals(w.sent.length - before, 1);
  assertStringIncludes(w.sent[w.sent.length - 1].text, 'SOCOTECO no longer lists the power interruption on Thu 8 Oct (Feeder 14-3).');
  assertEquals(w.sent[w.sent.length - 1].markup?.inline_keyboard, [[{ text: '🔓 Unblock', callback_data: 'pw:unblock:2026-10-08' }]]);
  assertEquals(w.fin.length, 0, 'the question goes to OPS only');
  assertEquals(await w.run([], '2026-10-02T01:45:00Z', sched([])), [], 'asked once');
  assertEquals(w.sent.length - before, 1);
});

Deno.test('SPEC-41 3.5-5: NGCP and staff notices are never checked against the SOCOTECO schedule', async () => {
  const w = world({ ops_notices: [hand('2026-10-08', { source: 'ngcp', title: 'NGCP grid interruption' }), hand('2026-10-15', { source: 'staff', title: 'Water tank cleaning' })] });
  await w.run([]);
  assertEquals(live(w.db).length, 4);
  for (let i = 0; i < 3; i++) assertEquals(await w.run([], at(i), sched([])), []);
  assertEquals(live(w.db).length, 4);
  const [a, b] = [(await readNotice(w.db, '2026-10-08'))!, (await readNotice(w.db, '2026-10-15'))!];
  assertEquals([a.source, a.missRuns, a.status, b.source, b.missRuns, b.status], ['ngcp', undefined, 'active', 'staff', undefined, 'active']);
  // wording: an NGCP notice is not announced as SOCOTECO, and Feeder 14-3 is not claimed for it
  assertStringIncludes(w.sent[0].text, '⚡ NGCP power interruption Thu 8 Oct, 06:00-17:00.');
  assertEquals(w.sent[0].text.includes('Feeder'), false);
  assertStringIncludes(w.sent[1].text, '⚡ Scheduled power interruption Thu 15 Oct');
});

Deno.test('SPEC-41 3.5-6: a date outside every current post is never released (its post scrolled out of the feed)', async () => {
  const w = world({ ops_notices: [hand('2026-11-20')] });
  await w.run([]);
  for (let i = 0; i < 3; i++) assertEquals(await w.run([], at(i), MOVED()), []);
  assertEquals([live(w.db).length, (await readNotice(w.db, '2026-11-20'))!.missRuns], [2, undefined]);
});

Deno.test('SPEC-41 3.5-8: Keep it blocked brings the notice back as a staff notice; the next run adopts it and re-blocks; later runs never release it', async () => {
  const w = world({ ops_notices: [hand('2026-10-08')] });
  await w.run([]);
  await w.run([], '2026-10-02T01:15:00Z', sched([]));
  await w.run([], '2026-10-02T01:30:00Z', sched([]));
  assertEquals(live(w.db), []);
  const k = await keepNotice(w.db, PID, '2026-10-08');
  assertEquals(k.ok && k.already, false);
  const n = w.db.tables.ops_notices.find((r) => r.effective_date === '2026-10-08')!;
  assertEquals([n.is_active, n.source], [true, 'staff']);
  assertEquals(await readNotice(w.db, '2026-10-08'), null, 'the state is deleted');
  assertEquals(await w.run([], '2026-10-02T01:45:00Z'), ['2026-10-08: adopted']);
  assertEquals(live(w.db), ['2026-10-07', '2026-10-08'], 're-blocked');
  assertEquals((await readNotice(w.db, '2026-10-08'))!.source, 'staff');
  for (let i = 0; i < 3; i++) assertEquals(await w.run([], at(i), sched([])), []);
  assertEquals(live(w.db), ['2026-10-07', '2026-10-08'], 'later runs never release it');
  const again = await keepNotice(w.db, PID, '2026-10-08');
  assertEquals(again.ok && again.already, true, 'a second tap changes nothing');
  assertEquals((await keepNotice(w.db, PID, '2026-12-31')).ok, false, 'no notice on record for that date');
});

Deno.test('SPEC-41 3.5-9: a night another active notice still needs stays held after a release (the releasable() rule)', async () => {
  const w = world();
  await w.run([found('2026-10-14', '18:00:00', 2, 100), found('2026-10-15', '06:00:00', 11, 101)]);
  assertEquals(live(w.db), ['2026-10-14', '2026-10-15']);
  const s = sched(['2026-10-14']); // Oct 14 is still listed, Oct 15 is not
  await w.run([], '2026-10-02T01:15:00Z', s);
  assertEquals(await w.run([], '2026-10-02T01:30:00Z', s), ['2026-10-15: released (not on SOCOTECO schedule)']);
  assertEquals(live(w.db), ['2026-10-14'], 'night 14 is held for the 18:00 outage');
  assertStringIncludes(w.fin[0].text, 'The night of Oct 15 is open again');
  assertEquals((await readNotice(w.db, '2026-10-14'))!.status, 'active');
});

Deno.test('SPEC-41 3.5: a release that frees nothing says nothing (every night is needed by another active notice)', async () => {
  const w = world();
  await w.run([found('2026-10-14', '18:00:00', 2, 100), found('2026-10-15', '06:00:00', 11, 101)]); // night 14 is wanted by both
  const cards = [w.sent.length, w.fin.length];
  const s = sched(['2026-10-15']); // the 18:00 outage on Oct 14 is no longer listed
  await w.run([], '2026-10-02T01:15:00Z', s);
  assertEquals(await w.run([], '2026-10-02T01:30:00Z', s), ['2026-10-14: released (not on SOCOTECO schedule)']);
  assertEquals(live(w.db), ['2026-10-14', '2026-10-15'], 'night 14 stays for the Oct 15 outage');
  assertEquals([w.sent.length - cards[0], w.fin.length - cards[1]], [0, 0], 'nothing was freed, so no card');
  assertEquals((await readNotice(w.db, '2026-10-14'))!.status, 'released');
});

Deno.test('SPEC-41 3.5 (audit L5a): a moved poster (filename = moved-FROM date, read = moved-TO date) lists both dates; the moved-TO date stays held and the old date is freed by the cancel card, not by two misses', async () => {
  const old = P + 'SPI-PMS-10082026-LEON-LLIDO-SS.jpg';
  const sc = scheduleFrom([{ id: 22013, posters: [P + 'SPI-PMS-10102026-DAMALERIO-SS.jpg', old, P + 'SPI-PMS-10252026-TUPI-B-SS.jpg'] }], { [old]: '2026-10-15' }, () => true)!;
  assertEquals([...sc.listed].sort(), ['2026-10-08', '2026-10-15']);
  const w = world({ ops_notices: [hand('2026-10-08')] });
  await w.run([]); // adopts Oct 8 and blocks it
  const r = await w.run([found('2026-10-15', '06:00:00', 11, 22013, { url: old, originalDate: '2026-10-08' })]); // a real move: the read names Oct 15, moved from Oct 8
  assertStringIncludes(r.join('|'), '2026-10-08: moved to Thu 15 Oct');
  assertEquals(live(w.db), ['2026-10-07', '2026-10-08', '2026-10-14', '2026-10-15']);
  assert(!!(await readNotice(w.db, '2026-10-08'))!.cancelAskedAt, 'the cancel card was sent: staleNotices skips it from now on');
  for (let i = 0; i < 3; i++) assertEquals(await w.run([], at(i), sc), [], `run ${i + 1}`);
  assertEquals(live(w.db), ['2026-10-07', '2026-10-08', '2026-10-14', '2026-10-15'], 'nothing is released by the scrape; the Unblock tap frees Oct 8');
  assertEquals((await readNotice(w.db, '2026-10-15'))!.status, 'active');
  assertEquals((await releaseNotice(w.db, PID, '2026-10-08', 'unblock', 'test')).ok, true);
  assertEquals(live(w.db), ['2026-10-14', '2026-10-15'], 'the moved-TO date stays held');
});

Deno.test('SPEC-41 3.2 (audit L5a): miss, unknown, miss does not release - release needs two CONSECUTIVE clean misses', async () => {
  const w = world({ ops_notices: [hand('2026-10-08')] });
  await w.run([]);
  const s = sched(['2026-10-15']); // Oct 8 covered, not listed
  assertEquals(await w.run([], at(0), s), ['2026-10-08: not on the SOCOTECO schedule (clean scrape 1 of 2)']);
  assertEquals((await readNotice(w.db, '2026-10-08'))!.missRuns, 1);
  assertEquals(await w.run([], at(1), null), [], 'unknown run');
  assertEquals((await readNotice(w.db, '2026-10-08'))!.missRuns ?? 0, 0, 'the unknown run broke the streak');
  assertEquals(await w.run([], at(2), s), ['2026-10-08: not on the SOCOTECO schedule (clean scrape 1 of 2)'], 'counting starts over');
  assertEquals(live(w.db), ['2026-10-07', '2026-10-08']);
});

Deno.test('SPEC-41 3.5 (audit L5a): a date a current poster read names is never released, even when its filename says another date', async () => {
  const f = P + 'SPI-PMS-10082026-LEON-LLIDO-SS.jpg';
  const sc = scheduleFrom([{ id: 5, posters: [f, P + 'SPI-PMS-10252026-TUPI-B-SS.jpg'] }], { [f]: '2026-10-09' }, () => true)!;
  const w = world({ ops_notices: [hand('2026-10-09')] });
  await w.run([]);
  for (let i = 0; i < 3; i++) assertEquals(await w.run([], at(i), sc), [], `run ${i + 1}`);
  assertEquals((await readNotice(w.db, '2026-10-09'))!.status, 'active');
  assertEquals((await readNotice(w.db, '2026-10-09'))!.missRuns ?? 0, 0);
});

Deno.test('audit L5a: equal postId with a different poster URL (a corrected poster added to a post we hold) is newer, not ignored; the same poster again is still ignored', async () => {
  const w = world();
  await w.run([found('2026-10-15', '06:00:00', 11, 100)]);
  const fixed = P + 'SPI-PMS-10152026-LEON-LLIDO-SS_20261003_160149_0000.jpg';
  assertEquals(await w.run([found('2026-10-15', '08:00:00', 3, 100, { url: fixed })], '2026-10-02T02:00:00Z'), ['2026-10-15: changed']);
  assertEquals([w.db.tables.ops_notices[0].effective_time, w.db.tables.ops_notices[0].duration_hours], ['08:00:00', 3]);
  assertStringIncludes(w.sent[1].text, `SOCOTECO notice: ${fixed}`);
  assertEquals(await w.run([found('2026-10-15', '13:00:00', 4, 100, { url: fixed })], '2026-10-02T03:00:00Z'), ['2026-10-15: older poster ignored'], 'same post, same poster, other times: not newer');
});

Deno.test('audit L5a: a live notice state with no url is the same poster: equal postId is ignored, a newer post still changes it', async () => {
  const w = world();
  await w.run([found('2026-10-15', '06:00:00', 11, 100)]);
  await patchNoticeState(w.db, '2026-10-15', { url: undefined });
  assertEquals((await readNotice(w.db, '2026-10-15'))!.url ?? '', '', 'the state has no url');
  assertEquals(await w.run([found('2026-10-15', '08:00:00', 3, 100, { url: P + 'SPI-OTHER.jpg' })], '2026-10-02T02:00:00Z'), ['2026-10-15: older poster ignored']);
  assertEquals(await w.run([found('2026-10-15', '08:00:00', 3, 101, { url: P + 'SPI-OTHER.jpg' })], '2026-10-02T03:00:00Z'), ['2026-10-15: changed']);
});

Deno.test('round 6: only a notice power-watch inserted is auto-released; a dashboard row (no source), a staff photo marked socoteco, and a staff-typed row are asked once after two misses (one Unblock card), never released', async () => {
  const typed = { posted_by_name: 'Test Staff @test_staff' };
  const sc = sched([]); // nothing listed, every date covered
  for (const [name, row] of [['dashboard row, no source', hand('2026-10-08', { source: null, posted_by_name: 'Admin dashboard' })],
    ['staff photo marked socoteco', hand('2026-10-08', { ...typed })],
    ['a second row on the date typed by staff beside the power-watch one', null]] as const) {
    const w = world({ ops_notices: row ? [row] : [hand('2026-10-08'), hand('2026-10-08', { id: 'n-b', ...typed })] });
    await w.run([]);
    const cards = w.sent.length;
    assertEquals(await w.run([], at(0), sc), ['2026-10-08: not on the SOCOTECO schedule (clean scrape 1 of 2)'], `${name} run 1`);
    assertEquals(await w.run([], at(1), sc), ['2026-10-08: no longer lists'], `${name} run 2: one ask`);
    assertEquals(w.sent.length - cards, 1, `${name}: one card`);
    const card = w.sent[w.sent.length - 1];
    assertStringIncludes(card.text, 'no longer lists the power interruption on Thu 8 Oct');
    assertEquals(card.markup?.inline_keyboard[0][0].callback_data, 'pw:unblock:2026-10-08', 'the Unblock tap');
    assertEquals(await w.run([], at(2), sc), [], `${name} run 3: no second card`);
    assertEquals(w.sent.length - cards, 1, `${name}: still one card`);
    assertEquals(live(w.db), ['2026-10-07', '2026-10-08'], `${name}: nothing released`);
    const s = (await readNotice(w.db, '2026-10-08'))!;
    assertEquals([s.status, !!s.cancelAskedAt], ['active', true], name);
  }
  // the power-watch-inserted row is released after two clean misses
  const w = world({ ops_notices: [hand('2026-10-08')] });
  await w.run([]);
  assertEquals(await w.run([], at(0), sc), ['2026-10-08: not on the SOCOTECO schedule (clean scrape 1 of 2)']);
  assertEquals(await w.run([], at(1), sc), ['2026-10-08: released (not on SOCOTECO schedule)']);
  assertEquals(live(w.db), []);
});

Deno.test('round 6 (K): an unsent cancel card is a pending ask, never an auto-release', async () => {
  const w = world({ ops_notices: [hand('2026-10-08')] });
  await w.run([]);
  await patchNoticeState(w.db, '2026-10-08', { card: { kind: 'cancel', note: 'cancelled' }, missRuns: 1 });
  w.telegram(false); // the card cannot go out: it stays queued
  const r = await w.run([], at(0), sched([]));
  assertEquals(r.some((x) => x.includes('released')), false, r.join('|'));
  assertEquals(live(w.db), ['2026-10-07', '2026-10-08']);
});

Deno.test('round 6: an old cancelled or moved poster read again does not ask to unblock a date a newer poster set', async () => {
  const w = world();
  await w.run([found('2026-10-15', '06:00:00', 11, 200)]);
  assertEquals(await w.run([found('2026-10-15', '06:00:00', 11, 100, { status: 'cancelled' })], '2026-10-02T02:00:00Z'), [], 'older cancelled poster: nothing');
  assertEquals((await readNotice(w.db, '2026-10-15'))!.card, null);
  assertEquals(live(w.db), ['2026-10-14', '2026-10-15']);
  const r = await w.run([found('2026-10-20', '06:00:00', 11, 100, { originalDate: '2026-10-15' })], '2026-10-02T03:00:00Z');
  assertEquals(r.some((x) => x.includes('2026-10-15: moved')), false, 'an older moved poster does not ask for Oct 15');
  assertEquals(await w.run([found('2026-10-15', '06:00:00', 11, 300, { status: 'cancelled' })], '2026-10-02T04:00:00Z'), ['2026-10-15: cancelled'], 'a newer cancelled poster still asks');
});
