import { cronSecretMatches } from './cron-auth.ts';

function equal(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) throw new Error(`${message}: expected ${expected}, got ${actual}`);
}

Deno.test('accepts only an exact non-empty cron secret', () => {
  equal(cronSecretMatches('cascade-test-secret', 'cascade-test-secret'), true, 'exact match');
  equal(cronSecretMatches('cascade-test-secret', 'cascade-test-secret '), false, 'trailing space');
  equal(cronSecretMatches('cascade-test-secret', 'CASCADE-TEST-SECRET'), false, 'case change');
  equal(cronSecretMatches('', ''), false, 'empty values');
  equal(cronSecretMatches(undefined, 'value'), false, 'missing configured secret');
  equal(cronSecretMatches('value', null), false, 'missing supplied secret');
});
