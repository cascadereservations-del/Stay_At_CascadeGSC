// Cassy draft_guest_reply (Telegram plan §3, session 27). A host pastes a guest message (or sends a
// chat screenshot captioned "cassy reply") and gets a reply to copy - in the Concierge's own voice,
// gated by the Concierge's own deterministic risk classifier. Never sends anything to a guest.
import { FACTS, VOICE, SITE_URL } from '../_shared/cascade-core/facts.ts';
import { classify, type RiskCode } from '../messenger-concierge/policy.ts';
import { detectLang } from '../messenger-concierge/booking.ts';
import { lintReply, thinPo } from '../messenger-concierge/voice.ts';
import { chatJson } from '../_shared/cascade-core/providers.ts';
import { visionExtractText, parseModelJson, hasVisionKey } from '../_shared/cascade-core/vision.ts';
import { guestContext, guestContextLines } from '../_shared/cascade-core/tools.ts';

/** "cassy reply: …", "cassy draft …", "cassy, how should I answer: …" -> the guest text (may be empty when a photo carries it). */
export function draftRequest(text: string): { draft: boolean; text: string } {
  const m = /^\s*(?:reply|draft|answer|sagot)\s*(?:to|for)?\s*[:\-–]?\s*([\s\S]*)$/i.exec(text)
    ?? /^\s*(?:how (?:should|do|can|would) (?:i|we) (?:answer|reply|respond)(?: to)?(?: this| this one)?|what (?:should|do) (?:i|we) (?:say|reply|answer))\s*[:\-–?]?\s*([\s\S]*)$/i.exec(text);
  return m ? { draft: true, text: m[1].trim() } : { draft: false, text };
}

const TRANSCRIBE_PROMPT = `This is a screenshot of a chat between a guest and Cascade Hideaway (a small Airbnb in General Santos City). Return ONLY JSON: {"guest_name": string|null, "guest_messages": string, "our_last_message": string|null}. guest_messages = the guest's messages only, newest last, verbatim (Tagalog/Bisaya/English as written); our_last_message = the host side's latest message if visible. If it is not a chat, return {"guest_name": null, "guest_messages": "", "our_last_message": null}.`;

export async function transcribeChat(bytes: Uint8Array, mime: string): Promise<{ guest_name: string | null; guest_messages: string; our_last_message: string | null }> {
  if (!hasVisionKey()) throw new Error('no vision key');
  return parseModelJson(await visionExtractText(TRANSCRIBE_PROMPT, bytes, mime, 'Cascade Guest Reader'), { guest_name: null, guest_messages: '', our_last_message: null });
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

// deno-lint-ignore no-explicit-any
export async function draftGuestReply(db: any, guestText: string, guestName: string | null): Promise<string> {
  const risk = classify(guestText, { hasBooking: true }); // SPEC-32 s2: the host drafts for a known guest
  // deno-lint-ignore no-explicit-any
  const ctx = guestName ? guestContextLines(await guestContext(db, { name: guestName }).catch(() => ({} as any))) : [];
  const system = `${VOICE}\n\nFACTS:\n${typeof FACTS === 'string' ? FACTS : JSON.stringify(FACTS)}\n\nYou are drafting for the HOST to copy and send from the Facebook Page; the host will read it first. Write only the reply to the guest, in the guest's language, warm and short. Do not invent availability or prices beyond FACTS; if dates are asked, say you will check and confirm. Return ONLY JSON {"reply": "<the message>"}.`;
  // The draft never sees the calendar: dates get a "will check" instruction, and a draft that still
  // claims availability is flagged in code (live 2026-09-17: "Yes, available pa po ang October 3 to 4").
  const datesAsked = /\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s*\d{1,2}|\d{1,2}[\/-]\d{1,2}|\b(?:available|avail|vacant|bakante|free)\b/i.test(guestText);
  const datesHint = datesAsked ? '[The guest mentions dates or availability. You cannot see the calendar: do NOT say the dates are available or taken; say you will check and confirm shortly, then give the rate and the link.] ' : '';
  const q = `${datesHint}${guestName ? `Guest name: ${guestName}\n` : ''}${ctx.length ? `What we know about this guest:\n${ctx.join('\n')}\n` : ''}Guest wrote:\n"""${guestText.slice(0, 1500)}"""`;
  const raw = await chatJson({ system, history: [], question: q, title: 'Cascade Cassy draft', temperature: 0.5, maxTokens: 500, timeoutMs: 30_000 });
  const reply = String(parseModelJson<{ reply?: string }>(raw, {}).reply ?? raw).trim().replace(/\s*\n{3,}/g, '\n\n');
  const lint = lintReply(reply, guestText); if (lint.length) console.warn('voice_lint', JSON.stringify({ source: 'cassy_draft', lint })); // measured, as the concierge is (2026-09-24)
  const lines = [`✍️ Draft reply${risk !== 'routine' ? ` · ${risk.replace('_', ' ')}` : ''}${guestName ? ` · ${guestName}` : ''}`, '', reply, ''];
  if (FLAG[risk]) lines.push(`⚠️ This reads as ${FLAG[risk]}.`);
  if (datesAsked && /\b(available|avail|open|free|vacant|bakante)\b/i.test(reply) && !/\b(check|confirm)\b/i.test(reply)) lines.push('⚠️ The draft claims availability — check the calendar before sending.');
  if (ctx.length) lines.push(...ctx);
  lines.push(`Do: copy, adjust, send from the Page. Nothing was sent. Site link if needed: ${SITE_URL}`);
  return lines.join('\n');
}

/** Session 28: the ✏️ Revise tap. Rewrites a host message in the Concierge voice; every fact, figure,
 * date and name stays. Returns the card the host reads (never sent to a guest). */
// deno-lint-ignore no-explicit-any
export async function reviseHostMessage(_db: any, template: string, context: string): Promise<string> {
  // Session 29 (live): a Bislish template came back as Tagalog with six "po". The register is read from the template
  // itself and enforced in code, as the Concierge does (D-170).
  const lang = detectLang(template);
  const register = { en: 'refined conversational English, no "po"', tl: 'natural Taglish, at most two "po"', bis: 'natural Bislish (Cebuano with English hospitality terms), never Tagalog words or "po"/"opo"' }[lang];
  const system = `${VOICE}\n\nFACTS:\n${typeof FACTS === 'string' ? FACTS : JSON.stringify(FACTS)}\n\nYou are revising a message the HOST is about to send to a guest. The message is in ${register}: reply in exactly that register. Keep every fact, figure, date, amount and name exactly; make it warmer, shorter and more natural, one message, no greeting line if the original has none. Return ONLY JSON {"reply": "<the revised message>"}.`;
  const q = `${context ? `Card context:\n${context.slice(0, 800)}\n\n` : ''}Message to revise:\n\"\"\"${template.slice(0, 1500)}\"\"\"`;
  const raw = await chatJson({ system, history: [], question: q, title: 'Cascade Cassy revise', temperature: 0.5, maxTokens: 400, timeoutMs: 30_000 });
  const reply = thinPo(String(parseModelJson<{ reply?: string }>(raw, {}).reply ?? raw).trim().replace(/\s*\n{3,}/g, '\n\n'), lang === 'bis' ? 0 : lang === 'tl' ? 2 : 1);
  const lint = lintReply(reply); if (lint.length) console.warn('voice_lint', JSON.stringify({ source: 'cassy_revise', lint }));
  return ['✍️ Revised draft', '', reply, '', 'Do: copy and send from the Page or the app. Nothing was sent.', `📨 ${reply}`].join('\n');
}
