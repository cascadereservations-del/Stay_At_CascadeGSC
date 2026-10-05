// deno test --no-check --allow-env telegram-expense/staffpay.test.ts
// SPEC-37: the cards, keyboards, proof read and verdict of the Staff Payment Request. Synthetic names and numbers only (public repo).
// Lives here because CI skips _shared/cascade-core tests.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { crc16, qrphWithAmount } from '../_shared/cascade-core/qrph.ts';
import {
  BANK_APPS, CAPTION_MAX, CUR, dayLabel, duplicateText, financeCaption, financeKeyboard, mismatchKeyboard, mismatchText, normaliseProof, opsCancelText,
  opsPaidKeyboard, opsPaidText, opsRequestText, parseSprTap, payBlock, type PayLine, type PayReq, proofPrompt, proofVerdict, RPC_STEP, tapRefusal, typeLabel,
} from '../_shared/cascade-core/staffpay.ts';

const ID = 'e3700000-0000-4000-8000-0000000000a1';
const clean = (date: string, guest: string | undefined, base: number, transport: number, type = 'turnover'): PayLine =>
  ({ kind: 'clean', session_id: crypto.randomUUID(), date, type, base, transport, amount: base + transport, ...(guest ? { guest } : {}) });
const claim = (description: string, amount: number, receipt = false): PayLine => ({ kind: 'claim', claim_id: crypto.randomUUID(), date: '2026-10-05', description, amount, receipt });
const req = (lines: PayLine[], over: Partial<PayReq> = {}): PayReq => ({
  id: ID, ref: 'E3700000', status: 'requested', payee_name: 'Honey', lines,
  total_amount: lines.reduce((s, l) => s + Number(l.amount), 0), ...over,
});
// the example of the spec: two cleans (one with transport) and one expense
const EX = req([clean('2026-10-02', 'Ana', 500, 150), clean('2026-10-04', 'Ben', 500, 0), claim('2 pcs KitKat for the guest', 40)]);

Deno.test('payBlock: the example renders exactly Honey\'s shape (weekday in Manila, transport shown as base + transport)', () => {
  assertEquals(payBlock(EX), [
    'Cleaning services',
    'Oct 2 Fri (Ana) = 650 (500 + 150 transport)',
    'Oct 4 Sun (Ben) = 500',
    'Other expenses',
    '2 pcs KitKat for the guest = 40',
    `Total: ${CUR}1,190`,
  ].join('\n'));
  assertEquals(dayLabel('2026-10-05'), 'Oct 5 Mon');
});

Deno.test('payBlock: a clean without a guest name drops the brackets; a deep clean says so; a cleans-only request has no expense heading', () => {
  const r = req([clean('2026-10-02', undefined, 1000, 0, 'deep_clean')]);
  assertEquals(payBlock(r), ['Cleaning services', 'Oct 2 Fri = 1,000 · Deep clean', `Total: ${CUR}1,000`].join('\n'));
  assertEquals(typeLabel('mid_stay'), 'Mid-stay clean');
  assertEquals(typeLabel(undefined), 'Turnover');
});

Deno.test('payBlock: the Finance-only receipt marker appears on Finance blocks and never in OPS', () => {
  const r = req([clean('2026-10-02', 'Ana', 500, 0), claim('Sugar', 20, true), claim('Soap', 35, false)]);
  const fin = payBlock(r, { receipts: true });
  assert(fin.includes('Sugar = 20 · receipt below') && fin.includes('Soap = 35 · no receipt'));
  const ops = opsRequestText(r);
  assertEquals(/receipt/i.test(ops), false, 'OPS text carries no receipt marker');
  assert(ops.startsWith("Honey sent a payment request for ₱555. Finance will pay it and post here when it is done."));
  assert(ops.endsWith('Ref CASCADE-E3700000'));
});

Deno.test('finance caption: first sentence names the payee, the amount and who acts; the QR paragraph and the Ref line frame the block', () => {
  const c = financeCaption(EX, true);
  assert(c.startsWith("Honey is asking to be paid ₱1,190. Finance: pay Honey with the QR above, then tap I'm paying this."));
  assert(c.includes("The QR is Honey's payout account with ₱1,190 already set."));
  assert(c.endsWith('Ref CASCADE-E3700000'));
  const noQr = financeCaption(EX, false);
  assert(noQr.includes("Honey's payout QR is not saved yet, so there is no QR here."));
  assertEquals(noQr.includes('with the QR above'), false);
});

Deno.test('finance caption: 20 lines with long expense text stay within 1,024 characters, say +N more, and still end with the Ref line', () => {
  const lines: PayLine[] = [];
  for (let i = 0; i < 10; i++) lines.push(clean(`2026-10-${String(i + 1).padStart(2, '0')}`, 'Guestname', 500, 150));
  for (let i = 0; i < 10; i++) lines.push(claim(`Expense number ${i} ` + 'x'.repeat(480), 99, i % 2 === 0));
  const r = req(lines);
  for (const state of ['requested', 'paying', 'paid', 'cancelled'] as const) {
    const c = financeCaption({ ...r, status: state, paying_by_name: 'Marifel', paying_at: '2026-10-05T07:05:00Z', sent_said_at: '2026-10-05T07:10:00Z', paid_at: '2026-10-05T07:12:00Z', paid_by_name: 'Marifel', proof_verdict: 'match', proof_reference: 'AB1234567890', cancelled_by_name: 'Marifel', cancelled_at: '2026-10-05T07:20:00Z' }, true);
    assert(c.length <= CAPTION_MAX, `${state}: ${c.length}`);
    assert(c.endsWith('Ref CASCADE-E3700000'), state);
    assert(/\+\d+ more/.test(c), `${state} says +N more`);
    assert(c.includes(`Total: ${CUR}${Number(r.total_amount).toLocaleString('en-US')}`), `${state} keeps the total`);
  }
  assertEquals(/\+\d+ more/.test(financeCaption(EX, true)), false, 'a short request is not trimmed');
});

Deno.test('finance caption by state: who is paying and when, who sent it, PAID, override, cancelled', () => {
  const base = { ...EX };
  assert(financeCaption({ ...base, status: 'paying', paying_by_name: 'Marifel', paying_at: '2026-10-05T07:05:00Z' }, true).startsWith('Marifel is paying Honey ₱1,190 now (3:05 PM). Payment sent?'));
  assert(financeCaption({ ...base, status: 'paying', paying_by_name: 'Marifel', sent_said_at: '2026-10-05T07:10:00Z' }, true).startsWith('Marifel sent Honey ₱1,190 at 3:10 PM. Waiting for the transfer screenshot here.'));
  const paid = financeCaption({ ...base, status: 'paid', paid_by_name: 'Marifel', paid_at: '2026-10-05T07:12:00Z', proof_verdict: 'match', proof_reference: 'AB1234567890' }, true);
  assert(paid.startsWith('PAID. Honey has been paid ₱1,190. Marifel sent it on Oct 5 at 3:12 PM and the screenshot matches (reference AB1234567890). The cleans and the expense are marked paid in the ledger.'));
  const ovr = financeCaption({ ...base, status: 'paid', paid_by_name: 'Marifel', paid_at: '2026-10-05T07:12:00Z', proof_verdict: 'override', proof_amount: 1100 }, true);
  assert(ovr.includes('Marifel confirmed the amount by hand; the screenshot read ₱1,100.'));
  assert(financeCaption({ ...base, status: 'cancelled', cancelled_by_name: 'Marifel', cancelled_at: '2026-10-05T07:20:00Z' }, true).startsWith("Cancelled by Marifel at 3:20 PM. Nothing was paid; Honey's cleans are free to request again."));
});

Deno.test('finance keyboard by state: requested has pay and cancel, said-sent has no cancel, paid and cancelled have none, copy buttons carry the amount and the reference', () => {
  const rows = (r: PayReq) => financeKeyboard(r).inline_keyboard;
  const flat = (r: PayReq) => rows(r).flat();
  const requested = flat(EX);
  assertEquals(requested.filter((b) => b.callback_data).map((b) => b.callback_data), [`spr:pay:${ID}`, `spr:cancel:${ID}`]);
  assertEquals(requested.filter((b) => b.copy_text).map((b) => b.copy_text!.text), ['1190', 'CASCADE-E3700000']);
  assertEquals(rows({ ...EX, total_amount: 1190.5 })[0][0].copy_text!.text, '1190.50');
  const paying = flat({ ...EX, status: 'paying' });
  assertEquals(paying.filter((b) => b.callback_data).map((b) => b.callback_data), [`spr:sent:${ID}`, `spr:no:${ID}`]);
  const said = flat({ ...EX, status: 'paying', sent_said_at: '2026-10-05T07:10:00Z' });
  assertEquals(said.map((b) => b.callback_data), [`spr:sent:${ID}`, `spr:no:${ID}`], 'No, not sent stays while no screenshot is stored');
  const withProof = flat({ ...EX, status: 'paying', sent_said_at: '2026-10-05T07:10:00Z', proof_file_unique_id: 'f' });
  assertEquals(withProof.map((b) => b.callback_data), [`spr:sent:${ID}`]);
  assertEquals(flat({ ...EX, status: 'paid' }), []);
  assertEquals(flat({ ...EX, status: 'cancelled' }), []);
  assertEquals(BANK_APPS.length, 0, 'no bank app is listed until its package id is verified (SPEC-37 7.C)');
});

Deno.test('every callback_data is at most 64 bytes, including the OPS Received button and the mismatch buttons', () => {
  const all = [
    ...financeKeyboard(EX).inline_keyboard.flat(), ...financeKeyboard({ ...EX, status: 'paying' }).inline_keyboard.flat(),
    ...mismatchKeyboard(ID).inline_keyboard.flat(), ...(opsPaidKeyboard(EX)?.inline_keyboard.flat() ?? []),
  ];
  for (const b of all) if (b.callback_data) assert(new TextEncoder().encode(b.callback_data).length <= 64, b.callback_data);
  assertEquals(opsPaidKeyboard(EX)!.inline_keyboard[0][0].callback_data, 'cleanerack:Honey');
  assertEquals(opsPaidKeyboard({ ...EX, payee_name: 'A very long payee name that cannot fit in a button' }), null);
});

Deno.test('parseSprTap accepts only spr:<step>:<uuid>', () => {
  assertEquals(parseSprTap(`spr:pay:${ID}`), { step: 'pay', id: ID });
  assertEquals(parseSprTap(`spr:ovr:${ID.toUpperCase()}`), { step: 'ovr', id: ID });
  assertEquals(parseSprTap(`spr:nope:${ID}`), null, 'bad step');
  assertEquals(parseSprTap('spr:pay:not-a-uuid'), null, 'bad uuid');
  assertEquals(parseSprTap(`spr:pay:${ID}:extra`), null, 'extra part');
  assertEquals(parseSprTap(`xpr:pay:${ID}`), null);
  assertEquals(parseSprTap(''), null);
  assertEquals(RPC_STEP.no, 'not_sent');
  assertEquals(RPC_STEP.ovr, 'override');
});

Deno.test('normaliseProof: reference upper A-Z0-9 of 4 to 64, amount above zero or null, confidence clamped, status checked', () => {
  const r = normaliseProof({ amount: '1,340.00', reference: ' ab-12 3456 ', date: '2026-10-05', recipient_name: 'HONEY C.', status: 'SUCCESS', confidence: 7 })!;
  assertEquals(r.amount, 1340);
  assertEquals(r.reference, 'AB123456');
  assertEquals(r.status, 'success');
  assertEquals(r.confidence, 1);
  assertEquals(normaliseProof({ amount: 0, reference: 'abc', confidence: -2, status: 'weird' }), { amount: null, reference: null, date: null, recipient_name: null, status: null, confidence: 0 });
  assertEquals(normaliseProof({ amount: null })!.amount, null);
  assertEquals(normaliseProof({ reference: 'x'.repeat(65) })!.reference, null);
  assertEquals(normaliseProof(null), null);
  assertEquals(normaliseProof('text'), null);
});

Deno.test('proofVerdict: within 0.49 matches, 1 off mismatches, pending is not a proof, no read is unread', () => {
  assertEquals(proofVerdict({ amount: 1190.49, status: 'success' }, 1190), 'match');
  assertEquals(proofVerdict({ amount: 1189.51 }, '1190.00'), 'match');
  assertEquals(proofVerdict({ amount: 1191 }, 1190), 'mismatch');
  assertEquals(proofVerdict({ amount: 1190, status: 'pending' }, 1190), 'not_proof');
  assertEquals(proofVerdict({ amount: 1190, status: 'failed' }, 1190), 'not_proof');
  assertEquals(proofVerdict({ amount: null }, 1190), 'not_proof');
  assertEquals(proofVerdict(null, 1190), 'unread');
});

Deno.test('reply texts: prompt, mismatch by verdict, duplicate, tap refusals (SPEC-37 6.4)', () => {
  assertEquals(proofPrompt(EX, 'Marifel'), "Marifel, send the transfer screenshot here as a photo. It is checked against ₱1,190 before Honey's request is marked paid.");
  assertEquals(mismatchText(EX, { amount: 1100 }, 'mismatch'), "The screenshot shows ₱1,100, but Honey's request is ₱1,190, so it is not marked paid yet. If the screenshot is right and the reading is wrong, tap Amount is right. Otherwise send the correct screenshot.");
  assert(mismatchText(EX, null, 'not_proof').startsWith('This looks like the screen before sending'));
  assert(mismatchText(EX, null, 'unread').includes('could not be read automatically'));
  assertEquals(duplicateText('WXYZ1234'), 'This screenshot was already used for request WXYZ1234, so nothing changed. Send the screenshot for this payment.');
  assertEquals(tapRefusal('not_open', { status: 'paying' }), 'Someone is already paying this one.');
  assertEquals(tapRefusal('not_open', { status: 'paid' }), 'This request is already closed.');
  assert(tapRefusal('already_paid', { date: '2026-10-02', payee: 'Honey' }).startsWith('The clean on Oct 2 Fri was already paid another way'));
  assert(tapRefusal('money_may_be_sent').includes('Tap No, not sent first'));
});

Deno.test('OPS posts: paid names who sent it and the last four of the reference and closes warmly for Honey only; cancel says nothing was paid', () => {
  const paid = req(EX.lines, { status: 'paid', paid_by_name: 'Marifel', paid_at: '2026-10-05T07:12:00Z', proof_reference: 'AB1234567890', proof_verdict: 'match' });
  assertEquals(opsPaidText(paid), "Honey has been paid ₱1,190. Marifel sent it on Oct 5 at 3:12 PM, reference ending 7890. Honey: tap Received once it shows in your account. Ty, Hon 🌷\nRef CASCADE-E3700000");
  assertEquals(opsPaidText({ ...paid, payee_name: 'Joseph' }).includes('Ty, Hon'), false);
  assertEquals(opsCancelText(EX), "Finance cancelled Honey's payment request for ₱1,190; nothing was paid. Honey: send a new one from the Cascade Staff app if it is still owed.\nRef CASCADE-E3700000");
});

Deno.test('amount QR: a non-GCash QR Ph base round-trips through qrphWithAmount with a valid CRC and tag 54', () => {
  // a synthetic merchant QR Ph (static, tag 26 template), built with crc16; not any real account
  const body = '000201010211' + '26340012com.example.p2p0114ZZSYNTH0000001' + '5204601653036085802PH5909Synthetic6005Conel' + '6304';
  const base = body + crc16(body);
  const out = qrphWithAmount(base, 4840);
  assert(out.startsWith('000201010212'), 'dynamic once an amount rides on it');
  assert(out.includes('54074840.00'), 'tag 54 with the amount to two decimals');
  assertEquals(out.slice(-4), crc16(out.slice(0, -4)), 'the CRC is valid');
  assert(out.indexOf('5802PH') > out.indexOf('5407'), 'tag 54 sits before the country tag');
});
