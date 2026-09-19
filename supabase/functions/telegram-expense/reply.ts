// SPEC-16 (session 37): the pure parts of the Telegram reply surface. The bot remembers who it asked and
// for what in telegram_pending (kind 'awaiting_reply'); it never reads state back out of message text,
// which Telegram is free to reformat (D-195). No I/O, unit-tested in reply.test.ts. index.ts owns the calls.
import type { Change, CountItem } from './count.ts';

export type Flow =
  | 'count_qty' | 'expense' | 'edit_amount' | 'payclean_amount'
  | 'receipt_item_edit' | 'receipt_item_add' | 'manual_clean';

export type Route =
  | { kind: 'flow' }         // the person is being asked something: this text is the answer
  | { kind: 'count_lines' }  // a reply to a count card itself: the SPEC-03 many-lines power path
  | { kind: 'refuse' }       // a reply to a bot message that asked nothing: say so, save nothing
  | { kind: 'passthrough' }; // commands, then numeric fast entry, as before

/**
 * The four-step decision. Step 3 is the D-195 guard: no reply to a bot message ever reaches the expense
 * parser. A command is never an answer, so it passes through even while a question is open.
 */
export function routeText(i: { awaiting: boolean; replyToCountCard: boolean; replyToBot: boolean; text: string }): Route {
  if (i.text.trimStart().startsWith('/')) return { kind: 'passthrough' };
  if (i.awaiting) return { kind: 'flow' };
  if (i.replyToCountCard) return { kind: 'count_lines' };
  if (i.replyToBot) return { kind: 'refuse' };
  return { kind: 'passthrough' };
}

export const NOT_WAITING = 'That card is not waiting for an answer, so nothing was saved. Tap a button on it, or /menu.';
export const CANCELLED = '❌ Cancelled. Nothing saved.';
export const COUNT_EXPIRED = '⏰ That count expired. Run /count again.';

/** What each open question says when the answer does not fit. The question stays open. */
export function refusal(flow: Flow): string {
  return ({
    count_qty: 'Just the new number, like 20. Nothing saved yet.',
    expense: 'Type the amount, like 1706 or 1706 Lazada. Nothing saved yet.',
    edit_amount: 'Just the total, like 1706. Nothing saved yet.',
    payclean_amount: 'Just the amount you paid, like 500. Nothing saved yet.',
    receipt_item_edit: 'Type the new price, like 216, or name and price, like Mr Muscle 216. Nothing saved yet.',
    receipt_item_add: 'Type the item and its price, like Joy Dishwashing 89. Nothing saved yet.',
    manual_clean: 'Type: cleaner, date, amount, like Honey, 05-28, 500. Nothing saved yet.',
  } as Record<Flow, string>)[flow];
}

/** A stock count: `20`, `0`, `1.5`, `₱20`. Not `twenty`, `2 20`, `-1` or three decimals. */
export function parseQty(text: string): number | null {
  const t = String(text ?? '').trim().replace(/^₱\s*/, '').replace(/,/g, '');
  if (!/^\d+(\.\d{1,2})?$/.test(t)) return null;
  return Number(t);
}

/** A money amount: like parseQty, but zero is not an amount. */
export function parseAmount(text: string): number | null {
  const n = parseQty(text);
  return n !== null && n > 0 ? n : null;
}

/** `1706`, `1706 Lazada`, or with a detected amount just `Lazada` (keeps the detected figure). */
export function parseExpenseAnswer(text: string, preAmount: number): { amount: number; vendor: string | null } | null {
  const tokens = String(text ?? '').trim().split(/\s+/).filter(Boolean);
  if (!tokens.length) return null;
  const first = parseAmount(tokens[0]);
  if (first !== null) return { amount: first, vendor: tokens.slice(1).join(' ') || null };
  // With nothing detected, text without a leading amount is not an answer. It is never booked.
  if (preAmount > 0 && !/\d/.test(tokens[0])) return { amount: preAmount, vendor: tokens.join(' ') };
  return null;
}

/** `Honey, 05-28, 500` or the old `Honey | 05-28 | 500 | note`. A fourth part is the note. */
export function parseManualClean(text: string): { cleaner: string; dateTok: string; amount: number; notes: string | null } | null {
  const parts = String(text ?? '').split(/[|,]/).map((s) => s.trim());
  const [cleaner = '', dateTok = '', amtTok = ''] = parts;
  const amount = parseAmount(amtTok);
  if (!cleaner || !dateTok || amount === null) return null;
  return { cleaner, dateTok, amount, notes: parts.slice(3).join(', ').trim() || null };
}

/** `Joy Dishwashing 89`, `Tissue 45 x2`, `216`. Moved from index.ts unchanged. */
export function parseNamePriceQty(tokens: string[]) {
  let qty = 1, qtyExplicit = false; const kept: string[] = [];
  for (const t of tokens) { const mq = t.match(/^x(\d+)$/i) || t.match(/^(\d+)x$/i); if (mq) { qty = Number(mq[1]) || 1; qtyExplicit = true; continue; } kept.push(t); }
  let price: number | null = null;
  if (kept.length) { const last = kept[kept.length - 1].replace(/[₱,]/g, ''); if (/^\d+(\.\d{1,2})?$/.test(last)) { price = Number(last); kept.pop(); } }
  return { name: kept.join(' ').trim(), price, qty, qtyExplicit };
}

/** Set (or clear) one item's new count. Typing the number the system already has removes the change. */
export function setChange(items: CountItem[], changes: Change[], index: number, counted: number): Change[] {
  const it = items[index - 1];
  if (!it) return changes;
  const rest = changes.filter((c) => c.item_id !== it.id);
  if (it.qty !== counted) rest.push({ item_id: it.id, name: it.name, unit: it.unit, before: it.qty, counted, reorder: it.reorder });
  const order = new Map(items.map((x, i) => [x.id, i]));
  return rest.sort((a, b) => (order.get(a.item_id) ?? 0) - (order.get(b.item_id) ?? 0));
}

const short = (s: string, n = 22) => (s.length > n ? s.slice(0, n - 1) + '…' : s);
const plural = (n: number) => `${n} change${n === 1 ? '' : 's'}`;

/** Card A's text. The buttons are the instruction; the card no longer advertises a format. */
export function countCardText(label: string, itemCount: number, changeCount: number): string {
  return changeCount
    ? `📦 Count · ${label} · ${itemCount} items · ${plural(changeCount)}\nTap another item, or Apply. Nothing is saved until Apply.`
    : `📦 Count · ${label} · ${itemCount} items\nTap an item whose count changed. The number is what the system has now.`;
}

/** One button per item; Apply only when there is something to apply. Every callback_data is ≤ 64 bytes. */
export function countCardKeyboard(pid: string, items: CountItem[], changes: Change[]) {
  const byId = new Map(changes.map((c) => [c.item_id, c]));
  const rows: Array<Array<{ text: string; callback_data: string }>> = items.map((it, i) => {
    const c = byId.get(it.id);
    const text = c
      ? `✏️ ${i + 1} · ${short(it.name)} · ${c.before} → ${c.counted}`
      : `${i + 1} · ${short(it.name)} · ${it.qty} ${it.unit}`;
    return [{ text, callback_data: `inv:item:${pid}:${i + 1}` }];
  });
  const last = [{ text: '❌ Cancel', callback_data: `inv:no:${pid}` }];
  if (changes.length) last.unshift({ text: `✅ Apply ${plural(changes.length)}`, callback_data: `inv:ok:${pid}` });
  rows.push(last);
  return { inline_keyboard: rows };
}

/** Prompt B: the one question after an item tap. */
export function countQtyPrompt(it: CountItem): string {
  return `🔢 ${it.name}\nSystem has ${it.qty} ${it.unit}. Type the new count.`;
}
