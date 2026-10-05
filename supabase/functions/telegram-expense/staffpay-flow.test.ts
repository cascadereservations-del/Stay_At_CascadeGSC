// deno test --no-check --allow-env telegram-expense/staffpay-flow.test.ts
// SPEC-37: the Finance taps and the transfer screenshot, against a fake database and a fake Telegram. Synthetic data only (public repo).
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { onPayReqPhoto, onPayReqTap, type PayDeps } from './staffpay-flow.ts';

const RID = 'e3700000-0000-4000-8000-0000000000a1';
const FIN = -1001, OPS = -1002;
const lines = [{ kind: 'clean', session_id: 's1', date: '2026-10-02', type: 'turnover', base: 500, transport: 150, amount: 650, guest: 'Ana' }, { kind: 'claim', claim_id: 'c1', date: '2026-10-02', description: 'KitKat', amount: 40, receipt: false }];
const row = (over: Record<string, unknown> = {}) => ({
  id: RID, ref: 'E3700000', status: 'requested', payee_name: 'Honey', lines, total_amount: 690, finance_chat_id: FIN, finance_message_id: 77, ops_chat_id: OPS, ops_message_id: 88,
  paying_by_name: 'Marifel', paying_at: '2026-10-05T07:05:00Z', sent_said_at: null, proof_file_unique_id: null, ...over,
});

type World = { rows: Record<string, any>; rpcs: Array<{ name: string; args: any }>; calls: Array<{ method: string; body: any }>; answers: Array<[string, string | undefined]>; asks: any[]; deletes: any[]; updates: any[]; rpcResult: (args: any) => any; read: string };
function world(rowState: any, rpcResult: (args: any) => any = () => ({ ok: true, status: 'paying' })): World {
  return { rows: { [RID]: rowState }, rpcs: [], calls: [], answers: [], asks: [], deletes: [], updates: [], rpcResult, read: '{}' };
}
function deps(w: World, over: Partial<PayDeps> = {}): PayDeps {
  const db = {
    from(table: string) {
      const q: any = { table, filters: {} as Record<string, unknown>, op: 'select', payload: null };
      q.select = () => q;
      q.eq = (c: string, v: unknown) => { q.filters[c] = v; return q; };
      q.update = (p: unknown) => { q.op = 'update'; q.payload = p; return q; };
      q.delete = () => { q.op = 'delete'; return q; };
      q.maybeSingle = () => {
        if (table !== 'staff_pay_requests') return Promise.resolve({ data: null });
        const hit = Object.values(w.rows).find((r: any) => (!('id' in q.filters) || r.id === q.filters.id) && (!('finance_message_id' in q.filters) || r.finance_message_id === q.filters.finance_message_id) && (!('status' in q.filters) || r.status === q.filters.status));
        return Promise.resolve({ data: hit ?? null });
      };
      q.then = (res: (v: unknown) => unknown) => { if (q.op === 'delete') w.deletes.push({ table, ...q.filters }); if (q.op === 'update') w.updates.push({ table, ...q.filters, payload: q.payload }); return Promise.resolve({ error: null }).then(res); };
      return q;
    },
    rpc(name: string, args: any) { w.rpcs.push({ name, args }); return Promise.resolve({ data: w.rpcResult(args), error: null }); },
  };
  return {
    db, call: (method, body) => { w.calls.push({ method, body }); return Promise.resolve({ ok: true, result: { message_id: 1 } }); },
    answer: (id, text) => { w.answers.push([id, text]); return Promise.resolve(); }, isFinance: (c) => c === FIN, financeOnly: 'FINANCE_ONLY_TEXT', opsChat: String(OPS),
    askProof: (chatId, fromId, rid, text) => { w.asks.push({ chatId, fromId, rid, text }); return Promise.resolve(); },
    photo: () => Promise.resolve({ bytes: new Uint8Array([1, 2, 3, 4]), mime: 'image/jpeg' }), read: () => Promise.resolve(w.read), visionReady: () => true, ...over,
  };
}
const cq = (step: string, chat = FIN) => ({ id: 'cb1', data: `spr:${step}:${RID}`, from: { id: 920000001, first_name: 'Marifel' }, message: { chat: { id: chat }, message_id: 77, photo: [{}] } });
const photoMsg = (over: Record<string, unknown> = {}) => ({ chat: { id: FIN }, message_id: 200, from: { id: 920000001, first_name: 'Marifel' }, photo: [{ file_id: 'small', file_unique_id: 'u-small' }, { file_id: 'big', file_unique_id: 'u-big' }], ...over });
const aw = { id: 'aw1', payload: { flow: 'payreq_proof', from_id: 920000001, rid: RID } };

Deno.test('tap: I\'m paying this calls the pay step with the tapper, answers once, and edits the card caption', async () => {
  const w = world(row(), () => { w.rows[RID] = row({ status: 'paying' }); return { ok: true, status: 'paying' }; });
  await onPayReqTap(deps(w), cq('pay'));
  assertEquals(w.rpcs[0], { name: 'telegram_staff_pay_step_v1', args: { p_request_id: RID, p_step: 'pay', p_actor_tg: 920000001, p_actor_name: 'Marifel', p_proof: null } });
  assertEquals(w.answers, [['cb1', undefined]]);
  const edit = w.calls.find((c) => c.method === 'editMessageCaption')!;
  assertEquals([edit.body.chat_id, edit.body.message_id], [FIN, 77]);
  assert(String(edit.body.caption).startsWith('Marifel is paying Honey ₱690 now'));
  assertEquals('parse_mode' in edit.body, false, 'plain text: no parse_mode');
});

Deno.test('tap from OPS answers FINANCE_ONLY and calls nothing; a bad button changes nothing', async () => {
  const w = world(row());
  await onPayReqTap(deps(w), cq('pay', OPS));
  assertEquals(w.answers, [['cb1', 'FINANCE_ONLY_TEXT']]);
  assertEquals(w.rpcs.length, 0);
  const w2 = world(row());
  await onPayReqTap(deps(w2), { ...cq('pay'), data: 'spr:bogus:xx' });
  assertEquals(w2.rpcs.length, 0);
  assert(String(w2.answers[0][1]).includes('Nothing changed'));
});

Deno.test('tap: Yes, payment sent opens the screenshot question for the tapper', async () => {
  const w = world(row({ status: 'paying' }), () => { w.rows[RID] = row({ status: 'paying', sent_said_at: '2026-10-05T07:10:00Z' }); return { ok: true, status: 'paying' }; });
  await onPayReqTap(deps(w), cq('sent'));
  assertEquals(w.asks.length, 1);
  assertEquals([w.asks[0].chatId, w.asks[0].fromId, w.asks[0].rid], [FIN, 920000001, RID]);
  assert(w.asks[0].text.startsWith('Marifel, send the transfer screenshot here as a photo.'));
});

Deno.test('tap refused by the database: the reason is the answer and nothing is edited', async () => {
  const w = world(row({ status: 'paying' }), () => ({ ok: false, reason: 'money_may_be_sent', status: 'paying' }));
  await onPayReqTap(deps(w), cq('cancel'));
  assert(String(w.answers[0][1]).startsWith('Payment was marked as sent, so it cannot be cancelled here.'));
  assertEquals(w.calls.length, 0);
});

Deno.test('tap: cancel edits the card and tells OPS as a reply to the request post, then closes any screenshot question', async () => {
  const w = world(row(), () => { w.rows[RID] = row({ status: 'cancelled', cancelled_by_name: 'Marifel', cancelled_at: '2026-10-05T07:20:00Z' }); return { ok: true, status: 'cancelled' }; });
  await onPayReqTap(deps(w), cq('cancel'));
  const ops = w.calls.find((c) => c.method === 'sendMessage')!;
  assertEquals([ops.body.chat_id, ops.body.reply_to_message_id, ops.body.allow_sending_without_reply], [OPS, 88, true]);
  assert(String(ops.body.text).startsWith("Finance cancelled Honey's payment request for ₱690"));
  assertEquals(w.deletes.length, 1);
});

Deno.test('screenshot while the question is open: a matching read settles, the card says PAID, the reply and the OPS post follow', async () => {
  const paid = row({ status: 'paid', paid_by_name: 'Marifel', paid_at: '2026-10-05T07:12:00Z', proof_verdict: 'match', proof_reference: 'AB1234567890', sent_said_at: '2026-10-05T07:10:00Z' });
  const w = world(row({ status: 'paying', sent_said_at: '2026-10-05T07:10:00Z' }), () => { w.rows[RID] = paid; return { ok: true, status: 'paid', verdict: 'match' }; });
  w.read = JSON.stringify({ amount: 690, reference: 'ab 1234567890', status: 'success', confidence: 0.9 });
  const handled = await onPayReqPhoto(deps(w), photoMsg(), aw);
  assertEquals(handled, true);
  const proof = w.rpcs[0].args;
  assertEquals([w.rpcs[0].name, proof.p_step, proof.p_proof.verdict, proof.p_proof.reference, proof.p_proof.file_unique_id, proof.p_proof.file_id], ['telegram_staff_pay_step_v1', 'proof', 'match', 'AB1234567890', 'u-big', 'big']);
  assertEquals(proof.p_proof.sha256.length, 64);
  const sends = w.calls.filter((c) => c.method === 'sendMessage');
  assert(String(sends[0].body.text).startsWith('✅ This matches ₱690.'));
  assertEquals(sends[0].body.reply_to_message_id, 200);
  assertEquals(sends[1].body.chat_id, OPS);
  assert(String(sends[1].body.text).startsWith('Honey has been paid ₱690. Marifel sent it'));
  assert(w.calls.some((c) => c.method === 'editMessageCaption' && String(c.body.caption).startsWith('PAID.')));
  assert(w.deletes.length >= 1, 'the open question is closed');
});

Deno.test('screenshot with the wrong amount: not marked paid, Finance is offered Amount is right and Send another, OPS hears nothing', async () => {
  const w = world(row({ status: 'paying', sent_said_at: '2026-10-05T07:10:00Z' }), () => ({ ok: true, status: 'paying', verdict: 'mismatch' }));
  w.read = JSON.stringify({ amount: 600, reference: 'ZZ112233', status: 'success' });
  assertEquals(await onPayReqPhoto(deps(w), photoMsg(), aw), true);
  const sends = w.calls.filter((c) => c.method === 'sendMessage');
  assertEquals(sends.length, 1);
  assert(String(sends[0].body.text).startsWith('The screenshot shows ₱600, but Honey\'s request is ₱690'));
  assertEquals(sends[0].body.reply_markup.inline_keyboard[0].map((b: any) => b.callback_data), [`spr:ovr:${RID}`, `spr:sent:${RID}`]);
});

Deno.test('an unreadable screenshot (no vision key) is stored as unread and offers Amount is right', async () => {
  const w = world(row({ status: 'paying', sent_said_at: '2026-10-05T07:10:00Z' }), () => ({ ok: true, status: 'paying', verdict: 'unread' }));
  assertEquals(await onPayReqPhoto(deps(w, { visionReady: () => false }), photoMsg(), aw), true);
  assertEquals(w.rpcs[0].args.p_proof.verdict, 'unread');
  assert(String(w.calls.find((c) => c.method === 'sendMessage')!.body.text).includes('could not be read automatically'));
});

Deno.test('a second Finance member replying to the paying card is a proof too, so it never falls into receipt OCR; a photo that replies to nothing is a receipt', async () => {
  const w = world(row({ status: 'paying', sent_said_at: '2026-10-05T07:10:00Z' }), () => ({ ok: true, status: 'paying', verdict: 'mismatch' }));
  assertEquals(await onPayReqPhoto(deps(w), photoMsg({ reply_to_message: { message_id: 77 } }), null), true);
  assertEquals(w.rpcs.length, 1);
  const w2 = world(row({ status: 'paying', sent_said_at: '2026-10-05T07:10:00Z' }));
  assertEquals(await onPayReqPhoto(deps(w2), photoMsg(), null), false, 'an ordinary receipt');
  assertEquals(await onPayReqPhoto(deps(w2), photoMsg({ reply_to_message: { message_id: 999 } }), null), false, 'a reply to some other message');
  const w3 = world(row({ status: 'requested' }));
  assertEquals(await onPayReqPhoto(deps(w3), photoMsg({ reply_to_message: { message_id: 77 } }), null), false, 'a card that is not paying');
});

Deno.test('a photo in OPS is never ours; a duplicate screenshot is refused in words; a non-image file keeps the question open', async () => {
  const w = world(row({ status: 'paying', sent_said_at: '2026-10-05T07:10:00Z' }), () => ({ ok: false, reason: 'duplicate_proof', other_ref: 'WXYZ1234' }));
  assertEquals(await onPayReqPhoto(deps(w), photoMsg({ chat: { id: OPS } }), aw), false);
  assertEquals(w.rpcs.length, 0);
  assertEquals(await onPayReqPhoto(deps(w), photoMsg(), aw), true);
  assertEquals(String(w.calls.find((c) => c.method === 'sendMessage')!.body.text), 'This screenshot was already used for request WXYZ1234, so nothing changed. Send the screenshot for this payment.');
  const w2 = world(row({ status: 'paying', sent_said_at: '2026-10-05T07:10:00Z' }));
  assertEquals(await onPayReqPhoto(deps(w2), { chat: { id: FIN }, message_id: 5, from: { id: 920000001 }, document: { file_id: 'd', mime_type: 'application/pdf' } }, aw), true);
  assertEquals(w2.deletes.length, 0, 'the question stays open');
  assert(String(w2.calls[0].body.text).startsWith('Send the transfer screenshot as a photo.'));
});

Deno.test('a screenshot for a request that is no longer paying is refused and closes the stale question', async () => {
  const w = world(row({ status: 'cancelled' }));
  assertEquals(await onPayReqPhoto(deps(w), photoMsg(), aw), true);
  assertEquals(w.rpcs.length, 0);
  assertEquals(w.deletes.length, 1);
});
