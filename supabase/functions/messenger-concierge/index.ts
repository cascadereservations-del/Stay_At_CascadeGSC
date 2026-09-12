// messenger-concierge v1 (2026-09-11)
// Facebook Messenger webhook -> deterministic risk gate -> Gemini reply grounded in
// facts.ts + live calendar_events -> Send API. Human takeover: any Page-inbox reply
// (echo) silences the bot on that thread for 24 h. Kill switch: app_settings.concierge_mode.
//
// Secrets (Edge Function secrets, never app_settings):
//   META_VERIFY_TOKEN, META_APP_SECRET, META_PAGE_TOKEN, META_APP_ID (optional),
//   CASCADE_GEMINI_BOT_KEY (falls back to GEMINI_BOT_KEY), CASCADE_OPENROUTER_BOT_KEY
//   (backup provider, optional), TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID.
// Deploy with verify_jwt=false: Meta cannot send a Supabase JWT.

import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { gate, needsDatesFirst, trimRepeatedInvite, type RiskCode } from './policy.ts';
import { FACTS, VOICE, SITE_URL } from '../_shared/cascade-core/facts.ts';
import { chatJson } from '../_shared/cascade-core/providers.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const GRAPH = 'https://graph.facebook.com/v21.0';
const PAGE_ID = '699640026568720'; // Cascades Hideaway; /me fails for some page-token types
// 2026-09-12: Google retired gemini-2.5-flash for new keys (404 names gemini-3.6-flash as the
// successor). Override without a redeploy via the CASCADE_GEMINI_MODEL secret.
// Cascade-scoped secret names (set 2026-09-12); the bare names are the pre-2026-09-12 fallback.
const HUMAN_HOLD_MS = 24 * 3_600_000;
const HISTORY_KEEP = 12;

// Guest-facing handoff lines, from Lloyd's approved wording (voice questionnaire, group 8):
// warm, positively framed, "we" not "I", emoji only where it earns its place, and no "po" —
// these go out in English. No booking link: everyone who sees these already has a booking.
const HANDOFF: Record<RiskCode, string> = {
  routine:          '',
  payment:          "Thank you. Our host will personally verify your payment and send your confirmation shortly, so everything is properly recorded.\n\nWe're looking forward to welcoming you to Cascade Hideaway, and we'll have everything ready for your stay.",
  refund:           "Thank you for letting us know. Refunds are reviewed personally by our host, and we've passed this along for their attention right away. We'll make sure it is followed through.",
  cancellation:     "Thank you for letting us know about the change in your plans. Our host has already been notified and will personally assist you with your booking.\n\nWe completely understand, and we'll keep the next steps as smooth as possible for you.",
  complaint:        "Thank you for letting us know right away. Our host has already been alerted, and our service partners have been notified so they can attend to this as soon as possible.\n\nYour comfort matters to us, and we'll make sure this is followed through promptly.",
  safety:           "Your safety comes first. Our host has been alerted immediately. If anyone is in danger, please call 911 right away.",
  access:           "For your security, access details are shared personally by our host. We've alerted them and they'll message you directly.",
  policy_exception: "That's a request our host would love to consider personally. We've passed it along, and you can expect a reply soon.",
  uncertain:        "Let us bring in our host for this one so you receive a complete answer. They'll be with you shortly.",
};
// Sticker, photo or reaction with no text: a prospect, so answer with the link rather than a handoff line.
const ATTACHMENT_REPLY = "Hello! You can view live availability and rates here:\n👉 " + SITE_URL + "\n\nWe offer special savings for direct bookings through our site, and we'd be happy to check specific dates for you.";
// Early/late check-in-out before dates are known (see needsDatesFirst in policy.ts).
const LOCAL_RE = /(po|pwede|kailan|maaga|naa|moy|kami|namin|ba|ninyo|nyo)/i;
function datesFirstReply(name: string | null, text: string): string {
  const hi = name ? `Hello ${name}.` : 'Hello.';
  if (LOCAL_RE.test(text)) return `${hi}

Salamat po sa pagtanong - gusto po naming ma-accommodate kayo. Depende po ito sa calendar ng araw na iyon: kapag walang ibang guest na dumarating o umaalis sa parehong araw, madali pong ma-arrange. Ano po ang mga petsa na tinitingnan ninyo? Ite-check po namin agad.

👉 ${SITE_URL}`;
  return `${hi}

We'd love to make that work for you. It depends on the calendar for that day: when no other guest arrives or leaves the same day, it is easy to arrange. Which dates are you looking at? We'll check right away.

👉 ${SITE_URL}`;
}
const ACK_SUGGEST = "Thank you for your message. Our host will reply personally very shortly.\n\nIn the meantime, you may check live availability and rates here:\n👉 " + SITE_URL;

type Turn = { role: 'guest' | 'bot'; text: string; at: string };
type Thread = { psid: string; guest_name: string | null; human_until: string | null; bot_turns: number; history: Turn[]; last_risk: string | null };
// deno-lint-ignore no-explicit-any
type Db = SupabaseClient<any, 'public', any>;

async function hmacOk(secret: string, body: string, header: string | null): Promise<boolean> {
  if (!secret || !header?.startsWith('sha256=')) return false;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body)));
  const hex = Array.from(sig, (b) => b.toString(16).padStart(2, '0')).join('');
  const want = header.slice(7);
  if (hex.length !== want.length) return false;
  let d = 0; for (let i = 0; i < hex.length; i++) d |= hex.charCodeAt(i) ^ want.charCodeAt(i);
  return d === 0;
}

async function fbSend(psid: string, text: string): Promise<void> {
  const token = env('META_PAGE_TOKEN');
  const post = (payload: unknown) => fetch(`${GRAPH}/${PAGE_ID}/messages?access_token=${token}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload), signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  await post({ recipient: { id: psid }, sender_action: 'typing_on' });
  const r = await post({ recipient: { id: psid }, messaging_type: 'RESPONSE', message: { text } });
  if (r && !r.ok) console.error('fb_send_failed', r.status, (await r.text()).slice(0, 200));
}

async function fbName(psid: string): Promise<string | null> {
  const r = await fetch(`${GRAPH}/${psid}?fields=first_name&access_token=${env('META_PAGE_TOKEN')}`, { signal: AbortSignal.timeout(5_000) }).catch(() => null);
  if (!r?.ok) return null;
  return ((await r.json()) as { first_name?: string }).first_name ?? null;
}

async function tgOps(text: string): Promise<void> {
  const token = env('TELEGRAM_BOT_TOKEN'), chat = env('TELEGRAM_CHAT_ID');
  if (!token || !chat) return;
  await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true }), signal: AbortSignal.timeout(10_000),
  }).catch(() => {});
}

// Availability is computed here, night by night, and handed to the model as explicit open
// windows. Handing it raw booked ranges made it merge two separate one-night bookings into one
// block and miss the open night between them (live test, 2026-09-12).
const HORIZON_DAYS = 120;
const dayStr = (d: Date) => d.toISOString().slice(0, 10);
const addDays = (iso: string, n: number) => { const d = new Date(iso + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return dayStr(d); };
const pretty = (iso: string) => new Date(iso + 'T00:00:00Z').toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' });

async function availabilityBlock(db: Db): Promise<string> {
  const today = dayStr(new Date(Date.now() + 8 * 3_600_000)); // Manila
  const horizonEnd = addDays(today, HORIZON_DAYS);
  const { data } = await db.from('calendar_events').select('checkin_date, checkout_date').neq('status', 'cancelled').gte('checkout_date', today).lte('checkin_date', horizonEnd).order('checkin_date').limit(200);
  const bookedNights = new Set<string>();
  const checkins = new Set<string>(), checkouts = new Set<string>();
  for (const r of data ?? []) {
    checkins.add(r.checkin_date); checkouts.add(r.checkout_date);
    for (let d = r.checkin_date; d < r.checkout_date; d = addDays(d, 1)) bookedNights.add(d);
  }

  // Walk the horizon and collect runs of open nights as check-in -> check-out windows.
  const windows: string[] = [], booked: string[] = [];
  let runStart: string | null = null;
  for (let d = today; d < horizonEnd; d = addDays(d, 1)) {
    if (bookedNights.has(d)) {
      booked.push(pretty(d));
      if (runStart) { const nights = (Date.parse(d) - Date.parse(runStart)) / 86_400_000; windows.push(`${pretty(runStart)} to ${pretty(d)} (${nights} night${nights > 1 ? 's' : ''})`); runStart = null; }
    } else if (!runStart) runStart = d;
  }
  if (runStart) windows.push(`${pretty(runStart)} onwards (open through at least ${pretty(horizonEnd)})`);

  return [
    `TODAY (Manila): ${today}. Dates below are ${new Date(today).getUTCFullYear()} unless stated.`,
    `A stay needs EVERY night from check-in through the night before check-out to be open. The check-out day itself can be a new guest's check-in day.`,
    `OPEN WINDOWS (check-in to check-out): ${windows.join('; ') || 'none in the next ' + HORIZON_DAYS + ' days'}`,
    `BOOKED NIGHTS: ${booked.join(', ') || 'none'}`,
    `If a requested range includes a booked night, say exactly which nights are taken and which are open, then offer the open part or the nearest window. For dates beyond ${pretty(horizonEnd)}, say the host will confirm.`,
    // Turnover safeguard (live test 2026-09-12: a free 1 PM check-out was promised with no dates known).
    `ANOTHER GUEST CHECKS OUT ON: ${[...checkouts].filter((d) => d >= today).sort().map(pretty).join(', ') || 'none'} - early check-in is NOT possible on these days (12 noon at the earliest, and only once the unit is ready).`,
    `ANOTHER GUEST CHECKS IN ON: ${[...checkins].filter((d) => d >= today).sort().map(pretty).join(', ') || 'none'} - late check-out is NOT possible on these days; check-out stays at 12 noon.`,
    `Offer early check-in or late check-out ONLY when the guest's dates are known and the day in question is on neither list. Otherwise say you will gladly arrange it once their dates are set and the calendar allows.`,
  ].join('\n');
}

type Draft = { reply: string; uncertain: boolean };

// Landmarks come from the same tables that feed the guest guide's maps (pois, dining_spots), so a
// distance the bot quotes is one Lloyd has already published. Anything not listed -> host confirms.
let landmarksCache: { at: number; text: string } | null = null;
let dbForLandmarks: Db | null = null; // set per request in Deno.serve; draft() has no db parameter
async function landmarksBlock(db: Db): Promise<string> {
  if (landmarksCache && Date.now() - landmarksCache.at < 10 * 60_000) return landmarksCache.text;
  const [p, d] = await Promise.all([
    db.from('pois').select('name, category, distance_km, distance_text, note').eq('is_active', true).order('sort_order').limit(60),
    db.from('dining_spots').select('name, cuisine, distance_km, distance_text, must_try').eq('is_active', true).order('sort_order').limit(60),
  ]);
  const line = (r: any, kind: string) => `- ${r.name} (${kind}${r.cuisine ? ': ' + r.cuisine : ''}): ${r.distance_km != null ? r.distance_km + ' km' : ''}${r.distance_text ? ', ' + r.distance_text : ''}${r.must_try ? '; must try ' + r.must_try : ''}${r.note ? '; ' + r.note : ''}`;
  const rows = [...(p.data ?? []).map((r) => line(r, r.category ?? 'place')), ...(d.data ?? []).map((r) => line(r, 'dining'))];
  const text = rows.length
    ? `Known places near the unit (distance from the unit; travel time depends on traffic and how the guest travels):\n${rows.join('\n')}\nIf a place the guest names is not in this list, do not estimate - say the host will confirm the distance personally.`
    : 'No landmark list is loaded; say the host will confirm distances personally.';
  landmarksCache = { at: Date.now(), text };
  return text;
}

const systemPrompt = (thread: Thread, availability: string, landmarks = '') =>
  `${VOICE}\n\nGUEST FIRST NAME: ${thread.guest_name ?? 'unknown'}\n\nFACTS\n${FACTS}\n\nLANDMARKS\n${landmarks}\n\nAVAILABILITY\n${availability}`;

function draftFrom(raw: string, who: string): Draft {
  const parsed = JSON.parse(raw) as { reply?: string; uncertain?: boolean };
  const reply = (parsed.reply ?? '').trim().slice(0, 1800); // Messenger allows 2000; two handoff options need room
  if (!reply) throw new Error(`${who}_empty`);
  return { reply, uncertain: parsed.uncertain === true };
}

async function draft(thread: Thread, question: string, availability: string): Promise<Draft> {
  const landmarks = await landmarksBlock(dbForLandmarks!).catch(() => '');
  const raw = await chatJson({
    system: systemPrompt(thread, availability, landmarks),
    history: thread.history.slice(-HISTORY_KEEP).map((h) => ({ role: h.role === 'bot' ? 'assistant' as const : 'user' as const, text: h.text })),
    question, title: 'Cascade Concierge',
  });
  return draftFrom(raw, 'model');
}

// ---- Host handoff with one-tap replies (2026-09-12) --------------------------------------
// When the bot hands a guest to the host, ops gets a Telegram card: the guest's message, two
// suggested replies as buttons, and "Write my own". A tap (or a reply to the card) is sent to
// the guest on Messenger signed with the responder's name. Button clicks reach the Telegram
// webhook owned by telegram-expense, which forwards `ch:` callbacks and `#CH-` replies here.
const OPS_NAMES: Record<string, string> = Object.fromEntries(
  env('CASCADE_OPS_NAMES').split(',').map((p) => p.trim().split(':')).filter((p) => p.length === 2) as [string, string][],
); // e.g. "123456:Lloyd,234567:Marifel,345678:Honey"
const whoIs = (from: { id?: number | string; first_name?: string } | undefined) =>
  OPS_NAMES[String(from?.id ?? '')] ?? from?.first_name ?? 'Cascade host';

async function tgCall(method: string, body: Record<string, unknown>): Promise<any> {
  const token = env('TELEGRAM_BOT_TOKEN'); if (!token) return null;
  const r = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  return r ? await r.json().catch(() => null) : null;
}

// Two candidate replies for the host, in the concierge voice. Rides the normal draft() path so it
// inherits the provider fallback; the options come back joined by a separator line.
async function suggestOptions(thread: Thread, text: string, availability: string): Promise<string[]> {
  const ask = `The guest just wrote: "${text}". Our host will answer this personally. Draft exactly TWO alternative replies the host could send - one gently declining or holding the line, one accommodating if we can - each complete, in our voice, 40-90 words, no link. Return them in "reply" separated by a line containing only ---. Set uncertain to false.`;
  try {
    const out = await draft(thread, ask, availability);
    const parts = out.reply.split(/\n\s*---\s*\n/).map((s) => s.trim()).filter(Boolean);
    return parts.slice(0, 2);
  } catch (e) { console.error('suggest_options_failed', String(e).slice(0, 200)); return []; }
}

async function openHandoff(db: Db, thread: Thread, text: string, risk: RiskCode, link: string): Promise<void> {
  const chat = env('TELEGRAM_CHAT_ID'); if (!chat) return;
  const options = await suggestOptions(thread, text, await availabilityBlock(db));
  const { data: row } = await db.from('concierge_handoffs').insert({ psid: thread.psid, guest_name: thread.guest_name, guest_text: text, risk, options }).select('id').single();
  const id: string = row?.id ?? ''; if (!id) return;
  const short = id.slice(0, 8);
  const body = [
    `🛎 Guest needs the host (${risk})`,
    `Guest: ${thread.guest_name ?? thread.psid}`,
    `> ${text.slice(0, 400)}`,
    '',
    ...options.map((o, i) => `Option ${i + 1}:\n${o}\n`),
    `Tap an option to send it to the guest, or reply to this message to write your own. #CH-${short}`,
    link,
  ].join('\n');
  const keyboard = [
    options.map((_, i) => ({ text: `Send option ${i + 1}`, callback_data: `ch:${short}:${i + 1}` })),
    [{ text: '✍️ Write my own', callback_data: `ch:${short}:own` }],
  ].filter((r) => r.length);
  const sent = await tgCall('sendMessage', { chat_id: chat, text: body, disable_web_page_preview: true, reply_markup: { inline_keyboard: keyboard } });
  if (sent?.result?.message_id) await db.from('concierge_handoffs').update({ tg_message_id: sent.result.message_id }).eq('id', id);
}

// `like` on a uuid column is a Postgres error (uuid ~~ text), so "Option not found" on every tap
// (live 2026-09-12). Open cards are few: fetch them and match the 8-char prefix here.
async function openHandoffByShort(db: Db, short: string): Promise<any | null> {
  const { data } = await db.from('concierge_handoffs').select('*').eq('status', 'open').order('created_at', { ascending: false }).limit(50);
  return (data ?? []).find((h: any) => String(h.id).startsWith(short)) ?? null;
}

async function sendHostReply(db: Db, short: string, text: string, from: any, cbId?: string): Promise<void> {
  const h = await openHandoffByShort(db, short);
  if (!h) { if (cbId) await tgCall('answerCallbackQuery', { callback_query_id: cbId, text: 'Already handled.' }); return; }
  const name = whoIs(from);
  const final = `${text.trim()}\n\n— ${name}, Cascade Hideaway`;
  await fbSend(h.psid, final);
  const now = new Date().toISOString();
  await db.from('concierge_handoffs').update({ status: 'sent', sent_text: final, resolved_by: name, resolved_at: now }).eq('id', h.id);
  const { data: t } = await db.from('concierge_threads').select('history').eq('psid', h.psid).maybeSingle();
  await db.from('concierge_threads').upsert({ psid: h.psid, history: [...(t?.history ?? []), { role: 'bot', text: final, at: now }].slice(-HISTORY_KEEP * 2), updated_at: now });
  if (cbId) await tgCall('answerCallbackQuery', { callback_query_id: cbId, text: `Sent as ${name}` });
  if (h.tg_message_id) await tgCall('editMessageText', { chat_id: env('TELEGRAM_CHAT_ID'), message_id: h.tg_message_id, text: `✅ ${name} replied to ${h.guest_name ?? h.psid}:\n${text.trim().slice(0, 600)}\n\nGuest wrote:\n> ${String(h.guest_text).slice(0, 300)}` });
}

// Telegram updates forwarded by telegram-expense: button taps and "write my own" replies.
async function handleOps(db: Db, update: any): Promise<void> {
  const cq = update?.callback_query;
  if (cq?.data?.startsWith('ch:')) {
    const [, short, choice] = String(cq.data).split(':');
    if (choice === 'own') {
      await tgCall('answerCallbackQuery', { callback_query_id: cq.id });
      await tgCall('sendMessage', { chat_id: cq.message?.chat?.id, text: `Reply to THIS message with what you want to send the guest. #CH-${short}`, reply_markup: { force_reply: true, selective: true } });
      return;
    }
    const h = await openHandoffByShort(db, short);
    const opt = h?.options?.[Number(choice) - 1];
    if (!opt) { await tgCall('answerCallbackQuery', { callback_query_id: cq.id, text: 'Option not found.' }); return; }
    await sendHostReply(db, short, opt, cq.from, cq.id);
    return;
  }
  const msg = update?.message;
  const m = /#CH-([0-9a-f]{8})/.exec(String(msg?.reply_to_message?.text ?? ''));
  if (m && msg?.text) await sendHostReply(db, m[1], String(msg.text), msg.from);
}

async function handle(db: Db, ev: Record<string, any>, mode: string): Promise<void> {
  const msg = ev.message; if (!msg) return;
  const now = new Date();

  // Staff replied from the Page inbox: hold the bot on this thread.
  if (msg.is_echo) {
    if (env('META_APP_ID') && String(msg.app_id ?? '') === env('META_APP_ID')) return; // our own send
    await db.from('concierge_threads').upsert({ psid: ev.recipient.id, human_until: new Date(now.getTime() + HUMAN_HOLD_MS).toISOString(), updated_at: now.toISOString() });
    return;
  }

  const psid: string = ev.sender.id;
  const { data: row } = await db.from('concierge_threads').select('*').eq('psid', psid).maybeSingle();
  const thread: Thread = (row as Thread | null) ?? { psid, guest_name: null, human_until: null, bot_turns: 0, history: [], last_risk: null };
  if (!thread.guest_name) thread.guest_name = await fbName(psid);

  const text: string = (msg.text ?? '').trim();
  const link = `https://www.facebook.com/messages/t/${psid}`;
  const g = gate(text || 'attachment', { mode, humanUntil: thread.human_until, botTurns: thread.bot_turns, now });
  let risk: RiskCode = text ? g.risk : 'uncertain';
  let handoff = g.handoff || !text;   // the bot steps aside: handoff line to the guest, 24 h hold
  let flagOnly = false;               // the bot answered but wants a host to glance: alert, no hold
  let reply = '';

  if (!g.reply) { /* mode off, or a human holds this thread */ }
  else if (handoff) reply = text ? HANDOFF[risk] : ATTACHMENT_REPLY;
  else if (needsDatesFirst(text, thread.history.filter((h) => h.role === 'guest').map((h) => h.text).join(' '))) reply = datesFirstReply(thread.guest_name, text);
  else {
    try {
      const out = await draft(thread, text, await availabilityBlock(db));
      reply = trimRepeatedInvite(out.reply, thread.history.filter((h) => h.role === 'bot').map((h) => h.text), text, SITE_URL);
      // A model-flagged uncertainty used to silence the bot for 24 h right after it had answered
      // (live test 2026-09-12: a warm reply about a mother's recovery, then silence). Now it only
      // alerts the host; the conversation continues, and the host can still take over by replying.
      if (out.uncertain) { flagOnly = true; risk = 'uncertain'; }
    } catch (e) {
      console.error('draft_failed', String(e).slice(0, 400));
      handoff = true; risk = 'uncertain'; reply = HANDOFF.uncertain;
    }
  }

  const sentToGuest = Boolean(reply) && mode === 'auto';
  if (reply) {
    if (mode === 'auto') await fbSend(psid, reply);
    else { await fbSend(psid, ACK_SUGGEST); await tgOps(`💬 Concierge draft (${risk})\nGuest: ${thread.guest_name ?? psid}\n> ${text.slice(0, 300)}\n\nSuggested reply:\n${reply}\n\n${link}`); }
    if (handoff) {
      thread.human_until = new Date(now.getTime() + HUMAN_HOLD_MS).toISOString();
      if (mode === 'auto') {
        if (text) await openHandoff(db, thread, text, risk, link);
        else await tgOps(`🛎 Concierge handoff (${risk})\nGuest: ${thread.guest_name ?? psid}\n> [attachment]\n\n${link}`);
      }
    } else if (flagOnly && mode === 'auto') {
      await tgOps(`👀 Concierge answered but wants a host to glance\nGuest: ${thread.guest_name ?? psid}\n> ${text.slice(0, 300)}\n\nBot replied:\n${reply.slice(0, 500)}\n\n${link}`);
    }
  }

  const turns: Turn[] = [{ role: 'guest', text: text || '[attachment]', at: now.toISOString() }];
  if (sentToGuest) turns.push({ role: 'bot', text: reply, at: now.toISOString() });
  await db.from('concierge_threads').upsert({
    psid, guest_name: thread.guest_name, human_until: thread.human_until,
    bot_turns: thread.bot_turns + (sentToGuest && !handoff ? 1 : 0),
    history: [...thread.history, ...turns].slice(-HISTORY_KEEP * 2), last_risk: risk, updated_at: now.toISOString(),
  });
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (req.method === 'GET') {
    const want = env('META_VERIFY_TOKEN');
    const ok = Boolean(want) && url.searchParams.get('hub.mode') === 'subscribe' && url.searchParams.get('hub.verify_token') === want;
    return ok ? new Response(url.searchParams.get('hub.challenge') ?? '', { status: 200 }) : new Response('forbidden', { status: 403 });
  }
  if (req.method !== 'POST') return new Response('method_not_allowed', { status: 405 });

  // Ops path: Telegram updates forwarded by telegram-expense, authenticated with the same
  // webhook secret Telegram uses for that function (Edge secrets are project-wide).
  if (url.searchParams.get('ops') === '1') {
    const want = env('TELEGRAM_WEBHOOK_SECRET');
    if (!want || req.headers.get('x-telegram-bot-api-secret-token') !== want) return new Response('unauthorized', { status: 401 });
    const db: Db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'));
    try { await handleOps(db, await req.json()); } catch (e) { console.error('ops_failed', String(e).slice(0, 300)); }
    return new Response('ok', { status: 200 });
  }

  const body = await req.text();
  if (!(await hmacOk(env('META_APP_SECRET'), body, req.headers.get('x-hub-signature-256')))) return new Response('bad signature', { status: 401 });

  const db: Db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'));
  dbForLandmarks = db;
  const { data: setting } = await db.from('app_settings').select('value').eq('key', 'concierge_mode').maybeSingle();
  const mode = typeof setting?.value === 'string' ? setting.value : 'off';

  let payload: { entry?: Array<{ messaging?: Array<Record<string, any>> }> };
  try { payload = JSON.parse(body); } catch { return new Response('ok', { status: 200 }); }

  for (const ev of payload.entry?.flatMap((e) => e.messaging ?? []) ?? []) {
    try { await handle(db, ev, mode); } catch (e) { console.error('concierge_event_failed', String(e).slice(0, 200)); }
  }
  return new Response('EVENT_RECEIVED', { status: 200 });
});
