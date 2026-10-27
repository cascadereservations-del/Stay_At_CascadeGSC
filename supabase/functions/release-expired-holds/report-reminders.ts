// s99 (D-348): phone reminder to send the cleaning report for a turnover that was paid ahead. Source: staff_report_reminders_due_v1 (one row per
// request + still-owed date + stage; owed_dates = every date that payee still owes). One push per payee per run, however many requests, stages and dates.
// Same shape as payout-notices.ts: each row is claimed (staff_report_reminder_claim_v1; a claim older than 1 h is taken over, A1) BEFORE the send, so two overlapping runs
// cannot both send; sent_v1 closes it; release_v1 puts it back only for a transient failure. A permanent refusal or a dead sub closes the row.
// drain() never throws and stops at a deadline. Lock-screen text carries no amount and no guest name: dates only.
import type { PushResult } from '../_shared/C_webpush.ts';
import type { PushMsg, Sub } from './payout-notices.ts';

export type Due = { request_id: string; ref: string; payee_user_id: string; checkout_date: string; stage: number; owed_dates: string[] };
export const BUDGET_MS = 60_000;
export const WORST_ITEM_MS = 40_000; // MAX_SUBS phones x (10 s push + one 10 s retry); a new group starts only if it can finish inside BUDGET_MS and the shared deadline
export const MAX_SUBS = 2;
export const PUSH_TITLE = 'Cleaning report still owed';

export interface Deps {
  nowMs?: () => number;
  /** Absolute epoch ms by which the whole request must be done (shared with the other drains). */
  deadlineMs?: number;
  /** missing = the SQL release is not applied yet (function not found). */
  due(): Promise<{ rows: Due[]; missing?: boolean }>;
  claim(r: Due): Promise<boolean>;
  release(r: Due): Promise<void>;
  sent(r: Due): Promise<void>;
  subs(userId: string): Promise<Sub[]>;
  /** null = VAPID is not configured (nothing is claimed, the rows wait). */
  push: ((s: Sub, m: PushMsg) => Promise<PushResult>) | null;
  deleteSub(id: string): Promise<void>;
  touchSub(id: string): Promise<void>;
  log(msg: string): void;
}
export interface DrainResult { groups: number; sent: number; failed: number }

const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const dm = (d: string) => `${Number(d.slice(8, 10))} ${MON[Number(d.slice(5, 7)) - 1]}`;

export function reminderBody(dates: string[]): string {
  const u = [...new Set(dates)].sort().map(dm);
  if (u.length === 1) return `Paid ahead for ${u[0]}. Please send the cleaning report.`;
  const shown = u.length > 4 ? [...u.slice(0, 4), `${u.length - 4} more`] : u;
  return `Paid ahead for ${shown.slice(0, -1).join(', ')} and ${shown[shown.length - 1]}. Please send the cleaning report for each.`;
}

export async function drain(d: Deps): Promise<DrainResult> {
  const out: DrainResult = { groups: 0, sent: 0, failed: 0 };
  if (!d.push) return out;
  const nowMs = d.nowMs ?? Date.now;
  const stopAt = Math.min(nowMs() + BUDGET_MS, (d.deadlineMs ?? Infinity)) - WORST_ITEM_MS;
  let rows: Due[];
  try {
    const r = await d.due();
    if (r.missing) return out;
    rows = r.rows;
  } catch (e) { d.log(`report reminders: read failed (${String(e).slice(0, 80)})`); return out; }
  // One group per payee: every due row (any request, any stage) is claimed and closed together, ONE push says what is owed.
  const groups = new Map<string, Due[]>();
  for (const r of rows) groups.set(r.payee_user_id, [...(groups.get(r.payee_user_id) ?? []), r]);
  for (const g of groups.values()) {
    if (nowMs() > stopAt) { d.log('report reminders: time budget reached, the rest waits for the next run'); break; }
    out.groups++;
    const mine: Due[] = [];
    try {
      for (const r of g) if (await d.claim(r)) mine.push(r);
      if (!mine.length) continue; // another run owns every row of this payee
      const msg: PushMsg = { title: PUSH_TITLE, body: reminderBody(mine.flatMap((r) => r.owed_dates)), url: './checklist/', tag: 'report-owed' };
      let ok = 0, retry = 0;
      // subs() throws on a database error: that reaches the catch below and puts the claims back (never "no phone").
      for (const s of (await d.subs(g[0].payee_user_id)).slice(0, MAX_SUBS)) {
        try {
          let r = await d.push(s, msg);
          if (!r.ok && r.transient) r = await d.push(s, msg);
          if (r.ok) { ok++; await d.touchSub(s.id); }
          else if (r.gone) await d.deleteSub(s.id);
          else if (r.transient) retry++;
          else d.log(`report reminders: push refused for good (status ${r.status}), closed`);
        } catch { retry++; }
      }
      // Reminders go only to phones holding the `paid` topic. A payee with no live subscription (none, all dead, or refused for good) has the stage
      // marked sent: the Today/Pay "Reports still owed" cards remain. Only a transient failure with no success puts the claims back.
      if (ok > 0 || retry === 0) { for (const r of mine) await d.sent(r); out.sent++; }
      else { for (const r of mine) await d.release(r); out.failed++; }
    } catch (e) {
      out.failed++; d.log(`report reminders: payee ${g[0].payee_user_id.slice(0, 8)} (${String(e).slice(0, 80)})`);
      for (const r of mine) await d.release(r).catch(() => {});
    }
  }
  return out;
}
