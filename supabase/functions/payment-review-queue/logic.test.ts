import { assertEquals } from 'jsr:@std/assert@1';
import { parseQueueRequest, queueErrorStatus } from './logic.ts';

Deno.test('accepts a bounded property-scoped queue request', () => {
  const request = parseQueueRequest(new URL('https://local.invalid/?property_id=51000000-0000-4000-8000-000000000001&limit=25'));
  assertEquals(request, { propertyId: '51000000-0000-4000-8000-000000000001', limit: 25 });
});

Deno.test('rejects malformed or oversized queue requests', () => {
  assertEquals(parseQueueRequest(new URL('https://local.invalid/?property_id=nope')), null);
  assertEquals(parseQueueRequest(new URL('https://local.invalid/?property_id=51000000-0000-4000-8000-000000000001&limit=101')), null);
});

Deno.test('maps authorization and validation failures without leaking details', () => {
  assertEquals(queueErrorStatus('42501'), 403);
  assertEquals(queueErrorStatus('22023'), 400);
  assertEquals(queueErrorStatus(undefined), 503);
});
