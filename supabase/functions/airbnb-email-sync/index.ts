// airbnb-email-sync v13
//
// v12 (Step 9 of income-model-v2 / Option B — completes the income_stage model):
//   - Booking insert now sets income_stage='estimated' (Tier 1 estimate).
//   - Payout insert now sets income_stage='confirmed' (Tier 2 canonical).
//   - On payout, the booking-email estimate is now VOIDED (superseded by the
//     canonical payout row), not confirmed — prevents the estimate lingering
//     as a confirmed duplicate. Matches the 59 backfilled void/estimated rows.
//
// Phase D (guest enrichment):
//   - handleBooking now detects returning/VIP guests on every new booking.
//   - Inserts into returning_guest_alerts when guest has prior stays.
//   - Sends OPS notification without financial data (v4 behaviour retained).
//   - Sends Finance notification with guest tier badge + financial details.
//   - Calls refresh_guest_stats() after every booking to keep guests table current.
//
// Phase E (reconciliation mechanism):
//   - handlePayout calls reconcile_reservation_from_transactions() for each
//     confirmation code settled in that payout transfer.
//   - This is the authoritative trigger: a payout email means the booking is
//     financially closed → CSV truth overwrites email-parser estimates.
//   - handleBooking calls reconcile for confirmed codes (financials only —
//     dates stay from email until payout settles the booking).
//
// Authority model (enforced at the function boundary):
//   Financial fields (host_payout, guest_paid)   → airbnb_transactions (CSV)
//   Date fields (checkin, checkout) for completed → airbnb_transactions (CSV)
//   Date fields for confirmed/upcoming            → email (most current source)
//   Operational fields (guest_name, count, times) → email always
//
// v4 retained: OPS notification stripped of all financial figures.
//
// v6 (session 24):
//   - Returning/VIP guest now also sends a stripped operational card to OPS
//     (tier badge, name, stay # — NO peso amounts, NO financial fields).
//     OPS financial isolation rule remains fully intact.

// v7 (session 26, 2026-09-16, Telegram plan §1/§5): every card opens with a withHeader() line;
//   the new-booking card carries guest_context_v1 lines (stay #, last stay, last [URGENT] note,
//   preferences, note, tags, birthday, open follow-ups) and only the lines that have data. The
//   two separate returning-guest cards are folded into it (one card per chat per booking);
//   returning_guest_alerts is still written and stamped sent.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { withHeader, groups, doSend, autoKeyboard, BTN } from '../_shared/cascade-core/format.ts';
import { guestContext, guestContextLines } from '../_shared/cascade-core/tools.ts';

const esc = (s: unknown) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

type LegacyDatabaseClient = {
  from: (relation: string) => any;
  rpc: (functionName: string, args?: Record<string, unknown>) => PromiseLike<any>;
};

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const PROPERTY_ID              = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const TELEGRAM_FINANCE_CHAT_ID = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID');
const TELEGRAM_OPS_CHAT_ID     = Deno.env.get('TELEGRAM_CHAT_ID');
const TELEGRAM_BOT_TOKEN       = Deno.env.get('TELEGRAM_BOT_TOKEN');

async function sendTelegram(chatId: string|undefined, text: string, reply_markup?: unknown): Promise<void> {
  if (!chatId || !TELEGRAM_BOT_TOKEN) return;
  try {
    await fetch(`https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: chatId, text, parse_mode: 'HTML', disable_web_page_preview: true, reply_markup }),
    });
  } catch (_) {}
}

Deno.serve(withObservability({ functionName: 'airbnb-email-sync', route: 'ops' }, async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } }
  ) as unknown as LegacyDatabaseClient;

  let body: { events: EmailEvent[] };
  try { body = await req.json(); }
  catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON' }),
      { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
  }

  const events: EmailEvent[] = body?.events ?? [];
  if (!Array.isArray(events) || events.length === 0)
    return new Response(JSON.stringify({ inserted: 0, skipped: 0, errors: [] }),
      { headers: { ...CORS, 'Content-Type': 'application/json' } });

  const results = { inserted: 0, skipped: 0, errors: [] as string[] };
  for (const event of events) {
    try { await processEvent(supabase, event, results); }
    catch (err) { results.errors.push(`${event.gmail_message_id}: ${String(err)}`); }
  }
  return new Response(JSON.stringify(results),
    { headers: { ...CORS, 'Content-Type': 'application/json' } });
}));

// ── Types ──────────────────────────────────────────────────────────────────
interface EmailEvent {
  gmail_message_id:  string;
  email_type:        'booking'|'payout'|'cancellation';
  email_date:        string;
  subject:           string;
  guest_name?:       string;
  confirmation_code?: string;
  checkin_date?:     string;
  checkout_date?:    string;
  checkin_time?:     string;
  checkout_time?:    string;
  guest_count?:      number;
  guest_paid?:       number;
  host_service_fee?: number;
  host_payout?:      number;
  payout_amount?:    number;
  detail_lines?:     PayoutDetail[];
  cancelled_code?:   string;
  cancelled_dates?:  string;
  guest_first_name?: string;
  refund_type?:      string;
}
interface PayoutDetail {
  guest_name:        string;
  amount:            number;
  line_type:         string;
  checkin_date?:     string;
  checkout_date?:    string;
  confirmation_code?: string;
}
interface GuestRecord {
  id:                  string;
  name:                string;
  tier:                string|null;
  total_stays:         number;
  total_nights_stayed: number;
  first_stay_date:     string|null;
}

// ── Helpers ────────────────────────────────────────────────────────────────
function tierBadge(tier: string|null, stays: number): string {
  if (tier === 'vip')       return `⭐ VIP Guest (${stays} stays)`;
  if (tier === 'returning') return `🔄 Returning Guest (${stays} stays)`;
  return '🆕 New Guest';
}

async function reconcile(supabase: LegacyDatabaseClient, code: string): Promise<void> {
  try {
    await supabase.rpc('reconcile_reservation_from_transactions', { p_code: code });
  } catch (e) {
    console.warn(`reconcile failed for ${code}:`, String(e));
  }
}

async function refreshGuestStats(supabase: LegacyDatabaseClient, guestId: string): Promise<void> {
  try {
    await supabase.rpc('refresh_guest_stats', { p_guest_id: guestId });
  } catch (e) {
    console.warn(`refresh_guest_stats failed for ${guestId}:`, String(e));
  }
}

// ── Event router ───────────────────────────────────────────────────────────
async function processEvent(
  supabase: LegacyDatabaseClient,
  event: EmailEvent,
  results: { inserted: number; skipped: number; errors: string[] }
): Promise<void> {
  const { error: logErr } = await supabase.from('airbnb_email_events').insert({
    property_id:      PROPERTY_ID,
    gmail_message_id: event.gmail_message_id,
    email_type:       event.email_type,
    email_date:       event.email_date,
    subject:          event.subject,
    raw_payload:      event,
  });
  if (logErr) {
    if (logErr.code === '23505') { results.skipped++; return; }
    throw new Error(`log insert: ${logErr.message}`);
  }
  switch (event.email_type) {
    case 'booking':      await handleBooking(supabase, event);      break;
    case 'payout':       await handlePayout(supabase, event);       break;
    case 'cancellation': await handleCancellation(supabase, event); break;
  }
  results.inserted++;
}

// ── Booking handler ────────────────────────────────────────────────────────
async function handleBooking(
  supabase: LegacyDatabaseClient,
  event: EmailEvent
): Promise<void> {
  if (!event.confirmation_code || !event.guest_name) return;

  // ── 1. Guest upsert ──────────────────────────────────────────────────────
  let guestId: string|null = null;
  let guest: GuestRecord|null = null;

  const { data: existingGuest } = await supabase
    .from('guests').select('id,name,tier,total_stays,total_nights_stayed,first_stay_date')
    .eq('property_id', PROPERTY_ID).ilike('name', event.guest_name)
    .eq('source', 'airbnb').maybeSingle();

  if (existingGuest) {
    guestId = existingGuest.id;
    guest   = existingGuest as GuestRecord;
  } else {
    const { data: newGuest, error: guestErr } = await supabase
      .from('guests')
      .insert({ property_id: PROPERTY_ID, name: event.guest_name, source: 'airbnb' })
      .select('id,name,tier,total_stays,total_nights_stayed,first_stay_date').single();
    if (!guestErr && newGuest) { guestId = newGuest.id; guest = newGuest as GuestRecord; }
  }

  // ── 2. Reservation upsert ────────────────────────────────────────────────
  const { error: resErr } = await supabase.from('airbnb_reservations').upsert({
    property_id:              PROPERTY_ID,
    confirmation_code:        event.confirmation_code,
    source:                   'airbnb',
    status:                   'confirmed',
    guest_id:                 guestId,
    guest_name:               event.guest_name,
    guest_count:              event.guest_count ?? null,
    checkin_date:             event.checkin_date ?? null,
    checkout_date:            event.checkout_date ?? null,
    checkin_time:             event.checkin_time ?? null,
    checkout_time:            event.checkout_time ?? null,
    guest_paid:               event.guest_paid ?? null,
    host_service_fee:         event.host_service_fee ?? null,
    host_payout:              event.host_payout ?? null,
    booking_email_message_id: event.gmail_message_id,
  }, { onConflict: 'confirmation_code', ignoreDuplicates: false }).select('id').single();
  if (resErr) throw new Error(`reservation upsert: ${resErr.message}`);

  // ── 3. Income transaction (pending — will be reconciled on payout) ───────
  if (event.host_payout && event.checkin_date) {
    const { error: txnErr } = await supabase.from('transactions').insert({
      property_id:      PROPERTY_ID,
      txn_type:         'income',
      category:         'airbnb_income',
      source:           'airbnb_email',
      status:           'pending_review',
      income_stage:     'estimated',
      transaction_date: event.checkin_date,
      gross_amount:     event.host_payout,
      payee_name:       event.guest_name,
      external_ref:     event.confirmation_code,
      notes:            `Booking ${event.confirmation_code} — awaiting payout`,
    });
    if (txnErr && txnErr.code !== '23505') throw new Error(`transaction insert: ${txnErr.message}`);
  }

  // ── 4. Phase E: reconcile financials for this code ───────────────────────
  if (event.confirmation_code) await reconcile(supabase, event.confirmation_code);

  // ── 5. Phase D: refresh guest stats ─────────────────────────────────────
  if (guestId) await refreshGuestStats(supabase, guestId);

  // Re-fetch guest to get updated tier/stats after refresh
  if (guestId) {
    const { data: refreshed } = await supabase
      .from('guests').select('tier,total_stays,total_nights_stayed')
      .eq('id', guestId).maybeSingle();
    if (refreshed) guest = { ...guest!, ...(refreshed as Partial<GuestRecord>) };
  }

  // ── 6. Phase D: detect returning/VIP guest and log the alert ─────────────
  const isReturning = (guest?.total_stays ?? 0) >= 2;
  if (isReturning && guest && guestId) {
    const { data: priorStay } = await supabase
      .from('airbnb_reservations')
      .select('checkin_date,checkout_date')
      .eq('guest_id', guestId)
      .neq('confirmation_code', event.confirmation_code)
      .eq('status', 'completed')
      .order('checkin_date', { ascending: false })
      .limit(1).maybeSingle();

    const nights = (event.checkin_date && event.checkout_date)
      ? Math.round((new Date(event.checkout_date).getTime() - new Date(event.checkin_date).getTime()) / 86400000)
      : null;

    await supabase.from('returning_guest_alerts').insert({
      property_id:       PROPERTY_ID,
      guest_name:        event.guest_name,
      current_checkin:   event.checkin_date ?? null,
      current_checkout:  event.checkout_date ?? null,
      current_nights:    nights,
      previous_stays:    Math.max(0, (guest.total_stays ?? 1) - 1),
      total_nights:      guest.total_nights_stayed ?? 0,
      last_stay_checkin: priorStay?.checkin_date ?? null,
      last_stay_checkout:priorStay?.checkout_date ?? null,
      telegram_sent:     false,
      source:            'booking_email',
    });
  }

  // ── 7. Build notifications ───────────────────────────────────────────────
  const nights = (event.checkin_date && event.checkout_date)
    ? Math.round((new Date(event.checkout_date).getTime() - new Date(event.checkin_date).getTime()) / 86400000) : '?';
  const earn = event.host_payout
    ? `₱${event.host_payout.toLocaleString('en-PH', { minimumFractionDigits: 2 })}` : '—';
  const badge = tierBadge(guest?.tier ?? null, guest?.total_stays ?? 1);
  const guestLine = `👤 ${esc(event.guest_name)} (${event.guest_count ?? '?'} guest${(event.guest_count??1)>1?'s':''})`;
  const dateLine  = `📅 ${event.checkin_date??'TBD'} → ${event.checkout_date??'TBD'} (${nights}n)`;
  // v7: guest history lines (empty for a first-timer with nothing on file). No money in them.
  const ctxLines = guestContextLines(await guestContext(supabase, { guestId, name: event.guest_name })).map(esc);
  // Session 28: a returning guest gets the welcome-back message ready to send (Copy / Revise buttons).
  const first = String(event.guest_name ?? '').split(' ')[0] || 'there';
  const when = event.checkin_date && event.checkout_date ? ` on ${event.checkin_date} to ${event.checkout_date}` : '';
  const welcome = `Hi ${first}, welcome back to Cascade Hideaway! We are glad to have you with us again${when}. Everything will be ready the way you like it - just message us if there is anything you need before you arrive. 🌿`;
  const doLines = isReturning
    ? [...doSend(first, esc(welcome)), ...(ctxLines.some((l) => l.startsWith('🧹')) ? ['Then confirm the last issue is closed.'] : [])]
    : [`Do: prepare for check-in${event.checkin_date ? ` on ${event.checkin_date}` : ''}.`];

  // OPS: operational data only — no financial figures (cleaners present)
  const opsCard = withHeader('booking', `Airbnb ${event.confirmation_code}`, groups([badge, guestLine, dateLine], ctxLines, doLines));
  await sendTelegram(TELEGRAM_OPS_CHAT_ID, opsCard, autoKeyboard(opsCard));

  // Finance: same card plus the payout line
  const finCard = withHeader('booking', `Airbnb ${event.confirmation_code}`, groups([badge, guestLine, dateLine], [`💰 Host earns: ${earn}`], ctxLines, doLines));
  await sendTelegram(TELEGRAM_FINANCE_CHAT_ID, finCard, autoKeyboard(finCard));

  // ── 8. The returning-guest alert row is stamped sent: the card above carried it (v7) ────
  if (isReturning && guest) {
    await supabase.from('returning_guest_alerts')
      .update({ telegram_sent: true, telegram_sent_at: new Date().toISOString() })
      .eq('property_id', PROPERTY_ID)
      .eq('guest_name', event.guest_name)
      .eq('current_checkin', event.checkin_date ?? '')
      .is('telegram_sent', false);
  }
}

// ── Payout handler ─────────────────────────────────────────────────────────
async function handlePayout(
  supabase: LegacyDatabaseClient,
  event: EmailEvent
): Promise<void> {
  if (!event.payout_amount) return;
  const payoutDate = event.email_date.substring(0, 10);

  // Log the payout transfer as an income transaction
  const { error: txnErr } = await supabase.from('transactions').insert({
    property_id:      PROPERTY_ID,
    txn_type:         'income',
    category:         'airbnb_income',
    source:           'airbnb_payout_email',
    status:           'confirmed',
    income_stage:     'confirmed',
    transaction_date: payoutDate,
    gross_amount:     event.payout_amount,
    payee_name:       'Airbnb',
    external_ref:     event.gmail_message_id,
    notes:            `Payout email: ${event.subject}`,
  });
  if (txnErr && txnErr.code !== '23505') throw new Error(`payout transaction: ${txnErr.message}`);

  const details: PayoutDetail[] = event.detail_lines ?? [];
  const homeCodes = details
    .filter(d => d.line_type === 'Home' && d.confirmation_code)
    .map(d => d.confirmation_code!);

  for (const code of homeCodes) {
    // Record payout fields from email; mark completed unless the stay was cancelled.
    // A cancelled booking still pays out its non-refunded share (HMWAX9DAHZ, 2026-08-12) and
    // that payout must not resurrect the stay — August 2026 read 119 % occupancy because it did.
    await supabase.from('airbnb_reservations').update({
      payout_amount:           event.payout_amount / (homeCodes.length || 1),
      payout_date:             payoutDate,
      payout_email_message_id: event.gmail_message_id,
    }).eq('confirmation_code', code);
    await supabase.from('airbnb_reservations').update({ status: 'completed' })
      .eq('confirmation_code', code).neq('status', 'cancelled');

    // Void the booking-email estimate — superseded by the canonical payout row (Option B)
    await supabase.from('transactions').update({ status: 'void' })
      .eq('external_ref', code).eq('status', 'pending_review')
      .eq('source', 'airbnb_email');

    // Phase E: Now that booking is COMPLETED, run full reconciliation.
    // This is the definitive moment — CSV truth overwrites email estimates
    // for BOTH financial figures AND dates (payout = stay is over).
    await reconcile(supabase, code);

    // Phase D: refresh guest stats for this booking's guest
    const { data: res } = await supabase
      .from('airbnb_reservations').select('id, guest_id').eq('confirmation_code', code).maybeSingle();
    if (res?.guest_id) await refreshGuestStats(supabase, res.guest_id);

    // D-110: the payout row names its stay. An e-mail covering two stays stays
    // unlinked for the admin to split by hand (booking_id is direct bookings only).
    if (res?.id && homeCodes.length === 1) {
      await supabase.from('transactions').update({ reservation_id: res.id })
        .eq('external_ref', event.gmail_message_id).eq('source', 'airbnb_payout_email').is('reservation_id', null);
    }
  }

  // Finance-only payout notification (unchanged from v4)
  const detailLines = details.filter(d => d.line_type === 'Home')
    .map(d => `  • ${d.guest_name}: ₱${Math.abs(d.amount).toLocaleString('en-PH', { minimumFractionDigits: 2 })}`)
    .join('\n') || '  (no reservation details)';
  await sendTelegram(TELEGRAM_FINANCE_CHAT_ID, withHeader('finance', 'Airbnb payout', groups(
    [`💸 <b>Airbnb Payout Received</b>`, `💰 Total: ₱${event.payout_amount.toLocaleString('en-PH', { minimumFractionDigits: 2 })}`],
    [`📅 Sent: ${payoutDate}`, `🏦 Bank: Rocloyd Ligason, 4647 (PHP)`],
    detailLines.split('\n'),
    ['Do: nothing - the ledger row is confirmed. Log any expense from this payout with the button below.'],
  )), autoKeyboard('', BTN.expense)); // session 28
}

// ── Cancellation handler ───────────────────────────────────────────────────
async function handleCancellation(
  supabase: LegacyDatabaseClient,
  event: EmailEvent
): Promise<void> {
  if (!event.cancelled_code) return;

  await supabase.from('airbnb_reservations').update({
    status:                     'cancelled',
    cancelled_at:               event.email_date,
    refund_type:                event.refund_type ?? null,
    cancel_email_message_id:    event.gmail_message_id,
  }).eq('confirmation_code', event.cancelled_code);

  await supabase.from('transactions').update({ status: 'void' })
    .eq('external_ref', event.cancelled_code).eq('status', 'pending_review');

  // Phase D: refresh guest stats (cancelled stay doesn't count)
  const { data: res } = await supabase
    .from('airbnb_reservations').select('guest_id').eq('confirmation_code', event.cancelled_code).maybeSingle();
  if (res?.guest_id) await refreshGuestStats(supabase, res.guest_id);

  const guestLabel  = event.guest_first_name ? ` by ${event.guest_first_name}` : '';
  const refundLabel = event.refund_type === 'complete' ? 'Full refund issued' :
                      event.refund_type === 'partial'  ? 'Partial refund issued' : 'Refund per policy';

  // OPS: no financial data
  await sendTelegram(TELEGRAM_OPS_CHAT_ID, withHeader('attention', `cancelled ${event.cancelled_code}`, groups(
    [`❌ <b>Booking Cancelled${esc(guestLabel)}</b>`, `🔑 Code: ${event.cancelled_code}`],
    [`📅 ${esc(event.cancelled_dates??'')}`, `💸 ${refundLabel}`],
    ['Do: nothing - the dates are open again for rebooking.'],
  )));
}
