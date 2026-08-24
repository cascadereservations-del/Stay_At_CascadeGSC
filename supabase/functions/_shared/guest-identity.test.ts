import { normalizeEmail, normalizePhilippinePhone } from './guest-identity.ts';

function equal(actual: unknown, expected: unknown, message: string): void { if (actual !== expected) throw new Error(`${message}: expected ${expected}, got ${actual}`); }

Deno.test('normalizes common Philippine mobile formats to one E.164 value', () => {
  equal(normalizePhilippinePhone('09171234567'), '+639171234567', 'local format');
  equal(normalizePhilippinePhone('9171234567'), '+639171234567', 'national format');
  equal(normalizePhilippinePhone('+639171234567'), '+639171234567', 'E.164 format');
});

Deno.test('rejects an invalid phone and normalizes email only by trim/lowercase', () => {
  equal(normalizePhilippinePhone('0917123'), null, 'invalid phone');
  equal(normalizeEmail('  Guest@Example.TEST '), 'guest@example.test', 'normalized email');
});
