import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { verifyAutomationSignature } from '../_shared/automation-auth.ts';
import { parseDeliveryCallback } from '../_shared/automation-delivery.ts';

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type, x-automation-signature', 'Content-Type': 'application/json' };
const json = (body: Record<string, unknown>, status = 200) => new Response(JSON.stringify(body), { status, headers: CORS });

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const raw = await request.text();
  const secret = Deno.env.get('AUTOMATION_CALLBACK_SECRET');
  if (!secret || !await verifyAutomationSignature(secret, raw, request.headers.get('x-automation-signature') ?? '')) return json({ error: 'unauthorized' }, 401);
  let input: unknown;
  try { input = JSON.parse(raw); } catch { return json({ error: 'invalid_payload' }, 400); }
  const callback = parseDeliveryCallback(input);
  if (!callback) return json({ error: 'invalid_payload' }, 400);
  const url = Deno.env.get('SUPABASE_URL'); const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return json({ error: 'callback_unavailable' }, 503);
  const db = createClient(url, key);
  const { data, error } = await db.rpc('record_automation_delivery_callback', {
    p_callback_id: callback.callback_id,
    p_outbox_id: callback.event_id,
    p_workflow_id: callback.workflow_id,
    p_channel: callback.channel,
    p_status: callback.status,
    p_recipient_hash: callback.recipient_hash,
    p_provider_message_id: callback.provider_message_id,
    p_error_code: callback.error_code,
  });
  if (error || !data) return json({ error: 'callback_unavailable' }, 503);
  return json(data, 202);
});
