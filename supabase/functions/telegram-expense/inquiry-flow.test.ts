// deno test --no-check --allow-env telegram-expense/inquiry-flow.test.ts
// SPEC-38: the request taps against an in-memory telegram_pending and recording fakes for Telegram, Cassy, Messenger, the e-mail relay
// and the RPCs. Synthetic names, numbers and ids only (public repo).
import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { type Deps, onInquiryReason, onIqTap, sendRequests, stripPreview } from './inquiry-flow.ts';
import { deliverToGuest, type SendIO, type Thread } from './inquiry-send.ts';
import { IQ, type InquiryView } from '../_shared/cascade-core/inquiry.ts';

const FIN = '-100111', OPS = '-100222';
const ID = '00a49c5e-1111-4222-8333-444455556666';
const PID = '0b9f2c1e-7a4d-4e1b-9c3a-5d6e7f8a9b01';
const NOW = Date.parse('2026-10-05T01:15:00Z'); // 9:15 am Manila
const view = (o: Partial<InquiryView> = {}): InquiryView => ({
  id: ID, ref: '00A49C5E', guest_name: 'Ana Cruz', guest_email: 'ana@example.com', guest_phone: '0917 123 4567', checkin_date: '2026-11-30', checkout_date: '2026-12-04', nights: 4, pax: 2,
  total_amount: 12400, deposit_amount: 6200, notes: 'via Messenger (psid 1)', submitted_at: '2026-10-04T14:40:00Z', status: 'pending', has_receipt: false,
  hold_expires_at: null, held_by: null, held_at: null, conflict: false, ...o,
});
const THREAD = (over: Partial<Thread> = {}): Thread => ({ psid: '555', guest_name: 'Ana Cruz', booking_flow: { step: 'await_receipt', lang: 'en', booking_id: ID, hold: false }, history: [
  { role: 'guest', text: 'book Nov 30', at: '2026-10-04T14:30:00Z' }, { role: 'guest', text: 'pwede po early check-in?', at: new Date(NOW - 3_600_000).toISOString() }], ...over });

type Rec = { sent: any[]; edits: any[]; answers: any[]; fwd: any[]; asks: any[]; fb: any[]; relay: any[]; rpcs: any[]; updates: any[]; asked: any[] };
function setup(o: { views?: InquiryView[]; thread?: Thread | null; decide?: (a: any) => any; fb?: boolean; relay?: boolean; fwd?: boolean } = {}) {
  const r: Rec = { sent: [], edits: [], answers: [], fwd: [], asks: [], fb: [], relay: [], rpcs: [], updates: [], asked: [] };
  const pending: any[] = [];
  let views = o.views ?? [view()];
  const q = (table: string, op: string, arg?: any) => {
    const f: Array<(x: any) => boolean> = [];
    const api: any = {
      eq: (c: string, v: unknown) => { f.push((x) => String(x[c]) === String(v)); return api; },
      select: () => api,
      maybeSingle: async () => { const hit = pending.filter((x) => f.every((g) => g(x)))[0]; if (op === 'delete' && hit) pending.splice(pending.indexOf(hit), 1); return { data: hit ?? null }; },
      then: (res: any) => { if (table === 'telegram_pending' && op === 'delete') for (const x of pending.filter((y) => f.every((g) => g(y)))) pending.splice(pending.indexOf(x), 1); if (op === 'update') r.updates.push({ table, patch: arg, f: f.length }); return Promise.resolve({ error: null }).then(res); },
    };
    return api;
  };
  const db = {
    from: (table: string) => ({
      insert: (row: any) => { if (table === 'telegram_pending') pending.push({ id: row.id ?? PID, ...row }); return Promise.resolve({ error: null }); },
      select: () => q(table, 'select'), delete: () => q(table, 'delete'), update: (p: any) => q(table, 'update', p),
    }),
    rpc: async (fn: string, args: any) => {
      r.rpcs.push({ fn, args });
      if (fn === 'telegram_inquiry_view_v1') return { data: args.p_booking_id ? views.filter((v) => v.id === args.p_booking_id) : views.filter((v) => v.status === 'pending' && !v.has_receipt) };
      if (fn === 'telegram_inquiry_decide_v1') return { data: o.decide ? o.decide(args) : { ok: true, outcome: args.p_action === 'hold' ? 'held' : 'declined', already_processed: false, expires_at: new Date(NOW + 86_400_000).toISOString() } };
      if (fn === 'telegram_inquiry_message_logged_v1') return { data: { ok: true, inserted: true } };
      return { data: null };
    },
  };
  const th = o.thread === undefined ? THREAD() : o.thread;
  const io: SendIO = {
    db, thread: async () => th,
    fbSend: async (psid, text, ha) => { r.fb.push({ psid, text, ha }); return o.fb !== false; },
    relay: async (m) => { r.relay.push(m); return o.relay !== false; },
    token: async (_id, exp) => `tok-${exp}`, now: () => NOW,
  };
  const d: Deps = {
    db, financeChat: FIN, opsChat: OPS,
    send: async (chatId, text, extra) => { r.sent.push({ chatId, text, extra }); return { ok: true, result: { message_id: 700 + r.sent.length } }; },
    edit: async (chatId, mid, text, rm) => { r.edits.push({ chatId, mid, text, rm }); return { ok: true }; },
    answer: async (id, text) => { r.answers.push({ id, text }); return {}; },
    forward: async (u) => { r.fwd.push(u); return o.fwd !== false; },
    ask: async (chatId, fromId, flow, refs, text) => { r.asked.push({ chatId, fromId, flow, refs, text }); },
    io, now: () => NOW, rateToday: async () => null,
  };
  return { d, r, pending, setViews: (v: InquiryView[]) => { views = v; } };
}
const card = (extra: string) => `📬 BOOKING · Request from Ana Cruz · not paid yet\n\nAna Cruz asked for Mon 30 Nov to Fri 4 Dec.\n💬 Guest wrote: "pwede po early check-in?"${extra}`;
const cq = (data: string, over: Record<string, unknown> = {}, text = card('')) => ({ id: 'cb1', data, from: { id: 907000001, first_name: 'Lloyd' }, message: { chat: { id: Number(FIN) }, message_id: 900, text, reply_markup: { inline_keyboard: [[{ text: 'x', callback_data: 'y' }]] } }, ...over });
const btns = (rm: any): string[] => (rm?.inline_keyboard ?? []).flat().map((b: any) => b.callback_data).filter((x: unknown): x is string => typeof x === 'string'); // url buttons have no callback_data

Deno.test('Hold, first tap: the preview carries the exact held line and channel, nothing is written', async () => {
  const { d, r } = setup();
  await onIqTap(d, cq(IQ.hold(ID)));
  assertEquals(r.rpcs.map((x) => x.fn).filter((f) => f === 'telegram_inquiry_decide_v1'), []);
  assertEquals(r.fb.length + r.relay.length, 0);
  const e = r.edits[0];
  assertStringIncludes(e.text, '➖➖➖➖');
  assertStringIncludes(e.text, '✅ Hold for Ana until Tue 6 Oct, 9:15 am?');
  assertStringIncludes(e.text, 'will receive, on Messenger:\n📨 ⤵\nAna, our host has set Nov 30 to Dec 4 aside for you until Tue 6 Oct, 9:15 am, Manila time. The ₱6,200 reservation fee secures the stay');
  assertStringIncludes(e.text, 'This request has no timer today');
  assertEquals(btns(e.rm), [IQ.holdok(ID), IQ.back(ID)]);
  assertEquals(r.answers.length, 1);
});

Deno.test('Hold and send: one named RPC call, the held line to Messenger, an audit row, the card, and a money-free OPS line', async () => {
  const { d, r } = setup({ views: [view({ held_at: '2026-10-05T01:15:00Z', held_by: 'Lloyd', hold_expires_at: new Date(NOW + 86_400_000).toISOString() })] });
  await onIqTap(d, cq(IQ.holdok(ID)));
  const dec = r.rpcs.find((x) => x.fn === 'telegram_inquiry_decide_v1')!;
  assertEquals(dec.args, { p_telegram_user_id: 907000001, p_booking_id: ID, p_action: 'hold', p_reason_code: null, p_hold_hours: 24, p_actor_name: 'Lloyd' });
  assertEquals(r.fb.length, 1);
  assertEquals(r.fb[0].psid, '555');
  assertEquals(r.fb[0].ha, false); // the guest wrote an hour ago: plain RESPONSE
  assertStringIncludes(r.fb[0].text, 'our host has set Nov 30 to Dec 4 aside for you');
  const log = r.rpcs.find((x) => x.fn === 'telegram_inquiry_message_logged_v1')!;
  assertEquals([log.args.p_purpose, log.args.p_channel, log.args.p_delivered, log.args.p_idempotency_key, log.args.p_actor_name], ['hold', 'messenger', true, `tg-inquiry-msg:hold:${ID}`, 'Lloyd']);
  const e = r.edits.at(-1)!;
  assertStringIncludes(e.text, '✅ Held for Ana until Tue 6 Oct, 9:15 am, by Lloyd at 9:15 am. Sent to Ana on Messenger.');
  assertEquals(btns(e.rm).filter((x: string) => x.startsWith('iq:')), [IQ.dec(ID), IQ.paid(ID), IQ.draft(ID)]); // Hold drops off once held; SPEC-44 Paid stays
  const ops = r.sent.find((s) => String(s.chatId) === OPS)!;
  assertStringIncludes(ops.text, "Ana's dates, Nov 30 to Dec 4, are held until Tue 6 Oct, 9:15 am (Lloyd)");
  assert(!ops.text.includes('₱') && !ops.text.includes('0917'));
  // the Messenger thread follows the hold: new expiry and a fresh receipt token, and Cassy knows what was said
  const patched = r.updates.filter((u) => u.table === 'concierge_threads');
  assert(patched.some((u) => u.patch.booking_flow?.hold_expires_at && String(u.patch.booking_flow.receipt_token).startsWith('tok-')));
  assert(patched.some((u) => u.patch.history?.at(-1)?.role === 'bot'));
});

Deno.test('Hold and send, second tap or re-delivery: already held, nothing is sent again', async () => {
  const { d, r } = setup({ decide: () => ({ ok: true, outcome: 'held', already_processed: true, expires_at: new Date(NOW + 86_400_000).toISOString() }), views: [view({ held_by: 'Lloyd', held_at: '2026-10-05T01:00:00Z' })] });
  await onIqTap(d, cq(IQ.holdok(ID)));
  assertEquals(r.fb.length + r.relay.length, 0);
  assertEquals(r.rpcs.filter((x) => x.fn === 'telegram_inquiry_message_logged_v1').length, 0);
  assertStringIncludes(r.edits.at(-1)!.text, 'Already held until Tue 6 Oct, 9:15 am by Lloyd');
  assertEquals(r.sent.length, 0);
});

Deno.test('Hold when Messenger refuses and there is no e-mail: the card says so, shows the text and the phone, and OPS is told Finance has it', async () => {
  const { d, r } = setup({ fb: false, views: [view({ guest_email: null })] });
  await onIqTap(d, cq(IQ.holdok(ID)));
  const e = r.edits.at(-1)!;
  assertStringIncludes(e.text, 'Held for Ana');
  assertStringIncludes(e.text, 'did not reach Ana (Messenger refused and there is no e-mail). Send it by SMS to 0917 123 4567:\n📨 ⤵\nAna, our host');
  assert(btns(e.rm).includes('tpl:copy')); // 📄 Show as text
  const log = r.rpcs.find((x) => x.fn === 'telegram_inquiry_message_logged_v1')!;
  assertEquals([log.args.p_channel, log.args.p_delivered], ['messenger', false]);
  assertStringIncludes(r.sent.find((s) => String(s.chatId) === OPS)!.text, 'Finance is sending the message by hand');
});

Deno.test('Hold: Messenger refused with an e-mail on file falls back to the relay', async () => {
  const { d, r } = setup({ fb: false });
  await onIqTap(d, cq(IQ.holdok(ID)));
  assertEquals(r.relay.length, 1);
  assertEquals(r.relay[0].guest_email, 'ana@example.com');
  assertEquals(r.relay[0].subject, 'Your Cascade Hideaway request 00A49C5E');
  const log = r.rpcs.find((x) => x.fn === 'telegram_inquiry_message_logged_v1')!;
  assertEquals([log.args.p_channel, log.args.p_delivered], ['email', true]);
  assertStringIncludes(r.edits.at(-1)!.text, 'Sent to Ana on e-mail.');
});

Deno.test('a refused tap (no tapper id, or a conflict) keeps the buttons and sends nothing', async () => {
  for (const reason of ['no_tapper', 'conflict']) {
    const { d, r } = setup({ decide: () => ({ ok: false, reason }) });
    await onIqTap(d, cq(IQ.holdok(ID)));
    assertEquals(r.fb.length + r.relay.length + r.sent.length, 0, reason);
    const e = r.edits.at(-1)!;
    assert(btns(e.rm).includes(IQ.hold(ID)) && btns(e.rm).includes(IQ.dec(ID)), `${reason}: buttons stay`);
    assertStringIncludes(e.text, reason === 'conflict' ? 'no longer free' : 'Nothing changed');
  }
});

Deno.test('a request closed since the card was drawn: the card says why and has no buttons', async () => {
  for (const [v, word] of [[view({ status: 'cancelled' }), 'cancelled'], [view({ status: 'expired' }), 'expired'], [view({ has_receipt: true }), 'receipt card']] as const) {
    const { d, r } = setup({ views: [v] });
    await onIqTap(d, cq(IQ.holdok(ID)));
    assertStringIncludes(r.edits.at(-1)!.text, word);
    assertEquals(r.edits.at(-1)!.rm, undefined);
    assertEquals(r.rpcs.filter((x) => x.fn === 'telegram_inquiry_decide_v1').length, 0);
  }
});

Deno.test('Decline: reasons, then a preview of the exact line, then one RPC call, the line, the flow ends, OPS is told', async () => {
  const { d, r } = setup();
  await onIqTap(d, cq(IQ.dec(ID)));
  assertEquals(btns(r.edits[0].rm).filter((x: string) => x.startsWith('iq:dr:')).length, 6);
  await onIqTap(d, cq(IQ.dr('taken', ID)));
  assertStringIncludes(r.edits[1].text, "❌ Decline Ana's request (dates taken)?");
  assertStringIncludes(r.edits[1].text, "We're sorry that Nov 30 to Dec 4 is no longer open");
  assertEquals(btns(r.edits[1].rm), [IQ.dx('taken', ID), IQ.back(ID)]);
  await onIqTap(d, cq(IQ.dx('taken', ID)));
  const dec = r.rpcs.filter((x) => x.fn === 'telegram_inquiry_decide_v1');
  assertEquals(dec.length, 1);
  assertEquals([dec[0].args.p_action, dec[0].args.p_reason_code], ['decline', 'taken']);
  assertEquals(r.fb.length, 1);
  assertStringIncludes(r.fb[0].text, 'thank you for choosing Cascade Hideaway');
  assert(r.updates.some((u) => u.table === 'concierge_threads' && u.patch.booking_flow?.step === 'cancelled'));
  assertEquals(r.rpcs.find((x) => x.fn === 'telegram_inquiry_message_logged_v1')!.args.p_idempotency_key, `tg-inquiry-msg:decline:${ID}`);
  const e = r.edits.at(-1)!;
  assertStringIncludes(e.text, '❌ Declined by Lloyd at 9:15 am (dates taken). Calendar freed, ledger row voided. Sent to Ana on Messenger.');
  assertEquals(e.rm, undefined);
  assertStringIncludes(r.sent.find((s) => String(s.chatId) === OPS)!.text, "Ana's request for Nov 30 to Dec 4 was declined by Lloyd");
});

Deno.test('Decline as Duplicate or test sends nothing to the guest', async () => {
  const { d, r } = setup();
  await onIqTap(d, cq(IQ.dr('dup', ID)));
  assertStringIncludes(r.edits[0].text, 'without a message to the guest');
  await onIqTap(d, cq(IQ.dx('dup', ID)));
  assertEquals(r.fb.length + r.relay.length, 0);
  assertEquals(r.rpcs.filter((x) => x.fn === 'telegram_inquiry_message_logged_v1').length, 0);
  assertStringIncludes(r.edits.at(-1)!.text, 'No message was sent to the guest.');
  assertEquals(r.updates.filter((u) => u.table === 'concierge_threads').length, 0);
});

Deno.test('Decline twice: the second answer is already_processed and sends nothing', async () => {
  const { d, r } = setup({ decide: () => ({ ok: true, outcome: 'declined', already_processed: true }) });
  await onIqTap(d, cq(IQ.dx('taken', ID)));
  assertEquals(r.fb.length + r.relay.length, 0);
  assertStringIncludes(r.edits.at(-1)!.text, 'Already declined');
});

Deno.test('Decline > Other opens the question and restores the card; the typed reason goes to Cassy', async () => {
  const { d, r } = setup();
  await onIqTap(d, cq(IQ.dr('other', ID), {}, card('') + '\n\n➖➖➖➖\nWhy decline?'));
  assertEquals(r.asked.length, 1);
  assertEquals([r.asked[0].flow, r.asked[0].refs.booking_id, r.asked[0].refs.card_mid], ['inquiry_reason', ID, 900]);
  assertStringIncludes(r.asked[0].text, 'the guest never sees your words');
  assert(!r.edits[0].text.includes('Why decline?'), 'the card is restored');
  await onInquiryReason(d, { chat: { id: Number(FIN) }, from: { id: 907000001 }, message_id: 950 }, { booking_id: ID, card_mid: 900 }, 'guest asked for a party');
  assertEquals(r.fwd[0].message.text, `cassy inquiry: decline ${ID} ||| guest asked for a party`);
  assertEquals(r.fwd[0].message.message_id, 900);
  assertEquals(r.rpcs.filter((x) => x.fn === 'telegram_inquiry_decide_v1').length, 0, 'nothing is declined until the draft is sent');
});

Deno.test('Cassy reply tap: toast at once, then the synthetic request goes to Cassy', async () => {
  const { d, r } = setup();
  await onIqTap(d, cq(IQ.draft(ID)));
  assertEquals(r.answers.length, 1);
  assertEquals(r.answers[0].text, 'Cassy is drafting…');
  assertEquals(r.fwd[0].message.text, `cassy inquiry: reply ${ID}`);
  assertEquals(r.fwd[0].message.message_id, 900);
  const down = setup({ fwd: false });
  await onIqTap(down.d, cq(IQ.draft(ID)));
  assertStringIncludes(down.r.sent[0].text, 'Cassy could not be reached');
});

const seedReply = (p: ReturnType<typeof setup>, over: Record<string, unknown> = {}, chat = FIN) => p.pending.push({ id: PID, chat_id: Number(chat), kind: 'inquiry_reply', expires_at: new Date(NOW + 3_600_000).toISOString(), payload: { purpose: 'reply', booking_id: ID, text: 'Ana, early check-in is welcome from 12 noon when no guest checks out that day.', ops_ok: true, ...over } });

Deno.test('Send a Cassy reply: one winner, one audit row keyed by the draft, the card says who sent it; a second tap sends nothing', async () => {
  const p = setup(); seedReply(p);
  await onIqTap(p.d, cq(IQ.send(PID), {}, '✍️ Reply for Ana'));
  assertEquals(p.r.fb.length, 1);
  assertStringIncludes(p.r.fb[0].text, 'early check-in is welcome');
  assertEquals(p.r.rpcs.find((x) => x.fn === 'telegram_inquiry_message_logged_v1')!.args.p_idempotency_key, `tg-inquiry-msg:${PID}`);
  assertStringIncludes(p.r.edits.at(-1)!.text, '📤 Sent to Ana on Messenger by Lloyd at 9:15 am.');
  await onIqTap(p.d, cq(IQ.send(PID), { id: 'cb2' }, '✍️ Reply for Ana'));
  assertEquals(p.r.fb.length, 1);
  assertEquals(p.r.answers.at(-1)!.text, 'That reply was already sent or has expired. Nothing was sent twice.');
});

Deno.test('Send from OPS: a draft with money is refused and kept; a money-free draft is sent', async () => {
  const p = setup(); seedReply(p, { ops_ok: false, text: 'Early check-in is ₱100 per hour before noon.' }, OPS);
  await onIqTap(p.d, cq(IQ.send(PID), { message: { chat: { id: Number(OPS) }, message_id: 901, text: 'draft' } }));
  assertEquals(p.r.fb.length, 0);
  assertStringIncludes(String(p.r.answers.at(-1)!.text), 'mentions amounts');
  assertEquals(p.pending.length, 1, 'the draft is not used up by the refused tap');
  const q = setup(); seedReply(q, {}, OPS);
  await onIqTap(q.d, cq(IQ.send(PID), { message: { chat: { id: Number(OPS) }, message_id: 901, text: 'draft' } }));
  assertEquals(q.r.fb.length, 1);
});

const OPS_CHAT_MSG = { chat: { id: Number(OPS) }, message_id: 901, text: 'draft' };
const SHAPES = /\d{4}[ -]?\d{3}|\d{7,}|@[\w-]+\.|ana@/; // a phone-like digit run or an e-mail

Deno.test('Send from OPS when delivery fails: the OPS card has no phone, e-mail or detail, and Finance gets the SMS fallback card', async () => {
  const p = setup({ fb: false, relay: false });
  seedReply(p, {}, OPS);
  await onIqTap(p.d, cq(IQ.send(PID), { message: OPS_CHAT_MSG }));
  const ops = p.r.edits.at(-1)!;
  assertStringIncludes(ops.text, 'did not reach Ana');
  assertStringIncludes(ops.text, 'Finance has been sent the text');
  assert(!SHAPES.test(ops.text), ops.text);
  assert(!ops.text.includes('early check-in is welcome'), 'OPS card does not repeat the draft');
  assertEquals(ops.rm, undefined);
  const fin = p.r.sent.find((s) => String(s.chatId) === FIN)!;
  assertStringIncludes(fin.text, 'Send it by SMS to 0917 123 4567:');
  assertStringIncludes(fin.text, 'early check-in is welcome');
  assertStringIncludes(fin.text, 'Tapped Send in the OPS group: Lloyd');
  assertEquals(p.r.sent.filter((s) => String(s.chatId) === OPS).length, 0);
});

Deno.test('Send from OPS when delivery fails and Finance cannot be reached: OPS is told to tell Finance, still no phone', async () => {
  const p = setup({ fb: false, relay: false });
  p.d.send = async () => { throw new Error('telegram down'); };
  seedReply(p, {}, OPS);
  await onIqTap(p.d, cq(IQ.send(PID), { message: OPS_CHAT_MSG }));
  const t = p.r.edits.at(-1)!.text;
  assertStringIncludes(t, 'Tell Finance');
  assert(!SHAPES.test(t), t);
});

Deno.test('Send from Finance when delivery fails: the card keeps the SMS fallback with the phone', async () => {
  const p = setup({ fb: false, relay: false });
  seedReply(p);
  await onIqTap(p.d, cq(IQ.send(PID), {}, '✍️ Reply for Ana'));
  const t = p.r.edits.at(-1)!.text;
  assertStringIncludes(t, 'Send it by SMS to 0917 123 4567:');
  assertStringIncludes(t, 'early check-in is welcome');
});

Deno.test('Hold preview names the later of now+24h and an existing site hold, as the RPC does', async () => {
  const later = new Date(NOW + 48 * 3_600_000).toISOString();
  const { d, r } = setup({ views: [view({ hold_expires_at: later })] });
  await onIqTap(d, cq(IQ.hold(ID)));
  assertStringIncludes(r.edits[0].text, '✅ Hold for Ana until Wed 7 Oct, 9:15 am?');
});

Deno.test('Send a drafted decline: the RPC declines with Other first and the message goes only then; a refused tap puts the draft back', async () => {
  const p = setup(); seedReply(p, { purpose: 'decline', reason_code: 'other', reason_private: 'party', text: 'Ana, thank you for your request. We are unable to accept this stay.' });
  await onIqTap(p.d, cq(IQ.send(PID), {}, "❌ Decline Ana's request with this message?"));
  const dec = p.r.rpcs.find((x) => x.fn === 'telegram_inquiry_decide_v1')!;
  assertEquals([dec.args.p_action, dec.args.p_reason_code], ['decline', 'other']);
  assertEquals(dec.args.p_actor_name, 'Lloyd', 'the tapper is named on the audit row (D-302.2)');
  assertEquals(p.r.fb.length, 1);
  assertStringIncludes(p.r.edits.at(-1)!.text, 'Declined by Lloyd');
  assert(!JSON.stringify(p.r.rpcs).includes('party'), 'the private reason never reaches an RPC');
  const q = setup({ decide: () => ({ ok: false, reason: 'no_tapper' }) }); seedReply(q, { purpose: 'decline', text: 'Ana, thank you for your request.' });
  await onIqTap(q.d, cq(IQ.send(PID), {}, "❌ Decline Ana's request with this message?"));
  assertEquals(q.r.fb.length, 0);
  assertEquals(q.pending.length, 1, 'restored for another try');
  assertStringIncludes(q.r.edits.at(-1)!.text, 'tap again');
});

Deno.test('Discard deletes the draft; Back redraws the card from the original text and the live view', async () => {
  const p = setup(); seedReply(p);
  await onIqTap(p.d, cq(IQ.drop(PID)));
  assertEquals(p.pending.length, 0);
  assertEquals(p.r.edits[0].text, '🗑 Discarded. Nothing was sent.');
  const withPreview = card('') + '\n\n➖➖➖➖\n✅ Hold for Ana until Tue 6 Oct, 9:15 am?\n📨 ⤵\nline';
  await onIqTap(p.d, cq(IQ.back(ID), {}, withPreview));
  assertEquals(p.r.edits[1].text, card(''));
  assertEquals(stripPreview(withPreview), card(''));
  assert(btns(p.r.edits[1].rm).includes(IQ.hold(ID)) && btns(p.r.edits[1].rm).includes(IQ.draft(ID)));
});

Deno.test('a malformed button is refused with a toast and changes nothing', async () => {
  const { d, r } = setup();
  await onIqTap(d, cq('iq:hold:not-a-uuid'));
  assertEquals(r.answers[0].text, 'That button is not valid. Nothing changed.');
  assertEquals(r.edits.length + r.rpcs.length, 0);
});

Deno.test('/requests: nothing waiting says so; with requests each is its own card, OPS gets the money-free card', async () => {
  const none = setup({ views: [] });
  await sendRequests(none.d, FIN);
  assertEquals(none.r.sent[0].text, 'No booking requests are waiting for payment.');
  const fin = setup({ views: [view(), view({ id: '11111111-1111-4222-8333-444455556666', ref: '11111111', guest_name: 'Ben Reyes' })] });
  await sendRequests(fin.d, FIN);
  assertEquals(fin.r.sent.length, 2);
  assertStringIncludes(fin.r.sent[0].text, '💰 Total ₱12,400');
  assert(btns(fin.r.sent[0].extra.reply_markup).includes(IQ.hold(ID)));
  const ops = setup({ views: [view()] });
  await sendRequests(ops.d, OPS);
  assert(!ops.r.sent[0].text.includes('₱') && !ops.r.sent[0].text.includes('0917') && !ops.r.sent[0].text.includes('ana@example.com'));
  assertEquals(btns(ops.r.sent[0].extra.reply_markup), [IQ.draft(ID)]);
});

Deno.test('deliverToGuest: card_only when there is no thread and no e-mail; a site guest gets the relay; the log records every attempt', async () => {
  const none = setup({ thread: null, views: [view({ guest_email: null })] });
  const out = await deliverToGuest(none.d.io, view({ guest_email: null }), 'hello', { purpose: 'reply' });
  assertEquals(out, { channel: 'card_only', delivered: false, detail: 'no channel' });
  const site = setup({ thread: null });
  const o2 = await deliverToGuest(site.d.io, view(), 'hello', { purpose: 'reply' });
  assertEquals([o2.channel, o2.delivered, site.r.relay.length, site.r.fb.length], ['email', true, 1, 0]);
  const old = setup({ thread: THREAD({ history: [{ role: 'guest', text: 'hi', at: new Date(NOW - 30 * 3_600_000).toISOString() }] }) });
  await deliverToGuest(old.d.io, view(), 'hello', { purpose: 'reply' });
  assertEquals(old.r.fb[0].ha, true); // 30 h since the guest wrote: the HUMAN_AGENT tag
});
