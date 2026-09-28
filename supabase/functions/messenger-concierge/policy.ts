// Deterministic risk gate. Runs BEFORE the model; the model cannot override it.
// Risk codes mirror guest_reply_drafts.risk_code (P8 shared inbox).
export type RiskCode =
  | 'routine' | 'payment' | 'refund' | 'cancellation' | 'complaint'
  | 'safety' | 'access' | 'policy_exception' | 'uncertain';

const RULES: Array<[RiskCode, RegExp]> = [
  ['safety',           /\b(emergency|fire|flood|injur|hurt|bleed|police|ambulance|unsafe|threat|suicid|kill myself|harass|stalk|smoke (coming|from|in the|everywhere)|smell(s|ing)? (of )?(gas|smoke|burning)|burning smell|gas leak|sparks?|electric(al)? shock|short circuit|nahimatay|fainted|unconscious|dumudugo|nagdugo|seizure|convuls|chest pain|hirap huminga|can'?t breathe|allerg|amoy (ng )?gas|baho (og|sa|ug) gas|sparking|nag-?spark|baha (na )?sa loob|water (coming|rising|leaking) (in|under|through)|knocking\b[^.?!\n]{0,25}\b(door|window)|stranger|intruder|sumusunod|nagsunod|gisundan|break(ing)? in|nakawan|robbed|magnanakaw|kawatan)/i], // D-270: Jev bench - "smoke coming from the kitchen" was routine; "can we smoke?" stays a house-rule question
  // "pin" needs a closing boundary: Bisaya "pinakaduol" (nearest) was gated as an access request (live 2026-09-13).
  // Session 58 (live lockout 2026-09-28, "nakalimutan ko po yung code ... didn't bring a card" read as routine; only Jev
  // caught it): a forgotten code, key or card and "can't get inside" in all three registers are the door too.
  ['access',           /\b(door code|access code|pin\b|passcode|keypad|locked (myself |ourselves |us )?out|can'?t (get in|open|get inside|go inside|enter)|door won'?t|smart ?lock|forg[eo]t\w*\b[^.?!\n]{0,25}\b(door|access|gate|pin|key|keys|card|keycard)\b|didn'?t bring\b[^.?!\n]{0,15}\b(key|keys|card|keycard)\b|nakalimutan\b[^.?!\n]{0,30}\b(code|pin|susi|card)\b|naiwan\b[^.?!\n]{0,30}\b(susi|card|key)\b|(hindi|di) (po )?(ako |kami )?(maka-?pasok|makapasok)|(dili|di) (ko|mi|kami) (ka)?sulod|unsa (ang |man ang )?code|code sa (pultahan|door|unit)|lock\b[^.?!\n]{0,20}\b(beeping|blinking|red|dead|low batt\w*|won'?t|wont|not responding|hindi nag-?respond|ayaw)|ayaw (mag-?open|bumukas|mag-?unlock|mag-?bukas)|dili (ma-?abli|mo-?abli|mo-?open)|gate pass|send (me|us) (the |your )?(exact )?(address|location|map|pin)|exact (address|location)|house (number|no)\b|block and lot|\bblk\b|guard\w*\b[^.?!\n]{0,20}\b(won'?t|wont|hindi|dili|ayaw))/i],
  // "Is the deposit refundable?" is a routine policy question; asking for money back is not.
  // SPEC-32 s2 (F14): "refunded", "refund policy" and "refunds rule" are a prospect's policy question - they escalate only
  // on a thread that holds a booking or names one (REFUND_BOOKED below). A bare "refund" ("I want a refund") always does.
  ['refund',           /\b(refund(?!able|ed\b|s? (policy|rule))|money back|chargeback|ibalik|balik ang pera)/i],
  // How to pay is routine (the booking page lists the options); reporting a payment is not.
  // SPEC-32 s2 (F2): Taglish and Bisaya claims ("nasend ko na po yung bayad" went to the model, which confirmed a booking
  // no one had checked). A send / transfer / padala verb needs the money within 25 characters: "na-send ko na po ang
  // email ko" at the details step must not become a payment card and break the booking flow.
  ['payment',          /\b(paid|nagbayad|bayad na|receipt|screenshot|proof of|reference (no|number)|(send|sent|transfer)\w* .{0,25}(deposit|payment|gcash|money)|(deposit|payment) .{0,25}(sent|paid|made)|nabayaran|binayaran|bayad (ko|namin) na|nag-?gcash|nakapag-?bayad|gi-?bayad|nabayran|(na-?send|nasend|sinend|na-?transfer|napadala)\w* .{0,25}(bayad|payment|gcash|deposit|fee|pera|money|receipt)|charged (twice|double|two times)|charged (me |us )?(php ?)?\d|siningil\w*|double.?charg\w*|overcharg\w*|wrong amount|amount\b[^.?!\n]{0,20}\b(wrong|mali|iba)|nadoble\b[^.?!\n]{0,15}\b(bayad|payment)|sobra\b[^.?!\n]{0,15}\b(bayad|singil|nabayaran|charge))/i],
  // The cancellation policy is routine; changing an actual booking is not.
  ['cancellation',     /\b(cancel\w*\s+(my|our|the|ang|yung)\s*(booking|reservation|stay|dates|reserba)|cancel po kasi|reschedul|move (my|our|the) (dates|booking|stay)|change (my|our|the) dates|(di|hindi) na (kami|ako|mi) tuloy|dili na mi (mo-?adto|padayon|mo-?stay))/i],
  // D-222: "scam" left this rule - "legit po ba? hindi scam?" is a prospect's trust question (TRUST_RE answers it with
  // reviews), and routing it here sent a work order and told the prospect "service partners have been notified".
  ['complaint',        /\b(complain|disappoint|terrible|dirty|broken|not working|no water|no wifi|no internet|brownout|noisy|report you|review you|walay tubig|walang tubig|walay kuryente|walang kuryente|sira ang|guba ang|leak\w*|tumutulo|nagtulo|nagatulo|wala\w*( pong?| pa| kami| mi| na)? (wifi|internet|tubig|kuryente|ilaw|signal|hot water)|nawalan (ng|og|sa) (kuryente|tubig|wifi|signal|ilaw)|no (power|electricity|hot water|signal|aircon|light)|wifi\b[^.?!\n]{0,12}\b(down|off|slow|not|dead|weak)|slow (wifi|internet|net)|mahina (ang |ang inyong )?(wifi|internet|signal|tubig)|(hindi|di|ayaw|dili|wala\w*) (po )?(gumagana|gumana|lumalamig|umaandar|umandar|mag-? ?on|mo-? ?on|mugana|mo-?gana|nag-?on|nagagana)|ipis|cockroach|roach|\bants\b|langgam|daga|\brats?\b|surot|bed ?bugs?|lamok|mosquito|(remote|towel|key ?card)\b[^.?!\n]{0,10}\b(missing|wala|nawawala)|missing (remote|towel|pillow|blanket)|(left|forgot|naiwan|nakalimutan|nabilin|na-?left)\b[^.?!\n]{0,40}\b(in|at|sa) (the |ang )?(unit|room|house|home|kwarto|banyo|cr|bathroom|kitchen|kusina)\b|lost (my|our)\b|nawala\w*\b[^.?!\n]{0,30}\b(ko|namin|nako|namo)\b|can you check (the )?(unit|room)|(we|kami|mi)\b[^.?!\n]{0,10}\b(already left|umalis na|checked out na|nakalabas na|left na|nakaalis na)|leaving now|paalis na (kami|mi)|(nakalimutan|forgot|naiwan)\b[^.?!\n]{0,25}\b(i-?off|turn off|patayin|aircon on|ilaw on))/i], // D-270: Tagalog/Bisaya complaints (Jev bench)
  // Lloyd 2026-09-13: a general "discount?" / "cheaper?" is answered from the rate tiers (the site
  // applies the best rate automatically; longer stays, higher discount). Only haggling and a
  // named price (next rule) go to the host.
  // D-222: "more than N" counts people only ("more than 2 km from SM" is a distance question).
  ['policy_exception', /\b(haggle|tawad|pets?|dogs?|cats?|aso|pusa|iro|iring|videoke|karaoke|party|event|extra guest|more than \d+ ?(guests?|pax|people|persons?|adults?|kids?|children|tao|tawo)|overnight visitor)/i],
  // A guest proposing their own price ("can you do 1500", "pwede po ba 1,500 per night", "student rate")
  // is a negotiation: the host decides (D-067). A proposal verb near a 3-5 digit amount, or a budget plea.
  ['policy_exception', /\b(can you (do|make it|give)|could you do|possible( po)?( ba)?|pwede( po)?( ba)?|kaya( po)?( ba)?|make it|how about)\b[^.?!]{0,30}?\b\d{1,2},?\d{3}\b|\b(student|senior|budget) (rate|price|discount)|\brate na lang\b|\bmagkano na lang\b|\b(last|lowest|final) price\b/i], // D-271 held-out eval: "last price po?"
  ['uncertain',        /\b(system prompt|ignore (previous|your) instructions|api key|database|owner'?s? (phone|address)|other guests?|who else is staying)/i],
];

/** D-269: a policy_exception about a HOUSE RULE (party, pets, extra guests) has a factual answer in FACTS, given before the
 *  host hears it (persona.ts houseRule). Haggling and named prices return null: those stay the host's line alone. */
export function houseRuleKind(text: string): 'party' | 'pets' | 'guests' | null {
  if (/\b(haggle|tawad)/i.test(text)) return null;
  if (/\b(part(y|ies)|events?|videoke|karaoke)\b/i.test(text)) return 'party';
  if (/\b(pets?|dogs?|cats?|aso|pusa|iro|iring)\b/i.test(text)) return 'pets'; // D-271: Tagalog and Bisaya pet words
  if (/\b(extra guests?|overnight visitors?|more than \d+ ?(guests?|pax|people|persons?|adults?|kids?|children|tao|tawo))\b/i.test(text)) return 'guests';
  return null;
}

const REFUND_BOOKED = /\b(refund\w*)/i;
/** A turn names a booking of its own ("my booking", "yung bayad"), whatever the thread holds. */
export const NAMES_BOOKING = /\b(my|our|aming|among|yung) (booking|reservation|stay|deposit|payment|bayad)\b/i;
/** `hasBooking`: the thread holds a booking (booking_flow.ref), or the caller is the host drafting for a known guest. */
// Session 58 (DESIGN-guest-case-catalogue G3): a prospect's safety QUESTION ("is there a fire extinguisher?", "does the road
// flood?") is not an emergency - it used to send the 911 line, mute the bot 24 h and raise an urgent work order. The safety
// rule is skipped only when the text asks about safety and says nothing is happening now.
const SAFETY_ASK_RE = /\b(is there|are there|do you have|meron|may (ba|po|kayo)|naa ba|nearby|near(est)?|station|exit|extinguisher|alarm|contact (number|no)|hotline|number|schedule|does (the|it|this)|when it rains|kung umulan|kung mag-?ulan|safe (po )?ba|how safe|is it safe|what if|in case|paano kung|unsaon kung)\b/i;
const SAFETY_NOW_RE = /\b(now|right now|ngayon|karon|na po|na gyud|help|tulong|tabang|please|pls|911|coming|rising|there is|there'?s|may (tao|lalaki|babae|usok|apoy|baha)|naa\w* (tawo|aso|kalayo|baha)|nahimatay|fainted|dumudugo|bleeding|nasugatan|injured|reaction|attack|seizure|sparking|smell|amoy|baho|knocking|stranger|intruder|sumusunod|gisundan)\b/i;
export function classify(text: string, opts: { hasBooking?: boolean } = {}): RiskCode {
  const booked = !!opts.hasBooking || NAMES_BOOKING.test(text);
  for (const [code, re] of RULES) {
    if (code === 'safety' && re.test(text) && SAFETY_ASK_RE.test(text) && !SAFETY_NOW_RE.test(text)) continue;
    if (re.test(text)) return code;
    if (code === 'refund' && booked && REFUND_BOOKED.test(text) && !/\brefundable\b/i.test(text)) return 'refund';
  }
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
export function gate(text: string, opts: { mode: string; humanUntil: string | null; botTurns: number; now?: Date; hasBooking?: boolean }): Gate {
  const now = opts.now ?? new Date();
  const risk = classify(text, { hasBooking: opts.hasBooking });
  if (opts.mode === 'off') return { reply: false, handoff: false, risk };
  // Lloyd 2026-09-28 ("verify that emergencies should be included in the notifications"): a human hold (2 h after a staff
  // reply, 24 h after a safety report) used to swallow every message - a second emergency in that window reached no one.
  // A safety or door message always goes through: the line to the guest, the card and the urgent alert to the host.
  if (opts.humanUntil && new Date(opts.humanUntil) > now) return risk === 'safety' || risk === 'access' ? { reply: true, handoff: true, risk } : { reply: false, handoff: false, risk };
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

// ---- Session 58 (DESIGN-guest-case-catalogue G1): what the host card needs to match a person to a stay ----

/** The name a guest gives in a message ("my name is Allyssa", "Allyssa Estenzo po yung name ko"), or null. */
export function statedName(text: string): string | null {
  const NAME = String.raw`([A-Z][\p{L}'-]+(?: [A-Z][\p{L}'-]+)?)`;
  const m = new RegExp(String.raw`\b(?:my name is|name ko(?: po)? ay|ako (?:po )?si|this is|i am|i'm)\s+` + NAME, 'u').exec(text)
    ?? new RegExp('^\s*' + NAME + String.raw`\s+(?:po\s+)?(?:yung|ang|ni)\s+name\s+(?:ko|nako)`, 'u').exec(text);
  const name = m?.[1] ?? null;
  return name && !/^(The|This|Here|Hi|Hello|Good|Guest|Sorry)\b/.test(name) ? name : null;
}

export type StayRow = { guest_name: string | null; raw_summary: string | null; checkin_date: string; checkout_date: string; source: string | null };
/** In-house / arriving / departing lines for a host card, from confirmed calendar rows; `today` is YYYY-MM-DD (Manila). */
export function stayLines(rows: StayRow[], today: string): string[] {
  const who = (r: StayRow) => `${r.guest_name || r.raw_summary || 'unnamed'} · ${r.checkin_date} to ${r.checkout_date} · ${r.source ?? '?'}`;
  const inHouse = rows.filter((r) => r.checkin_date <= today && today < r.checkout_date);
  const arriving = rows.filter((r) => r.checkin_date === today);
  const departing = rows.filter((r) => r.checkout_date === today);
  return [
    `In-house: ${inHouse.length ? inHouse.map(who).join(' | ') : 'nobody'}`,
    ...(arriving.length ? [`Arriving today: ${arriving.map(who).join(' | ')}`] : []),
    ...(departing.length ? [`Departing today: ${departing.map(who).join(' | ')}`] : []),
  ];
}
