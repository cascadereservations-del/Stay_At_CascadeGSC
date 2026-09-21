// SPEC-11 session 2. The short name a verifier finding travels under when it
// has to fit inside a Telegram button.
//
// Telegram allows 64 bytes of callback data. A V1 key is 'V1:' plus two uuids,
// which is 77 on its own, so the button carries a hash and the handler finds
// its way back by hashing the findings that are still open.
//
// It lives in _shared rather than in system-verifier/cards.ts because
// telegram-expense needs it too, and Hard Rule 9 says a function that imports
// another function's file must be redeployed whenever that file changes. Card
// wording will change; this will not.
//
// SPEC-11 says md5. This is sha256: Web Crypto has no md5, so md5 would mean
// carrying an implementation of it into two Edge Functions purely to shorten a
// string. Sixteen hex characters either way.
export async function ackHash(key: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(key));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('').slice(0, 16);
}
