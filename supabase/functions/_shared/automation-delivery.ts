export type AutomationChannel = 'email' | 'telegram' | 'whatsapp' | 'internal';
export type AutomationDeliveryStatus = 'sent' | 'failed' | 'skipped';

/**
 * An event represents a complete workflow, not one provider attempt.  Only
 * the workflow's final internal callback may close it; channel callbacks keep
 * it dispatchable so a partial host-alert fan-out can be reconciled safely.
 */
export function nextOutboxStatus(channel: AutomationChannel, status: AutomationDeliveryStatus): 'completed' | 'dispatched' | 'failed' {
  if (status === 'failed') return 'failed';
  return channel === 'internal' ? 'completed' : 'dispatched';
}

export function deliveryIsComplete(status: AutomationDeliveryStatus): boolean {
  return status === 'sent' || status === 'skipped';
}
