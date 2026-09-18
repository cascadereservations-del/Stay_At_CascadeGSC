// SPEC-03 (session 33): the pure parts of the Telegram stock count — which group an item belongs to,
// reading the typed reply, and the before/after review lines. No I/O, unit-tested in count.test.ts.
// index.ts owns the Telegram calls and the RPC.

export type CountItem = { id: string; name: string; unit: string; qty: number; reorder: number | null };
export type CountRow = { is_consumable: boolean; category: string; name: string };

/** B70's three groups, in one place. `handleStockQuery` does not group today and is left alone. */
export function inventoryGroup(row: CountRow): 'consumables' | 'appliances' | 'stores' {
  if (row.is_consumable) return 'consumables';
  if (row.category === 'Kitchen & Dining' || row.name === 'Washing Machine (Panasonic)') return 'appliances';
  return 'stores';
}

export const GROUP_LABEL = { consumables: 'Consumables', appliances: 'Appliances & utensils', stores: 'Stores' } as const;
/** The three buttons Lloyd asked for. "All groups" is every item, numbered straight through. */
export const SCOPE_GROUPS: Record<'1' | '2' | '3', Array<keyof typeof GROUP_LABEL>> = {
  '1': ['consumables'],
  '2': ['stores'],
  '3': ['consumables', 'appliances', 'stores'],
};

/** `2 20`, `7 0`, `12: 3`, `4 = 1.5`, `9-0`. A count of zero is a real answer, never "missing". */
const LINE_RE = /^\s*(\d{1,3})\s*[:=\-]?\s*(\d+(?:\.\d{1,2})?)\s*$/;

export type ParsedCount = {
  changes: Array<{ index: number; counted: number }>;
  unreadable: string[];
  outOfRange: number[];
};

/**
 * Read the reply. Every line is either a change or a complaint: a bad line never discards the good
 * ones, because someone who mistyped line 4 should not have to retype lines 1 to 3.
 * A later line for the same number wins (a correction inside the same message).
 */
export function parseCountReply(text: string, itemCount: number): ParsedCount {
  const byIndex = new Map<number, number>();
  const unreadable: string[] = [];
  const outOfRange: number[] = [];
  for (const raw of String(text ?? '').split(/[\n;,]+/)) {
    const line = raw.trim();
    if (!line) continue;
    const m = LINE_RE.exec(line);
    if (!m) { unreadable.push(line.slice(0, 40)); continue; }
    const index = Number(m[1]);
    if (index < 1 || index > itemCount) { outOfRange.push(index); continue; }
    byIndex.set(index, Number(m[2]));
  }
  return {
    changes: [...byIndex.entries()].sort((a, b) => a[0] - b[0]).map(([index, counted]) => ({ index, counted })),
    unreadable,
    outOfRange,
  };
}

export type Change = { item_id: string; name: string; unit: string; before: number; counted: number; reorder: number | null };

/** Only a line that actually moves the number is a change; re-typing the same count is a no-op. */
export function changesFrom(items: CountItem[], parsed: ParsedCount): Change[] {
  const out: Change[] = [];
  for (const { index, counted } of parsed.changes) {
    const it = items[index - 1];
    if (!it || it.qty === counted) continue;
    out.push({ item_id: it.id, name: it.name, unit: it.unit, before: it.qty, counted, reorder: it.reorder });
  }
  return out;
}

const num = (n: number) => String(n);

/** "• Coffee (3-in-1): 28 → 20 pc  (−8)" with a flag when the new figure is at or under the reorder point. */
export function reviewLines(changes: Change[]): string[] {
  return changes.map((c) => {
    const d = c.counted - c.before;
    const delta = `${d > 0 ? '+' : '−'}${num(Math.abs(d))}`;
    const low = c.reorder !== null && c.counted <= c.reorder ? '  🔴 below reorder' : '';
    return `• ${c.name}: ${num(c.before)} → ${num(c.counted)} ${c.unit}  (${delta})${low}`;
  });
}

/** The numbered list the person counts against. */
export function numberedCountLines(items: CountItem[], startAt = 1): string[] {
  return items.map((it, i) => ` ${startAt + i}. ${it.name} — ${num(it.qty)} ${it.unit}`);
}

/** Split lines into messages that stay under Telegram's 4,096-character limit. */
export function chunkLines(lines: string[], limit = 3500): string[] {
  const out: string[] = [];
  let buf = '';
  for (const l of lines) {
    if (buf && buf.length + l.length + 1 > limit) { out.push(buf); buf = ''; }
    buf = buf ? buf + '\n' + l : l;
  }
  if (buf) out.push(buf);
  return out;
}
