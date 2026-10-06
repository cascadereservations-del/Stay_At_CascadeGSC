// Cassy draft_guest_reply (Telegram plan §3, session 27; D-269 2026-09-28). A host pastes a guest message, or sends a chat
// screenshot (the ✍️ Guest reply button), and gets replies to copy. Never sends anything to a guest.
// D-269: for Messenger and pasted text the draft IS the concierge - the deployed messenger-concierge runs the conversation
// through its probe (real calendar, booking flow, persona.ts, voice guards; every send recorded, none made), so a fix to the
// concierge is a fix to the drafts. Airbnb chats keep a separate model draft: Airbnb forbids links, off-platform contact and
// payment, which the Messenger brain offers by design.
import { loadContact } from '../_shared/cascade-core/contact.ts';
import { factsFor, voiceFor, SITE_URL } from '../_shared/cascade-core/facts.ts';
import { loadCard, type RateCard } from '../_shared/cascade-core/pricing.ts'; // SPEC-34: drafts quote the stored rate card
import { classify, type RiskCode } from '../messenger-concierge/policy.ts';
import { isHard, jevRoute, routeRisk } from '../messenger-concierge/jev.ts'; // D-271
import { CASSY_INTRO, detectLang } from '../messenger-concierge/booking.ts';
import { SIGNATURE } from '../messenger-concierge/persona.ts';
import { leafAtClose, lintReply, thinPo, toneRules } from '../messenger-concierge/voice.ts';
import { chatJson } from '../_shared/cascade-core/providers.ts';
import { visionExtractText, parseModelJson, hasVisionKey } from '../_shared/cascade-core/vision.ts';
import { guestContext, guestContextLines } from '../_shared/cascade-core/tools.ts';
import { threadForBooking } from '../_shared/cascade-core/messenger.ts'; // SPEC-38: the Messenger thread a request came from
import { asLang, draftKeyboard, dueWhat, firstName, joinMessage, quotesReason, replyContext, siteNotes, stayShort, type InquiryView, type Lang } from '../_shared/cascade-core/inquiry.ts';
import { hasMoney, maskMoney } from '../_shared/ops-money.ts';

/** "cassy reply: …", "cassy draft …", "cassy, how should I answer: …" -> the guest text (may be empty when a photo carries it). */
export function draftRequest(text: string): { draft: boolean; text: string } {
  const m = /^\s*(?:reply|draft|answer|sagot)\s*(?:to|for)?\s*[:\-–]?\s*([\s\S]*)$/i.exec(text)
    ?? /^\s*(?:how (?:should|do|can|would) (?:i|we) (?:answer|reply|respond)(?: to)?(?: this| this one)?|what (?:should|do) (?:i|we) (?:say|reply|answer))\s*[:\-–?]?\s*([\s\S]*)$/i.exec(text);
  return m ? { draft: true, text: m[1].trim() } : { draft: false, text };
}

export type Platform = 'messenger' | 'airbnb' | 'other';
export type Line = { from: 'guest' | 'host'; text: string };
export type Transcript = { guest_name: string | null; platform: Platform; messages: Line[] };

const TRANSCRIBE_PROMPT = `This is a screenshot of a chat between a guest and Cascade Hideaway (a small Airbnb in General Santos City). Return ONLY JSON: {"guest_name": string|null, "platform": "messenger"|"airbnb"|"other", "messages": [{"from": "guest"|"host", "text": string}]}. messages = every visible message, oldest first, verbatim (Tagalog/Bisaya/English as written); "host" is the Cascade side (right-hand or blue bubbles, the Page, the host or the concierge). platform "airbnb" when the Airbnb app or site is shown. If it is not a chat, return {"guest_name": null, "platform": "other", "messages": []}.`;

export async function transcribeChat(bytes: Uint8Array, mime: string): Promise<Transcript> {
  if (!hasVisionKey()) throw new Error('no vision key');
  const t = parseModelJson<Partial<Transcript>>(await visionExtractText(TRANSCRIBE_PROMPT, bytes, mime, 'Cascade Guest Reader'), {});
  const messages = (Array.isArray(t.messages) ? t.messages : []).filter((m) => m && (m.from === 'guest' || m.from === 'host') && String(m.text ?? '').trim()).map((m) => ({ from: m.from, text: String(m.text).trim() }));
  return { guest_name: t.guest_name ?? null, platform: t.platform === 'airbnb' || t.platform === 'messenger' ? t.platform : 'other', messages };
}

/** The guest's newest messages (everything after the host's last line) and the thread before them. */
export function splitThread(lines: Line[]): { latest: string; before: Line[] } {
  const lastHost = lines.map((l) => l.from).lastIndexOf('host');
  const latest = lines.slice(lastHost + 1).filter((l) => l.from === 'guest').map((l) => l.text).join('\n');
  return { latest, before: lines.slice(0, lastHost + 1) };
}

const FLAG: Partial<Record<RiskCode, string>> = {
  payment: 'a payment claim - check Finance before you confirm anything',
  refund: 'a refund ask - the 5-day rule decides; do not promise money back in chat',
  cancellation: 'a cancellation or date change - check the calendar and the refund rule first',
  complaint: 'a complaint - read the whole thread before sending; consider a call',
  safety: 'a safety report - call the guest now, the draft is secondary',
  access: 'an access issue - verify identity before giving any code',
  policy_exception: 'a policy exception (pets, extra guests, price) - your call, not the draft',
  uncertain: 'an odd request - read it twice',
};

/** A concierge reply the HOST sends from the Page: Cassy's self-introduction is the bot's, not the host's - and so is the
 *  initial-message signature (SPEC-39, D-300.1: "Cassy, Cascade Concierge"). */
export function forHost(reply: string): string {
  let r = reply.replace(new RegExp(`\\s*${SIGNATURE}\\s*$`), '');
  for (const s of Object.values(CASSY_INTRO)) r = r.replace(s.trim(), '').replace(/\n{3,}/g, '\n\n');
  // "we've shared your message with our host" is the bot's line; the host sending the draft IS the host (live test 2026-09-28).
  r = r.replace(/[^.!?\n]*\b(shared your (message|request) with (our host|them)|our host also looks at special requests|na-share na (namin|namo))[^.!?\n]*[.!?][ \t]*/gi, '').replace(/\n{3,}/g, '\n\n');
  return leafAtClose(r.replace(/[ \t]{2,}/g, ' ').replace(/[ \t]+\n/g, '\n').trim());
}

type Brain = { reply: string; step: string | null; risk: string | null; effects: Array<{ fx: string }> };
/** The deployed concierge, through its probe: the thread seeded, the newest guest message answered, nothing sent. */
async function conciergeDraft(before: Line[], latest: string, name: string | null, flow?: Record<string, unknown>): Promise<Brain | null> {
  const secret = Deno.env.get('CASCADE_PROBE_SECRET') ?? '', base = Deno.env.get('SUPABASE_URL') ?? '';
  if (secret.length < 24 || !base) return null;
  const r = await fetch(`${base}/functions/v1/messenger-concierge`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'x-cascade-probe': secret },
    body: JSON.stringify({ psid: `probe:cassy-${crypto.randomUUID()}`, name, history: before.map((l) => ({ role: l.from === 'guest' ? 'guest' : 'bot', text: l.text })), turns: [{ text: latest, advance_minutes: 1 }], ...(flow ? { flow } : {}) }), // SPEC-38 s8: flow = the request's booking flow seed (probe path only)
    signal: AbortSignal.timeout(60_000),
  }).catch(() => null);
  const j = r?.ok ? await r.json().catch(() => null) : null;
  const t = j?.ok ? j.turns?.[0] : null;
  if (!t?.reply || /DIR-PROBE/.test(t.reply)) return null; // a probe booking reference must never reach a host's clipboard
  // The concierge's own fallback when its model call fails (live 2026-09-28: the probe key 401'd) is not a draft.
  if (/^Let us bring in our host/.test(t.reply.trim())) { console.warn('cassy_brain_fallback', JSON.stringify({ risk: t.risk })); return null; }
  return { reply: forHost(t.reply), step: t.step ?? null, risk: t.risk ?? null, effects: t.effects ?? [] };
}

// deno-lint-ignore no-explicit-any
async function rewrite(db: any, text: string, how: string, airbnb = false): Promise<string> {
  const card = await loadCard(db), lang = detectLang(text); await loadContact(db);
  const register = { en: 'refined conversational English, no "po"', tl: 'natural Taglish, at most two "po"', bis: 'natural Bislish (Cebuano with English hospitality terms), never Tagalog words or "po"/"opo"' }[lang];
  const base = `${voiceFor(card)}\n\nFACTS:\n${factsFor(card)}`;
  const system = `${airbnb ? airbnbPrompt(base) : base}\n\nYou are rewriting a reply the HOST is about to send to a guest. It is in ${register}: keep exactly that register. ${how} Keep every fact, figure, date, amount, link and name exactly. Return ONLY JSON {"reply": "<the message>"}.`;
  const raw = await chatJson({ system, history: [], question: `Reply:\n"""${text.slice(0, 1500)}"""`, title: 'Cascade Cassy rewrite', temperature: 0.4, maxTokens: 400, timeoutMs: 30_000 });
  return leafAtClose(thinPo(String(parseModelJson<{ reply?: string }>(raw, {}).reply ?? raw).trim().replace(/\s*\n{3,}/g, '\n\n'), lang === 'bis' ? 0 : lang === 'tl' ? 2 : 1));
}

// ---- SPEC-39 section 6 (BRIEF H, D-296.3): Marifel's Airbnb register. Cassy stays Cassy on Messenger (D-173); on Airbnb the
// host sends the draft as herself, so the draft is written as Marifel and checked in code (airbnbTone) before she reads it. ----

/** The Airbnb voice (PLAYBOOK-airbnb-messaging-2026-10-02 section 1), appended to the draft prompt for an Airbnb guest. */
export const AIRBNB_HOST_REGISTER = `AIRBNB REGISTER - this guest writes on AIRBNB and the reply is sent by MARIFEL, the host, as herself: write as Marifel, a person (never Cassy, never "our host" - she IS the host).
- Open with "Hi {first name}!" - that greeting is the one "!" allowed. At most one 🌿 or 💚 in the whole reply.
- A Filipino guest gets warm Taglish with "po" once or twice; a guest writing English gets plain English with no "po".
- Answer first ("Yes po, ..."), short and warm, two short paragraphs at most.
- End with these two lines exactly, nothing after them: "Marifel & The Cascade Team" then "Hotel Comfort. Home Warmth."
- Never links, phone numbers, e-mail, GCash, QR or any payment outside Airbnb, and never suggest booking elsewhere; for a booking, invite a booking request on the Airbnb listing.
- Never promise a discount, a refund or a late check-out: say you will check and confirm.`;
/** Playbook 5.5: when something went wrong or the guest is worried. */
export const AIRBNB_CALM = `CALM MOMENT: something went wrong or the guest is worried. No "!" anywhere and no emoji - open "Hi {first name}." Answer the question, own it in one sentence, say what is true now, then "Thank you for your understanding." Still end with the two sign-off lines.`;
const SIGN_OFF_RE = /Marifel & The Cascade Team\s*\n\s*Hotel Comfort\. Home Warmth\.\s*$/;
const SIGN_OFF = 'Marifel & The Cascade Team\nHotel Comfort. Home Warmth.';

/** s73 D1 (golden 2026-10-06, discount-ask 0/3): the Airbnb draft was given Messenger's whole VOICE and FACTS - direct rates,
 *  the site link, GCash, the e-mail - and quoted them. Airbnb forbids steering a guest off the platform, so the Airbnb prompt
 *  drops the direct-booking FACTS sections and every other sentence that carries a link, a figure or the direct route. */
const AIRBNB_DROP_SECTION = /^(RATES|PROMOTION|BOOKING & PAYMENT|CONTACT)\b/;
const DIRECT_RE = /https?:\/\/|www\.|👉|\bPHP\b|₱|\bpesos?\b|\d,\d{3}|\d\s?%|\bgcash\b|\bQR\b|\bmaya\b|instapay|unionbank|\bdirect\b|\bsite\b|\blink\b|\be-?mail\b|@|whats ?app|\+63|\b09\d{2}|\bpromo\w*|\breservation fee\b|\bfee\b|\bdeposit\b|\btier\b|\bstandard figure\b|\bfares? we quote\b|\bfull payment\b/iu;
/** A section heading ("REFERENCE REPLIES (...", "BEFORE YOU ANSWER - ...") ends an example. */
const HEADING = /^[A-Z][A-Z &/,()-]{3,}/;
export function airbnbPrompt(prompt: string): string {
  const lines = prompt.split('\n\n').filter((b) => !AIRBNB_DROP_SECTION.test(b.trim())).join('\n\n')
    .replace('replying on Facebook Messenger to prospective guests', 'replying on Airbnb to guests').split('\n');
  // An example (its Q: line up to the next Q: or heading) that would lose ANY sentence goes whole: a half-answer teaches
  // the model the wrong shape.
  const kept: string[] = [];
  let ex: string[] | null = null;
  const flush = () => { if (ex && !ex.some((l) => DIRECT_RE.test(l))) kept.push(...ex); ex = null; };
  for (const l of lines) {
    if (/^Q:/.test(l)) { flush(); ex = [l]; continue; }
    if (ex && HEADING.test(l)) flush();
    (ex ?? kept).push(l);
  }
  flush();
  return kept.flatMap((l) => {
    if (!l.trim()) return [l];
    const k = l.split(/(?<=[.!?])\s+/).filter((s) => !DIRECT_RE.test(s)).join(' ');
    return k.trim() ? [k] : [];
  }).join('\n').replace(/\n{3,}/g, '\n\n');
}
/** The leaks a draft is never shown with: regenerated once, then replaced by airbnbFallback. */
const LEAKS = ['off_platform', 'direct_booking', 'price'];
export const airbnbLeaks = (m: string) => airbnbTone(m, false).filter((v) => LEAKS.includes(v));
const AIRBNB_STRICT = '[AIRBNB RULE - the last draft broke it: no link or URL, no phone, no e-mail, no GCash or QR, no peso, PHP or percentage figure, and never "book directly", "direct rate" or "our site". For a price or discount question, say you will check and confirm here on the listing, with no number. If dates are asked, say you will check and confirm.] ';
/** Code-written, so it can never carry a leak; airbnbFinish signs it. */
export function airbnbFallback(name: string | null, calm: boolean): string {
  return `Hi ${firstName(name) || 'there'}${calm ? '.' : '!'} Thank you for your message. I'll check this for you and confirm here on the listing shortly.`;
}
/** s73 D2-D4, in code rather than hoped for from the model: a Taglish guest's draft carries a courtesy "po" (one or two,
 *  thinPo as everywhere else); a calm draft thanks the guest for their understanding (playbook 5.5); the sign-off is
 *  written exactly once, at the end. */
/** Any sign-off line the model wrote, in any case, dashed or on one line ("- Marifel", "Hotel comfort, home warmth"). */
const SIGN_OFF_LINE = /^[ \t]*[-–—]?[ \t]*(?:Marifel(?:\s*&\s*the Cascade Team)?(?:[ \t,.]*Hotel Comfort[.,]?[ \t]*Home Warmth\.?)?|Hotel Comfort[.,]?[ \t]*Home Warmth\.?)[ \t\p{Extended_Pictographic}️!.]*$/gimu;
/** A valediction the model put above its own sign-off ("Warm regards,"), at the very end of the body only. */
const VALEDICTION_END = /(?:\n+[ \t]*(?:warm(?:est)? regards|kind regards|best regards|regards|best wishes|warmly|cheers|sincerely|with warmth|yours truly)[ \t]*[,.]?[ \t]*)+$/i;
export function airbnbFinish(m: string, lang: Lang, calm: boolean): string {
  let body = m.replace(SIGN_OFF_LINE, '').replace(/\n{3,}/g, '\n\n').trim().replace(VALEDICTION_END, '').trim();
  if (lang === 'en') body = thinPo(body, 0); // a guest writing English gets plain English with no "po"
  if (lang === 'bis') body = thinPo(body, 0);
  if (lang === 'tl') body = /\bpo\b/i.test(body) ? thinPo(body, 2) : courtesyPo(body);
  if (calm && !/\bunderstanding\b/i.test(body)) body += '\n\nThank you for your understanding.';
  return `${punctuate(body, calm)}\n\n${SIGN_OFF}`;
}
// s74: the register's punctuation in code (the golden 15/18 misses were all "!"): calm has none; warm has exactly one, after
// "Hi <name>" (titles "Ma." / "Mr.", honorifics "Ate" / "Sir" and a trailing "po" kept). "!!", "?!" and "!..." collapse to one mark.
const BANG = /[!?]*![!?.]*/g;
const unbang = (s: string) => s.replace(BANG, (x) => (x.includes('?') ? '?' : '.'));
const GREET = /^((?:hi|hello)\s+(?:(?:ate|kuya|sir|ma'?am)\s+)?(?:(?:mr|mrs|ms|dr|ma|sta|sto|st|atty|engr|[a-z])\.\s+)?[^\s,.!?]+(?:\s+po)?)\s*(?:!+|[,.])(?=\s|$)/i;
function punctuate(body: string, calm: boolean): string {
  const g = calm ? null : GREET.exec(body);
  if (!g) return unbang(body);
  return `${g[1]}!` + unbang(body.slice(g[0].length)).replace(/^(\s*(?:\p{Extended_Pictographic}\s*)*)(\p{Ll})/u, (_, s, c) => s + c.toUpperCase());
}
/** "Yes, ..." -> "Yes po, ..."; otherwise "po" closes the first sentence after the greeting ("... shortly po."). */
function courtesyPo(body: string): string {
  const g = /^(?:hi|hello)\b[^\n!.]*[!.]\s*/i.exec(body)?.[0] ?? '', rest = body.slice(g.length);
  const lead = /^(yes|salamat)\b/i.exec(rest); // never "Thank you po so much"
  if (lead) return g + lead[0] + ' po' + rest.slice(lead[0].length);
  // a sentence end, never "Oct. 20", "St. Elizabeth", "Mr. Santos", "2:00 P.M. Salamat" or "e.g."
  const i = rest.search(/(?<!\b(?:[A-Z][a-z]?|Mrs|Brgy|Sta))[.?](?=\s+[A-Z]|\s*$)/);
  return i < 0 ? body : g + rest.slice(0, i) + ' po' + rest.slice(i);
}
/** Generate, finish, and refuse a leak: one stricter regeneration, then the code-written fallback (never the leaking text). */
export async function airbnbGuard(gen: (strict: boolean) => Promise<string>, finish: (m: string) => string, fallback: string): Promise<string> {
  for (const strict of [false, true]) {
    const m = finish(await gen(strict)), leak = airbnbLeaks(m);
    if (!leak.length) return m;
    console.warn('airbnb_leak', JSON.stringify({ strict, leak }));
  }
  return finish(fallback);
}
/** The calm list (Q5 default): a complaint, safety, access, refund, cancellation or payment matter, or our own mistake. */
export function calmMoment(guestText: string, risk: string): boolean {
  return ['complaint', 'safety', 'access', 'refund', 'cancellation', 'payment'].includes(risk)
    || /\b((?:by|our|a|an|the) (?:mistake|error)|in error|went wrong|something wrong|confus\w*|(?:do|did) (?:i|we) (?:have|need) to check ?out|don'?t (?:have|need) to check ?out|not working|stopped working|broken|sira|hindi gumagana|madumi|dirty|disappoint\w*)\b/i.test(guestText);
}
/** The Airbnb register checked in code (as voice.ts toneRules checks Cassy's). [] = clean. */
export function airbnbTone(m: string, calm: boolean): string[] {
  const v: string[] = [], lines = m.trim().split('\n');
  v.push(...lintReply(m).filter((x) => x === 'exclaim' || x === 'boilerplate'));
  if (toneRules(m, 'en', true).includes('urgency')) v.push('urgency');
  // s73 round 2: a bare domain counts as a link - airbnb.com included (the register allows no link at all).
  // s74 (Fable re-check): more rails, banks, socials, contact asks and TLDs - the realistic path is echoing the guest's own words.
  if (/https?:\/\/|www\.|\b[\w-]+\.(?:com|ph|me|net|org|ly|co|app|io|site)\b|\S+@\S+\.\w|(?:(?:\+?63|\b0)\s?|\b)9\d{2}[\s.-]?\d{3}[\s.-]?\d{4}\b|\(0?9\d{2}\)\s?\d{3}[\s.-]?\d{4}|\bg[\s-]?cash\b|\bqr\b|\bpay ?maya\b|(?<!\bhi |\bhello )\bmaya\b|\b(?:bpi|bdo|metrobank|landbank|cebuana)\b|\bpalawan (?:express|pawnshop)\b|\bbank (?:transfer|deposit|account|details)\b|\bwhats ?app\b|\bviber\b|(?<!airbnb )\bmessenger\b|\b(?:facebook|instagram|insta|telegram|fb)\b|\bour page\b(?! on airbnb)|\boutside airbnb\b|\bon google\b|\bgoogle (?:us|it)\b|\bdot com\b|\b(?:e-?mail|text|dm|pm) (?:me|us)\b|\bcall us\b|\b(?:send|drop) us an? e-?mail\b|\bgive us a call\b|\bsearch (?:for )?us\b|(?<!airbnb )\bwebsite\b|\bcascade hideaway (?:site|page)\b/i.test(m) || /\bIG\b/.test(m)) v.push('off_platform');
  if (/\breserv\w*\s+direct(?:ly)?\b(?!\s+(?:through|on|via|in) (?:the )?airbnb)|\b(?:avoid|skip|save on|no) (?:the )?(?:airbnb )?(?:service )?fees?\b|\bcheaper\b(?![^.!?\n]*\bairbnb\b)|\bbook(?:ing)?\s+direct(?:ly)?\b(?!\s+(?:through|on|via|in) (?:the )?airbnb)|\bdirect(?:ly)?\s+(?:rate|booking|price|site)s?\b|\b(?:our|the) (?:booking )?(?:site|website)\b|\b(?:contact|message|text|call|reach|e-?mail|pay|reserve with|book with) (?:me|us) directly\b|\bbetter deal\b|\bdirect(?:ly)?\b[^.!?\n]{0,60}\b(?:text|message|call|whats ?app|viber|e-?mail|dm|pm) (?:me|us)\b|\b(?:pay|send|transfer|settle)\w*\s+(?:\w+\s+){0,2}deposit\b|\bdeposit\s+(?:of\s+)?(?:PHP|₱|P)?\s?\d/i.test(m)) v.push('direct_booking');
  if (/\bPHP\s?\d|₱\s?\d|\bpesos?\b|\d[\d,]*\s?php\b|\b(?!100\b)\d+(?:\.\d+)?\s?%(?!\s?(?:ready|sure|safe|clean|complete)|\s?of (?:our )?(?:guests|reviews))|\b(?:rate|price|drops? to|down to|for)\s+(?:is\s+|of\s+)?(?!20\d\d\b)\d{3,5}\b|\bpercent\b|\b\d{1,2},\d{3}\b|\b\d{3,5}\s*(?:per night|a night|\/night|nightly)|\b\d+(?:\.\d+)?\s?k\b|\b(?!20\d\d\b)\d{4,5}\b|\b\w+teen hundred\b/i.test(m) || /\bP\d/.test(m)) v.push('price');
  if (/\b(discount of|we can (?:offer|give) (?:you )?(?:a )?(?:discount|lower|special)|(?:full|a) refund (?:is|will be)|you(?:'ll| will) be refunded|late check-?out is fine|yes,? you can (?:check out|stay) late)\b/i.test(m)) v.push('promise');
  if (!SIGN_OFF_RE.test(m)) v.push('no_sign_off');
  if ((m.match(/\bpo\b/gi) ?? []).length > 2) v.push('po_over_two');
  if (/\bCassy\b|\bour host\b/i.test(m)) v.push('not_marifel');
  if (calm) { if (m.includes('!')) v.push('exclamation_in_calm'); if (/[\p{Extended_Pictographic}]/u.test(m)) v.push('emoji_in_calm'); }
  else if ((m.match(/!/g) ?? []).length > 1) v.push('exclamation_after_greeting'); // s74: one "!", after the greeting, on any line layout
  return v;
}

/** The draft's system prompt. An Airbnb draft gets airbnbPrompt (no direct-booking facts) plus Marifel's register. */
export function draftSystem(card: RateCard, airbnb: boolean, calm = false): string {
  const base = `${voiceFor(card)}\n\nFACTS:\n${factsFor(card)}`;
  const channel = airbnb ? `${AIRBNB_HOST_REGISTER}${calm ? `\n${AIRBNB_CALM}` : ''}` : 'Do not invent availability or prices beyond FACTS.';
  return `${airbnb ? airbnbPrompt(base) : base}\n\nYou are drafting for the HOST to copy and send; the host will read it first. Write only the reply to the guest, in the guest's language, warm and short. ${channel} If dates are asked, say you will check and confirm. Return ONLY JSON {"reply": "<the message>"}.`;
}

// deno-lint-ignore no-explicit-any
export async function modelDraft(db: any, guestText: string, guestName: string | null, ctx: string[], airbnb: boolean, hint = '', calm = false): Promise<string> {
  const card = await loadCard(db); await loadContact(db);
  const system = draftSystem(card, airbnb, calm);
  const datesAsked = /\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s*\d{1,2}|\d{1,2}[\/-]\d{1,2}|\b(?:available|avail|vacant|bakante|free)\b|\bcheck-?\s?(?:in|out)\b|\b(?:today|tomorrow|tonight|extend|another night)\b/i.test(guestText);
  // s74 (Fable): "I don't have to check out today do I" got "your check-out is today" / an invented "October 27th".
  const datesHint = datesAsked && !hint ? "[The guest mentions dates, availability or their stay. You cannot see the calendar or this guest's reservation: never say dates are available or taken, and never state or confirm which day or date their own stay starts or ends; say you will check the booking and confirm here. The house check-in and check-out times in FACTS may be stated.] " : '';
  const q = `${hint}${datesHint}${guestName ? `Guest name: ${guestName}\n` : ''}${ctx.length ? `What we know about this guest:\n${ctx.join('\n')}\n` : ''}Guest wrote:\n"""${guestText.slice(0, 1500)}"""`;
  const once = async (strict: boolean) => {
    const raw = await chatJson({ system, history: [], question: (strict ? AIRBNB_STRICT : '') + q, title: 'Cascade Cassy draft', temperature: 0.5, maxTokens: 500, timeoutMs: 30_000 });
    return leafAtClose(String(parseModelJson<{ reply?: string }>(raw, {}).reply ?? raw).trim().replace(/\s*\n{3,}/g, '\n\n'));
  };
  if (!airbnb) return once(false);
  return airbnbGuard(once, (m) => airbnbFinish(m, detectLang(guestText), calm), airbnbFallback(guestName, calm));
}

/** s73 R4: the Messenger brain (direct rates, the site link) only for a source that is positively Messenger - a screenshot the
 *  reader labels messenger, or a "messenger:" marker. Pasted text and an unclear screenshot get the Airbnb register, safe on
 *  both platforms. A leading "airbnb:" / "messenger:" marker (or a caption line) is taken off the guest text. */
export function draftPlatform(text: string, label?: Platform): { platform: 'airbnb' | 'messenger'; text: string; guessed: boolean } {
  const mk = /^\s*(airbnb|messenger)\s*(?:[:\-–]\s*|\n\s*|$)/i.exec(text);
  const t = mk ? text.slice(mk[0].length) : text, said = mk ? mk[1].toLowerCase() : label;
  return { platform: said === 'messenger' && !/\bairbnb\b/i.test(t) ? 'messenger' : 'airbnb', text: t, guessed: !mk && label !== 'messenger' && label !== 'airbnb' };
}

/** Messages for the host, in order: a header card, then each option alone so a long-press copies only the reply. */
// deno-lint-ignore no-explicit-any
export async function draftGuestReply(db: any, guestText: string, guestName: string | null, thread: { before?: Line[]; platform?: Platform } = {}): Promise<string[]> {
  const src = draftPlatform(guestText, thread.platform), platform = src.platform;
  guestText = src.text;
  // A bare "messenger" / "airbnb:" marker carries no guest message: ask for it, never draft from nothing.
  if (!guestText.trim()) return ['✍️ Please paste the guest message after the marker, for example "messenger: Hi po, available ba Oct 3?", or send a screenshot of the chat.'];
  // deno-lint-ignore no-explicit-any
  const ctx = guestName ? guestContextLines(await guestContext(db, { name: guestName }).catch(() => ({} as any))) : [];
  const brain = platform === 'airbnb' ? null : await conciergeDraft(thread.before ?? [], guestText, guestName).catch(() => null);
  // SPEC-32 s2: the host drafts for a known guest, so the booked-guest regex is the floor. D-271: the concierge's own routing
  // (Jev-primary) already ran inside the probe - no second Jev call; Airbnb and the fallback route here.
  const base = classify(guestText, { hasBooking: true });
  const risk: RiskCode = isHard(base) ? base : brain?.risk ? brain.risk as RiskCode : routeRisk(base, await jevRoute(guestText, Deno.env.get('CASCADE_OPENROUTER_BOT_KEY')));
  // SPEC-39 section 6: an Airbnb draft is Marifel's register, checked in code; a failing draft is rewritten once with the
  // violation named, and if it still fails the host is told before she reads it (nothing reaches a guest from here).
  const airbnb = platform === 'airbnb', calm = airbnb && calmMoment(guestText, risk);
  // A rewrite of an Airbnb draft is finished like the draft and dropped ('') if it leaks: the clean original stands.
  const airbnbSafe = (m: string) => { const f = m ? airbnbFinish(m, detectLang(guestText), calm) : ''; return f && !airbnbLeaks(f).length ? f : ''; };
  let main = brain?.reply || await modelDraft(db, guestText, guestName, ctx, airbnb, '', calm);
  let airbnbFail = airbnb ? airbnbTone(main, calm) : [];
  if (airbnbFail.length) {
    const fixed = airbnbSafe(await rewrite(db, main, `Fix only these: ${airbnbFail.join(', ')}. ${AIRBNB_HOST_REGISTER}${calm ? `\n${AIRBNB_CALM}` : ''}`, true).catch(() => ''));
    if (fixed) { main = fixed; airbnbFail = airbnbTone(fixed, calm); }
    if (airbnbFail.length) console.warn('airbnb_tone', JSON.stringify({ calm, fail: airbnbFail }));
  }
  const lint = lintReply(main, guestText); if (lint.length) console.warn('voice_lint', JSON.stringify({ source: 'cassy_draft', brain: !!brain, lint }));
  let short = main.length > 320 ? await rewrite(db, main, `Make it noticeably shorter - two short paragraphs at most - by dropping pleasantries, never facts.${airbnb ? ' Keep the greeting line and the two sign-off lines exactly.' : ''}`, airbnb).catch(() => '') : '';
  if (airbnb) short = airbnbSafe(short);
  const head = [`✍️ Guest reply${guestName ? ` · ${guestName}` : ''} · ${platform === 'airbnb' ? 'Airbnb' : 'Messenger'}${risk !== 'routine' ? ` · ${risk.replace('_', ' ')}` : ''}`,
    brain ? '1️⃣ is what the concierge would send (calendar and rate card checked).' : `1️⃣ is a drafted reply${platform === 'airbnb' ? ' (Airbnb: no links or outside payment)' : ' (the concierge could not be reached, so dates are not checked)'}.`,
    ...(short ? ['2️⃣ says the same, shorter.'] : [])];
  if (src.guessed) head.push('ℹ️ Source unclear, so this is the Airbnb-safe draft. For a Messenger chat: "cassy reply messenger: …" or a screenshot.');
  if (FLAG[risk]) head.push(`⚠️ This reads as ${FLAG[risk]}.`);
  if (airbnbFail.length) head.push(`⚠️ Airbnb voice check: ${airbnbFail.join(', ')}. Read it before sending.`);
  if (brain?.effects.some((e) => e.fx === 'qr' || e.fx === 'image')) head.push('📎 The concierge would attach the GCash QR here: send it with the reply.');
  if (brain?.effects.some((e) => e.fx === 'handoff')) head.push('🛎 The concierge would also flag this to you: it is yours to decide.');
  if (!brain && platform !== 'airbnb' && /\b(available|avail|open|free|vacant|bakante)\b/i.test(main) && !/\b(check|confirm)\b/i.test(main)) head.push('⚠️ The draft claims availability: check the calendar before sending.');
  if (ctx.length) head.push(...ctx);
  head.push(`Nothing was sent. Long-press an option to copy it.${platform === 'airbnb' ? '' : ` Site: ${SITE_URL}`}`);
  return [head.join('\n'), main, ...(short ? [short] : [])];
}

/** Session 28: the ✏️ Revise tap. Rewrites a host message in the Concierge voice; every fact, figure,
 * date and name stays. Returns the card the host reads (never sent to a guest). */
// deno-lint-ignore no-explicit-any
export async function reviseHostMessage(db: any, template: string, context: string): Promise<string> {
  const card = await loadCard(db); await loadContact(db);
  // Session 29 (live): a Bislish template came back as Tagalog with six "po". The register is read from the template
  // itself and enforced in code, as the Concierge does (D-170).
  const lang = detectLang(template);
  const register = { en: 'refined conversational English, no "po"', tl: 'natural Taglish, at most two "po"', bis: 'natural Bislish (Cebuano with English hospitality terms), never Tagalog words or "po"/"opo"' }[lang];
  const system = `${voiceFor(card)}\n\nFACTS:\n${factsFor(card)}\n\nYou are revising a message the HOST is about to send to a guest. The message is in ${register}: reply in exactly that register. Keep every fact, figure, date, amount and name exactly; make it warmer, shorter and more natural, one message, no greeting line if the original has none. Return ONLY JSON {"reply": "<the revised message>"}.`;
  const q = `${context ? `Card context:\n${context.slice(0, 800)}\n\n` : ''}Message to revise:\n\"\"\"${template.slice(0, 1500)}\"\"\"`;
  const raw = await chatJson({ system, history: [], question: q, title: 'Cascade Cassy revise', temperature: 0.5, maxTokens: 400, timeoutMs: 30_000 });
  const reply = thinPo(String(parseModelJson<{ reply?: string }>(raw, {}).reply ?? raw).trim().replace(/\s*\n{3,}/g, '\n\n'), lang === 'bis' ? 0 : lang === 'tl' ? 2 : 1);
  const lint = lintReply(reply); if (lint.length) console.warn('voice_lint', JSON.stringify({ source: 'cassy_revise', lint }));
  return ['✍️ Revised draft', '', reply, '', 'Do: copy and send from the Page or the app. Nothing was sent.', `📨 ${reply}`].join('\n');
}

// ---- SPEC-38 (session 70): Cassy's reply, and the "other" decline, for a request that has not paid yet ----
// Never sends anything. The card it builds is a draft: the tap that sends lives in telegram-expense (iq:send:). Every text passes the
// voice gate (lintReply + toneRules); a text that fails twice shows the failure and no Send button.

export type InquiryDraft = { text: string; gate: string[]; source: 'concierge' | 'model'; lang: Lang; channel: 'Messenger' | 'e-mail' | 'no channel'; lastMessage: string | null; guestText: string };

/** The two gates every guest-facing draft passes. `privateReason` (decline/other) must never be echoed back. */
export function gateInquiry(text: string, guestText: string, lang: Lang, privateReason?: string): string[] {
  const g: string[] = [...lintReply(text, guestText), ...toneRules(text, lang)];
  if (privateReason && quotesReason(text, privateReason)) g.push('quotes_private_reason');
  return g;
}

/** The decline/other instruction: the reason only chooses a gentle wording; it is never to be quoted, revealed or hinted at. */
export function declineInstruction(dates: string, register: string, privateReason: string): string {
  return `Write a short, polite message declining the guest's request for ${dates}, in ${register}, two or three sentences, no exclamation. The host's private reason, ONLY to choose a gentle wording - never quote, reveal or hint at it: """${privateReason.slice(0, 300)}""". Do not promise anything, do not mention money. Return ONLY JSON {"reply": "<the message>"}.`;
}

/** OPS may send only a draft with no money (D-297.2). A draft with an amount is sent from Finance, and OPS is told so. */
export function routeDraft(surface: 'finance' | 'ops', text: string): { ops_ok: boolean; toFinance: boolean } {
  const money = hasMoney(text);
  return { ops_ok: surface === 'finance' || !money, toFinance: surface === 'ops' && money };
}

/** The draft card. A failed gate removes Send: the card says which rules failed and offers Draft again.
 *  D-306: `forOps` (the card is posted in OPS) masks the whole text, the guest's own words included; the stored payload stays whole. */
export function inquiryDraftCard(o: { view: InquiryView; purpose: 'reply' | 'decline'; pid: string; forOps?: boolean; d: Pick<InquiryDraft, 'text' | 'gate' | 'source' | 'channel' | 'lastMessage'> }): { text: string; keyboard: { text: string; callback_data?: string }[][] } {
  const first = firstName(o.view.guest_name) || 'the guest', ok = o.d.gate.length === 0;
  const head = o.purpose === 'decline'
    ? `❌ Decline ${first}'s request with this message?`
    : `✍️ Reply for ${first} · ${o.d.channel}${o.d.source === 'concierge' ? ' · calendar and rate card checked' : ''}`;
  const lines = [head, ...(o.purpose === 'reply' && o.d.lastMessage ? [`Guest wrote: "${o.d.lastMessage}"`] : []), '📨 ⤵', o.d.text,
    ...(ok ? [] : [`⚠️ Voice check: ${o.d.gate.join(', ')}. Send is off; tap 🔄 Draft again.`])];
  return { text: o.forOps ? maskMoney(lines.join('\n')) : lines.join('\n'), keyboard: draftKeyboard({ purpose: o.purpose, pid: o.pid, bookingId: o.view.id, first: firstName(o.view.guest_name), sendOk: ok }) };
}

const REGISTER: Record<Lang, string> = { en: 'refined conversational English, no "po"', tl: 'natural Taglish, at most two "po"', bis: 'natural Bislish (Cebuano with English hospitality terms), never Tagalog words or "po"/"opo"' };

/** Draft the reply (the concierge through its probe, or the model with a request hint) or the "other" decline for one request. */
// deno-lint-ignore no-explicit-any
export async function draftInquiry(db: any, view: InquiryView, purpose: 'reply' | 'decline', privateReason?: string): Promise<InquiryDraft> {
  const t = await threadForBooking(db, view.id).catch(() => null);
  const ctx = replyContext(t?.history, view.submitted_at);
  const lastMessage = t ? joinMessage(ctx.latest) : siteNotes(view.notes);
  const guestText = (t ? ctx.latest.join('\n') : '') || siteNotes(view.notes) || '';
  const lang: Lang = asLang(t?.booking_flow?.lang ?? detectLang(guestText || 'hello'));
  const channel: InquiryDraft['channel'] = t ? 'Messenger' : view.guest_email ? 'e-mail' : 'no channel';
  let text = '', source: InquiryDraft['source'] = 'model';

  if (purpose === 'reply') {
    if (!guestText.trim()) throw new Error('nothing to answer yet');
    const seed = {
      step: view.has_receipt ? 'receipt_sent' : 'await_receipt', checkin: view.checkin_date, checkout: view.checkout_date, pax: view.pax ?? undefined, name: view.guest_name, lang, ref: view.ref,
      deposit: view.deposit_amount ?? undefined, total: view.total_amount ?? undefined, pay_full: view.total_amount !== null && view.deposit_amount === view.total_amount,
      hold: view.hold_expires_at !== null, hold_expires_at: view.hold_expires_at ?? undefined,
    };
    const brain = t && ctx.latest.length
      ? await conciergeDraft(ctx.before.map((h) => ({ from: h.role === 'guest' ? 'guest' as const : 'host' as const, text: String(h.text ?? '') })), guestText, view.guest_name, seed).catch(() => null)
      : null;
    if (brain?.reply) { text = brain.reply; source = 'concierge'; }
    else {
      const due = dueWhat(view);
      const hint = `[The guest submitted request ${view.ref} for ${stayShort(view)}${view.pax ? `, ${view.pax} guests` : ''}, and has not paid yet. ${due === 'payment' ? '' : `The amount due, stored when they asked, is ${due}. `}Answer only what they wrote in two or three warm sentences. Never say the booking is confirmed, never quote a figure that is not in this hint, never invite them to book again.] `;
      text = await modelDraft(db, guestText, view.guest_name, [], false, hint);
    }
  } else {
    const card = await loadCard(db); await loadContact(db);
    const system = `${voiceFor(card)}\n\nFACTS:\n${factsFor(card)}\n\nYou are drafting for the HOST to send; the host will read it first. Write only the message to the guest.`;
    const raw = await chatJson({ system, history: [], question: declineInstruction(stayShort(view), REGISTER[lang], String(privateReason ?? '')), title: 'Cascade Cassy inquiry decline', temperature: 0.4, maxTokens: 300, timeoutMs: 30_000 });
    text = leafAtClose(thinPo(String(parseModelJson<{ reply?: string }>(raw, {}).reply ?? raw).trim().replace(/\s*\n{3,}/g, '\n\n'), lang === 'bis' ? 0 : lang === 'tl' ? 2 : 1));
  }

  let gate = gateInquiry(text, guestText, lang, privateReason);
  if (gate.length) {
    const fixed = await rewrite(db, text, 'Fix only these: ' + gate.join(', ') + '.').catch(() => '');
    if (fixed) { text = fixed; gate = gateInquiry(fixed, guestText, lang, privateReason); }
  }
  if (gate.length) console.warn('voice_lint', JSON.stringify({ source: 'cassy_inquiry', purpose, brain: source === 'concierge', gate }));
  return { text, gate, source, lang, channel, lastMessage, guestText };
}
