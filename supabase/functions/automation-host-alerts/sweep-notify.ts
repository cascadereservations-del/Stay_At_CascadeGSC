// D-218 (Lloyd 2026-09-23): CH-W04 used to post "ANOMALIES FOUND" every morning for the same stuck rows
// (three dead internal rows, five days running). Now it speaks when the set of problem rows is new or
// different from the last one it reported, and once a week on Monday as the standing reminder.
export function sweepShouldNotify(total: number, signature: string, lastSignature: string | null,
                                  manilaWeekday: number): boolean {
  if (total === 0) return false;
  return signature !== (lastSignature ?? '') || manilaWeekday === 1;
}

/** Order-independent fingerprint of the anomaly ids, so no row id is stored in app_settings. */
export async function sweepSignature(ids: string[]): Promise<string> {
  const data = new TextEncoder().encode([...ids].sort().join(','));
  const hash = await crypto.subtle.digest('SHA-256', data);
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export const manilaWeekday = (now: Date = new Date()): number =>
  new Date(now.getTime() + 8 * 3600_000).getUTCDay();
