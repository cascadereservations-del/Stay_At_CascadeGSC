import { validateSiteEvent } from '../_shared/site-event.ts';

const NOW = Date.UTC(2026, 7, 24, 0, 0, 0);
const SESSION_ID = '11111111-1111-4111-8111-111111111111';

function equal(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) throw new Error(`${message}: expected ${String(expected)}, got ${String(actual)}`);
}

function validEvent(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    session_id: SESSION_ID,
    event_name: 'page_view',
    occurred_at: new Date(NOW).toISOString(),
    viewport_group: 'mobile',
    referrer_group: 'direct',
    page_version: '2026-08-24',
    ...overrides,
  };
}

Deno.test('accepts a valid allowlisted aggregate event', () => {
  const result = validateSiteEvent(validEvent(), NOW);
  equal(result.ok, true, 'valid event');
});

Deno.test('rejects unknown keys including personal data fields', () => {
  const result = validateSiteEvent(validEvent({ guest_email: 'guest@example.test' }), NOW);
  equal(result.ok, false, 'unknown field');
  if (!result.ok) equal(result.error, 'unknown_property', 'unknown field code');
});

Deno.test('rejects invalid session UUIDs', () => {
  const result = validateSiteEvent(validEvent({ session_id: 'not-a-uuid' }), NOW);
  equal(result.ok, false, 'invalid UUID');
  if (!result.ok) equal(result.error, 'invalid_session_id', 'UUID error code');
});

Deno.test('rejects future timestamps more than five minutes ahead', () => {
  const result = validateSiteEvent(validEvent({ occurred_at: new Date(NOW + 5 * 60 * 1000 + 1).toISOString() }), NOW);
  equal(result.ok, false, 'future event');
  if (!result.ok) equal(result.error, 'invalid_occurred_at', 'future timestamp code');
});

Deno.test('rejects event names and bucket values outside the contract', () => {
  const eventName = validateSiteEvent(validEvent({ event_name: 'form_field_blur' }), NOW);
  const bucket = validateSiteEvent(validEvent({ nights_bucket: '2026-08-24' }), NOW);
  equal(eventName.ok, false, 'unknown event');
  equal(bucket.ok, false, 'exact dates cannot be bucket values');
});

Deno.test('rejects payloads larger than four kilobytes', () => {
  const result = validateSiteEvent(validEvent({ page_version: 'x'.repeat(4096) }), NOW);
  equal(result.ok, false, 'oversized payload');
  if (!result.ok) equal(result.error, 'payload_too_large', 'payload size code');
});
