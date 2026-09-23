// D-218 (Lloyd 2026-09-23): the same missing report used to be announced every morning for 14 days
// (Nyke Perez's 2026-09-20 checkout, day after day). Now: the first morning, one reminder on day 3,
// and from day 4 it is one Follow-ups task that closes itself when the report is filed.
export type MissedStep = 'alert' | 'remind' | 'task' | 'silent';

export function missedCleaningStep(daysOverdue: number): MissedStep {
  if (!Number.isFinite(daysOverdue) || daysOverdue <= 1) return 'alert';
  if (daysOverdue === 3) return 'remind';
  if (daysOverdue >= 4) return 'task';
  return 'silent';
}

/** The Manila date `days` before today, as YYYY-MM-DD: the oldest checkout the lookback still reports, so
 *  a task is closed only when its checkout is still inside the window and has stopped being reported. */
export function manilaDateDaysAgo(days: number, now: Date = new Date()): string {
  return new Date(now.getTime() + 8 * 3600_000 - days * 86_400_000).toISOString().slice(0, 10);
}
