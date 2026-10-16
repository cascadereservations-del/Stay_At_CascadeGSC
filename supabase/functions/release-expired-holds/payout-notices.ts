// s89: drains public.staff_payout_change_notices (written by save_staff_details_v1 when a payout QR or bank name really changes).
// finance_text -> the Finance Telegram group (never OPS, D-306); staff_text -> that person's phones holding the `paid` topic (Web Push).
// Each channel is stamped on its own (finance_sent_at / staff_sent_at), so a failure on one channel or one row never blocks the others, and
// drain() never throws: it runs after release-expired-holds' own job. A table that does not exist yet (42P01) is skipped silently.
// Lock-screen text carries no QR, account number or amount: the rows hold first names only.
import type { PushResult } from '../_shared/C_webpush.ts';

export type Sub = { id: string; endpoint: string; p256dh: string; auth: string };
export type Notice = { id: string; user_id: string; finance_text: string; staff_text: string; finance_sent_at: string | null; staff_sent_at: string | null };
export type PushMsg = { title: string; body: string; url: string; tag: string };
export const BATCH = 20;
export const PUSH_TITLE = 'Your payout details changed';

export interface Deps {
  now: () => string;
  /** Unsent rows, oldest first, at most `limit`. missing = the table is not there yet. */
  unsent(limit: number): Promise<{ rows: Notice[]; missing?: boolean }>;
  stamp(id: string, col: 'finance_sent_at' | 'staff_sent_at', at: string): Promise<void>;
  /** null = Finance Telegram is not configured (nothing is stamped, the row waits). */
  sendFinance: ((text: string) => Promise<boolean>) | null;
  subs(userId: string): Promise<Sub[]>;
  /** null = VAPID is not configured (nothing is stamped, the row waits). */
  push: ((s: Sub, m: PushMsg) => Promise<PushResult>) | null;
  deleteSub(id: string): Promise<void>;
  touchSub(id: string): Promise<void>;
  log(msg: string): void;
}
export interface DrainResult { rows: number; finance: number; staff: number; failed: number }

export async function drain(d: Deps): Promise<DrainResult> {
  const out: DrainResult = { rows: 0, finance: 0, staff: 0, failed: 0 };
  let rows: Notice[];
  try {
    const r = await d.unsent(BATCH);
    if (r.missing) return out;
    rows = r.rows;
  } catch (e) { d.log(`payout notices: read failed (${String(e).slice(0, 80)})`); return out; }
  for (const n of rows) {
    out.rows++;
    try {
      if (!n.finance_sent_at && d.sendFinance) {
        if (await d.sendFinance(n.finance_text)) { await d.stamp(n.id, 'finance_sent_at', d.now()); out.finance++; } else out.failed++;
      }
    } catch (e) { out.failed++; d.log(`payout notices: finance ${n.id.slice(0, 8)} (${String(e).slice(0, 80)})`); }
    try {
      if (!n.staff_sent_at && d.push) {
        const subs = await d.subs(n.user_id);
        let sent = 0, retry = 0;
        for (const s of subs) {
          const m = { title: PUSH_TITLE, body: n.staff_text, url: './#home', tag: 'cascade-payout-change' };
          try {
            let r = await d.push(s, m);
            if (!r.ok && r.transient) r = await d.push(s, m);
            if (r.ok) { sent++; await d.touchSub(s.id); } else if (r.gone) await d.deleteSub(s.id); else retry++;
          } catch { retry++; }
        }
        // No phone holds the topic (or all were dead): nothing to deliver, so the row is closed. A phone that only failed transiently keeps it open.
        if (sent > 0 || retry === 0) { await d.stamp(n.id, 'staff_sent_at', d.now()); out.staff++; } else out.failed++;
      }
    } catch (e) { out.failed++; d.log(`payout notices: staff ${n.id.slice(0, 8)} (${String(e).slice(0, 80)})`); }
  }
  return out;
}
