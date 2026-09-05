export type AutomationChannel = 'email' | 'telegram' | 'whatsapp' | 'internal';
export type AutomationDeliveryStatus = 'sent' | 'failed' | 'skipped';

export type DeliveryCallback = {
  callback_id: string;
  event_id: string;
  workflow_id: string;
  channel: AutomationChannel;
  status: AutomationDeliveryStatus;
  recipient_hash: string | null;
  provider_message_id: string | null;
  error_code: string | null;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CALLBACK_ID = /^[A-Za-z0-9][A-Za-z0-9:_-]{15,159}$/;
const WORKFLOWS = new Set(['CH-S01','CH-W01','CH-W02','CH-W03','CH-W04','CH-W05','CH-W06','CH-W07','CH-W08','CH-W09','CH-W10','CH-W11','CH-W12']);
const CHANNELS = new Set<AutomationChannel>(['email','telegram','whatsapp','internal']);
const STATUSES = new Set<AutomationDeliveryStatus>(['sent','failed','skipped']);

export function parseDeliveryCallback(input: unknown): DeliveryCallback | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const value = input as Record<string, unknown>;
  const allowed = new Set(['callback_id','event_id','workflow_id','channel','status','recipient_hash','provider_message_id','error_code']);
  if (Object.keys(value).some((key) => !allowed.has(key))) return null;
  if (typeof value.callback_id !== 'string' || !CALLBACK_ID.test(value.callback_id)
    || typeof value.event_id !== 'string' || !UUID.test(value.event_id)
    || typeof value.workflow_id !== 'string' || !WORKFLOWS.has(value.workflow_id)
    || typeof value.channel !== 'string' || !CHANNELS.has(value.channel as AutomationChannel)
    || typeof value.status !== 'string' || !STATUSES.has(value.status as AutomationDeliveryStatus)) return null;
  const optional = (key: string, max: number, pattern?: RegExp): string | null | undefined => {
    const item = value[key];
    if (item === undefined || item === null) return null;
    if (typeof item !== 'string' || item.length > max || (pattern && !pattern.test(item))) return undefined;
    return item;
  };
  const recipient = optional('recipient_hash', 128);
  const provider = optional('provider_message_id', 256);
  const error = optional('error_code', 64, /^[A-Za-z0-9_]+$/);
  if (recipient === undefined || provider === undefined || error === undefined) return null;
  return {
    callback_id: value.callback_id,
    event_id: value.event_id,
    workflow_id: value.workflow_id,
    channel: value.channel as AutomationChannel,
    status: value.status as AutomationDeliveryStatus,
    recipient_hash: recipient,
    provider_message_id: provider,
    error_code: error,
  };
}

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
