// inventory-categorise v1 (s86 lane D-cat): Jev (typesafe/jev-1.13 via OpenRouter Decisions, D-271) sorts items that sit in
// 'Uncategorised' into the existing categories. Request {item_id} or {all:true} (max 50 per call). Gate manage_inventory.
// verify_jwt = true; requireStaffAccess re-checks inside. Called from the staff app with supabase-js (CORS in handler.ts).
// Secrets by name: CASCADE_OPENROUTER_BOT_KEY, TELEGRAM_BOT_TOKEN, TELEGRAM_FINANCE_CHAT_ID, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY.
import { withObservability } from '../_shared/observability.ts';
import { makeHandler } from './handler.ts';

Deno.serve(withObservability({ functionName: 'inventory-categorise', route: 'ops' }, makeHandler()));
