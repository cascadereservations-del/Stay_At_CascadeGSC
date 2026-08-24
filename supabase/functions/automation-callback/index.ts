import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { verifyAutomationSignature } from '../_shared/automation-auth.ts';

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type, x-automation-signature', 'Content-Type': 'application/json' };
const WORKFLOWS = new Set(['CH-S01','CH-W01','CH-W02','CH-W03','CH-W04','CH-W05','CH-W06','CH-W07','CH-W08','CH-W09','CH-W10','CH-W11','CH-W12']);
const CHANNELS = new Set(['email','telegram','whatsapp','internal']);
const STATUSES = new Set(['sent','failed','skipped']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const json = (body: Record<string, unknown>, status = 200) => new Response(JSON.stringify(body), { status, headers: CORS });

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const raw = await request.text();
  const secret = Deno.env.get('AUTOMATION_CALLBACK_SECRET');
  if (!secret || !await verifyAutomationSignature(secret, raw, request.headers.get('x-automation-signature') ?? '')) return json({ error: 'unauthorized' }, 401);
  let body: Record<string, unknown>;
  try { body = JSON.parse(raw); } catch { return json({ error: 'invalid_payload' }, 400); }
  const allowed = new Set(['event_id','workflow_id','channel','status','recipient_hash','provider_message_id','error_code']);
  if (Object.keys(body).some((key) => !allowed.has(key)) || typeof body.event_id !== 'string' || !UUID.test(body.event_id) || typeof body.workflow_id !== 'string' || !WORKFLOWS.has(body.workflow_id) || typeof body.channel !== 'string' || !CHANNELS.has(body.channel) || typeof body.status !== 'string' || !STATUSES.has(body.status)) return json({ error: 'invalid_payload' }, 400);
  const url = Deno.env.get('SUPABASE_URL'); const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return json({ error: 'callback_unavailable' }, 503);
  const db = createClient(url, key);
  const delivery = { outbox_id: body.event_id, workflow_id: body.workflow_id, channel: body.channel, status: body.status, recipient_hash: typeof body.recipient_hash === 'string' ? body.recipient_hash.slice(0, 128) : null, provider_message_id: typeof body.provider_message_id === 'string' ? body.provider_message_id.slice(0, 256) : null, error_code: typeof body.error_code === 'string' && /^[a-z0-9_]{1,64}$/i.test(body.error_code) ? body.error_code : null, completed_at: body.status === 'sent' || body.status === 'skipped' ? new Date().toISOString() : null };
  const { error: insertError } = await db.from('automation_delivery_log').insert(delivery);
  if (insertError) return json({ error: 'callback_unavailable' }, 503);
  const outboxStatus = body.status === 'sent' || body.status === 'skipped' ? 'completed' : 'failed';
  await db.from('automation_outbox').update({ status: outboxStatus, completed_at: outboxStatus === 'completed' ? new Date().toISOString() : null, last_error_code: delivery.error_code, attempt_count: 1 }).eq('id', body.event_id);
  return json({ ok: true }, 202);
});
