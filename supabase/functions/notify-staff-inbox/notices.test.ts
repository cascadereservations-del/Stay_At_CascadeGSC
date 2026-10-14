// deno test --node-modules-dir=none --allow-env notify-staff-inbox/notices.test.ts
// Lane XS2: the notice and rain kinds. Frozen clock: NOW is 2026-10-14 11:07 in Manila (03:07Z); nothing reads Date.now().
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { claimKey, type InboxDeps, parseEvent, runInbox, type Sub } from './inbox.ts';
import { dayLabel, hoursLabel, isImportant, type NoticeRow, noticeBody, rainBody, rainKey } from './notices.ts';
import { type DbLike, makeDeps } from './deps.ts';
import type { PushResult } from '../_shared/C_webpush.ts';

const NOW = Date.UTC(2026, 9, 14, 3, 7, 0);
const N1 = '3f2a9c1e-7b6d-4e0a-8c55-0d1e2f3a4b5c';
const PROP = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const subs: Sub[] = [{ id: 's1', endpoint: 'https://fcm.googleapis.com/fcm/send/a', p256dh: 'p', auth: 'a' }];
const ok: PushResult = { ok: true, status: 201, gone: false, transient: false };
const row = (o: Partial<NoticeRow> = {}): NoticeRow => ({ id: N1, property_id: PROP, notice_type: 'brownout', effective_date: '2026-10-16', effective_time: '13:00:00', duration_hours: 3, is_active: true, ...o });
// the Staff service worker amount filter (pay/C_push-sw.js): a body that matches it would be replaced by a generic sentence
const C_AMOUNT = /(?:PHP|Php|php|₱|\bP)\s*\d|\d[\d,.]*\s*(?:[Pp]esos?\b|PHP|Php|php|₱)|\d[\d,]{3,}/;

function fake(o: Partial<InboxDeps> = {}) {
  // deno-lint-ignore no-explicit-any
  const calls: string[] = [], sent: Array<{ id: string; m: any }> = [];
  const deps: InboxDeps = {
    nowMs: () => NOW,
    recipients: async () => { calls.push('inbox-recipients'); return subs; },
    noticeRecipients: async (p) => { calls.push(`notice-recipients:${p}`); return subs; },
    notice: async (id) => { calls.push(`notice:${id}`); return row(); },
    claim: async (k) => { calls.push(`claim:${k}`); return true; },
    deleteSub: async () => {}, touchSub: async () => {},
    push: async (s, m) => { sent.push({ id: s.id, m }); return ok; },
    log: () => {}, ...o,
  };
  return { deps, calls, sent };
}
const NOTICE = { kind: 'notice' as const, noticeId: N1 };
const RAIN = (o: Record<string, unknown> = {}) => ({ kind: 'rain' as const, from: '2026-10-14T15:00', peakPct: 80, brownoutNoticeId: null as string | null, ...o });

Deno.test('the body is parsed for both new kinds and refused when wrong', () => {
  assertEquals(parseEvent({ kind: 'notice', notice_id: N1.toUpperCase() }), { ok: true, value: NOTICE });
  assertEquals(parseEvent({ kind: 'notice' }), { ok: false, reason: 'bad_notice_id' });
  assertEquals(parseEvent({ kind: 'rain', from: '2026-10-14T15:00:00', peak_pct: 80 }), { ok: true, value: RAIN() });
  assertEquals(parseEvent({ kind: 'rain', from: '2026-10-14T15:00', peak_pct: 80, brownout_notice_id: N1 }), { ok: true, value: RAIN({ brownoutNoticeId: N1 }) });
  assertEquals(parseEvent({ kind: 'rain', from: '2026-10-14T15:00', peak_pct: 101 }), { ok: false, reason: 'bad_peak_pct' });
  assertEquals(parseEvent({ kind: 'rain', from: '2026-10-14T15:00', peak_pct: null }), { ok: false, reason: 'bad_peak_pct' });
  assertEquals(parseEvent({ kind: 'rain', from: 'soon', peak_pct: 80 }), { ok: false, reason: 'bad_from' });
  assertEquals(parseEvent({ kind: 'rain', from: '2026-10-14T15:00', peak_pct: 80, brownout_notice_id: 'x' }), { ok: false, reason: 'bad_notice_id' });
  assertEquals(parseEvent({ kind: 'rain_brownout', notice_id: N1 }), { ok: false, reason: 'bad_kind' });
});

Deno.test('lock-screen wording: brownout, water, no hours, hours across noon', () => {
  assertEquals(dayLabel('2026-10-16'), 'Fri 16 Oct');
  assertEquals(noticeBody(NOTICE, row()), 'Brownout scheduled Fri 16 Oct, 1:00 to 4:00 pm');
  assertEquals(noticeBody(NOTICE, row({ notice_type: 'water', effective_time: '11:00:00' })), 'Water interruption scheduled Fri 16 Oct, 11:00 am to 2:00 pm');
  assertEquals(noticeBody(NOTICE, row({ effective_time: null, duration_hours: null })), 'Brownout scheduled Fri 16 Oct');
  assertEquals(hoursLabel('08:30:00', null), 'from 8:30 am');
  assertEquals(hoursLabel('00:00:00', 2), '12:00 to 2:00 am');
  assertEquals(hoursLabel('23:00:00', 3), '11:00 pm to 2:00 am');
});

Deno.test('rain wording: from about 3 pm (80%), during the brownout, and already begun', () => {
  assertEquals(rainBody(RAIN(), false, NOW), 'Rain likely from about 3 pm (80%).');
  assertEquals(rainBody(RAIN(), true, NOW), 'Rain likely from about 3 pm during the brownout.');
  assertEquals(rainBody(RAIN({ from: '2026-10-14T15:30' }), false, NOW), 'Rain likely from about 3:30 pm (80%).');
  assertEquals(rainBody(RAIN({ from: '2026-10-14T11:00' }), false, NOW), 'Rain likely in the next 3 hours (80%).');
  assertEquals(rainBody(RAIN({ from: '2026-10-14T11:00' }), true, NOW), 'Rain likely in the next 3 hours during the brownout.');
});

Deno.test('no body can trip the service worker amount filter or carries an exclamation mark', () => {
  const bodies = [noticeBody(NOTICE, row()), noticeBody(NOTICE, row({ notice_type: 'water', effective_time: '11:00:00' })), noticeBody(NOTICE, row({ effective_time: null })),
    rainBody(RAIN(), false, NOW), rainBody(RAIN(), true, NOW), rainBody(RAIN({ from: '2026-10-14T15:30', peakPct: 100 }), false, NOW)];
  for (const b of bodies) { assert(!C_AMOUNT.test(b), b); assert(!b.includes('!'), b); }
});

Deno.test('which notices count: brownout and water, active, today or later, any source', () => {
  assert(isImportant(row(), NOW));
  assert(isImportant(row({ notice_type: 'water' }), NOW));
  assert(isImportant(row({ effective_date: '2026-10-14' }), NOW)); // today
  assert(!isImportant(row({ effective_date: '2026-10-13' }), NOW)); // yesterday
  assert(!isImportant(row({ notice_type: 'note' }), NOW));
  assert(!isImportant(row({ notice_type: 'deep_clean' }), NOW));
  assert(!isImportant(row({ is_active: false }), NOW));
  // just after midnight in Manila (16:00Z) it is already the 15th
  assert(!isImportant(row({ effective_date: '2026-10-14' }), Date.UTC(2026, 9, 14, 16, 0, 0)));
});

Deno.test('claim keys: notice per notice, rain per Manila date and window start hour', () => {
  assertEquals(claimKey(NOTICE, NOW), `notice:${N1}`);
  assertEquals(claimKey(RAIN(), NOW), 'rain:2026-10-14:15');
  assertEquals(rainKey('2026-10-14T09:00'), 'rain:2026-10-14:09');
  assertEquals(claimKey(RAIN({ from: '2026-10-14T16:00' }), NOW), 'rain:2026-10-14:16'); // a later window is its own episode
});

Deno.test('a new notice: read, recipients of its property, claim notice:<id>, the payload keys', async () => {
  const f = fake();
  const out = await runInbox(NOTICE, f.deps);
  assertEquals(f.calls, [`notice:${N1}`, `notice-recipients:${PROP}`, `claim:notice:${N1}`]);
  assertEquals(f.sent[0].m, { title: 'Cascade Staff', body: 'Brownout scheduled Fri 16 Oct, 1:00 to 4:00 pm', url: './#calendar/notices', tag: 'notices' });
  assertEquals(Object.keys(f.sent[0].m), ['title', 'body', 'url', 'tag']);
  assertEquals(out, { ok: true, push: { sent: 1, gone: 0, failed: 0, subscriptions: 1 } });
});

Deno.test('a past, inactive or unimportant notice tells nobody and claims nothing', async () => {
  for (const r of [row({ effective_date: '2026-10-13' }), row({ is_active: false }), row({ notice_type: 'note' })]) {
    const f = fake({ notice: async () => r });
    const out = await runInbox(NOTICE, f.deps);
    assertEquals(out.skipped, 'not_important');
    assertEquals(f.sent.length, 0);
    assertEquals(f.calls, []);
  }
  const gone = fake({ notice: async () => undefined });
  assertEquals((await runInbox(NOTICE, gone.deps)).skipped, 'not_found');
  const bad = fake({ notice: async () => null });
  assertEquals((await runInbox(NOTICE, bad.deps)).reason, 'rpc_failed');
});

Deno.test('a second ask for the same notice sends nothing', async () => {
  const f = fake({ claim: async () => false });
  assertEquals((await runInbox(NOTICE, f.deps)).skipped, 'already_sent');
  assertEquals(f.sent.length, 0);
});

Deno.test('rain without a brownout: the plain wording, house recipients, one claim per episode', async () => {
  const f = fake();
  await runInbox(RAIN(), f.deps);
  assertEquals(f.calls, [`notice-recipients:${PROP}`, 'claim:rain:2026-10-14:15']);
  assertEquals(f.sent[0].m, { title: 'Cascade Staff', body: 'Rain likely from about 3 pm (80%).', url: './#calendar/notices', tag: 'notices' });
  const again = fake({ claim: async () => false });
  assertEquals((await runInbox(RAIN(), again.deps)).skipped, 'already_sent');
  assertEquals(again.sent.length, 0);
});

Deno.test('rain during a brownout names it; a brownout that is past, inactive or not a brownout is ignored', async () => {
  const f = fake();
  await runInbox(RAIN({ brownoutNoticeId: N1 }), f.deps);
  assertEquals(f.sent[0].m.body, 'Rain likely from about 3 pm during the brownout.');
  for (const r of [row({ effective_date: '2026-10-13' }), row({ is_active: false }), row({ notice_type: 'water' })]) {
    const g = fake({ notice: async () => r });
    await runInbox(RAIN({ brownoutNoticeId: N1 }), g.deps);
    assertEquals(g.sent[0].m.body, 'Rain likely from about 3 pm (80%).');
  }
  const bad = fake({ notice: async () => null });
  assertEquals((await runInbox(RAIN({ brownoutNoticeId: N1 }), bad.deps)).reason, 'rpc_failed');
});

Deno.test('rain from a day already past is refused; no phones means no claim', async () => {
  const f = fake();
  assertEquals((await runInbox(RAIN({ from: '2026-10-13T15:00' }), f.deps)).skipped, 'not_important');
  assertEquals(f.calls, []);
  const g = fake({ noticeRecipients: async () => [] });
  assertEquals((await runInbox(RAIN(), g.deps)).skipped, 'no_recipients');
  assertEquals(g.sent.length, 0);
});

Deno.test('the database calls: exact RPC name and argument key, exact table read', async () => {
  const rpcs: Array<{ fn: string; args: unknown }> = [], reads: string[] = [];
  const db: DbLike = {
    rpc: async (fn, args) => { rpcs.push({ fn, args }); return { data: subs, error: null }; },
    from: (t: string) => ({ select: (c: string) => ({ eq: (k: string, v: string) => ({ maybeSingle: async () => { reads.push(`${t}|${c}|${k}=${v}`); return { data: row(), error: null }; } }) }) }),
  };
  const d = makeDeps(db, async () => ok, () => NOW);
  assertEquals(await d.noticeRecipients(PROP), subs);
  assertEquals((await d.notice(N1))?.id, N1);
  assertEquals(rpcs, [{ fn: 'staff_push_notice_recipients_v1', args: { p_property_id: PROP } }]);
  assertEquals(reads, [`ops_notices|id,property_id,notice_type,effective_date,effective_time,duration_hours,is_active|id=${N1}`]);
  const failing = makeDeps({ rpc: async () => ({ data: null, error: { code: '42883' } }), from: () => ({ select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: null, error: { code: 'x' } }) }) }) }) }, async () => ok, () => NOW);
  assertEquals(await failing.noticeRecipients(PROP), null);
  assertEquals(await failing.notice(N1), null);
});
