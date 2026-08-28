export type NotificationRoute = 'finance' | 'ops' | 'guest' | 'internal';

export type NotificationRequest = {
  route: NotificationRoute;
  template: string;
  fields: Record<string, unknown>;
};

export type Notification = {
  route: NotificationRoute;
  template: string;
  text: string;
  fields: Record<string, unknown>;
};

export class NotificationRouteError extends Error {
  constructor(public readonly reason: string, detail?: string) {
    super(detail ? `${reason}: ${detail}` : reason);
    this.name = 'NotificationRouteError';
  }
}

const FORBIDDEN_OPS_KEY = /(amount|currency|payout|revenue|expense|balance|payment|paid|receipt|bank|refund|deposit|fee|rate|price|cost|ledger|transaction)/i;
const FORBIDDEN_OPS_TEXT = /(?:₱|\b(?:php|usd|eur|gbp|jpy|aud|cad)\b|\b(?:paid|payment|payout|revenue|expense|balance|receipt|bank|refund|deposit|fee|rate|price|cost|ledger|transaction)\b)/i;

function inspectOpsValue(value: unknown, keyPath: string): void {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => inspectOpsValue(entry, `${keyPath}[${index}]`));
    return;
  }
  if (value && typeof value === 'object') {
    for (const [key, nested] of Object.entries(value)) {
      if (FORBIDDEN_OPS_KEY.test(key)) {
        throw new NotificationRouteError('ops_financial_field', `${keyPath}.${key}`);
      }
      inspectOpsValue(nested, `${keyPath}.${key}`);
    }
    return;
  }
  if (typeof value === 'string' && FORBIDDEN_OPS_TEXT.test(value)) {
    throw new NotificationRouteError('ops_financial_text', keyPath);
  }
}

export function assertRoutePayloadSafe(route: NotificationRoute, payload: unknown): void {
  if (route !== 'ops') return;
  inspectOpsValue(payload, 'payload');
}

type TemplateDefinition = {
  route: NotificationRoute;
  required: readonly string[];
  allowed: readonly string[];
  render: (fields: Record<string, unknown>) => string;
};

const text = (fields: Record<string, unknown>, key: string): string => String(fields[key] ?? '').trim();
const integer = (fields: Record<string, unknown>, key: string): number => {
  const value = Number(fields[key]);
  if (!Number.isInteger(value) || value < 0) throw new NotificationRouteError('invalid_template_field', key);
  return value;
};
const money = (fields: Record<string, unknown>, amountKey: string, currencyKey: string): string => {
  const amount = Number(fields[amountKey]);
  const currency = text(fields, currencyKey).toUpperCase();
  if (!Number.isFinite(amount) || amount < 0 || !/^[A-Z]{3}$/.test(currency)) {
    throw new NotificationRouteError('invalid_template_field', amountKey);
  }
  return `${currency} ${amount.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
};

const TEMPLATES: Record<string, TemplateDefinition> = {
  'ops.arrival_advisory': {
    route: 'ops',
    required: ['booking_ref', 'unit_name', 'guest_name', 'checkin_date', 'checkout_date', 'pax'],
    allowed: ['booking_ref', 'unit_name', 'guest_name', 'checkin_date', 'checkout_date', 'pax'],
    render: (fields) => [
      '🏠 Arrival Advisory',
      `Booking: ${text(fields, 'booking_ref')}`,
      `Property: ${text(fields, 'unit_name')}`,
      `Guest: ${text(fields, 'guest_name')}`,
      `Check-in: ${text(fields, 'checkin_date')}`,
      `Check-out: ${text(fields, 'checkout_date')}`,
      `Guests: ${integer(fields, 'pax')}`,
    ].join('\n'),
  },
  'ops.turnover_due': {
    route: 'ops',
    required: ['booking_ref', 'unit_name', 'checkout_date', 'turnover_date'],
    allowed: ['booking_ref', 'unit_name', 'checkout_date', 'turnover_date', 'assigned_staff'],
    render: (fields) => [
      '🧹 Turnover Due',
      `Booking: ${text(fields, 'booking_ref')}`,
      `Property: ${text(fields, 'unit_name')}`,
      `Departure: ${text(fields, 'checkout_date')}`,
      `Turnover: ${text(fields, 'turnover_date')}`,
      ...(text(fields, 'assigned_staff') ? [`Assigned: ${text(fields, 'assigned_staff')}`] : []),
    ].join('\n'),
  },
  'finance.payment_review': {
    route: 'finance',
    required: ['booking_ref', 'expected_amount', 'currency', 'match_status'],
    allowed: ['booking_ref', 'expected_amount', 'currency', 'match_status'],
    render: (fields) => [
      '💳 Payment Review',
      `Booking: ${text(fields, 'booking_ref')}`,
      `Expected: ${money(fields, 'expected_amount', 'currency')}`,
      `Match: ${text(fields, 'match_status')}`,
    ].join('\n'),
  },
  'finance.system_failure': {
    route: 'finance',
    required: ['job_name', 'reason_code', 'correlation_id', 'last_succeeded_at', 'consecutive_failures'],
    allowed: ['job_name', 'reason_code', 'correlation_id', 'last_succeeded_at', 'consecutive_failures'],
    render: (fields) => [
      '⚠️ Cascade System Failure',
      `Job: ${text(fields, 'job_name')}`,
      `Reason: ${text(fields, 'reason_code')}`,
      `Last success: ${text(fields, 'last_succeeded_at')}`,
      `Consecutive failures: ${integer(fields, 'consecutive_failures')}`,
      `Correlation: ${text(fields, 'correlation_id')}`,
    ].join('\n'),
  },
  'ops.operational_risk': {
    route: 'ops',
    required: ['job_name', 'reason_code', 'correlation_id', 'impact'],
    allowed: ['job_name', 'reason_code', 'correlation_id', 'impact'],
    render: (fields) => [
      '⚠️ Operational Automation Risk',
      `Job: ${text(fields, 'job_name')}`,
      `Reason: ${text(fields, 'reason_code')}`,
      `Impact: ${text(fields, 'impact')}`,
      `Correlation: ${text(fields, 'correlation_id')}`,
    ].join('\n'),
  },
  'guest.booking_confirmed': {
    route: 'guest',
    required: ['booking_ref', 'unit_name', 'checkin_date', 'checkout_date'],
    allowed: ['booking_ref', 'unit_name', 'checkin_date', 'checkout_date'],
    render: (fields) => [
      'Your reservation is confirmed.',
      `Booking: ${text(fields, 'booking_ref')}`,
      `Property: ${text(fields, 'unit_name')}`,
      `Check-in: ${text(fields, 'checkin_date')}`,
      `Check-out: ${text(fields, 'checkout_date')}`,
    ].join('\n'),
  },
  'internal.system_failure': {
    route: 'internal',
    required: ['correlation_id', 'reason_code'],
    allowed: ['correlation_id', 'reason_code', 'job_name'],
    render: (fields) => [
      'Cascade system event',
      `Correlation: ${text(fields, 'correlation_id')}`,
      `Reason: ${text(fields, 'reason_code')}`,
      ...(text(fields, 'job_name') ? [`Job: ${text(fields, 'job_name')}`] : []),
    ].join('\n'),
  },
};

export function createNotification(request: NotificationRequest): Notification {
  const definition = TEMPLATES[request.template];
  if (!definition) throw new NotificationRouteError('unknown_template', request.template);
  if (definition.route !== request.route) {
    throw new NotificationRouteError('template_route_mismatch', `${request.template} cannot use ${request.route}`);
  }

  const allowed = new Set(definition.allowed);
  for (const key of Object.keys(request.fields)) {
    if (!allowed.has(key)) throw new NotificationRouteError('unknown_template_field', key);
  }
  for (const key of definition.required) {
    if (!(key in request.fields) || request.fields[key] === null || request.fields[key] === '') {
      throw new NotificationRouteError('missing_template_field', key);
    }
  }

  assertRoutePayloadSafe(request.route, request.fields);
  const rendered = definition.render(request.fields);
  assertRoutePayloadSafe(request.route, { rendered_text: rendered });

  return {
    route: request.route,
    template: request.template,
    text: rendered,
    fields: { ...request.fields },
  };
}
