// Session 119: who actually stays. Reads the guest's own words and returns a SUGGESTION string for the stay, or null.
// Pure (no I/O). Conservative by design: anything unclear is null, a person confirms or edits the suggestion in the staff app or admin, and
// Cassy never writes the names. No phone number, e-mail, link or digit ever leaves here (the SQL also refuses contact text).
// shortcut: deterministic patterns only (English + Taglish); add a model call after a real message shows a miss, and only with Lloyd's yes.

export const MAX_SUGGESTION = 300;
export const MAX_ITEMS = 8;

const REL = '(?:parents?|mother|mom|mommy|mum|father|dad|daddy|papa|mama|sisters?|brothers?|siblings?|friends?|cousins?|colleagues?|co-?workers?|boss|clients?|family|relatives?|aunts?|uncles?|grandparents?|grandmother|grandfather|grandma|grandpa|in-laws?|daughters?|sons?|kids?|children|wife|husband|girlfriend|boyfriend|partner|fianc[eé]e?|team|staff|employees?|visitors?|lola|lolo|tita|tito|nanay|tatay|magulang|kapatid|kaibigan|anak|asawa|pamilya)';
const RELS_RE = new RegExp(`^(?:(?:my|our|ang\\s+mga|ang|mga)\\s+)?(${REL})\\b(?:\\s+(?:ko|namin)\\b)?`, 'i');
const SEP_RE = /^\s*(?:,|&|\band\b|\bat\b|\bsi\b|\bsina\b)\s*/i;
const ME_RE = /^(?:me|myself|ako|I)\b/;
// words that start with a capital but are never a person's name
const BLOCK = new Set(['and', 'at', 'si', 'sina', 'kay', 'the', 'my', 'our', 'we', 'me', 'us', 'i', 'it', 'this', 'that', 'there', 'cascade', 'hideaway', 'airbnb', 'general', 'gensan', 'manila', 'davao', 'cebu', 'philippines',
  'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday', 'january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december',
  'grab', 'jollibee', 'facebook', 'marketplace', 'double', 'check', 'mr', 'mrs', 'ms', 'miss', 'dr', 'sir', 'maam', "ma'am", 'ma’am', 'engr', 'atty',
  'christmas', 'new', 'year', 'easter', 'holy', 'week', 'weekend', 'valentine', 'valentines', 'birthday', 'anniversary', 'honeymoon', 'staycation', 'wedding', 'family', 'friends', 'guests', 'guest', 'po', 'hi', 'hello', 'thank', 'thanks', 'please', 'good', 'morning', 'afternoon', 'evening', 'night', 'today', 'tomorrow', 'tonight', 'noon', 'am', 'pm', 'php', 'gcash', 'maya']);
const fold = (s: string) => s.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();
const ME = '\u0000me';

/** A name from the head of `s`: 1-3 capitalised words, none blocked. Null when the head is not a name. */
function nameHead(s: string): string | null {
  const words: string[] = [];
  const re = /^\p{Lu}\p{Ll}[\p{L}'’-]*/u; // a capital then a lower-case letter: ALL-CAPS words and titles (Mr., Ma'am) are not names
  let rest = s;
  while (words.length < 3) {
    const m = re.exec(rest);
    if (!m || BLOCK.has(fold(m[0]))) break;
    words.push(m[0]); rest = rest.slice(m[0].length);
    if (!/^ \p{Lu}/u.test(rest)) break;
    rest = rest.slice(1);
  }
  return words.length ? words.join(' ') : null;
}

type Who = { rels: string[]; names: string[]; me: boolean; rest: string };

/** "my mother", "my friends Ana and Ben", "Ana Cruz, Ben", "me, Ana, Ben" read from the head of `s`; `rest` is what follows. */
function parseWho(s: string, allowMe: boolean): Who {
  let rest = s.trim();
  const rels: string[] = [], names: string[] = []; let me = false;
  for (;;) {
    const m = RELS_RE.exec(rest);
    if (!m) break;
    rels.push(m[1].toLowerCase()); rest = rest.slice(m[0].length);
    const sep = SEP_RE.exec(rest);
    if (!sep || !RELS_RE.test(rest.slice(sep[0].length))) break;
    rest = rest.slice(sep[0].length);
  }
  rest = rest.replace(/^\s+/, '');
  for (;;) {
    let item: string | null = null, len = 0;
    const mm = allowMe ? ME_RE.exec(rest) : null;
    if (mm) { item = ME; len = mm[0].length; } else { const n = nameHead(rest); if (n) { item = n; len = n.length; } }
    if (!item) break;
    if (item === ME) me = true; else names.push(item);
    rest = rest.slice(len);
    const sep = SEP_RE.exec(rest);
    if (!sep || !sep[0].trim()) break; // a list needs a real separator
    const after = rest.slice(sep[0].length);
    if (!(allowMe && ME_RE.test(after)) && !nameHead(after)) break;
    rest = after;
  }
  return { rels, names, me, rest };
}

const TAIL = /^\s*(?:$|[,.;!:)]|(?:who|from|on|in|for|po|please|pls|next|this|that|during|to|so|since|because|as|with|kasi|dahil)\b)/i;
const STAY_CUE = /^\s*(?:(?:will|would|are|is|going\s+to)\s+(?:be\s+|the\s+ones?\s+(?:who\s+)?(?:will\s+be\s+)?)?(?:staying|stay|checking[\s-]*in|the\s+guests?)|(?:ang\s+)?(?:mag-?stay|tutuloy|titira|matutulog))\b/i;
const STAY_TAIL = /^\s*(?:$|[,.;!]|(?:with\s+(?:me|us)|there|here|too|also|po|(?:at|in)\s+(?:your|cascade)|(?:at|in)\s+the\s+(?:place|unit|house|condo|cascade|hideaway)|on|from|for|during|starting|until|then|so|but)\b)/i;
const NEGATION = /\b(?:not|never|won'?t|wont|don'?t|isn'?t|aren'?t|no\s+one|hindi|wala|cancel(?:led)?)\b/i;
const HEDGE = /\b(?:if|maybe|might|perhaps|baka|kung|siguro|sana|not\s+sure|depends?)\b/i; // hypothetical, not a statement
const REPORTED = /\b(?:said|told|sabi|sinabi)\b/i; // someone else's words, someone else's relatives
const BOOKING = /\b(?:book(?:ing|ed)?|reserv(?:ation|ed|ing)|pa-?book)\b/i;

function fromSentence(s: string): Who | null {
  // 1. "booking for my mother Rosa", "it is for my friend Ana and Ben", "I booked this for my parents"
  const a = /\b(?:book(?:ing|ed)?|reserv(?:ation|ed|ing)|(?:it|this|that)(?:\s+is|['’]s))\b[^.!?\n]{0,30}?\bfor\s+(.+)$/i.exec(s);
  if (a) { const w = parseWho(a[1], false); if ((w.rels.length || w.names.length) && TAIL.test(w.rest)) return w; }
  // 2. Taglish "pa-book po para kay Rosa", "para sa nanay ko"
  const p = /\bpara\s+(?:kay|kina|sa)\s+(.+)$/i.exec(s);
  if (p && BOOKING.test(s)) { const w = parseWho(p[1], false); if ((w.rels.length || w.names.length) && TAIL.test(w.rest)) return w; }
  // 3. "my parents will be staying", "my friends Ana and Ben are checking in", "ang mga magulang ko ang mag-stay"
  for (const m of s.matchAll(/\b[\p{L}-]+/gu)) {
    const i = m.index ?? 0;
    if (/['’]s\s+$/.test(s.slice(Math.max(0, i - 4), i)) || /\b(?:her|his|their|your|its)\s+$/i.test(s.slice(Math.max(0, i - 7), i))) continue; // "my wife's parents": whose parents is not clear
    const w = parseWho(s.slice(i), false);
    if (!w.rels.length) continue;
    const c = STAY_CUE.exec(w.rest);
    if (c && STAY_TAIL.test(w.rest.slice(c[0].length))) return w;
  }
  // 4. "we are 3: me, Ana, Ben", "kasama ko si Ana at Ben"
  const g = /\b(?:we(?:['’]re|\s+are|\s+will\s+be)|there\s+(?:are|will\s+be)|kami\s+ay)\s+(\d{1,2})(?:\s*(?:pax|persons?|people|guests?|in\s+total|of\s+us))?\s*(?::|-|\(|,|\bwhich\s+(?:are|is)\b|\bnamely\b)\s*(.+)$/i.exec(s);
  if (g) { const w = parseWho(g[2], true); if (w.names.length && TAIL.test(w.rest)) return w; }
  const k = /\bkasama\s+(?:ko|namin)\s+(?:si|sina)\s+(.+)$/i.exec(s);
  if (k) { const w = parseWho(k[1], false); if (w.names.length && TAIL.test(w.rest)) return { ...w, me: true }; }
  return null;
}

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

/** The suggested "who is staying" text for one stay, or null. `booker` is the Airbnb booker's name (used for "me" and "parents of ..."). */
export function stayingSuggestion(text: unknown, booker?: string | null): string | null {
  const found = new Set<string>();
  const own = String(booker ?? '').trim();
  for (const raw of String(text ?? '').slice(0, 2000).split(/(?<=[.!?])\s+|\n+/)) {
    const s = raw.trim();
    if (!s || s.includes('?') || NEGATION.test(s) || HEDGE.test(s) || REPORTED.test(s)) continue;
    const w = fromSentence(s);
    if (!w) continue;
    const people = [...(w.me && own ? [own] : []), ...w.names];
    const seen = new Set<string>();
    const names = people.filter((n) => { const f = fold(n); return seen.has(f) ? false : (seen.add(f), true); }).slice(0, MAX_ITEMS);
    const rels = [...new Set(w.rels)];
    let out: string;
    if (w.names.length) out = rels.length ? `${names.join(', ')} (${rels.join(' and ')})` : names.join(', ');
    else if (rels.length) out = cap(rels.join(' and ')) + (own ? ` of ${own.split(/\s+/)[0]}` : '');
    else continue;
    found.add(out);
  }
  if (found.size !== 1) return null; // two different readings of one message: say nothing
  const out = [...found][0];
  return out.length > MAX_SUGGESTION || /[\d@]|https?:|www\./i.test(out) ? null : out;
}
