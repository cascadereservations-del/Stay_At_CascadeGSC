// Lane C (s81, fix round 2): keep the Finance card in step with a payment the Staff app is handling, so a Telegram person does not tap "Yes sent" for
// someone else's payment. Reuses the card text and buttons telegram-expense already draws (financeCaption / financeKeyboard); the only new state is
// "being paid in the Staff app": same block, no buttons. A paid or cancelled card is redrawn by its own flows and is left alone.
import { financeCaption, financeKeyboard, type PayReq, payBlock, payReference, peso } from '../_shared/cascade-core/staffpay.ts';

export type CardReq = PayReq & { paying_by_user_id?: string | null; paying_by_tg?: number | string | null };
export type CardDeps = { tg: (method: string, body: Record<string, unknown>) => Promise<{ ok?: boolean; description?: string } | null> };

export function webCardText(r: CardReq): string {
  const head = `${r.paying_by_name || 'Someone'} is paying ${r.payee_name} ${peso(r.total_amount)} in the Staff app now. Nothing to tap here until it is paid.`;
  return [head, '', payBlock(r, { receipts: true, clip: 48, budget: 700 }), '', `Ref ${payReference(r)}`].join('\n');
}

export async function redrawFinanceCard(r: CardReq, d: CardDeps): Promise<'edited' | 'skipped' | 'failed'> {
  if (!r.finance_chat_id || !r.finance_message_id) return 'skipped';
  let text: string, reply_markup: unknown;
  if (r.status === 'paying' && r.paying_by_user_id && !r.paying_by_tg) { text = webCardText(r); reply_markup = { inline_keyboard: [] }; }
  else if (r.status === 'requested' || r.status === 'paying') { text = financeCaption(r, true); reply_markup = financeKeyboard(r); }
  else return 'skipped';
  const at = { chat_id: r.finance_chat_id, message_id: r.finance_message_id };
  const res = await d.tg('editMessageCaption', { ...at, caption: text, reply_markup });
  if (res?.ok) return 'edited';
  const why = String(res?.description ?? '');
  if (/not modified/i.test(why)) return 'edited';
  if (/no caption/i.test(why)) return (await d.tg('editMessageText', { ...at, text, reply_markup }))?.ok ? 'edited' : 'failed';
  return 'failed';
}
