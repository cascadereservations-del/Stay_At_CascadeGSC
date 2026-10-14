import { cronAuthFailure, cronSecretMatches } from './cron-auth.ts';

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

Deno.test('cronAuthFailure: null only for the exact secret, 401 otherwise, closed when unset', async () => {
  const req = (h?: string) => new Request('https://x.test/f', { method: 'POST', headers: h === undefined ? {} : { 'x-cascade-cron-secret': h } });
  equal(cronAuthFailure(req('s3cret-value'), 's3cret-value'), null, 'exact secret passes');
  for (const [h, sec] of [[undefined, 's3cret-value'], ['wrong-secret', 's3cret-value'], ['', ''], [undefined, undefined], ['s3cret-value', undefined]] as [string | undefined, string | undefined][]) {
    const r = cronAuthFailure(req(h), sec);
    equal(r?.status, 401, `denied for header=${h} secret=${sec}`);
    equal((await r!.json()).error, 'unauthorized', 'body says unauthorized');
  }
});

Deno.test('cronOrServiceAuthorized: the cron secret or the service-role bearer, nothing else, closed when unset', async () => {
  const { cronOrServiceAuthorized } = await import('./cron-auth.ts');
  const req = (h: Record<string, string>) => new Request('https://x.test/f', { method: 'POST', headers: h });
  equal(cronOrServiceAuthorized(req({ 'x-cascade-cron-secret': 'cron-s' }), 'cron-s', 'svc-k'), true, 'cron secret');
  equal(cronOrServiceAuthorized(req({ authorization: 'Bearer svc-k' }), 'cron-s', 'svc-k'), true, 'service bearer');
  equal(cronOrServiceAuthorized(req({ authorization: 'Bearer sb_publishable_abc' }), 'cron-s', 'svc-k'), false, 'the publishable key alone is not enough');
  equal(cronOrServiceAuthorized(req({}), 'cron-s', 'svc-k'), false, 'no header');
  equal(cronOrServiceAuthorized(req({ 'x-cascade-cron-secret': 'cron-s' }), undefined, undefined), false, 'secret unset: closed');
  equal(cronOrServiceAuthorized(req({ authorization: 'Bearer ' }), undefined, undefined), false, 'empty bearer, nothing set');
  equal(cronOrServiceAuthorized(req({ 'x-cascade-cron-secret': 'wrong', authorization: 'Bearer nope' }), 'cron-s', 'svc-k'), false, 'both wrong');
});
