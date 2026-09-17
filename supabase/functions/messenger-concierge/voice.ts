// Concierge communication protocol, the part code can check (session 28, 2026-09-17).
// Source: docs/concierge-communication-protocol.md. Three moves in every reply, in this order:
//   1. ANSWER   - if the guest asked something, the first sentences answer it (never skipped by a flow)
//   2. ACKNOWLEDGE - the person before the fact: name, "po", what they told us
//   3. ADVANCE  - one ask at most, and the guest is never left without a next step
// lintReply() is run over every canned prompt in voice.test.ts (fails the build) and over every
// outgoing reply at runtime (warn-only log `voice_lint`, so live drift is visible without blocking).

export type Violation = 'no_answer' | 'form_speak' | 'two_asks' | 'too_long' | 'cold_opener' | 'robot_word' | 'shouting' | 'too_dense';

const QUESTION_RE = /\?|\b(is it|are there|do you|does it|can we|can i|may i|pwede|meron|may (?:\w+ )?ba|magkano|how (much|far|many|long)|available|avail|bakante)\b/i;
const FORM_RE = /^\s*(your|enter|provide|input|type)\s+(mobile|number|phone|e-?mail|name|date)/i;
const ROBOT_RE = /\b(as an ai|language model|bot|automated|process(ing)? (your )?(booking|request)|ticket|form)\b/i;
const COLD_RE = /^\s*(what|which|when|how many|your)\b[^.!]*\?\s*$/i;

/** Rules a canned prompt or a live reply must satisfy. `guestText` enables the ANSWER check. */
export function lintReply(reply: string, guestText = '', opts: { firstTurn?: boolean; name?: string | null } = {}): Violation[] {
  const v: Violation[] = [];
  const asks = (reply.match(/\?/g) ?? []).length;
  if (asks > 2) v.push('two_asks');
  if (reply.length > 700) v.push('too_long');
  // Easy to consume (protocol rule 4): at most four paragraphs, none longer than ~320 characters.
  const paras = reply.split(/\n\s*\n/).filter((p) => p.trim());
  if (paras.length > 4 || paras.some((p) => p.length > 320)) v.push('too_dense');
  if (FORM_RE.test(reply)) v.push('form_speak');
  if (ROBOT_RE.test(reply)) v.push('robot_word');
  if (/\b[A-Z]{6,}\b/.test(reply.replace(/\b(GCASH|PHP|YES|QR|OK|DEPOSIT|FULL)\b/g, ''))) v.push('shouting');
  if (opts.firstTurn && COLD_RE.test(reply)) v.push('cold_opener');
  // ANSWER: a guest question must be met with an answer before the next ask - a reply that is only
  // a question back to them is the failure Lloyd saw live ("is Oct 3 to 4 available?" -> "Your mobile number po?").
  if (guestText && QUESTION_RE.test(guestText)) {
    const firstPara = reply.split(/\n\s*\n/)[0] ?? '';
    const answers = /\b(yes|yes po|oo|open|available|free|bakante|taken|booked|not open|na-?book|we have|meron|wala|it is|it's|we can|we're|we are|the (rate|nearest|nightly|unit|home)|₱|php)\b/i.test(firstPara) && !/\?\s*$/.test(firstPara.trim());
    if (!answers) v.push('no_answer');
  }
  return v;
}
