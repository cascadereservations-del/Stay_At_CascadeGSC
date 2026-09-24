// Deterministic risk gate. Runs BEFORE the model; the model cannot override it.
// Risk codes mirror guest_reply_drafts.risk_code (P8 shared inbox).
export type RiskCode =
  | 'routine' | 'payment' | 'refund' | 'cancellation' | 'complaint'
  | 'safety' | 'access' | 'policy_exception' | 'uncertain';

const RULES: Array<[RiskCode, RegExp]> = [
  ['safety',           /\b(emergency|fire|flood|injur|hurt|bleed|police|ambulance|unsafe|threat|suicid|kill myself|harass|stalk)/i],
  // "pin" needs a closing boundary: Bisaya "pinakaduol" (nearest) was gated as an access request (live 2026-09-13).
  ['access',           /\b(door code|access code|pin\b|passcode|keypad|locked out|can'?t (get in|open)|door won'?t|smart ?lock)/i],
  // "Is the deposit refundable?" is a routine policy question; asking for money back is not.
  ['refund',           /\b(refund(?!able)|money back|chargeback|ibalik|balik ang pera)/i],
  // How to pay is routine (the booking page lists the options); reporting a payment is not.
  ['payment',          /\b(paid|nagbayad|bayad na|receipt|screenshot|proof of|reference (no|number)|(send|sent|transfer)\w* .{0,25}(deposit|payment|gcash|money)|(deposit|payment) .{0,25}(sent|paid|made))/i],
  // The cancellation policy is routine; changing an actual booking is not.
  ['cancellation',     /\b(cancel\w*\s+(my|our|the|ang|yung)\s*(booking|reservation|stay|dates|reserba)|cancel po kasi|reschedul|move (my|the) (dates|booking)|change (my|the) dates)/i],
  // D-222: "scam" left this rule - "legit po ba? hindi scam?" is a prospect's trust question (TRUST_RE answers it with
  // reviews), and routing it here sent a work order and told the prospect "service partners have been notified".
  ['complaint',        /\b(complain|disappoint|terrible|dirty|broken|not working|no water|no wifi|no internet|brownout|noisy|report you|review you)/i],
  // Lloyd 2026-09-13: a general "discount?" / "cheaper?" is answered from the rate tiers (the site
  // applies the best rate automatically; longer stays, higher discount). Only haggling and a
  // named price (next rule) go to the host.
  // D-222: "more than N" counts people only ("more than 2 km from SM" is a distance question).
  ['policy_exception', /\b(haggle|tawad|pets?|dogs?|cats?|party|event|extra guest|more than \d+ ?(guests?|pax|people|persons?|adults?|kids?|children|tao|tawo)|overnight visitor)/i],
  // A guest proposing their own price ("can you do 1500", "pwede po ba 1,500 per night", "student rate")
  // is a negotiation: the host decides (D-067). A proposal verb near a 3-5 digit amount, or a budget plea.
  ['policy_exception', /\b(can you (do|make it|give)|could you do|possible( po)?( ba)?|pwede( po)?( ba)?|kaya( po)?( ba)?|make it|how about)\b[^.?!]{0,30}?\b\d{1,2},?\d{3}\b|\b(student|senior|budget) (rate|price|discount)|\brate na lang\b|\bmagkano na lang\b/i],
  ['uncertain',        /\b(system prompt|ignore (previous|your) instructions|api key|database|owner'?s? (phone|address)|other guests?|who else is staying)/i],
];

export function classify(text: string): RiskCode {
  for (const [code, re] of RULES) if (re.test(text)) return code;
  return 'routine';
}

export interface Gate { reply: boolean; handoff: boolean; risk: RiskCode }

/** D-222: the concierge mode from the app_settings rows. A failed or empty read is 'suggest' - the guest gets the
 *  holding line and the host the draft - never 'off': on 2026-09-13 13:15Z a 504 on this read silenced a reply with no
 *  card and no log line. An explicit 'off' row is still honoured. */
export function modeFrom(rows: { key: string; value: unknown }[] | null): string {
  const v = (rows ?? []).find((r) => r.key === 'concierge_mode')?.value;
  return typeof v === 'string' && v ? v : 'suggest';
}

// mode: 'off' = silent; 'suggest' = draft goes to ops only; 'auto' = reply to guest.
export function gate(text: string, opts: { mode: string; humanUntil: string | null; botTurns: number; now?: Date }): Gate {
  const now = opts.now ?? new Date();
  const risk = classify(text);
  if (opts.mode === 'off') return { reply: false, handoff: false, risk };
  if (opts.humanUntil && new Date(opts.humanUntil) > now) return { reply: false, handoff: false, risk };
  if (risk !== 'routine') return { reply: true, handoff: true, risk };
  // ponytail: flat cap of 30 bot turns in one conversation (the counter resets after a 6 h gap),
  // then a human. 12 was hit by a real live chat on 2026-09-13 and turned every later message into
  // a handoff; 30 only stops a runaway loop.
  if (opts.botTurns >= 30) return { reply: true, handoff: true, risk: 'uncertain' };
  return { reply: true, handoff: false, risk };
}

// Early check-in / late check-out asked before any dates are known. Three prompt-side rules
// (FACTS, OUTPUT check, per-turn note) were all ignored live on 2026-09-12 - the model promised
// a free 1 PM check-out every time. So this is decided here, without the model: the bot asks
// for the dates and promises nothing. Once a date appears anywhere in the thread the model
// answers from the CHECKS OUT / CHECKS IN lists as usual.
const TIMING_ASK = /\b(early|earlier|maaga|before (noon|12|2 ?pm|two)|late(r)? check.?out|after (noon|12)|leave (at|around|by) \d|check.?out (at|around|by) \d|check.?in (at|around|by) (\d|[1-9]|1[01]) ?(am|:)|stay (until|till)|extend|extension|umalis nang (late|alas)|late check|matagal)/i;
const DATE_HINT = /\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.? ?\d{1,2}|\b\d{1,2}[\/-]\d{1,2}|\b(today|tonight|tomorrow|bukas|ngayon|this (weekend|week)|next (week|weekend|month)|karon)\b|\benero|pebrero|marso|abril|mayo|hunyo|hulyo|agosto|setyembre|oktubre|nobyembre|disyembre/i;
export function needsDatesFirst(text: string, priorGuestText: string): boolean {
  return TIMING_ASK.test(text) && !DATE_HINT.test(text) && !DATE_HINT.test(priorGuestText);
}

// Lloyd 2026-09-12: the site invitation + closer must not trail every reply. Keep them on a
// fresh conversation or a booking/rate/availability question; otherwise, when the last two bot
// turns already carried the link, drop the invitation paragraph (and the ':' lead-in before it)
// and a short generic closer left dangling at the end.
const INQUIRY_RE = /\b(rate|price|how much|magkano|pila|tagpila|avail|book|reserv|dates?|nights?|stay (for|from|on)|check.?in on|weekend)\b/i;
const CLOSER_RE = /^(we('d| would| will)?( be)? ?(happy|glad|love|look forward)|we look forward|malipayon|masaya (po )?kami|maraming salamat|salamat)/i;
export function trimRepeatedInvite(reply: string, priorBotTexts: string[], question: string, siteUrl: string): string {
  if (priorBotTexts.length === 0 || INQUIRY_RE.test(question)) return reply;
  if (!priorBotTexts.slice(-2).some((t) => t.includes(siteUrl))) return reply;
  const paras = reply.split(/\n{2,}/);
  const i = paras.findIndex((p) => p.includes(siteUrl));
  if (i < 0) return reply;
  paras.splice(i, 1);
  if (i > 0 && /:\s*$/.test(paras[i - 1])) paras.splice(i - 1, 1);
  const last = paras[paras.length - 1] ?? '';
  if (paras.length > 1 && last.length < 90 && CLOSER_RE.test(last.trim())) paras.pop();
  return paras.join('\n\n').trim();
}

/** D-227: the host's handoff card names a spent model budget - the one draft failure the host can fix in a
 *  minute. OpenRouter answers 402 (no credit) or 429 (limit reached); anything else gets no note.
 *  ponytail: if the Gemini fallback is open it throws last and hides the OpenRouter cause; that is the
 *  first failure only, since an empty Gemini prepay trips its breaker for six hours. */
export function draftFailureNote(err: unknown): string {
  return /openrouter_(402|429)\b/.test(String(err))
    ? 'The model budget for today is used up; raise the key limit at openrouter.ai/settings/keys.'
    : '';
}
