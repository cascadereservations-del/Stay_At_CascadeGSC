// Cassy draft_guest_reply (Telegram plan §3, session 27; D-269 2026-09-28). A host pastes a guest message, or sends a chat
// screenshot (the ✍️ Guest reply button), and gets replies to copy. Never sends anything to a guest.
// D-269: for Messenger and pasted text the draft IS the concierge - the deployed messenger-concierge runs the conversation
// through its probe (real calendar, booking flow, persona.ts, voice guards; every send recorded, none made), so a fix to the
// concierge is a fix to the drafts. Airbnb chats keep a separate model draft: Airbnb forbids links, off-platform contact and
// payment, which the Messenger brain offers by design.
import { factsFor, voiceFor, SITE_URL } from '../_shared/cascade-core/facts.ts';
import { loadCard } from '../_shared/cascade-core/pricing.ts'; // SPEC-34: drafts quote the stored rate card
import { classify, type RiskCode } from '../messenger-concierge/policy.ts';
import { CASSY_INTRO, detectLang } from '../messenger-concierge/booking.ts';
import { leafAtClose, lintReply, thinPo } from '../messenger-concierge/voice.ts';
import { chatJson } from '../_shared/cascade-core/providers.ts';
import { visionExtractText, parseModelJson, hasVisionKey } from '../_shared/cascade-core/vision.ts';
import { guestContext, guestContextLines } from '../_shared/cascade-core/tools.ts';

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
async function conciergeDraft(before: Line[], latest: string, name: string | null): Promise<Brain | null> {
  const secret = Deno.env.get('CASCADE_PROBE_SECRET') ?? '', base = Deno.env.get('SUPABASE_URL') ?? '';
  if (secret.length < 24 || !base) return null;
  const r = await fetch(`${base}/functions/v1/messenger-concierge`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'x-cascade-probe': secret },
    body: JSON.stringify({ psid: `probe:cassy-${crypto.randomUUID()}`, name, history: before.map((l) => ({ role: l.from === 'guest' ? 'guest' : 'bot', text: l.text })), turns: [{ text: latest, advance_minutes: 1 }] }),
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
  const card = await loadCard(db), lang = detectLang(text);
  const register = { en: 'refined conversational English, no "po"', tl: 'natural Taglish, at most two "po"', bis: 'natural Bislish (Cebuano with English hospitality terms), never Tagalog words or "po"/"opo"' }[lang];
  const system = `${voiceFor(card)}\n\nFACTS:\n${factsFor(card)}\n\nYou are rewriting a reply the HOST is about to send to a guest. It is in ${register}: keep exactly that register. ${how} Keep every fact, figure, date, amount, link and name exactly. Return ONLY JSON {"reply": "<the message>"}.`;
  const raw = await chatJson({ system, history: [], question: `Reply:\n"""${text.slice(0, 1500)}"""`, title: 'Cascade Cassy rewrite', temperature: 0.4, maxTokens: 400, timeoutMs: 30_000 });
  return leafAtClose(thinPo(String(parseModelJson<{ reply?: string }>(raw, {}).reply ?? raw).trim().replace(/\s*\n{3,}/g, '\n\n'), lang === 'bis' ? 0 : lang === 'tl' ? 2 : 1));
}

// deno-lint-ignore no-explicit-any
async function modelDraft(db: any, guestText: string, guestName: string | null, ctx: string[], airbnb: boolean): Promise<string> {
  const card = await loadCard(db);
  const channel = airbnb
    ? 'This guest writes on AIRBNB: never include links, phone numbers, e-mail, GCash, QR or any payment outside Airbnb, and never suggest booking elsewhere; for a booking, invite them to send a booking request on the Airbnb listing.'
    : 'Do not invent availability or prices beyond FACTS.';
  const system = `${voiceFor(card)}\n\nFACTS:\n${factsFor(card)}\n\nYou are drafting for the HOST to copy and send; the host will read it first. Write only the reply to the guest, in the guest's language, warm and short. ${channel} If dates are asked, say you will check and confirm. Return ONLY JSON {"reply": "<the message>"}.`;
  const datesAsked = /\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s*\d{1,2}|\d{1,2}[\/-]\d{1,2}|\b(?:available|avail|vacant|bakante|free)\b/i.test(guestText);
  const datesHint = datesAsked ? '[The guest mentions dates or availability. You cannot see the calendar: do NOT say the dates are available or taken; say you will check and confirm shortly.] ' : '';
  const q = `${datesHint}${guestName ? `Guest name: ${guestName}\n` : ''}${ctx.length ? `What we know about this guest:\n${ctx.join('\n')}\n` : ''}Guest wrote:\n"""${guestText.slice(0, 1500)}"""`;
  const raw = await chatJson({ system, history: [], question: q, title: 'Cascade Cassy draft', temperature: 0.5, maxTokens: 500, timeoutMs: 30_000 });
  return leafAtClose(String(parseModelJson<{ reply?: string }>(raw, {}).reply ?? raw).trim().replace(/\s*\n{3,}/g, '\n\n'));
}

/** Messages for the host, in order: a header card, then each option alone so a long-press copies only the reply. */
// deno-lint-ignore no-explicit-any
export async function draftGuestReply(db: any, guestText: string, guestName: string | null, thread: { before?: Line[]; platform?: Platform } = {}): Promise<string[]> {
  const platform = thread.platform === 'airbnb' || /\bairbnb\b/i.test(guestText) ? 'airbnb' : thread.platform ?? 'messenger';
  const risk = classify(guestText, { hasBooking: true }); // SPEC-32 s2: the host drafts for a known guest
  // deno-lint-ignore no-explicit-any
  const ctx = guestName ? guestContextLines(await guestContext(db, { name: guestName }).catch(() => ({} as any))) : [];
  const brain = platform === 'airbnb' ? null : await conciergeDraft(thread.before ?? [], guestText, guestName).catch(() => null);
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
  const card = await loadCard(db);
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
