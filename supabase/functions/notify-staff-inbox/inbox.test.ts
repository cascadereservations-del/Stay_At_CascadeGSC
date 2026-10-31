// deno test --node-modules-dir=none --allow-env notify-staff-inbox/inbox.test.ts
// Lane XS: the order of events, the exact lock-screen payload, the claim keys, the caller check and the exact RPC names and argument keys.
// Frozen clock: no Date.now() anywhere; the bucket maths runs on NOW below.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { claimKey, CORS_H, handle, INBOX_BODY, type InboxDeps, parseEvent, runInbox, type Sub } from './inbox.ts';
import { type DbLike, makeDeps } from './deps.ts';
import type { PushResult } from '../_shared/C_webpush.ts';

const NOW = Date.UTC(2026, 9, 14, 3, 7, 0); // 2026-10-14 03:07:00Z
const H = '3f2a9c1e-7b6d-4e0a-8c55-0d1e2f3a4b5c';
const subs: Sub[] = [
  { id: 's1', endpoint: 'https://fcm.googleapis.com/fcm/send/a', p256dh: 'p', auth: 'a' },
  { id: 's2', endpoint: 'https://fcm.googleapis.com/fcm/send/b', p256dh: 'p', auth: 'a' },
];
const ok: PushResult = { ok: true, status: 201, gone: false, transient: false };

function fake(o: Partial<InboxDeps> & { results?: PushResult[] } = {}) {
  const calls: string[] = [], sent: Array<{ id: string; m: unknown }> = [], results = [...(o.results ?? [])];
  const deps: InboxDeps = {
    nowMs: () => NOW,
    recipients: async () => { calls.push('recipients'); return subs; },
    noticeRecipients: async () => subs,
    notice: async () => undefined,
    claim: async (k) => { calls.push(`claim:${k}`); return true; },
    deleteSub: async (id) => { calls.push(`delete:${id}`); },
    touchSub: async (id) => { calls.push(`touch:${id}`); },
    push: async (s, m) => { sent.push({ id: s.id, m }); return results.shift() ?? ok; },
    log: () => {},
    ...o,
  };
  return { deps, calls, sent };
}
const ev = (kind: 'handover' | 'guest_wrote') => ({ kind, psid: '1234567890', handoffId: kind === 'handover' ? H : null });

Deno.test('the payload has exactly the paid notice keys and no guest detail', async () => {
  const f = fake();
  await runInbox(ev('guest_wrote'), f.deps);
  assertEquals(f.sent[0].m, { title: 'Cascade Staff', body: 'A guest wrote on Messenger', url: './#inbox', tag: 'inbox' });
  assertEquals(Object.keys(f.sent[0].m as object), ['title', 'body', 'url', 'tag']);
  const g = fake();
  await runInbox(ev('handover'), g.deps);
  assertEquals((g.sent[0].m as { body: string }).body, 'Cassy needs you on a guest chat');
  for (const b of Object.values(INBOX_BODY)) assert(!/[!]|1234567890|PHP|@/.test(b));
  assert(!JSON.stringify(f.sent[0].m).includes('1234567890'));
});

Deno.test('claim keys: handover per handoff, guest_wrote per guest per 15-minute bucket', () => {
  assertEquals(claimKey(ev('handover'), NOW), `handover:${H}`);
  const b = Math.floor(NOW / 900_000);
  assertEquals(claimKey(ev('guest_wrote'), NOW), `guest_wrote:1234567890:${b}`);
  assertEquals(claimKey(ev('guest_wrote'), NOW + 7 * 60_000), `guest_wrote:1234567890:${b}`); // 03:14, same bucket
  assertEquals(claimKey(ev('guest_wrote'), NOW + 8 * 60_000), `guest_wrote:1234567890:${b + 1}`); // 03:15, next bucket
});

Deno.test('the order: recipients, claim, then every send, then touch', async () => {
  const f = fake();
  const out = await runInbox(ev('handover'), f.deps);
  assertEquals(f.calls, ['recipients', `claim:handover:${H}`, 'touch:s1', 'touch:s2']);
  assertEquals(out, { ok: true, push: { sent: 2, gone: 0, failed: 0, subscriptions: 2 } });
});

Deno.test('a second ask of the same key sends nothing', async () => {
  const f = fake({ claim: async () => false });
  const out = await runInbox(ev('handover'), f.deps);
  assertEquals(f.sent.length, 0);
  assertEquals(out.skipped, 'already_sent');
});

Deno.test('no phone listening: nothing is claimed and nothing is sent', async () => {
  const f = fake({ recipients: async () => [] });
  const out = await runInbox(ev('guest_wrote'), f.deps);
  assertEquals(out.skipped, 'no_recipients');
  assertEquals(f.calls, []);
});

Deno.test('VAPID secrets missing: skipped before any read', async () => {
  const f = fake({ push: null });
  const out = await runInbox(ev('guest_wrote'), f.deps);
  assertEquals(out.skipped, 'push_not_configured');
  assertEquals(f.calls, []);
});

Deno.test('a failed read or claim answers rpc_failed and sends nothing', async () => {
  const a = fake({ recipients: async () => null });
  assertEquals((await runInbox(ev('handover'), a.deps)).reason, 'rpc_failed');
  const b = fake({ claim: async () => null });
  assertEquals((await runInbox(ev('handover'), b.deps)).reason, 'rpc_failed');
  assertEquals(a.sent.length + b.sent.length, 0);
});

Deno.test('404/410 drops that subscription; a transient answer is retried once; one failure never blocks the next phone', async () => {
  const gone: PushResult = { ok: false, status: 410, gone: true, transient: false };
  const slow: PushResult = { ok: false, status: 503, gone: false, transient: true };
  const f = fake({ results: [gone, slow, ok] });
  const out = await runInbox(ev('guest_wrote'), f.deps);
  assertEquals(f.calls.filter((c) => c.startsWith('delete') || c.startsWith('touch')), ['delete:s1', 'touch:s2']);
  assertEquals(f.sent.map((s) => s.id), ['s1', 's2', 's2']);
  assertEquals(out.push, { sent: 1, gone: 1, failed: 0, subscriptions: 2 });
  const g = fake({ results: [slow, slow, ok] });
  assertEquals((await runInbox(ev('guest_wrote'), g.deps)).push, { sent: 1, gone: 0, failed: 1, subscriptions: 2 });
  const t = fake({ push: async () => { throw new Error('boom'); } });
  assertEquals((await runInbox(ev('guest_wrote'), t.deps)).push.failed, 2);
});

Deno.test('the body is validated; nothing echoes the input', () => {
  assertEquals(parseEvent(null), { ok: false, reason: 'bad_request' });
  assertEquals(parseEvent({ kind: 'paid', psid: '1' }), { ok: false, reason: 'bad_kind' });
  assertEquals(parseEvent({ kind: 'guest_wrote', psid: 'a b' }), { ok: false, reason: 'bad_psid' });
  assertEquals(parseEvent({ kind: 'guest_wrote' }), { ok: false, reason: 'bad_psid' });
  assertEquals(parseEvent({ kind: 'handover', psid: '1' }), { ok: false, reason: 'bad_handoff_id' });
  assertEquals(parseEvent({ kind: 'handover', psid: '1', handoff_id: 'x' }), { ok: false, reason: 'bad_handoff_id' });
  assertEquals(parseEvent({ kind: 'guest_wrote', psid: '1', handoff_id: 'x' }), { ok: true, value: { kind: 'guest_wrote', psid: '1', handoffId: null } });
});

Deno.test('the request: preflight allows the browser headers, a stranger gets 401, a good call gets 200', async () => {
  const f = fake();
  const o = { authorized: (r: Request) => r.headers.get('x-test') === 'yes', deps: f.deps };
  const pre = await handle(new Request('https://x.test/', { method: 'OPTIONS' }), o);
  assertEquals(pre.status, 200);
  for (const h of ['authorization', 'apikey', 'x-client-info', 'content-type']) assert(CORS_H['Access-Control-Allow-Headers'].includes(h));
  assertEquals((await handle(new Request('https://x.test/', { method: 'GET' }), o)).status, 405);
  const body = JSON.stringify({ kind: 'guest_wrote', psid: '1234567890' });
  assertEquals((await handle(new Request('https://x.test/', { method: 'POST', body }), o)).status, 401);
  assertEquals(f.calls, []);
  assertEquals((await handle(new Request('https://x.test/', { method: 'POST', body: '{', headers: { 'x-test': 'yes' } }), o)).status, 400);
  const good = await handle(new Request('https://x.test/', { method: 'POST', body, headers: { 'x-test': 'yes' } }), o);
  assertEquals(good.status, 200);
  assertEquals((await good.json()).push.sent, 2);
  const bad = fake({ recipients: async () => null });
  assertEquals((await handle(new Request('https://x.test/', { method: 'POST', body, headers: { 'x-test': 'yes' } }), { ...o, deps: bad.deps })).status, 502);
});

Deno.test('the database calls use the exact RPC names and argument keys', async () => {
  const rpcs: Array<{ fn: string; args: unknown }> = [], tables: string[] = [];
  const chain = (t: string) => ({
    delete: () => ({ eq: async (c: string, v: string) => { tables.push(`${t}.delete.${c}=${v}`); } }),
    update: (row: Record<string, unknown>) => ({ eq: async (c: string, v: string) => { tables.push(`${t}.update.${Object.keys(row)}.${c}=${v}.${row.last_ok_at}`); } }),
  });
  const db: DbLike = {
    rpc: async (fn, args) => { rpcs.push({ fn, args }); return fn === 'staff_push_claim_v1' ? { data: true, error: null } : { data: subs, error: null }; },
    from: chain,
  };
  const d = makeDeps(db, async () => ok, () => NOW);
  assertEquals(await d.recipients(), subs);
  assertEquals(await d.claim('k1'), true);
  await d.deleteSub('s1');
  await d.touchSub('s2');
  assertEquals(rpcs, [{ fn: 'staff_push_inbox_recipients_v1', args: undefined }, { fn: 'staff_push_claim_v1', args: { p_key: 'k1' } }]);
  assertEquals(tables, ['staff_push_subscriptions.delete.id=s1', 'staff_push_subscriptions.update.last_ok_at.id=s2.2026-10-14T03:07:00.000Z']);
  const failing = makeDeps({ rpc: async () => ({ data: null, error: { code: '42883' } }), from: chain }, async () => ok, () => NOW);
  assertEquals(await failing.recipients(), null);
  assertEquals(await failing.claim('k'), null);
});

// ---- s104: meter_resend, a push to the ONE cleaner who submitted the report ----
const U = '9c1e4a52-3b7d-4f08-8a21-5e6f7a8b9c0d';
const R = '1b2c3d4e-5f60-4a71-8b92-a3b4c5d6e7f8';
Deno.test('meter_resend: parses, rejects bad ids and a bad stay', () => {
  assertEquals(parseEvent({ kind: 'meter_resend', user_id: U.toUpperCase(), reading_id: R, stay: '2026-10-22' }), { ok: true, value: { kind: 'meter_resend', userId: U, readingId: R, stay: '2026-10-22' } });
  assertEquals(parseEvent({ kind: 'meter_resend', user_id: U, reading_id: R }), { ok: true, value: { kind: 'meter_resend', userId: U, readingId: R, stay: null } });
  assertEquals(parseEvent({ kind: 'meter_resend', user_id: 'x', reading_id: R }), { ok: false, reason: 'bad_user_id' });
  assertEquals(parseEvent({ kind: 'meter_resend', user_id: U, reading_id: 'x' }), { ok: false, reason: 'bad_reading_id' });
  assertEquals(parseEvent({ kind: 'meter_resend', user_id: U, reading_id: R, stay: '22 Oct' }), { ok: false, reason: 'bad_stay' });
});

Deno.test('meter_resend: one claim per reading per 15 minutes, the payload is the plain sentence, only that user phones are asked', async () => {
  const e = { kind: 'meter_resend' as const, userId: U, readingId: R, stay: '2026-10-22' };
  assertEquals(claimKey(e, NOW), `meter_resend:${R}:${Math.floor(NOW / 900_000)}`);
  const asked: string[] = [];
  const f = fake({ userRecipients: async (u) => { asked.push(u); return subs; } });
  const out = await runInbox(e, f.deps);
  assertEquals(out.push.sent, 2);
  assertEquals(asked, [U]);
  assert(!f.calls.includes('recipients'));
  assertEquals(f.sent[0].m, { title: 'Cascade Staff', body: 'New meter photo needed for the Thu 22 Oct stay.', url: './#calendar/notices', tag: 'meter-resend' });
  assert(!/[!]|PHP|@/.test((f.sent[0].m as { body: string }).body));
  const none = await runInbox({ ...e, stay: null }, fake({ userRecipients: async () => subs }).deps);
  assertEquals(none.ok, true);
});

Deno.test('meter_resend: no phone for that user sends and claims nothing; a failed read is a 502; a second ask in the bucket sends nothing', async () => {
  const f = fake({ userRecipients: async () => [] });
  const e = { kind: 'meter_resend' as const, userId: U, readingId: R, stay: null };
  assertEquals((await runInbox(e, f.deps)).skipped, 'no_recipients');
  assert(!f.calls.some((c) => c.startsWith('claim:')));
  assertEquals((await runInbox(e, fake({ userRecipients: async () => null }).deps)).reason, 'rpc_failed');
  const g = fake({ userRecipients: async () => subs, claim: async () => false });
  assertEquals((await runInbox(e, g.deps)).skipped, 'already_sent');
  assertEquals(g.sent.length, 0);
});

Deno.test('meter_resend: userRecipients reads staff_push_subscriptions by user and notices topic, falls back when topics is absent', async () => {
  const seen: string[] = [];
  const mk = (firstErr: { code?: string; message?: string } | null) => {
    // deno-lint-ignore no-explicit-any
    const q: any = { select: () => q, eq: (c: string, v: string) => { seen.push(`${c}=${v}`); return q; }, contains: (c: string, v: string[]) => { seen.push(`${c}~${v}`); return Promise.resolve({ data: firstErr ? null : subs, error: firstErr }); }, then: (r: (x: unknown) => void) => r({ data: subs, error: null }) };
    return { rpc: async () => ({ data: null, error: null }), from: (t: string) => { seen.push(`from:${t}`); return q; } } as unknown as DbLike;
  };
  assertEquals(await makeDeps(mk(null), null, () => NOW).userRecipients!(U), subs);
  assertEquals(seen, ['from:staff_push_subscriptions', `user_id=${U}`, 'topics~notices']);
  assertEquals(await makeDeps(mk({ code: '42703' }), null, () => NOW).userRecipients!(U), subs);
  assertEquals(await makeDeps(mk({ code: '57014' }), null, () => NOW).userRecipients!(U), null);
});
