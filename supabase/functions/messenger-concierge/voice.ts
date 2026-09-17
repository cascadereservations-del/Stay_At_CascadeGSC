// Concierge communication protocol, the part code can check (session 28, 2026-09-17).
// Source: docs/concierge-communication-protocol.md. Three moves in every reply, in this order:
//   1. ANSWER   - if the guest asked something, the first sentences answer it (never skipped by a flow)
//   2. ACKNOWLEDGE - the person before the fact: name, "po", what they told us
//   3. ADVANCE  - one ask at most, and the guest is never left without a next step
// lintReply() is run over every canned prompt in voice.test.ts (fails the build) and over every
// outgoing reply at runtime (warn-only log `voice_lint`, so live drift is visible without blocking).

export type Violation = 'no_answer' | 'form_speak' | 'two_asks' | 'too_long' | 'cold_opener' | 'robot_word' | 'shouting' | 'too_dense' | 'command_tone' | 'exclaim' | 'boilerplate';

const QUESTION_RE = /\?|\b(is it|are there|do you|does it|can we|can i|may i|pwede|meron|may (?:\w+ )?ba|magkano|how (much|far|many|long)|available|avail|bakante)\b/i;
const FORM_RE = /^\s*(your|enter|provide|input|type)\s+(mobile|number|phone|e-?mail|name|date)/i;
const ROBOT_RE = /\b(as an ai|language model|bot|automated|process(ing)? (your )?(booking|request)|ticket|form)\b/i;
const COLD_RE = /^\s*(what|which|when|how many|your)\b[^.!]*\?\s*$/i;
// Cassy persona (D-167): guide, never command; no exaggerated enthusiasm.
const COMMAND_RE = /(^|\n|[.!?]\s+)(send|reply|tap|enter|pay|scan|upload|click)\s+(me|us|the|your|a|an|₱|\d|it|here|now|deposit|full)\b/i;
const EXCLAIM_RE = /\b(wonderful|amazing|awesome|lovely|fantastic|great news|good news|napakagandang|lubos (po )?kaming nagagalak|ikinagagalak)\b|!{2,}/i;
// D-168 section 22: corporate / translated filler a real host would never type.
const BOILERPLATE_RE = /\b(rest assured|please be advised|kindly|absolutely|certainly|great question|happy to help|at your earliest convenience|do not hesitate|utmost (pleasure|satisfaction)|valued (customer|guest)|esteemed guest|highly value your patronage|any inconvenience this may have caused|nagagalak|ipabatid|pahingi|pakibigay|pasayloa kami sa dakong)\b/i;

// Session 29 (live, "is there parking?" at confirm): the model echoed the stay card from history and rephrased the site
// invite, so the card went out twice with an invite between. When the flow's own ask follows, only the answer is kept.
const FLOW_NOISE_RE = /^(here are your stay details|here's your stay|ito po ang details|mao ni ang details|📅|📞|💰|💳|to secure (your|the) stay|para ma-secure|👉)|https?:\/\/|\b(our|sa) site\b|\bdirect(ly)? book|\bdetails\b[^\n]{0,20}\bstay\b|\bstay details\b|· \d+ nights?\b|^\W{0,4}total ₱|ready whenever you are/i;
const CLOSER_RE = /\s*[^.!?\n]*\b(any (other|more|further) questions|(iba|uban|ubang|lain|laing)\b[^.!?\n]{0,25}(katanungan|questions?|tanong|pangutana)|mag-atubili)\b[^.!?\n]*[.!?]?/gi;
/** The model's answer without an echoed card, a site invite or an "any other questions" closer. Never returns ''. */
export function answerOnly(reply: string): string {
  const paras = reply.split(/\n\s*\n/);
  const cut = paras.findIndex((p) => FLOW_NOISE_RE.test(p.trim()));
  return (cut < 0 ? paras : paras.slice(0, cut)).join('\n\n').replace(CLOSER_RE, '').trim() || paras[0].trim();
}

/** Protocol 07 section 4: "po" is purposeful, one or two per message. The model's Taglish parking answer carried six
 *  (live, session 29). "po" is an enclitic, so dropping the extras leaves every sentence intact; "opo"/"pong" are untouched. */
export function thinPo(text: string, keep = 2): string {
  let n = 0;
  return text.replace(/ po\b/g, (m) => (++n > keep ? '' : m));
}

// Session 30 (live 2026-09-17 18:25, "hello, available Oct 20 to 22?"): the reply read "…directly on our site:" with no
// link under it, then two more nudges ("Direct bookings offer…", "No pressure at all…"), in stiff uncontracted English.
const SOFT_NUDGE_RE = /\b(no pressure|whenever you(?:'d| would) like to secure|here whenever you(?:'re| are) ready|walang pressure|kapag handa na (po )?kayo)\b/i;
const CONTRACTIONS: Array<[RegExp, string]> = [
  [/\b(We|we|You|you|I|They|they) would\b/g, "$1'd"], [/\b(We|we|You|you|They|they) are\b/g, "$1're"], [/\b(We|we|You|you|I|They|they) will\b/g, "$1'll"],
  [/\b(We|we|You|you|I|They|they) have\b(?= (?:been|already|prepared|arranged|noted|set|reserved))/g, "$1've"], [/\b(It|it|That|that|There|there) is\b/g, "$1's"],
  [/\b(D|d)o not\b/g, "$1on't"], [/\b(D|d)oes not\b/g, "$1oesn't"], [/\b(C|c)annot\b/g, "$1an't"], [/\b(I|i)s not\b/g, "$1sn't"],
];
/** Code-owned polish for a model reply (D-097: prompt rules alone fail). An invite sentence that ends in ":" always has
 *  its link under it; when the site is offered, the soft "no pressure" paragraphs go (one invitation per message,
 *  protocol rule 4); English replies use contractions (protocol 08). Pure, so it is tested. */
export function tidyReply(reply: string, siteUrl: string, english: boolean): string {
  let paras = reply.split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean);
  for (let i = 0; i < paras.length; i++) {
    if (!/:\s*$/.test(paras[i])) continue;
    const next = paras[i + 1] ?? '';
    if (/^(👉|https?:\/\/|🏡|⭐|📅|•|-)/.test(next)) continue;          // the colon is followed by what it promised
    if (/\b(site|website|link)\b/i.test(paras[i])) paras.splice(i + 1, 0, `👉 ${siteUrl}`);
    else paras[i] = paras[i].replace(/\s*:\s*$/, '.');
  }
  if (paras.some((p) => p.includes(siteUrl))) paras = paras.filter((p, i) => i === 0 || !SOFT_NUDGE_RE.test(p) || p.includes(siteUrl));
  let out = paras.join('\n\n');
  if (english) for (const [re, to] of CONTRACTIONS) out = out.replace(re, to);
  return out;
}

/** The chat already holds the guest count: a paragraph that only asks for it again is dropped (live 2026-09-17 18:34,
 *  the model asked despite the hint - D-097, code owns it). Never returns ''. */
const PAX_ASK_RE = /^[^\n]*\b(how many (guests|people|persons|of you)|number of guests|ilan po (kayo|ang)|pila (mo|ka tawo))\b[^\n]*\?\s*$/i;
export function dropPaxAsk(reply: string): string {
  const paras = reply.split(/\n\s*\n/);
  const kept = paras.filter((p) => !PAX_ASK_RE.test(p.trim()));
  if (!kept.length || kept.length === paras.length) return reply;
  // The canned site line opens with "Or…" because it used to follow that question.
  return kept.join('\n\n').replace(/(^|\n\n)Or you may\b/, '$1You may').replace(/(^|\n\n)O maaari rin po\b/, '$1Maaari rin po');
}

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
  if (COMMAND_RE.test(reply)) v.push('command_tone');
  if (EXCLAIM_RE.test(reply)) v.push('exclaim');
  if (BOILERPLATE_RE.test(reply)) v.push('boilerplate');
  // ANSWER: a guest question must be met with an answer before the next ask - a reply that is only
  // a question back to them is the failure Lloyd saw live ("is Oct 3 to 4 available?" -> "Your mobile number po?").
  if (guestText && QUESTION_RE.test(guestText)) {
    const firstPara = reply.split(/\n\s*\n/)[0] ?? '';
    const answers = /\b(yes|yes po|oo|opo|may|mayroon|meron|open|available|free|bakante|taken|booked|reserved|not open|na-?book|we have|meron|wala|it is|it's|we can|we're|we are|the (rate|nearest|nightly|unit|home)|₱|php)\b/i.test(firstPara) && !/\?\s*$/.test(firstPara.trim());
    if (!answers) v.push('no_answer');
  }
  return v;
}
