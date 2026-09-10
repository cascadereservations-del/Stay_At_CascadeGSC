export interface FeedHorizonEvent {
  uid: string;
  checkout: string;
}

export interface ReapCandidate {
  id: string;
  uid: string;
  checkin_date: string;
}

export interface HorizonClassification<T extends ReapCandidate> {
  feedHorizon: string;
  horizonGuard: string | null;
  horizonSkipped: number;
  rowsToReap: T[];
}

const DAY_MS = 86_400_000;

export function classifyMissingAirbnbRows<T extends ReapCandidate>(
  events: FeedHorizonEvent[],
  upcoming: T[],
): HorizonClassification<T> {
  const uidsInFeed = new Set(events.map((event) => event.uid));
  const missing = upcoming.filter((row) => !uidsInFeed.has(row.uid));
  const feedHorizon = events.reduce(
    (max, event) => event.checkout && event.checkout > max ? event.checkout : max,
    '',
  );

  // An empty or invalid horizon is unexpected after parseIcal. Fail closed instead of
  // cancelling every missing row against an incomplete provider response.
  const horizonDate = feedHorizon ? new Date(`${feedHorizon}T00:00:00Z`) : null;
  if (!horizonDate || Number.isNaN(horizonDate.getTime())) {
    return {
      feedHorizon,
      horizonGuard: null,
      horizonSkipped: missing.length,
      rowsToReap: [],
    };
  }

  const horizonGuard = new Date(horizonDate.getTime() - 2 * DAY_MS).toISOString().slice(0, 10);
  const rowsToReap: T[] = [];
  let horizonSkipped = 0;

  for (const row of missing) {
    if (!row.checkin_date || row.checkin_date >= horizonGuard) {
      horizonSkipped++;
    } else {
      rowsToReap.push(row);
    }
  }

  return { feedHorizon, horizonGuard, horizonSkipped, rowsToReap };
}
