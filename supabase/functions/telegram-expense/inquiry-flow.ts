// SPEC-38 (session 70, D-297 item 2): Telegram taps on a direct request that has not paid yet. Finance (anyone in the group, D-302.2) holds
// the dates 24 h or declines with a reason; Finance and OPS may send a Cassy-drafted reply. Two taps for anything that writes or sends:
// the first shows exactly what the guest would receive, the second does it. The decision lives in telegram_inquiry_decide_v1 (the
// tapper's Telegram id and name, advisory lock, idempotent); this file only renders, routes and calls inquiry-send. Plain text, never Markdown: guest words
// are in these cards. Every Telegram and database call is injected (Deps) so the whole flow runs in inquiry-flow.test.ts.
import { autoKeyboard } from '../_shared/cascade-core/format.ts';
import {
  ALREADY_SENT, asLang, cardMarkup, channelName, channelPlan, type CardExtra, CONFIRM_RPC, confirmedLine, confirmRefusal, declineKeyboard, type DeclineCode, declineLine, declinedResult, DECLINE_LABELS, declinePreview, declinePreviewKeyboard,
  financeCard, firstName, fmtClock, fmtUntil, guestTextSince, heldLine, heldResult, HOLD_HOURS, holdPreview, holdPreviewKeyboard, type InquiryView, joinMessage, lastGuestAt, NO_REQUESTS,
  opsCard, OPS_MONEY_REFUSED, opsDeclinedLine, opsHeldLine, parseIqTap, REASON_PROMPT, sentLine, siteNotes, staleReason, viaOf,
  expectedOf, isUuid, opsConfirmedLine, paidPrompt, type PaidReply, receiptMethod,
} from '../_shared/cascade-core/inquiry.ts';
import { hasMoney } from '../_shared/ops-money.ts';
import { type Delivery, sendAndLog, type SendIO } from './inquiry-send.ts';

export type Deps = {
  // deno-lint-ignore no-explicit-any
  db: any;
  financeChat: string; opsChat: string;
  // deno-lint-ignore no-explicit-any
  send: (chatId: any, text: string, extra?: Record<string, unknown>) => Promise<any>;
  // deno-lint-ignore no-explicit-any
  edit: (chatId: any, mid: number, text: string, rm?: unknown) => Promise<any>;
  /** a photo card's caption (the receipt card); the receipt card is a text message when its caption was too long */
  // deno-lint-ignore no-explicit-any
  editCaption: (chatId: any, mid: number, caption: string, rm?: unknown) => Promise<any>;
  answer: (cbId: string, text?: string) => Promise<unknown>;
  /** hand a synthetic Telegram update to telegram-cassy; false when it could not be reached */
  forward: (update: unknown) => Promise<boolean>;
  /** SPEC-16: ask one person one question (a telegram_pending awaiting_reply row, then the prompt with Cancel).
   *  SPEC-44 inquiry_paid: the prompt is a force_reply (10 minutes) and only a reply to it counts. */
  // deno-lint-ignore no-explicit-any
  ask: (chatId: any, fromId: unknown, flow: 'inquiry_reason' | 'inquiry_paid', refs: Record<string, unknown>, text: string) => Promise<void>;
  io: SendIO;
  now: () => number;
  /** Finance only: today's rate-card total for the request's dates, or null */
  rateToday?: (v: InquiryView) => Promise<number | null>;
};

const SEP = '\n\n➖➖➖➖\n';
/** The card as it was before any preview was appended to it (Back, and every result line, start from this). */
export const stripPreview = (text: string): string => String(text ?? '').split(SEP)[0];
const withPreview = (text: string, preview: string) => `${stripPreview(text)}${SEP}${preview}`;
// deno-lint-ignore no-explicit-any
const who = (from: any) => String(from?.first_name ?? from?.username ?? 'Team').slice(0, 30);
// deno-lint-ignore no-explicit-any
const missing = (e: any) => /does not exist|could not find|PGRST202|42883/i.test(`${e?.code ?? ''} ${e?.message ?? ''}`);
const NOT_ON = '⚠️ Booking decisions in Telegram are not switched on yet (database update pending). Nothing was changed.';

async function getView(d: Deps, id: string | null): Promise<InquiryView | null> {
  const { data, error } = await d.db.rpc('telegram_inquiry_view_v1', { p_booking_id: id });
  if (error) throw new Error(missing(error) ? NOT_ON : `could not read the request: ${String(error.message).slice(0, 120)}`);
  return ((Array.isArray(data) ? data[0] : null) ?? null) as InquiryView | null;
}

async function extraFor(d: Deps, v: InquiryView, surface: 'finance' | 'ops'): Promise<CardExtra> {
  const t = await d.io.thread(v.id).catch(() => null);
  return {
    lastMessage: t ? joinMessage(guestTextSince(t.history, v.submitted_at)) : siteNotes(v.notes), via: viaOf(v.notes),
    rateToday: surface === 'finance' && d.rateToday ? await d.rateToday(v).catch(() => null) : null,
  };
}
async function planFor(d: Deps, v: InquiryView) {
  const t = await d.io.thread(v.id).catch(() => null);
  return { lang: asLang(t?.booking_flow?.lang), plan: channelPlan({ hasThread: !!t, lastGuestAt: lastGuestAt(t?.history), hasEmail: !!v.guest_email, now: d.now() }) };
}

/** The refusal an RPC answer maps to, as one plain sentence. `keep`: the buttons stay for another try. */
// deno-lint-ignore no-explicit-any
function refusal(r: any, by: string): { line: string; keep: boolean; stale: boolean } {
  const k = String(r?.reason ?? r?.outcome ?? '');
  const map: Record<string, string> = {
    no_tapper: `⛔ Telegram did not say who tapped, ${by}. Please tap again. Nothing changed.`,
    conflict: '⚠️ Those dates are no longer free (another booking or hold overlaps), so nothing was held.',
  };
  if (map[k]) return { line: map[k], keep: true, stale: false };
  return { line: `⚠️ ${k || 'unknown result'}. Nothing changed.`, keep: false, stale: ['not_pending', 'receipt_arrived', 'not_found', 'invalid_state'].includes(k) };
}

/** `held` once Finance held it in Telegram (Hold then drops off the card); a hold the guest's own site request opened keeps the button, because Hold extends it and tells the guest. */
const heldState = (v: InquiryView) => (v.held_at ? 'held' as const : 'open' as const);
const rm = (v: InquiryView, text: string, state?: 'held' | 'open') => cardMarkup(v, 'finance', text, state);

/** Edit the card to say why it can no longer be acted on (no buttons). */
// deno-lint-ignore no-explicit-any
async function closeCard(d: Deps, chatId: any, mid: number, text: string, v: InquiryView | null): Promise<void> {
  await d.edit(chatId, mid, `${stripPreview(text)}\n\n${staleReason(v) ?? 'This request is no longer open.'}`);
}

/** One sentence for the card: where the message went, or what to do by hand when it did not reach the guest (Finance cards only). */
function sentText(del: Delivery, first: string, text: string, v: InquiryView): string {
  if (del.delivered) return `Sent to ${first} on ${channelName(del.channel)}.`;
  const where = v.guest_phone ? ` Send it by SMS to ${v.guest_phone}:` : ' Send it yourself:';
  return `The message did not reach ${first} (${del.detail || 'no channel'}).${where}\n📨 ⤵\n${text}`;
}

/** The tap on a request card. Every path ends in an edit of the tapped card, a toast, or a message; nothing is silent. */
// deno-lint-ignore no-explicit-any
export async function onIqTap(d: Deps, cq: any): Promise<void> {
  const chatId = cq.message?.chat?.id, mid = cq.message?.message_id, data = String(cq.data ?? '');
  const text = String(cq.message?.text ?? ''), by = who(cq.from), isFin = String(chatId) === d.financeChat;
  const tap = parseIqTap(data);
  if (!tap) { await d.answer(cq.id, 'That button is not valid. Nothing changed.'); return; }

  // ---- taps that never write the booking ----
  if (tap.kind === 'drop') {
    await d.answer(cq.id);
    await d.db.from('telegram_pending').delete().eq('id', tap.id).eq('kind', 'inquiry_reply');
    await d.edit(chatId, mid, '🗑 Discarded. Nothing was sent.');
    return;
  }
  if (tap.kind === 'send') { await onSend(d, cq, tap.id, by, isFin); return; }
  if (tap.kind === 'draft') { await onDraft(d, cq, tap.id, text); return; }

  await d.answer(cq.id);
  const v = await getView(d, tap.id);
  // A request that closed (or got a receipt) since the card was drawn: say why, and stop. Back also refreshes the card.
  if (!v || staleReason(v)) { await closeCard(d, chatId, mid, text, v); return; }
  if (!isFin) return; // Hold, Decline and their previews are Finance's; OPS never sees these buttons
  const orig = stripPreview(text);

  if (tap.kind === 'back') { await d.edit(chatId, mid, orig, rm(v, orig, heldState(v))); return; }
  if (tap.kind === 'paid') {
    // SPEC-44: one question to the tapper; the card stays as it is until the answer confirms.
    const expected = expectedOf(v);
    await d.ask(chatId, cq.from?.id, 'inquiry_paid', { booking_id: v.id, card_mid: mid, card_text: orig, expected }, paidPrompt(v, expected));
    return;
  }
  if (tap.kind === 'hold') {
    const { lang, plan } = await planFor(d, v);
    const until = new Date(Math.max(d.now() + HOLD_HOURS * 3_600_000, Date.parse(v.hold_expires_at ?? '') || 0)).toISOString(); // the RPC keeps a later site hold, so the preview must name the same time
    const note = v.hold_expires_at ? '' : `\nThis request has no timer today. After this it is released if no receipt arrives within ${HOLD_HOURS} h.`;
    await d.edit(chatId, mid, withPreview(text, holdPreview(v, heldLine(v, lang, until), until, channelName(plan.channel)) + note), { inline_keyboard: holdPreviewKeyboard(v.id) });
    return;
  }
  if (tap.kind === 'dec') {
    await d.edit(chatId, mid, withPreview(text, 'Why decline? Pick a reason. Each one sends the guest a short polite message, except Duplicate or test.'), { inline_keyboard: declineKeyboard(v.id) });
    return;
  }
  if (tap.kind === 'dr') {
    if (tap.code === 'other') {
      await d.edit(chatId, mid, orig, rm(v, orig, heldState(v)));
      await d.ask(chatId, cq.from?.id, 'inquiry_reason', { booking_id: v.id, card_mid: mid }, REASON_PROMPT);
      return;
    }
    const { lang, plan } = await planFor(d, v);
    await d.edit(chatId, mid, withPreview(text, declinePreview(v, tap.code, declineLine(tap.code, v, lang), channelName(plan.channel))), { inline_keyboard: declinePreviewKeyboard(tap.code, v.id) });
    return;
  }
  if (tap.kind === 'holdok') { await onHoldOk(d, cq, v, text, by); return; }
  if (tap.kind === 'dx') {
    if (tap.code === 'other') { await d.edit(chatId, mid, withPreview(text, 'Tap Other and type the reason first.'), { inline_keyboard: declineKeyboard(v.id) }); return; }
    const { data: r, error } = await d.db.rpc('telegram_inquiry_decide_v1', { p_telegram_user_id: cq.from?.id ?? null, p_booking_id: v.id, p_action: 'decline', p_reason_code: tap.code, p_hold_hours: HOLD_HOURS, p_actor_name: by });
    if (error) { await d.edit(chatId, mid, `${text}\n\n${missing(error) ? NOT_ON : `⚠️ ${String(error.message).slice(0, 140)}. Nothing was changed.`}`, cq.message?.reply_markup); return; }
    if (!r?.ok) {
      const f = refusal(r, by);
      if (f.stale) { await closeCard(d, chatId, mid, text, await getView(d, v.id)); return; }
      await d.edit(chatId, mid, `${orig}\n\n${f.line}`, f.keep ? rm(v, orig, heldState(v)) : undefined);
      return;
    }
    await finishDecline(d, cq, v, orig, by, tap.code, null, r);
  }
}

async function onHoldOk(d: Deps, cq: any, v: InquiryView, text: string, by: string): Promise<void> {
  const chatId = cq.message.chat.id, mid = cq.message.message_id, orig = stripPreview(text);
  const { data: r, error } = await d.db.rpc('telegram_inquiry_decide_v1', { p_telegram_user_id: cq.from?.id ?? null, p_booking_id: v.id, p_action: 'hold', p_reason_code: null, p_hold_hours: HOLD_HOURS, p_actor_name: by });
  if (error) { await d.edit(chatId, mid, `${text}\n\n${missing(error) ? NOT_ON : `⚠️ ${String(error.message).slice(0, 140)}. Nothing was changed.`}`, cq.message?.reply_markup); return; }
  if (!r?.ok) {
    const f = refusal(r, by);
    if (f.stale) { await closeCard(d, chatId, mid, text, await getView(d, v.id)); return; }
    await d.edit(chatId, mid, `${orig}\n\n${f.line}`, f.keep ? rm(v, orig, heldState(v)) : undefined);
    return;
  }
  const fresh = (await getView(d, v.id)) ?? v;
  if (r.already_processed) {
    const line = `ℹ️ Already held until ${fmtUntil(r.expires_at ?? fresh.hold_expires_at ?? '')}${fresh.held_by ? ` by ${fresh.held_by}` : ''}. Nothing was sent again.`;
    await d.edit(chatId, mid, `${orig}\n\n${line}`, rm(fresh, orig, 'held'));
    return;
  }
  const until = String(r.expires_at);
  const { lang } = await planFor(d, fresh);
  const line = heldLine(fresh, lang, until);
  const del = await sendAndLog(d.io, fresh, line, { purpose: 'hold', holdExpiresAt: until, tgUserId: cq.from?.id, actorName: by, key: `tg-inquiry-msg:hold:${v.id}` });
  const first = firstName(fresh.guest_name) || 'the guest';
  const result = `${orig}\n\n${heldResult(first, fmtUntil(until), by, fmtClock(d.now()), sentText(del, first, line, fresh))}`;
  await d.edit(chatId, mid, result, rm(fresh, result, 'held'));
  if (d.opsChat) await d.send(d.opsChat, opsHeldLine(fresh, fmtUntil(until), by) + (del.delivered ? '' : ' Finance is sending the message by hand.'));
}

/** After a decline the RPC accepted: send the line (not for dup), log it, edit the card, tell OPS. `r` is the RPC answer. */
// deno-lint-ignore no-explicit-any
async function finishDecline(d: Deps, cq: any, v: InquiryView, head: string, by: string, code: DeclineCode, customText: string | null, r: any): Promise<void> {
  const chatId = cq.message.chat.id, mid = cq.message.message_id;
  if (r.already_processed) { await d.edit(chatId, mid, `${head}\n\nℹ️ Already declined. Nothing was sent again.`); return; }
  const fresh = (await getView(d, v.id)) ?? v;
  const first = firstName(fresh.guest_name) || 'the guest';
  const { lang } = await planFor(d, fresh);
  const msg = customText ?? declineLine(code, fresh, lang);
  let del: Delivery | null = null;
  if (msg !== null && code !== 'dup') del = await sendAndLog(d.io, fresh, msg, { purpose: 'decline', tgUserId: cq.from?.id, actorName: by, key: `tg-inquiry-msg:decline:${v.id}` });
  const result = declinedResult(by, fmtClock(d.now()), code === 'other' ? 'other reason' : DECLINE_LABELS[code].toLowerCase(), del === null ? 'No message was sent to the guest.' : sentText(del, first, msg ?? '', fresh));
  await d.edit(chatId, mid, `${head}\n\n${result}`, del && !del.delivered ? autoKeyboard(result) : undefined);
  if (d.opsChat) await d.send(d.opsChat, opsDeclinedLine(fresh, by));
}

// ---- Cassy reply and "Other" decline ----

// deno-lint-ignore no-explicit-any
async function onDraft(d: Deps, cq: any, id: string, text: string): Promise<void> {
  const chatId = cq.message.chat.id, mid = cq.message.message_id;
  const v = await getView(d, id);
  if (!v || staleReason(v)) { await d.answer(cq.id, staleReason(v) ?? 'That request no longer exists.'); await closeCard(d, chatId, mid, text, v); return; }
  await d.answer(cq.id, 'Cassy is drafting…');
  const ok = await d.forward({ update_id: Number(cq.id) || d.now(), message: { message_id: mid, date: Math.floor(d.now() / 1000), chat: cq.message.chat, from: cq.from, text: `cassy inquiry: reply ${id}` } });
  if (!ok) await d.send(chatId, '⚠️ Cassy could not be reached, so nothing was drafted. Tap ✍️ Cassy reply again in a minute.');
}

/** The reply to the "Other" reason question (flow inquiry_reason): the words go to Cassy, who drafts the polite line. Nothing is declined yet. */
// deno-lint-ignore no-explicit-any
export async function onInquiryReason(d: Deps, msg: any, p: { booking_id?: string; card_mid?: number }, reason: string): Promise<void> {
  const chatId = msg.chat?.id;
  if (!p.booking_id) { await d.send(chatId, '⚠️ That question lost its request, so nothing was drafted.'); return; }
  const ok = await d.forward({ update_id: Number(msg.message_id) || d.now(), message: { message_id: p.card_mid ?? msg.message_id, date: Math.floor(d.now() / 1000), chat: msg.chat, from: msg.from, text: `cassy inquiry: decline ${p.booking_id} ||| ${reason}` } });
  await d.send(chatId, ok ? '✍️ Cassy is writing the message. Nothing is declined or sent until you tap Decline and send on her draft.' : '⚠️ Cassy could not be reached, so nothing was drafted or declined. Tap Decline and Other again in a minute.', { reply_to_message_id: msg.message_id, allow_sending_without_reply: true });
}

// ---- SPEC-44: confirm on the one-tap RPC ----

const NOT_ON_CONFIRM = '⚠️ One-tap confirm is not switched on yet (database update pending). Nothing was confirmed; use the Inquiries page in the admin.';
/** Fable audit (s76): a lost answer may still have confirmed, so it never says nothing was. */
export const NO_ANSWER = '⚠️ The answer did not come back; check the booking on the Inquiries page before trying again.';
/** The one-tap RPC. `said`: the line to show when it errored or never answered (a missing function is the only sure "nothing"). */
// deno-lint-ignore no-explicit-any
async function callConfirm(d: Deps, args: Record<string, unknown>): Promise<{ r: any; said: string | null }> {
  try {
    const { data, error } = await d.db.rpc(CONFIRM_RPC, args);
    if (error) return { r: null, said: missing(error) ? NOT_ON_CONFIRM : NO_ANSWER };
    return { r: data, said: null };
  } catch (e) { console.error('confirm_rpc', String(e).slice(0, 160)); return { r: null, said: NO_ANSWER }; }
}

/** The reply to the Paid – confirm prompt, already parsed (flow inquiry_paid; index.ts consumed the question). `pid` is that question's
 *  row: the idempotency key, so a retried update cannot confirm twice. Ref and amount stay in Finance; OPS gets the usual line. */
// deno-lint-ignore no-explicit-any
export async function onInquiryPaid(d: Deps, msg: any, p: { booking_id?: string; card_mid?: number; card_text?: string; expected?: number | null }, a: PaidReply, pid: string): Promise<void> {
  const chatId = msg.chat?.id, by = who(msg.from);
  const reply = (t: string) => d.send(chatId, t, { reply_to_message_id: msg.message_id, allow_sending_without_reply: true });
  if (!isUuid(p.booking_id)) { await reply('⚠️ That question lost its request, so nothing was confirmed.'); return; }
  const amount = a.amount ?? (Number(p.expected) > 0 ? Number(p.expected) : null);
  if (amount === null) { await reply(confirmRefusal({ outcome: 'amount_required' }, by, 'request').line); return; }
  const { r, said } = await callConfirm(d, {
    p_telegram_user_id: msg.from?.id ?? null, p_booking_id: p.booking_id, p_method: a.method, p_reference: a.reference, p_amount: amount,
    p_note: a.method === 'cash' ? `cash seen by ${by}` : null, p_comparison_id: null, p_idempotency_key: `tg-paid:${pid}`,
  });
  if (said) { await reply(said); return; }
  if (!r?.ok || r.outcome !== 'confirmed') { await reply(confirmRefusal(r, by, 'request').line); return; }
  if (p.card_mid) await d.edit(chatId, Number(p.card_mid), `${stripPreview(String(p.card_text ?? '')) || '📬 BOOKING · Request'}\n\n${confirmedLine(by, a.method, a.reference)}`);
  await reply('✅ Confirmed. The request card above is updated.');
  if (d.opsChat && !r.already_processed) await d.send(d.opsChat, opsConfirmedLine(p.booking_id, by)); // a replay posts nothing twice
}

/** The receipt card's ✅ Confirm booking (bk_ok:<comparison id>): the one-tap RPC with that comparison, the method from where the
 *  request came from, and the reference and amount the receipt read gave. The card is a photo caption, or text when it was long. */
// deno-lint-ignore no-explicit-any
export async function onReceiptConfirm(d: Deps, cq: any, cmpId: string): Promise<void> {
  const chatId = cq.message?.chat?.id, mid = cq.message?.message_id, by = who(cq.from);
  const isCaption = typeof cq.message?.caption === 'string';
  const body = String(cq.message?.caption ?? cq.message?.text ?? '');
  const put = (line: string, keep: boolean) => (isCaption ? d.editCaption : d.edit)(chatId, mid, `${body}\n\n${line}`, keep ? cq.message?.reply_markup : undefined);
  if (!isUuid(cmpId)) { await put('⚠️ That button is not valid. Nothing changed.', false); return; }
  const { data: cmp } = await d.db.from('payment_evidence_comparisons').select('booking_id,evidence_candidate_ids').eq('id', cmpId).maybeSingle();
  if (!cmp?.booking_id) { await put(`⚠️ That receipt check is no longer on file, so nothing was confirmed. Confirm it from the Inquiries page in the admin.`, false); return; }
  const cid = (cmp.evidence_candidate_ids ?? [])[0];
  const { data: cand } = cid ? await d.db.from('payment_evidence_candidates').select('normalized_amount,normalized_reference').eq('id', cid).maybeSingle() : { data: null };
  const { data: bk } = await d.db.from('booking_inquiries').select('notes').eq('id', cmp.booking_id).maybeSingle();
  const method = receiptMethod(bk?.notes), ref = cand?.normalized_reference ?? null;
  const { r, said } = await callConfirm(d, {
    p_telegram_user_id: cq.from?.id ?? null, p_booking_id: cmp.booking_id, p_method: method, p_reference: ref,
    p_amount: cand?.normalized_amount != null ? Number(cand.normalized_amount) : null, p_note: null, p_comparison_id: cmpId,
    // A key per tap (the callback query id; Telegram redelivers the same tap with the same id), so a refused tap - dates taken,
    // a hold in the way - never pins its outcome on this card for later taps (Fable SQL-lane audit, s76).
    p_idempotency_key: `tg-receipt:${cmpId}:${String(cq.id ?? 'tap').replace(/[^A-Za-z0-9_-]/g, '').slice(0, 60)}`,
  });
  if (said) { await put(said, true); return; }
  if (!r?.ok || r.outcome !== 'confirmed') { const f = confirmRefusal(r, by, 'receipt'); await put(f.line, f.keep); return; }
  await put(confirmedLine(by, method, ref), false);
  if (d.opsChat && !r.already_processed) await d.send(d.opsChat, opsConfirmedLine(String(cmp.booking_id), by)); // a second tap posts nothing twice
}

/** A pending row, deleted and returned in one call: one winner. null when gone, expired, the wrong kind or from another chat. */
// deno-lint-ignore no-explicit-any
async function takePending(d: Deps, pid: string, chatId: any) {
  const { data } = await d.db.from('telegram_pending').delete().eq('id', pid).eq('kind', 'inquiry_reply').select('id,chat_id,kind,payload,expires_at').maybeSingle();
  if (!data) return null;
  if (new Date(data.expires_at) < new Date(d.now()) || String(data.chat_id) !== String(chatId)) return null;
  return data;
}

// deno-lint-ignore no-explicit-any
async function onSend(d: Deps, cq: any, pid: string, by: string, isFin: boolean): Promise<void> {
  const chatId = cq.message.chat.id, mid = cq.message.message_id, text = String(cq.message?.text ?? '');
  // Peek before consuming: an OPS tap on a draft that carries money must not use the draft up.
  const { data: peek } = await d.db.from('telegram_pending').select('payload').eq('id', pid).eq('kind', 'inquiry_reply').maybeSingle();
  if (peek && !isFin && (peek.payload?.ops_ok === false || hasMoney(String(peek.payload?.text ?? '')))) { await d.answer(cq.id, OPS_MONEY_REFUSED); return; }
  const row = await takePending(d, pid, chatId);
  if (!row) { await d.answer(cq.id, ALREADY_SENT); return; }
  await d.answer(cq.id);
  const p = row.payload ?? {}, msgText = String(p.text ?? '');
  const v = await getView(d, String(p.booking_id ?? ''));
  if (!v || v.status !== 'pending') { await d.edit(chatId, mid, `${stripPreview(text)}\n\n${staleReason(v) ?? 'This request is no longer open.'} Nothing was sent.`); return; }
  const first = firstName(v.guest_name) || 'the guest';

  if (p.purpose === 'decline') {
    // The RPC decides first; the message goes only when this tap is the one that declined. A refused tap puts the draft back.
    const { data: r, error } = isFin ? await d.db.rpc('telegram_inquiry_decide_v1', { p_telegram_user_id: cq.from?.id ?? null, p_booking_id: v.id, p_action: 'decline', p_reason_code: 'other', p_hold_hours: HOLD_HOURS, p_actor_name: by }) : { data: null, error: null };
    const refused = !isFin || !!error || !r?.ok;
    if (refused) {
      const f = !isFin ? { line: 'A decline is sent from the Finance group. Nothing was sent.', keep: true, stale: false } : error ? { line: missing(error) ? NOT_ON : `⚠️ ${String(error.message).slice(0, 140)}. Nothing was changed.`, keep: true, stale: false } : refusal(r, by);
      if (f.keep) await d.db.from('telegram_pending').insert({ id: row.id, chat_id: row.chat_id, kind: row.kind, payload: row.payload, expires_at: row.expires_at });
      if (f.stale) { await closeCard(d, chatId, mid, text, await getView(d, v.id)); return; }
      await d.edit(chatId, mid, `${text}\n\n${f.line}`, f.keep ? cq.message?.reply_markup : undefined);
      return;
    }
    await finishDecline(d, cq, v, `❌ Decline ${first}'s request`, by, 'other', msgText, r);
    return;
  }

  if (!isFin && (p.ops_ok === false || hasMoney(msgText))) { await d.edit(chatId, mid, OPS_MONEY_REFUSED); return; }
  const del = await sendAndLog(d.io, v, msgText, { purpose: 'reply', tgUserId: cq.from?.id, actorName: by, key: `tg-inquiry-msg:${pid}` });
  const head = sentLine(first, del.channel, by, fmtClock(d.now()));
  if (del.delivered) await d.edit(chatId, mid, `${head}\n\n${msgText}`);
  else if (isFin) await d.edit(chatId, mid, `⚠️ ${sentText(del, first, msgText, v)}`, autoKeyboard('📨 ⤵'));
  else {
    // OPS never sees the guest's phone, e-mail or the channel detail (SPEC-38 s2): the SMS fallback goes to Finance as its own card.
    const fallback = d.financeChat ? await d.send(d.financeChat, `⚠️ ${sentText(del, first, msgText, v)}
(Tapped Send in the OPS group: ${by}.)`, { reply_markup: autoKeyboard('📨 ⤵') }).then((r) => r?.ok !== false, () => false) : false;
    await d.edit(chatId, mid, `⚠️ The message did not reach ${first}. ${fallback ? 'Finance has been sent the text to pass on by hand.' : 'Tell Finance, who can send it by hand.'}`);
  }
}

// ---- /requests ----

/** Up to 5 open requests, oldest first, each as its own card for this chat (Finance: full card and buttons; OPS: the money-free card). */
// deno-lint-ignore no-explicit-any
export async function sendRequests(d: Deps, chatId: any): Promise<void> {
  const surface = String(chatId) === d.financeChat ? 'finance' : 'ops';
  const { data, error } = await d.db.rpc('telegram_inquiry_view_v1', { p_booking_id: null });
  if (error) { await d.send(chatId, missing(error) ? NOT_ON : `⚠️ I could not read the requests: ${String(error.message).slice(0, 120)}.`); return; }
  const list = (Array.isArray(data) ? data : []) as InquiryView[];
  if (!list.length) { await d.send(chatId, NO_REQUESTS); return; }
  for (const v of list.slice(0, 5)) {
    const x = await extraFor(d, v, surface);
    const t = surface === 'finance' ? financeCard(v, x) : opsCard(v, x);
    const markup = cardMarkup(v, surface, t, heldState(v));
    await d.send(chatId, t, { disable_web_page_preview: true, ...(markup ? { reply_markup: markup } : {}) });
  }
}
