// cascade-core chains (D-290). One guest, two bookings back to back (checkout of stay 1 = check-in of stay 2) is ONE stay:
// no turnover, no cleaning, no second pre-arrival welcome. The rule itself lives in SQL (stay_chains_v1, stay_continues_v1);
// this file is the read side for edge functions. Every read degrades: a missing or failing RPC logs once and answers
// "no chains", so the caller behaves exactly as it did before D-290.
export type Chain = {
  junction_date: string;
  guest_id?: string | null;
  guest_name: string | null;
  first_uid: string;
  first_source?: string | null;
  first_code: string | null;
  first_checkin: string;
  next_uid: string;
  next_code: string | null;
  next_checkout: string;
};

/** Junctions with junction_date in [from, to]. [] when the RPC is missing or fails. */
export async function fetchChains(db: any, propertyId: string, from: string, to: string): Promise<Chain[]> {
  try {
    const { data, error } = await db.rpc('stay_chains_v1', { p_property_id: propertyId, p_from: from, p_to: to });
    if (error) { console.warn('stay_chains_v1 unavailable:', String(error.message ?? error).slice(0, 160)); return []; }
    return ((data ?? []) as Chain[]).filter((c) => c && c.junction_date && c.first_uid && c.next_uid);
  } catch (e) {
    console.warn('stay_chains_v1 threw:', String(e).slice(0, 160));
    return [];
  }
}

/** True when a chained stay continues across `date` (one guest checks out and in on the same day). false on any failure. */
export async function stayContinues(db: any, propertyId: string, date: string): Promise<boolean> {
  try {
    const { data, error } = await db.rpc('stay_continues_v1', { p_property_id: propertyId, p_date: date });
    if (error) { console.warn('stay_continues_v1 unavailable:', String(error.message ?? error).slice(0, 160)); return false; }
    return data === true;
  } catch (e) {
    console.warn('stay_continues_v1 threw:', String(e).slice(0, 160));
    return false;
  }
}

/** Removes every junction date from the check-in and check-out day sets (in place): no turnover happens on those days. */
export function dropJunctionDays(chains: Chain[], ...daySets: Array<Set<string>>): void {
  for (const c of chains) for (const s of daySets) s.delete(c.junction_date);
}

/** Whole span of the stay a booking belongs to (its own check-in/out given), following junctions both ways. null when in no chain. */
export function chainSpan(uid: string, checkin: string, checkout: string, chains: Chain[]): { start: string; end: string; bookings: number } | null {
  let start = checkin, end = checkout, bookings = 1;
  for (let cur = uid, i = 0; i < 20; i++) {
    const prev = chains.find((c) => c.next_uid === cur);
    if (!prev) break;
    start = prev.first_checkin; bookings++; cur = prev.first_uid;
  }
  for (let cur = uid, i = 0; i < 20; i++) {
    const nxt = chains.find((c) => c.first_uid === cur);
    if (!nxt) break;
    end = nxt.next_checkout; bookings++; cur = nxt.next_uid;
  }
  return bookings > 1 ? { start, end, bookings } : null;
}
