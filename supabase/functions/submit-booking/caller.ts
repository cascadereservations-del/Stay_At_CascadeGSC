// TASKS #21 (s78): who is calling, for the hourly cap. Pure, so caller.test.ts can read it.
// cf-connecting-ip first: Cloudflare sets it in front of Supabase and overwrites any value the caller sends, whereas the
// first x-forwarded-for entry is whatever the caller wrote. ponytail: which header Supabase forwards was not read live;
// if a deploy logs submit_cap_no_ip, the cap is off and this order needs the header the platform actually sends.
const IP = /^[0-9A-Fa-f:.]{2,45}$/;

export function clientIp(h: Headers): string | null {
  for (const v of [h.get('cf-connecting-ip'), h.get('x-real-ip'), h.get('x-forwarded-for')?.split(',')[0]]) {
    const s = (v ?? '').trim();
    if (IP.test(s)) return s.toLowerCase();
  }
  return null;
}

/** HMAC-SHA256 of the address keyed by a server secret, so the stored hash cannot be turned back into an address by
 *  hashing all 4 billion IPv4 addresses (a plain or fixed-salt hash can). Only this hex ever leaves the function. */
export async function callerHash(secret: string, ip: string): Promise<string> {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', k, enc.encode('submit-booking-caller-v1|' + ip));
  return Array.from(new Uint8Array(sig), (b) => b.toString(16).padStart(2, '0')).join('');
}
