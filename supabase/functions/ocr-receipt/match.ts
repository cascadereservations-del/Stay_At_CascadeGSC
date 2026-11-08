// ocr-receipt, supply mode (s110): match a printed receipt line to an active inventory item. Pure: no I/O, match.test.ts covers it.
// Score = Dice overlap of normalised tokens ("TISSUE 2PLY 12S" -> tissue, 2, ply, 12). A word matches on equality, a shared 3+ letter
// prefix (tissue/tissues) or a till abbreviation (wht -> white). Two different sizes on both sides halve the score (500ml is not 1000ml).

export const MATCH_THRESHOLD = 0.5;

export type Candidate = { item_id: string; names: string[] }; // the item's name plus option names
export type Match = { item_id: string | null; score: number };

const NOISE = new Set(['pcs', 'pc', 'pack', 'pk', 'x', 'of', 'the', 'and', 'with', 'for', 'a', 's', 'ea', 'each']);

export function tokens(s: string): string[] {
  return String(s ?? '').toLowerCase().replace(/['’`]/g, '')
    .replace(/(\d)([a-z])/g, '$1 $2').replace(/([a-z])(\d)/g, '$1 $2')
    .split(/[^a-z0-9]+/).filter((t) => t && !NOISE.has(t));
}

const isNum = (t: string) => /^\d+$/.test(t);
const subseq = (a: string, b: string) => { let i = 0; for (const c of b) if (c === a[i]) i++; return i === a.length; };

function same(a: string, b: string): boolean {
  if (a === b) return true;
  if (isNum(a) || isNum(b)) return false;
  const [s, l] = a.length <= b.length ? [a, b] : [b, a];
  if (s.length >= 3 && l.startsWith(s)) return true;
  return s.length >= 3 && s[0] === l[0] && subseq(s, l); // wht -> white
}

export function score(line: string, name: string): number {
  const a = tokens(line), b = tokens(name);
  if (!a.length || !b.length) return 0;
  const used = new Set<number>();
  let common = 0;
  for (const t of a) {
    const j = b.findIndex((u, k) => !used.has(k) && same(t, u));
    if (j >= 0) { used.add(j); common++; }
  }
  let s = (2 * common) / (a.length + b.length);
  const na = new Set(a.filter(isNum)), nb = new Set(b.filter(isNum));
  if (na.size && nb.size && ![...na].some((n) => nb.has(n))) s *= 0.5;
  return s;
}

/** Best item for a line: the highest score over every name of every item; null item when the best is under the threshold. */
export function matchLine(line: string, items: Candidate[], threshold = MATCH_THRESHOLD): Match {
  let best: Match = { item_id: null, score: 0 };
  for (const it of items) for (const n of it.names) {
    const s = score(line, n);
    if (s > best.score) best = { item_id: it.item_id, score: s };
  }
  const score2 = Math.round(best.score * 100) / 100;
  return best.score >= threshold ? { item_id: best.item_id, score: score2 } : { item_id: null, score: score2 };
}
