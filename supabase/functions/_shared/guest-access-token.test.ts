import { createGuestAccessToken, hashGuestAccessToken } from './guest-access-token.ts';

function equal(actual: unknown, expected: unknown, message: string): void { if (actual !== expected) throw new Error(`${message}: expected ${expected}, got ${actual}`); }

Deno.test('creates an opaque 256-bit guest access token and stores only its hash', async () => {
  const token = createGuestAccessToken();
  equal(/^[A-Za-z0-9_-]{43}$/.test(token), true, 'token is 256-bit base64url');
  const hash = await hashGuestAccessToken(token);
  equal(/^[a-f0-9]{64}$/.test(hash), true, 'hash is SHA-256 hex');
  equal(hash === token, false, 'raw token is not hash');
});
