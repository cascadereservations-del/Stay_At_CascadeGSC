// Cassy draft_guest_reply (Telegram plan §3, session 27; D-269 2026-09-28). A host pastes a guest message, or sends a chat
// screenshot (the ✍️ Guest reply button), and gets replies to copy. Never sends anything to a guest.
// D-269: for Messenger and pasted text the draft IS the concierge - the deployed messenger-concierge runs the conversation
// through its probe (real calendar, booking flow, persona.ts, voice guards; every send recorded, none made), so a fix to the
// concierge is a fix to the drafts. Airbnb chats keep a separate model draft: Airbnb forbids links, off-platform contact and
// payment, which the Messenger brain offers by design.
import { loadContact } from '../_shared/cascade-core/contact.ts';
import { factsFor, voiceFor, SITE_URL } from '../_shared/cascade-core/facts.ts';
import { loadCard } from '../_shared/cascade-core/pricing.ts'; // SPEC-34: drafts quote the stored rate card
import { classify, type RiskCode } from '../messenger-concierge/policy.ts';
import { isHard, jevRoute, routeRisk } from '../messenger-concierge/jev.ts'; // D-271
import { CASSY_INTRO, detectLang } from '../messenger-concierge/booking.ts';
import { leafAtClose, lintReply, thinPo, toneRules } from '../messenger-concierge/voice.ts';
import { chatJson } from '../_shared/cascade-core/providers.ts';
import { visionExtractText, parseModelJson, hasVisionKey } from '../_shared/cascade-core/vision.ts';
import { guestContext, guestContextLines } from '../_shared/cascade-core/tools.ts';
import { threadForBooking } from '../_shared/cascade-core/messenger.ts'; // SPEC-38: the Messenger thread a request came from
import { asLang, draftKeyboard, dueWhat, firstName, joinMessage, quotesReason, replyContext, siteNotes, stayShort, type InquiryView, type Lang } from '../_shared/cascade-core/inquiry.ts';
import { hasMoney } from '../_shared/ops-money.ts';

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

/** A concierge reply the HOST sends from the Page: Cassy's self-introduction is the bot's, not the host's. */
export function forHost(reply: string): string {
  let r = reply;
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
async function rewrite(db: any, text: string, how: string): Promise<string> {
  const card = await loadCard(db), lang = detectLang(text); await loadContact(db);
  const register = { en: 'refined conversational English, no "po"', tl: 'natural Taglish, at most two "po"', bis: 'natural Bislish (Cebuano with English hospitality terms), never Tagalog words or "po"/"opo"' }[lang];
  const system = `${voiceFor(card)}\n\nFACTS:\n${factsFor(card)}\n\nYou are rewriting a reply the HOST is about to send to a guest. It is in ${register}: keep exactly that register. ${how} Keep every fact, figure, date, amount, link and name exactly. Return ONLY JSON {"reply": "<the message>"}.`;
  const raw = await chatJson({ system, history: [], question: `Reply:\n"""${text.slice(0, 1500)}"""`, title: 'Cascade Cassy rewrite', temperature: 0.4, maxTokens: 400, timeoutMs: 30_000 });
  return leafAtClose(thinPo(String(parseModelJson<{ reply?: string }>(raw, {}).reply ?? raw).trim().replace(/\s*\n{3,}/g, '\n\n'), lang === 'bis' ? 0 : lang === 'tl' ? 2 : 1));
}

// deno-lint-ignore no-explicit-any
async function modelDraft(db: any, guestText: string, guestName: string | null, ctx: string[], airbnb: boolean, hint = ''): Promise<string> {
  const card = await loadCard(db); await loadContact(db);
  const channel = airbnb
    ? 'This guest writes on AIRBNB: never include links, phone numbers, e-mail, GCash, QR or any payment outside Airbnb, and never suggest booking elsewhere; for a booking, invite them to send a booking request on the Airbnb listing.'
    : 'Do not invent availability or prices beyond FACTS.';
  const system = `${voiceFor(card)}\n\nFACTS:\n${factsFor(card)}\n\nYou are drafting for the HOST to copy and send; the host will read it first. Write only the reply to the guest, in the guest's language, warm and short. ${channel} If dates are asked, say you will check and confirm. Return ONLY JSON {"reply": "<the message>"}.`;
  const datesAsked = /\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s*\d{1,2}|\d{1,2}[\/-]\d{1,2}|\b(?:available|avail|vacant|bakante|free)\b/i.test(guestText);
  const datesHint = datesAsked && !hint ? '[The guest mentions dates or availability. You cannot see the calendar: do NOT say the dates are available or taken; say you will check and confirm shortly.] ' : '';
  const q = `${hint}${datesHint}${guestName ? `Guest name: ${guestName}\n` : ''}${ctx.length ? `What we know about this guest:\n${ctx.join('\n')}\n` : ''}Guest wrote:\n"""${guestText.slice(0, 1500)}"""`;
  const raw = await chatJson({ system, history: [], question: q, title: 'Cascade Cassy draft', temperature: 0.5, maxTokens: 500, timeoutMs: 30_000 });
  return leafAtClose(String(parseModelJson<{ reply?: string }>(raw, {}).reply ?? raw).trim().replace(/\s*\n{3,}/g, '\n\n'));
}

/** Messages for the host, in order: a header card, then each option alone so a long-press copies only the reply. */
// deno-lint-ignore no-explicit-any
export async function draftGuestReply(db: any, guestText: string, guestName: string | null, thread: { before?: Line[]; platform?: Platform } = {}): Promise<string[]> {
  const platform = thread.platform === 'airbnb' || /\bairbnb\b/i.test(guestText) ? 'airbnb' : thread.platform ?? 'messenger';
  // deno-lint-ignore no-explicit-any
  const ctx = guestName ? guestContextLines(await guestContext(db, { name: guestName }).catch(() => ({} as any))) : [];
  const brain = platform === 'airbnb' ? null : await conciergeDraft(thread.before ?? [], guestText, guestName).catch(() => null);
  // SPEC-32 s2: the host drafts for a known guest, so the booked-guest regex is the floor. D-271: the concierge's own routing
  // (Jev-primary) already ran inside the probe - no second Jev call; Airbnb and the fallback route here.
  const base = classify(guestText, { hasBooking: true });
  const risk: RiskCode = isHard(base) ? base : brain?.risk ? brain.risk as RiskCode : routeRisk(base, await jevRoute(guestText, Deno.env.get('CASCADE_OPENROUTER_BOT_KEY')));
  const main = brain?.reply || await modelDraft(db, guestText, guestName, ctx, platform === 'airbnb');
  const lint = lintReply(main, guestText); if (lint.length) console.warn('voice_lint', JSON.stringify({ source: 'cassy_draft', brain: !!brain, lint }));
  const short = main.length > 320 ? await rewrite(db, main, 'Make it noticeably shorter - two short paragraphs at most - by dropping pleasantries, never facts.').catch(() => '') : '';
  const head = [`✍️ Guest reply${guestName ? ` · ${guestName}` : ''} · ${platform === 'airbnb' ? 'Airbnb' : 'Messenger'}${risk !== 'routine' ? ` · ${risk.replace('_', ' ')}` : ''}`,
    brain ? '1️⃣ is what the concierge would send (calendar and rate card checked).' : `1️⃣ is a drafted reply${platform === 'airbnb' ? ' (Airbnb: no links or outside payment)' : ' (the concierge could not be reached, so dates are not checked)'}.`,
    ...(short ? ['2️⃣ says the same, shorter.'] : [])];
  if (FLAG[risk]) head.push(`⚠️ This reads as ${FLAG[risk]}.`);
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

/** The draft card. A failed gate removes Send: the card says which rules failed and offers Draft again. */
export function inquiryDraftCard(o: { view: InquiryView; purpose: 'reply' | 'decline'; pid: string; d: Pick<InquiryDraft, 'text' | 'gate' | 'source' | 'channel' | 'lastMessage'> }): { text: string; keyboard: { text: string; callback_data?: string }[][] } {
  const first = firstName(o.view.guest_name) || 'the guest', ok = o.d.gate.length === 0;
  const head = o.purpose === 'decline'
    ? `❌ Decline ${first}'s request with this message?`
    : `✍️ Reply for ${first} · ${o.d.channel}${o.d.source === 'concierge' ? ' · calendar and rate card checked' : ''}`;
  const lines = [head, ...(o.purpose === 'reply' && o.d.lastMessage ? [`Guest wrote: "${o.d.lastMessage}"`] : []), '📨 ⤵', o.d.text,
    ...(ok ? [] : [`⚠️ Voice check: ${o.d.gate.join(', ')}. Send is off; tap 🔄 Draft again.`])];
  return { text: lines.join('\n'), keyboard: draftKeyboard({ purpose: o.purpose, pid: o.pid, bookingId: o.view.id, first: firstName(o.view.guest_name), sendOk: ok }) };
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
