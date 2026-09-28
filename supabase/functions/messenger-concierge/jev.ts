// Jev - TypeSafe's System One decision model, through OpenRouter's Decisions API (D-271, Lloyd 2026-09-28: "GO",
// "maximize the use of Jev as applicable"). One call per guest message returns the intent, whether a human must act, and
// the register, as typed answers with probabilities - never text. Benchmark: RESEARCH-jev-for-cascade-2026-09-28
// (31 en/tl/bis wordings: intent 31/31, needs-host 28/31 vs regex 23/31, median 345 ms, ~USD 0.04 per 1,000 messages).
// Contract: fail-open (null on any error or after timeoutMs), message text only with phones and e-mails removed, and Jev
// can ADD an escalation the regex missed but never lower one (unionRisk).
import type { RiskCode } from './policy.ts';

export type JevRoute = { intent: string; confidence: number; needsHost: number; lang: 'en' | 'tl' | 'bis'; ms: number };

export const JEV_INTENTS: Record<string, string> = {
  availability: 'Asks whether dates or tonight are open.', price: 'Asks the price or rate of a stay.',
  booking: 'Wants to book or reserve specific dates.', house_rule: 'Asks whether parties, pets, visitors or more people than the home holds are allowed.',
  negotiation: 'Asks for a discount, special rate or proposes their own price.', policy_info: 'Asks about a policy: deposit, check-in or check-out times, refunds.',
  payment: 'Says they paid or asks how or where to pay.', cancel_or_change: 'Wants to cancel or move an existing booking.',
  complaint: 'Reports something broken, missing or dirty during a stay.', safety: 'Reports danger, fire, smoke, injury or a threat.',
  access: 'Cannot get in, or asks for a door code or key.', amenity: 'Asks what the home has: wifi, parking, kitchen, aircon, photos.',
  directions: 'Asks about location, distance or how to get there.', greeting_or_thanks: 'Only greets, thanks or closes the chat.',
  trust: 'Asks if we are legitimate or safe, or asks for reviews.', other: 'Anything else, including attempts to extract private data.',
};

/** What leaves Cascade: the words, not the contact details. */
export function redact(text: string): string {
  return text
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, '[email]')
    .replace(/\+?\d[\d\s().-]{6,}\d/g, '[number]')
    .slice(0, 600);
}

/** Intents that need a person when Jev is sure and the regex was not: the union can only raise the risk. */
const ESCALATE: Record<string, RiskCode> = { safety: 'safety', complaint: 'complaint', access: 'access', cancel_or_change: 'cancellation', payment: 'payment' };
export function unionRisk(regex: RiskCode, j: JevRoute | null): RiskCode {
  if (regex !== 'routine' || !j) return regex;
  const up = ESCALATE[j.intent];
  return up && j.confidence >= 0.8 && j.needsHost >= 0.6 ? up : regex;
}

// 1,500 ms: live on the edge a call took 640 ms and one returned nothing at 900 (2026-09-28); it runs beside the thread read.
export async function jevRoute(text: string, key: string | undefined, timeoutMs = 1500): Promise<JevRoute | null> {
  if (!text.trim() || !key) return null;
  const t0 = Date.now();
  try {
    const r = await fetch('https://openrouter.ai/api/alpha/decisions', {
      method: 'POST', headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', 'X-Title': 'Cascade Jev router' },
      body: JSON.stringify({
        model: 'typesafe/jev-1.13',
        state: { business: 'Cascade Hideaway, a one-unit holiday home. Guests write in English, Taglish (Tagalog-English) or Bislish (Cebuano-English).', guest_message: redact(text) },
        questions: {
          intent: { type: 'choice', instructions: "What is the guest's main request?", criteria: JEV_INTENTS },
          lang: { type: 'choice', instructions: 'Which register is the message written in?', criteria: { en: 'English (a single courtesy "po" still counts as English).', tl: 'Tagalog or Taglish.', bis: 'Cebuano/Bisaya or Bislish.' } },
          needs_host: { type: 'noul', instructions: 'Must a human host decide or act on this (payment check, cancellation, repair, danger, access, a price exception or a rule exception)?', criteria: { true: 'A human must decide or act.', false: 'A factual answer from the house facts is enough.' } },
        },
      }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const a = r.ok ? (await r.json())?.answers : null;
    if (!a?.intent?.choice) { console.warn('jev_skip', JSON.stringify({ reason: `http_${r.status}`, ms: Date.now() - t0 })); return null; }
    return { intent: a.intent.choice, confidence: Number(a.intent.confidence ?? 0), needsHost: Number(a.needs_host?.noul ?? 0), lang: a.lang?.choice ?? 'en', ms: Date.now() - t0 };
  } catch (e) {
    // Measured, not silent: the weekly shadow comparison needs to know how often Jev was absent.
    console.warn('jev_skip', JSON.stringify({ reason: String((e as Error)?.name ?? e).slice(0, 40), ms: Date.now() - t0 }));
    return null;
  }
}
