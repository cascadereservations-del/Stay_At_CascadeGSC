// notify-cleaner-payment v7 (session 70, SPEC-37, D-296..D-298): the Staff Payment Request poster.
// It was the old dashboard "Send Invoice" (v1, session I): it inserted telegram_pending kind 'cleanpay_invoice', which the kind CHECK has
// refused since B53, and nothing in the new dashboard called it. It is now what the Cascade Staff app calls when a staff member sends a
// payment request: the request is validated and written by ONE definer RPC under the staff member's own JWT
// (staff_pay_request_create_v1: ownership, locks, rates, the 20-line cap, idempotency), then this function posts it:
//   Finance  a photo card (the payee's payout QR rebuilt with the amount by qrph.ts, no storage, no URL) or a text card when no QR is saved,
//            with the Copy / I'm paying this / Cancel buttons; receipt photos (private bucket, signed 15 minutes) as replies under it;
//   OPS      the same block without the QR, the buttons or the receipt marker (D-297.1: OPS may see staff-pay amounts, D-289 unchanged).
// Finance taps and the transfer screenshot are handled by telegram-expense. If the Finance card cannot be posted the request is
// cancelled at once (a request Finance cannot see must not hold the cleans). The payout QR is read here with the service role and is
// never logged. verify_jwt stays false: requireStaffAccess checks the JWT and the submit_cleaning role inside.
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { requireStaffAccess, staffAuthResponse } from '../_shared/staff-auth.ts';
import { qrphWithAmount, qrPng } from '../_shared/cascade-core/qrph.ts';
import { financeCaption, financeKeyboard, opsRequestText, type PayReq, peso } from '../_shared/cascade-core/staffpay.ts';
import { parseRequest } from './request.ts';

const SUPABASE_URL  = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SERVICE_ROLE  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const TG_TOKEN      = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const FINANCE_CHAT  = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID') ?? '';
const OPS_CHAT      = Deno.env.get('TELEGRAM_CHAT_ID') ?? '';
const PROPERTY_ID   = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const CORS_H = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function reply(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...CORS_H, 'Content-Type': 'application/json' } });
}

// deno-lint-ignore no-explicit-any
async function tg(method: string, body: BodyInit, json: boolean): Promise<any> {
  const r = await fetch(`https://api.telegram.org/bot${TG_TOKEN}/${method}`, {
    method: 'POST', ...(json ? { headers: { 'Content-Type': 'application/json' } } : {}), body, signal: AbortSignal.timeout(20_000),
  }).catch(() => null);
  return r ? r.json().catch(() => null) : null;
}
const tgJson = (method: string, body: Record<string, unknown>) => tg(method, JSON.stringify(body), true);

/** The photo card: the QR PNG as a multipart upload, caption and keyboard alongside. */
function tgPhoto(chatId: string, png: Uint8Array, caption: string, replyMarkup: unknown) {
  const form = new FormData();
  form.append('chat_id', chatId);
  form.append('photo', new Blob([png as unknown as BlobPart], { type: 'image/png' }), 'pay-qr.png');
  form.append('caption', caption);
  form.append('reply_markup', JSON.stringify(replyMarkup));
  return tg('sendPhoto', form, false);
}

/** Receipt photos under the Finance card: one sendPhoto, or one sendMediaGroup for 2 to 10. A failure here is logged, never fatal. */
// deno-lint-ignore no-explicit-any
async function postReceipts(db: any, requestId: string, financeMessageId: number): Promise<void> {
  const { data: rows } = await db.from('cleaning_expense_claims').select('description,amount,receipt_path').eq('pay_request_id', requestId).not('receipt_path', 'is', null).limit(10);
  const shots: Array<{ url: string; caption: string }> = [];
  for (const k of rows ?? []) {
    const { data: signed } = await db.storage.from('cleaning-photos').createSignedUrl(String(k.receipt_path), 900);
    if (signed?.signedUrl) shots.push({ url: signed.signedUrl, caption: `Receipt · ${String(k.description).replace(/\s+/g, ' ').slice(0, 200)} · ${peso(k.amount)}` });
  }
  if (!shots.length) return;
  const at = { chat_id: FINANCE_CHAT, reply_to_message_id: financeMessageId, allow_sending_without_reply: true };
  const res = shots.length === 1
    ? await tgJson('sendPhoto', { ...at, photo: shots[0].url, caption: shots[0].caption })
    : await tgJson('sendMediaGroup', { ...at, media: shots.map((s) => ({ type: 'photo', media: s.url, caption: s.caption })) });
  if (!res?.ok) console.warn('receipt photos not posted:', String(res?.description ?? 'no answer').slice(0, 120));
}

Deno.serve(withObservability({ functionName: 'notify-cleaner-payment', route: 'ops' }, async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_H });
  if (req.method !== 'POST') return reply({ ok: false, reason: 'method_not_allowed' }, 405);

  let identity;
  try { identity = await requireStaffAccess(req, 'submit_cleaning', PROPERTY_ID); }
  catch (e) { const r = staffAuthResponse(e, CORS_H); if (r) return r; throw e; }
  if (!TG_TOKEN || !FINANCE_CHAT || !SUPABASE_ANON) return reply({ ok: false, reason: 'not_configured' }, 500);

  const parsed = parseRequest(await req.json().catch(() => null));
  if (!parsed.ok) return reply({ ok: false, reason: parsed.reason }, 400);
  const { key, sessions, claim_ids, extras } = parsed.value;

  // 1. The request is written under the staff member's own JWT, so auth.uid() is the payee.
  const userDb = createClient(SUPABASE_URL, SUPABASE_ANON, {
    global: { headers: { Authorization: `Bearer ${identity.accessToken}` } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data: created, error } = await userDb.rpc('staff_pay_request_create_v1', {
    p_sessions: sessions, p_claim_ids: claim_ids, p_extras: extras, p_idempotency_key: key,
  });
  if (error) {
    console.error('staff_pay_request_create_v1 failed:', error.code);
    return error.code === '22P02' ? reply({ ok: false, reason: 'bad_request' }, 400) : reply({ ok: false, reason: 'create_failed' }, 500);
  }
  if (!created?.ok) return reply({ ok: false, reason: created?.reason ?? 'refused' }, created?.reason === 'not_authorized' ? 403 : 409);
  // A retry of a request whose card is already posted (or that moved on) posts nothing again.
  if (created.replay && (created.finance_message_id || created.status !== 'requested')) return reply({ ok: true, replay: true, ref: created.ref, total: created.total });

  const r: PayReq = { id: created.request_id, ref: created.ref, status: 'requested', payee_name: created.payee_name, lines: created.lines, total_amount: created.total };
  const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

  // 2. The payee's payout QR, rebuilt with this request's amount. Read with the service role; never logged.
  let png: Uint8Array | null = null;
  const { data: sd } = await db.from('staff_details').select('payout_qrph').eq('user_id', identity.userId).maybeSingle();
  if (typeof sd?.payout_qrph === 'string' && sd.payout_qrph) {
    try { png = await qrPng(qrphWithAmount(sd.payout_qrph, Number(created.total))); }
    catch (e) { console.error('payout QR could not be built:', String((e as Error)?.message ?? e).slice(0, 80)); }
  }

  // 3. Finance. A card Finance cannot see must not hold the cleans: cancel and say so.
  const caption = financeCaption(r, !!png), markup = financeKeyboard(r);
  const card = png
    ? await tgPhoto(FINANCE_CHAT, png, caption, markup)
    : await tgJson('sendMessage', { chat_id: FINANCE_CHAT, text: caption, reply_markup: markup });
  const financeMessageId = Number(card?.result?.message_id);
  if (!card?.ok || !financeMessageId) {
    console.error('Finance card failed:', String(card?.description ?? 'no answer').slice(0, 120));
    await db.rpc('telegram_staff_pay_step_v1', { p_request_id: r.id, p_step: 'cancel', p_actor_tg: null, p_actor_name: 'system: Finance card failed', p_proof: null });
    return reply({ ok: false, reason: 'card_failed' }, 502);
  }
  await postReceipts(db, r.id, financeMessageId).catch((e) => console.warn('receipt photos failed:', String(e).slice(0, 120)));

  // 4. OPS: the summary. A failure is logged, not fatal.
  let opsMessageId: number | null = null;
  if (OPS_CHAT) {
    const ops = await tgJson('sendMessage', { chat_id: OPS_CHAT, text: opsRequestText(r) });
    if (ops?.ok) opsMessageId = Number(ops.result?.message_id) || null;
    else console.warn('OPS post failed:', String(ops?.description ?? 'no answer').slice(0, 120));
  }

  // 5. Remember where the cards are (the first Finance tap repairs this if it fails).
  const ids = { finance_chat_id: Number(FINANCE_CHAT), finance_message_id: financeMessageId, ops_chat_id: OPS_CHAT ? Number(OPS_CHAT) : null, ops_message_id: opsMessageId };
  let saved = await db.from('staff_pay_requests').update(ids).eq('id', r.id);
  if (saved.error) saved = await db.from('staff_pay_requests').update(ids).eq('id', r.id);
  if (saved.error) console.error('card ids not saved:', saved.error.code);

  return reply({ ok: true, ref: r.ref, total: created.total });
}));
