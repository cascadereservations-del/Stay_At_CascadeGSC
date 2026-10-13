// deno test --node-modules-dir=none --allow-env notify-cleaner-payment/paid.test.ts
// Lane C (s81): the wording is exact, and the order of events in runPaid is checked with fakes. No clock reads, no network.
import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { noticeText, php, pushBody, PUSH_TITLE, referenceText, workRange } from './paid-text.ts';
import { type NoticeData, type PaidDeps, runPaid, type Sub } from './paid.ts';

const N = { first_name: 'Honey', total: 1235, date_from: '2026-10-10', date_to: '2026-10-12', bank_reference: '12345678', bank_label: 'MariBank', ref: 'ABCD1234' };

Deno.test('the push is exactly the approved wording and carries no amount, no reference', () => {
  assertEquals(PUSH_TITLE, 'Your payment has been sent');
  assertEquals(pushBody(N), 'Hi Honey, your pay for Oct 10 to Oct 12 is on its way to your MariBank account. Open Cascade Staff for the details. Thank you for your care with the house.');
  assert(!/PHP|₱|1,?235|1234/.test(pushBody(N)));
  assert(!pushBody(N).includes('!'));
});

Deno.test('the in-app and Telegram notice is exactly the approved wording', () => {
  assertEquals(noticeText(N),
    'Hi Honey, we have sent PHP 1,235 to your MariBank account for your work on Oct 10 to Oct 12. Reference: 1234 5678. Please let us know if anything looks different on your side. Thank you for your care with the house. Marifel & The Cascade Team');
  assert(!noticeText(N).includes('!'));
});

Deno.test('one-day range, no bank label, no bank reference, cents', () => {
  assertEquals(workRange('2026-10-10', '2026-10-10'), 'Oct 10');
  assertEquals(workRange('2026-10-10', null), 'Oct 10');
  assertEquals(workRange(null, null), '');
  assertEquals(php(1235.5), 'PHP 1,235.50');
  assertEquals(php('40'), 'PHP 40');
  assertEquals(referenceText({ ...N, bank_reference: 'ab12-3456 789' }), 'ab12 3456 789');
  const bare = { first_name: 'Honey', total: 40, date_from: '2026-10-10', date_to: '2026-10-10', bank_reference: null, bank_label: null, ref: 'ABCD1234' };
  assertEquals(noticeText(bare), 'Hi Honey, we have sent PHP 40 to your account for your work on Oct 10. Reference: CASCADE-ABCD1234. Please let us know if anything looks different on your side. Thank you for your care with the house. Marifel & The Cascade Team');
  assertEquals(pushBody(bare), 'Hi Honey, your pay for Oct 10 is on its way to your account. Open Cascade Staff for the details. Thank you for your care with the house.');
});

type Call = { kind: string; arg?: unknown };
function fake(over: Omit<Partial<PaidDeps>, 'subs'> & { notice?: NoticeData | { ok: false; reason: string }; subs?: Sub[]; pushAnswers?: Array<Array<{ ok: boolean; status: number; gone: boolean; transient: boolean }>> } = {}) {
  const calls: Call[] = [];
  const notice = over.notice ?? { ok: true, request_id: 'r', payee_user_id: 'u', payee_name: 'Honey', paid_by_tg: null, ops_chat_id: -100, ops_message_id: 7, ...N } as NoticeData;
  const answers = (over.pushAnswers ?? []).map((a) => [...a]);
  let si = 0;
  const deps: PaidDeps = {
    claim: async (id) => { calls.push({ kind: 'claim', arg: id }); return notice; },
    tg: async (method, body) => { calls.push({ kind: 'tg:' + method, arg: body }); return { ok: true }; },
    opsChat: '-100',
    financeCard: async () => ({ chat_id: -200, message_id: 9, text: 'PAID. card', reply_markup: { inline_keyboard: [] }, ops_keyboard: { inline_keyboard: [[{ text: 'Received' }]] } }),
    subs: async () => over.subs ?? [],
    deleteSub: async (id) => { calls.push({ kind: 'delete', arg: id }); },
    touchSub: async (id) => { calls.push({ kind: 'touch', arg: id }); },
    push: over.push === null ? null : (over.push ?? (async (s, m) => {
      calls.push({ kind: 'push', arg: { id: s.id, m } });
      const list = answers[si] ?? []; const a = list.shift() ?? { ok: true, status: 201, gone: false, transient: false };
      return a;
    })),
    log: (m) => calls.push({ kind: 'log', arg: m }),
    ...('tg' in over ? { tg: over.tg! } : {}),
  };
  return { deps, calls, next: () => si++ };
}
const sub = (id: string): Sub => ({ id, endpoint: 'https://p.test/' + id, p256dh: 'k', auth: 'a' });

Deno.test('a web-settled request: claim first, then OPS notice with the Received button as a reply, the Finance card redrawn, then the push', async () => {
  const f = fake({ subs: [sub('s1')] });
  const out = await runPaid('r', f.deps);
  assertEquals(out, { ok: true, telegram: 'sent', push: { sent: 1, gone: 0, failed: 0, subscriptions: 1 } });
  assertEquals(f.calls.map((c) => c.kind), ['claim', 'tg:sendMessage', 'tg:editMessageCaption', 'push', 'touch']);
  const ops = f.calls[1].arg as Record<string, unknown>;
  assertEquals([ops.chat_id, ops.reply_to_message_id, ops.allow_sending_without_reply], [-100, 7, true]);
  assertStringIncludes(String(ops.text), 'Hi Honey, we have sent PHP 1,235');
  assertEquals(ops.reply_markup, { inline_keyboard: [[{ text: 'Received' }]] });
  assert(!('parse_mode' in ops), 'plain text, no parse_mode');
  const pushed = (f.calls[3].arg as { m: { title: string; body: string } }).m;
  assertEquals(pushed.title, 'Your payment has been sent');
  assert(!/PHP|1,235/.test(pushed.body));
});

Deno.test('a request Finance settled in Telegram: no second OPS post, the push still goes', async () => {
  const f = fake({ subs: [sub('s1')], notice: { ok: true, request_id: 'r', payee_user_id: 'u', payee_name: 'Honey', paid_by_tg: 920000001, ops_chat_id: -100, ops_message_id: 7, ...N } as NoticeData });
  const out = await runPaid('r', f.deps);
  assertEquals(out.telegram, 'skipped');
  assertEquals(f.calls.map((c) => c.kind), ['claim', 'push', 'touch']);
});

Deno.test('already sent or not paid: nothing is sent; an unknown request is not ok', async () => {
  for (const reason of ['already_sent', 'not_paid']) {
    const f = fake({ notice: { ok: false, reason }, subs: [sub('s1')] });
    const out = await runPaid('r', f.deps);
    assertEquals([out.ok, out.skipped], [true, reason]);
    assertEquals(f.calls.map((c) => c.kind), ['claim']);
  }
  assertEquals((await runPaid('r', fake({ notice: { ok: false, reason: 'not_found' } }).deps)).ok, false);
});

Deno.test('a push that fails never stops the notice or the other phones: transient gets ONE retry, final failures none, 404/410 delete the subscription', async () => {
  const gone = { ok: false, status: 410, gone: true, transient: false }, trans = { ok: false, status: 503, gone: false, transient: true };
  const fin = { ok: false, status: 400, gone: false, transient: false }, good = { ok: true, status: 201, gone: false, transient: false };
  // s1: transient then ok (2 attempts); s2: transient twice (2 attempts, then given up); s3: gone; s4: final failure (1 attempt); s5: throws
  const answers: Record<string, typeof good[]> = { s1: [trans, good], s2: [trans, trans, good], s3: [gone], s4: [fin] };
  const f = fake({
    subs: ['s1', 's2', 's3', 's4', 's5'].map(sub),
    push: async (s, m) => {
      f.calls.push({ kind: 'push', arg: s.id });
      if (s.id === 's5') throw new Error('boom');
      return answers[s.id].shift()!;
    },
  });
  const out = await runPaid('r', f.deps);
  assertEquals(out.push, { sent: 1, gone: 1, failed: 3, subscriptions: 5 });
  assertEquals(out.telegram, 'sent', 'Telegram went out before any push');
  const pushes = f.calls.filter((c) => c.kind === 'push').map((c) => c.arg);
  assertEquals(pushes, ['s1', 's1', 's2', 's2', 's3', 's4', 's5']);
  assertEquals(f.calls.filter((c) => c.kind === 'delete').map((c) => c.arg), ['s3']);
  assertEquals(f.calls.filter((c) => c.kind === 'touch').map((c) => c.arg), ['s1']);
});

Deno.test('without VAPID secrets push is skipped and Telegram still goes; a Telegram failure does not stop the push', async () => {
  const noVapid = fake({ subs: [sub('s1')], push: null });
  const a = await runPaid('r', noVapid.deps);
  assertEquals([a.telegram, a.push.subscriptions], ['sent', 0]);
  assert(!noVapid.calls.some((c) => c.kind === 'push'));
  const tgDown = fake({ subs: [sub('s1')], tg: async () => { throw new Error('telegram down'); } });
  const b = await runPaid('r', tgDown.deps);
  assertEquals([b.telegram, b.push.sent], ['failed', 1]);
  const tgNo = fake({ subs: [sub('s1')], tg: async () => ({ ok: false, description: 'Bad Request: chat not found' }) });
  const c = await runPaid('r', tgNo.deps);
  assertEquals([c.telegram, c.push.sent], ['failed', 1]);
  assert(tgNo.calls.some((x) => x.kind === 'log'));
});
