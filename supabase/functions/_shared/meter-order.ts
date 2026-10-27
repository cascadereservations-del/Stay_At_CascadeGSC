// Meter readings in STAY order, not arrival order (Lloyd 2026-10-27).
//
// Reports arrive late and out of order: Honey filed the 17-19 Oct stay on 27 Oct, after the 23-24 Oct stay was
// already on file, and the old "lower than the last reading" rule refused a correct number (4273 < 4326). A
// reading belongs to its stay's check-out date, so it is checked against the stay before it AND the stay after it.
//
// Shared by last-readings (what the checklist compares with) and submit-cleaning (the rule), so the page and the
// server can never disagree about which readings are the neighbours.

/** Flags that mean a stored reading's NUMBERS are wrong, so it is never a neighbour (D-219). */
export const METER_WRONG_NUMBER_FLAGS = ['misread', 're_entry', 'duplicate'];

export type MeterRow = {
  id?: string | null;
  electric_curr: number | string | null;
  water_curr: number | string | null;
  electric_prev?: number | string | null;
  water_prev?: number | string | null;
  recorded_at: string;
  meter_flag?: string | null;
  cleaning_sessions?: { cleaning_type?: string | null; checkout_date?: string | null; nights_stayed?: number | null } | null;
};

export type Neighbour = { value: number; key: string; row: MeterRow };
export type Neighbours = {
  prevElec: Neighbour | null; nextElec: Neighbour | null;
  prevWater: Neighbour | null; nextWater: Neighbour | null;
  /** The first later turnover row, whose usage was computed across this stay and must be re-pointed. */
  next: MeterRow | null;
};

const num = (v: unknown) => { const n = Number(v); return v !== null && v !== '' && Number.isFinite(n) && n > 0 ? n : null; };

/** The stay a reading belongs to: its session's check-out date, else the Manila day it was recorded. */
export function stayKey(row: MeterRow): string {
  const co = row.cleaning_sessions?.checkout_date;
  if (co && /^\d{4}-\d{2}-\d{2}/.test(co)) return co.slice(0, 10);
  return new Date(row.recorded_at).toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
}

/** Rows that may be a neighbour: real numbers, and not a mid-stay (D-160: a mid-stay is never a baseline). */
export function usableRows(rows: MeterRow[] | null | undefined): MeterRow[] {
  return (rows ?? []).filter(r =>
    !(r.meter_flag && METER_WRONG_NUMBER_FLAGS.includes(r.meter_flag)) &&
    r.cleaning_sessions?.cleaning_type !== 'mid_stay');
}

/** The readings either side of a stay that checked out on `key`. An existing reading for the same day counts as
 *  earlier (the new one is being recorded now). */
export function meterNeighbours(rows: MeterRow[] | null | undefined, key: string): Neighbours {
  const sorted = usableRows(rows)
    .map(r => ({ r, k: stayKey(r) }))
    .sort((a, b) => a.k < b.k ? -1 : a.k > b.k ? 1 : a.r.recorded_at < b.r.recorded_at ? -1 : 1);
  const before = sorted.filter(x => x.k <= key), after = sorted.filter(x => x.k > key);
  const pick = (list: typeof sorted, field: 'electric_curr' | 'water_curr', last: boolean): Neighbour | null => {
    const seq = last ? [...list].reverse() : list;
    const hit = seq.find(x => num(x.r[field]) !== null);
    return hit ? { value: num(hit.r[field])!, key: hit.k, row: hit.r } : null;
  };
  return {
    prevElec: pick(before, 'electric_curr', true), nextElec: pick(after, 'electric_curr', false),
    prevWater: pick(before, 'water_curr', true), nextWater: pick(after, 'water_curr', false),
    next: after[0]?.r ?? null,
  };
}

const day = (key: string) => new Date(`${key}T00:00:00+08:00`).toLocaleDateString('en-PH',
  { timeZone: 'Asia/Manila', month: 'short', day: 'numeric' });

/** The refusal, or null. A reading must not be below the stay before it or above the stay after it: a meter does
 *  not run backwards (D-219). A missing number or neighbour never blocks: there is nothing to compare. */
export function meterOrderMessage(elec: number | null, water: number | null, n: Neighbours): string | null {
  const out: string[] = [];
  const check = (label: string, unit: string, v: number | null, p: Neighbour | null, q: Neighbour | null) => {
    if (v === null || !Number.isFinite(v)) return;
    if (p && v < p.value) out.push(`${label} ${v} ${unit} is lower than the reading for the stay that checked out ${day(p.key)} (${p.value})`);
    else if (q && v > q.value) out.push(`${label} ${v} ${unit} is higher than the reading for the later stay that checked out ${day(q.key)} (${q.value})`);
  };
  check('electric', 'kWh', elec, n.prevElec, n.nextElec);
  check('water', 'm³', water, n.prevWater, n.nextWater);
  if (!out.length) return null;
  return [
    `The ${out.join(', and the ')}. A meter does not run backwards, so this report was not sent.`,
    `Check the check-out date first, then read the photo again and type the number exactly as it shows. If both are right, message Lloyd - one of the readings on file is wrong.`,
  ].join(' ');
}

/** The later stay's usage, recomputed from this reading. Null when nothing changes or a number is missing. */
export function repointNext(next: MeterRow | null, elec: number | null, water: number | null):
  Record<string, number | null> | null {
  if (!next?.id) return null;
  const nights = Number(next.cleaning_sessions?.nights_stayed) || 0;
  const patch: Record<string, number | null> = {};
  const one = (v: number | null, curr: unknown, prev: unknown, dp: number, f: [string, string, string]) => {
    const c = num(curr);
    if (v === null || !Number.isFinite(v) || v <= 0 || c === null || c < v || num(prev) === v) return;
    const delta = Number((c - v).toFixed(dp));
    patch[f[0]] = v; patch[f[1]] = delta;
    patch[f[2]] = nights > 0 ? Number((delta / nights).toFixed(dp)) : null;
  };
  one(elec, next.electric_curr, next.electric_prev, 2, ['electric_prev', 'electric_delta', 'kwh_per_night']);
  one(water, next.water_curr, next.water_prev, 3, ['water_prev', 'water_delta', 'm3_per_night']);
  return Object.keys(patch).length ? patch : null;
}
