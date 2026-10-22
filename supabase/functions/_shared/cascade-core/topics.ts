// SPEC-47: notable topics. Maps a guest's words (or a Jev intent) to topic KEYS only; the text itself is never kept by this file.
// Pure parts here (unit-tested in topics.test.ts); recordTopics is the one fire-and-forget writer both functions share.
export const TOPICS = ['directions', 'links', 'wifi', 'brownout', 'guest_count', 'early_checkin', 'late_checkout', 'parking', 'pets', 'id', 'complaint'] as const;
export type Topic = typeof TOPICS[number];

// English + common Tagalog/Bisaya. Matched on folded lowercase text; \b keeps "pin" out of "spinning".
const MAP: Record<Topic, RegExp> = {
  directions: /\b(?:locations?|address|directions?|how to get|how do (?:we|i) get|saan|asa|unsa(?:ng)? (?:daan|lugar)|pin|waze|google maps|gmaps|landmark|papunta|pasingil)\b/,
  links: /\b(?:links?|website|web ?site|guide|guest guide|url|facebook page|airbnb page)\b/,
  wifi: /\b(?:wi-?fi|wifi|internet|password sa wifi|router|signal)\b/,
  brownout: /\b(?:brown-?outs?|power (?:cut|outage|interruption|failure)|outage|walang kuryente|kuryente|nawalan ng (?:kuryente|ilaw)|blackout|generator|ecoflow|walay (?:kuryente|suga|power))\b|\bpower\b/,
  guest_count: /\b(?:how many (?:people|guests|persons|pax)|pax|max(?:imum)? (?:guests|people|persons|capacity|occupancy)|capacity|extra (?:person|guest|bed)|additional (?:person|guest)|dagdag (?:na )?(?:tao|bisita)|ilan (?:ang|po)? ?(?:tao|pax)|pila (?:ka tawo|ang tawo)|add(?:ing)? (?:a |one )?(?:guest|person))\b/,
  early_checkin: /\b(?:early (?:check-?in|arrival|arrive)|check-?in early|arrive early|mas maaga|earlier check-?in|maaga (?:kaming|kami|po))\b/,
  late_checkout: /\b(?:late (?:check-?out|departure)|check-?out late|extend (?:our )?check-?out|extension|stay (?:a bit )?later|mas late|late na (?:kami )?(?:mag)?check-?out)\b/,
  parking: /\b(?:parking|park (?:the|our|a|my) (?:car|van|vehicle)|garage|paradahan|parkingan|where (?:do|can) (?:we|i) park)\b/,
  pets: /\b(?:pets?|dogs?|cats?|puppy|aso|pusa|iro|iring)\b/,
  id: /\b(?:valid id|government id|gov(?:ernment)? id|ids?|id photo|passport|driver'?s? licen[cs]e|ipapakita ang id|photo of (?:my |our )?id)\b/,
  complaint: /\b(?:complain(?:t|ing)?|not working|broken|dirty|no (?:hot )?water|walang (?:tubig|aircon)|sira|madumi|ipis|cockroach|smell|amoy|bulok|leak(?:ing|s)?|disappointed|unacceptable)\b/,
};

const fold = (s: string) => s.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();

/** Topic keys found in a guest's words, in TOPICS order. Empty text gives []. */
export function topicsFromText(text: string): string[] {
  const t = fold(String(text ?? '')).slice(0, 4000);
  if (!t.trim()) return [];
  return TOPICS.filter((k) => MAP[k].test(t));
}

/** Jev intents that name a topic on their own (a sure reading only); the rest come from the words. */
const INTENT_TOPIC: Record<string, Topic> = { directions: 'directions', complaint: 'complaint' };

/** One guest turn: the sure Jev intent plus the words. Jev down (null) falls back to the words alone. */
export function topicsForTurn(text: string, jev: { intent: string; confidence: number } | null): string[] {
  const out = new Set(topicsFromText(text));
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
