// SPEC-47: notable topics. Maps a guest's words (or a Jev intent) to topic KEYS only; the text itself is never kept by this file.
// Pure parts here (unit-tested in topics.test.ts); recordTopics is the one fire-and-forget writer both functions share.
export const TOPICS = ['directions', 'links', 'wifi', 'brownout', 'guest_count', 'early_checkin', 'late_checkout', 'parking', 'pets', 'id', 'complaint'] as const;
export type Topic = typeof TOPICS[number];

// English + common Tagalog/Bisaya. Matched on folded lowercase text; \b keeps "pin" out of "spinning". Phrases, not bare words:
// a topic is a reason to look at the guest card, so a false hit costs more than a miss.
const re = (r: RegExp) => (t: string) => r.test(t);
const NEG = /\b(?:not|no|hindi|dili|wasn'?t|isn'?t|never|walang)\b/;
/** True when the match is preceded by a negation within three words ("was not dirty at all"). */
function negated(t: string, at: number): boolean {
  return NEG.test(t.slice(0, at).split(/\s+/).slice(-3).join(' '));
}
const COMPLAINT_ALWAYS = /\b(?:complain(?:t|ing|ed)?|not working|doesn'?t work|broken|no (?:hot )?water|walang (?:tubig|aircon)|sira ang|mabaho|smells? (?:bad|like)|smelly|ipis|cockroach|bulok|leak(?:ing|s)?|disappointed|unacceptable)\b/;
const COMPLAINT_NEGATABLE = /\b(?:dirty|madumi)\b/g;
/** Clock times after "check in at" / "check out at": 11am check-in is early, 2pm check-out is late. Standard times are 2pm in, 12pm out. */
function timeAfter(t: string, cue: RegExp): number | null {
  const m = cue.exec(t); if (!m) return null;
  let h = Number(m[1]); const pm = m[3] === 'pm';
  if (!(h >= 1 && h <= 12)) return null;
  if (pm && h < 12) h += 12; if (!pm && h === 12) h = 0;
  return h + Number(m[2] ?? 0) / 60;
}
const IN_AT = /\bcheck-?\s?in (?:at|by|around|before|time of) ?(\d{1,2})(?::(\d\d))? ?(am|pm)\b/;
const OUT_AT = /\bcheck-?\s?out (?:at|until|til|till|by|around|after) ?(\d{1,2})(?::(\d\d))? ?(am|pm)\b/;

const MAP: Record<Topic, (t: string) => boolean> = {
  directions: re(/\b(?:locations?|(?:your|the|exact|full|complete) address|directions?|how to get (?:there|to|in)|how do (?:we|i) get (?:there|to|in)|(?:saan|asa)\b(?:\s+\w+){0,3}\s+(?:location|lugar|bahay|place|address|kayo|banda|pin)|unsa(?:ng)? (?:daan|lugar)|pin location|drop(?:ped)? (?:a |the |your )?pin|(?:send|share) (?:me |us )?(?:a |the |your )?pin|waze|google maps|gmaps|landmark|papunta)\b/),
  links: re(/\b(?:links?|url|facebook page|airbnb page)\b/),
  wifi: re(/\b(?:wi-?fi|wifi|internet|router)\b/),
  brownout: re(/\b(?:brown-?outs?|power (?:is |was )?(?:out|off|gone|down)|power (?:cut|outage|interruption|failure)|outage|kuryente|nawalan ng (?:kuryente|ilaw)|blackout|generator|ecoflow|walay (?:kuryente|suga|power))\b/),
  guest_count: re(/\b(?:how many (?:people|guests|persons|pax)|pax|max(?:imum)?(?: of)? (?:\d+ )?(?:guests|people|persons|pax|capacity|occupancy)|(?:guests|people|persons|pax) max|capacity|extra (?:person|guest|bed)|additional (?:person|guest)|dagdag (?:na )?(?:tao|bisita)|ilan\b(?:\s+\w+){0,4}\s+(?:tao|pax|bisita)|pila\b(?:\s+\w+){0,4}\s+(?:tawo|tao)|add(?:ing)? (?:a |one )?(?:guest|person))\b/),
  early_checkin: (t) => /\b(?:early (?:check-?in|arrival|arrive)|check-?in early|arrive early|earlier check-?in|maaga\b(?:\s+\w+){0,4}\s+(?:check-?in|dumating|dating|arrive|pumasok)|(?:check-?in|dating|dumating|arrive)\b(?:\s+\w+){0,4}\s+maaga)\b/.test(t) || (timeAfter(t, IN_AT) ?? 99) < 14,
  late_checkout: (t) => /\b(?:late (?:check-?out|departure)|check-?out late|extend (?:our |my )?(?:stay|check-?out)|stay (?:a bit )?later|mas late|late na (?:kami )?(?:mag)?check-?out)\b/.test(t) || (timeAfter(t, OUT_AT) ?? 0) > 12,
  parking: re(/\b(?:parking|garage|paradahan|parkingan|(?:we|i)(?: will| can| shall|'ll)? park|we'?ll park|park (?:outside|inside|in front|the|our|a|my|at)|where (?:do|can) (?:we|i) park)\b/),
  pets: re(/\b(?:pets?|dogs?|cats?|puppy|aso|pusa|iro|iring)\b/),
  id: re(/\b(?:valid id|government id|gov(?:ernment)? id|ids?|id photo|passport|driver'?s? licen[cs]e|ipapakita ang id|photo of (?:my |our )?id)\b/),
  complaint: (t) => COMPLAINT_ALWAYS.test(t) || [...t.matchAll(COMPLAINT_NEGATABLE)].some((m) => !negated(t, m.index ?? 0)),
};

const fold = (s: string) => s.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();

/** Topic keys found in a guest's words, in TOPICS order. Empty text gives []. */
export function topicsFromText(text: string): string[] {
  const t = fold(String(text ?? '')).slice(0, 4000);
  if (!t.trim()) return [];
  return TOPICS.filter((k) => MAP[k](t));
}

/** Jev intents that name a topic on their own (a sure reading only); the rest come from the words. */
const INTENT_TOPIC: Record<string, Topic> = { directions: 'directions', complaint: 'complaint' };

/** One guest turn: the sure Jev intent plus the words. Jev down (null) falls back to the words alone. */
export function topicsForTurn(text: string, jev: { intent: string; confidence: number } | null): string[] {
  // Messenger takes "complaint" from Jev alone: the words are too loose to start a card note on their own.
  const out = new Set(topicsFromText(text).filter((k) => k !== 'complaint'));
  const t = jev && jev.confidence >= 0.8 ? INTENT_TOPIC[jev.intent] : undefined;
  if (t) out.add(t);
  return TOPICS.filter((k) => out.has(k));
}

type Rpc = { rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<{ error?: { message?: string } | null }> };

/** Fire-and-forget: call WITHOUT await. Never throws, never rejects, never blocks a reply; a failed write is one counts-only log line. */
export function recordTopics(db: Rpc, guestId: string | null | undefined, bookingId: string | null, topics: string[], source: 'airbnb' | 'messenger'): Promise<void> {
  if (!guestId || !topics.length) return Promise.resolve();
  return (async () => {
    for (const p_topic of topics) {
      try {
        const { error } = await db.rpc('record_guest_topic_v1', { p_guest_id: guestId, p_booking_id: bookingId, p_topic, p_source: source });
        if (error) console.warn('topic_write_failed', source, String(error.message ?? error).slice(0, 80));
      } catch (e) { console.warn('topic_write_failed', source, String(e).slice(0, 80)); }
    }
  })();
}
