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
