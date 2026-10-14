// deno test --no-check --allow-env rain-alert/rainpush.test.ts
// Lane XS2: the staff push for rain. Frozen clock: NOW is 2026-10-14 11:07 Manila (03:07Z). No network.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { type BrownoutRow, type HourProb, hoursFromGoogle, pickBrownout, pickWindow, runRainPush, type RainPushDeps } from './rainpush.ts';

const NOW = Date.UTC(2026, 9, 14, 3, 7, 0);
const B1 = '3f2a9c1e-7b6d-4e0a-8c55-0d1e2f3a4b5c';
const dry: HourProb[] = [11, 12, 13, 14, 15].map((hour) => ({ hour, prob: 20 }));
const wet = (from: number, p = 80): HourProb[] => [11, 12, 13, 14, 15, 16].map((hour) => ({ hour, prob: hour >= from ? p : 20 }));

function deps(o: Partial<RainPushDeps> & { hrs?: HourProb[] | null; brown?: BrownoutRow[] } = {}) {
  const sent: Array<Record<string, unknown>> = [], marks: string[] = [];
  const d: RainPushDeps = {
    nowMs: () => NOW, manilaDate: '2026-10-14', manilaHour: 11,
    hours: async () => (o.hrs === undefined ? wet(14) : o.hrs),
    brownouts: async () => o.brown ?? [],
    lastPushAt: async () => null,
    send: async (b) => { sent.push(b); return { ok: true, sent: 2 }; },
    markPushed: async (iso) => { marks.push(iso); },
    log: () => {}, ...o,
  };
  return { d, sent, marks };
}

Deno.test('Google hours are read for today only', () => {
  const dt = (day: number, hours: number, p: number) => ({ displayDateTime: { year: 2026, month: 10, day, hours }, precipitation: { probability: { percent: p } } });
  assertEquals(hoursFromGoogle({ forecastHours: [dt(14, 11, 30), dt(14, 12, 65), dt(15, 1, 90), {}] }, '2026-10-14'), [{ hour: 11, prob: 30 }, { hour: 12, prob: 65 }]);
  assertEquals(hoursFromGoogle(null, '2026-10-14'), []);
});

Deno.test('the window: 60% or more, from the first wet hour, inside the next 3 hours, peak of the wet hours', () => {
  assertEquals(pickWindow(wet(14, 80), 11), { startHour: 14, peakPct: 80 });
  assertEquals(pickWindow([{ hour: 11, prob: 59 }, { hour: 12, prob: 60 }, { hour: 13, prob: 75 }], 11), { startHour: 12, peakPct: 75 });
  assertEquals(pickWindow(dry, 11), null);
  assertEquals(pickWindow([{ hour: 11, prob: 59 }], 11), null); // just below the threshold
  assertEquals(pickWindow(wet(15, 90), 11), null); // 15:00 is 3 h 53 min away: outside
  assertEquals(pickWindow([{ hour: 10, prob: 90 }], 11), null); // already past
});

Deno.test('a brownout is picked only when its hours overlap now to now + 3 h', () => {
  const r = (o: Partial<BrownoutRow>): BrownoutRow => ({ id: B1, effective_date: '2026-10-14', effective_time: '13:00:00', duration_hours: 3, ...o });
  assertEquals(pickBrownout([r({})], NOW), B1); // 13:00 to 16:00 starts inside the window
  assertEquals(pickBrownout([r({ effective_time: '09:00:00', duration_hours: 3 })], NOW), B1); // 09:00 to 12:00 is on now
  assertEquals(pickBrownout([r({ effective_time: '06:00:00', duration_hours: 3 })], NOW), null); // ended at 09:00
  assertEquals(pickBrownout([r({ effective_time: '15:00:00' })], NOW), null); // starts 3 h 53 min away
  assertEquals(pickBrownout([r({ effective_time: null, duration_hours: null })], NOW), B1); // all day
  assertEquals(pickBrownout([r({ effective_date: '2026-10-13', effective_time: '22:00:00', duration_hours: 14 })], NOW), B1); // overnight into today (ends 12:00)
  assertEquals(pickBrownout([r({ effective_date: '2026-10-13', effective_time: '22:00:00', duration_hours: 4 })], NOW), null);
  assertEquals(pickBrownout([r({ effective_time: '09:00:00', duration_hours: null })], NOW), B1); // no length: 3 hours
  assertEquals(pickBrownout([], NOW), null);
});

Deno.test('rain without a brownout: one call to notify-staff-inbox with exactly kind, from, peak_pct', async () => {
  const f = deps();
  const out = await runRainPush(f.d);
  assertEquals(out, { pushed: true });
  assertEquals(f.sent, [{ kind: 'rain', from: '2026-10-14T14:00', peak_pct: 80 }]);
  assertEquals(f.marks, ['2026-10-14T03:07:00.000Z']);
});

Deno.test('rain during a brownout adds brownout_notice_id', async () => {
  const f = deps({ brown: [{ id: B1, effective_date: '2026-10-14', effective_time: '13:00:00', duration_hours: 3 }] });
  await runRainPush(f.d);
  assertEquals(f.sent, [{ kind: 'rain', from: '2026-10-14T14:00', peak_pct: 80, brownout_notice_id: B1 }]);
});

Deno.test('below the threshold nothing is sent, and a missing forecast sends nothing', async () => {
  const a = deps({ hrs: dry });
  assertEquals((await runRainPush(a.d)).skipped, 'below_threshold');
  const b = deps({ hrs: null });
  assertEquals((await runRainPush(b.d)).skipped, 'no_forecast');
  assertEquals(a.sent.length + b.sent.length, 0);
});

Deno.test('never twice inside 3 hours, even for a new window; after 3 hours a new window may buzz again', async () => {
  const recent = deps({ lastPushAt: async () => new Date(NOW - 2 * 3_600_000).toISOString() });
  assertEquals((await runRainPush(recent.d)).skipped, 'within_3h_of_last_push');
  assertEquals(recent.sent.length, 0);
  const later = deps({ lastPushAt: async () => new Date(NOW - 3 * 3_600_000).toISOString() });
  assertEquals((await runRainPush(later.d)).pushed, true);
});

Deno.test('a push that reached nobody (already claimed, no phones) is not marked as pushed; a failure never throws', async () => {
  const none = deps({ send: async () => ({ ok: true, sent: 0 }) });
  assertEquals((await runRainPush(none.d)).pushed, false);
  assertEquals(none.marks.length, 0);
  const logs: string[] = [];
  const boom = deps({ send: async () => { throw new Error('down'); }, log: (m) => logs.push(m) });
  assertEquals(await runRainPush(boom.d), { pushed: false, skipped: 'error' });
  assert(logs[0].startsWith('rain push failed'));
});
