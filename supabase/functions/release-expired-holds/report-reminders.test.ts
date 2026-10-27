// deno test --allow-env release-expired-holds/report-reminders.test.ts - fakes only, synthetic data.
import { assertEquals } from 'jsr:@std/assert@1';
import { drain, type Deps, type Due, reminderBody } from './report-reminders.ts';
import type { Sub } from './payout-notices.ts';

const due = (date: string, over: Partial<Due> = {}): Due => ({ request_id: 'aaaaaaaa-0000-4000-8000-000000000001', ref: 'ABCD1234', payee_user_id: 'u1', checkout_date: date, stage: 1, owed_dates: ['2026-10-22', '2026-10-19'], ...over });
const sub: Sub = { id: 's1', endpoint: 'https://push.example/x', p256dh: 'p', auth: 'a' };
const ok = { ok: true, status: 201, gone: false, transient: false };
function world(rows: Due[], over: Partial<Deps> = {}) {
  const claims: string[] = [], releases: string[] = [], sents: string[] = [], pushes: Array<Record<string, string>> = [], logs: string[] = [], deleted: string[] = [];
  const deps: Deps = { due: async () => ({ rows }),
    claim: async (r) => { claims.push(r.checkout_date); return true; }, release: async (r) => { releases.push(r.checkout_date); }, sent: async (r) => { sents.push(r.checkout_date); },
    subs: async () => [sub], push: async (_s, m) => { pushes.push(m); return ok; }, deleteSub: async (id) => { deleted.push(id); }, touchSub: async () => {}, log: (m) => logs.push(m), ...over };
  return { deps, claims, releases, sents, pushes, logs, deleted };
}

Deno.test('body: hand-written dates, one / two / many, no amounts', () => {
  assertEquals(reminderBody(['2026-10-19']), 'Paid ahead for 19 Oct. Please send the cleaning report.');
  assertEquals(reminderBody(['2026-10-22', '2026-10-19']), 'Paid ahead for 19 Oct and 22 Oct. Please send the cleaning report for each.');
  assertEquals(reminderBody(['2026-11-03', '2026-10-19', '2026-10-22']), 'Paid ahead for 19 Oct, 22 Oct and 3 Nov. Please send the cleaning report for each.');
  assertEquals(reminderBody(['2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04', '2026-10-05', '2026-10-06']), 'Paid ahead for 1 Oct, 2 Oct, 3 Oct, 4 Oct and 2 more. Please send the cleaning report for each.');
});
Deno.test('one request with two owed dates: both rows claimed, ONE push with the contract text, both marked sent', async () => {
  const w = world([due('2026-10-19'), due('2026-10-22')]);
  assertEquals(await drain(w.deps), { groups: 1, sent: 1, failed: 0 });
  assertEquals(w.claims, ['2026-10-19', '2026-10-22']);
  assertEquals(w.sents, ['2026-10-19', '2026-10-22']);
  assertEquals(w.pushes, [{ title: 'Cleaning report still owed', body: 'Paid ahead for 19 Oct and 22 Oct. Please send the cleaning report for each.', url: './checklist/', tag: 'report-owed' }]);
  assertEquals(w.releases, []);
});
Deno.test('claim race: a lost first claim sends nothing; a lost later claim is not marked sent by us', async () => {
  const lost = world([due('2026-10-19'), due('2026-10-22')], { claim: async () => false });
  assertEquals(await drain(lost.deps), { groups: 1, sent: 0, failed: 0 });
  assertEquals([lost.pushes.length, lost.sents, lost.releases], [0, [], []]);
  const part = world([due('2026-10-19'), due('2026-10-22')], { claim: async (r) => r.checkout_date === '2026-10-19' });
  await drain(part.deps);
  assertEquals([part.pushes.length, part.sents], [1, ['2026-10-19']]);
});
Deno.test('stages and requests are separate messages', async () => {
  const w = world([due('2026-10-19'), due('2026-10-19', { stage: 3 }), due('2026-10-19', { request_id: 'bbbbbbbb-0000-4000-8000-000000000002' })]);
  assertEquals((await drain(w.deps)).sent, 3);
  assertEquals(w.pushes.length, 3);
});
Deno.test('transient failure releases every claim; a retry that works does not; permanent refusal closes; a dead sub is deleted and closes', async () => {
  const t = world([due('2026-10-19'), due('2026-10-22')], { push: async () => ({ ok: false, status: 503, gone: false, transient: true }) });
  assertEquals(await drain(t.deps), { groups: 1, sent: 0, failed: 1 });
  assertEquals([t.releases, t.sents], [['2026-10-19', '2026-10-22'], []]);
  let n = 0;
  const r = world([due('2026-10-19')], { push: async () => (++n === 1 ? { ok: false, status: 503, gone: false, transient: true } : ok) });
  assertEquals([(await drain(r.deps)).sent, r.releases], [1, []]);
  const p = world([due('2026-10-19')], { push: async () => ({ ok: false, status: 400, gone: false, transient: false }) });
  assertEquals([(await drain(p.deps)).sent, p.releases, p.sents, p.logs.length], [1, [], ['2026-10-19'], 1]);
  const g = world([due('2026-10-19')], { push: async () => ({ ok: false, status: 410, gone: true, transient: false }) });
  assertEquals([(await drain(g.deps)).sent, g.deleted, g.sents], [1, ['s1'], ['2026-10-19']]);
  const none = world([due('2026-10-19')], { subs: async () => [] });
  assertEquals([(await drain(none.deps)).sent, none.sents], [1, ['2026-10-19']]);
});
Deno.test('a throw after the claim releases it and does not stop the next group', async () => {
  let n = 0;
  const w = world([due('2026-10-19'), due('2026-10-19', { payee_user_id: 'u2' })], { subs: async () => { if (++n === 1) throw new Error('db down'); return [sub]; } });
  assertEquals(await drain(w.deps), { groups: 2, sent: 1, failed: 1 });
  assertEquals(w.releases, ['2026-10-19']);
});
Deno.test('no VAPID: nothing claimed; function missing or read failure: nothing thrown', async () => {
  const off = world([due('2026-10-19')], { push: null });
  assertEquals(await drain(off.deps), { groups: 0, sent: 0, failed: 0 });
  assertEquals(off.claims, []);
  assertEquals((await drain(world([], { due: async () => ({ rows: [], missing: true }) }).deps)).groups, 0);
  assertEquals((await drain(world([], { due: async () => { throw new Error('boom'); } }).deps)).groups, 0);
});
Deno.test('budget: a new group starts only inside the start window, the rest waits', async () => {
  let t = 0;
  const w = world([due('2026-10-19', { payee_user_id: 'a' }), due('2026-10-19', { payee_user_id: 'b' }), due('2026-10-19', { payee_user_id: 'c' })], { nowMs: () => (t += 15_000) });
  const r = await drain(w.deps);
  assertEquals(r.groups < 3, true);
  assertEquals(w.logs.some((m) => m.includes('time budget')), true);
});
