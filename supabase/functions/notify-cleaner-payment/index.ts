// notify-cleaner-payment v1 (session I)
// Dashboard action: sends a payment invoice card to the OPS Telegram group for a specific cleaning session.
// The cleaner taps "✅ Received Payment" to mark fee_paid_at + fee_acked_at via cleanpayinvoice: callback in telegram-expense.
// verify_jwt: true — requires a valid Supabase user JWT from the dashboard.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';

const SUPABASE_URL  = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const TG_TOKEN      = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const OPS_CHAT      = Deno.env.get('TELEGRAM_CHAT_ID') ?? '';
const PROPERTY_ID   = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const JSON_H        = { 'Content-Type': 'application/json' };
const CORS_H        = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function ok(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...CORS_H, ...JSON_H } });
}
function fail(msg: string, status = 400): Response {
  return new Response(JSON.stringify({ error: msg }), { status, headers: { ...CORS_H, ...JSON_H } });
}

function peso(n: unknown): string {
  const x = Number(n);
  return (isFinite(x) ? x : 0).toLocaleString();
}
function mdEsc(s: unknown): string {
  return String(s ?? '').replace(/([_*`\[])/g, '\\$1');
}
function typeLabelOf(t: string | null | undefined): string {
  return t === 'deep_clean' ? 'Deep Clean' : 'Turnover';
}

async function tgCall(method: string, body: unknown): Promise<any> {
  const r = await fetch(`https://api.telegram.org/bot${TG_TOKEN}/${method}`, {
    method: 'POST',
    headers: JSON_H,
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  return r ? r.json().catch(() => null) : null;
}

Deno.serve(withObservability({ functionName: 'notify-cleaner-payment', route: 'ops' }, async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_H });
  if (req.method !== 'POST') return fail('Method not allowed', 405);

  // ── Auth: validate JWT belongs to a real Supabase user ──
  const authHeader = req.headers.get('Authorization') ?? '';
  if (!authHeader.startsWith('Bearer ')) return fail('Unauthorized', 401);
  const jwt = authHeader.replace('Bearer ', '');

  // Use the user's JWT client just for auth validation
  const userClient = createClient(SUPABASE_URL, jwt);
  const { data: { user }, error: authErr } = await userClient.auth.getUser();
  if (authErr || !user) return fail('Unauthorized', 401);

  // All data ops use service role
  const db = createClient(SUPABASE_URL, SERVICE_ROLE);

  let body: any;
  try { body = await req.json(); } catch { return fail('Invalid JSON'); }

  const sessionId = String(body?.session_id ?? '').trim();
  if (!sessionId) return fail('session_id required');
  if (!OPS_CHAT)  return fail('OPS group not configured', 500);
  if (!TG_TOKEN)  return fail('Telegram not configured', 500);

  // ── Load cleaning session ──
  const { data: sess, error: sessErr } = await db
    .from('cleaning_sessions')
    .select('id,cleaner_name,cleaning_type,cleaned_at,checkin_date,checkout_date,last_guest_name,fee_amount,fee_paid_at')
    .eq('id', sessionId)
    .eq('property_id', PROPERTY_ID)
    .maybeSingle();

  if (sessErr || !sess) return fail('Session not found', 404);
  if (sess.fee_paid_at) return ok({ error: 'Session already marked as paid', already_paid: true }, 409);

  // ── Resolve fee amount ──
  let feeAmount = parseFloat(sess.fee_amount) || 0;
  if (feeAmount <= 0) {
    const sessionDateStr = String(sess.checkout_date ?? sess.checkin_date ?? (sess.cleaned_at ?? '')).slice(0, 10);
    const { data: rate } = await db
      .from('cleaner_rate_schedule')
      .select('regular_rate,general_rate')
      .lte('effective_from', sessionDateStr)
      .order('effective_from', { ascending: false })
      .limit(1)
      .maybeSingle();
    feeAmount = sess.cleaning_type === 'deep_clean'
      ? (Number(rate?.general_rate) || 500)
      : (Number(rate?.regular_rate) || 500);
  }

  const sessionDate = String(sess.checkout_date ?? sess.checkin_date ?? String(sess.cleaned_at ?? '').slice(0, 10));
  const guestName   = sess.last_guest_name || 'Guest';
  const typeLabel   = typeLabelOf(sess.cleaning_type);

  // ── Create pending record (so telegram-expense can handle the callback) ──
  const { data: pending, error: pendingErr } = await db
    .from('telegram_pending')
    .insert({
      chat_id: Number(OPS_CHAT),
      kind: 'cleanpay_invoice',
      payload: {
        sessionId,
        feeAmount,
        cleanerName: sess.cleaner_name ?? 'Cleaner',
        sessionDate,
        guestName,
      },
    })
    .select('id')
    .single();

  if (pendingErr || !pending) {
    console.error('pending insert error:', pendingErr?.message);
    return fail('Could not create pending record', 500);
  }

  const pid = pending.id;

  // ── Send card to OPS group ──
  const cardText = [
    `🧹 *Payment Ready — ${mdEsc(sess.cleaner_name ?? 'Cleaner')}*`,
    ``,
    `📅 ${sessionDate}  ·  ${typeLabel}`,
    `👤 ${mdEsc(guestName)}`,
    `💵 Fee: *₱${peso(feeAmount)}*`,
    ``,
    `_Tap below to confirm you received this payment._`,
  ].join('\n');

  const tgResult = await tgCall('sendMessage', {
    chat_id:      OPS_CHAT,
    text:         cardText,
    parse_mode:   'Markdown',
    reply_markup: {
      inline_keyboard: [[
        { text: '✅ Received Payment', callback_data: `cleanpayinvoice:${pid}` },
      ]],
    },
  });

  if (!tgResult?.ok) {
    // Clean up pending record — don't leave orphaned rows
    await db.from('telegram_pending').delete().eq('id', pid);
    console.error('Telegram send failed:', JSON.stringify(tgResult));
    return fail('Telegram send failed — check OPS_CHAT and bot token', 502);
  }

  return ok({ ok: true, message_id: tgResult.result?.message_id });
}));
