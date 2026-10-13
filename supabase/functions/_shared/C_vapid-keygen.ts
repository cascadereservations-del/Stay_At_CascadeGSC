// Lane C (s81): makes one VAPID key pair for Web Push. Lloyd runs this once on his own machine; the agent never does.
//   deno run supabase/functions/_shared/C_vapid-keygen.ts
// It prints the two values to the terminal only (nothing is written to disk). Store them as Supabase secrets, never in a file or a chat:
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (a mailto: address, for example mailto:cascadereservations@gmail.com)
import { bytesToB64u } from './C_webpush.ts';

const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
const pub = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
const jwk = await crypto.subtle.exportKey('jwk', pair.privateKey);
console.log(`VAPID_PUBLIC_KEY=${bytesToB64u(pub)}`);
console.log(`VAPID_PRIVATE_KEY=${jwk.d}`);
console.log('VAPID_SUBJECT=mailto:cascadereservations@gmail.com');
