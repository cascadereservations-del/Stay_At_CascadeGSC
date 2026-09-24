// The Airbnb iCal parser, moved out of index.ts so it can be tested (SPEC-24 section 1).
//
// RFC 5545 folds every content line at 75 octets: the rest continues on the next line after one
// leading space or tab. Airbnb's DESCRIPTION is "Reservation URL: https://www.airbnb.com/hosting/
// reservations/details/HMxxxxxxxx" plus the phone tail, which crosses the fold. Before this file the
// parser read one physical line, so every stored description ended at ".../reservations/de" and the
// confirmation code - the only exact key to airbnb_reservations - was lost (D-225).

export interface ICalEvent { uid: string; checkin: string; checkout: string; summary?: string; description?: string; status: 'confirmed' | 'blocked'; }

export function parseIcal(text: string): ICalEvent[] {
  const unfolded = text.replace(/\r?\n[ \t]/g, '');
  const events: ICalEvent[] = [];
  const blocks = unfolded.split('BEGIN:VEVENT');
  for (let i = 1; i < blocks.length; i++) {
    const block = blocks[i].split('END:VEVENT')[0];
    const uid = extractProp(block, 'UID');
    const dtstart = extractProp(block, 'DTSTART');
    const dtend = extractProp(block, 'DTEND');
    const summary = extractProp(block, 'SUMMARY');
    const description = extractProp(block, 'DESCRIPTION');
    if (!uid || !dtstart || !dtend) continue;
    const checkin = normalizeDate(dtstart);
    const checkout = normalizeDate(dtend);
    if (!checkin || !checkout) continue;
    const lsum = (summary ?? '').toLowerCase();
    const status: 'confirmed' | 'blocked' = lsum.includes('not available') || lsum.includes('blocked') || lsum === '' ? 'blocked' : 'confirmed';
    events.push({ uid, checkin, checkout, summary, description, status });
  }
  return events;
}

export function extractProp(block: string, key: string): string | undefined {
  const re = new RegExp(`^${key}(?:;[^:]+)?:(.+)$`, 'm');
  const m = block.match(re); return m ? m[1].trim() : undefined;
}

export function normalizeDate(val: string): string | null {
  const clean = val.replace(/T.+$/, '').replace(/-/g, '');
  if (clean.length !== 8) return null;
  return `${clean.slice(0,4)}-${clean.slice(4,6)}-${clean.slice(6,8)}`;
}

/** The Airbnb confirmation code in an (unfolded) event description, or null. */
export function confirmationCodeFrom(description?: string | null): string | null {
  const m = (description ?? '').match(/reservations\/details\/([A-Z0-9]{10})\b/);
  return m ? m[1] : null;
}
