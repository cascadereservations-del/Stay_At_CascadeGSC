// deno test supabase/functions/power-watch/plan.test.ts - synthetic guests only (this repo is public).
import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { lintReply, toneRules } from '../messenger-concierge/voice.ts';
import { templateOf } from '../_shared/cascade-core/format.ts';
import type { NoticeState } from '../_shared/cascade-core/brownout.ts';
import {
  airbnbCovers, cancelCard, changedCard, classifyNights, extraGuestCards, guestDraft, newCard, nightsLine, posterDate, releasedCard, reminderCard, reminderDue,
  scheduleFrom, seenCard, seenDue, seriesKey, staleNotices, touchedNights, windowLabel, type Row,
} from './plan.ts';

Deno.test('D-290 night math: block every night the outage touches (night N = check in N, out N+1; 12:00 out, 14:00 in)', () => {
  assertEquals(touchedNights('2026-10-15', '06:00:00', 11), ['2026-10-14', '2026-10-15'], 'the real Oct 15 one: 06:00-17:00');
  assertEquals(touchedNights('2026-10-15', '18:00:00', 2), ['2026-10-15'], '18:00-20:00 is evening only');
  assertEquals(touchedNights('2026-10-15', '08:00:00', 3), ['2026-10-14'], '08:00-11:00 ends before 12:00 checkout');
  assertEquals(touchedNights('2026-10-15', '13:00:00', 2), ['2026-10-15'], '13:00-15:00 starts after checkout, runs past 14:00 check-in');
  assertEquals(touchedNights('2026-10-15', '12:00:00', 2), [], '12:00-14:00 sits between checkout and check-in');
  assertEquals(touchedNights('2026-10-15', '11:00:00', 2), ['2026-10-14'], '11:00-13:00 starts before checkout');
  assertEquals(touchedNights('2026-10-15', '13:00:00', 1), [], '13:00-14:00 ends as check-in opens');
  assertEquals(touchedNights('2026-10-15', '13:00:00', 1.5), ['2026-10-15'], '13:00-14:30 runs past 14:00');
});
Deno.test('night math: month ends, overnight outages and posters with no times', () => {
  assertEquals(touchedNights('2026-11-01', '06:00:00', 11), ['2026-10-31', '2026-11-01']);
  assertEquals(touchedNights('2026-10-15', '22:00:00', 8), ['2026-10-15'], '22:00 to 06:00 next day is night 15 only');
  assertEquals(touchedNights('2026-10-15', null, null), ['2026-10-14', '2026-10-15'], 'unknown times: the safe side');
  assertEquals(touchedNights('2026-10-15', '06:00:00', null), ['2026-10-14', '2026-10-15'], 'unknown length runs to midnight');
  assertEquals(touchedNights('2026-10-15', '10:00:00', 30), ['2026-10-14', '2026-10-15', '2026-10-16'], 'a 30-hour outage');
});

const T = '2026-10-02';
const direct = (night: string, name: string, status = 'blocked'): Row => ({ uid: `direct:${name}`, source: 'direct', status, checkin_date: night, checkout_date: addOne(night), guest_name: name });
const addOne = (d: string) => new Date(Date.parse(`${d}T00:00:00Z`) + 86_400_000).toISOString().slice(0, 10);
const airbnbBlock = (a: string, b: string): Row => ({ uid: `ab-${a}`, source: 'airbnb', status: 'blocked', checkin_date: a, checkout_date: b });
const ours = (night: string): Row => ({ uid: `brownout:${night}`, source: 'manual', status: 'blocked', checkin_date: night, checkout_date: addOne(night) });

Deno.test('classify: free night is blocked; an Airbnb block is said, not re-blocked; a guest is never blocked; ours is held', () => {
  const nights = ['2026-10-14', '2026-10-15'];
  assertEquals(classifyNights(nights, [], T), { toBlock: nights, held: [], already: [], guests: [] });
  assertEquals(classifyNights(nights, [airbnbBlock('2026-10-14', '2026-10-15')], T), { toBlock: ['2026-10-15'], held: [], already: ['2026-10-14'], guests: [] });
  assertEquals(classifyNights(nights, [airbnbBlock('2026-10-14', '2026-10-16')], T).already, nights, 'one Airbnb block over both nights');
  const g = classifyNights(nights, [direct('2026-10-14', 'Test Guest', 'confirmed')], T);
  assertEquals([g.toBlock, g.guests], [['2026-10-15'], [{ night: '2026-10-14', name: 'Test Guest' }]]);
  assertEquals(classifyNights(nights, [direct('2026-10-14', 'Pending Guest')], T).guests.length, 1, 'a pending direct hold is a guest too');
  assertEquals(classifyNights(nights, [{ ...airbnbBlock('2026-10-14', '2026-10-15'), status: 'confirmed', guest_name: null }], T).guests, [{ night: '2026-10-14', name: '' }]);
  assertEquals(classifyNights(nights, [ours('2026-10-14')], T).held, ['2026-10-14']);
  assertEquals(classifyNights(nights, [{ ...direct('2026-10-14', 'Gone'), status: 'cancelled' }], T).toBlock, nights, 'a cancelled stay is not a guest');
  assertEquals(classifyNights(['2026-10-01', '2026-10-02'], [], T).toBlock, ['2026-10-02'], 'last night is past');
});

const st = (o: Partial<NoticeState> = {}): NoticeState => ({
  date: '2026-10-15', noticeId: 'n1', time: '06:00:00', hours: 11, postId: 5, poster: 'SPI-TEST.jpg', status: 'active',
  nights: ['2026-10-14', '2026-10-15'], blocked: ['2026-10-14', '2026-10-15'], already: [], guests: [], card: { kind: 'new' }, ...o,
});

Deno.test('card: the new-outage card leads with what happened and who acts, and carries Done / Undo', () => {
  const c = newCard(st());
  assertEquals(c.text, [
    '🟡 ATTENTION · brownout Thu 15 Oct', '',
    '⚡ SOCOTECO power interruption Thu 15 Oct, 06:00-17:00 (Feeder 14-3).', '',
    'Blocked on our booking site: nights of Oct 14 and Oct 15.', '',
    'Marifel: block the same nights in Airbnb now.',
  ].join('\n'));
  assertEquals(c.markup?.inline_keyboard, [[{ text: '✅ Blocked in Airbnb', callback_data: 'pw:done:2026-10-15' }, { text: '↩ Undo block', callback_data: 'pw:undo:2026-10-15' }]]);
  assert(!/!/.test(c.text));
});
Deno.test('card: a night already blocked in Airbnb is said instead of blocked; nothing to block means no buttons', () => {
  const c = newCard(st({ blocked: ['2026-10-15'], already: ['2026-10-14'] }));
  assertStringIncludes(c.text, 'Blocked on our booking site: night of Oct 15.');
  assertStringIncludes(c.text, 'Already blocked, so nothing was added: night of Oct 14.');
  assertStringIncludes(c.text, 'Marifel: block the same night in Airbnb now.');
  const none = newCard(st({ blocked: [], already: ['2026-10-14', '2026-10-15'] }));
  assertEquals(none.markup, undefined);
  assert(!/Marifel: block/.test(none.text));
});
Deno.test('card: a guest in the house is not blocked; prep, the 📨 draft and the Show as text / Revise row follow', () => {
  const c = newCard(st({ blocked: ['2026-10-15'], guests: [{ night: '2026-10-14', name: 'Test Guest' }] }));
  assertStringIncludes(c.text, 'Not blocked, a guest is in the house: night of Oct 14.');
  assertStringIncludes(c.text, 'Test Guest is staying the night of Oct 14.');
  assertStringIncludes(c.text, 'Prep: EcoFlow at 100% the day before, emergency light on top of the fridge.');
  assertStringIncludes(c.text, 'Do: send Test Guest this (Show as text to long-press it, or Revise with Cassy):');
  const draft = templateOf(c.text);
  assert(draft.startsWith('Hi Test, a quick heads-up: Socoteco has scheduled a power interruption on Thu 15 Oct, 6:00 AM to 5:00 PM.'), draft);
  assertEquals(c.markup?.inline_keyboard.map((r) => r[0].callback_data), ['tpl:copy', 'pw:done:2026-10-15']);
  // a guest only: no Airbnb job, so no Done / Undo
  const only = newCard(st({ blocked: [], guests: [{ night: '2026-10-14', name: 'Test Guest' }, { night: '2026-10-15', name: 'Test Guest' }] }));
  assertStringIncludes(only.text, 'Test Guest is staying the nights of Oct 14 and Oct 15.');
  assertEquals(only.markup?.inline_keyboard.map((r) => r[0].callback_data), ['tpl:copy']);
});
Deno.test('card: two guests, the second gets a card of their own with their own draft', () => {
  const s = st({ blocked: [], guests: [{ night: '2026-10-14', name: 'Ana Test' }, { night: '2026-10-15', name: 'Ben Test' }] });
  assertStringIncludes(newCard(s).text, 'Ana Test is staying');
  const extra = extraGuestCards(s);
  assertEquals(extra.length, 1);
  assertStringIncludes(extra[0].text, 'Ben Test is staying the night of Oct 15.');
  assert(templateOf(extra[0].text).startsWith('Hi Ben,'));
});

Deno.test('the guest draft passes the Cassy voice rules (calm, guide never command, no exclamation words, one short paragraph)', () => {
  for (const [name, changed] of [['Test Guest', false], ['', false], ['Ana Test', true]] as const) {
    for (const [time, hours] of [['06:00:00', 11], ['13:00:00', 2], [null, null]] as const) {
      const d = guestDraft(name, '2026-10-15', time, hours, changed);
      assertEquals(lintReply(d), [], d);
      assertEquals(toneRules(d), [], d);
      assert(!d.includes('\n'), 'one paragraph: the card keeps the 📨 text up to the first blank line');
      assert(d.length <= 320, `${d.length} chars`);
      assertStringIncludes(d, 'Wi-Fi router has backup power');
      assertStringIncludes(d, 'near the TV unit');
      assertStringIncludes(d, 'on top of the fridge');
    }
  }
  assertStringIncludes(guestDraft('Ana Test', '2026-10-15', '08:00:00', 3, true), 'has moved the power interruption to Thu 15 Oct, 8:00 AM to 11:00 AM.');
});

Deno.test('card: changed - what was, what is, what Marifel adds or removes', () => {
  const prev = { time: '06:00:00', hours: 11, blocked: ['2026-10-14', '2026-10-15'] };
  const c = changedCard(st({ time: '08:00:00', hours: 3, blocked: ['2026-10-14'], nights: ['2026-10-14'], card: { kind: 'changed', prev } }));
  assertStringIncludes(c.text, 'SOCOTECO changed the power interruption on Thu 15 Oct (Feeder 14-3).');
  assertStringIncludes(c.text, 'Now 08:00-11:00, was 06:00-17:00.');
  assertStringIncludes(c.text, 'Released on our booking site: night of Oct 15.');
  assertStringIncludes(c.text, 'Marifel: unblock night of Oct 15 in Airbnb if you blocked it.');
  assertEquals(c.markup, undefined, 'nothing new to block, so no Done button');
  const more = changedCard(st({ card: { kind: 'changed', prev: { time: '13:00:00', hours: 2, blocked: ['2026-10-15'] } } }));
  assertStringIncludes(more.text, 'Now blocked on our booking site: night of Oct 14.');
  assertStringIncludes(more.text, 'Marifel: block night of Oct 14 in Airbnb now.');
  assertEquals(more.markup?.inline_keyboard[0][0].callback_data, 'pw:done:2026-10-15');
});
Deno.test('card: cancelled or moved asks before anything is released, with the Unblock button', () => {
  const c = cancelCard(st({ card: { kind: 'cancel', note: 'cancelled' } }));
  assertStringIncludes(c.text, 'SOCOTECO cancelled the power interruption on Thu 15 Oct');
  assertStringIncludes(c.text, 'Unblock nights of Oct 14 and Oct 15 on our booking site and in Airbnb?');
  assertEquals(c.markup?.inline_keyboard, [[{ text: '🔓 Unblock', callback_data: 'pw:unblock:2026-10-15' }]]);
  assertStringIncludes(cancelCard(st({ card: { kind: 'cancel', note: 'moved to Thu 22 Oct' } })).text, 'SOCOTECO moved to Thu 22 Oct the power interruption');
  assertStringIncludes(cancelCard(st({ blocked: [], card: { kind: 'cancel', note: 'cancelled' } })).text, 'Nothing was blocked');
});

Deno.test('follow-ups: Airbnb seen once; one reminder after three hours; neither after Done, Undo, a cancel question or a card still waiting', () => {
  const sent = st({ card: null, cardAt: '2026-10-02T01:00:00Z' });
  const rows: Row[] = [ours('2026-10-14'), ours('2026-10-15')];
  const at = (h: number) => new Date(Date.parse('2026-10-02T01:00:00Z') + h * 3_600_000);
  assertEquals(reminderDue(sent, rows, at(2.9), T), false);
  assertEquals(reminderDue(sent, rows, at(3), T), true);
  assertEquals(reminderDue({ ...sent, remindedAt: 'x' }, rows, at(5), T), false, 'only one');
  assertEquals(reminderDue({ ...sent, doneAt: 'x' }, rows, at(5), T), false, 'Done tapped');
  assertEquals(reminderDue({ ...sent, status: 'undone' }, rows, at(5), T), false);
  assertEquals(reminderDue({ ...sent, cancelAskedAt: 'x' }, rows, at(5), T), false);
  assertEquals(reminderDue({ ...sent, card: { kind: 'new' } }, rows, at(5), T), false);
  assertEquals(reminderDue({ ...sent, blocked: [] }, rows, at(5), T), false, 'nothing for Marifel to block');
  assertEquals(seenDue(sent, rows), false);
  const covered = [...rows, airbnbBlock('2026-10-14', '2026-10-16')];
  assertEquals(airbnbCovers(sent.blocked, covered), true, 'one Airbnb block over both nights');
  assertEquals(seenDue(sent, covered), true);
  assertEquals(seenDue({ ...sent, seenAt: 'x' }, covered), false, 'once');
  assertEquals(reminderDue(sent, covered, at(5), T), false, 'covered: no reminder');
  assertEquals(airbnbCovers(sent.blocked, [...rows, airbnbBlock('2026-10-14', '2026-10-15')]), false, 'only one night so far');
  assertEquals(airbnbCovers(sent.blocked, [...rows, { ...airbnbBlock('2026-10-14', '2026-10-16'), status: 'cancelled' }]), false, 'a cancelled Airbnb row is not a block');
  assertStringIncludes(seenCard(sent).text, '✅ Airbnb block seen for nights of Oct 14 and Oct 15');
  assertStringIncludes(reminderCard(sent).text, 'Reminder: Airbnb is not blocked yet');
  assertEquals(reminderCard(sent).markup?.inline_keyboard[0][0].callback_data, 'pw:done:2026-10-15');
});

Deno.test('wording helpers', () => {
  assertEquals(windowLabel('2026-10-15', '06:00:00', 11), 'Thu 15 Oct, 06:00-17:00');
  assertEquals(windowLabel('2026-10-15', null, null), 'Thu 15 Oct (times not shown on the poster)');
  assertEquals(windowLabel('2026-10-15', '06:00:00', null), 'Thu 15 Oct, 06:00 onward');
  assertStringIncludes(nightsLine(st({ already: ['2026-10-13'] })), 'Marifel blocks the same nights in Airbnb by hand.');
});

// ---- SPEC-41 Part 3 ----------------------------------------------------------------------------------------------------------
const PU = 'https://www.socoteco2.com/wp-content/uploads/2026/10/';

Deno.test('SPEC-41 3.5-7: posterDate reads the filename date, never the upload suffix; seriesKey drops the date and the suffix; feeder posters have no series', () => {
  assertEquals(posterDate(PU + 'SPI-10092026-BATULAKI-GLAN-2_20261003_160149_0002.jpg'), '2026-10-09', 'not 2026-10-03');
  assertEquals(posterDate(PU + 'SPI-09252026-F13-3.jpg'), '2026-09-25');
  assertEquals(posterDate(PU + 'SPI-PMS-10152026-LEON-LLIDO-SS.jpg'), '2026-10-15');
  assertEquals(posterDate(PU + 'logo.png'), null);
  assertEquals(seriesKey(PU + 'SPI-PMS-10152026-LEON-LLIDO-SS.jpg'), 'SPI-PMS--LEON-LLIDO-SS');
  assertEquals(seriesKey(PU + 'SPI-PMS-10082026-LEON-LLIDO-SS_20261003_160149_0000.jpg'), 'SPI-PMS--LEON-LLIDO-SS');
  assertEquals(seriesKey(PU + 'SPI-09252026-F13-3.jpg'), null);
  assertEquals(seriesKey(PU + 'SPI-09252026-PORTION-OF-F14-3.jpg'), null);
});

Deno.test('SPEC-41 3.2: feeder posters are never superseded (one can repeat on two dates in two posts); a read-class poster lists the date the OCR found', () => {
  const sc = scheduleFrom([
    { id: 2, posters: [PU + 'SPI-10122026-PORTION-OF-F14-3.jpg', PU + 'SPI-10042026-BATULAKI-GLAN.jpg'] },
    { id: 1, posters: [PU + 'SPI-10052026-PORTION-OF-F14-3.jpg'] },
  ], { [PU + 'SPI-10042026-BATULAKI-GLAN.jpg']: '2026-10-06' }, () => true)!;
  assertEquals([...sc.listed].sort(), ['2026-10-05', '2026-10-06', '2026-10-12']);
  const unread = scheduleFrom([{ id: 2, posters: [PU + 'SPI-10042026-BATULAKI-GLAN.jpg'] }], {}, () => true)!;
  assertEquals(unread.listed.size, 0, 'a read-class poster that was not found to be ours lists nothing');
});

Deno.test('SPEC-41 3.2 (audit L5a): a hit poster lists BOTH the date its read names and its filename date; with no read it lists the filename', () => {
  const old = PU + 'SPI-PMS-10082026-LEON-LLIDO-SS.jpg', far = PU + 'SPI-PMS-10252026-TUPI-B-SS.jpg';
  const moved = scheduleFrom([{ id: 9, posters: [old, far] }], { [old]: '2026-10-15' }, () => true)!;
  assertEquals([...moved.listed].sort(), ['2026-10-08', '2026-10-15'], 'moved-TO and moved-FROM both listed: one paid read never frees a night; the cancel card frees the old date');
  assertEquals([moved.covered('2026-10-08'), moved.covered('2026-10-15')], [true, true], 'the old date is judged, not skipped');
  assertEquals([...scheduleFrom([{ id: 9, posters: [old] }], {}, () => true)!.listed], ['2026-10-08'], 'no read recorded: filename date (decided before ours existed)');
  const same = scheduleFrom([{ id: 9, posters: [old] }], { [old]: '2026-10-08' }, () => true)!;
  assertEquals([...same.listed], ['2026-10-08'], 'a read that confirms the filename lists it');
  const cross = scheduleFrom([{ id: 9, posters: [PU + 'SPI-10082026-PORTION-OF-F14-3.jpg'] }, { id: 8, posters: [PU + 'SPI-10092026-PORTION-OF-F14-3.jpg'] }], { [PU + 'SPI-10082026-PORTION-OF-F14-3.jpg']: '2026-10-09' }, () => true)!;
  assertEquals([...cross.listed].sort(), ['2026-10-08', '2026-10-09'], 'a mismatching read lists its own date and the filename date');
});

Deno.test('SPEC-41 3.2: staleNotices - miss, release, ask, hit; unknown, a source that is not checked, a past date and a pending question are skipped', () => {
  const sc = { listed: new Set(['2026-10-15']), covered: (d: string) => d >= '2026-10-03' && d <= '2026-10-25' };
  const s = (o: Partial<NoticeState>) => st({ date: '2026-10-08', blocked: ['2026-10-07', '2026-10-08'], nights: ['2026-10-07', '2026-10-08'], ...o });
  const runU = (states: NoticeState[], sched: typeof sc | null = sc, rows: Row[] = []) => staleNotices(states, sched, rows, T);
  const run = (states: NoticeState[], sched: typeof sc | null = sc, rows: Row[] = []) => { const { unknown: _u, ...r } = runU(states, sched, rows); return r; };
  assertEquals(run([s({})]), { miss: ['2026-10-08'], hit: [], release: [], ask: [] });
  assertEquals(run([s({ missRuns: 1 })]), { miss: [], hit: [], release: ['2026-10-08'], ask: [] });
  assertEquals(run([s({ date: '2026-10-15', missRuns: 1 })]), { miss: [], hit: ['2026-10-15'], release: [], ask: [] });
  assertEquals(run([s({ missRuns: 1 })], null), { miss: [], hit: [], release: [], ask: [] }, 'unknown');
  assertEquals(run([s({ missRuns: 1, source: 'ngcp' }), s({ missRuns: 1, source: 'staff' })]), { miss: [], hit: [], release: [], ask: [] });
  assertEquals(run([s({ missRuns: 1, source: 'socoteco' })]).release, ['2026-10-08']);
  assertEquals(run([s({ date: '2026-11-20', missRuns: 1 })]), { miss: [], hit: [], release: [], ask: [] }, 'outside every post');
  assertEquals(run([s({ missRuns: 1, status: 'released' }), s({ missRuns: 1, blocked: [] }), s({ missRuns: 1, cancelAskedAt: 'x' })]), { miss: [], hit: [], release: [], ask: [] });
  assertEquals(run([s({ date: '2026-10-01', missRuns: 1 })]).release, [], 'a date already past');
  const guest: Row = { uid: 'ab', source: 'airbnb', status: 'confirmed', checkin_date: '2026-10-06', checkout_date: '2026-10-08', guest_name: 'Test Guest' };
  assertEquals(run([s({ missRuns: 1 })], sc, [guest]), { miss: [], hit: [], release: [], ask: ['2026-10-08'] }, 'a guest on a held night: ask, never release');
  // audit L5a: an unknown run (no schedule, or the date outside every span) is reported so watch.ts resets missRuns: miss, unknown, miss never releases.
  assertEquals(runU([s({ missRuns: 1 })], null).unknown, ['2026-10-08'], 'no schedule');
  assertEquals(runU([s({ date: '2026-11-20', missRuns: 1 })]).unknown, ['2026-11-20'], 'outside every span');
  assertEquals(runU([s({ missRuns: 1, source: 'ngcp' })], null).unknown, [], 'a source that is not checked is not tracked');
});

Deno.test('SPEC-41: an NGCP or staff notice is worded as what it is, with no feeder; the draft for a guest names the right provider and passes the voice rules', () => {
  const n = newCard(st({ source: 'ngcp' }));
  assertStringIncludes(n.text, '⚡ NGCP power interruption Thu 15 Oct, 06:00-17:00.');
  assertEquals(/Feeder|SOCOTECO/.test(n.text), false, n.text);
  assertStringIncludes(newCard(st({ source: 'staff' })).text, '⚡ Scheduled power interruption Thu 15 Oct');
  assertStringIncludes(newCard(st({ source: 'socoteco' })).text, '⚡ SOCOTECO power interruption Thu 15 Oct, 06:00-17:00 (Feeder 14-3).');
  assertStringIncludes(newCard(st({ url: 'https://example.com/p.jpg' })).text, 'SOCOTECO notice: https://example.com/p.jpg');
  assertStringIncludes(cancelCard(st({ source: 'ngcp', card: { kind: 'cancel', note: 'cancelled' } })).text, '⚡ NGCP cancelled the power interruption on Thu 15 Oct.');
  assertStringIncludes(changedCard(st({ source: 'ngcp', card: { kind: 'changed' } })).text, '⚡ NGCP changed the power interruption on Thu 15 Oct.');
  assertStringIncludes(reminderCard(st({ source: 'ngcp' })).text, 'for the NGCP interruption');
  assertStringIncludes(seenCard(st({ source: 'staff' })).text, '(Scheduled interruption Thu 15 Oct)');
  const g = newCard(st({ source: 'ngcp', blocked: [], guests: [{ night: '2026-10-14', name: 'Test Guest' }] }));
  assert(templateOf(g.text).startsWith('Hi Test, a quick heads-up: NGCP has scheduled a power interruption on'), templateOf(g.text));
  for (const by of ['Socoteco', 'NGCP', 'The power company']) {
    const d = guestDraft('Test Guest', '2026-10-15', '06:00:00', 11, false, by);
    assertEquals(lintReply(d), [], d); assertEquals(toneRules(d), [], d); assert(d.length <= 320, `${d.length}`);
  }
});

Deno.test('SPEC-41 3.4: the release card leads with the nights that are open again, tells Marifel what to do, and has one button', () => {
  const c = releasedCard(st({ date: '2026-10-08' }), ['2026-10-07', '2026-10-08']);
  assertEquals(c.text, [
    '🟡 ATTENTION · brownout Thu 8 Oct', '',
    '✅ The nights of Oct 7 and Oct 8 are open again on our booking site. SOCOTECO no longer lists the Thu 8 Oct power interruption for Feeder 14-3 on its current schedule.', '',
    'Marifel: if Airbnb is still blocked for those nights, unblock them there.', '',
    'If SOCOTECO told you directly that it is still on, tap Keep it blocked.',
  ].join('\n'));
  assertEquals(c.markup?.inline_keyboard, [[{ text: '🔒 Keep it blocked', callback_data: 'pw:keep:2026-10-08' }]]);
  assert(!/!/.test(c.text));
  assertStringIncludes(releasedCard(st({ date: '2026-10-08' }), ['2026-10-07']).text, 'The night of Oct 7 is open again');
  assertStringIncludes(releasedCard(st({ date: '2026-10-08' }), ['2026-10-07']).text, 'unblock it there.');
});

Deno.test('audit L5a: the next month PMS post does not supersede an October poster whose date is still ahead; a re-post within 14 days still does; a passed date is superseded', () => {
  const oct = PU + 'SPI-PMS-10152026-LEON-LLIDO-SS.jpg', nov = PU + 'SPI-PMS-11122026-LEON-LLIDO-SS.jpg', repost = PU + 'SPI-PMS-10222026-LEON-LLIDO-SS.jpg';
  const T = '2026-10-05';
  const far = scheduleFrom([{ id: 30, posters: [nov] }, { id: 20, posters: [oct] }], {}, () => true, T)!;
  assertEquals([...far.listed].sort(), ['2026-10-15'].concat(['2026-11-12']).sort(), 'Oct 15 is still ahead and stays listed beside the Nov poster');
  assertEquals(far.covered('2026-10-15'), true);
  const near = scheduleFrom([{ id: 30, posters: [repost] }, { id: 20, posters: [oct] }], {}, () => true, T)!;
  assertEquals([...near.listed], ['2026-10-22'], 'seven days apart: the newer post owns the series');
  const past = scheduleFrom([{ id: 30, posters: [nov] }, { id: 20, posters: [oct] }], {}, () => true, '2026-10-20')!;
  assertEquals([...past.listed], ['2026-11-12'], 'the October date has passed: superseded');
});
