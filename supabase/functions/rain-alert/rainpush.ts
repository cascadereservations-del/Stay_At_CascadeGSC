// Lane XS2 (s84): the staff push for rain. Lloyd 2026-10-14: tell every staff phone that holds the `notices` topic whenever rain is forecast at the house within
// the next 3 hours (60% or more); during a brownout the same push says so. This is separate from the Telegram OPS warning in index.ts, which is unchanged.
//   - Quiet hours: none of its own. It runs inside rain-alert, which already answers only between 06:00 and 20:00 Manila.
//   - One push per rain episode: notify-staff-inbox claims rain:<Manila date>:<hour the window starts>. Here a second guard keeps it to one push per 3 hours
//     even when the forecast shifts the start hour (a new window later the same day may buzz again, never inside 3 hours of the last push).
//   - The hours come from the Google Weather call rain-alert already makes (the same key), read fresh: the weather-proxy cache is only refreshed when someone opens
//     the app, so it can be hours old at cron time.
// Pure and injectable: no clock, no network in this file.
export const RAIN_PUSH_THRESHOLD = 60; // % chance
export const RAIN_LOOKAHEAD_H = 3;
export const RAIN_MIN_GAP_MS = 3 * 3_600_000;
const HOUR = 3_600_000;

export type HourProb = { hour: number; prob: number }; // Manila hour of today, precipitation probability %
export type BrownoutRow = { id: string; effective_date: string; effective_time: string | null; duration_hours: number | string | null };

/** Google forecastHours -> today's Manila hours. displayDateTime is already in the location's local time. */
// deno-lint-ignore no-explicit-any
export function hoursFromGoogle(data: any, today: string): HourProb[] {
  const [y, m, d] = today.split('-').map(Number);
  // deno-lint-ignore no-explicit-any
  return ((data?.forecastHours ?? []) as any[])
    .filter((h) => h?.displayDateTime && h.displayDateTime.year === y && h.displayDateTime.month === m && h.displayDateTime.day === d)
    .map((h) => ({ hour: Number(h.displayDateTime.hours ?? 0), prob: Number(h.precipitation?.probability?.percent ?? 0) }));
}

/** The first hour in [now, now + 3 h] whose chance reaches the threshold, and the highest chance across those hours. Null when none does. */
export function pickWindow(hours: HourProb[], nowHour: number): { startHour: number; peakPct: number } | null {
  const inside = hours.filter((h) => h.hour >= nowHour && h.hour <= nowHour + RAIN_LOOKAHEAD_H).sort((a, b) => a.hour - b.hour);
  const wet = inside.filter((h) => h.prob >= RAIN_PUSH_THRESHOLD);
  return wet.length ? { startHour: wet[0].hour, peakPct: Math.max(...wet.map((h) => h.prob)) } : null;
}

/** The brownout whose hours overlap [now, now + 3 h]. A notice with no time covers its whole day; one with a time and no length is taken as 3 hours. */
export function pickBrownout(rows: BrownoutRow[], nowMs: number): string | null {
  for (const r of rows) {
    const t = r.effective_time ? String(r.effective_time).slice(0, 8).padEnd(8, ':00').slice(0, 8) : '00:00:00';
    const start = Date.parse(`${r.effective_date}T${t}+08:00`);
    if (!Number.isFinite(start)) continue;
    const len = r.effective_time ? (Number(r.duration_hours) > 0 ? Number(r.duration_hours) : 3) * HOUR : 24 * HOUR;
    if (start < nowMs + RAIN_LOOKAHEAD_H * HOUR && start + len > nowMs) return r.id;
  }
  return null;
}

export type RainPushDeps = {
  nowMs: () => number;
  manilaDate: string;
  manilaHour: number;
  hours: () => Promise<HourProb[] | null>;
  brownouts: () => Promise<BrownoutRow[]>;
  lastPushAt: () => Promise<string | null>;
  /** POST to notify-staff-inbox; resolves with whether a push went out. */
  send: (body: Record<string, unknown>) => Promise<{ ok: boolean; sent: number }>;
  markPushed: (iso: string) => Promise<void>;
  log: (m: string) => void;
};

/** Never throws: a failure here must not touch the Telegram warning that runs after it. */
export async function runRainPush(d: RainPushDeps): Promise<{ pushed: boolean; skipped?: string }> {
  try {
    const last = await d.lastPushAt();
    if (last && d.nowMs() - Date.parse(last) < RAIN_MIN_GAP_MS) return { pushed: false, skipped: 'within_3h_of_last_push' };
    const hours = await d.hours();
    if (!hours) return { pushed: false, skipped: 'no_forecast' };
    const w = pickWindow(hours, d.manilaHour);
    if (!w) return { pushed: false, skipped: 'below_threshold' };
    const brownout = pickBrownout(await d.brownouts(), d.nowMs());
    const body: Record<string, unknown> = { kind: 'rain', from: `${d.manilaDate}T${String(w.startHour).padStart(2, '0')}:00`, peak_pct: w.peakPct };
    if (brownout) body.brownout_notice_id = brownout;
    const r = await d.send(body);
    if (r.ok && r.sent > 0) await d.markPushed(new Date(d.nowMs()).toISOString());
    return { pushed: r.ok && r.sent > 0 };
  } catch (e) {
    d.log(`rain push failed ${String(e).slice(0, 120)}`);
    return { pushed: false, skipped: 'error' };
  }
}
