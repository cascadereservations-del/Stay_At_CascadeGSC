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
  kwh_per_night?: number | string | null;
  m3_per_night?: number | string | null;
  recorded_at: string;
  meter_flag?: string | null;
  cleaning_sessions?: { cleaning_type?: string | null; checkout_date?: string | null; nights_stayed?: number | null } | null;
};

export type Neighbour = { value: number; key: string; row: MeterRow };
export type Neighbours = {
  prevElec: Neighbour | null; nextElec: Neighbour | null;
  prevWater: Neighbour | null; nextWater: Neighbour | null;
};

const num = (v: unknown) => { const n = Number(v); return v !== null && v !== '' && Number.isFinite(n) && n > 0 ? n : null; };

/** The stay a reading belongs to: its session's check-out date, else the Manila day it was recorded. Never later
 *  than the day it was recorded: a meter cannot be read before its stay ends, so a future check-out (a typo, or a
 *  check-in day's autofill) must not make the reading look like a later stay (Opus review 2026-10-27). */
export function stayKey(row: MeterRow): string {
  const day = new Date(row.recorded_at).toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
  const co = row.cleaning_sessions?.checkout_date;
  return co && /^\d{4}-\d{2}-\d{2}/.test(co) && co.slice(0, 10) < day ? co.slice(0, 10) : day;
}

/** Rows that may be a neighbour: real numbers only (D-219). The page leaves mid-stays out (D-160: never the shown
 *  baseline); the server keeps them, as it always has, so stored deltas chain through a mid-stay and are not
 *  counted twice. */
export function usableRows(rows: MeterRow[] | null | undefined, withMidStay = false): MeterRow[] {
  return (rows ?? []).filter(r =>
    !(r.meter_flag && METER_WRONG_NUMBER_FLAGS.includes(r.meter_flag)) &&
    (withMidStay || r.cleaning_sessions?.cleaning_type !== 'mid_stay'));
}

/** The readings either side of a stay that checked out on `key`. An existing reading for the same day counts as
 *  earlier (the new one is being recorded now). */
export function meterNeighbours(rows: MeterRow[] | null | undefined, key: string, withMidStay = false): Neighbours {
  const sorted = usableRows(rows, withMidStay)
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

/** The later stays' usage, recomputed from this reading: per meter, the row that holds the next electric and the
 *  row that holds the next water number (usually the same row). Empty when nothing changes. */
export function repointNext(n: Neighbours, elec: number | null, water: number | null):
  { id: string; patch: Record<string, number | null> }[] {
  const out = new Map<string, Record<string, number | null>>();
  const one = (nb: Neighbour | null, v: number | null, dp: number, f: ['electric' | 'water', string, string]) => {
    const r = nb?.row;
    if (!r?.id || v === null || !Number.isFinite(v) || v <= 0 || nb!.value < v) return;
    if (num(f[0] === 'electric' ? r.electric_prev : r.water_prev) === v) return;
    const nights = Number(r.cleaning_sessions?.nights_stayed) || 0;
    const delta = Number((nb!.value - v).toFixed(dp));
    const patch = out.get(r.id) ?? {};
    patch[`${f[0]}_prev`] = v; patch[f[1]] = delta;
    patch[f[2]] = nights > 0 ? Number((delta / nights).toFixed(dp)) : null;
    out.set(r.id, patch);
  };
  one(n.nextElec, elec, 2, ['electric', 'electric_delta', 'kwh_per_night']);
  one(n.nextWater, water, 3, ['water', 'water_delta', 'm3_per_night']);
  return [...out].map(([id, patch]) => ({ id, patch }));
}

/** The usage history the 2x anomaly check averages over (2026-10-27). Only rows whose usage covers ONE stay: a row
 *  whose stored previous is not the electric reading of the stay right before it (in stay order, mid-stays
 *  included, as the server chains) still spans a gap a late report has not filled, and would inflate the average
 *  (24 Oct 2026: 86 kWh in one night, measured from 17 Oct). Rows being re-pointed right now are left out too:
 *  their stored numbers are stale. */
export function usageSamples(rows: MeterRow[] | null | undefined, sinceMs: number, skipIds: string[] = []):
  { kwh_per_night: number; m3_per_night: number | null }[] {
  const sorted = usableRows(rows, true)
    .map(r => ({ r, k: stayKey(r) }))
    .sort((a, b) => a.k < b.k ? -1 : a.k > b.k ? 1 : a.r.recorded_at < b.r.recorded_at ? -1 : 1);
  const out: { kwh_per_night: number; m3_per_night: number | null }[] = [];
  let before: number | null = null, beforeKey: string | null = null;
  for (const { r, k: key } of sorted) {
    // A gap shows two ways: the stored previous is not the stay before's reading, or the reading covers more days
    // than the stay's nights plus one quiet day (a report still missing, or a long vacancy: per night is inflated).
    const nights = Number(r.cleaning_sessions?.nights_stayed) || 0;
    const days = beforeKey ? Math.round((Date.parse(key) - Date.parse(beforeKey)) / 86_400_000) : 0;
    const prev = num(r.electric_prev), spansGap = before !== null && (prev !== before || (nights > 0 && days > nights + 1));
    const k = num(r.kwh_per_night);
    if (!spansGap && k !== null && Date.parse(r.recorded_at) >= sinceMs && !(r.id && skipIds.includes(r.id))) {
      const m = Number(r.m3_per_night);
      out.push({ kwh_per_night: k, m3_per_night: r.m3_per_night !== null && r.m3_per_night !== undefined && Number.isFinite(m) ? m : null });
    }
    if (num(r.electric_curr) !== null) { before = num(r.electric_curr); beforeKey = key; }
  }
  return out;
}
