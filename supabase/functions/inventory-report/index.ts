// inventory-report v1 (s84 lane I): PDF stock reports built here and posted to Telegram with sendDocument.
//   kind: order | all | consumables | low | misc;  to: finance (prices, read_finance callers only) | ops (no money at all, D-306).
// verify_jwt = true; requireStaffAccess re-checks read_operations inside. Called from the staff app with supabase-js (CORS in handler.ts).
// Secrets by name: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, TELEGRAM_FINANCE_CHAT_ID, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY.
// ponytail: no server rate limit; the staff app disables the button for 30 s after a send. Add a per-user limit if anyone spams OPS.
import { withObservability } from '../_shared/observability.ts';
import { makeHandler } from './handler.ts';

Deno.serve(withObservability({ functionName: 'inventory-report', route: 'ops' }, makeHandler()));
