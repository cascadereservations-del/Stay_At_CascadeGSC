// deno test -A supabase/functions/telegram-expense/refund.test.ts - SPEC-42 9a: /refund destination rule, the dead Confirm button (F1), D-306.
import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { differentAccountReason, foldName, parseDirRef, refundCard, refundGate } from './refund.ts';

const nothingChanged = (verb: string, why: string) => `⚠️ Could not ${verb}, so nothing was changed. ${why}`;
const mdEsc = (s: unknown) => String(s ?? '').replace(/([_*`\[])/g, '\\$1');
const payer = { name: 'Synthetic Payer', channel: 'GCash' };
const facts = ['Booking:   `DIR-1A2B3C4D`', 'Amount:    ₱500'];

Deno.test('DIR ref: DIR- prefix or a bare 8-hex id prefix, case-insensitive; Airbnb codes are not', () => {
  assertEquals(parseDirRef('DIR-1A2B3C4D'), { prefix: '1a2b3c4d', explicit: true });
  assertEquals(parseDirRef('dir-1a2b3c4d'), { prefix: '1a2b3c4d', explicit: true });
  assertEquals(parseDirRef('1A2B3C4D'), { prefix: '1a2b3c4d', explicit: false });
  assertEquals(parseDirRef('HMSHFR4NRD'), null);
  assertEquals(parseDirRef('DIR-1A2B3C4'), null);
  assertEquals(parseDirRef('DIR-1A2B3C4G'), null);
  assertEquals(parseDirRef(''), null);
});

Deno.test('recipient fold: case, spacing, accents and punctuation do not make a different payer', () => {
  assertEquals(foldName('  Juan   dela-Cruz '), foldName('JUAN DELA CRUZ'));
  assertEquals(foldName('José Peña'), foldName('jose pena'));
  assert(foldName('Juan Cruz') !== foldName('Juana Cruz'));
  assertEquals(foldName(null), '');
});

Deno.test('reason must start with "different account:" and say why', () => {
  assertEquals(differentAccountReason('different account: guest asked for her sister'), 'guest asked for her sister');
  assertEquals(differentAccountReason('Different Account:  sister'), 'sister');
  assertEquals(differentAccountReason('different account:'), null);
  assertEquals(differentAccountReason('different account: x'), null);
  assertEquals(differentAccountReason('the guest said different account: sister'), null);
  assertEquals(differentAccountReason(null), null);
});

Deno.test('gate: the paying account passes, in any case or spacing', () => {
  const g = refundGate('synthetic   PAYER', payer, null);
  assertEquals(g.state, 'match');
  assert(g.canConfirm);
  assertEquals(g.warning, null);
});

Deno.test('gate: another recipient is refused with a plain reason until the note carries "different account:"', () => {
  const g = refundGate('Someone Else', payer, null);
  assertEquals(g.state, 'mismatch');
  assert(!g.canConfirm);
  assertStringIncludes(g.warning!, 'Not the paying account. A refund goes back to the account that paid.');
  assert(!refundGate('Someone Else', payer, 'InstaPay-1 note without the prefix').canConfirm);
  const ok = refundGate('Someone Else', payer, 'different account: guest asked for her sister');
  assertEquals(ok.state, 'reasoned');
  assert(ok.canConfirm);
});

Deno.test('gate: no payer on record cannot be shown to match, so it needs the reason too', () => {
  const g = refundGate('Anyone', { name: null, channel: null }, null);
  assertEquals(g.state, 'unknown');
  assert(!g.canConfirm);
  assertStringIncludes(g.warning!, 'No paying account is on record');
  assert(refundGate('Anyone', { name: ' ', channel: null }, 'different account: receipt was not read').canConfirm);
});

Deno.test('card happy path: Paid from line and a Confirm button that carries the saved id', () => {
  const c = refundCard(facts, refundGate('Synthetic Payer', payer, null), 'pend-123', nothingChanged, mdEsc, payer);
  assertStringIncludes(c.text, 'Paid from: Synthetic Payer · GCash');
  assertEquals(c.keyboard, [[{ text: '✅ Confirm Refund', callback_data: 'refund_ok:pend-123' }, { text: '❌ Cancel', callback_data: 'llm_cancel:pend-123' }]]);
});

Deno.test('card mismatch: warning, the way out, and no Confirm button', () => {
  const c = refundCard(facts, refundGate('Someone Else', payer, null), '', nothingChanged, mdEsc, payer);
  assertStringIncludes(c.text, 'Not the paying account');
  assertStringIncludes(c.text, 'different account:');
  assertEquals(c.keyboard, null);
  assert(!c.text.includes('refund_ok'));
});

Deno.test('F1: when the pending row could not be saved the card says nothing was changed and has no Confirm button', () => {
  const c = refundCard(facts, refundGate('Synthetic Payer', payer, null), '', nothingChanged, mdEsc, payer);
  assertEquals(c.keyboard, null);
  assertStringIncludes(c.text, 'Could not prepare the refund, so nothing was changed.');
  assert(!c.text.includes('refund_ok:'));
});

Deno.test('card for an Airbnb booking (no payer): no Paid from line, and still never a button with an empty id', () => {
  const open = { state: 'match' as const, canConfirm: true, warning: null };
  const ok = refundCard(facts, open, 'p1', nothingChanged, mdEsc, null);
  assert(!ok.text.includes('Paid from'));
  assertEquals(ok.keyboard![0][0].callback_data, 'refund_ok:p1');
  assertEquals(refundCard(facts, open, '', nothingChanged, mdEsc, null).keyboard, null);
});

Deno.test('cards read as plain sentences: no key=value dump, no exclamation', () => {
  const c = refundCard(facts, refundGate('Someone Else', payer, null), '', nothingChanged, mdEsc, payer);
  assert(!/[a-z_]+=\S/.test(c.text), 'no key=value dumps');
  assert(!c.text.includes('!'), 'Cassy voice: no exclamation');
});

// D-306: a refund is booking money. It is prepared and confirmed in the Finance group only, never OPS.
const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
const between = (a: string, b: string) => {
  const i = src.indexOf(a);
  assert(i >= 0, 'missing anchor: ' + a);
  return src.slice(i, src.indexOf(b, i));
};

Deno.test('D-306: the refund path never names the OPS chat', () => {
  const refundFns = between('async function handleRefundCommand(', '// CALLBACK QUERY HANDLER');
  assert(refundFns.length > 500);
  assert(!/OPS_CHAT|opsChat/.test(refundFns), 'refund functions must not reference the OPS chat');
});

Deno.test('D-306: outside Finance both the command and the Confirm tap refuse before any money is read, saved or sent', () => {
  const cmd = between('async function handleRefundCommand(', 'const fullText');
  assertStringIncludes(cmd, 'if (!isFinanceChat(chatId)) { await tgSend(chatId, FINANCE_ONLY); return; }');
  const tap = between("if(data.startsWith('refund_ok:'))", 'consumePending');
  assertStringIncludes(tap, 'if(!isFinanceChat(chatId)){await tgSend(chatId,FINANCE_ONLY);return;}');
});

Deno.test('D-306: the refusal an OPS member sees holds no money (no digits, no peso sign, no PHP), and it never echoes the typed command', () => {
  const finOnly = /const FINANCE_ONLY='([^']*)'/.exec(src)![1];
  assert(finOnly.length > 0);
  assert(!/[0-9₱]|php/i.test(finOnly), 'the refusal must not contain digits, the peso sign or PHP: ' + finOnly);
});
