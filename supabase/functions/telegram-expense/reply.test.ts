// deno test --no-check --allow-env telegram-expense/reply.test.ts
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import type { Change, CountItem } from './count.ts';
import { BTN, doSend } from '../_shared/cascade-core/format.ts';
import {
  countCardKeyboard, countCardText, NOT_WAITING, parseAmount, parseExpenseAnswer, parseManualClean, parseQty, refusal,
  routeText, setChange,
} from './reply.ts';

const item = (id: string, name: string, qty: number, reorder: number | null = null, unit = 'pc'): CountItem =>
  ({ id, name, unit, qty, reorder });

// What the router sees for a Telegram message, derived the way index.ts derives it.
const routeOf = (msg: any, awaiting: boolean, countCardMid: number | null = null) => routeText({
  awaiting,
  replyToCountCard: countCardMid !== null && msg.reply_to_message?.message_id === countCardMid,
  replyToBot: !!msg.reply_to_message?.from?.is_bot,
  text: String(msg.text ?? ''),
});

// D-195: the update that booked ₱2. Telegram hands back the old count card with the backticks stripped.
const D195 = {
  update_id: 700000001,
  message: {
    message_id: 5120,
    from: { id: 5550001, is_bot: false, first_name: 'Lloyd' },
    chat: { id: -1002000000001, type: 'supergroup', title: 'Cascade Finance' },
    date: 1789800000,
    text: '2 20',
    reply_to_message: {
      message_id: 5119,
      from: { id: 7000000001, is_bot: true, first_name: 'Cascade Hideaway' },
      chat: { id: -1002000000001, type: 'supergroup' },
      date: 1789799900,
      text: '📦 COUNT · Consumables · 19 items\n 1. Bottled Water — 24 pc\n 2. Coffee (3-in-1) — 28 pc\n\n' +
        'Reply to this message with ONLY the lines that changed, as  <#> <new count>:\n  2 20\n  7 0\n' +
        'COUNT|56e217d4-7e4b-46a0-ae8c-000000000000',
    },
  },
};

Deno.test('D-195: "2 20" replied to the old count card, with nobody being asked, is refused', () => {
  assertEquals(D195.message.reply_to_message.text.includes('`'), false); // the shape that broke every marker
  assertEquals(routeOf(D195.message, false), { kind: 'refuse' });
  // The old card is not a live count card, so even its message id matching nothing changes nothing.
  assertEquals(routeOf(D195.message, false, 4000), { kind: 'refuse' });
  assertEquals(NOT_WAITING, 'That card is not waiting for an answer, so nothing was saved. Tap a button on it, ask Cassy with /cassy <your question>, or /menu.');
  // SPEC-23: a refusal must say how to reach Cassy; Lloyd hit this live on 2026-09-22 with no way forward.
  assertEquals(NOT_WAITING.includes('/cassy'), true);
});

Deno.test('the person being asked is answered, whether or not they used Reply', () => {
  assertEquals(routeOf({ text: '20' }, true), { kind: 'flow' });
  assertEquals(routeOf({ text: '20', reply_to_message: { message_id: 9, from: { is_bot: true } } }, true), { kind: 'flow' });
});

Deno.test('a reply to the live count card is the many-lines power path', () => {
  const msg = { text: '2 20\n7 0', reply_to_message: { message_id: 4000, from: { is_bot: true } } };
  assertEquals(routeOf(msg, false, 4000), { kind: 'count_lines' });
});

Deno.test('plain text and commands pass through; a command is never taken as an answer', () => {
  assertEquals(routeOf({ text: '500 supplies' }, false), { kind: 'passthrough' });
  assertEquals(routeOf({ text: '/menu' }, true), { kind: 'passthrough' });
  assertEquals(routeOf({ text: '/count', reply_to_message: { message_id: 9, from: { is_bot: true } } }, false), { kind: 'passthrough' });
});

Deno.test('"twenty" or "2 20" to a count prompt is refused with the spec wording, so the row is kept', () => {
  assertEquals(parseQty('twenty'), null);
  assertEquals(parseQty('2 20'), null);
  assertEquals(refusal('count_qty'), 'Just the new number, like 20. Nothing saved yet.');
});

Deno.test('a count is a number of zero or more with at most two decimals', () => {
  assertEquals(parseQty('20'), 20);
  assertEquals(parseQty('0'), 0);
  assertEquals(parseQty('1.5'), 1.5);
  assertEquals(parseQty('₱20'), 20);
  assertEquals(parseQty('-1'), null);
  assertEquals(parseQty('1.555'), null);
  assertEquals(parseAmount('0'), null); // zero is a count, never an amount
  assertEquals(parseAmount('1,706'), 1706);
});

Deno.test('the expense answer: amount first, or a shop name that keeps the detected amount', () => {
  assertEquals(parseExpenseAnswer('1706 SC Johnson Lazada', 0), { amount: 1706, vendor: 'SC Johnson Lazada' });
  assertEquals(parseExpenseAnswer('1706', 0), { amount: 1706, vendor: null });
  assertEquals(parseExpenseAnswer('Lazada', 1706), { amount: 1706, vendor: 'Lazada' });
  assertEquals(parseExpenseAnswer('Lazada', 0), null);
  assertEquals(parseExpenseAnswer('twenty', 0), null);
});

Deno.test('manual clean takes commas or the old pipes, and needs all three parts', () => {
  assertEquals(parseManualClean('Honey, 05-28, 500'), { cleaner: 'Honey', dateTok: '05-28', amount: 500, notes: null });
  assertEquals(parseManualClean('Honey | 05-28 | 500 | deep clean bonus'), { cleaner: 'Honey', dateTok: '05-28', amount: 500, notes: 'deep clean bonus' });
  assertEquals(parseManualClean('Honey, 05-28'), null);
  assertEquals(parseManualClean('Honey, 05-28, five hundred'), null);
});

const ITEMS = [item('i1', 'Bottled Water', 24), item('i2', 'Coffee (3-in-1)', 28, 10), item('i3', 'Sugar sachets', 40)];

Deno.test('a tapped count sets, replaces and clears one change, kept in list order', () => {
  let c: Change[] = setChange(ITEMS, [], 3, 30);
  c = setChange(ITEMS, c, 2, 20);
  assertEquals(c.map((x) => [x.name, x.before, x.counted]), [['Coffee (3-in-1)', 28, 20], ['Sugar sachets', 40, 30]]);
  c = setChange(ITEMS, c, 2, 22);
  assertEquals(c[0].counted, 22);
  c = setChange(ITEMS, c, 2, 28); // typing what the system has is no change
  assertEquals(c.map((x) => x.name), ['Sugar sachets']);
});

Deno.test('the count card: no Apply at 0 changes, Apply with a count once there is one', () => {
  const kb0 = countCardKeyboard('p', ITEMS, []);
  assertEquals(kb0.inline_keyboard.at(-1), [{ text: '❌ Cancel', callback_data: 'inv:no:p' }]);
  assertEquals(kb0.inline_keyboard[1][0].text, '2 · Coffee (3-in-1) · 28 pc');
  const kb1 = countCardKeyboard('p', ITEMS, setChange(ITEMS, [], 2, 20));
  assertEquals(kb1.inline_keyboard.at(-1)!.map((b) => b.text), ['✅ Apply 1 change', '❌ Cancel']);
  assertEquals(kb1.inline_keyboard[1][0].text, '✏️ 2 · Coffee (3-in-1) · 28 → 20');
  assertEquals(countCardText('Consumables', 19, 1), '📦 Count · Consumables · 19 items · 1 change\nTap another item, or Apply. Nothing is saved until Apply.');
});

Deno.test('a 73-item All-groups card keeps every callback_data within 64 bytes', () => {
  const pid = crypto.randomUUID();
  const many = Array.from({ length: 73 }, (_, i) => item(crypto.randomUUID(), `A very long inventory item name number ${i}`, i));
  const kb = countCardKeyboard(pid, many, setChange(many, [], 73, 999));
  const enc = new TextEncoder();
  const all = kb.inline_keyboard.flat();
  assertEquals(all.length, 75); // 73 items, Apply, Cancel
  assertEquals(all.every((b) => enc.encode(b.callback_data).length <= 64), true);
  assertEquals(all.every((b) => b.text.length <= 64), true);
});

Deno.test('SPEC-22: no button label promises a copy, because Telegram cannot copy on tap', () => {
  for (const group of Object.values(BTN)) for (const b of group) assertEquals(/copy/i.test(b.text), false, b.text);
  assertEquals(/\bCopy\b/.test(doSend('Ana', 'hi').join(' ')), false);
  assertEquals(doSend('Ana', 'hi')[0].includes('Show as text'), true);
});

import { ASK_CASSY_PROMPT, CASSY_LABELS, cassyAsk } from './reply.ts';
Deno.test('Ask Cassy button: the prompt asks, and a reply to it is a question for Cassy (live 2026-09-26)', () => {
  assertEquals(CASSY_LABELS.includes('🤖 Ask Cassy'), true);
  const q = 'Create a polite message answering the guest if the unit is available today';
  assertEquals(cassyAsk(q, ASK_CASSY_PROMPT, true), `cassy ${q}`);
  assertEquals(cassyAsk(q, ASK_CASSY_PROMPT, false), null);             // a person quoting the prompt is not the bot's prompt
  assertEquals(cassyAsk(q, 'How many did you count?', true), null);      // other bot prompts keep their own flows
  assertEquals(cassyAsk('  ', ASK_CASSY_PROMPT, true), null);
});
