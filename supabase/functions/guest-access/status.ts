// SPEC-42 s6 (H9): turns the facts guest_booking_status_v1 returns into what the guest sees. Pure: no network, no clock of its
// own. The page shows only what this returns, so what is left out here never reaches a guest (no name, contact, address,
// door code, receipt path or account number is ever an input).

export type StatusFacts = {
  ref: string;
  status: string;
  checkin_date: string;
  checkout_date: string;
  pax: unknown;
  total_amount: unknown;
  deposit_amount: unknown;
  has_receipt: boolean;
  hold_status: string | null;
  hold_expires_at: string | null;
};

export type StatusState = 'held' | 'under_review' | 'awaiting_payment' | 'confirmed' | 'released' | 'cancelled';

// PHP 1,000 refundable security deposit, due with the balance at least one day before check-in (booking-terms.html).
export const SECURITY_DEPOSIT = 1000;
const DAY_MS = 86_400_000;

// Unknown is null, never 0.
function amount(value: unknown): number | null {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(value);
  return Number.isFinite(n) && n >= 0 ? n : null;
}

export function bookingState(f: Pick<StatusFacts, 'status' | 'has_receipt' | 'hold_status' | 'hold_expires_at'>, nowMs: number): StatusState | null {
  if (f.status === 'confirmed') return 'confirmed';
  if (f.status === 'cancelled') return 'cancelled';
  if (f.status === 'expired') return 'released';
  if (f.status !== 'pending') return null;
  if (f.has_receipt) return 'under_review';
  if (f.hold_status === 'expired' || f.hold_status === 'released') return 'released';
  if (f.hold_status === 'active') {
    const until = f.hold_expires_at ? Date.parse(f.hold_expires_at) : NaN;
    return Number.isFinite(until) && until > nowMs ? 'held' : 'released';
  }
  return 'awaiting_payment';
}

function dayBefore(date: string): string {
  return new Date(Date.parse(`${date}T00:00:00Z`) - DAY_MS).toISOString().slice(0, 10);
}

function nightsBetween(checkin: string, checkout: string): number | null {
  const n = Math.round((Date.parse(`${checkout}T00:00:00Z`) - Date.parse(`${checkin}T00:00:00Z`)) / DAY_MS);
  return Number.isFinite(n) && n > 0 ? n : null;
}

export function statusView(f: StatusFacts, nowMs: number) {
  const state = bookingState(f, nowMs);
  if (!state) return null;
  const closed = state === 'cancelled' || state === 'released';
  const total = amount(f.total_amount);
  const fee = amount(f.deposit_amount);
  const paidStep = f.has_receipt || state === 'confirmed';
  return {
    state,
    ref: f.ref,
    checkin_date: f.checkin_date,
    checkout_date: f.checkout_date,
    nights: nightsBetween(f.checkin_date, f.checkout_date),
    pax: amount(f.pax),
    checkin_time: '2:00 PM',
    checkout_time: '12:00 PM',
    hold_expires_at: state === 'held' ? f.hold_expires_at : null,
    // No money on a closed booking: a cancelled or released request owes and shows nothing.
    money: closed ? null : {
      total,
      reservation_payment: fee,
      balance_due_date: dayBefore(f.checkin_date),
      security_deposit: SECURITY_DEPOSIT,
    },
    timeline: closed ? null : [
      { key: 'requested', done: true },
      { key: 'paid', done: paidStep },
      { key: 'confirmed', done: state === 'confirmed' },
      { key: 'arrival', done: false },
    ],
    can_upload_receipt: state === 'held' || state === 'awaiting_payment',
  };
}
