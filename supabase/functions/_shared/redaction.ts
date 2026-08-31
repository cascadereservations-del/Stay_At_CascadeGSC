const EMAIL = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi;
const PHONE = /(?:\+63|0)9\d{9}\b/g;
const BEARER = /\b(?:bearer\s+|token[=:]\s*)[A-Za-z0-9._~+/=-]{12,}/gi;
const URL_WITH_QUERY = /https?:\/\/[^\s?]+\?[^\s]+/gi;
const BANK_REFERENCE = /\b(?:ref(?:erence)?|trace|transaction)[\s#:=-]*[A-Z0-9-]{6,}\b/gi;
const MONEY = /(?:₱\s*\d[\d,]*(?:\.\d{1,2})?|\b(?:php|usd|eur|gbp)\s*\d[\d,]*(?:\.\d{1,2})?)/gi;
const PROPERTY_ADDRESS = /\b(?:block|blk|lot|unit|house)\s+[A-Z0-9-]+(?:\s+(?:lot|block|blk|unit|house)\s+[A-Z0-9-]+)?(?:,\s*[A-Z][A-Z0-9 '-]{2,40})?/gi;
const STREET_ADDRESS = /\b\d{1,6}\s+[A-Z][A-Z0-9'-]+(?:\s+[A-Z][A-Z0-9'-]+){0,4}\s+(?:street|st|road|rd|avenue|ave|drive|dr|lane|ln)\b/gi;
const ACCESS_CODE = /\b(?:access|door|gate|wifi)\s*(?:code|pin)?\s*[:=#-]?\s*[A-Z0-9-]{4,16}\b/gi;
const PIN_CODE = /\bpin\s*[:=#-]?\s*[A-Z0-9-]{4,16}\b/gi;

export type RedactionRoute = 'finance' | 'ops' | 'guest' | 'internal';

const keyMarker = (key: string, route: RedactionRoute): string | null => {
  const normalized = key.toLowerCase();
  if (/(?:^|_)(?:token|secret|authorization|password|api_?key)(?:$|_)/.test(normalized)) return '[REDACTED_TOKEN]';
  if (/(?:^|_)(?:access_code|door_code|gate_code|wifi_code|pin)(?:$|_)/.test(normalized)) return '[REDACTED_ACCESS_CODE]';
  if (/(?:message|body|content)/.test(normalized)) return '[REDACTED_MESSAGE_BODY]';
  if (/(?:receipt|signed).*(?:url|path)|(?:url|path).*(?:receipt|signed)/.test(normalized)) return '[REDACTED_RECEIPT_URL]';
  if (/(?:bank_?reference|transaction_?reference|trace_?number)/.test(normalized)) return '[REDACTED_BANK_REFERENCE]';
  if (/(?:email|phone|mobile|contact_?number)/.test(normalized)) return normalized.includes('email') ? '[REDACTED_EMAIL]' : '[REDACTED_PHONE]';
  if (/(?:address|street|barangay|brgy)/.test(normalized)) return '[REDACTED_ADDRESS]';
  if (/(?:^|_)(?:raw|ocr_raw|provider_payload)(?:$|_)/.test(normalized)) return '[REDACTED_RAW_PAYLOAD]';
  if (route === 'ops' && /(?:amount|price|rate|fee|payout|revenue|expense|balance|total|deposit|refund|currency)/.test(normalized)) {
    return '[REDACTED_AMOUNT]';
  }
  return null;
};

export function redactForLog(value: string, route: RedactionRoute = 'internal'): string {
  let redacted = value
    .replace(BEARER, '[REDACTED_TOKEN]')
    .replace(URL_WITH_QUERY, '[REDACTED_SIGNED_URL]')
    .replace(EMAIL, '[REDACTED_EMAIL]')
    .replace(PHONE, '[REDACTED_PHONE]')
    .replace(BANK_REFERENCE, '[REDACTED_BANK_REFERENCE]')
    .replace(PROPERTY_ADDRESS, '[REDACTED_ADDRESS]')
    .replace(STREET_ADDRESS, '[REDACTED_ADDRESS]')
    .replace(ACCESS_CODE, '[REDACTED_ACCESS_CODE]')
    .replace(PIN_CODE, '[REDACTED_ACCESS_CODE]');
  if (route === 'ops') redacted = redacted.replace(MONEY, '[REDACTED_AMOUNT]');
  return redacted;
}

function redactValue(
  value: unknown,
  route: RedactionRoute,
  key: string | undefined,
  seen: WeakSet<object>,
): unknown {
  const marker = key ? keyMarker(key, route) : null;
  if (marker && value !== null && value !== undefined) return marker;
  if (typeof value === 'string') return redactForLog(value, route);
  if (typeof value === 'bigint') return value.toString();
  if (value === null || value === undefined || typeof value !== 'object') return value;
  if (value instanceof Error) return redactForLog(value.message, route);
  if (value instanceof Date) return value.toISOString();
  if (seen.has(value)) return '[REDACTED_CIRCULAR]';
  seen.add(value);
  if (Array.isArray(value)) return value.map((item) => redactValue(item, route, undefined, seen));
  return Object.fromEntries(
    Object.entries(value).map(([field, nested]) => [field, redactValue(nested, route, field, seen)]),
  );
}

export function redactLogValue(value: unknown, route: RedactionRoute = 'internal', key?: string): unknown {
  return redactValue(value, route, key, new WeakSet<object>());
}

export function redactLogFields(fields: Record<string, unknown>, route: RedactionRoute = 'internal'): Record<string, unknown> {
  return redactLogValue(fields, route) as Record<string, unknown>;
}

export function redactLogArguments(values: unknown[], route: RedactionRoute = 'internal'): unknown[] {
  return values.map((value) => redactLogValue(value, route));
}
