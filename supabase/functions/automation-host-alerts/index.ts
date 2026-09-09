import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';

// Poll-and-ack endpoint for CH-S01 Host Alert Router. The cascade-n8n stack is
// loopback-only, so Supabase cannot push to it; n8n pulls instead.
//
//   POST { action: "claim" }  -> up to MAX_CLAIM pending system.job_stale rows,
//                                marked dispatched, returned with rendered text
//                                and the owner chat id (from an edge secret).
//   POST { action: "ack", event_id, channel, status, provider_message_id?, error_code? }
//                             -> record_automation_delivery_callback, server-side,
//                                so n8n never holds the callback HMAC secret.
//
// Auth: constant-time bearer compare against N8N_HOST_ALERTS_SECRET, the same
// pattern as automation-event-detail. Only system.job_stale rows are reachable.

const JSON_HEADERS = { 'Content-Type': 'application/json' };
const json = (body: Record<string, unknown>, status = 200) => new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ERROR_CODE = /^[A-Za-z0-9_]{1,64}$/;
const MAX_CLAIM = 10;
const WORKFLOW_ID = 'CH-S01';

function fixedLengthEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let i = 0; i < left.length; i += 1) difference |= left.charCodeAt(i) ^ right.charCodeAt(i);
  return difference === 0;
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

type ClaimRow = {
  id: string;
  event_type: string;
  route_class: string;
  template_key: string;
  payload: Record<string, unknown> | null;
  created_at: string;
};

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const secret = Deno.env.get('N8N_HOST_ALERTS_SECRET');
  const token = (request.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (!secret || !fixedLengthEqual(token, secret)) return json({ error: 'unauthorized' }, 401);

  let body: Record<string, unknown>;
  try { body = await request.json(); } catch { return json({ error: 'invalid_payload' }, 400); }
  if (!body || typeof body !== 'object' || Array.isArray(body)) return json({ error: 'invalid_payload' }, 400);

  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return json({ error: 'unavailable' }, 503);
  const db = createClient(url, key, { auth: { persistSession: false } });
  const chatId = Deno.env.get('N8N_HOST_ALERTS_CHAT_ID') ?? null;

  if (body.action === 'claim') {
    const now = new Date().toISOString();
    const { data, error } = await db
      .from('automation_outbox')
      .select('id,event_type,route_class,template_key,payload,created_at')
      .eq('event_type', 'system.job_stale')
      .eq('status', 'pending')
      .or(`next_attempt_at.is.null,next_attempt_at.lte.${now}`)
      .order('created_at', { ascending: true })
      .limit(MAX_CLAIM);
    if (error) return json({ error: 'claim_failed' }, 503);
    const rows = (data ?? []) as ClaimRow[];
    if (rows.length > 0) {
      const { error: markError } = await db
        .from('automation_outbox')
        .update({ status: 'dispatched', dispatched_at: now })
        .in('id', rows.map((r) => r.id))
        .eq('status', 'pending');
      if (markError) return json({ error: 'claim_failed' }, 503);
    }
    const events = rows.map((r) => {
      const payload = r.payload && typeof r.payload === 'object' ? r.payload : {};
      return {
        event_id: r.id,
        event_type: r.event_type,
        route_class: r.route_class,
        template_key: r.template_key,
        text: typeof payload.rendered_text === 'string' ? payload.rendered_text : null,
        correlation_id: typeof payload.correlation_id === 'string' ? payload.correlation_id : null,
        created_at: r.created_at,
      };
    });
    return json({ ok: true, workflow_id: WORKFLOW_ID, recipient_chat_id: chatId, events });
  }

  if (body.action === 'ack') {
    const eventId = body.event_id;
    const channel = body.channel;
    const status = body.status;
    const providerMessageId = body.provider_message_id ?? null;
    const errorCode = body.error_code ?? null;
    if (typeof eventId !== 'string' || !UUID.test(eventId)) return json({ error: 'invalid_payload' }, 400);
    if (channel !== 'telegram' && channel !== 'internal') return json({ error: 'invalid_payload' }, 400);
    if (status !== 'sent' && status !== 'failed' && status !== 'skipped') return json({ error: 'invalid_payload' }, 400);
    if (providerMessageId !== null && (typeof providerMessageId !== 'string' || providerMessageId.length > 256)) return json({ error: 'invalid_payload' }, 400);
    if (errorCode !== null && (typeof errorCode !== 'string' || !ERROR_CODE.test(errorCode))) return json({ error: 'invalid_payload' }, 400);

    const recipientHash = channel === 'telegram' && chatId ? await sha256(chatId) : null;
    const { data, error } = await db.rpc('record_automation_delivery_callback', {
      p_callback_id: `s01:${channel}:${eventId.toLowerCase()}`,
      p_outbox_id: eventId,
      p_workflow_id: WORKFLOW_ID,
      p_channel: channel,
      p_status: status,
      p_recipient_hash: recipientHash,
      p_provider_message_id: providerMessageId,
      p_error_code: errorCode,
    });
    if (error || !data) return json({ error: 'callback_unavailable' }, 503);
    return json({ ok: true, result: data }, 202);
  }

  return json({ error: 'invalid_payload' }, 400);
});
