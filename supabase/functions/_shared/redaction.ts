const EMAIL = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi;
const PHONE = /(?:\+63|0)9\d{9}\b/g;
const BEARER = /\b(?:bearer\s+|token[=:]\s*)[A-Za-z0-9._~+/=-]{12,}/gi;
const URL_WITH_QUERY = /https?:\/\/[^\s?]+\?[^\s]+/gi;
const BANK_REFERENCE = /\b(?:ref(?:erence)?|trace|transaction)[\s#:=-]*[A-Z0-9-]{6,}\b/gi;
const MONEY = /(?:₱\s*\d[\d,]*(?:\.\d{1,2})?|\b(?:php|usd|eur|gbp)\s*\d[\d,]*(?:\.\d{1,2})?)/gi;

export function redactForLog(value: string, route: 'finance' | 'ops' | 'guest' | 'internal' = 'internal'): string {
  let redacted = value
    .replace(BEARER, '[REDACTED_TOKEN]')
    .replace(URL_WITH_QUERY, '[REDACTED_SIGNED_URL]')
    .replace(EMAIL, '[REDACTED_EMAIL]')
    .replace(PHONE, '[REDACTED_PHONE]')
    .replace(BANK_REFERENCE, '[REDACTED_BANK_REFERENCE]');
  if (route === 'ops') redacted = redacted.replace(MONEY, '[REDACTED_AMOUNT]');
  return redacted;
}

export function redactLogFields(fields: Record<string, unknown>, route: 'finance' | 'ops' | 'guest' | 'internal' = 'internal'): Record<string, unknown> {
  return Object.fromEntries(Object.entries(fields).map(([key, value]) => [
    key,
    typeof value === 'string' ? redactForLog(value, route) : value,
  ]));
}
