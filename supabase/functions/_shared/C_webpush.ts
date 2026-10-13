// Lane C (s81): Web Push for the Staff app, on WebCrypto only. No npm package, no node:crypto, so it runs on the Supabase Edge runtime (Deno) on the
// Free plan with nothing to install. RFC 8291 (message encryption, aes128gcm) + RFC 8292 (VAPID, ES256 JWT) + RFC 8030 (delivery).
//   VAPID_PUBLIC_KEY   base64url of the 65-byte uncompressed P-256 public key (also what the browser subscribes with)
//   VAPID_PRIVATE_KEY  base64url of the 32-byte private scalar d
//   VAPID_SUBJECT      mailto:... or https://... contact for the push services
// The payload is built by the caller; the lock-screen text must never carry an amount (see paid-text.ts).

const enc = new TextEncoder();

export function b64uToBytes(s: string): Uint8Array {
  const p = s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4);
  const bin = atob(p);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
export function bytesToB64u(b: Uint8Array): string {
  let s = '';
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
const cat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};
const buf = (b: Uint8Array): ArrayBuffer => b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) as ArrayBuffer;

async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, bytes: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey('raw', buf(ikm), 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt: buf(salt), info: buf(info) }, key, bytes * 8));
}

export type PushSubscriptionKeys = { endpoint: string; p256dh: string; auth: string };
export type Vapid = { publicKey: string; privateKey: string; subject: string };

/** RFC 8291 section 3: the request body for one payload. `salt` and `ephemeral` are injectable only so a test can reproduce the RFC's vector. */
export async function encryptPayload(
  sub: { p256dh: string; auth: string }, payload: Uint8Array,
  o: { salt?: Uint8Array; ephemeral?: CryptoKeyPair } = {},
): Promise<Uint8Array> {
  const uaPublic = b64uToBytes(sub.p256dh), authSecret = b64uToBytes(sub.auth);
  if (uaPublic.length !== 65 || uaPublic[0] !== 4 || authSecret.length !== 16) throw new Error('webpush: bad subscription keys');
  const eph = o.ephemeral ?? await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', eph.publicKey));
  const uaKey = await crypto.subtle.importKey('raw', buf(uaPublic), { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, eph.privateKey, 256));
  const ikm = await hkdf(authSecret, shared, cat(enc.encode('WebPush: info\0'), uaPublic, asPublic), 32);
  const salt = o.salt ?? crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12);
  if (payload.length > 3993) throw new Error('webpush: payload too large'); // one 4096-byte record: 86 header + 16 tag + 1 delimiter
  const plain = cat(payload, new Uint8Array([2])); // 0x02: the last (only) record, no padding
  const aes = await crypto.subtle.importKey('raw', buf(cek), 'AES-GCM', false, ['encrypt']);
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: buf(nonce) }, aes, buf(plain)));
  return cat(salt, new Uint8Array([0, 0, 0x10, 0]), new Uint8Array([asPublic.length]), asPublic, cipher); // rs = 4096
}

/** RFC 8292: `vapid t=<jwt>,k=<public key>`; the JWT is signed ES256 and valid 12 hours from `nowSec`. */
export async function vapidAuthorization(endpoint: string, v: Vapid, nowSec: number): Promise<string> {
  const pub = b64uToBytes(v.publicKey);
  if (pub.length !== 65 || pub[0] !== 4) throw new Error('webpush: VAPID public key must be a 65-byte uncompressed P-256 point');
  const key = await crypto.subtle.importKey('jwk', {
    kty: 'EC', crv: 'P-256', d: v.privateKey, x: bytesToB64u(pub.slice(1, 33)), y: bytesToB64u(pub.slice(33, 65)), ext: true,
  }, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const head = bytesToB64u(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const claims = bytesToB64u(enc.encode(JSON.stringify({ aud: new URL(endpoint).origin, exp: nowSec + 12 * 3600, sub: v.subject })));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(`${head}.${claims}`))); // r||s, 64 bytes
  return `vapid t=${head}.${claims}.${bytesToB64u(sig)}, k=${v.publicKey}`;
}

/** The push services the browsers use. The endpoint is a URL a client handed us and the server POSTs to it, so it must be one of these hosts:
 *  https only, no port, no credentials, and the suffix must start at a dot (fcm.googleapis.com.evil.example and evilfcm.googleapis.com are refused). */
const PUSH_EXACT = ['fcm.googleapis.com', 'updates.push.services.mozilla.com'];
const PUSH_SUFFIX = ['push.apple.com', 'notify.windows.com', 'push.services.mozilla.com', 'pushnotifications.push.google.com'];
export function isAllowedPushEndpoint(endpoint: string): boolean {
  let u: URL;
  try { u = new URL(endpoint); } catch { return false; }
  if (u.protocol !== 'https:' || u.port || u.username || u.password) return false;
  const h = u.hostname.toLowerCase();
  if (!/^[a-z0-9.-]+$/.test(h)) return false;
  return PUSH_EXACT.includes(h) || PUSH_SUFFIX.some((s) => h.endsWith('.' + s) && h.length > s.length + 1);
}

export type PushResult = { ok: boolean; status: number; gone: boolean; transient: boolean };

/** One delivery attempt. gone = the push service says this subscription is dead (404 or 410): delete it. transient = worth one retry. */
export async function sendPush(
  sub: PushSubscriptionKeys, message: { title: string; body: string; url?: string; tag?: string }, v: Vapid,
  d: { fetch?: typeof fetch; nowSec: number; ttl?: number },
): Promise<PushResult> {
  const f = d.fetch ?? fetch;
  if (!isAllowedPushEndpoint(sub.endpoint)) return { ok: false, status: 0, gone: true, transient: false }; // never POST to a host that is not a push service; gone = drop the row
  let res: Response;
  try {
    const body = await encryptPayload(sub, enc.encode(JSON.stringify(message)));
    res = await f(sub.endpoint, {
      method: 'POST',
      headers: {
        Authorization: await vapidAuthorization(sub.endpoint, v, d.nowSec),
        'Content-Encoding': 'aes128gcm', 'Content-Type': 'application/octet-stream',
        TTL: String(d.ttl ?? 86400), Urgency: 'normal',
      },
      body: buf(body),
      signal: AbortSignal.timeout(10_000),
    });
  } catch {
    return { ok: false, status: 0, gone: false, transient: true };
  }
  await res.body?.cancel().catch(() => {});
  const gone = res.status === 404 || res.status === 410;
  return { ok: res.status >= 200 && res.status < 300, status: res.status, gone, transient: !gone && (res.status === 429 || res.status >= 500) };
}

/** Reads the three VAPID secrets; null when any is missing, so the caller skips push and still sends the other channels. */
export function vapidFromEnv(get: (k: string) => string | undefined): Vapid | null {
  const publicKey = get('VAPID_PUBLIC_KEY'), privateKey = get('VAPID_PRIVATE_KEY'), subject = get('VAPID_SUBJECT');
  return publicKey && privateKey && subject ? { publicKey, privateKey, subject } : null;
}
