// deno test --no-check -A telegram-expense/spec44.test.ts
// SPEC-44 (s76): ✅ Paid – confirm on the request card and the receipt card's Confirm, both on telegram_confirm_direct_booking_v1.
// Recording fakes for Telegram and the database. Synthetic names, numbers and ids only (public repo).
import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { type Deps, NO_ANSWER, onInquiryPaid, onIqTap, onReceiptConfirm } from './inquiry-flow.ts';
import { answersOpen, refusal } from './reply.ts';
import type { SendIO } from './inquiry-send.ts';
import { confirmedLine, confirmRefusal, CONFIRM_RPC, IQ, type InquiryView, maskRef, PAID_AGAIN, paidPrompt, parsePaidReply } from '../_shared/cascade-core/inquiry.ts';

const FIN = '-100111', OPS = '-100222';
const ID = '00a49c5e-1111-4222-8333-444455556666';
const CMP = '0c0c0c0c-2222-4333-8444-555566667777';
const CAND = '0d0d0d0d-3333-4444-8555-666677778888';
const PID = '0b9f2c1e-7a4d-4e1b-9c3a-5d6e7f8a9b01';
const NOW = Date.parse('2026-10-08T01:15:00Z');
const REF = '9876543210123';
const view = (o: Partial<InquiryView> = {}): InquiryView => ({
  id: ID, ref: '00A49C5E', guest_name: 'Ana Cruz', guest_email: 'ana@example.com', guest_phone: '0917 123 4567', checkin_date: '2026-11-30', checkout_date: '2026-12-04', nights: 4, pax: 2,
  total_amount: 12400, deposit_amount: 6200, notes: 'via Messenger (psid 1)', submitted_at: '2026-10-07T14:40:00Z', status: 'pending', has_receipt: false,
  hold_expires_at: null, held_by: null, held_at: null, conflict: false, ...o,
});
const CARD = '📬 BOOKING · Request from Ana Cruz · not paid yet\n\nAna Cruz asked for Mon 30 Nov to Fri 4 Dec.';

// deno-lint-ignore no-explicit-any
function setup(o: { views?: InquiryView[]; confirm?: (a: any) => any; rows?: Record<string, any>; rpcError?: unknown; rpcThrows?: boolean } = {}) {
  // deno-lint-ignore no-explicit-any
  const r = { sent: [] as any[], edits: [] as any[], captions: [] as any[], answers: [] as any[], asked: [] as any[], rpcs: [] as any[] };
  const rows = o.rows ?? {};
  const db = {
    from: (table: string) => {
      const api = { select: () => api, eq: () => api, maybeSingle: async () => ({ data: rows[table] ?? null }) };
      return api;
    },
    // deno-lint-ignore no-explicit-any
    rpc: async (fn: string, args: any) => {
      r.rpcs.push({ fn, args });
      if (fn === 'telegram_inquiry_view_v1') return { data: (o.views ?? [view()]).filter((v) => v.id === args.p_booking_id) };
      if (fn === CONFIRM_RPC && o.rpcThrows) throw new Error('fetch failed');
      if (fn === CONFIRM_RPC && o.rpcError) return { data: null, error: o.rpcError };
      if (fn === CONFIRM_RPC) return { data: o.confirm ? o.confirm(args) : { ok: true, outcome: 'confirmed', booking_ref: '00A49C5E', guest_name: 'Ana Cruz', checkin: '2026-11-30', checkout: '2026-12-04' } };
      return { data: null };
    },
  };
  const io = { db, thread: async () => null, fbSend: async () => true, relay: async () => true, token: async () => null, now: () => NOW } as SendIO;
  const d: Deps = {
    db, financeChat: FIN, opsChat: OPS,
    send: async (chatId, text, extra) => { r.sent.push({ chatId, text, extra }); return { ok: true, result: { message_id: 800 + r.sent.length } }; },
    edit: async (chatId, mid, text, rm) => { r.edits.push({ chatId, mid, text, rm }); return { ok: true }; },
    editCaption: async (chatId, mid, text, rm) => { r.captions.push({ chatId, mid, text, rm }); return { ok: true }; },
    answer: async (id, text) => { r.answers.push({ id, text }); return {}; },
    forward: async () => true,
    ask: async (chatId, fromId, flow, refs, text) => { r.asked.push({ chatId, fromId, flow, refs, text }); },
    io, now: () => NOW,
  };
  return { d, r };
}
const cq = (data: string, chat = FIN, text = CARD) => ({ id: 'cb1', data, from: { id: 907000001, first_name: 'Lloyd' }, message: { chat: { id: Number(chat) }, message_id: 900, text, reply_markup: { inline_keyboard: [[{ text: 'x', callback_data: 'y' }]] } } });
const reply = (text: string, replyTo = 950) => ({ message_id: 951, chat: { id: Number(FIN) }, from: { id: 907000001, first_name: 'Lloyd' }, text, reply_to_message: { message_id: replyTo, from: { is_bot: true } } });
const plain = (s: string) => { assert(!s.includes('!'), s); assert(!/unfortunately/i.test(s), s); };

// ---- the parser ----

Deno.test('parser: every accepted shape', () => {
  assertEquals(parsePaidReply('1234567890123 5073'), { method: 'messenger_gcash', reference: '1234567890123', amount: 5073 });
  assertEquals(parsePaidReply('1234567890'), { method: 'messenger_gcash', reference: '1234567890', amount: null }); // 10 digits, amount defaults later
  assertEquals(parsePaidReply('1234567890123456 ₱5,073.50'), { method: 'messenger_gcash', reference: '1234567890123456', amount: 5073.5 });
  assertEquals(parsePaidReply('  cash 5073 '), { method: 'cash', reference: null, amount: 5073 });
  assertEquals(parsePaidReply('Cash 6,200'), { method: 'cash', reference: null, amount: 6200 });
  assertEquals(parsePaidReply('bank BPI-77A1 5073'), { method: 'bank', reference: 'BPI-77A1', amount: 5073 });
  assertEquals(parsePaidReply('BANK 4455'), { method: 'bank', reference: '4455', amount: null });
});

Deno.test('parser: every rejected shape asks again', () => {
  for (const t of ['', 'paid', '123456789', '12345678901234567', '1234 567 890123', '1234567890123 5073 extra', '1234567890123 abc', '1234567890123 0',
    '1234567890123 -5', '1234567890123 50,73', 'cash', 'cash five thousand', 'cash 0', 'cash 5073 now', 'bank', 'bank ab', 'bank --12', 'bank REF!1 5073',
    'bank REF1 5073 more', 'gcash 1234567890123 5073', '5073 1234567890123', 'cash 5073.123']) {
    assertEquals(parsePaidReply(t), null, t);
  }
  // Fable audit: a leading zero is a phone number; a figure far above the stay is a typo
  assertEquals(parsePaidReply('1234567890123 09171234567'), null);
  assertEquals(parsePaidReply('cash 0917'), null);
  assertEquals(parsePaidReply('1234567890123 5073', 6200)?.amount, 5073);
  assertEquals(parsePaidReply('1234567890123 18600', 6200)?.amount, 18600); // exactly 3x is still accepted
  assertEquals(parsePaidReply('1234567890123 18601', 6200), null);
  assertEquals(parsePaidReply('cash 200000'), { method: 'cash', reference: null, amount: 200000 });
  assertEquals(parsePaidReply('cash 200001'), null);
  assertEquals(parsePaidReply('bank BPI77 99999', 6200), null);
  assertEquals(refusal('inquiry_paid'), PAID_AGAIN);
  plain(PAID_AGAIN);
  assertEquals(PAID_AGAIN.split(/[.;]\s/).length <= 2, true);
});

Deno.test('only a reply to the prompt answers Paid – confirm; other questions keep taking the next text', () => {
  assert(answersOpen('inquiry_paid', 950, 950));
  assert(answersOpen('inquiry_paid', 950, '950'));
  assert(!answersOpen('inquiry_paid', 950, undefined));
  assert(!answersOpen('inquiry_paid', 950, 949));
  assert(!answersOpen('inquiry_paid', undefined, undefined)); // the prompt never posted: nothing counts
  assert(answersOpen('expense', undefined, undefined));
  assert(answersOpen('inquiry_reason', 950, undefined));
});

// ---- tap -> prompt -> reply -> RPC ----

Deno.test('Paid tap: one force-reply question with the expected amount; nothing is written yet', async () => {
  const { d, r } = setup();
  await onIqTap(d, cq(IQ.paid(ID)));
  assertEquals(r.rpcs.filter((x) => x.fn === CONFIRM_RPC), []);
  assertEquals(r.asked.length, 1);
  const a = r.asked[0];
  assertEquals([a.flow, a.fromId, a.refs.booking_id, a.refs.card_mid, a.refs.expected], ['inquiry_paid', 907000001, ID, 900, 6200]);
  assertEquals(a.refs.card_text, CARD);
  assertStringIncludes(a.text, 'Ana: how was it paid?');
  assertStringIncludes(a.text, 'Reply with the GCash reference and amount, e.g. 1234567890123 5073 - or cash 5073 - or bank <ref> 5073.');
  assertStringIncludes(a.text, 'Amount can be left out if it is exactly ₱6,200.');
  plain(a.text);
  assertEquals(r.edits, []); // the card is untouched until the answer confirms
});

Deno.test('Paid tap: the full payment is the expected amount; an unknown amount must be typed', () => {
  assertStringIncludes(paidPrompt(view(), 12400), 'exactly ₱12,400');
  assertStringIncludes(paidPrompt(view(), null), 'Include the amount received.');
});

Deno.test('Paid tap in OPS does nothing (the button is Finance only); after a receipt the card points to the receipt card', async () => {
  const ops = setup();
  await onIqTap(ops.d, cq(IQ.paid(ID), OPS));
  assertEquals(ops.r.asked, []);
  const rc = setup({ views: [view({ has_receipt: true })] });
  await onIqTap(rc.d, cq(IQ.paid(ID)));
  assertEquals(rc.r.asked, []);
  assertStringIncludes(rc.r.edits[0].text, 'A receipt came in - confirm it on the receipt card above.');
});

Deno.test('wiring: tap, reply, then exactly one RPC call keyed by the question row; the card shows the masked ref; OPS gets the usual line', async () => {
  const { d, r } = setup();
  await onIqTap(d, cq(IQ.paid(ID)));
  const refs = r.asked[0].refs;
  const msg = reply(`${REF} 6200`);
  await onInquiryPaid(d, msg, refs, parsePaidReply(msg.text)!, PID);
  const calls = r.rpcs.filter((x) => x.fn === CONFIRM_RPC);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].args, { p_telegram_user_id: 907000001, p_booking_id: ID, p_method: 'messenger_gcash', p_reference: REF, p_amount: 6200, p_note: null, p_comparison_id: null, p_idempotency_key: `tg-paid:${PID}` });
  const card = r.edits.find((e) => e.mid === 900)!;
  assertStringIncludes(card.text, CARD);
  assertStringIncludes(card.text, '✅ Confirmed by Lloyd · ref …0123.');
  assert(!card.text.includes(REF), 'the whole reference never shows');
  assertEquals(card.rm, undefined); // no buttons left
  const ops = r.sent.filter((s) => String(s.chatId) === OPS);
  assertEquals(ops.length, 1);
  assertEquals(ops[0].text, '🏠 CONFIRMED · Direct 00A49C5E\n\nDirect booking confirmed by Lloyd. Calendar is updated; turnover follows the usual schedule.');
});

Deno.test('wiring: amount left out takes the expected; cash records who saw it; bank passes its ref', async () => {
  const { d, r } = setup();
  const refs = { booking_id: ID, card_mid: 900, card_text: CARD, expected: 6200 };
  await onInquiryPaid(d, reply(REF), refs, parsePaidReply(REF)!, PID);
  await onInquiryPaid(d, reply('cash 6200'), refs, parsePaidReply('cash 6200')!, PID);
  await onInquiryPaid(d, reply('bank BPI77 6200'), refs, parsePaidReply('bank BPI77 6200')!, PID);
  const c = r.rpcs.filter((x) => x.fn === CONFIRM_RPC).map((x) => x.args);
  assertEquals([c[0].p_method, c[0].p_amount], ['messenger_gcash', 6200]);
  assertEquals([c[1].p_method, c[1].p_reference, c[1].p_amount, c[1].p_note], ['cash', null, 6200, 'cash seen by Lloyd']);
  assertEquals([c[2].p_method, c[2].p_reference], ['bank', 'BPI77']);
  assertStringIncludes(r.edits[1].text, '✅ Confirmed by Lloyd · cash.');
});

Deno.test('wiring: no amount and nothing expected is refused before any RPC', async () => {
  const { d, r } = setup();
  await onInquiryPaid(d, reply(REF), { booking_id: ID, card_mid: 900, card_text: CARD, expected: null }, parsePaidReply(REF)!, PID);
  assertEquals(r.rpcs.filter((x) => x.fn === CONFIRM_RPC), []);
  assertStringIncludes(r.sent[0].text, 'The amount received is needed');
});

Deno.test('D-306: no reference or amount ever reaches OPS, on any outcome', async () => {
  for (const outcome of ['confirmed', 'conflict', 'reference_reused', 'not_linked', 'denied']) {
    const { d, r } = setup({ confirm: () => (outcome === 'confirmed' ? { ok: true, outcome } : { ok: false, outcome, prior_ref: 'BD111111' }) });
    await onInquiryPaid(d, reply(`${REF} 6200`), { booking_id: ID, card_mid: 900, card_text: CARD, expected: 6200 }, parsePaidReply(`${REF} 6200`)!, PID);
    for (const s of r.sent.filter((x) => String(x.chatId) === OPS)) {
      assert(!s.text.includes(REF.slice(-4)) && !/6,?200|₱/.test(s.text), s.text);
    }
    if (outcome !== 'confirmed') assertEquals(r.sent.filter((x) => String(x.chatId) === OPS).length, 0, outcome);
  }
});

// ---- every outcome, in plain sentences ----

Deno.test('every outcome has a plain sentence (no "!", no "Unfortunately"); reference_reused names the other booking; not_linked says how to link', () => {
  const outcomes = ['conflict', 'invalid_state', 'reference_reused', 'not_linked', 'amount_required', 'reference_required', 'note_required', 'denied', 'something_new', ''];
  for (const where of ['request', 'receipt'] as const) for (const k of outcomes) {
    const f = confirmRefusal({ ok: false, outcome: k, prior_ref: 'BD111111' }, 'Lloyd', where);
    plain(f.line);
    assert(/nothing was confirmed|not confirmed|cannot be confirmed/i.test(f.line), f.line);
  }
  assertStringIncludes(confirmRefusal({ outcome: 'reference_reused', prior_ref: 'BD111111' }, 'Lloyd', 'request').line, 'booking BD111111');
  const nl = confirmRefusal({ outcome: 'not_linked' }, 'Lloyd', 'request').line;
  assertStringIncludes(nl, 'not linked to a staff profile');
  assertStringIncludes(nl, 'Ask Lloyd to map it');
  assertStringIncludes(confirmRefusal({ outcome: 'reference_required' }, 'Lloyd', 'receipt').line, 'Inquiries page in the admin');
  assertEquals(maskRef(REF), '…0123');
});

Deno.test('each refusal reaches the person who replied, as a reply; the card keeps its buttons', async () => {
  for (const outcome of ['conflict', 'invalid_state', 'reference_reused', 'not_linked', 'amount_required', 'reference_required', 'note_required', 'denied']) {
    const { d, r } = setup({ confirm: () => ({ ok: false, outcome, prior_ref: 'BD111111' }) });
    await onInquiryPaid(d, reply(`${REF} 6200`), { booking_id: ID, card_mid: 900, card_text: CARD, expected: 6200 }, parsePaidReply(`${REF} 6200`)!, PID);
    assertEquals(r.edits, [], outcome);
    assertEquals(r.sent.length, 1, outcome);
    assertEquals([String(r.sent[0].chatId), r.sent[0].extra.reply_to_message_id], [FIN, 951]);
    assertEquals(r.sent[0].text, confirmRefusal({ outcome, prior_ref: 'BD111111' }, 'Lloyd', 'request').line);
  }
});

Deno.test('confirmedLine: cash says cash, a reference is masked, a GCash receipt without one says GCash (never cash)', () => {
  assertStringIncludes(confirmedLine('Lloyd', 'cash', null), '· cash.');
  assertStringIncludes(confirmedLine('Lloyd', 'messenger_gcash', REF), '· ref …0123.');
  assertStringIncludes(confirmedLine('Lloyd', 'messenger_gcash', null), '· GCash.');
  assertStringIncludes(confirmedLine('Lloyd', 'gcash_qr', null), '· GCash QR.');
  assertStringIncludes(confirmedLine('Lloyd', 'bank', null), '· bank transfer.');
});

Deno.test('a lost answer never claims nothing was confirmed; a missing RPC does', async () => {
  for (const o of [{ rpcThrows: true }, { rpcError: { message: 'upstream timeout', code: '57014' } }]) {
    const { d, r } = setup(o);
    await onInquiryPaid(d, reply(`${REF} 6200`), { booking_id: ID, card_mid: 900, card_text: CARD, expected: 6200 }, parsePaidReply(`${REF} 6200`)!, PID);
    assertEquals(r.sent.map((s) => s.text), [NO_ANSWER]);
    assert(!/nothing was confirmed/i.test(NO_ANSWER));
  }
  const gone = setup({ rpcError: { message: 'function does not exist', code: '42883' } });
  await onInquiryPaid(gone.d, reply(`${REF} 6200`), { booking_id: ID, card_mid: 900, card_text: CARD, expected: 6200 }, parsePaidReply(`${REF} 6200`)!, PID);
  assertStringIncludes(gone.r.sent[0].text, 'not switched on yet');
});

// ---- the receipt card ----

Deno.test('receipt Confirm: the one-tap RPC with the comparison id, the read reference and amount, Messenger method; caption edited; OPS line', async () => {
  const { d, r } = setup({ rows: {
    payment_evidence_comparisons: { booking_id: ID, evidence_candidate_ids: [CAND] },
    payment_evidence_candidates: { normalized_amount: '6200.00', normalized_reference: REF },
    booking_inquiries: { notes: 'via Messenger (psid 1)' },
  } });
  const tap = { id: 'cb2', data: `bk_ok:${CMP}`, from: { id: 907000001, first_name: 'Lloyd' }, message: { chat: { id: Number(FIN) }, message_id: 777, caption: '🧾 receipt 00A49C5E', reply_markup: { inline_keyboard: [] } } };
  await onReceiptConfirm(d, tap, CMP);
  const c = r.rpcs.filter((x) => x.fn === CONFIRM_RPC);
  assertEquals(c.length, 1);
  assertEquals(c[0].args, { p_telegram_user_id: 907000001, p_booking_id: ID, p_method: 'messenger_gcash', p_reference: REF, p_amount: 6200, p_note: null, p_comparison_id: CMP, p_idempotency_key: `tg-receipt:${CMP}` });
  assertEquals(r.captions.length, 1);
  assertStringIncludes(r.captions[0].text, '🧾 receipt 00A49C5E\n\n✅ Confirmed by Lloyd · ref …0123.');
  const ops = r.sent.filter((s) => String(s.chatId) === OPS);
  assertEquals(ops.map((s) => s.text.split('\n')[0]), ['🏠 CONFIRMED · Direct 00A49C5E']);
  assert(!ops[0].text.includes('0123') && !ops[0].text.includes('6200'));
});

Deno.test('receipt Confirm: a site request pays by QR; a text card (long caption) is edited as text; a refusal keeps the buttons', async () => {
  const { d, r } = setup({ confirm: () => ({ ok: false, outcome: 'not_linked' }), rows: {
    payment_evidence_comparisons: { booking_id: ID, evidence_candidate_ids: [CAND] },
    payment_evidence_candidates: { normalized_amount: 6200, normalized_reference: null },
    booking_inquiries: { notes: null },
  } });
  const rm = { inline_keyboard: [[{ text: '✅ Confirm booking', callback_data: `bk_ok:${CMP}` }]] };
  await onReceiptConfirm(d, { id: 'cb3', from: { id: 5, first_name: 'Joy' }, message: { chat: { id: Number(FIN) }, message_id: 778, text: '🧾 long card', reply_markup: rm } }, CMP);
  assertEquals(r.rpcs.find((x) => x.fn === CONFIRM_RPC)!.args.p_method, 'gcash_qr');
  assertEquals(r.captions, []);
  assertStringIncludes(r.edits[0].text, 'Joy, your Telegram account is not linked');
  assertEquals(r.edits[0].rm, rm);
  assertEquals(r.sent.filter((s) => String(s.chatId) === OPS), []);
});

Deno.test('receipt Confirm: a replay (already_processed) posts no second OPS line; a lost answer keeps the buttons', async () => {
  const rows = { payment_evidence_comparisons: { booking_id: ID, evidence_candidate_ids: [CAND] }, payment_evidence_candidates: { normalized_amount: 6200, normalized_reference: REF }, booking_inquiries: { notes: null } };
  const tap = { id: 'cb5', from: { id: 5, first_name: 'Joy' }, message: { chat: { id: Number(FIN) }, message_id: 780, caption: 'c', reply_markup: { inline_keyboard: [[{ text: 'k', callback_data: `bk_ok:${CMP}` }]] } } };
  const again = setup({ rows, confirm: () => ({ ok: true, outcome: 'confirmed', already_processed: true }) });
  await onReceiptConfirm(again.d, tap, CMP);
  assertEquals(again.r.sent.filter((s) => String(s.chatId) === OPS), []);
  assertStringIncludes(again.r.captions[0].text, '✅ Confirmed by Joy');
  const lost = setup({ rows, rpcThrows: true });
  await onReceiptConfirm(lost.d, tap, CMP);
  assertStringIncludes(lost.r.captions[0].text, NO_ANSWER);
  assertEquals(lost.r.captions[0].rm, tap.message.reply_markup);
});

Deno.test('receipt Confirm: a comparison that is gone confirms nothing and calls no RPC', async () => {
  const { d, r } = setup();
  await onReceiptConfirm(d, { id: 'cb4', from: { id: 5, first_name: 'Joy' }, message: { chat: { id: Number(FIN) }, message_id: 779, caption: 'c' } }, CMP);
  assertEquals(r.rpcs.filter((x) => x.fn === CONFIRM_RPC), []);
  assertStringIncludes(r.captions[0].text, 'nothing was confirmed');
});
