// notify-staff-inbox v1 (s82 lane XS): the Web Push that tells owner/admin phones a guest needs them (see inbox.ts for the order of events).
// verify_jwt is off, like notify-cleaner-payment: the caller is messenger-concierge (service-role bearer) or the database (x-cascade-cron-secret);
// anything else is a 401. Secrets by name: SUPABASE_SERVICE_ROLE_KEY (built in), CASCADE_CRON_SHARED_SECRET, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT.
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { cronSecretMatches } from '../_shared/cron-auth.ts';
import { sendPush, vapidFromEnv } from '../_shared/C_webpush.ts';
import { handle, type Sub } from './inbox.ts';
import { makeDeps } from './deps.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

const authorized = (req: Request): boolean =>
  cronSecretMatches(Deno.env.get('CASCADE_CRON_SHARED_SECRET'), req.headers.get('x-cascade-cron-secret')) ||
  cronSecretMatches(SERVICE_ROLE, (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '') || null);

Deno.serve(withObservability({ functionName: 'notify-staff-inbox', route: 'ops' }, (req) => {
  const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });
  const vapid = vapidFromEnv((k) => Deno.env.get(k));
  const push = vapid ? (s: Sub, m: { title: string; body: string; url: string; tag: string }) => sendPush(s, m, vapid, { nowSec: Math.floor(Date.now() / 1000) }) : null;
  return handle(req, { authorized, deps: makeDeps(db, push, () => Date.now()) });
}));
