const ALLOWED_KEYS = new Set(['session_id', 'event_name', 'occurred_at', 'viewport_group', 'referrer_group', 'nights_bucket', 'lead_time_bucket', 'payment_method', 'error_code', 'page_version']);
const EVENT_NAMES = new Set(['page_view', 'hero_check_dates', 'date_range_selected', 'guest_details_started', 'guest_details_valid', 'payment_method_viewed', 'receipt_selected', 'reservation_submit', 'reservation_success', 'reservation_error', 'airbnb_outbound', 'airbnb_embed_view', 'airbnb_embed_error', 'contact_outbound']);
const VIEWPORTS = new Set(['mobile', 'tablet', 'desktop']);
const REFERRERS = new Set(['direct', 'search', 'social', 'referral', 'other']);
const NIGHT_BUCKETS = new Set(['1', '2-4', '5-6', '7-13', '14-27', '28+']);
const LEAD_TIME_BUCKETS = new Set(['0-2', '3-7', '8-30', '31+']);
const PAYMENT_METHODS = new Set(['bank_transfer', 'gcash', 'cash_on_arrival']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_BYTES = 4096;

type ValidatedEvent = {
  session_id: string;
  event_name: string;
  occurred_at: string;
  viewport_group?: string;
  referrer_group?: string;
  nights_bucket?: string;
  lead_time_bucket?: string;
  payment_method?: string;
  error_code?: string;
  page_version?: string;
};

export type SiteEventValidation = { ok: true; value: ValidatedEvent } | { ok: false; error: 'invalid_payload' | 'payload_too_large' | 'unknown_property' | 'invalid_session_id' | 'invalid_event_name' | 'invalid_occurred_at' | 'invalid_property' };

function isOptionalString(value: unknown, permitted: Set<string>): boolean {
  return value === undefined || (typeof value === 'string' && permitted.has(value));
}

export function validateSiteEvent(payload: unknown, now = Date.now()): SiteEventValidation {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return { ok: false, error: 'invalid_payload' };
  const record = payload as Record<string, unknown>;
  if (new TextEncoder().encode(JSON.stringify(record)).byteLength > MAX_BYTES) return { ok: false, error: 'payload_too_large' };
  if (Object.keys(record).some((key) => !ALLOWED_KEYS.has(key))) return { ok: false, error: 'unknown_property' };
  if (typeof record.session_id !== 'string' || !UUID.test(record.session_id)) return { ok: false, error: 'invalid_session_id' };
  if (typeof record.event_name !== 'string' || !EVENT_NAMES.has(record.event_name)) return { ok: false, error: 'invalid_event_name' };
  if (typeof record.occurred_at !== 'string' || !Number.isFinite(Date.parse(record.occurred_at)) || Date.parse(record.occurred_at) > now + 5 * 60 * 1000) return { ok: false, error: 'invalid_occurred_at' };
  if (!isOptionalString(record.viewport_group, VIEWPORTS) || !isOptionalString(record.referrer_group, REFERRERS) || !isOptionalString(record.nights_bucket, NIGHT_BUCKETS) || !isOptionalString(record.lead_time_bucket, LEAD_TIME_BUCKETS) || !isOptionalString(record.payment_method, PAYMENT_METHODS) || (record.error_code !== undefined && (typeof record.error_code !== 'string' || record.error_code.length > 64 || !/^[a-z0-9_]+$/i.test(record.error_code))) || (record.page_version !== undefined && (typeof record.page_version !== 'string' || record.page_version.length > 64))) return { ok: false, error: 'invalid_property' };
  return { ok: true, value: record as ValidatedEvent };
}
