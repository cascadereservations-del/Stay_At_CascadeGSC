import { redactForLog, redactLogFields } from './redaction.ts';

function includes(value: string, expected: string, message: string): void {
  if (!value.includes(expected)) throw new Error(message);
}

Deno.test('redacts tokens, signed URLs, contact data and bank references', () => {
  const result = redactForLog('Bearer abcdefghijklmnop contact a@b.com +639171234567 ref ABCD-123456 https://x.test/a?token=secret');
  includes(result, '[REDACTED_TOKEN]', 'token');
  includes(result, '[REDACTED_EMAIL]', 'email');
  includes(result, '[REDACTED_PHONE]', 'phone');
  includes(result, '[REDACTED_BANK_REFERENCE]', 'reference');
  includes(result, '[REDACTED_SIGNED_URL]', 'url');
});

Deno.test('redacts amounts from OPS logs but retains finance diagnostic context', () => {
  includes(redactForLog('guest paid PHP 1,780.00', 'ops'), '[REDACTED_AMOUNT]', 'OPS amount');
  includes(redactForLog('guest paid PHP 1,780.00', 'finance'), 'PHP 1,780.00', 'Finance amount');
});

Deno.test('redacts string fields without mutating safe structured values', () => {
  const fields = redactLogFields({ count: 2, email: 'guest@example.com' });
  if (fields.count !== 2 || fields.email !== '[REDACTED_EMAIL]') throw new Error('field redaction mismatch');
});

Deno.test('recursively redacts nested contact fields', () => {
  const fields = redactLogFields({ nested: { email: 'guest@example.com', count: 2 } });
  const nested = fields.nested as Record<string, unknown>;
  if (nested.email !== '[REDACTED_EMAIL]' || nested.count !== 2) throw new Error('nested redaction mismatch');
});

Deno.test('redacts sensitive field values regardless of primitive type', () => {
  const fields = redactLogFields({
    access_code: 4821,
    message_body: 'guest supplied private details',
    receipt_url: 'https://storage.test/private.jpg',
  });
  if (fields.access_code !== '[REDACTED_ACCESS_CODE]') throw new Error('access code field');
  if (fields.message_body !== '[REDACTED_MESSAGE_BODY]') throw new Error('message body field');
  if (fields.receipt_url !== '[REDACTED_RECEIPT_URL]') throw new Error('receipt URL field');
});

Deno.test('redacts unstructured address and access-code text', () => {
  const result = redactForLog('Meet at Block 47 Lot 39, Bria Homes. Gate code: 4821');
  includes(result, '[REDACTED_ADDRESS]', 'address');
  includes(result, '[REDACTED_ACCESS_CODE]', 'access code');
});
