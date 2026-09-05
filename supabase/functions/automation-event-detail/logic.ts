export type WorkflowAudience = 'finance' | 'guest' | 'internal';

type Contract = { eventType: string; workflowId: string; audience: WorkflowAudience };
const CONTRACTS: readonly Contract[] = [
  { eventType: 'booking.requested', workflowId: 'CH-W01', audience: 'finance' },
  { eventType: 'booking.receipt_uploaded', workflowId: 'CH-W02', audience: 'finance' },
  { eventType: 'booking.confirmed', workflowId: 'CH-W03', audience: 'guest' },
  { eventType: 'booking.cancelled', workflowId: 'CH-W03', audience: 'guest' },
  { eventType: 'calendar.projection_requested', workflowId: 'CH-W09', audience: 'internal' },
  { eventType: 'guest.returning_detected', workflowId: 'CH-W10', audience: 'internal' },
  { eventType: 'guest.identity_conflict', workflowId: 'CH-W11', audience: 'internal' },
];

export type EventRecord = {
  id: string;
  event_type: string;
  aggregate_id: string;
  route_class: string;
  template_key: string;
  payload: Record<string, unknown>;
};
export type BookingRecord = {
  id: string;
  status: string;
  checkin_date: string;
  checkout_date: string;
  pax: number | null;
  total_amount: number | null;
  deposit_amount: number | null;
  guest_name: string;
  guest_email: string | null;
  guest_phone: string | null;
};

export function workflowAudience(eventType: string, workflowId: string): WorkflowAudience | null {
  return CONTRACTS.find((contract) => contract.eventType === eventType && contract.workflowId === workflowId)?.audience ?? null;
}

export function buildEventDetail(
  event: EventRecord,
  workflowId: string,
  booking: BookingRecord,
  expiresAt: string,
): Record<string, unknown> | null {
  const audience = workflowAudience(event.event_type, workflowId);
  if (!audience) return null;
  if (event.route_class !== audience && !(audience === 'internal' && event.route_class === 'internal')) return null;

  const base: Record<string, unknown> = {
    event_id: event.id,
    event_type: event.event_type,
    audience,
    template_key: event.template_key,
    booking_ref: booking.id.slice(0, 8).toUpperCase(),
    status: booking.status,
    checkin_date: booking.checkin_date,
    checkout_date: booking.checkout_date,
    expires_at: expiresAt,
  };
  if (audience === 'finance') {
    return { ...base, pax: booking.pax, total_amount: booking.total_amount, deposit_amount: booking.deposit_amount };
  }
  if (audience === 'guest') {
    return { ...base, guest_name: booking.guest_name, guest_email: booking.guest_email, guest_phone: booking.guest_phone };
  }
  if (event.event_type === 'calendar.projection_requested') {
    return {
      ...base,
      calendar_event_id: event.aggregate_id,
      operation: event.payload.operation,
      sync_hash: event.payload.sync_hash,
    };
  }
  return {
    ...base,
    guest_id: event.payload.guest_id,
    previous_completed_stays: event.payload.previous_completed_stays,
    total_completed_nights: event.payload.total_completed_nights,
  };
}
