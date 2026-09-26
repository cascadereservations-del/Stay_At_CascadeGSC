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
import { draftFailureNote, gate, modeFrom, needsDatesFirst, trimRepeatedInvite, type RiskCode } from './policy.ts';
import { needsCalendarCheck } from './booking.ts';
// Messenger book intent (booking PRD §A, session 27): code-driven slot filling, no model in the loop.
import { BOT_REPLY, CANCEL_RE, CASSY_INTRO, PAY_HOW_RE, payHowReply, answer, availabilityAck, availabilityLine, bookingStart, dmRange, greeting, greetBlock, guestLang, holdCancelReply, holdNote, lastMinute, lastRef, otherQuestions, isActive, opener, openWindows, paidClaimReply, parseDates, paymentPromise, paymentReply, pick as reg, prompt, quoteTotal, rateLine, replyLang, start, strayReceiptReply, trimWindow, type Flow, type Window } from './booking.ts';
import { addChatRoute, AMENITY_RE, dropBankUnlessAsked, payHoldReply, answerOnly, appendLook, beforeClose, breakAfterIntro, capName, claimsOpen, decisionInvite, dropNameAsk, dropPaxAsk, dropSiteInvite, dropSoloLink, ensureGreeting, firstInvite, fitFourParagraphs, fixEarlyFee, gladNotHappy, isCold, parseDraftJson, offersEarlyCheckin, setTurnoverCheckin, turnoverCheckinLine, lintReply, offRegister, setAvailability, thinPo, lookNudge, tidyReply, TRUST_RE, withIntro } from './voice.ts';
import { GCASH_QRPH_BASE, qrphWithAmount, qrPng } from '../_shared/cascade-core/qrph.ts';
import { fbSendImage, fbSendImageBytes } from '../_shared/cascade-core/messenger.ts';
import { AIRBNB_URL, MAYA_FACT, SITE_URL, discountRange, factsFor, voiceCompact, voiceFor } from '../_shared/cascade-core/facts.ts';
import { currentCard, livePromos, loadCard, tierRate } from '../_shared/cascade-core/pricing.ts';
import { chatJson, geminiBreaker, setProviderKey } from '../_shared/cascade-core/providers.ts';
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
  cancellation:     "Thank you for letting us know about the change in your plans. Our host has already been notified and will personally assist you with your booking.\n\nWe'll keep the next steps as smooth as possible for you.",
  complaint:        "Thank you for letting us know right away. Our host has already been alerted, and our service partners have been notified so they can attend to this as soon as possible.\n\nYour comfort matters to us, and we'll make sure this is followed through promptly.",
  safety:           "Your safety comes first. Our host has been alerted immediately. If anyone is in danger, please call 911 right away.",
  access:           "For your security, access details are shared personally by our host. We've alerted them and they'll message you directly.",
  policy_exception: "That's a request our host would love to consider personally. We've passed it along, and you can expect a reply soon.",
  uncertain:        "Let us bring in our host for this one so you receive a complete answer. They'll be with you shortly.",
};
// Sticker, photo or reaction with no text: a prospect, so answer with the link rather than a handoff line.
const ATTACHMENT_REPLY = "Thank you for your message. If you have dates in mind, share them here and we'll check the calendar for you, or you may see the home, live availability and our direct rates on our site:\n\n👉 " + SITE_URL;
// Early/late check-in-out before dates are known (see needsDatesFirst in policy.ts).
const LOCAL_RE = /\b(po|pwede|kailan|maaga|naa|moy|kami|namin|ba|ninyo|nyo)\b/i;
// Voice close-out (protocol 10): no greeting on a follow-up, two "po" at most, both routes, never a bare link.
function datesFirstReply(name: string | null, text: string, followUp: boolean): string {
  const local = LOCAL_RE.test(text);
  const open = followUp ? (name ? `${name}, ` : '') : `${name ? `Hi ${name}.` : 'Hello.'} `;
  const cap = (s: string) => (open.endsWith(', ') ? s[0].toLowerCase() + s.slice(1) : s);
  if (local) return `${open}${cap('Salamat')} po sa pagtanong. We'd be glad to arrange that for you: depende ito sa calendar ng araw na iyon, and kapag walang ibang guest na dumarating o umaalis that day, madali pong ma-arrange.

Share lang dito ang dates ninyo and we'll check right away, o puwede ninyong i-check ang live availability sa aming site:

👉 ${SITE_URL}`;
  return `${open}${cap('We')}'d be glad to arrange that for you. It depends on the calendar for that day: when no other guest arrives or leaves the same day, it's easy to arrange.

If you share your dates here, we'll check right away and arrange it in this chat, or you may see live availability on our site:

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
// Voice close-out (protocol 10): three registers, no exclamation words, one or two "po", and the open door offers both
// routes. `lang` is the SETTLED register of the turn (Bislish only after two Bisaya turns, D-172).
type L3 = 'en' | 'tl' | 'bis';
const l3Of = (lang: string): L3 => (lang === 'bisaya' ? 'bis' : lang === 'taglish' ? 'tl' : 'en');
function closingReply(name: string | null, lang: string, thanks: boolean, lastBotText: string): string {
  const n = name ? `, ${name}` : '';
  const l = l3Of(lang);
  const fresh = (xs: string[]) => { const ys = xs.filter((x) => !lastBotText.includes(x.replace(/^[^.]*\.\s*/, '').slice(0, 40))); return ys.length ? ys : xs; };
  let reply = pick(fresh(({
    en: thanks
      ? [`It's our pleasure${n}. We're here whenever you need us.`, `You're most welcome${n}. Message us anytime and we'll take care of it.`, `Our pleasure${n}. If anything else comes to mind, we're one message away.`]
      : [`Thank you${n}. We're here whenever you need us.`, `Noted with thanks${n}. Take care, and message us anytime.`, `Thank you${n}. We'll be right here whenever you're ready.`],
    tl: thanks
      ? [`It's our pleasure po${n}. Nandito lang kami anytime.`, `Walang anuman po${n}. Message lang anytime and we'll take care of it.`, `Salamat din po${n}. Kung may maisip pa kayo, one message away lang kami.`]
      : [`Salamat po${n}. Nandito lang kami kapag kailangan ninyo.`, `Sige po${n}, ingat kayo. Message lang anytime.`, `Noted po${n}. Nandito lang kami kapag ready na kayo.`],
    bis: thanks
      ? [`Walay sapayan${n}. Naa ra mi diri anytime.`, `Salamat pud${n}. Message lang if naa moy need and we'll take care of it.`]
      : [`Salamat${n}. Naa ra mi diri kung naa moy need.`, `Noted${n}. Amping, ug message lang anytime.`],
  })[l]));
  if (!lastBotText.includes(SITE_URL)) reply += '\n\n' + ({
    en: `Whenever you're ready, we can arrange the booking right here in the chat, or you may secure your dates on our site:`,
    tl: `Kapag ready po kayo, we can arrange the booking dito sa chat, o puwede ninyong i-secure ang dates sa aming site:`,
    bis: `Kung ready na mo, we can arrange the booking diri sa chat, or pwede pud i-secure ang dates sa among site:`,
  })[l] + `\n\n👉 ${SITE_URL}`;
  return reply;
}
// D-173 / SPEC-01: Lloyd's approved wording, three registers ("automated" failed our own lint;
// there was no Bisaya line). The strings live in booking.ts so voice.test.ts can lint them.
function botReply(name: string | null, lang: string): string {
  const n = name ? `${name}, ` : '';
  return n + BOT_REPLY[l3Of(lang)];
}
// Lloyd 2026-09-13: anchor the saving, not the percentage. When the guest names a stay length,
// the standard total, the discounted total and the added value are computed here so the
// numbers are never invented ("5 nights: PHP 8,900 becomes about PHP 8,010, with drinking water").
const peso = (n: number) => 'PHP ' + n.toLocaleString('en-US');
function stayAnchor(text: string, lang = 'english'): string {
  const m = /\b(\d{1,2})\s*(?:nights?|gabi|days?|araw)\b/i.exec(text);
  if (!m) return '';
  const n = Number(m[1]);
  // SPEC-34: the live card's tier for n nights and its base (the standard every saving is measured from).
  const card = currentCard(), std = card.base, tier = { rate: tierRate(card, n) };
  if (n < 2 || n > 60 || tier.rate >= std) return '';
  const extras = n >= 5 ? ', plus drinking water for the stay and a complimentary mid-stay refresh with fresh linens and towels' : ''; // D-249: the refresh starts at 5 nights, as the site says
  // Order and wording follow pricing research: anchor on the standard rate, adjust to the precise
  // direct rate (precise figures read as calculated and lower), then the per-stay total, then the
  // saving in pesos (rule of 100: absolute over percent when the base is large), then one value-add.
  // SPEC-28 section 1: the quoted wording was English whatever the guest wrote, so a Taglish rate question got an English
  // answer with one "po". A Taglish turn gets the same three facts, same order, in everyday Taglish.
  const q = lang === 'taglish'
    ? [`para sa ${n} nights po, bumababa ang direct rate namin sa ${peso(tier.rate)} per night mula sa standard ${peso(std)}`, `mga ${peso(n * tier.rate)} para sa buong stay imbes na ${peso(n * std)}`, `kaya makakatipid kayo ng mga ${peso(n * (std - tier.rate))}`, n >= 5 ? 'kasama na rin ang drinking water for the stay at complimentary mid-stay refresh with fresh linens and towels' : '']
    : [`for ${n} nights your direct rate comes down to ${peso(tier.rate)} per night from the standard ${peso(std)}`, `about ${peso(n * tier.rate)} for the stay instead of ${peso(n * std)}`, `so you keep about ${peso(n * (std - tier.rate))}`, extras.slice(2)];
  return `[Stay anchor for ${n} nights - say it in THIS order, in one warm paragraph: (1) "${q[0]}", (2) "${q[1]}", (3) "${q[2]}"${q[3] ? `, (4) "${q[3]}"` : ''}. Do not state the percentage; do not use the word "discount" more than once; then the link, then ask which dates they are looking at.] `;
}
// Dates the guest has already given, so a later early/late check-in question is answered against
// the calendar instead of "once your dates are set" (live audit 2026-09-13, Oct 10-12 given two turns earlier).
// Explicit dates only: "will decide tomorrow" was collected as a stay date (live 2026-09-13).
const DATES_RE = /\b(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.? ?\d{1,2}(?:\s*(?:-|–|to|hanggang)\s*(?:[a-z]+ )?\d{1,2})?|\d{1,2}[\/-]\d{1,2}(?:\s*(?:-|to)\s*\d{1,2}[\/-]\d{1,2})?)\b/gi;
function guestDatesBlock(guestTexts: string[]): string {
  const found = [...new Set(guestTexts.join(' \n ').match(DATES_RE) ?? [])].slice(-3);
  return found.length ? `\n\nGUEST'S DATES SO FAR (from their own messages): ${found.join('; ')}. Treat these as their dates: answer early check-in / late check-out against the CHECKS OUT / CHECKS IN lists for these days, and do not ask for the dates again.` : '';
}
/** K18 (D-182): the stay the guest's own words name, newest message first; a single date is one night. */
function stayFrom(guestTexts: string[], now: Date): { checkin: string; checkout: string } | null {
  const today = dayStr(new Date(now.getTime() + 8 * 3_600_000)); // Manila
  for (const t of [...guestTexts].reverse()) {
    const d = parseDates(t, now);
    if (d[0] && d[0] >= today) return { checkin: d[0], checkout: d[1] && d[1] > d[0] ? d[1] : addDays(d[0], 1) };
  }
  return null;
}

type Turn = { role: 'guest' | 'bot'; text: string; at: string };
type Thread = { psid: string; guest_name: string | null; human_until: string | null; bot_turns: number; history: Turn[]; last_risk: string | null; booking_flow?: Flow | null; last_mid?: string | null };
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
async function fbSend(psid: string, text: string, humanAgent = false): Promise<boolean> {
  const token = env('META_PAGE_TOKEN');
  const post = (payload: unknown) => fetch(`${GRAPH}/${PAGE_ID}/messages?access_token=${token}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload), signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  await post({ recipient: { id: psid }, sender_action: 'typing_on' });
  const envelope = humanAgent ? { messaging_type: 'MESSAGE_TAG', tag: 'HUMAN_AGENT' } : { messaging_type: 'RESPONSE' };
  const r = await post({ recipient: { id: psid }, ...envelope, message: { text } });
  if (r && !r.ok) console.error('fb_send_failed', r.status, (await r.text()).slice(0, 200));
  return !!r?.ok;
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

  // Walk the horizon and collect runs of open nights as check-in -> check-out windows. SPEC-14: the walk itself
  // lives in booking.ts, so the model's block and the code's "nearest open dates" line can never disagree.
  const booked: string[] = [];
  for (let d = today; d < horizonEnd; d = addDays(d, 1)) if (bookedNights.has(d)) booked.push(pretty(d));
  const windows = openWindows(bookedNights, today, horizonEnd).map((w) => w.open_ended
    ? `${pretty(w.start)} onwards (open through at least ${pretty(w.end)})`
    : `${pretty(w.start)} to ${pretty(w.end)} (${w.nights} night${w.nights > 1 ? 's' : ''})`);

  return [
    `TODAY (Manila): ${today}. Dates below are ${new Date(today).getUTCFullYear()} unless stated.`,
    `A stay needs EVERY night from check-in through the night before check-out to be open. The check-out day itself can be a new guest's check-in day.`,
    `OPEN WINDOWS (check-in to check-out): ${windows.join('; ') || 'none in the next ' + HORIZON_DAYS + ' days'}`,
    `BOOKED NIGHTS: ${booked.join(', ') || 'none'}`,
    `If a requested range includes a booked night, say exactly which nights are taken and which are open, then offer the open part or the nearest window. For dates beyond ${pretty(horizonEnd)}, say the host will confirm.`,
    // Turnover safeguard (live test 2026-09-12: a free 1 PM check-out was promised with no dates known).
    `ANOTHER GUEST CHECKS OUT ON: ${[...checkouts].filter((d) => d >= today).sort().map(pretty).join(', ') || 'none'} - on these days check-in stays at 2:00 PM: never offer 12 noon or any early check-in, free or paid; say we will let them know right away if the home is ready earlier.`,
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
// SPEC-34: VOICE and FACTS are refilled from the rate card loaded for this turn (a promotion block when one is live).
const systemPrompt = (thread: Thread, availability: string, landmarks = '', compact = false) => {
  const card = currentCard(), voice = voiceFor(card);
  return `${compact ? voiceCompact(voice) : voice}\n\nGUEST FIRST NAME: ${thread.guest_name ?? 'unknown'}\n\nFACTS\n${factsFor(card)}\n\nLANDMARKS\n${landmarks}\n\nAVAILABILITY\n${availability}`;
};

// Language of the guest's message, decided in code so the instruction can ride on the user turn itself, where small
// models honour it: guestLang() in booking.ts, the one detector (SPEC-28 section 4).
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
const NEGATIVE_RE = /\b(unfortunately|sorry|cannot|can'?t|unable to|(don'?t|do not|doesn'?t|does not) (have|offer|allow|accept|provide)|not (available|allowed|possible|permitted)|no longer|hindi (po )?(pwede|puwede|available)|wala (po )?(kami|kaming)|bawal)\b/i;
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
  // golden run 2026-09-17: a dates ask anywhere in the reply is the next step - never a second one after the warm close
  if (!datesKnown && /\b(preferred dates|dates in mind|share (your|ang|lang)[^.?!\n]{0,20}dates|which dates|petsa)\b/i.test(reply)) return reply;
  // Lloyd's canonical shape (2026-09-13): the site line plus the direct-booking tagline, link solo,
  // withheld only when one of our last two replies already carried the link.
  // Voice close-out: the saving rides inside the one invitation sentence (it used to be a third paragraph after the link,
  // which pushed replies past four paragraphs and read as a second nudge).
  const siteEn = `We can arrange the booking right here in the chat, or you may secure your dates on our site, where direct bookings carry our best rates:\n\n👉 ${SITE_URL}`;
  const siteTl = `We can arrange the booking dito sa chat, o puwede ninyong i-secure ang dates sa aming site, where direct bookings carry our best rates:\n\n👉 ${SITE_URL}`;
  // The model already closed with a dates line: add only the site part (no second "let us know").
  if (/\?\s*$/.test(reply.trim()) || /\b(dates?|petsa|book|reserve|availability|i-?hold)\b/i.test(lastPara)) {
    return linkRecent ? reply : `${reply.trim()}\n\n${isEn ? siteEn : siteTl}`;
  }
  // Soft, warm, friendly - an open door, never a push.
  const en = !datesKnown
    ? `Just let us know your preferred dates, and we'll gladly check our availability for you.${linkRecent ? '' : ' ' + siteEn}`
    : linkRecent ? '' // session 30: the canned "No pressure at all…" / "Whenever it feels right…" lines stacked a second invitation on the model's own warm close
    : `Whenever you feel ready, we can arrange the booking right here in the chat, or you may secure your dates on our site, where direct bookings carry our best rates:\n\n👉 ${SITE_URL}`;
  const tl = !datesKnown
    ? `Sabihin lang po ang preferred dates ninyo at gladly po naming iche-check ang availability para sa inyo.${linkRecent ? '' : ' ' + siteTl}`
    : linkRecent ? ''
    : `Kapag ready po kayo, we can arrange the booking dito sa chat, o puwede ninyong i-secure ang dates sa aming site, where direct bookings carry our best rates:\n\n👉 ${SITE_URL}`;
  // english_po replies are English with one courtesy po, so the nudge stays English too
  // (live v55: an English answer got a Taglish nudge).
  const add = isEn ? en : tl;
  return add ? `${reply.trim()}\n\n${add}` : reply.trim();
}
// Messenger renders markdown literally ("*   Robinsons", "**2:00 PM**" seen live 2026-09-13).
const plainText = (s: string) => s.replace(/^[ \t]*[*•-][ \t]+/gm, '').replace(/\*\*([^*\n]+)\*\*/g, '$1');

function draftFrom(raw: string, who: string): Draft {
  const parsed = parseDraftJson(raw);
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
  const ask = (plain = false) => chatJson({
    system: systemPrompt(thread, availability, landmarks, compact),
    history: thread.history.slice(-HISTORY_KEEP).map((h) => ({ role: h.role === 'bot' ? 'assistant' as const : 'user' as const, text: h.text })),
    question: plain ? `[Reply as plain text only, no JSON, no code fences.] ${question}` : question, title: 'Cascade Concierge', tier, plain,
  });
  return await draftOrPlain(ask, (raw) => draftFrom(raw, 'model'));
}
/** Live 2026-09-25: unreadable JSON handed three guests to the host in a minute - one fresh call before giving up.
 *  SPEC-32 s5 (F12): after the second, one plain-text call wrapped as the reply; a parse failure alone never hands off. */
export async function draftOrPlain(ask: (plain?: boolean) => Promise<string>, parse: (raw: string) => Draft): Promise<Draft> {
  const raw = await ask();
  try { return parse(raw); } catch (e) {
    if (!(e instanceof SyntaxError)) throw e;
    console.warn('draft_json_retry', String(e).slice(0, 120), raw.slice(0, 160));
    const again = await ask();
    try { return parse(again); } catch (e2) {
      if (!(e2 instanceof SyntaxError)) throw e2;
      const text = (await ask(true)).replace(/^```\w*\s*|\s*```$/g, '').trim();
      if (!text) throw e2;
      console.warn('draft_plain_fallback', text.slice(0, 160));
      return { reply: text.slice(0, 1800), uncertain: false };
    }
  }
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
    for (const o of parts.slice(0, 2)) { const lint = lintReply(o, text); if (lint.length) console.warn('voice_lint', JSON.stringify({ source: 'host_option', psid: thread.psid, lint })); } // 2026-09-24
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

async function openHandoff(db: Db, thread: Thread, text: string, risk: RiskCode, link: string, note = '', anyWording = false): Promise<void> {
  const chat = env('TELEGRAM_CHAT_ID'); if (!chat) return;
  // A repeat of the SAME ask within 24 h nudges nobody twice. It used to be one open card per
  // guest per risk with no age limit: two stale policy cards from the day before silently
  // swallowed a dog request and a price proposal (live audit 2026-09-13) - the host never saw them.
  // SPEC-31 s2: after the QR every payment claim is the same ask, whatever its wording - one card per 24 h.
  const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  const { data: dup } = await db.from('concierge_handoffs').select('guest_text').eq('psid', thread.psid).eq('risk', risk).eq('status', 'open').gte('created_at', new Date(Date.now() - HUMAN_HOLD_MS).toISOString()).limit(10);
  if ((dup ?? []).some((d: any) => anyWording || norm(String(d.guest_text)) === norm(text))) return;
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
    ...(note ? [`⚠️ ${note}`] : []), // D-227: why the bot stepped aside, when it is something the host can fix
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
  // SPEC-17 (D-212): the handoff stays open and the card says so when Messenger did not accept the reply.
  // Before this the card showed a tick and the row closed while the guest had received nothing.
  if (!(await fbSend(h.psid, final, true))) {
    if (cbId) await tgCall('answerCallbackQuery', { callback_query_id: cbId, text: 'Messenger refused the send. Nothing was sent.' });
    if (h.tg_message_id) await tgCall('editMessageText', { chat_id: env('TELEGRAM_CHAT_ID'), message_id: h.tg_message_id, text: `\u26a0\ufe0f Messenger refused the reply to ${h.guest_name ?? h.psid}, so nothing was sent and this is still open. Tap again in a minute.\n\nGuest wrote:\n> ${String(h.guest_text).slice(0, 300)}` });
    return;
  }
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
  const body = { guest_name: flow.name ?? thread.guest_name ?? 'Messenger guest', guest_phone: flow.phone, guest_email: flow.email ?? '', checkin_date: flow.checkin, checkout_date: flow.checkout,
    pax: flow.pax, notes: `via Messenger (psid ${psid})`, contact_type: 'phone', hold: true, channel: 'messenger', total_amount: q.total, deposit_amount: flow.pay_full ? q.total : q.deposit, pay_full: flow.pay_full === true };
  const r = await fetch(`${env('SUPABASE_URL')}/functions/v1/submit-booking`, { method: 'POST', headers: { 'Content-Type': 'application/json', apikey: env('SUPABASE_ANON_KEY'), Authorization: `Bearer ${env('SUPABASE_ANON_KEY')}` }, body: JSON.stringify(body), signal: AbortSignal.timeout(30_000) }).catch(() => null);
  const j = r ? await r.json().catch(() => null) : null;
  if (!r || !j) { console.error('submit_flow_failed', r?.status); return { flow, reply: `Sorry po, something went wrong on our side — please try again in a minute, or book here: ${SITE_URL}`, image: null }; }
  if (r.status === 409 || j.error === 'dates_unavailable') return { flow: { ...flow, step: 'dates', updated_at: new Date().toISOString() }, reply: reg(flow.lang, { en: `Sorry — those dates were reserved just moments ago. If other dates suit you, just share your check-in and check-out and we'll gladly check them for you.`, tl: `Sorry po, kaka-reserve lang ng dates na iyon. If may ibang dates kayong gusto, share lang po ang check-in and check-out and iche-check namin agad.`, bis: `Sorry, kaka-reserve lang sa dates nga na. If naa moy other dates, share lang ang check-in and check-out and amo dayon i-check.` }), image: null };
  if (!j.ok) { console.error('submit_flow_rejected', JSON.stringify(j).slice(0, 200)); return { flow, reply: `Sorry po, I couldn't send that request (${String(j.error ?? 'error').replace(/_/g, ' ')}). You can also book here: ${SITE_URL}`, image: null }; }
  const f: Flow = { ...flow, step: 'await_receipt', booking_id: j.inquiry_id, ref: j.ref, deposit: Number(j.deposit_amount), total: Number(j.total_amount), hold: j.hold === true,
    hold_expires_at: j.hold_expires_at ?? null, receipt_token: j.receipt_upload_token, receipt_expires_at: j.receipt_upload_expires_at, updated_at: new Date().toISOString() };
  return { flow: f, reply: paymentReply(f, f.name ?? thread.guest_name, SITE_URL), image: QR_URL };
}
const receiptThanks = (flow: Flow, first: string) => reg(flow.lang, { en: `Thank you, ${first}. We've received your receipt and we'll confirm the reservation as soon as it's reviewed. You'll hear from us here.`, tl: `Salamat po, ${first}. Received na namin ang receipt — iko-confirm namin ang reservation once na-review na. Dito po namin kayo iu-update.`, bis: `Salamat, ${first}. Na-receive na namo ang receipt — amo dayon i-confirm ang reservation once na-review na. Diri ra namo mo i-update.` });
async function forwardReceipt(flow: Flow, url: string, name: string | null): Promise<{ sent: boolean; reply: string }> {
  const first = name ? name.split(' ')[0] : 'po';
  if (!flow.receipt_token || (flow.receipt_expires_at && Date.parse(flow.receipt_expires_at) < Date.now())) return { sent: false, reply: reg(flow.lang, { en: `Thank you. That hold has since expired — just say "book" and we'll set the dates up again.`, tl: `Salamat po. Nag-expire na ang hold na iyon — message lang po "book" and we'll set the dates up again.`, bis: `Salamat. Na-expire na ang hold — message lang "book" and amo i-set up ang dates again.` }) };
  const img = await fetch(url, { signal: AbortSignal.timeout(20_000) }).catch(() => null);
  if (!img || !img.ok) return { sent: false, reply: reg(flow.lang, { en: `Sorry, I couldn't open that image. Could you send it once more?`, tl: `Sorry po, hindi ko ma-open ang image. Puwede po bang i-send ulit?`, bis: `Sorry, wala nako ma-open ang image. Pwede i-send usab?` }) };
  const bytes = new Uint8Array(await img.arrayBuffer());
  const mime = (img.headers.get('content-type') ?? 'image/jpeg').split(';')[0].trim();
  const r = await fetch(`${env('SUPABASE_URL')}/functions/v1/upload-booking-receipt`, { method: 'POST', headers: { Authorization: `Bearer ${flow.receipt_token}`, 'Content-Type': mime, 'X-Receipt-Filename': 'messenger.' + (mime.split('/')[1] || 'jpg'), apikey: env('SUPABASE_ANON_KEY') }, body: bytes, signal: AbortSignal.timeout(30_000) }).catch(() => null);
  const j = r ? await r.json().catch(() => ({})) : {};
  if (r?.ok) return { sent: true, reply: receiptThanks(flow, first) };
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
/** SPEC-14 (D-184): the open window nearest the guest's requested check-in that is long enough for their stay.
 *  null when the calendar cannot be read, or nothing inside the horizon fits - the reserved line then stands alone. */
async function nearestWindow(db: Db, flow: Flow): Promise<Window | null> {
  const today = dayStr(new Date(Date.now() + 8 * 3_600_000)); // Manila
  const horizonEnd = addDays(today, HORIZON_DAYS);
  const { data, error } = await db.from('calendar_events').select('checkin_date, checkout_date').neq('status', 'cancelled').gte('checkout_date', today).lte('checkin_date', horizonEnd).order('checkin_date').limit(200);
  if (error) { console.error('calendar_read_failed', 'nearestWindow', String(error.message ?? error).slice(0, 200)); return null; }
  const booked = new Set<string>();
  for (const r of data ?? []) for (let d = r.checkin_date; d < r.checkout_date; d = addDays(d, 1)) booked.add(d);
  const want = flow.checkin && flow.checkin >= today ? flow.checkin : today;
  const wanted = flow.checkin && flow.checkout ? Math.max(1, Math.round((Date.parse(flow.checkout) - Date.parse(flow.checkin)) / 86_400_000)) : 1;
  const fits = openWindows(booked, today, horizonEnd).filter((w) => w.nights >= wanted);
  if (!fits.length) return null;
  const best = fits.sort((a, b) => Math.abs(Date.parse(a.start) - Date.parse(want)) - Math.abs(Date.parse(b.start) - Date.parse(want)))[0];
  return trimWindow(best, wanted); // offer the stay they asked for, not the whole block up to the next booking
}
// ---- Effects seam and probe (voice close-out 2026-09-17, SPEC-06 sections 1-2) -------------------------------
// Everything handle() does to the outside world goes through `fx`. liveEffects wraps today's functions one to one
// (no behaviour change on the guest path); probeEffects records the calls and sends nothing, so scripted golden
// conversations run through the REAL handle() - real prompt, real model, real calendar - on a fresh probe: thread.
type Effects = {
  send(psid: string, text: string): Promise<void>;
  qr(psid: string, flow: Flow | null, fallbackUrl: string): Promise<void>;
  ops(text: string): Promise<void>;
  handoff(db: Db, thread: Thread, text: string, risk: RiskCode, link: string, note?: string, anyWording?: boolean): Promise<void>;
  submit(flow: Flow, thread: Thread, psid: string): Promise<{ flow: Flow; reply: string; image: string | null }>;
  receipt(flow: Flow, url: string, name: string | null): Promise<{ sent: boolean; reply: string }>;
  name(psid: string): Promise<string | null>;
};
const liveEffects: Effects = {
  send: async (psid, text) => { await fbSend(psid, text); },
  // session 28: the QR carries the chosen amount (QR Ph tag 54); the static site QR is the fallback
  qr: async (psid, flow, fallbackUrl) => {
    let sent = false;
    try { const amt = Number(flow?.deposit ?? 0); if (amt > 0) sent = await fbSendImageBytes(psid, await qrPng(qrphWithAmount(GCASH_QRPH_BASE, amt)), `gcash-${amt}.png`); }
    catch (e) { console.error('qr_amount_failed', String(e).slice(0, 200)); }
    if (!sent) await fbSendImage(psid, fallbackUrl);
  },
  ops: tgOps, handoff: openHandoff, submit: submitFlow, receipt: forwardReceipt, name: fbName,
};
type ProbeCall = { fx: string; text?: string; detail?: unknown };
export function probeEffects(calls: ProbeCall[], guestName: string | null, now = new Date()): Effects {
  return {
    send: (_psid, text) => { calls.push({ fx: 'send', text }); return Promise.resolve(); },
    qr: (_psid, flow) => { calls.push({ fx: 'qr', detail: { amount: flow?.deposit ?? null } }); return Promise.resolve(); },
    ops: (text) => { calls.push({ fx: 'ops', text: text.slice(0, 300) }); return Promise.resolve(); },
    handoff: (_db, _thread, text, risk, _link, note) => { calls.push({ fx: 'handoff', text: text.slice(0, 200), detail: { risk, note: note ?? '' } }); return Promise.resolve(); },
    submit: (flow, thread) => {
      const q = quoteTotal(flow.checkin!, flow.checkout!), deposit = flow.pay_full ? q.total : q.deposit, at = now;
      calls.push({ fx: 'submit', detail: { checkin: flow.checkin, checkout: flow.checkout, pax: flow.pax, total: q.total, deposit } });
      // SPEC-31 s6: mirrors submit-booking - a hold only for the fee 5+ days out; the Messenger upload window is 24 h either way (D-255).
      const hold = !flow.pay_full && !lastMinute(flow.checkin!, at);
      const until = new Date(at.getTime() + 24 * 3_600_000).toISOString();
      const f: Flow = { ...flow, step: 'await_receipt', booking_id: 'probe', ref: 'DIR-PROBE', deposit, total: q.total, hold, hold_expires_at: hold ? until : null, receipt_token: 'probe', receipt_expires_at: until, updated_at: at.toISOString() };
      return Promise.resolve({ flow: f, reply: paymentReply(f, thread.guest_name, SITE_URL, at), image: QR_URL });
    },
    receipt: (flow, _url, name) => { calls.push({ fx: 'receipt' }); return Promise.resolve({ sent: true, reply: receiptThanks(flow, name ? name.split(' ')[0] : 'po') }); },
    name: () => Promise.resolve(guestName),
  };
}

export async function handle(db: Db, ev: Record<string, any>, mode: string, fx: Effects = liveEffects, now = new Date()): Promise<void> {
  const msg = ev.message; if (!msg) return;
  await loadCard(db); // SPEC-34: every quote this turn reads the stored rate card (60 s cache; seed card + log on failure)

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
  // D-222: one retry, then stop. A failed read used to fall through as a brand-new thread, and the upsert at the end
  // would have overwritten the guest's history with this one turn. The caller alerts the host with the link.
  let { data: row, error: rowErr } = await db.from('concierge_threads').select('*').eq('psid', psid).maybeSingle();
  if (rowErr) ({ data: row, error: rowErr } = await db.from('concierge_threads').select('*').eq('psid', psid).maybeSingle());
  if (rowErr) throw new Error('thread_read_failed: ' + String(rowErr.message ?? rowErr).slice(0, 120));
  const thread: Thread = (row as Thread | null) ?? { psid, guest_name: null, human_until: null, bot_turns: 0, history: [], last_risk: null, booking_flow: null, last_mid: null };

  // Meta retries a webhook it considers slow, and this function answers synchronously BEFORE the 200 -
  // one model call can take 25 s, two with a fallback. Without this the guest is answered twice.
  // ponytail: last id only; a small recent-ids array if Meta is ever seen replaying out of order.
  if (msg.mid && msg.mid === thread.last_mid) {
    console.log('duplicate_mid_ignored', JSON.stringify({ psid, mid: msg.mid }));
    return;
  }

  if (!thread.guest_name) thread.guest_name = await fx.name(psid);

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
  // D-173 / SPEC-01: Cassy introduces herself once per thread, never again - not after a 6 h gap,
  // not on a resumed card. History is the record; it is capped at HISTORY_KEEP*2, so a very long
  // thread could re-introduce her once, which is harmless.
  // ponytail: history scan; add concierge_threads.introduced_at only if a repeat is ever seen live.
  const introduced = thread.history.some((h) => h.role === 'bot' && /\bCassy\b/.test(h.text));
  // D-258 (live 2026-09-26 02:14Z): a second booking on a thread the bot answered minutes ago opened with "Hi Ben, thank you
  // for reaching out". A new flow greets only when the bot has not spoken for 12 h.
  const greetNow = !thread.history.some((h) => h.role === 'bot' && now.getTime() - Date.parse(h.at) < 12 * 3_600_000);
  const g = gate(text || 'attachment', { mode, humanUntil: thread.human_until, botTurns: priorTurns, now, hasBooking: !!thread.booking_flow?.ref }); // SPEC-32 s2
  // Lloyd 2026-09-13: a discount ask gets the answer (the direct site applies the best rate
  // automatically; the longer the stay, the higher the discount) AND the host line and card.
  // SPEC-34 (D-262): while a promotion is live, "any promo?" has a factual answer - the promotion - so it is answered
  // with the normal close, not sent to the host as a price request (golden 2026-09-26: the host line pushed every
  // promo answer past 700 characters and dropped the chat route). A discount ask still goes to the host.
  const promoAsk = /\b(promos?|promotions?|sale)\b/i.test(text) && !/\b(discount|discounted|lower price|cheaper|mas mura)\b/i.test(text) && livePromos(currentCard(), now).length > 0;
  const discountAsk = !promoAsk && /\b(discount|discounted|lower price|best price|cheaper|mas mura|promo|may promo)\b/i.test(text);
  let risk: RiskCode = text ? g.risk : 'uncertain';
  let handoff = g.handoff || !text;   // the bot steps aside: handoff line to the guest, 24 h hold
  let flagOnly = false;               // the bot answered but wants a host to glance: alert, no hold
  let draftNote = '';                 // D-227: a spent model budget, named on the host's card
  let reply = '';

  // Book flow: runs before every other branch. A receipt image on a thread that is waiting for one
  // is evidence, not an attachment handoff; a slot answer is code-parsed; a question mid-flow passes
  // through to the model with the flow kept where it is.
  let flow: Flow | null = isActive(thread.booking_flow, now) ? thread.booking_flow! : null;
  let flowReply: string | null = null, flowImage: string | null = null, flowFollowUp: string | null = null;
  let startText: string | null = null;
  const payHold = !!flow && ['await_receipt', 'receipt_sent'].includes(flow.step); // SPEC-31 s4: the QR is out; the model answers questions only
  let calendarDown = false; // session 30: the calendar read failed on this turn - the reply does not claim availability and a host is told
  const attachment = (msg.attachments ?? []).find((a: any) => a?.type === 'image' && a?.payload?.url);
  // SPEC-31 (REVIEW F1-F3): after the QR, code owns the cancel, the "paid na" claim and the stray photo. `booked` is the
  // thread's booking whatever its step, readable 8 days (lastRef); a card's risk and note are applied after flowReply.
  const booked = lastRef(thread.booking_flow, now);
  let card: { risk: RiskCode; note: string; anyWording: boolean } | null = null;
  const uploadOpen = flow?.step === 'await_receipt' && !(flow.receipt_expires_at && Date.parse(flow.receipt_expires_at) < now.getTime());
  const guestSaid = thread.history.filter((h) => h.role === 'guest').slice(-6).map((h) => h.text).join(' ');
  if (g.reply && uploadOpen && attachment) {
    const r = await fx.receipt(flow!, String(attachment.payload.url), thread.guest_name);
    flowReply = r.reply; if (r.sent) flow = { ...flow!, step: 'receipt_sent', updated_at: now.toISOString() };
  } else if (g.reply && attachment && (booked || /\b(gcash|bayad|paid|receipt|deposit|payment|sent)\b/i.test(`${guestSaid} ${text}`))) {
    // s3: a photo with no live upload (hold lapsed, second photo, never booked) is a receipt for the host to match.
    flowReply = strayReceiptReply(booked?.name ?? thread.guest_name, replyLang(text || guestSaid.slice(-200), booked?.lang));
    card = { risk: 'payment', note: booked ? holdNote(booked, now) : 'No booking on this thread; the guest mentioned payment.', anyWording: true };
    if (booked) { const seen: Flow = { ...booked, photo_at: now.toISOString() }; thread.booking_flow = seen; if (flow) flow = seen; } // updated_at untouched: a lapsed flow stays lapsed
  } else if (g.reply && text && flow && ['await_receipt', 'receipt_sent'].includes(flow.step) && CANCEL_RE.test(text) && ['routine', 'cancellation'].includes(g.risk)) {
    // s1: never "we'll cancel it" from the model - the host releases the hold (telegram-expense bk_no) from this card.
    const change = (parseDates(text, now)[0] ?? '') >= dayStr(new Date(now.getTime() + 8 * 3_600_000));
    flowReply = holdCancelReply(flow, flow.name ?? thread.guest_name, replyLang(text, flow.lang), change);
    card = { risk: 'cancellation', note: holdNote(flow, now, change ? 'change requested' : ''), anyWording: false };
    flow = { ...flow, step: 'cancel_requested', updated_at: now.toISOString() };
  } else if (g.reply && text && booked && ['await_receipt', 'receipt_sent', 'cancel_requested', 'receipt_declined'].includes(booked.step) && g.risk === 'payment') {
    // s2: "paid na po?" is answered from what we hold, and the host gets one payment card per 24 h.
    flowReply = paidClaimReply(booked, booked.name ?? thread.guest_name, replyLang(text, booked.lang));
    card = { risk: 'payment', note: holdNote(booked, now), anyWording: true };
  } else if (g.reply && text && PAY_HOW_RE.test(text) && ['routine', 'payment'].includes(g.risk) && !(flow && ['await_receipt', 'receipt_sent'].includes(flow.step))
      && !(booked && ['await_receipt', 'receipt_sent', 'cancel_requested', 'receipt_declined', 'confirmed'].includes(booked.step))) {
    // D-258: "how do I pay?" before the QR is out - the GCash QR and one line, code-owned (the model promised a QR later).
    flowReply = payHowReply(flow, flow?.name ?? thread.guest_name, replyLang(text, flow?.lang), now);
    flowImage = QR_URL;
  } else if (g.reply && text && !g.handoff && flow && !['await_receipt', 'receipt_sent'].includes(flow.step)) {
    const before = flow;
    const s = answer(flow, text, now); flow = s.flow;
    if (s.action === 'passthrough') flowFollowUp = prompt(flow, thread.guest_name, true); // protocol: the model answers, then the flow's ask follows (resumed card: soft nudge)
    if (s.action === 'ask') flowReply = s.reply ?? prompt(flow, thread.guest_name);
    // Protocol rule 1 mid-flow (live 2026-09-17 10:57: "Oct 20 to 22 po, available pa po ba?" got the contact ask with no
    // answer): dates completed on this turn are checked against the calendar before the next ask.
    if (s.action === 'ask' && flow.checkin && flow.checkout && (flow.checkin !== before.checkin || flow.checkout !== before.checkout)) {
      const nights = await bookedNightsFor(db, flow); calendarDown = !nights;
      const line = availabilityLine(flow, nights, nights && nights.size ? await nearestWindow(db, flow) : null);
      if (/already reserved|Reserved na/.test(line)) { flow = { ...flow, step: 'dates', checkin: undefined, checkout: undefined }; flowReply = line; }
      else flowReply = `${availabilityAck(flow, line)}\n\n${s.reply ?? prompt(flow, thread.guest_name)}`;
    }
    else if (s.action === 'cancelled') flowReply = s.reply;
    else if (s.action === 'submit') { const r = await fx.submit(flow, thread, psid); flow = r.flow; flowReply = r.reply; flowImage = r.image; }
  } else if (g.reply && text && !g.handoff && !flow && g.risk === 'routine' && (startText = bookingStart(text,
      thread.history.filter((h) => h.role === 'guest').map((h) => h.text), thread.history.filter((h) => h.role === 'bot').slice(-1)[0]?.text ?? '', now))) {
    flow = start(startText, now); // session 49: a dated "can I book" and a yes to our own chat offer both start here (bookingStart)
    // Protocol rule 1 - answer what was asked before asking anything. Availability is answered from the
    // calendar here (exact, no model); any other question goes to the model with the flow's ask appended.
    // D-222: the calendar is read whenever both dates are known, not only on an "available" word - "book Oct 10 to 12
    // for 2" on a taken night used to be quoted and fail only at submit.
    if (needsCalendarCheck(flow)) {
      const nights = await bookedNightsFor(db, flow); calendarDown = !nights;
      const line = availabilityLine(flow, nights, nights && nights.size ? await nearestWindow(db, flow) : null);
      if (/already reserved|Reserved na/.test(line)) { flow = { ...flow, step: 'dates', checkin: undefined, checkout: undefined }; flowReply = (greetNow ? greetBlock(thread.guest_name, flow.lang, !introduced) : '') + line; } // SPEC-28 section 3
      // SPEC-28 section 2: "is Oct 26 to 28 open? is there wifi?" - the model answers the wifi, then the dates line and the
      // flow's ask follow. The model's reply carries the one greeting (ensureGreeting), so the flow's part has none.
      else if (flow.asked === 'question' || flow.question) flowFollowUp = opener(flow, thread.guest_name, flow.question ? line : '', false, false).trim() + '\n\n' + prompt(flow, thread.guest_name);
      else flowReply = opener(flow, thread.guest_name, line, !introduced, greetNow) + prompt(flow, thread.guest_name);
      // D-173: no Cassy sentence on a resumed card - the disclosure belongs to the greeting, never to a flowFollowUp.
    } else if (flow.asked === 'question') flowFollowUp = opener(flow, thread.guest_name, '', false, false).trim() + '\n\n' + prompt(flow, thread.guest_name);
    else flowReply = opener(flow, thread.guest_name, '', !introduced, greetNow) + prompt(flow, thread.guest_name); // session 28: welcome first
  }
  if (flow) thread.booking_flow = flow;
  if (flowReply) { handoff = false; risk = 'routine'; }
  if (card) { handoff = true; risk = card.risk; draftNote = card.note; } // SPEC-31: the code line goes to the guest AND the host gets the card
  if (calendarDown) flagOnly = true; // OPS gets the glance card: the guest was told we will confirm the dates

  // Lloyd 2026-09-17 14:40: Bislish only when the guest keeps writing Bisaya (this turn and their previous one); a lone
  // Bisaya turn gets Taglish. Settled once per turn, so the code-owned lines follow the same register as the model.
  const prevGuest = thread.history.filter((h) => h.role === 'guest').slice(-1)[0]?.text ?? '';
  const turnLang = guestLang(text) === 'bisaya' && guestLang(prevGuest) !== 'bisaya' && flow?.lang !== 'bis' ? 'taglish' : guestLang(text);

  if (!g.reply) { /* mode off, or a human holds this thread */ }
  else if (flowReply) reply = flowReply;
  else if (handoff) reply = text ? HANDOFF[risk] : ATTACHMENT_REPLY;
  else if (THANKS_RE.test(text) || CLOSER_ONLY_RE.test(text)) reply = closingReply(thread.guest_name, turnLang, THANKS_RE.test(text), thread.history.filter((h) => h.role === 'bot').slice(-2).map((h) => h.text).join('\n'));
  else if (BOT_RE.test(text)) reply = botReply(thread.guest_name, turnLang);
  else if (needsDatesFirst(text, thread.history.filter((h) => h.role === 'guest').map((h) => h.text).join(' '))) reply = datesFirstReply(thread.guest_name, text, followUp);
  else {
    try {
      const stateBlock = followUp
        ? `\n\nCONVERSATION STATE: this is a FOLLOW-UP in a live chat (your last reply was ${Math.round(gapMin)} min ago). Do NOT greet again - no "Hello", "Hi", "Hello po", "Good morning". Address the guest by name early in the first sentence instead ("Ben, yes po...", "Sige po, Sir Ben, ..."), the way a host continues a conversation, then the answer.`
        : `\n\nCONVERSATION STATE: this is the FIRST exchange (or the guest is back after a long gap). Greet once, warmly, by first name if known.`
            + (introduced ? '' : ` Introduce yourself once in that greeting with exactly this sentence: \"${CASSY_INTRO[l3Of(turnLang)]}\"`);
      // First exchange gets the full model (voice, warmth, facts); follow-ups run on the lite tier.
      // Follow-ups: compact prompt (no exemplars) on the full model - cheaper than the old full
      // prompt AND better behaved than lite; the language hint rides on the guest's own turn.
      const lang = turnLang, l3 = l3Of(turnLang);
      const guestTexts = [...thread.history.filter((h) => h.role === 'guest').map((h) => h.text), text];
      const context = (await availabilityBlock(db)) + (await pendingBlock(db, psid)) + guestDatesBlock(guestTexts) + stateBlock;
      // The dates also ride on the guest turn: the system-side block alone was ignored for a
      // Bisaya late check-out question (live 2026-09-13) and the model asked for dates again.
      const datesKnown = [...new Set(guestTexts.join(' \n ').match(DATES_RE) ?? [])].slice(-3);
      const datesHint = datesKnown.length ? `[Guest's dates already given: ${datesKnown.join('; ')} - answer for these days, do not ask for dates.] ` : '';
      // Capacity rides on the guest turn too: "pwede 5 adults?" got "we can accommodate 5 adults" (live 2026-09-13).
      const capHint = /\b([4-9]|1\d)\s*(adults?|pax|persons?|people|guests?|tao|matanda)\b/i.test(text) ? '[Capacity is a hard limit: 3 adults, or 3 adults + 1 child, or 2 adults + 2 children. This group does not fit - say so warmly and suggest a larger place; never say we can accommodate them.] ' : '';
      // SPEC-34 (D-262): a dated stay that touches a promotion gets code's figures (rateLine: promo nights anchored on
      // the standard rate), so the model never does promo arithmetic or denies a live promotion.
      const stay = stayFrom(guestTexts.slice(-3), now), sq = stay ? quoteTotal(stay.checkin, stay.checkout) : null;
      const anchor = stay && sq && sq.q.promo_nights > 0 && sq.nights <= 60
        ? `[Stay figures computed by code for ${dmRange(stay.checkin, stay.checkout)} - say exactly these figures in one warm paragraph, then the link: "${rateLine({ checkin: stay.checkin, checkout: stay.checkout, lang: l3 } as Flow, now)}" Never mention any other "was" or "usual" price.] `
        : stayAnchor(guestTexts.slice(-3).join(' '), lang);
      const discHint = discountAsk ? `[Discount ask: say warmly that booking through our direct site gives the best rate automatically - adjusted to the dates and discounted by length of stay, ${discountRange(currentCard(), 'from')}, the longer the stay the higher the discount${livePromos(currentCard(), now).map((p) => `; also say warmly that our ${p.name} brings the nights of ${dmRange(p.first_night, p.last_night)} to ${peso(p.nightly_rate)} per night instead of the standard ${peso(currentCard().base)}`).join('')} - then the link. Do not quote any other number and do not promise a special price.] ${anchor}`
        : promoAsk ? `[Promo ask: answer in two short paragraphs after the greeting - ${livePromos(currentCard(), now).map((p) => `our ${p.name} brings the nights of ${dmRange(p.first_night, p.last_night)} to ${peso(p.nightly_rate)} per night instead of the standard ${peso(currentCard().base)}`).join('; ')}; outside those nights, booking direct still lowers the nightly rate the longer the stay. Ask which dates they have in mind. Quote no other number and no other "was" price.] ${anchor}`
        : (/\b(rate|price|magkano|how much|pila|tagpila)\b/i.test(text) ? anchor : '');
      const nameHint = !thread.guest_name && !followUp ? '[Guest name unknown: ask for their name once, warmly, inside this reply.] ' : '';
      // Lloyd 2026-09-17 14:30: mid-flow answers read bland and transactional. The model is told where it is and what follows.
      const flowHint = flowFollowUp ? '[The guest is in the middle of booking with us, and their booking summary follows your answer. Reply in two or three warm, unhurried sentences: the answer first, then the one reassurance or offer of help that fits it. No stay details, no amounts, no link, no closing question.] ' : '';
      // SPEC-31 s4 (F4, F7): the hold is open and the QR is out - the booking is arranged; the model answers the question only.
      const payHint = payHold ? `[The guest holds ${dmRange(flow!.checkin!, flow!.checkout!)} under ${flow!.ref} and is paying the ${peso(flow!.deposit ?? 0)} ${(flow!.deposit ?? 0) >= (flow!.total ?? 0) ? 'full amount' : 'reservation fee'} by GCash QR. Answer only what they asked in two or three warm sentences. Payment facts you may state: GCash QR with the amount set; ${MAYA_FACT} A UnionBank transfer only if they ask for a bank (the host sends the account by hand). Never say the booking is confirmed, never promise a reminder or an e-mail, never invite them to the site or to arrange the booking - it is already arranged.] ` : '';
      // SPEC-28: with dates AND another question, the calendar line answers the dates, so the model sees only the other question.
      const asked = flow?.question && flowFollowUp ? otherQuestions(text) || text : text;
      // Session 30 (live): the chat already held "2 guests" from an earlier booking attempt and the model asked again.
      const knownPax = thread.booking_flow?.pax;
      const paxHint = knownPax && !flowFollowUp ? `[Already known from this chat: ${knownPax} guest${knownPax === 1 ? '' : 's'}. Do not ask how many guests again; ask something only if it is truly needed.] ` : '';
      // Golden run 2026-09-25 (R10, 733 and 775 characters): on a first amenity or trust question, code adds the greeting,
      // the introduction and two labelled links - about 350 characters - so the model's own words get the other half.
      const firstLook = !thread.history.some((h) => h.role === 'bot') && !flowFollowUp && (AMENITY_RE.test(text) || TRUST_RE.test(text));
      const lookHint = firstLook ? '[Code adds the greeting, your introduction and the links to the site and reviews. Keep your own words under 300 characters: the answer with one detail that helps, then one short sentence inviting their dates. No links, no greeting, no introduction.] ' : '';
      let out = await draft(thread, nameHint + discHint + capHint + datesHint + paxHint + flowHint + payHint + lookHint + LANG_HINT[lang] + asked, context, 'full', followUp);
      // A name the guest states ("Hi, this is Ben") wins over the Facebook profile name (live
      // 2026-09-13: profile said Löyd, guest said Ben).
      if (out.guest_name && out.guest_name !== thread.guest_name) { console.log('guest_name_from_conversation', out.guest_name, 'was', thread.guest_name); thread.guest_name = out.guest_name; }
      if (NEGATIVE_RE.test(out.reply)) {
        console.error('negative_frame_retry', out.reply.slice(0, 160));
        const fix = `[REWRITE REQUIRED. Your draft opened with a negative ("${out.reply.slice(0, 60).replace(/\n/g, ' ')}..."). The first sentence must name what we DO offer for this wish - e.g. "For swimming po, EM Jake Wave Pool is about 2 km away" instead of "Wala po kaming pool"; "The unit is best suited to 3 adults" instead of "Hindi po pwede ang 4". Do not use "wala", "hindi pwede", "sorry", "unfortunately", "cannot", "not available" anywhere in the reply.] `;
        out = await draft(thread, fix + LANG_HINT[lang] + asked, context, 'full', followUp).catch(() => out);
      }
      // Session 30: a correct but cold answer is a defect (protocol 08 section 6: answer, context, next step, reassurance,
      // warm close). One rewrite, the same way a negative opener gets one; if it fails we keep the first draft.
      // Golden run 2026-09-17: "How much per night?" (English) got the Taglish reference reply pasted whole. The register
      // is decided in code, so it is checked in code: one rewrite, the same pattern as the negative opener.
      if (offRegister(out.reply, l3)) {
        console.warn('off_register_retry', l3, out.reply.slice(0, 160));
        const fix = l3 === 'en' ? `[REWRITE REQUIRED. The guest wrote in English and your draft was in Taglish. Write the whole reply in warm, natural English with contractions${lang === 'english_po' ? ' (one courtesy "po" is welcome)' : ', no "po"'}. Keep every fact. Do not copy a reference reply.] `
          : l3 === 'bis' ? `[REWRITE REQUIRED. The guest writes Bisaya and your draft used Tagalog words. Write it in natural Bislish: no "po", no "kayo", "namin", "dito", "hindi". Keep every fact.] `
          : `[REWRITE REQUIRED. The guest wrote in Tagalog / Taglish and your draft was plain English. Write it in natural Taglish with "po" once or twice, English for the hospitality and money terms. Keep every fact.] `;
        out = await draft(thread, fix + paxHint + datesHint + LANG_HINT[lang] + asked, context, 'full', followUp).catch(() => out);
      }
      if (!flowFollowUp && isCold(out.reply)) {
        console.warn('cold_reply_retry', out.reply.slice(0, 160));
        const warm = `[REWRITE REQUIRED. Your draft was correct but read as blunt and transactional. Keep every fact. Write it the way a calm boutique-hotel concierge would type it in chat: the answer first; then one sentence that shows care or preparation done for the guest ("we'll have it ready", "so you can settle in without a second thought"); then the next step made easy; then one short warm close on its own line. Natural contractions. No sales language, no "no pressure", no exclamation words, no second invitation.] `;
        out = await draft(thread, warm + paxHint + datesHint + LANG_HINT[lang] + asked, context, 'full', followUp).catch(() => out);
      }
      // K18 (D-182): the early check-in fee is computed in code; a contradicting peso figure is corrected (mid-flow too:
      // this runs on the answer before the flow's card is added).
      const feeFixed = fixEarlyFee(out.reply, text);
      if (feeFixed !== out.reply) { console.warn('early_fee_guard', out.reply.slice(0, 160)); out.reply = feeFixed; }
      // SPEC-32 s1b (D-247, F15): UnionBank only when the guest asked for a bank or another way to pay.
      const bankless = dropBankUnlessAsked(out.reply, text);
      if (bankless !== out.reply) { console.warn('bank_unasked_dropped', out.reply.slice(0, 160)); out.reply = bankless; }
      // Lloyd 2026-09-17: a day another guest checks out never gets the 12 noon check-in (golden run 2026-09-25 offered it).
      if (offersEarlyCheckin(out.reply)) {
        const stay = stayFrom(guestTexts, now);
        if (stay) {
          const { data: co, error: coErr } = await db.from('calendar_events').select('checkout_date').neq('status', 'cancelled').eq('checkout_date', stay.checkin).limit(1);
          if (coErr) console.error('calendar_read_failed', 'turnover_guard', String(coErr.message ?? coErr).slice(0, 200));
          if (co?.length) {
            console.warn('turnover_noon_guard', JSON.stringify({ day: stay.checkin, reply: out.reply.slice(0, 160) }));
            out.reply = setTurnoverCheckin(out.reply, turnoverCheckinLine(pretty(stay.checkin), l3));
          }
        }
      }
      // K18 (D-182): outside the book flow, a draft that calls the guest's dates open is checked against the calendar in
      // code, before the post-processing below. A booked night gets ONE rewrite around the flow's approved line (golden
      // run 6: a bare sentence swap left a rate quote and "secure your dates" beside "already reserved"); an unreadable
      // calendar gets the "we're checking" line and the OPS glance card. The code's line wins either way.
      if (!flowFollowUp && claimsOpen(out.reply)) {
        const stay = stayFrom(guestTexts, now);
        if (stay) {
          const f: Flow = { step: 'dates', ...stay, lang: l3, started_at: now.toISOString(), updated_at: now.toISOString() };
          const nights = await bookedNightsFor(db, f);
          if (!nights || nights.size) {
            const line = availabilityLine(f, nights, nights && nights.size ? await nearestWindow(db, f) : null);
            console.warn('availability_guard', JSON.stringify({ stay, down: !nights, reply: out.reply.slice(0, 160) }));
            const swapped = setAvailability(out.reply, line);
            if (nights) {
              const fix = `[REWRITE REQUIRED. The calendar (checked in code) shows these dates are already reserved; your draft said they were open. Put this sentence, word for word, right after any greeting: "${line}" Then answer anything else the guest asked. Then, in its own short paragraph, one sentence of care (for example, that we'd be glad to welcome them on dates that suit). Do not quote a rate or total for these dates and do not invite the guest to secure or book these dates. Keep every other fact.] `;
              const re = await draft(thread, fix + paxHint + LANG_HINT[lang] + asked, context, 'full', followUp).catch(() => null);
              out.reply = re && re.reply.includes(line) && !claimsOpen(re.reply.replace(line, '')) ? re.reply : swapped; // run 8: accept only the full line, never swap it in twice
            } else { out.reply = swapped; flagOnly = true; } // OPS gets the glance card, as on the flow path
          }
        }
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
        const asksToBook = /\b(discount|promo|book|reserve|reservation|link|site|website|magpa-?book|paano (po )?mag|how (do|can) (i|we)|rate|price|how much|magkano|pila|tagpila|avail|dates?|nights?|weekend|think about|decide|consider)\b/i.test(text);
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
      // Voice close-out: never a bare link - the both-routes sentence goes in before the warm close.
      // SPEC-14 (D-184): the model thanked the guest in only 12 of 33 first replies (golden run 9). On first contact
      // the approved greeting is guaranteed in code, the same line the book flow has used since session 28.
      // SPEC-21 (session 43): "thank you for reaching out" is for a guest we have never answered. The
      // 6-hour gap alone re-greeted a nine-message conversation live on 2026-09-22.
      const everAnswered = thread.history.some((h) => h.role === 'bot');
      if (!followUp && !everAnswered) reply = ensureGreeting(reply, thread.guest_name, l3);
      // D-173 / SPEC-01: the prompt rule above is not enough on its own (D-097), so the sentence is
      // guaranteed here - first exchange, not yet introduced, and never under a resumed card.
      // SPEC-21: SPEC-01 says the FIRST reply; that is a thread fact, not a clock fact. Gating it on
      // !followUp meant an active thread never heard it until a 6-hour gap (the ninth reply, live).
      if (!introduced && !flowFollowUp) reply = breakAfterIntro(withIntro(reply, l3));
      reply = gladNotHappy(reply);
      if ((!followUp || discountAsk) && !reply.includes(SITE_URL) && !flowFollowUp && !payHold) reply = beforeClose(reply, firstInvite(l3, SITE_URL));
      if (flowFollowUp) reply = `${answerOnly(reply)}\n\n${flowFollowUp}`; // the answer came first (and only the answer, session 29); now the flow's own ask
      if (discountAsk) { const ps = reply.trim().split(/\n\s*\n/); const last = ps[ps.length - 1] ?? ''; if (ps.length > 2 && last.length < 90 && !last.includes(SITE_URL) && !/:\s*$/.test(last)) reply = ps.slice(0, -1).join('\n\n'); }
      if (discountAsk) { reply += `\n\n${HANDOFF.policy_exception}`; handoff = true; risk = 'policy_exception'; }
      // A decision moment ("will think about it", "how do I book") always leaves the door open
      // with the link (live audit 2026-09-13: the model gave warmth and no link).
      if (followUp && !payHold && /\b(think about|decide|consider|book|reserve|reservation|magpa-?book|paano (po )?mag)\b/i.test(text) && !reply.includes(SITE_URL)) reply = beforeClose(reply, decisionInvite(l3, SITE_URL)); // session 30: never a bare link after the close
      // Repair a dangling "…on our site:" BEFORE the nudge decides (live 2026-09-17 19:12: the nudge saw no link,
      // appended its own line, and only then was the link put back - two invitations).
      if (!flowFollowUp) reply = tidyReply(reply, SITE_URL, lang === 'english' || lang === 'english_po');
      // SPEC-13 / D-176: look before you book. Decided BEFORE the booking nudge, because one message
      // carries one invitation (protocol rule 4): when this block fires, bookingNudge must not.
      // Never on a payment, receipt, refund, cancellation, complaint or safety turn, and never
      // under a handoff or a closer.
      const siteRecent = thread.history.filter((h) => h.role === 'bot').slice(-2).some((h) => h.text.includes(SITE_URL));
      const reviewsShown = thread.history.filter((h) => h.role === 'bot').some((h) => h.text.includes(AIRBNB_URL));
      // Mid-flow the resumed card already shows the site once (D-172), so only a reviews or trust
      // question earns anything, and only the reviews line.
      const look = (handoff || discountAsk || payHold || risk !== 'routine' || THANKS_RE.test(text) || CLOSER_ONLY_RE.test(text) || BOT_RE.test(text)) ? ''
        : flowFollowUp ? (TRUST_RE.test(text) ? lookNudge(text, l3, { site: true, reviews: reviewsShown }) : '')
        : lookNudge(text, l3, { site: siteRecent, reviews: reviewsShown });
      if (!discountAsk && !look && !payHold) reply = bookingNudge(reply, lang, datesKnown.length > 0, siteRecent);
      reply = linkSolo(reply, SITE_URL);
      if (knownPax && !flowFollowUp) reply = dropPaxAsk(reply);
      if (thread.guest_name) reply = dropNameAsk(reply); // golden run 2: the model asked a guest we already know for their name
      if (!flowFollowUp) reply = tidyReply(reply, SITE_URL, lang === 'english' || lang === 'english_po'); // session 30: no dangling "on our site:", one invitation, contractions
      if (!flowFollowUp && !discountAsk && !payHold) reply = addChatRoute(reply, SITE_URL, l3); // Lloyd 2026-09-17: the site AND the chat, guaranteed in code
      if (payHold) { const held = payHoldReply(reply, paidClaimReply(flow!, flow!.name ?? thread.guest_name, l3), SITE_URL); if (held !== reply) console.warn('pay_hold_guard', reply.slice(0, 160)); reply = held; }
      if (l3 === 'tl' && !flowFollowUp) reply = thinPo(reply, 2);
      // Appended last: linkSolo rewrites any line holding SITE_URL into a solo 👉 line, which would
      // destroy the labelled 🏡 line. The guaranteed solo site link goes when the block carries its own.
      if (look) {
        if (look.includes(SITE_URL)) reply = dropSiteInvite(dropSoloLink(reply, SITE_URL)); // golden run 2026-09-24: one site invitation, the block's
        reply = addChatRoute(appendLook(reply, look), SITE_URL, l3); // the invitation keeps both routes when the reply had none (golden fu-ok-salamat-tl)
        if (l3 === 'tl' && !flowFollowUp) reply = thinPo(reply, 2); // the block's own "po" was the third (golden run 2026-09-24, R6)
      } // golden run: the nudge and the chat route each carried a "po" of their own
      if (!flowFollowUp) reply = fitFourParagraphs(reply); // golden 2026-09-25: five paragraphs on a first Taglish rate reply
      reply = capName(reply, thread.guest_name); // golden 2026-09-25 reg-bot-bis: the name three times
      // A model-flagged uncertainty used to silence the bot for 24 h right after it had answered
      // (live test 2026-09-12: a warm reply about a mother's recovery, then silence). Now it only
      // alerts the host; the conversation continues, and the host can still take over by replying.
      if (out.uncertain) { flagOnly = true; risk = 'uncertain'; }
    } catch (e) {
      console.error('draft_failed', String(e).slice(0, 400));
      handoff = true; risk = 'uncertain'; reply = HANDOFF.uncertain; draftNote = draftFailureNote(e);
    }
  }

  const sentToGuest = Boolean(reply) && mode === 'auto';
  if (reply) {
    // Mid-flow (session 28 T6): the guest is already booking here - no site invite after the answer, and the composite
    // (model answer + card) is not lint-scored as one message.
    if (flowFollowUp) reply = reply.split(/\n\s*\n/).filter((p) => !/^(O maaari rin po kayong mag-check|Or you may check and secure|Kapag handa na po kayo, maaari|Kapag ready po kayo|We can arrange (the booking|everything)|Whenever you feel ready|👉 |Mas mababa po ang rate kapag direct|Direct bookings enjoy our best rates)/.test(p.trim())).join('\n\n');
    // Lloyd 2026-09-17 14:30: show the direct site whenever practicable - once, under a resumed confirm card.
    if (flowFollowUp && flow?.step === 'confirm' && !handoff) reply +='\n\n' + ({ en: `If you'd like to see more of the home first, everything is on our site, where direct bookings enjoy our best rates:`, tl: `If you'd like to see more of the home first, nasa site namin po ang lahat, with our best rates for direct bookings:`, bis: `If you'd like to see more of the home first, naa sa among site ang tanan, with our best rates for direct bookings:` })[flow.lang ?? 'en'] + `\n\n👉 ${SITE_URL}`;
    const lint = flowFollowUp ? [] : lintReply(reply, text, { firstTurn: !thread.history.length, name: thread.guest_name });
    if (lint.length) console.warn('voice_lint', JSON.stringify({ psid, lint, reply: reply.slice(0, 160) }));
    if (mode === 'auto') {
      await fx.send(psid, reply);
      if (flowImage) {
        await fx.qr(psid, flow, flowImage);
        // SPEC-10 control 6: the payment promise, as its own message under the QR. It rides with the
        // QR rather than with paymentReply because that reply is already near lintReply's 700-character
        // cap, and because this is the moment the guest is looking at the QR wondering whose account
        // it is. Sent only when a QR was sent, so it cannot leak into an ordinary answer.
        await fx.send(psid, paymentPromise(flow?.lang));
      }
    }
    else { await fx.send(psid, ACK_SUGGEST); await fx.ops(withHeader('guest', `draft · ${risk}`, `💬 Concierge draft (${risk})\nGuest: ${thread.guest_name ?? psid}\n> ${text.slice(0, 300)}\n\nSuggested reply:\n${reply}\n\n${link}`)); }
    if (handoff) {
      // A discount or pet request goes to the host, but it must not mute the bot for 24 h: a
      // prospect who then asks about Wi-Fi still gets an answer (live guest, 2026-09-13). The hold
      // stays for existing-booking matters (payment, refund, cancellation, complaint, safety, access).
      // 2026-09-13 (Lloyd): no automatic hold on a handoff. The bot keeps answering the guest's
      // other questions, remembers what is pending with the host (see pendingBlock), and pauses
      // only when a human actually replies from the inbox (echo) - or on a safety report.
      if (risk === 'safety') thread.human_until = new Date(now.getTime() + HUMAN_HOLD_MS).toISOString();
      if (mode === 'auto') {
        if (text || card) await fx.handoff(db, thread, text || '[photo: likely a payment receipt]', risk, link, draftNote, card?.anyWording);
        else await fx.ops(withHeader('guest', 'handoff · attachment', `🛎 Concierge handoff (attachment)\nGuest: ${thread.guest_name ?? psid}\n> [attachment]\n\n${link}`)); // SPEC-31 s3: a photo, not an uncertainty
      }
    } else if (flagOnly && mode === 'auto') {
      await fx.ops(withHeader('guest', 'glance', `👀 ${calendarDown ? 'The calendar could not be read: the guest was told we will confirm the dates. Please check and reply.' : 'Concierge answered but wants a host to glance'}\nGuest: ${thread.guest_name ?? psid}\n> ${text.slice(0, 300)}\n\nBot replied:\n${reply.slice(0, 500)}\n\n${link}`));
    }
  }

  const turns: Turn[] = [{ role: 'guest', text: text || '[attachment]', at: now.toISOString() }];
  if (sentToGuest) turns.push({ role: 'bot', text: reply, at: now.toISOString() });
  await db.from('concierge_threads').upsert({
    psid, guest_name: thread.guest_name, human_until: thread.human_until,
    bot_turns: priorTurns + (sentToGuest && !handoff && !flowReply ? 1 : 0),
    history: [...thread.history, ...turns].slice(-HISTORY_KEEP * 2), last_risk: risk, updated_at: now.toISOString(),
    booking_flow: thread.booking_flow ?? null,
    last_mid: msg.mid ?? thread.last_mid ?? null,
  });
}

/** Scripted turns through the real handle() on a fresh probe: thread; every outward effect is recorded, none is made.
 *  body: { psid: "probe:<uuid>", name?: string, now?: iso, turns: Array<string | { text?: string, image?: true, advance_minutes?: number }> } */
async function runProbe(body: string): Promise<Response> {
  const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json' } });
  let p: { psid?: string; name?: string; now?: string; golden?: boolean; turns?: Array<string | { text?: string; image?: boolean; advance_minutes?: number }> };
  try { p = JSON.parse(body); } catch { return json({ ok: false, error: 'bad_json' }, 400); }
  const psid = String(p.psid ?? '');
  if (!/^probe:[A-Za-z0-9-]{8,64}$/.test(psid) || !Array.isArray(p.turns) || !p.turns.length || p.turns.length > 12) return json({ ok: false, error: 'probe_psid_and_1_to_12_turns_required' }, 400);
  const db: Db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'));
  dbForLandmarks = db;
  let now = p.now && Date.parse(p.now) ? new Date(p.now) : new Date();
  const out: unknown[] = [];
  // D-254: probes never spend the guests' budget; golden runs have a key of their own (Lloyd 2026-09-26).
  setProviderKey((p.golden ? env('CASCADE_OPENROUTER_GOLDEN_RUN_KEY') : '') || env('CASCADE_OPENROUTER_PROBE_KEY') || null);
  try {
    await db.from('concierge_threads').delete().eq('psid', psid); // a fresh thread, always
    for (const [i, t] of p.turns.entries()) {
      const turn = typeof t === 'string' ? { text: t } : t;
      now = new Date(now.getTime() + (turn.advance_minutes ?? 1) * 60_000);
      const message: Record<string, unknown> = { mid: `probe-${i}`, text: turn.text ?? undefined };
      if (turn.image) message.attachments = [{ type: 'image', payload: { url: 'https://example.invalid/receipt.jpg' } }];
      const calls: ProbeCall[] = [], t0 = Date.now();
      await handle(db, { sender: { id: psid }, recipient: { id: PAGE_ID }, message }, 'auto', probeEffects(calls, p.name ?? null, now), now);
      const { data: row } = await db.from('concierge_threads').select('booking_flow, last_risk, guest_name').eq('psid', psid).maybeSingle();
      const reply = calls.filter((c) => c.fx === 'send').map((c) => c.text).join('\n\n');
      out.push({ guest: turn.text ?? '[image]', reply, step: row?.booking_flow?.step ?? null, flow_lang: row?.booking_flow?.lang ?? null, risk: row?.last_risk ?? null,
        effects: calls.filter((c) => c.fx !== 'send'), lint: lintReply(reply, turn.text ?? '', { firstTurn: i === 0, name: row?.guest_name ?? null }), ms: Date.now() - t0 });
    }
    return json({ ok: true, voice_compact_chars: voiceCompact().length, turns: out });
  } catch (e) {
    return json({ ok: false, error: String(e).slice(0, 300), turns: out }, 500);
  } finally {
    setProviderKey(null);
    await db.from('concierge_threads').delete().eq('psid', psid);
  }
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
  // Probe: header-gated, probe: psids only, sends nothing. A missing or wrong header falls through to the HMAC check,
  // which rejects it, so the probe adds no unauthenticated surface.
  const probeSecret = env('CASCADE_PROBE_SECRET'), probeHeader = req.headers.get('x-cascade-probe');
  if (probeSecret.length >= 24 && probeHeader === probeSecret) return await runProbe(body);
  if (!(await hmacOk(env('META_APP_SECRET'), body, req.headers.get('x-hub-signature-256')))) return new Response('bad signature', { status: 401 });

  const db: Db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'));
  dbForLandmarks = db;
  // D-222: one retry, and a failed read is 'suggest' (holding line + host draft), never a silent 'off' (live 2026-09-13).
  const readSettings = () => db.from('app_settings').select('key, value').in('key', ['concierge_mode', 'gemini_cooldown_until']);
  let { data: settings, error: settingsErr } = await readSettings();
  if (settingsErr || !settings?.length) ({ data: settings, error: settingsErr } = await readSettings());
  if (settingsErr || !settings?.length) console.error('settings_read_failed', String(settingsErr?.message ?? 'no rows').slice(0, 120));
  const mode = modeFrom(settingsErr ? null : settings);
  // Gemini circuit breaker state lives in app_settings so it survives cold isolates (D-103).
  const cooldown = (settings ?? []).find((s: any) => s.key === 'gemini_cooldown_until');
  geminiBreaker.until = typeof cooldown?.value === 'string' ? (Date.parse(cooldown.value) || 0) : 0;
  geminiBreaker.trip = async (until) => { await db.from('app_settings').upsert({ key: 'gemini_cooldown_until', value: new Date(until).toISOString() }); };

  let payload: { entry?: Array<{ messaging?: Array<Record<string, any>> }> };
  try { payload = JSON.parse(body); } catch { return new Response('ok', { status: 200 }); }

  for (const ev of payload.entry?.flatMap((e) => e.messaging ?? []) ?? []) {
    try { await handle(db, ev, mode); } catch (e) {
      console.error('concierge_event_failed', String(e).slice(0, 200));
      // D-222: a failed turn must reach a person - before this, an exception ended in silence for the guest.
      const who = ev?.sender?.id ? `https://www.facebook.com/messages/t/${ev.sender.id}` : '(no sender)';
      await liveEffects.ops(withHeader('guest', 'failed', `⚠️ A Messenger message could not be handled automatically. Please read it and reply by hand.\n\n${who}`)).catch(() => {});
    }
  }
  return new Response('EVENT_RECEIVED', { status: 200 });
});
