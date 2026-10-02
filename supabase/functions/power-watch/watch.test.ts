// deno test supabase/functions/power-watch/watch.test.ts - whole runs against an in-memory database. Synthetic data only.
import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { listNotices, patchNoticeState, readNotice, releaseNotice } from '../_shared/cascade-core/brownout.ts';
import { FakeDb } from './fake-db.ts';
import type { Built } from './plan.ts';
import { pruneStates, reconcile, type Found } from './watch.ts';

const PID = 'prop-1', URL0 = 'https://www.socoteco2.com/wp-content/uploads/2026/10/SPI-TEST.jpg';
const found = (date: string, time: string | null, hours: number | null, postId: number, extra: Partial<Found> = {}): Found => ({
  date, time, hours, title: 'SOCOTECO II scheduled interruption - TEST SUBSTATION (ours is 14-3)', purpose: 'Maintenance', poster: 'SPI-TEST.jpg', url: URL0,
  status: 'active', originalDate: null, postId, ...extra,
});
function world(tables: Record<string, Record<string, unknown>[]> = {}, posters: string[] = []) {
  const db = new FakeDb({ calendar_events: [], ops_notices: [], app_settings: [], ...tables });
  const sent: Built[] = [], mails: string[] = [], logs: string[] = [];
  let up = true;
  const run = (f: Found[], nowIso = '2026-10-02T01:00:00Z') => reconcile({
    db, propertyId: PID, today: '2026-10-02', now: new Date(nowIso),
    send: async (c) => { if (up) sent.push(c); return up; }, mail: async (s) => { mails.push(s); return true; }, log: (e) => logs.push(e), posters,
  }, f);
  return { db, sent, mails, run, telegram: (ok: boolean) => { up = ok; } };
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
  assertEquals(await done.run([], '2026-10-02T05:00:00Z'), []);
  assertEquals(done.sent.length, 1);
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
