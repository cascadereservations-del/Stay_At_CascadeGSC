import { signAutomationPayload, verifyAutomationSignature } from '../_shared/automation-auth.ts';

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
