// deno test --node-modules-dir=none --allow-env _shared/C_webpush.test.ts
// Lane C (s81). The encryption is checked three ways: the exact RFC 8291 appendix A vector, a round trip decrypted by node:crypto (a different
// implementation from the WebCrypto one that encrypted it), and the VAPID JWT verified with the public key. Time is a frozen number; no network.
import { assert, assertEquals, assertRejects } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { createDecipheriv, createECDH, hkdfSync } from 'node:crypto';
import { b64uToBytes, bytesToB64u, encryptPayload, sendPush, vapidAuthorization, vapidFromEnv } from './C_webpush.ts';

const NOW = 1_790_000_000; // frozen clock (seconds)

Deno.test('RFC 8291 appendix A: the exact encrypted body for the published inputs', async () => {
  const asPub = b64uToBytes('BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8');
  const jwk = { kty: 'EC', crv: 'P-256', d: 'yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw', x: bytesToB64u(asPub.slice(1, 33)), y: bytesToB64u(asPub.slice(33)), ext: true };
  const privateKey = await crypto.subtle.importKey('jwk', jwk, { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const publicKey = await crypto.subtle.importKey('raw', asPub as unknown as BufferSource, { name: 'ECDH', namedCurve: 'P-256' }, true, []);
  const body = await encryptPayload(
    { p256dh: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4', auth: 'BTBZMqHH6r4Tts7J_aSIgg' },
    new TextEncoder().encode('When I grow up, I want to be a watermelon'),
    { salt: b64uToBytes('DGv6ra1nlYgDCS1FRnbzlw'), ephemeral: { privateKey, publicKey } },
  );
  assertEquals(bytesToB64u(body),
    'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN');
});

function decryptAsBrowser(body: Uint8Array, uaPrivate: ReturnType<typeof createECDH>, auth: Uint8Array): string {
  const salt = body.slice(0, 16), rs = new DataView(body.buffer, body.byteOffset).getUint32(16), idlen = body[20];
  const asPublic = body.slice(21, 21 + idlen), cipher = body.slice(21 + idlen);
  assertEquals(rs, 4096); assertEquals(idlen, 65);
  const uaPublic = uaPrivate.getPublicKey();
  const shared = uaPrivate.computeSecret(asPublic);
  const ikm = Buffer.from(hkdfSync('sha256', shared, auth, Buffer.concat([Buffer.from('WebPush: info\0'), uaPublic, asPublic]), 32));
  const cek = Buffer.from(hkdfSync('sha256', ikm, salt, Buffer.from('Content-Encoding: aes128gcm\0'), 16));
  const nonce = Buffer.from(hkdfSync('sha256', ikm, salt, Buffer.from('Content-Encoding: nonce\0'), 12));
  const d = createDecipheriv('aes-128-gcm', cek, nonce);
  d.setAuthTag(Buffer.from(cipher.slice(cipher.length - 16)));
  const plain = Buffer.concat([d.update(cipher.slice(0, cipher.length - 16)), d.final()]);
  assertEquals(plain[plain.length - 1], 2); // last-record delimiter
  return plain.slice(0, plain.length - 1).toString('utf8');
}

function newPhone() {
  const ecdh = createECDH('prime256v1'); ecdh.generateKeys();
  const auth = crypto.getRandomValues(new Uint8Array(16));
  return { ecdh, auth, keys: { endpoint: 'https://push.example.test/send/abc', p256dh: bytesToB64u(ecdh.getPublicKey()), auth: bytesToB64u(auth) } };
}
async function newVapid() {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const pub = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
  const jwk = await crypto.subtle.exportKey('jwk', pair.privateKey);
  return { vapid: { publicKey: bytesToB64u(pub), privateKey: String(jwk.d), subject: 'mailto:test@example.test' }, publicKey: pair.publicKey };
}

Deno.test('round trip: a browser (node:crypto) decrypts what the Edge code encrypts, including non-ASCII text', async () => {
  const p = newPhone();
  const text = JSON.stringify({ title: 'Your payment has been sent', body: 'Hi Honey, thank you for your care. Salamat po ñ' });
  const body = await encryptPayload(p.keys, new TextEncoder().encode(text));
  assertEquals(decryptAsBrowser(body, p.ecdh, p.auth), text);
  const again = await encryptPayload(p.keys, new TextEncoder().encode(text));
  assert(bytesToB64u(body) !== bytesToB64u(again), 'a fresh salt and ephemeral key every time');
});

Deno.test('bad subscription keys and oversize payloads are refused before anything is sent', async () => {
  const p = newPhone();
  await assertRejects(() => encryptPayload({ p256dh: 'AAAA', auth: p.keys.auth }, new Uint8Array(3)), Error, 'bad subscription keys');
  await assertRejects(() => encryptPayload({ p256dh: p.keys.p256dh, auth: 'AAAA' }, new Uint8Array(3)), Error, 'bad subscription keys');
  await assertRejects(() => encryptPayload(p.keys, new Uint8Array(4000)), Error, 'too large');
});

Deno.test('VAPID: the JWT verifies with the public key, names the push service origin, expires in 12 hours, and carries the key', async () => {
  const { vapid, publicKey } = await newVapid();
  const header = await vapidAuthorization('https://push.example.test/send/abc?x=1', vapid, NOW);
  const m = /^vapid t=([\w-]+)\.([\w-]+)\.([\w-]+), k=([\w-]+)$/.exec(header)!;
  assert(m, 'header shape');
  assertEquals(m[4], vapid.publicKey);
  const claims = JSON.parse(new TextDecoder().decode(b64uToBytes(m[2])));
  assertEquals(claims, { aud: 'https://push.example.test', exp: NOW + 43200, sub: 'mailto:test@example.test' });
  assertEquals(JSON.parse(new TextDecoder().decode(b64uToBytes(m[1]))), { typ: 'JWT', alg: 'ES256' });
  const sig = b64uToBytes(m[3]); assertEquals(sig.length, 64);
  assert(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, publicKey, sig as unknown as BufferSource, new TextEncoder().encode(`${m[1]}.${m[2]}`) as unknown as BufferSource));
});

Deno.test('VAPID: a public key that is not a 65-byte point is refused', async () => {
  const { vapid } = await newVapid();
  await assertRejects(() => vapidAuthorization('https://x.test/a', { ...vapid, publicKey: 'AAAA' }, NOW), Error, '65-byte');
});

Deno.test('sendPush: headers, an encrypted body the phone can read, and the answer mapped (2xx ok, 404/410 gone, 429/5xx/none transient, 400 final)', async () => {
  const p = newPhone(), { vapid } = await newVapid();
  const seen: Array<{ url: string; headers: Record<string, string>; body: Uint8Array }> = [];
  const answer = (status: number) => async (url: string | URL | Request, init?: RequestInit) => {
    seen.push({ url: String(url), headers: init!.headers as Record<string, string>, body: new Uint8Array(init!.body as ArrayBuffer) });
    return new Response(null, { status });
  };
  const msg = { title: 'Your payment has been sent', body: 'Hi Honey, your pay for Oct 10 is on its way.' };
  const ok = await sendPush(p.keys, msg, vapid, { fetch: answer(201) as typeof fetch, nowSec: NOW });
  assertEquals(ok, { ok: true, status: 201, gone: false, transient: false });
  const h = seen[0].headers;
  assertEquals([h['Content-Encoding'], h['Content-Type'], h.TTL, h.Urgency], ['aes128gcm', 'application/octet-stream', '86400', 'normal']);
  assert(h.Authorization.startsWith('vapid t='));
  assertEquals(seen[0].url, 'https://push.example.test/send/abc');
  assertEquals(JSON.parse(decryptAsBrowser(seen[0].body, p.ecdh, p.auth)), msg);
  for (const [status, gone, transient] of [[404, true, false], [410, true, false], [429, false, true], [500, false, true], [503, false, true], [400, false, false], [401, false, false]] as const) {
    const r = await sendPush(p.keys, msg, vapid, { fetch: answer(status) as typeof fetch, nowSec: NOW });
    assertEquals([r.ok, r.gone, r.transient], [false, gone, transient], String(status));
  }
  const down = await sendPush(p.keys, msg, vapid, { fetch: (() => Promise.reject(new Error('offline'))) as typeof fetch, nowSec: NOW });
  assertEquals([down.ok, down.status, down.transient], [false, 0, true]);
});

Deno.test('vapidFromEnv: all three secrets or nothing', () => {
  const env: Record<string, string> = { VAPID_PUBLIC_KEY: 'a', VAPID_PRIVATE_KEY: 'b', VAPID_SUBJECT: 'mailto:x@y.z' };
  assertEquals(vapidFromEnv((k) => env[k]), { publicKey: 'a', privateKey: 'b', subject: 'mailto:x@y.z' });
  for (const drop of Object.keys(env)) assertEquals(vapidFromEnv((k) => (k === drop ? undefined : env[k])), null);
});
