// s89: drains public.staff_payout_change_notices (written by save_staff_details_v1 when a payout QR or bank name really changes).
// finance_text -> the Finance Telegram group (never OPS, D-306); staff_text -> that person's phones holding the `paid` topic (Web Push).
// Each channel is claimed by an update BEFORE it is sent (at most once: two overlapping runs cannot both send), and the claim is put back to null
// only when the send is worth retrying (a transient answer or a throw). A permanent refusal is logged and the channel stays closed, so a poisoned
// row cannot repeat every hour. drain() never throws and stops at a deadline: it runs after release-expired-holds' own job.
// A table that does not exist yet (42P01) is skipped silently. Lock-screen text carries no QR, account number or amount (rows hold first names only).
import type { PushResult } from '../_shared/C_webpush.ts';

export type Sub = { id: string; endpoint: string; p256dh: string; auth: string };
export type Notice = { id: string; user_id: string; finance_text: string; staff_text: string; finance_sent_at: string | null; staff_sent_at: string | null };
export type PushMsg = { title: string; body: string; url: string; tag: string };
export type Col = 'finance_sent_at' | 'staff_sent_at';
export type FinanceResult = 'sent' | 'retry' | 'permanent';
export const BATCH = 10;
export const BUDGET_MS = 45_000;
export const WORST_ITEM_MS = 55_000; // Finance send 15 s + MAX 2 phones x (10 s push + one 10 s retry); ML-24: no new row after deadlineMs - this
export const PUSH_TITLE = 'Your payout details changed';

export interface Deps {
  now: () => string;
  nowMs?: () => number;
  /** Absolute epoch ms by which the whole request must be done (shared with the other drains); a new row starts only if a worst-case row still fits. */
  deadlineMs?: number;
  /** Unsent rows (created in the last 7 days), oldest first, at most `limit`. missing = the table is not there yet. */
  unsent(limit: number): Promise<{ rows: Notice[]; missing?: boolean }>;
  /** update ... set col = at where id = id and col is null; true when a row came back (this run owns the send). */
  claim(id: string, col: Col, at: string): Promise<boolean>;
  /** set col back to null where col = at (only the owner of that claim can undo it). */
  release(id: string, col: Col, at: string): Promise<void>;
  /** null = Finance Telegram is not configured (nothing is claimed, the row waits). */
  sendFinance: ((text: string) => Promise<FinanceResult>) | null;
  subs(userId: string): Promise<Sub[]>;
  /** null = VAPID is not configured (nothing is claimed, the row waits). */
  push: ((s: Sub, m: PushMsg) => Promise<PushResult>) | null;
  deleteSub(id: string): Promise<void>;
  touchSub(id: string): Promise<void>;
  log(msg: string): void;
}
export interface DrainResult { rows: number; finance: number; staff: number; failed: number }

export async function drain(d: Deps): Promise<DrainResult> {
  const out: DrainResult = { rows: 0, finance: 0, staff: 0, failed: 0 };
  const nowMs = d.nowMs ?? Date.now;
  const stopAt = Math.min(nowMs() + BUDGET_MS, (d.deadlineMs ?? Infinity) - WORST_ITEM_MS);
  let rows: Notice[];
  try {
    const r = await d.unsent(BATCH);
    if (r.missing) return out;
    rows = r.rows;
  } catch (e) { d.log(`payout notices: read failed (${String(e).slice(0, 80)})`); return out; }
  for (const n of rows) {
    if (nowMs() > stopAt) { d.log('payout notices: time budget reached, the rest waits for the next run'); break; }
    out.rows++;
    if (!n.finance_sent_at && d.sendFinance) {
      const at = d.now();
      let claimed = false;
      try {
        claimed = await d.claim(n.id, 'finance_sent_at', at);
        if (claimed) {
          const r = await d.sendFinance(n.finance_text);
          if (r === 'sent') out.finance++;
          else if (r === 'permanent') { out.failed++; d.log(`payout notices: finance ${n.id.slice(0, 8)} refused for good, closed`); }
          else { out.failed++; await d.release(n.id, 'finance_sent_at', at); }
        }
      } catch (e) {
        out.failed++; d.log(`payout notices: finance ${n.id.slice(0, 8)} (${String(e).slice(0, 80)})`);
        if (claimed) await d.release(n.id, 'finance_sent_at', at).catch(() => {});
      }
    }
    if (!n.staff_sent_at && d.push) {
      const at = d.now();
      let claimed = false;
      try {
        claimed = await d.claim(n.id, 'staff_sent_at', at);
        if (claimed) {
          const subs = await d.subs(n.user_id);
          let sent = 0, retry = 0;
          for (const s of subs) {
            const m = { title: PUSH_TITLE, body: n.staff_text, url: './#home', tag: 'cascade-payout-change' };
            try {
              let r = await d.push(s, m);
              if (!r.ok && r.transient) r = await d.push(s, m);
              if (r.ok) { sent++; await d.touchSub(s.id); }
              else if (r.gone) await d.deleteSub(s.id);
              else if (r.transient) retry++;
              else d.log(`payout notices: push refused for good (status ${r.status}), closed`);
            } catch { retry++; }
          }
          // No phone holds the topic, all were dead or refused for good: nothing more to try, the row stays closed.
          // Only a phone that failed transiently (and none that got it) puts the claim back for the next run.
          if (sent > 0 || retry === 0) out.staff++;
          else { out.failed++; await d.release(n.id, 'staff_sent_at', at); }
        }
      } catch (e) {
        out.failed++; d.log(`payout notices: staff ${n.id.slice(0, 8)} (${String(e).slice(0, 80)})`);
        if (claimed) await d.release(n.id, 'staff_sent_at', at).catch(() => {});
      }
    }
  }
  return out;
}
