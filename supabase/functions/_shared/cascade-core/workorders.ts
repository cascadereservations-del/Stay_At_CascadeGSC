// cascade-core work orders (Telegram plan §6, session 26, 2026-09-16, D-160).
// One entry point for "something is wrong with the unit": a cleaner's [URGENT] note or a Messenger
// complaint/safety handoff. The record is the work_orders row (raise_work_order_v1, idempotent on
// source_kind + source_ref); the OPS card is advisory and carries a lite-tier suggestion. Nothing
// here messages a guest. work_orders is revoked from service_role, so the RPC is the only write.
// ponytail: the suggestion is one cheap JSON call with no retries; a failed suggestion still sends
// the card. Add a fixed lookup table of common issues when the model output proves unstable.
import { chatJson } from './providers.ts';
import { withHeader, groups, TEMPLATE_MARK, type HeaderKind } from './format.ts';

export const PROPERTY_ID = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';

export type RaiseArgs = {
  sourceKind: 'cleaning_issue' | 'guest_report';
  sourceRef: string;                 // cleaning_session:<id>:<n> | concierge_handoff:<id>
  title: string;                     // the issue, verbatim, trimmed to 200
  detail: string;                    // who reported it and when
  priority: 'low' | 'normal' | 'high' | 'urgent';
  reporter?: string;                 // Honey / guest name, for the card
  guestName?: string;                // whose stay it followed, for the card
};
export type Raised = { id: string; created: boolean; blocks_arrival: boolean; next_guest?: string | null; next_checkin?: string | null };

type Db = { rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: { message: string } | null }> };

export async function raiseWorkOrder(db: Db, a: RaiseArgs): Promise<Raised | null> {
  const { data, error } = await db.rpc('raise_work_order_v1', {
    p_property_id: PROPERTY_ID, p_source_kind: a.sourceKind, p_source_ref: a.sourceRef,
    p_title: a.title.slice(0, 200), p_detail: a.detail, p_priority: a.priority,
  });
  if (error) { console.warn('raise_work_order_v1 failed (non-fatal):', error.message); return null; }
  return (data ?? null) as Raised | null;
}

const SYSTEM = `You advise the operations team of Cascade Hideaway, a one-unit Airbnb in General Santos City. A problem with the unit was just reported. Answer as JSON {"action": "...", "guest_reply": "..."}: action = the one concrete next step for staff in at most 20 words (what to check, who to call, what to offer); guest_reply = one warm sentence the host could send the affected guest, or "" if no guest is affected. Never promise a refund; say "the host will follow up" instead. Reply in plain English even if the report is in Bisaya or Tagalog.`;

/** One cheap suggestion; empty strings when the model is unavailable. */
export async function suggestFix(issue: string, context: string): Promise<{ action: string; guest_reply: string }> {
  try {
    const raw = await chatJson({ system: SYSTEM, history: [], question: `Report: "${issue}". Context: ${context}`, tier: 'lite', maxTokens: 200, timeoutMs: 12_000, title: 'Cascade work order' });
    const j = JSON.parse(raw.replace(/^```(?:json)?\s*|\s*```$/g, '').trim());
    return { action: String(j.action ?? '').trim().slice(0, 240), guest_reply: String(j.guest_reply ?? '').trim().slice(0, 300) };
  } catch (e) { console.warn('suggestFix failed (non-fatal):', String(e).slice(0, 200)); return { action: '', guest_reply: '' }; }
}

const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const dm = (d?: string | null) => { if (!d) return ''; const x = new Date(d.slice(0, 10) + 'T00:00:00Z'); return `${x.getUTCDate()} ${MON[x.getUTCMonth()]}`; };

/** Plain-text OPS card for a newly created work order (no parse_mode; guest text is untrusted). */
export function workOrderCard(kind: HeaderKind, a: RaiseArgs, r: Raised, s: { action: string; guest_reply: string }): string {
  // Session 28: grouped (issue / next guest / suggestion / Do / guest reply as a 📨 template).
  return withHeader(kind, 'work order', groups(
    [`Issue: ${a.title}`, a.reporter && `Reported by ${a.reporter}${a.guestName ? ` after ${a.guestName}` : ''}`],
    [r.next_checkin && `Next guest: ${r.next_guest ?? 'arrival'} on ${dm(r.next_checkin)}${r.blocks_arrival ? ' — BLOCKS ARRIVAL until closed' : ''}`],
    [s.action && `Suggested: ${s.action}`],
    [`Do: fix it, then close work order #${r.id.slice(0, 8)} on the dashboard (Today → readiness).`],
    s.guest_reply ? ['Reply to the guest if needed (Copy, or Revise with Cassy):', `${TEMPLATE_MARK}${s.guest_reply}`] : [],
  ));
}
