// Session 70 (SPEC-37, D-298): the Finance side of the Staff Payment Request, kept out of index.ts so the three edits there stay small.
//   onPayReqTap    every spr: button on the Finance card: I'm paying this, Yes sent, No not sent, Amount is right, Cancel request.
//   onPayReqPhoto  the transfer screenshot (a photo, or an image sent as a document): read once, then one definer RPC decides.
// The database decides everything (telegram_staff_pay_step_v1 locks the request, settles the existing ledger and refuses a second
// payment); this file only maps taps and photos to that call and writes the answer on the card. Anyone in the Finance chat may tap
// (D-298.2); a tap from OPS answers FINANCE_ONLY. Card and posts are plain text: no parse_mode is ever set. Nothing here logs a
// screenshot, a payload or an account number.
import {
  duplicateText, financeCaption, financeKeyboard, matchText, mismatchKeyboard, mismatchText, normaliseProof, opsCancelText, opsPaidKeyboard,
  opsPaidText, parseSprTap, type PayReq, PROOF_PROMPT, proofPrompt, proofVerdict, RPC_STEP, tapRefusal,
} from '../_shared/cascade-core/staffpay.ts';
import { parseModelJson } from '../_shared/cascade-core/vision.ts';

export type PayDeps = {
  db: any;
  /** A raw Telegram Bot API call. Never given a parse_mode here. */
  call: (method: string, body: Record<string, unknown>) => Promise<any>;
  answer: (cbId: string, text?: string) => Promise<any>;
  isFinance: (chatId: unknown) => boolean;
  financeOnly: string;
  opsChat: string;
  /** Opens the one open question "send the screenshot" for this person (flow payreq_proof, 30 minutes). */
  askProof: (chatId: unknown, fromId: unknown, rid: string, text: string) => Promise<void>;
  photo: (fileId: string) => Promise<{ bytes: Uint8Array; mime: string } | null>;
  read: (prompt: string, bytes: Uint8Array, mime: string) => Promise<string>;
  visionReady: () => boolean;
};

const who = (from: any) => String(from?.first_name ?? from?.username ?? 'Finance').slice(0, 30);
const errText = (e: any) => String(e?.message ?? e ?? 'unknown error').replace(/\s+/g, ' ').slice(0, 140);

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as unknown as BufferSource)), (b) => b.toString(16).padStart(2, '0')).join('');
}

async function load(d: PayDeps, id: string): Promise<PayReq | null> {
  const { data } = await d.db.from('staff_pay_requests').select('*').eq('id', id).maybeSingle();
  return (data ?? null) as PayReq | null;
}

/** Redraw the Finance card: a photo card edits its caption, a text card (no QR saved) its text. */
async function editCard(d: PayDeps, r: PayReq, hasQr: boolean): Promise<void> {
  if (!r.finance_chat_id || !r.finance_message_id) return;
  const text = financeCaption(r, hasQr), rm = financeKeyboard(r);
  const res = await d.call('editMessageCaption', { chat_id: r.finance_chat_id, message_id: r.finance_message_id, caption: text, reply_markup: rm });
  if (res?.ok) return;
  const why = String(res?.description ?? '');
  if (/no caption/i.test(why)) await d.call('editMessageText', { chat_id: r.finance_chat_id, message_id: r.finance_message_id, text, reply_markup: rm });
  else if (!/not modified/i.test(why)) console.warn('staffpay card edit failed:', why.slice(0, 120));
}

/** A post to OPS as a reply to the request post (the post may be gone: allow_sending_without_reply). */
async function opsReply(d: PayDeps, r: PayReq, text: string, rm?: unknown): Promise<void> {
  const chat = r.ops_chat_id ?? d.opsChat;
  if (!chat) return;
  await d.call('sendMessage', {
    chat_id: chat, text, ...(rm ? { reply_markup: rm } : {}),
    ...(r.ops_message_id ? { reply_to_message_id: r.ops_message_id, allow_sending_without_reply: true } : {}),
  });
}

/** The open "send the screenshot" questions for a request are done once it is paid, cancelled or taken back. */
async function closeProofQuestions(d: PayDeps, rid: string): Promise<void> {
  await d.db.from('telegram_pending').delete().eq('kind', 'awaiting_reply').eq('payload->>flow', 'payreq_proof').eq('payload->>rid', rid);
}

/** Every spr: button. The caller has not answered the tap; this answers it exactly once. */
export async function onPayReqTap(d: PayDeps, cq: any): Promise<void> {
  const chatId = cq.message?.chat?.id, tap = parseSprTap(String(cq.data ?? ''));
  if (!tap) { await d.answer(cq.id, 'That button is not valid. Nothing changed.'); return; }
  if (!d.isFinance(chatId)) { await d.answer(cq.id, d.financeOnly); return; }
  const actor = who(cq.from);
  const { data: res, error } = await d.db.rpc('telegram_staff_pay_step_v1', {
    p_request_id: tap.id, p_step: RPC_STEP[tap.step], p_actor_tg: cq.from?.id ?? null, p_actor_name: actor, p_proof: null,
  });
  if (error || !res) {
    console.error('staffpay step failed:', errText(error ?? 'no result'));
    await d.answer(cq.id, 'That tap failed, so nothing was changed. Try again in a minute.');
    return;
  }
  if (res.ok === false) {
    const row = res.reason === 'already_paid' ? await load(d, tap.id) : null;
    await d.answer(cq.id, tapRefusal(String(res.reason), { status: res.status, date: res.date, payee: row?.payee_name }));
    return;
  }
  await d.answer(cq.id);
  const r = await load(d, tap.id);
  if (!r) return;
  // The poster could not save the card's ids: the first tap does, from the message it was tapped on.
  if ((!r.finance_chat_id || !r.finance_message_id) && cq.message?.message_id) {
    r.finance_chat_id = chatId; r.finance_message_id = cq.message.message_id;
    await d.db.from('staff_pay_requests').update({ finance_chat_id: chatId, finance_message_id: cq.message.message_id }).eq('id', r.id);
  }
  await editCard(d, r, !!cq.message?.photo);
  if (tap.step === 'sent') await d.askProof(chatId, cq.from?.id, r.id, proofPrompt(r, actor));
  if (tap.step === 'no' || r.status === 'paid' || r.status === 'cancelled') await closeProofQuestions(d, r.id);
  if (r.status === 'cancelled') await opsReply(d, r, opsCancelText(r));
  if (r.status === 'paid') await opsReply(d, r, opsPaidText(r), opsPaidKeyboard(r));
}

/**
 * A photo (or an image document) in Finance. It is a transfer screenshot when this person has the payreq_proof question open, or it
 * replies to the card of a request that is paying, so a second Finance member's screenshot never falls into receipt OCR.
 * Returns true when it was ours (the caller then stops), false when it is an ordinary receipt.
 */
export async function onPayReqPhoto(d: PayDeps, msg: any, aw: { id: string; payload: any } | null): Promise<boolean> {
  const chatId = msg.chat?.id;
  if (!d.isFinance(chatId)) return false;
  const awaitingProof = aw?.payload?.flow === 'payreq_proof';
  const replyMid = msg.reply_to_message?.message_id;
  let r: PayReq | null = null;
  if (awaitingProof) r = await load(d, String(aw!.payload.rid ?? ''));
  else if (replyMid) {
    const { data } = await d.db.from('staff_pay_requests').select('*').eq('finance_chat_id', chatId).eq('finance_message_id', replyMid).eq('status', 'paying').maybeSingle();
    r = (data ?? null) as PayReq | null;
    if (!r) return false;
  } else return false;

  const reply = (text: string, extra: Record<string, unknown> = {}) =>
    d.call('sendMessage', { chat_id: chatId, text, reply_to_message_id: msg.message_id, allow_sending_without_reply: true, ...extra });

  const photos = Array.isArray(msg.photo) ? msg.photo : [];
  const doc = msg.document && /^image\//i.test(String(msg.document.mime_type ?? '')) ? msg.document : null;
  const best = doc ?? photos[photos.length - 1];
  if (!best?.file_id) {
    if (awaitingProof) await reply('Send the transfer screenshot as a photo. Nothing is marked paid yet.');
    return awaitingProof;
  }
  if (!r || r.status !== 'paying' || !r.sent_said_at) {
    if (awaitingProof) await d.db.from('telegram_pending').delete().eq('id', aw!.id);
    await reply(tapRefusal('not_waiting_for_proof'));
    return true;
  }
  const got = await d.photo(String(best.file_id));
  if (!got) { await reply('I could not fetch that image, so nothing was saved. Send it again.'); return true; }

  const sha = await sha256Hex(got.bytes);
  let read: ReturnType<typeof normaliseProof> = null;
  if (d.visionReady()) {
    try { read = normaliseProof(parseModelJson<unknown>(await d.read(PROOF_PROMPT, got.bytes, got.mime), null)); }
    catch (e) { console.warn('staffpay proof read failed:', errText(e)); }
  }
  const verdict = proofVerdict(read, r.total_amount);
  if (awaitingProof) await d.db.from('telegram_pending').delete().eq('id', aw!.id);
  const { data: res, error } = await d.db.rpc('telegram_staff_pay_step_v1', {
    p_request_id: r.id, p_step: 'proof', p_actor_tg: msg.from?.id ?? null, p_actor_name: who(msg.from),
    p_proof: { file_unique_id: best.file_unique_id, file_id: best.file_id, sha256: sha, amount: read?.amount ?? null, reference: read?.reference ?? null, read, verdict },
  });
  if (error || !res) {
    console.error('staffpay proof failed:', errText(error ?? 'no result'));
    await reply('I could not record the screenshot, so nothing is marked paid. Tap Send the screenshot on the card and try again.');
    return true;
  }
  if (res.ok === false) {
    await reply(res.reason === 'duplicate_proof' ? duplicateText(String(res.other_ref ?? '')) : tapRefusal(String(res.reason), { status: res.status, date: res.date, payee: r.payee_name }));
    return true;
  }
  const after = (await load(d, r.id)) ?? r;
  await editCard(d, after, false);
  if (after.status === 'paid') {
    await reply(matchText(after));
    await closeProofQuestions(d, r.id);
    await opsReply(d, after, opsPaidText(after), opsPaidKeyboard(after));
  } else {
    await reply(mismatchText(after, read, verdict), { reply_markup: mismatchKeyboard(r.id) });
  }
  return true;
}
