// Lane C (s81): tell the staff member she was paid. Called with action "paid" after a settle, from the database trigger (cron secret) or from the
// Staff app (an owner/admin/finance session). Everything it needs arrives through `PaidDeps`, so the order of events is unit-tested without a network.
//   1. claim the notice once (staff_pay_notice_v1): a second ask, from the trigger AND the app, sends nothing twice.
//   2. Telegram: a request the Staff app settled gets the warm notice in OPS (as a reply to her request, with the Received button) and the Finance
//      card is redrawn as PAID. A request Finance settled in Telegram already got its OPS post from telegram-expense, so Telegram is skipped here.
//   3. Web Push to every phone she turned the toggle on for. A push that fails never blocks the others: one retry for a transient answer (429, 5xx,
//      no answer), none after that; a 404 or 410 deletes that subscription. The lock-screen text carries no amount.
// The in-app notice reads staff_pay_my_requests_v1 and needs nothing from here.
import { noticeText, PUSH_TITLE, pushBody, type PaidNotice } from './paid-text.ts';
import type { PushResult } from '../_shared/C_webpush.ts';

export type NoticeData = PaidNotice & {
  ok: true; request_id: string; payee_user_id: string; payee_name: string; paid_by_tg: number | null;
  ops_chat_id: number | null; ops_message_id: number | null;
};
export type Sub = { id: string; endpoint: string; p256dh: string; auth: string };

export type PaidDeps = {
  claim: (id: string) => Promise<NoticeData | { ok: false; reason: string }>;
  /** A Telegram Bot API call with a JSON body; resolves with the parsed answer or null. Never given a parse_mode. */
  tg: (method: string, body: Record<string, unknown>) => Promise<{ ok?: boolean; description?: string } | null>;
  opsChat: string;
  /** The Finance card's redraw (caption, keyboard) for the settled request, or null when the row cannot be read. */
  financeCard: (id: string) => Promise<{ chat_id: number; message_id: number; text: string; reply_markup: unknown; ops_keyboard: unknown } | null>;
  subs: (userId: string) => Promise<Sub[]>;
  deleteSub: (id: string) => Promise<void>;
  touchSub: (id: string) => Promise<void>;
  /** null when the VAPID secrets are not set: push is skipped, nothing else changes. */
  push: ((s: Sub, m: { title: string; body: string; url: string; tag: string }) => Promise<PushResult>) | null;
  log: (msg: string) => void;
};

export type PaidOutcome = {
  ok: boolean; skipped?: string;
  telegram: 'sent' | 'skipped' | 'failed';
  push: { sent: number; gone: number; failed: number; subscriptions: number };
};

const noPush = { sent: 0, gone: 0, failed: 0, subscriptions: 0 };

export async function runPaid(requestId: string, d: PaidDeps): Promise<PaidOutcome> {
  const n = await d.claim(requestId);
  if (!n.ok) return { ok: n.reason !== 'not_found', skipped: n.reason, telegram: 'skipped', push: noPush };

  let telegram: PaidOutcome['telegram'] = 'skipped';
  try {
    if (n.paid_by_tg == null) {
      const card = await d.financeCard(requestId);
      const chat = n.ops_chat_id ?? (d.opsChat ? Number(d.opsChat) : null);
      if (chat) {
        const res = await d.tg('sendMessage', {
          chat_id: chat, text: noticeText(n),
          ...(card?.ops_keyboard ? { reply_markup: card.ops_keyboard } : {}),
          ...(n.ops_message_id ? { reply_to_message_id: n.ops_message_id, allow_sending_without_reply: true } : {}),
        });
        telegram = res?.ok ? 'sent' : 'failed';
        if (!res?.ok) d.log(`paid notice: OPS post failed (${String(res?.description ?? 'no answer').slice(0, 80)})`);
      }
      if (card && card.chat_id && card.message_id) {
        const e = await d.tg('editMessageCaption', { chat_id: card.chat_id, message_id: card.message_id, caption: card.text, reply_markup: card.reply_markup });
        if (!e?.ok && /no caption/i.test(String(e?.description ?? ''))) await d.tg('editMessageText', { chat_id: card.chat_id, message_id: card.message_id, text: card.text, reply_markup: card.reply_markup });
      }
    }
  } catch (e) {
    telegram = 'failed';
    d.log(`paid notice: Telegram step threw (${String((e as Error)?.message ?? e).slice(0, 80)})`);
  }

  const push = { ...noPush };
  try {
    const subs = d.push ? await d.subs(n.payee_user_id) : [];
    push.subscriptions = subs.length;
    const message = { title: PUSH_TITLE, body: pushBody(n), url: './#home', tag: 'cascade-paid' };
    for (const s of subs) {
      try {
        let r = await d.push!(s, message);
        if (!r.ok && r.transient) r = await d.push!(s, message); // one retry, never more
        if (r.ok) { push.sent++; await d.touchSub(s.id); }
        else if (r.gone) { push.gone++; await d.deleteSub(s.id); }
        else push.failed++;
      } catch { push.failed++; }
    }
  } catch (e) {
    d.log(`paid notice: push step threw (${String((e as Error)?.message ?? e).slice(0, 80)})`);
  }
  return { ok: true, telegram, push };
}
