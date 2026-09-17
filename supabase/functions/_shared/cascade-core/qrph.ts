// cascade-core QR Ph (session 28, 2026-09-17). The GCash QR on the site is a static EMVCo/QR Ph
// payload (tag 27 com.p2pqrpay, GXCHPHM2XXX). Adding tag 54 (transaction amount) and flipping tag 01
// to 12 (dynamic) makes any QR Ph scanner - GCash or Maya - open with the amount already set, so the
// guest cannot mistype ₱890 as ₱980. The base payload is what the site's PNG decodes to; the amount
// version is generated per booking and sent as an image upload (no storage, no URL).
// esm.sh build: works in the edge runtime and in local deno (npm: needs node_modules locally); the deno.land/x qrcode has no quiet zone.
// @ts-ignore the @types package has no default export; the runtime module does
import QRCode from 'https://esm.sh/qrcode@1.5.4?target=denonext';

/** Decoded from https://cascadereservations-del.github.io/Stay_At_CascadeGSC/assets/images/qr-gcash.png (2026-09-17). Public by design: it is the QR every guest scans. */
export const GCASH_QRPH_BASE = '00020101021127830012com.p2pqrpay0111GXCHPHM2XXX02089996440303152170200000006560417DWQM4TK3JDNWCFOT15204601653036085802PH5909Cascades 6005CONEL610412346304350D';

/** CRC-16/CCITT-FALSE over the payload up to and including "6304", as EMVCo specifies. */
export function crc16(s: string): string {
  let c = 0xFFFF;
  for (const b of new TextEncoder().encode(s)) {
    c ^= b << 8;
    for (let i = 0; i < 8; i++) c = c & 0x8000 ? ((c << 1) ^ 0x1021) & 0xFFFF : (c << 1) & 0xFFFF;
  }
  return c.toString(16).toUpperCase().padStart(4, '0');
}

/** The base payload with tag 54 = amount (two decimals) inserted before tag 58 and the CRC recomputed. */
export function qrphWithAmount(base: string, amount: number): string {
  if (!(amount > 0) || !/6304[0-9A-F]{4}$/.test(base)) throw new Error('qrph: bad base or amount');
  const amt = amount.toFixed(2);
  let body = base.slice(0, -8).replace(/^000201010211/, '000201010212'); // dynamic once an amount rides on it
  const k = body.indexOf('5802PH'); if (k < 0) throw new Error('qrph: no country tag');
  body = body.slice(0, k) + '54' + String(amt.length).padStart(2, '0') + amt + body.slice(k) + '6304';
  return body + crc16(body);
}

/** PNG bytes for a payload; 8 px modules and a quiet zone so phone cameras read it from a chat bubble. */
export async function qrPng(payload: string): Promise<Uint8Array> {
  const buf: Uint8Array = await QRCode.toBuffer(payload, { type: 'png', errorCorrectionLevel: 'M', margin: 4, scale: 8 });
  return new Uint8Array(buf);
}
