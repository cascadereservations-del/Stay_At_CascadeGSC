import { signAutomationPayload, verifyAutomationSignature } from '../_shared/automation-auth.ts';
import { deliveryIsComplete, nextOutboxStatus } from '../_shared/automation-delivery.ts';

const SECRET = 'test-automation-secret';
const BODY = '{"event_id":"11111111-1111-4111-8111-111111111111","status":"completed"}';

function equal(actual: unknown, expected: unknown, message: string): void { if (actual !== expected) throw new Error(`${message}: expected ${expected}, got ${actual}`); }

Deno.test('accepts a valid automation callback HMAC', async () => {
  const signature = await signAutomationPayload(SECRET, BODY);
  equal(await verifyAutomationSignature(SECRET, BODY, signature), true, 'valid signature');
});

Deno.test('rejects missing or altered automation callback HMACs', async () => {
  const signature = await signAutomationPayload(SECRET, BODY);
  equal(await verifyAutomationSignature(SECRET, BODY, ''), false, 'missing signature');
  equal(await verifyAutomationSignature(SECRET, BODY + ' ', signature), false, 'altered body');
});

Deno.test('keeps an outbox event dispatchable until its workflow finalizes internally', () => {
  equal(nextOutboxStatus('email', 'sent'), 'dispatched', 'one successful channel is not the whole workflow');
  equal(nextOutboxStatus('telegram', 'skipped'), 'dispatched', 'skipped channel is not a terminal workflow result');
  equal(nextOutboxStatus('whatsapp', 'failed'), 'failed', 'provider failure stays visible for reconciliation');
  equal(nextOutboxStatus('internal', 'sent'), 'completed', 'only workflow finalization closes the event');
  equal(deliveryIsComplete('sent'), true, 'sent delivery is complete');
  equal(deliveryIsComplete('skipped'), true, 'skipped delivery is complete');
  equal(deliveryIsComplete('failed'), false, 'failed delivery is not complete');
});
