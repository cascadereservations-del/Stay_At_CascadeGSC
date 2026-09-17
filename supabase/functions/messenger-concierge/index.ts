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
// Messenger book intent (booking PRD §A, session 27): code-driven slot filling, no model in the loop.
import { answer, availabilityAck, availabilityLine, BOOK_RE, detectLang, greeting, isActive, opener, paymentReply, pick as reg, prompt, quoteTotal, start, type Flow } from './booking.ts';
import { addChatRoute, answerOnly, beforeClose, decisionInvite, dropPaxAsk, isCold, lintReply, thinPo, tidyReply } from './voice.ts';
import { GCASH_QRPH_BASE, qrphWithAmount, qrPng } from '../_shared/cascade-core/qrph.ts';
import { fbSendImage, fbSendImageBytes } from '../_shared/cascade-core/messenger.ts';
import { FACTS, VOICE, SITE_URL, RATE_TIERS, voiceCompact } from '../_shared/cascade-core/facts.ts';
import { chatJson, geminiBreaker } from '../_shared/cascade-core/providers.ts';
// Session 26 (2026-09-16, Telegram plan §5/§6): OPS cards open with 💬 GUEST; a complaint or safety
// handoff also raises a work order (guest_report) so the Today page sees it, not just this chat.
import { withHeader } from '../_shared/cascade-core/format.ts';
import { raiseWorkOrder } from '../_shared/cascade-core/workorders.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const GRAPH = 'https://graph.facebook.com/v21.0';
const PAGE_ID = '699640026568720'; // Cascades Hideaway; /me fails for some page-token types
// 2026-09-12: Google retired gemini-2.5-flash for new keys (404 names gemini-3.6-flash as the
// successor). Override without a redeploy via the CASCADE_GEMINI_MODEL secret.
// Cascade-scoped secret names (set 2026-09-12); the bare names are the pre-2026-09-12 fallback.
const HUMAN_HOLD_MS = 24 * 3_600_000;
// Sprint 0 (Lloyd, 2026-09-16): a host reply from the Page inbox used to mute the bot on that
// thread for 24 h, so a routine follow-up ("what's the Wi-Fi?") an hour later went unanswered.
// The echo hold is now 2 h; safety holds and the handoff dedupe window keep the 24 h constant.
const ECHO_HOLD_MS = 2 * 3_600_000;
const HISTORY_KEEP = 16; // 32 stored entries; 12 dropped a guest's dates after a 30-turn chat (2026-09-13)

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

// Two turns that need no model (live audit 2026-09-13: the model padded "salamat po" with a
// sales nudge and answered "are you a bot?" with "I ... just like a human host would").
// Closers: thanks, okay, noted, goodbye. Answered in code, warmly, and - Lloyd 2026-09-13 - with
// the direct site left as a gentle open door when it was not in our previous reply.
const THANKS_RE = /^\s*(ok(ay)?|sige|noted|got it|great|nice)?( po)?[,.! ]*(thank(s| you)( so much| very much)?|salamat( po)?( ulit)?|maraming salamat( po)?|ty|tysm)[,.! ]*(po|talaga)?[,.! ]*$/i; // "sige po, salamat" went to the model (v57 check)
const CLOSER_ONLY_RE = /^\s*(?:(?:ok(?:ay)?|sige|noted|got it|alright|copy|bye|good ?bye|ingat|see you|talk (?:to you )?later|ttyl|good night|goodnight)(?: po)?(?: na)?[,.! ]*){1,3}$/i;
const BOT_RE = /\b(are you a (bot|robot|an? ai)|is this a bot|bot (ka|po|ba)|ai (po )?ba|robot (ka|po) ba|chatbot|real person|human ba|tao (po )?ba|automated)\b/i;
const pick = (xs: string[]) => xs[Math.floor(Math.random() * xs.length)];
function closingReply(name: string | null, lang: string, thanks: boolean, lastBotText: string): string {
  const n = name ? `, ${name}` : '';
  const en = thanks
    ? pick([`It's truly our pleasure${n}. We're here whenever you need us, and we'd be delighted to welcome you.`, `You're most welcome${n}. It was lovely chatting with you; just message us anytime.`, `Our pleasure${n}. If anything else comes to mind, we're one message away.`])
    : pick([`Thank you${n}. We're here whenever you need us, and we'd be delighted to welcome you.`, `Noted with thanks${n}. Take care, and just message us anytime.`, `Of course${n}. We'll be right here whenever you're ready.`]);
  const tl = thanks
    ? pick([`It's our pleasure po${n}. Nandito lang po kami anytime, at we'd be delighted to welcome you.`, `Walang anuman po${n}. Masaya po kaming nakausap kayo; message lang po kayo anytime.`, `Salamat din po${n}. Kung may maisip pa po kayo, one message away lang po kami.`])
    : pick([`Salamat po${n}. Nandito lang po kami kapag kailangan ninyo, at we'd be delighted to welcome you.`, `Sige po${n}, ingat po kayo. Message lang po kayo anytime.`, `Noted po${n}. Nandito lang po kami kapag handa na kayo.`]);
  let reply = lang === 'english' ? en : tl;
  if (!lastBotText.includes(SITE_URL)) reply += lang === 'english'
    ? `\n\nWhenever you're ready, our direct booking site is here for you:\n\n👉 ${SITE_URL}`
    : `\n\nKapag handa na po kayo, nandito po ang direct booking site namin:\n\n👉 ${SITE_URL}`;
  return reply;
}
function botReply(name: string | null, lang: string): string {
  const n = name ? `${name}, ` : '';
  if (lang === 'english') return `${n}I'm Cascade Hideaway's automated assistant, and I'm glad to help with rates, dates, directions and anything about your stay. Whenever you'd like to talk to a person, our host Marifel is one message away.`;
  return `${n}ako po ang automated assistant ng Cascade Hideaway, at masaya po akong tumulong sa rates, dates, directions at kahit anong tungkol sa stay ninyo. Kapag gusto po ninyong makausap ang tao, si Marifel, ang host namin, ay one message away lang po.`;
}
// Lloyd 2026-09-13: anchor the saving, not the percentage. When the guest names a stay length,
// the standard total, the discounted total and the added value are computed here so the
// numbers are never invented ("5 nights: PHP 8,900 becomes about PHP 8,010, with drinking water").
const peso = (n: number) => 'PHP ' + n.toLocaleString('en-US');
function stayAnchor(text: string): string {
  const m = /\b(\d{1,2})\s*(?:nights?|gabi|days?|araw)\b/i.exec(text);
  if (!m) return '';
  const n = Number(m[1]);
  const tier = RATE_TIERS.find((t) => n >= t.min && n <= t.max);
  if (!tier || n < 2) return '';
  const extras = n >= 7 ? ', plus a complimentary mid-stay cleaning with fresh linens and towels' : n >= 5 ? ', plus drinking water for the stay' : '';
  // Order and wording follow pricing research: anchor on the standard rate, adjust to the precise
  // direct rate (precise figures read as calculated and lower), then the per-stay total, then the
  // saving in pesos (rule of 100: absolute over percent when the base is large), then one value-add.
  return `[Stay anchor for ${n} nights - say it in THIS order, in one warm paragraph: (1) "for ${n} nights your direct rate comes down to ${peso(tier.rate)} per night from the standard ${peso(1780)}", (2) "about ${peso(n * tier.rate)} for the stay instead of ${peso(n * 1780)}", (3) "so you keep about ${peso(n * (1780 - tier.rate))}"${extras ? `, (4) "${extras.slice(2)}"` : ''}. Do not state the percentage; do not use the word "discount" more than once; then the link, then ask which dates they are looking at.] `;
}
// Dates the guest has already given, so a later early/late check-in question is answered against
// the calendar instead of "once your dates are set" (live audit 2026-09-13, Oct 10-12 given two turns earlier).
// Explicit dates only: "will decide tomorrow" was collected as a stay date (live 2026-09-13).
const DATES_RE = /\b(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.? ?\d{1,2}(?:\s*(?:-|–|to|hanggang)\s*(?:[a-z]+ )?\d{1,2})?|\d{1,2}[\/-]\d{1,2}(?:\s*(?:-|to)\s*\d{1,2}[\/-]\d{1,2})?)\b/gi;
function guestDatesBlock(guestTexts: string[]): string {
  const found = [...new Set(guestTexts.join(' \n ').match(DATES_RE) ?? [])].slice(-3);
  return found.length ? `\n\nGUEST'S DATES SO FAR (from their own messages): ${found.join('; ')}. Treat these as their dates: answer early check-in / late check-out against the CHECKS OUT / CHECKS IN lists for these days, and do not ask for the dates again.` : '';
}

type Turn = { role: 'guest' | 'bot'; text: string; at: string };
type Thread = { psid: string; guest_name: string | null; human_until: string | null; bot_turns: number; history: Turn[]; last_risk: string | null; booking_flow?: Flow | null };
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

// humanAgent: a host's own reply from a handoff card. Sent with the HUMAN_AGENT tag (Meta feature
// added 2026-09-13) so it still delivers up to 7 days after the guest's last message, not 24 h.
async function fbSend(psid: string, text: string, humanAgent = false): Promise<void> {
  const token = env('META_PAGE_TOKEN');
  const post = (payload: unknown) => fetch(`${GRAPH}/${PAGE_ID}/messages?access_token=${token}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload), signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  await post({ recipient: { id: psid }, sender_action: 'typing_on' });
  const envelope = humanAgent ? { messaging_type: 'MESSAGE_TAG', tag: 'HUMAN_AGENT' } : { messaging_type: 'RESPONSE' };
  const r = await post({ recipient: { id: psid }, ...envelope, message: { text } });
  if (r && !r.ok) console.error('fb_send_failed', r.status, (await r.text()).slice(0, 200));
}

async function fbName(psid: string): Promise<string | null> {
  const r = await fetch(`${GRAPH}/${psid}?fields=first_name&access_token=${env('META_PAGE_TOKEN')}`, { signal: AbortSignal.timeout(5_000) }).catch(() => null);
  if (!r?.ok) { console.error('fb_name_failed', r?.status ?? 'no_response', r ? (await r.text()).slice(0, 300) : ''); return fbNameFromConversation(psid); }
  const body = await r.json().catch(() => ({})) as { first_name?: string };
  if (body.first_name) return body.first_name;
  console.error('fb_name_empty', JSON.stringify(body).slice(0, 300));
  return fbNameFromConversation(psid);
}

// Fallback (2026-09-13): the User Profile API returned 400 "missing permissions" for real
// guests. The Page's own conversation list carries the participant name under pages_messaging.
async function fbNameFromConversation(psid: string): Promise<string | null> {
  const r = await fetch(`${GRAPH}/${PAGE_ID}/conversations?platform=messenger&user_id=${psid}&fields=participants&access_token=${env('META_PAGE_TOKEN')}`, { signal: AbortSignal.timeout(5_000) }).catch(() => null);
  if (!r?.ok) { console.error('fb_conv_name_failed', r?.status ?? 'no_response', r ? (await r.text()).slice(0, 300) : ''); return null; }
  const j = await r.json().catch(() => ({})) as { data?: Array<{ participants?: { data?: Array<{ id?: string; name?: string }> } }> };
  const p = j.data?.[0]?.participants?.data?.find((x) => String(x.id) === String(psid));
  const first = (p?.name ?? '').trim().split(/\s+/)[0] || null;
  if (!first) console.error('fb_conv_name_empty', JSON.stringify(j).slice(0, 300));
  return first;
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
  const { data, error } = await db.from('calendar_events').select('checkin_date, checkout_date').neq('status', 'cancelled').gte('checkout_date', today).lte('checkin_date', horizonEnd).order('checkin_date').limit(200);
  // Session 30: supabase-js does not throw. A failed read used to look like an empty calendar, so the model was
  // told every night was open. Now it is told the calendar is unknown and must not state availability.
  if (error) {
    console.error('calendar_read_failed', 'availabilityBlock', String(error.message ?? error).slice(0, 200));
    return [
      `TODAY (Manila): ${today}.`,
      `AVAILABILITY: the calendar could not be read just now. Do NOT say that any date is open, available, booked or taken. Say warmly that we will check those dates and confirm shortly, then answer everything else as usual. Do not promise early check-in or late check-out.`,
    ].join('\n');
  }
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

type Draft = { reply: string; uncertain: boolean; guest_name?: string | null };

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
  // ponytail: travel time derived as km x 2..3 min (GenSan city traffic, matches the hand-written
  // 3.7 km ~10 min and 15 km ~25-35 min) unless the row's note already states minutes; set the note
  // per row to override.
  const mins = (r: any) => {
    const km = Number(r.distance_km);
    if (!(km > 0.5) || /\bmin\b/i.test(r.note ?? '')) return '';
    return `, about ${Math.max(2, Math.round(km * 2))}-${Math.round(km * 3)} min by car or Grab`;
  };
  const line = (r: any, kind: string) => `- ${r.name} (${kind}${r.cuisine ? ': ' + r.cuisine : ''}): ${r.distance_km != null ? r.distance_km + ' km' : ''}${r.distance_text ? ', ' + r.distance_text : ''}${mins(r)}${r.must_try ? '; must try ' + r.must_try : ''}${r.note ? '; ' + r.note : ''}`;
  const rows = [...(p.data ?? []).map((r) => line(r, r.category ?? 'place')), ...(d.data ?? []).map((r) => line(r, 'dining'))];
  const text = rows.length
    ? `Known places near the unit (distance from the unit; travel time depends on traffic and how the guest travels):\n${rows.join('\n')}\nIf a place the guest names is not in this list, do not estimate - say the host will confirm the distance personally.`
    : 'No landmark list is loaded; say the host will confirm distances personally.';
  landmarksCache = { at: Date.now(), text };
  return text;
}

// Follow-up turns get a compact prompt: the 13 reference replies (all English, all first-contact
// shaped) are dropped, which halves the tokens and removes the strongest pull toward English
// brochure answers. First contact keeps the full voice with exemplars.
// The OUTPUT contract sits after the exemplars, so it must be re-attached or the model stops
// returning {reply, uncertain} and every follow-up degrades to a handoff (live, 2026-09-13 10:42Z).
// Session 30 ROOT CAUSE of "it always reverts to blunt": this used VOICE.split('REFERENCE REPLIES')[0], and those
// words also occur in VOICE's FIRST paragraph ("The REFERENCE REPLIES below are Lloyd's approved wording"), so since
// 2026-09-13 every follow-up ran on 1,751 of ~30,000 characters: no Cassy persona, none of the three native protocols,
// no voice rules. The cut is now made at the HEADING line, in facts.ts, and voice.test.ts asserts what it keeps.
const VOICE_COMPACT = voiceCompact();
const systemPrompt = (thread: Thread, availability: string, landmarks = '', compact = false) =>
  `${compact ? VOICE_COMPACT : VOICE}\n\nGUEST FIRST NAME: ${thread.guest_name ?? 'unknown'}\n\nFACTS\n${FACTS}\n\nLANDMARKS\n${landmarks}\n\nAVAILABILITY\n${availability}`;

// Language of the guest's message, decided in code so the instruction can ride on the user turn
// itself, where small models honour it. Taglish/Tagalog and Bisaya markers; everything else English.
// Lloyd 2026-09-13: "how far from SM po" is an English sentence with a courtesy particle, not
// Taglish - it gets English back (one "po" welcome). Taglish needs a Tagalog content word.
function guestLang(text: string): 'taglish' | 'bisaya' | 'english_po' | 'english' {
  const t = ` ${text.toLowerCase()} `;
  if (/\b(naa|unsa|asa|kanus-a|pila|maayong|salamat kaayo|ba mo|mo ba|nimo|karon|kaayo|kini|usbon|usba|mi|kabuok|tawo|ug|og|dili|among|ugma|gahapon|muabot|moabot)\b/.test(t)) return 'bisaya';
  if (/\b(ang|ng|mga|kayo|ninyo|magkano|pwede|puwede|salamat|meron|kailan|saan|paano|bukas|ngayon|opo|hindi|kasi|namin|natin|sige|okay lang|ayos|kami|ako|niyo|nyo)\b/.test(t)) return 'taglish';
  const particles = (t.match(/\b(po|ba|lang|naman|opo)\b/g) ?? []).length;
  if (particles >= 2) return 'taglish';      // "may parking po ba?"
  if (particles === 1) return 'english_po';  // "how far from SM po"
  return 'english';
}
const LANG_HINT = {
  taglish: '[Reply in natural conversational Taglish with "po" - everyday Tagalog mixed with English the way a GenSan host texts, not formal Tagalog.] ',
  bisaya: '[Tubaga sa natural nga Bislish. Reply in natural Bislish (Cebuano with English hospitality terms). Never use Tagalog "po" / "opo" or Tagalog words such as "kasya".] ',
  english_po: '[The guest wrote English with a courtesy "po". Reply in warm English; one "po" is welcome, no Tagalog sentences.] ',
  english: '',
};

// Address guard (Lloyd, 2026-09-13): the block and lot are shared by the host after confirmation,
// never by the bot. The fact sheet no longer carries them; this catches a model that recalls them.
const ADDRESS_RE = /\b(block|blk\.?)\s*47\b,?\s*|\blot\s*39\b,?\s*/gi;
function redactAddress(reply: string): string {
  if (!ADDRESS_RE.test(reply)) return reply;
  console.error('address_redacted', reply.slice(0, 160));
  return reply.replace(ADDRESS_RE, '').replace(/\s{2,}/g, ' ');
}
// Rule of thumb 1-2 (Lloyd, 2026-09-11): positive frame, no negative words. Checked in code; one
// retry with a hard instruction, then the retry is sent as is and logged (safety lines and the
// fixed handoff lines never pass through here).
const NEGATIVE_RE = /\b(unfortunately|sorry|cannot|can'?t|(don'?t|do not|doesn'?t|does not) (have|offer|allow|accept|provide)|not (available|allowed|possible|permitted)|no longer|hindi (po )?(pwede|puwede|available)|wala (po )?(kami|kaming)|bawal)\b/i;
// Lloyd 2026-09-13: the booking link stands alone on its own line with a blank line above and
// below, so it is the one thing that catches the eye. The model tucked it mid-sentence live
// ("...through our site at https://tinyurl.com/... . If you have...").
function linkSolo(reply: string, url: string): string {
  if (!reply.includes(url)) return reply;
  const out: string[] = [];
  for (const line of reply.split('\n')) {
    const i = line.indexOf(url);
    if (i < 0) { out.push(line); continue; }
    const before = line.slice(0, i).replace(/\s*(?:👉\s*)?(?:\bat\b)?\s*:?\s*$/i, '').trim();
    const after = line.slice(i + url.length).replace(/^[.,!;:)]+\s*/, '').trim();
    if (before) out.push(before);
    out.push('', `👉 ${url}`, '');
    if (after) out.push(after);
  }
  return out.join('\n').replace(/\n{3,}/g, '\n\n').trim();
}
// Lloyd 2026-09-13: "the goal is to nudge always the messenger to book the unit". A model reply
// that ends with neither a question nor the link gets one soft next step - dates when unknown,
// the site when known. Closers, handoffs and the fixed lines never pass through here.
function bookingNudge(reply: string, lang: string, datesKnown: boolean, linkRecent: boolean): string {
  // Already nudged when the reply ends with a question, carries the link, or its last paragraph
  // already talks about dates or booking (live v56: the model wrote its own dates line and the
  // guard added a second one).
  const isEn = lang === 'english' || lang === 'english_po';
  const lastPara = reply.trim().split(/\n{2,}/).pop() ?? '';
  if (reply.includes(SITE_URL)) return reply;
  // Lloyd's canonical shape (2026-09-13): the site line plus the direct-booking tagline, link solo,
  // withheld only when one of our last two replies already carried the link.
  const siteEn = `We can arrange the booking right here in the chat, or you may check and secure your dates directly on our site:\n\n👉 ${SITE_URL}\n\nDirect bookings enjoy our best rates, with savings that grow the longer you stay.`;
  const siteTl = `We can arrange the booking dito sa chat, o maaari rin po kayong mag-check at mag-secure ng dates directly sa site namin:\n\n👉 ${SITE_URL}\n\nMas mababa po ang rate kapag direct booking, at lalo pong tumitipid habang humahaba ang stay.`;
  // The model already closed with a dates line: add only the site part (no second "let us know").
  if (/\?\s*$/.test(reply.trim()) || /\b(dates?|petsa|book|reserve|availability|i-?hold)\b/i.test(lastPara)) {
    return linkRecent ? reply : `${reply.trim()}\n\n${isEn ? siteEn : siteTl}`;
  }
  // Soft, warm, friendly - an open door, never a push.
  const en = !datesKnown
    ? `Just let us know your preferred dates, and we'll gladly check our availability for you.${linkRecent ? '' : ' ' + siteEn}`
    : linkRecent ? '' // session 30: the canned "No pressure at all…" / "Whenever it feels right…" lines stacked a second invitation on the model's own warm close
    : `Whenever you feel ready, we can arrange the booking right here in the chat, or you may secure your dates directly on our site:\n\n👉 ${SITE_URL}\n\nDirect bookings enjoy our best rates, with savings that grow the longer you stay.`;
  const tl = !datesKnown
    ? `Sabihin lang po ang preferred dates ninyo at gladly po naming iche-check ang availability para sa inyo.${linkRecent ? '' : ' ' + siteTl}`
    : linkRecent ? ''
    : `Kapag handa na po kayo, we can arrange the booking dito sa chat, o maaari ninyong i-secure ang dates directly sa site namin:\n\n👉 ${SITE_URL}\n\nMas mababa po ang rate kapag direct booking, at lalo pong tumitipid habang humahaba ang stay.`;
  // english_po replies are English with one courtesy po, so the nudge stays English too
  // (live v55: an English answer got a Taglish nudge).
  const add = isEn ? en : tl;
  return add ? `${reply.trim()}\n\n${add}` : reply.trim();
}
// Messenger renders markdown literally ("*   Robinsons", "**2:00 PM**" seen live 2026-09-13).
const plainText = (s: string) => s.replace(/^[ \t]*[*•-][ \t]+/gm, '').replace(/\*\*([^*\n]+)\*\*/g, '$1');

function draftFrom(raw: string, who: string): Draft {
  const parsed = JSON.parse(raw) as { reply?: string; uncertain?: boolean; guest_name?: unknown };
  const reply = (parsed.reply ?? '').trim().slice(0, 1800); // Messenger allows 2000; two handoff options need room
  if (!reply) throw new Error(`${who}_empty`);
  // Change 2 (D-097): the name the guest states in the conversation, when Graph gives us none.
  // One or two capitalised words, letters only, so "unknown", "Ma'am" or a sentence never sticks.
  const n = typeof parsed.guest_name === 'string' ? parsed.guest_name.trim() : '';
  const guest_name = /^\p{Lu}[\p{L}'-]{1,20}( \p{Lu}[\p{L}'-]{1,20})?$/u.test(n) && !/^(unknown|guest|sir|ma'?am|maam|none|null)$/i.test(n) ? n.split(' ')[0] : null;
  return { reply, uncertain: parsed.uncertain === true, guest_name };
}

// The landmark list is ~1.2k tokens; send it only when the turn is about a place, a distance or
// getting around (2026-09-13 token audit). Anything else answers from FACTS.
const PLACE_RE = /\b(far|near|distance|km|minutes?|mall|airport|hospital|clinic|pharmacy|resort|pool|beach|cafe|coffee|restaurant|food|eat|kain|dining|market|atm|bank|gas|store|church|school|transpo|grab|taxi|tricycle|drive|route|direction|location|asa|saan|malapit|layo|duol|lugar|place|around|nearby|recommend)\b/i;
async function draft(thread: Thread, question: string, availability: string, tier: 'full' | 'lite' = 'full', compact = false): Promise<Draft> {
  const landmarks = PLACE_RE.test(question) ? await landmarksBlock(dbForLandmarks!).catch(() => '') : 'Not loaded for this turn; for a place or distance not in FACTS say the host will confirm.';
  const raw = await chatJson({
    system: systemPrompt(thread, availability, landmarks, compact),
    history: thread.history.slice(-HISTORY_KEEP).map((h) => ({ role: h.role === 'bot' ? 'assistant' as const : 'user' as const, text: h.text })),
    question, title: 'Cascade Concierge', tier,
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
  const ask = `${stayAnchor(text)}The guest just wrote: "${text}". Our host will answer this personally. Draft exactly TWO alternative replies the host could send - one gently declining or holding the line, one accommodating if we can - each complete, in our voice, 40-90 words, no link. Return them in "reply" separated by a line containing only ---. Set uncertain to false.`;
  try {
    const out = await draft(thread, ask, availability, 'lite', true); // compact: 9.6k -> ~5.8k input tokens (llm_usage, 2026-09-13)
    const parts = out.reply.split(/\n\s*---\s*\n/).map((s) => s.trim()).filter(Boolean);
    return parts.slice(0, 2);
  } catch (e) { console.error('suggest_options_failed', String(e).slice(0, 200)); return []; }
}

// What this guest is already waiting on from the host, so the bot can answer other questions
// without re-opening the same request or pretending it never happened.
async function pendingBlock(db: Db, psid: string): Promise<string> {
  const { data } = await db.from('concierge_handoffs').select('risk, guest_text, created_at').eq('psid', psid).eq('status', 'open').order('created_at', { ascending: false }).limit(5);
  if (!data?.length) return '';
  const lines = data.map((h) => `- ${h.risk}: "${String(h.guest_text).slice(0, 160)}"`);
  return `\n\nPENDING WITH THE HOST (already passed along; the host will answer these personally):\n${lines.join('\n')}\nKeep answering everything else normally. If the guest asks about a pending item again, say warmly that the host is reviewing it and will reply personally - do not answer it yourself and do not promise an outcome.`;
}

async function openHandoff(db: Db, thread: Thread, text: string, risk: RiskCode, link: string): Promise<void> {
  const chat = env('TELEGRAM_CHAT_ID'); if (!chat) return;
  // A repeat of the SAME ask within 24 h nudges nobody twice. It used to be one open card per
  // guest per risk with no age limit: two stale policy cards from the day before silently
  // swallowed a dog request and a price proposal (live audit 2026-09-13) - the host never saw them.
  const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  const { data: dup } = await db.from('concierge_handoffs').select('guest_text').eq('psid', thread.psid).eq('risk', risk).eq('status', 'open').gte('created_at', new Date(Date.now() - HUMAN_HOLD_MS).toISOString()).limit(10);
  if ((dup ?? []).some((d: any) => norm(String(d.guest_text)) === norm(text))) return;
  const options = await suggestOptions(thread, text, await availabilityBlock(db));
  const { data: row } = await db.from('concierge_handoffs').insert({ psid: thread.psid, guest_name: thread.guest_name, guest_text: text, risk, options }).select('id').single();
  const id: string = row?.id ?? ''; if (!id) return;
  const short = id.slice(0, 8);
  // Something is wrong with the unit (or the guest is unsafe): make it a work order too. The
  // handoff card is the alert; the row is what Today and the readiness check read.
  let woLine = '';
  if (risk === 'complaint' || risk === 'safety') {
    const wo = await raiseWorkOrder(db, {
      sourceKind: 'guest_report', sourceRef: `concierge_handoff:${id}`, title: text.slice(0, 200),
      detail: `Messenger ${risk} from ${thread.guest_name ?? thread.psid} (#CH-${short})`, priority: risk === 'safety' ? 'urgent' : 'high',
    });
    if (wo?.id) woLine = `🔧 Work order #${wo.id.slice(0, 8)} ${wo.created ? 'raised' : 'already open'}${wo.blocks_arrival ? ' — blocks the next arrival until closed' : ''}`;
  }
  const body = withHeader('guest', `handoff · ${risk}`, [
    `🛎 Guest needs the host (${risk})`,
    `Guest: ${thread.guest_name ?? thread.psid}`,
    `> ${text.slice(0, 400)}`,
    ...(woLine ? [woLine] : []),
    '',
    ...options.map((o, i) => `Option ${i + 1}:\n${o}\n`),
    `Tap an option to send it to the guest, or reply to this message to write your own. #CH-${short}`,
    link,
  ].join('\n'));
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
  await fbSend(h.psid, final, true);
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

// ---- Book flow I/O (booking PRD §A). The pure parts live in booking.ts. ----
// SITE_URL is the tinyurl; the QR asset needs the Pages origin.
const QR_URL = 'https://cascadereservations-del.github.io/Stay_At_CascadeGSC/assets/images/qr-gcash.png';
async function submitFlow(flow: Flow, thread: Thread, psid: string): Promise<{ flow: Flow; reply: string; image: string | null }> {
  const q = quoteTotal(flow.checkin!, flow.checkout!); // session 28: the guest chose fee or full; submit-booking accepts either
  const body = { guest_name: thread.guest_name ?? 'Messenger guest', guest_phone: flow.phone, guest_email: flow.email ?? '', checkin_date: flow.checkin, checkout_date: flow.checkout,
    pax: flow.pax, notes: `via Messenger (psid ${psid})`, contact_type: 'phone', hold: true, channel: 'messenger', total_amount: q.total, deposit_amount: flow.pay_full ? q.total : q.deposit };
  const r = await fetch(`${env('SUPABASE_URL')}/functions/v1/submit-booking`, { method: 'POST', headers: { 'Content-Type': 'application/json', apikey: env('SUPABASE_ANON_KEY'), Authorization: `Bearer ${env('SUPABASE_ANON_KEY')}` }, body: JSON.stringify(body), signal: AbortSignal.timeout(30_000) }).catch(() => null);
  const j = r ? await r.json().catch(() => null) : null;
  if (!r || !j) { console.error('submit_flow_failed', r?.status); return { flow, reply: `Sorry po, something went wrong on our side — please try again in a minute, or book here: ${SITE_URL}`, image: null }; }
  if (r.status === 409 || j.error === 'dates_unavailable') return { flow: { ...flow, step: 'dates', updated_at: new Date().toISOString() }, reply: reg(flow.lang, { en: `Sorry — those dates were reserved just moments ago. If other dates suit you, just share your check-in and check-out and we'll gladly check them for you.`, tl: `Sorry po, kaka-reserve lang ng dates na iyon. If may ibang dates kayong gusto, share lang po ang check-in and check-out and iche-check namin agad.`, bis: `Sorry, kaka-reserve lang sa dates nga na. If naa moy other dates, share lang ang check-in and check-out and amo dayon i-check.` }), image: null };
  if (!j.ok) { console.error('submit_flow_rejected', JSON.stringify(j).slice(0, 200)); return { flow, reply: `Sorry po, I couldn't send that request (${String(j.error ?? 'error').replace(/_/g, ' ')}). You can also book here: ${SITE_URL}`, image: null }; }
  const f: Flow = { ...flow, step: 'await_receipt', booking_id: j.inquiry_id, ref: j.ref, deposit: Number(j.deposit_amount), total: Number(j.total_amount), hold: j.hold === true,
    hold_expires_at: j.hold_expires_at ?? null, receipt_token: j.receipt_upload_token, receipt_expires_at: j.receipt_upload_expires_at, updated_at: new Date().toISOString() };
  return { flow: f, reply: paymentReply(f, thread.guest_name, SITE_URL), image: QR_URL };
}
async function forwardReceipt(flow: Flow, url: string, name: string | null): Promise<{ sent: boolean; reply: string }> {
  const first = name ? name.split(' ')[0] : 'po';
  if (!flow.receipt_token || (flow.receipt_expires_at && Date.parse(flow.receipt_expires_at) < Date.now())) return { sent: false, reply: reg(flow.lang, { en: `Thank you. That hold has since expired — just say "book" and we'll set the dates up again.`, tl: `Salamat po. Nag-expire na ang hold na iyon — message lang po "book" and we'll set the dates up again.`, bis: `Salamat. Na-expire na ang hold — message lang "book" and amo i-set up ang dates again.` }) };
  const img = await fetch(url, { signal: AbortSignal.timeout(20_000) }).catch(() => null);
  if (!img || !img.ok) return { sent: false, reply: reg(flow.lang, { en: `Sorry, I couldn't open that image. Could you send it once more?`, tl: `Sorry po, hindi ko ma-open ang image. Puwede po bang i-send ulit?`, bis: `Sorry, wala nako ma-open ang image. Pwede i-send usab?` }) };
  const bytes = new Uint8Array(await img.arrayBuffer());
  const mime = (img.headers.get('content-type') ?? 'image/jpeg').split(';')[0].trim();
  const r = await fetch(`${env('SUPABASE_URL')}/functions/v1/upload-booking-receipt`, { method: 'POST', headers: { Authorization: `Bearer ${flow.receipt_token}`, 'Content-Type': mime, 'X-Receipt-Filename': 'messenger.' + (mime.split('/')[1] || 'jpg'), apikey: env('SUPABASE_ANON_KEY') }, body: bytes, signal: AbortSignal.timeout(30_000) }).catch(() => null);
  const j = r ? await r.json().catch(() => ({})) : {};
  if (r?.ok) return { sent: true, reply: reg(flow.lang, { en: `Thank you, ${first}. We've received your receipt and we'll confirm the reservation as soon as it's reviewed. You'll hear from us here.`, tl: `Salamat po, ${first}. Received na namin ang receipt — iko-confirm namin ang reservation once na-review na. Dito po namin kayo iu-update.`, bis: `Salamat, ${first}. Na-receive na namo ang receipt — amo dayon i-confirm ang reservation once na-review na. Diri ra namo mo i-update.` }) };
  if (j?.error === 'receipt_already_uploaded') return { sent: true, reply: reg(flow.lang, { en: `Your receipt is already with us and it's being reviewed.`, tl: `Nasa amin na po ang receipt ninyo — nire-review na.`, bis: `Naa na sa amo ang receipt — gi-review na.` }) };
  if (r?.status === 401) return { sent: false, reply: reg(flow.lang, { en: `Thank you. That upload link has since expired — just say "book" and we'll set the dates up again.`, tl: `Salamat po. Nag-expire na ang upload link — message lang po "book" and we'll set the dates up again.`, bis: `Salamat. Na-expire na ang upload link — message lang "book" and amo i-set up ang dates again.` }) };
  console.error('forward_receipt_failed', r?.status, JSON.stringify(j).slice(0, 200));
  return { sent: false, reply: `I couldn't attach that receipt po (${String(j?.error ?? 'error').replace(/_/g, ' ')}). Could you send it again?` };
}

/** Booked nights overlapping the flow's stay (calendar_events, cancelled excluded). */
/** Booked nights that overlap the stay, or null when the calendar could not be read (session 30: a failed read
 *  used to return an empty set, and the guest was told the dates were available). */
async function bookedNightsFor(db: Db, flow: Flow): Promise<Set<string> | null> {
  const { data: rows, error } = await db.from('calendar_events').select('checkin_date, checkout_date').neq('status', 'cancelled').lt('checkin_date', flow.checkout!).gt('checkout_date', flow.checkin!).limit(50);
  if (error) { console.error('calendar_read_failed', 'bookedNightsFor', String(error.message ?? error).slice(0, 200)); return null; }
  const booked = new Set<string>();
  for (const r of rows ?? []) for (let d = r.checkin_date; d < r.checkout_date; d = addDays(d, 1)) booked.add(d);
  return booked;
}
async function handle(db: Db, ev: Record<string, any>, mode: string): Promise<void> {
  const msg = ev.message; if (!msg) return;
  const now = new Date();

  // Staff replied from the Page inbox: hold the bot on this thread.
  if (msg.is_echo) {
    if (env('META_APP_ID') && String(msg.app_id ?? '') === env('META_APP_ID')) return; // our own send
    // Session 28 (live 2026-09-17 08:54): Messenger renders our GCash number and QR into its own
    // "Transfer with GCash" / "QR transfer" cards and echoes them as Page messages with no app_id and
    // no text. They are not a staff reply: an attachment-only echo within 3 min of our last bot turn
    // is Meta's, and holding the bot on it silenced the guest's next two questions for 2 h.
    if (!msg.text && Array.isArray(msg.attachments)) {
      const { data: t } = await db.from('concierge_threads').select('history').eq('psid', ev.recipient.id).maybeSingle();
      const lastBot = [...((t?.history ?? []) as Turn[])].reverse().find((h) => h.role === 'bot');
      if (lastBot && now.getTime() - Date.parse(lastBot.at) < 3 * 60_000) { console.log('echo_ignored_meta_card', JSON.stringify({ psid: ev.recipient.id, types: msg.attachments.map((a: any) => a?.type) })); return; }
    }
    await db.from('concierge_threads').upsert({ psid: ev.recipient.id, human_until: new Date(now.getTime() + ECHO_HOLD_MS).toISOString(), updated_at: now.toISOString() });
    return;
  }

  const psid: string = ev.sender.id;
  const { data: row } = await db.from('concierge_threads').select('*').eq('psid', psid).maybeSingle();
  const thread: Thread = (row as Thread | null) ?? { psid, guest_name: null, human_until: null, bot_turns: 0, history: [], last_risk: null, booking_flow: null };
  if (!thread.guest_name) thread.guest_name = await fbName(psid);

  const text: string = (msg.text ?? '').trim();
  const link = `https://www.facebook.com/messages/t/${psid}`;
  // Conversation stage, computed here rather than guessed by the model: a greeting belongs to the
  // first exchange or after a long silence; every other turn continues the chat. The same gap
  // resets the 12-turn cap (2026-09-13: bot_turns only ever grew, so a chatty guest was handed to
  // the host on every message for the rest of the thread's life).
  const lastBot = [...thread.history].reverse().find((h) => h.role === 'bot');
  const gapMin = lastBot ? (now.getTime() - Date.parse(lastBot.at)) / 60_000 : Infinity;
  const followUp = gapMin < 6 * 60;
  const priorTurns = followUp ? thread.bot_turns : 0;
  const g = gate(text || 'attachment', { mode, humanUntil: thread.human_until, botTurns: priorTurns, now });
  // Lloyd 2026-09-13: a discount ask gets the answer (the direct site applies the best rate
  // automatically; the longer the stay, the higher the discount) AND the host line and card.
  const discountAsk = /\b(discount|discounted|lower price|best price|cheaper|mas mura|promo|may promo)\b/i.test(text);
  let risk: RiskCode = text ? g.risk : 'uncertain';
  let handoff = g.handoff || !text;   // the bot steps aside: handoff line to the guest, 24 h hold
  let flagOnly = false;               // the bot answered but wants a host to glance: alert, no hold
  let reply = '';

  // Book flow: runs before every other branch. A receipt image on a thread that is waiting for one
  // is evidence, not an attachment handoff; a slot answer is code-parsed; a question mid-flow passes
  // through to the model with the flow kept where it is.
  let flow: Flow | null = isActive(thread.booking_flow, now) ? thread.booking_flow! : null;
  let flowReply: string | null = null, flowImage: string | null = null, flowFollowUp: string | null = null;
  let calendarDown = false; // session 30: the calendar read failed on this turn - the reply does not claim availability and a host is told
  const attachment = (msg.attachments ?? []).find((a: any) => a?.type === 'image' && a?.payload?.url);
  if (g.reply && flow?.step === 'await_receipt' && attachment) {
    const r = await forwardReceipt(flow, String(attachment.payload.url), thread.guest_name);
    flowReply = r.reply; if (r.sent) flow = { ...flow, step: 'receipt_sent', updated_at: now.toISOString() };
  } else if (g.reply && text && !g.handoff && flow && !['await_receipt', 'receipt_sent'].includes(flow.step)) {
    const before = flow;
    const s = answer(flow, text, now); flow = s.flow;
    if (s.action === 'passthrough') flowFollowUp = prompt(flow, thread.guest_name, true); // protocol: the model answers, then the flow's ask follows (resumed card: soft nudge)
    if (s.action === 'ask') flowReply = s.reply ?? prompt(flow, thread.guest_name);
    // Protocol rule 1 mid-flow (live 2026-09-17 10:57: "Oct 20 to 22 po, available pa po ba?" got the contact ask with no
    // answer): dates completed on this turn are checked against the calendar before the next ask.
    if (s.action === 'ask' && flow.checkin && flow.checkout && (flow.checkin !== before.checkin || flow.checkout !== before.checkout)) {
      const nights = await bookedNightsFor(db, flow); calendarDown = !nights;
      const line = availabilityLine(flow, nights);
      if (/already reserved|Reserved na/.test(line)) { flow = { ...flow, step: 'dates', checkin: undefined, checkout: undefined }; flowReply = line; }
      else flowReply = `${availabilityAck(flow, line)}\n\n${s.reply ?? prompt(flow, thread.guest_name)}`;
    }
    else if (s.action === 'cancelled') flowReply = s.reply;
    else if (s.action === 'submit') { const r = await submitFlow(flow, thread, psid); flow = r.flow; flowReply = r.reply; flowImage = r.image; }
  } else if (g.reply && text && !g.handoff && !flow && g.risk === 'routine' && BOOK_RE.test(text) && !/\b(how (do|can) (i|we)|paano|can i|pwede( po)? ba|possible)\b/i.test(text)) {
    flow = start(text, now);
    // Protocol rule 1 - answer what was asked before asking anything. Availability is answered from the
    // calendar here (exact, no model); any other question goes to the model with the flow's ask appended.
    if (flow.asked === 'availability') {
      const nights = await bookedNightsFor(db, flow); calendarDown = !nights;
      const line = availabilityLine(flow, nights);
      if (/already reserved|Reserved na/.test(line)) { flow = { ...flow, step: 'dates', checkin: undefined, checkout: undefined }; flowReply = greeting(thread.guest_name, flow.lang) + line; }
      else flowReply = opener(flow, thread.guest_name, line) + prompt(flow, thread.guest_name);
    } else if (flow.asked === 'question') flowFollowUp = opener(flow, thread.guest_name).trim() + '\n\n' + prompt(flow, thread.guest_name);
    else flowReply = opener(flow, thread.guest_name) + prompt(flow, thread.guest_name); // session 28: welcome first
  }
  if (flow) thread.booking_flow = flow;
  if (flowReply) { handoff = false; risk = 'routine'; }
  if (calendarDown) flagOnly = true; // OPS gets the glance card: the guest was told we will confirm the dates

  if (!g.reply) { /* mode off, or a human holds this thread */ }
  else if (flowReply) reply = flowReply;
  else if (handoff) reply = text ? HANDOFF[risk] : ATTACHMENT_REPLY;
  else if (THANKS_RE.test(text) || CLOSER_ONLY_RE.test(text)) reply = closingReply(thread.guest_name, guestLang(text), THANKS_RE.test(text), thread.history.filter((h) => h.role === 'bot').slice(-2).map((h) => h.text).join('\n'));
  else if (BOT_RE.test(text)) reply = botReply(thread.guest_name, guestLang(text));
  else if (needsDatesFirst(text, thread.history.filter((h) => h.role === 'guest').map((h) => h.text).join(' '))) reply = datesFirstReply(thread.guest_name, text);
  else {
    try {
      const stateBlock = followUp
        ? `\n\nCONVERSATION STATE: this is a FOLLOW-UP in a live chat (your last reply was ${Math.round(gapMin)} min ago). Do NOT greet again - no "Hello", "Hi", "Hello po", "Good morning". Address the guest by name early in the first sentence instead ("Ben, yes po...", "Sige po, Sir Ben, ..."), the way a host continues a conversation, then the answer.`
        : `\n\nCONVERSATION STATE: this is the FIRST exchange (or the guest is back after a long gap). Greet once, warmly, by first name if known.`;
      // First exchange gets the full model (voice, warmth, facts); follow-ups run on the lite tier.
      // Follow-ups: compact prompt (no exemplars) on the full model - cheaper than the old full
      // prompt AND better behaved than lite; the language hint rides on the guest's own turn.
      // Lloyd 2026-09-17 14:40: Bislish only when the guest keeps writing Bisaya (this turn and their previous one); a lone Bisaya turn gets Taglish.
      const prevGuest = thread.history.filter((h) => h.role === 'guest').slice(-1)[0]?.text ?? '';
      const lang = guestLang(text) === 'bisaya' && guestLang(prevGuest) !== 'bisaya' && flow?.lang !== 'bis' ? 'taglish' : guestLang(text);
      const guestTexts = [...thread.history.filter((h) => h.role === 'guest').map((h) => h.text), text];
      const context = (await availabilityBlock(db)) + (await pendingBlock(db, psid)) + guestDatesBlock(guestTexts) + stateBlock;
      // The dates also ride on the guest turn: the system-side block alone was ignored for a
      // Bisaya late check-out question (live 2026-09-13) and the model asked for dates again.
      const datesKnown = [...new Set(guestTexts.join(' \n ').match(DATES_RE) ?? [])].slice(-3);
      const datesHint = datesKnown.length ? `[Guest's dates already given: ${datesKnown.join('; ')} - answer for these days, do not ask for dates.] ` : '';
      // Capacity rides on the guest turn too: "pwede 5 adults?" got "we can accommodate 5 adults" (live 2026-09-13).
      const capHint = /\b([4-9]|1\d)\s*(adults?|pax|persons?|people|guests?|tao|matanda)\b/i.test(text) ? '[Capacity is a hard limit: 3 adults, or 3 adults + 1 child, or 2 adults + 2 children. This group does not fit - say so warmly and suggest a larger place; never say we can accommodate them.] ' : '';
      const anchor = stayAnchor(guestTexts.slice(-3).join(' '));
      const discHint = discountAsk ? `[Discount ask: say warmly that booking through our direct site gives the best rate automatically - adjusted to the dates and discounted by length of stay, 5% from 2 nights up to 25% from 28 nights, the longer the stay the higher the discount - then the link. Do not quote any other number and do not promise a special price.] ${anchor}` : (/\b(rate|price|magkano|how much|pila|tagpila)\b/i.test(text) ? anchor : '');
      const nameHint = !thread.guest_name && !followUp ? '[Guest name unknown: ask for their name once, warmly, inside this reply.] ' : '';
      // Lloyd 2026-09-17 14:30: mid-flow answers read bland and transactional. The model is told where it is and what follows.
      const flowHint = flowFollowUp ? '[The guest is in the middle of booking with us, and their booking summary follows your answer. Reply in two or three warm, unhurried sentences: the answer first, then the one reassurance or offer of help that fits it. No stay details, no amounts, no link, no closing question.] ' : '';
      // Session 30 (live): the chat already held "2 guests" from an earlier booking attempt and the model asked again.
      const knownPax = thread.booking_flow?.pax;
      const paxHint = knownPax && !flowFollowUp ? `[Already known from this chat: ${knownPax} guest${knownPax === 1 ? '' : 's'}. Do not ask how many guests again; ask something only if it is truly needed.] ` : '';
      let out = await draft(thread, nameHint + discHint + capHint + datesHint + paxHint + flowHint + LANG_HINT[lang] + text, context, 'full', followUp);
      // A name the guest states ("Hi, this is Ben") wins over the Facebook profile name (live
      // 2026-09-13: profile said Löyd, guest said Ben).
      if (out.guest_name && out.guest_name !== thread.guest_name) { console.log('guest_name_from_conversation', out.guest_name, 'was', thread.guest_name); thread.guest_name = out.guest_name; }
      if (NEGATIVE_RE.test(out.reply)) {
        console.error('negative_frame_retry', out.reply.slice(0, 160));
        const fix = `[REWRITE REQUIRED. Your draft opened with a negative ("${out.reply.slice(0, 60).replace(/\n/g, ' ')}..."). The first sentence must name what we DO offer for this wish - e.g. "For swimming po, EM Jake Wave Pool is about 2 km away" instead of "Wala po kaming pool"; "The unit is best suited to 3 adults" instead of "Hindi po pwede ang 4". Do not use "wala", "hindi pwede", "sorry", "unfortunately", "cannot", "not available" anywhere in the reply.] `;
        out = await draft(thread, fix + LANG_HINT[lang] + text, context, 'full', followUp).catch(() => out);
      }
      // Session 30: a correct but cold answer is a defect (protocol 08 section 6: answer, context, next step, reassurance,
      // warm close). One rewrite, the same way a negative opener gets one; if it fails we keep the first draft.
      if (!flowFollowUp && isCold(out.reply)) {
        console.warn('cold_reply_retry', out.reply.slice(0, 160));
        const warm = `[REWRITE REQUIRED. Your draft was correct but read as blunt and transactional. Keep every fact. Write it the way a calm boutique-hotel concierge would type it in chat: the answer first; then one sentence that shows care or preparation done for the guest ("we'll have it ready", "so you can settle in without a second thought"); then the next step made easy; then one short warm close on its own line. Natural contractions. No sales language, no "no pressure", no exclamation words, no second invitation.] `;
        out = await draft(thread, warm + paxHint + datesHint + LANG_HINT[lang] + text, context, 'full', followUp).catch(() => out);
      }
      if (followUp) {
        out.reply = out.reply.replace(/^\s*(hello|hi|hey|good (morning|afternoon|evening)|kumusta|kamusta|maayong \w+)[^\n]{0,60}?[!.,]?\s*\n+/i, '');
        // Inline greeting on a follow-up ("Hi Ben, about po sa 4 adults..." live 2026-09-13): drop
        // the "Hi " but keep the name up front, as Lloyd wants the name early in the sentence.
        // \p{L} so "Löyd" (live 2026-09-13) and other accented names match too.
        out.reply = out.reply.replace(/^\s*(hello|hi|hey|maayong \p{L}+|magandang \p{L}+|good (?:morning|afternoon|evening)|kumusta|kamusta)( po)?,?\s+((?:sir|ma'?am)\s+)?(\p{Lu}[\p{L}'-]*[,!.])/iu, (_m, _a, _b, t: string | undefined, n: string) => `${t ? t[0].toUpperCase() + t.slice(1) : ''}${n}`.replace(/!$/, ','));
        // Link and tagline belong to first contact. On a follow-up they come back only if the guest
        // asked how to book; otherwise strip them in code rather than hoping the model will.
        // Lloyd 2026-09-13: nudge the direct site wherever it fits - booking intent, rates, dates,
        // availability, "will think about it". Other follow-ups stay link-free.
        const asksToBook = /\b(book|reserve|reservation|link|site|website|magpa-?book|paano (po )?mag|how (do|can) (i|we)|rate|price|how much|magkano|pila|tagpila|avail|dates?|nights?|weekend|think about|decide|consider)\b/i.test(text);
        if (!asksToBook) {
          out.reply = out.reply.split('\n').filter((l) => !l.includes(SITE_URL) && !/^\s*👉\s*$/.test(l)).join('\n');
          // Only a trailing line after other content is stripped (the leading \n is required):
          // unanchored, a one-line reply that opened with "We'd be happy to..." was wiped to
          // nothing and nothing was sent (live, 2026-09-13 11:13Z).
          const before = out.reply;
          // Session 30 (Lloyd: "what happened to the warmth"): this used to delete EVERY warm close on a follow-up. A warm
          // close is part of the protocol (08 section 22); it goes only when our previous reply ended the same way.
          const WARM_CLOSE_RE = /\n\s*(we'?d be (happy|glad) to welcome you[^\n]*|we'?d love to (host|welcome) you[^\n]*|we look forward to (hosting|welcoming) you[^\n]*|masaya (po )?naming[^\n]*welcome[^\n]*)\s*$/i;
          if (WARM_CLOSE_RE.test('\n' + (lastBot?.text ?? '').trim().split('\n').pop())) out.reply = out.reply.replace(WARM_CLOSE_RE, '');
          out.reply = out.reply.replace(/\n\s*(if you (already )?have your dates[^\n]*|you can (also )?(check|view|secure)[^\n]*(availability|booking|dates)[^\n]*:?)\s*$/i, '');
          if (!out.reply.trim()) { console.error('reply_stripped_empty', before.slice(0, 200)); out.reply = before; }
        }
        out.reply = out.reply.replace(/\n{3,}/g, '\n\n').trim();
      }
      // A guest who calls US "Ma'am"/"Sir" does not become "Ma'am Löyd" (live 2026-09-13, twice
      // despite the prompt rule): drop a title the model put before their name in that case.
      if (thread.guest_name && /\b(ma'?am|sir|maam)\b/i.test(text)) out.reply = out.reply.replace(new RegExp(`\\b(ma'?am|sir)\\s+(?=${thread.guest_name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b)`, 'giu'), '');
      reply = thinPo(plainText(redactAddress(trimRepeatedInvite(out.reply, thread.history.filter((h) => h.role === 'bot').map((h) => h.text), text, SITE_URL))), lang === 'bisaya' ? 0 : 2); // protocol 09: no Tagalog po in Bisaya
      // The first substantive reply carries the booking link (VOICE); the model dropped it on
      // "Hello po" (live audit 2026-09-13), so it is guaranteed here.
      if ((!followUp || discountAsk) && !reply.includes(SITE_URL) && !flowFollowUp) reply += `\n\n👉 ${SITE_URL}`;
      if (flowFollowUp) reply = `${answerOnly(reply)}\n\n${flowFollowUp}`; // the answer came first (and only the answer, session 29); now the flow's own ask
      if (discountAsk) { reply += `\n\n${HANDOFF.policy_exception}`; handoff = true; risk = 'policy_exception'; }
      const l3 = lang === 'bisaya' ? 'bis' as const : lang === 'taglish' ? 'tl' as const : 'en' as const;
      // A decision moment ("will think about it", "how do I book") always leaves the door open
      // with the link (live audit 2026-09-13: the model gave warmth and no link).
      if (followUp && /\b(think about|decide|consider|book|reserve|reservation|magpa-?book|paano (po )?mag)\b/i.test(text) && !reply.includes(SITE_URL)) reply = beforeClose(reply, decisionInvite(l3, SITE_URL)); // session 30: never a bare link after the close
      // Repair a dangling "…on our site:" BEFORE the nudge decides (live 2026-09-17 19:12: the nudge saw no link,
      // appended its own line, and only then was the link put back - two invitations).
      if (!flowFollowUp) reply = tidyReply(reply, SITE_URL, lang === 'english' || lang === 'english_po');
      if (!discountAsk) reply = bookingNudge(reply, lang, datesKnown.length > 0, thread.history.filter((h) => h.role === 'bot').slice(-2).some((h) => h.text.includes(SITE_URL)));
      reply = linkSolo(reply, SITE_URL);
      if (knownPax && !flowFollowUp) reply = dropPaxAsk(reply);
      if (!flowFollowUp) reply = tidyReply(reply, SITE_URL, lang === 'english' || lang === 'english_po'); // session 30: no dangling "on our site:", one invitation, contractions
      if (!flowFollowUp && !discountAsk) reply = addChatRoute(reply, SITE_URL, l3); // Lloyd 2026-09-17: the site AND the chat, guaranteed in code
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
    // Mid-flow (session 28 T6): the guest is already booking here - no site invite after the answer, and the composite
    // (model answer + card) is not lint-scored as one message.
    if (flowFollowUp) reply = reply.split(/\n\s*\n/).filter((p) => !/^(O maaari rin po kayong mag-check|Or you may check and secure|Kapag handa na po kayo, maaari|Whenever you feel ready|👉 |Mas mababa po ang rate kapag direct|Direct bookings enjoy our best rates)/.test(p.trim())).join('\n\n');
    // Lloyd 2026-09-17 14:30: show the direct site whenever practicable - once, under a resumed confirm card.
    if (flowFollowUp && flow?.step === 'confirm') reply += '\n\n' + ({ en: `If you'd like to see more of the home first, everything is on our site, where direct bookings enjoy our best rates:`, tl: `If you'd like to see more of the home first, nasa site namin po ang lahat, with our best rates for direct bookings:`, bis: `If you'd like to see more of the home first, naa sa among site ang tanan, with our best rates for direct bookings:` })[flow.lang ?? 'en'] + `\n\n👉 ${SITE_URL}`;
    const lint = flowFollowUp ? [] : lintReply(reply, text, { firstTurn: !thread.history.length, name: thread.guest_name });
    if (lint.length) console.warn('voice_lint', JSON.stringify({ psid, lint, reply: reply.slice(0, 160) }));
    if (mode === 'auto') {
      await fbSend(psid, reply);
      if (flowImage) { // session 28: the QR carries the chosen amount (QR Ph tag 54); the static site QR is the fallback
        let sent = false;
        try { const amt = Number(flow?.deposit ?? 0); if (amt > 0) sent = await fbSendImageBytes(psid, await qrPng(qrphWithAmount(GCASH_QRPH_BASE, amt)), `gcash-${amt}.png`); }
        catch (e) { console.error('qr_amount_failed', String(e).slice(0, 200)); }
        if (!sent) await fbSendImage(psid, flowImage);
      }
    }
    else { await fbSend(psid, ACK_SUGGEST); await tgOps(withHeader('guest', `draft · ${risk}`, `💬 Concierge draft (${risk})\nGuest: ${thread.guest_name ?? psid}\n> ${text.slice(0, 300)}\n\nSuggested reply:\n${reply}\n\n${link}`)); }
    if (handoff) {
      // A discount or pet request goes to the host, but it must not mute the bot for 24 h: a
      // prospect who then asks about Wi-Fi still gets an answer (live guest, 2026-09-13). The hold
      // stays for existing-booking matters (payment, refund, cancellation, complaint, safety, access).
      // 2026-09-13 (Lloyd): no automatic hold on a handoff. The bot keeps answering the guest's
      // other questions, remembers what is pending with the host (see pendingBlock), and pauses
      // only when a human actually replies from the inbox (echo) - or on a safety report.
      if (risk === 'safety') thread.human_until = new Date(now.getTime() + HUMAN_HOLD_MS).toISOString();
      if (mode === 'auto') {
        if (text) await openHandoff(db, thread, text, risk, link);
        else await tgOps(withHeader('guest', `handoff · ${risk}`, `🛎 Concierge handoff (${risk})\nGuest: ${thread.guest_name ?? psid}\n> [attachment]\n\n${link}`));
      }
    } else if (flagOnly && mode === 'auto') {
      await tgOps(withHeader('guest', 'glance', `👀 ${calendarDown ? 'The calendar could not be read: the guest was told we will confirm the dates. Please check and reply.' : 'Concierge answered but wants a host to glance'}\nGuest: ${thread.guest_name ?? psid}\n> ${text.slice(0, 300)}\n\nBot replied:\n${reply.slice(0, 500)}\n\n${link}`));
    }
  }

  const turns: Turn[] = [{ role: 'guest', text: text || '[attachment]', at: now.toISOString() }];
  if (sentToGuest) turns.push({ role: 'bot', text: reply, at: now.toISOString() });
  await db.from('concierge_threads').upsert({
    psid, guest_name: thread.guest_name, human_until: thread.human_until,
    bot_turns: priorTurns + (sentToGuest && !handoff && !flowReply ? 1 : 0),
    history: [...thread.history, ...turns].slice(-HISTORY_KEEP * 2), last_risk: risk, updated_at: now.toISOString(),
    booking_flow: thread.booking_flow ?? null,
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
  const { data: settings } = await db.from('app_settings').select('key, value').in('key', ['concierge_mode', 'gemini_cooldown_until']);
  const setting = (settings ?? []).find((s: any) => s.key === 'concierge_mode');
  const mode = typeof setting?.value === 'string' ? setting.value : 'off';
  // Gemini circuit breaker state lives in app_settings so it survives cold isolates (D-103).
  const cooldown = (settings ?? []).find((s: any) => s.key === 'gemini_cooldown_until');
  geminiBreaker.until = typeof cooldown?.value === 'string' ? (Date.parse(cooldown.value) || 0) : 0;
  geminiBreaker.trip = async (until) => { await db.from('app_settings').upsert({ key: 'gemini_cooldown_until', value: new Date(until).toISOString() }); };

  let payload: { entry?: Array<{ messaging?: Array<Record<string, any>> }> };
  try { payload = JSON.parse(body); } catch { return new Response('ok', { status: 200 }); }

  for (const ev of payload.entry?.flatMap((e) => e.messaging ?? []) ?? []) {
    try { await handle(db, ev, mode); } catch (e) { console.error('concierge_event_failed', String(e).slice(0, 200)); }
  }
  return new Response('EVENT_RECEIVED', { status: 200 });
});
