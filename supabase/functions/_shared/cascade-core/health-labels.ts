// SPEC-18 (D-211). The health checks' own labels are written as the PASSING assertion -
// "Inventory quantities agree with movements" - so any surface that prints a label next to a red
// icon announces the opposite of what is wrong. The verifier card said exactly that on 2026-09-21,
// and the weekly Finance digest was still saying it a day later. Every renderer now comes here.
//
// A check key that is not in this map renders a neutral line, never the label.
import { pesoOrNull } from './format.ts';

/** The eleven labels as stored in admin_health_check_runs.label - kept only so tests can prove a
 *  failing card never quotes one. health_checks_core_v10.sql is the source; keep them identical. */
export const HEALTH_LABELS: Record<string, string> = {
  payout_rows_linked:          'Payout e-mails linked to a stay',
  completed_stays_paid:        'Completed stays with a payout row',
  payout_totals_agree:         'Reservation payouts equal payout e-mails plus adjustments',
  checkouts_cleaned:           'Checkouts (90 days) followed by a cleaning',
  cleaner_fees_settled:        'Cleaning fees settled in the ledger',
  meter_readings_reviewed:     'Odd meter readings reviewed',
  inventory_ledger_consistent: 'Inventory quantities agree with movements',
  ledger_duplicates:           'Duplicate ledger rows',
  ledger_position:             'Cash position: income \u2212 expenses \u2212 drawings',
  journals_balanced:           'Posted journals balance',
  concierge_handoffs_open:     'Messenger handoffs awaiting a human reply',
};
export const HEALTH_KEYS = Object.keys(HEALTH_LABELS);

const SUBJECT: Record<string, string> = {
  payout_rows_linked: 'payout e-mail not linked to a stay',
  completed_stays_paid: 'completed stay with no payout',
  payout_totals_agree: 'payout totals disagree',
  checkouts_cleaned: 'checkout with no cleaning logged',
  cleaner_fees_settled: 'cleaning fee not settled',
  meter_readings_reviewed: 'meter readings to review',
  inventory_ledger_consistent: 'inventory count disagrees with its movements',
  ledger_duplicates: 'duplicate ledger rows',
  ledger_position: 'cash position does not balance',
  journals_balanced: 'journal does not balance',
  concierge_handoffs_open: 'guest handoff waiting',
};

/** Short subject for an alert header. Never the label. */
export function problemSubject(check: string): string {
  return SUBJECT[check] ?? `system health check ${check.replace(/_/g, ' ')} needs a look`;
}

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/** One sentence that states the PROBLEM with its number in it. `d` is the stored detail; the scalar
 *  checks read their amount from d.d and say nothing about an amount they cannot read. */
export function problemSentence(check: string, n: number, d?: Record<string, any> | null): string {
  const diff = pesoOrNull(d?.d?.difference);
  const net = pesoOrNull(d?.d?.net);
  switch (check) {
    case 'payout_rows_linked':          return `${plural(n, 'payout e-mail is', 'payout e-mails are')} not linked to a stay.`;
    case 'completed_stays_paid':        return `${plural(n, 'completed stay has', 'completed stays have')} no payout row.`;
    case 'payout_totals_agree':         return diff ? `Reservation payouts and payout e-mails disagree by ${diff}.` : 'Reservation payouts and payout e-mails disagree.';
    case 'checkouts_cleaned':           return `${plural(n, 'checkout in the last 90 days has', 'checkouts in the last 90 days have')} no cleaning logged.`;
    case 'cleaner_fees_settled':        return `${plural(n, 'cleaning fee is', 'cleaning fees are')} owed and not settled in the ledger.`;
    case 'meter_readings_reviewed':     return `${plural(n, 'odd meter reading has', 'odd meter readings have')} not been reviewed.`;
    case 'inventory_ledger_consistent': return `${plural(n, 'inventory item disagrees', 'inventory items disagree')} with its own last stock movement.`;
    case 'ledger_duplicates':           return `${plural(n, 'set of duplicate ledger rows', 'sets of duplicate ledger rows')}.`;
    case 'ledger_position':             return net ? `Cash position does not balance: ${net} unaccounted after expenses and drawings.` : 'Cash position does not balance after expenses and drawings.';
    case 'journals_balanced':           return `${plural(n, 'posted journal does', 'posted journals do')} not balance.`;
    case 'concierge_handoffs_open':     return `${plural(n, 'guest handoff is', 'guest handoffs are')} waiting for a person.`;
    default:                            return `System health check ${check.replace(/_/g, ' ')} needs a look${n ? `, ${n} to look at` : ''}.`;
  }
}
