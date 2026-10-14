// inventory-report / report.ts (s84 lane I-fn): the report rows, pure. No I/O, no clock of its own.
// OPS and Finance are two different row builders, not one masked copy: the OPS builders never receive a cost, price, value or total
// (D-306), and the handler does not even select the cost columns for an OPS send.
import { maskMoney } from '../_shared/ops-money.ts';
import { redactForLog } from '../_shared/redaction.ts';

export type Kind = 'order' | 'all' | 'consumables' | 'low' | 'misc';
export type Dest = 'finance' | 'ops';
export const KINDS: readonly Kind[] = ['order', 'all', 'consumables', 'low', 'misc'];

export interface Item {
  id: string; name: string; category: string | null; unit: string | null;
  qty: number; reorder: number | null; par: number | null; consumable: boolean;
  purchaseUnit: string | null; unitsPer: number | null;
  /** Only ever set on the Finance path. */
  cost?: number | null;
}
export interface Shop {
  itemId: string | null; name: string; quantity: number; purchaseUnit: string | null; note: string | null;
  /** Only ever set on the Finance path. */
  estCost?: number | null;
}
export interface Group { heading: string; rows: string[][] }
export interface Report {
  kind: Kind; dest: Dest; title: string; subtitle: string; financeLine: string | null;
  columns: string[]; widths: number[]; groups: Group[]; totals: string[]; caption: string;
  rowCount: number; filename: string; empty: string | null;
}

const TITLES: Record<Kind, string> = { order: 'Order list', all: 'All items', consumables: 'Consumables', low: 'Low stock', misc: 'Miscellaneous items' };
const CAPTION_NAMES: Record<Kind, string> = { order: 'Order list', all: 'Full inventory', consumables: 'Consumables list', low: 'Low stock list', misc: 'Miscellaneous items' };

// ---------- small formatters ----------
export const num = (n: number): string => String(Math.round(n * 100) / 100);
export const money = (n: number): string => 'PHP ' + n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** "15 Oct 2026, 12:30 pm" in Manila time (UTC+8, no daylight saving). */
export function manilaStamp(now: Date): string {
  const m = new Date(now.getTime() + 8 * 3600_000);
  const h = m.getUTCHours();
  return `${m.getUTCDate()} ${MONTHS[m.getUTCMonth()]} ${m.getUTCFullYear()}, ${h % 12 || 12}:${String(m.getUTCMinutes()).padStart(2, '0')} ${h < 12 ? 'am' : 'pm'}`;
}
export function manilaDate(now: Date): string {
  return new Date(now.getTime() + 8 * 3600_000).toISOString().slice(0, 10);
}

/** Contacts out of any staff-facing text: e-mail, phone numbers (also spaced), door codes, addresses. Item names use only this. */
export function contactSafe(text: unknown, route: 'ops' | 'finance' = 'ops'): string {
  const t = String(text ?? '').replace(/\s+/g, ' ').trim()
    .replace(/\+?\d[\d\s().-]{6,}\d/g, (m) => (/^\s*\d{1,4}[\s-]\d{1,2}[\s-]\d{1,4}\s*$/.test(m) ? m : '[number hidden]'));
  return redactForLog(t, route);
}
/** Free text (shopping-list notes): contacts redacted, then every amount masked. Not for item names: it would eat "Item 119". */
export const opsText = (text: unknown): string => maskMoney(contactSafe(text));

// ---------- item logic ----------
export type Status = 'OUT' | 'LOW' | 'OK';
export const statusOf = (i: Item): Status => (i.qty <= 0 ? 'OUT' : i.reorder != null && i.qty <= i.reorder ? 'LOW' : 'OK');
const rank = (s: Status) => (s === 'OUT' ? 0 : s === 'LOW' ? 1 : 2);
const byName = (a: Item, b: Item) => a.name.localeCompare(b.name, 'en', { sensitivity: 'base' });
const byLevel = (a: Item, b: Item) => rank(statusOf(a)) - rank(statusOf(b)) || byName(a, b);
const catOf = (i: { category: string | null }) => contactSafe((i.category ?? '').trim()) || 'Other';
const isMisc = (i: Item) => catOf(i).toLowerCase() === 'miscellaneous';

/** Buy up to par, else twice the reorder level; whole packs, at least one pack for an item that is on the list. */
export function buyPlan(i: Item): { packs: number; units: number; target: number; label: string } {
  const target = i.par ?? (i.reorder != null ? i.reorder * 2 : 0);
  const per = i.unitsPer && i.unitsPer > 0 ? i.unitsPer : 1;
  const packs = Math.max(1, Math.ceil(Math.max(target - i.qty, 0) / per));
  const word = contactSafe(i.purchaseUnit?.trim() || (per > 1 ? 'pack' : (i.unit?.trim() || 'pc')));
  return { packs, units: packs * per, target, label: `${num(packs)} ${word}` };
}

function grouped<T>(rows: T[], cat: (r: T) => string, cmpGroup: (a: string, b: string) => number = (a, b) => a.localeCompare(b, 'en', { sensitivity: 'base' })): Array<[string, T[]]> {
  const m = new Map<string, T[]>();
  for (const r of rows) { const c = cat(r); (m.get(c) ?? m.set(c, []).get(c)!).push(r); }
  return [...m.entries()].sort((a, b) => cmpGroup(a[0], b[0]));
}

// ---------- columns ----------
const OPS_COLS: Record<Kind, [string[], number[]]> = {
  order: [['Item', 'On hand', 'Target', 'Buy', 'Note'], [0.36, 0.11, 0.11, 0.14, 0.28]],
  all: [['Item', 'On hand', 'Reorder at', 'Status'], [0.5, 0.15, 0.2, 0.15]],
  consumables: [['Item', 'On hand', 'Reorder at', 'Status'], [0.5, 0.15, 0.2, 0.15]],
  low: [['Item', 'On hand', 'Reorder at', 'Status'], [0.5, 0.15, 0.2, 0.15]],
  misc: [['Item', 'On hand', 'Unit', 'Note'], [0.4, 0.14, 0.14, 0.32]],
};
const FIN_COLS: Record<Kind, [string[], number[]]> = {
  order: [['Item', 'On hand', 'Target', 'Buy', 'Unit cost', 'Est. cost', 'Note'], [0.24, 0.08, 0.08, 0.1, 0.14, 0.15, 0.21]],
  all: [['Item', 'On hand', 'Reorder at', 'Status', 'Unit cost', 'Value'], [0.34, 0.11, 0.13, 0.1, 0.16, 0.16]],
  consumables: [['Item', 'On hand', 'Reorder at', 'Status', 'Unit cost', 'Value'], [0.34, 0.11, 0.13, 0.1, 0.16, 0.16]],
  low: [['Item', 'On hand', 'Reorder at', 'Status', 'Unit cost'], [0.38, 0.13, 0.15, 0.12, 0.22]],
  misc: [['Item', 'On hand', 'Unit', 'Unit cost', 'Value', 'Note'], [0.28, 0.1, 0.1, 0.16, 0.16, 0.2]],
};

const cost = (n: number | null | undefined) => (n == null ? '-' : money(n));

/** One row's cells, in the column order of its kind and destination. Finance cells only appear when dest is 'finance'. */
function cells(kind: Kind, dest: Dest, i: Item, note: string, plan?: ReturnType<typeof buyPlan>, shopQty?: string): string[] {
  const fin = dest === 'finance';
  const unitCost = fin ? i.cost ?? null : null;
  const name = contactSafe(i.name);
  const on = num(i.qty), re = i.reorder == null ? '-' : num(i.reorder), st = statusOf(i);
  switch (kind) {
    case 'order': {
      const tgt = plan ? num(plan.target) : '-';
      const buy = shopQty ?? plan?.label ?? '-';
      const est = plan && unitCost != null ? unitCost * plan.units : null;
      return fin ? [name, on, tgt, buy, cost(unitCost), cost(est), note] : [name, on, tgt, buy, note];
    }
    case 'misc': {
      const unit = contactSafe(i.unit?.trim() || '-');
      return fin ? [name, on, unit, cost(unitCost), cost(unitCost == null ? null : unitCost * i.qty), note] : [name, on, unit, note];
    }
    case 'low':
      return fin ? [name, on, re, st, cost(unitCost)] : [name, on, re, st];
    default:
      return fin ? [name, on, re, st, cost(unitCost), cost(unitCost == null ? null : unitCost * i.qty)] : [name, on, re, st];
  }
}

// ---------- the builder ----------
export function buildReport(kind: Kind, dest: Dest, items: Item[], shop: Shop[], now: Date, who: string): Report {
  const fin = dest === 'finance';
  const [columns, widths] = (fin ? FIN_COLS : OPS_COLS)[kind];
  let groups: Group[] = [];
  const totals: string[] = [];
  let rowCount = 0;
  const noteText = (t: unknown) => (fin ? contactSafe(t, 'finance') : opsText(t)); // Finance keeps amounts in notes, contacts still go
  let noPrice = 0;
  let sum = 0;

  const withCost = (i: Item) => { if (fin) { if (i.cost == null) noPrice++; } };

  if (kind === 'order') {
    const need = items.filter((i) => i.consumable && ((i.reorder != null && i.qty <= i.reorder) || (i.par != null && i.qty < i.par)));
    const covered = new Set(need.map((i) => i.id));
    const noteFor = new Map<string, string>();
    for (const s of shop) if (s.itemId && covered.has(s.itemId) && s.note) noteFor.set(s.itemId, noteText(s.note));
    const rows: Array<{ cat: string; level: number; name: string; cells: string[] }> = [];
    for (const i of need) {
      const plan = buyPlan(i);
      withCost(i);
      if (fin && i.cost != null) sum += i.cost * plan.units;
      rows.push({ cat: catOf(i), level: rank(statusOf(i)), name: i.name, cells: cells('order', dest, i, noteFor.get(i.id) ?? '', plan) });
    }
    const byId = new Map(items.map((i) => [i.id, i]));
    for (const s of shop) {
      if (s.itemId && covered.has(s.itemId)) continue;
      const it = s.itemId ? byId.get(s.itemId) : undefined;
      const base: Item = it ?? { id: '', name: s.name, category: null, unit: null, qty: 0, reorder: null, par: null, consumable: false, purchaseUnit: s.purchaseUnit, unitsPer: null };
      const qtyLabel = `${num(s.quantity)} ${contactSafe(s.purchaseUnit?.trim() || it?.unit?.trim() || 'pc')}`;
      const est = fin ? s.estCost ?? (it?.cost != null ? it.cost * s.quantity * (it.unitsPer && it.unitsPer > 0 && s.purchaseUnit ? it.unitsPer : 1) : null) : null;
      if (fin) { if (est == null) noPrice++; else sum += est; }
      const row = cells('order', dest, { ...base, name: s.name, cost: fin ? it?.cost ?? null : undefined }, noteText(s.note ?? ''), undefined, qtyLabel);
      if (fin) row[5] = cost(est);
      rows.push({ cat: it ? catOf(it) : 'Shopping list', level: 1, name: s.name, cells: row });
    }
    groups = grouped(rows, (r) => r.cat).map(([heading, rs]) => ({
      heading, rows: rs.sort((a, b) => a.level - b.level || a.name.localeCompare(b.name, 'en', { sensitivity: 'base' })).map((r) => r.cells),
    }));
    rowCount = rows.length;
    if (fin) totals.push(`Estimated total ${money(sum)}`);
  } else if (kind === 'misc') {
    const list = items.filter(isMisc).sort(byName);
    for (const i of list) { withCost(i); if (fin && i.cost != null) sum += i.cost * i.qty; }
    groups = list.length ? [{ heading: 'Miscellaneous', rows: list.map((i) => cells('misc', dest, i, '')) }] : [];
    rowCount = list.length;
    if (fin && list.length) totals.push(`Total value ${money(sum)}`);
  } else {
    const list = kind === 'all' ? items : kind === 'consumables' ? items.filter((i) => i.consumable) : items.filter((i) => i.reorder != null && i.qty <= i.reorder);
    for (const i of list) { withCost(i); if (fin && i.cost != null) sum += i.cost * i.qty; }
    const cmp = kind === 'low' ? byLevel : byName;
    groups = grouped(list, catOf).map(([heading, rs]) => ({ heading, rows: rs.sort(cmp).map((i) => cells(kind, dest, i, '')) }));
    rowCount = list.length;
    if (fin && kind !== 'low' && list.length) totals.push(`Total value ${money(sum)}`);
  }
  if (fin && noPrice > 0 && rowCount > 0) totals.push(`${noPrice} ${noPrice === 1 ? 'item has' : 'items have'} no price.`);

  const first = who.trim().split(/\s+/)[0] || 'the team'; // an unknown name reads "by the team"
  const caption = `${CAPTION_NAMES[kind]}, ${rowCount} ${rowCount === 1 ? 'item' : 'items'}. Sent from the staff app by ${first}.`;
  return {
    kind, dest, title: `Cascade Hideaway - ${TITLES[kind]}`, subtitle: `Made ${manilaStamp(now)} Manila time by ${first}`,
    financeLine: fin ? 'Finance copy - prices included' : null,
    columns, widths, groups, totals, caption: caption.slice(0, 200), rowCount,
    filename: `cascade-${kind}-${manilaDate(now)}.pdf`,
    empty: rowCount === 0 ? (kind === 'low' || kind === 'order' ? 'Nothing to list today. Every item is above its reorder level.' : 'Nothing to list today.') : null,
  };
}
