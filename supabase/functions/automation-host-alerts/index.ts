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
//   POST { action: "sweep", window_minutes? }
//                             -> CH-W04 reconciliation. Read-only: outbox rows that
//                                stalled, failed, or completed without a delivery
//                                record. Ids and statuses only, never payloads.
//
// Auth: constant-time bearer compare against N8N_HOST_ALERTS_SECRET, the same
// pattern as automation-event-detail. Only system.job_stale rows are reachable.

const JSON_HEADERS = { 'Content-Type': 'application/json' };
const json = (body: Record<string, unknown>, status = 200) => new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ERROR_CODE = /^[A-Za-z0-9_]{1,64}$/;
const MAX_CLAIM = 10;
const STALE_DISPATCH_MS = 15 * 60 * 1000;
const WORKFLOW_ID = 'CH-S01';
const SWEEP_WORKFLOW_ID = 'CH-W04';
const SWEEP_LIMIT = 50;

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
  if (!body || typeof body !== 'object' || Array.isArray(body)) return json({ error: 'invalid_payload', reason: 'body' }, 400);

  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return json({ error: 'unavailable' }, 503);
  const db = createClient(url, key, { auth: { persistSession: false } });
  // Route-class recipients. Finance and OPS are separate Telegram groups by
  // design (OPS payloads structurally carry no money fields); the plain
  // N8N_HOST_ALERTS_CHAT_ID is the fallback for either.
  const defaultChatId = Deno.env.get('N8N_HOST_ALERTS_CHAT_ID') ?? null;
  const chatIdFor = (routeClass: string | null | undefined): string | null =>
    (routeClass === 'ops' ? Deno.env.get('N8N_HOST_ALERTS_CHAT_ID_OPS') : Deno.env.get('N8N_HOST_ALERTS_CHAT_ID_FINANCE')) ?? defaultChatId;
  const chatId = defaultChatId;

  if (body.action === 'claim') {
    const now = new Date().toISOString();
    // Also re-claim rows that were claimed but never acked (workflow died mid-run):
    // dispatched, attempt_count still 0, and older than the stale window. The ack
    // RPC increments attempt_count, so a row with any ack is never re-claimed here.
    const staleBefore = new Date(Date.now() - STALE_DISPATCH_MS).toISOString();
    const { data, error } = await db
      .from('automation_outbox')
      .select('id,event_type,route_class,template_key,payload,created_at')
      .eq('event_type', 'system.job_stale')
      .or(`status.eq.pending,and(status.eq.dispatched,attempt_count.eq.0,dispatched_at.lt.${staleBefore})`)
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
        .in('status', ['pending', 'dispatched']);
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
        recipient_chat_id: chatIdFor(r.route_class),
      };
    });
    return json({ ok: true, workflow_id: WORKFLOW_ID, recipient_chat_id: chatId, events });
  }

  if (body.action === 'sweep') {
    // CH-W04 outbox reconciliation. Strictly read-only: it never writes, never
    // claims, and never returns a payload — only ids, statuses and timestamps,
    // so guest data cannot reach n8n through this path. Reusing this endpoint
    // (and therefore the existing header-auth credential) is deliberate: the
    // alternative was minting a privileged Supabase key and storing it in the
    // stack, which is exactly what D-051 exists to avoid.
    const rawWindow = body.window_minutes;
    const windowMinutes = typeof rawWindow === 'number' && Number.isFinite(rawWindow)
      ? Math.min(Math.max(Math.trunc(rawWindow), 5), 10080)
      : 1440;
    const since = new Date(Date.now() - windowMinutes * 60 * 1000).toISOString();
    const staleBefore = new Date(Date.now() - STALE_DISPATCH_MS).toISOString();
    const shape = 'id,event_type,route_class,status,attempt_count,created_at,dispatched_at,completed_at,last_error_code';

    // Acked at least once but never closed. The claim path deliberately will
    // not re-claim these (attempt_count > 0), so nothing else would surface them.
    const stuck = await db.from('automation_outbox').select(shape)
      .eq('status', 'dispatched').gt('attempt_count', 0).lt('dispatched_at', staleBefore)
      .order('dispatched_at', { ascending: true }).limit(SWEEP_LIMIT);

    // Due to be picked up and still sitting there — nothing is polling, or the
    // event type has no workflow claiming it.
    const stalePending = await db.from('automation_outbox').select(shape)
      .eq('status', 'pending').lt('created_at', staleBefore)
      .order('created_at', { ascending: true }).limit(SWEEP_LIMIT);

    const failed = await db.from('automation_outbox').select(shape)
      .eq('status', 'failed').gte('created_at', since)
      .order('created_at', { ascending: false }).limit(SWEEP_LIMIT);

    // Closed rows that left no delivery record. Diffed in memory rather than
    // with a join, so this stays a plain read against both tables.
    const completed = await db.from('automation_outbox').select('id,event_type,route_class,completed_at')
      .eq('status', 'completed').gte('completed_at', since)
      .order('completed_at', { ascending: false }).limit(SWEEP_LIMIT);
    const completedIds = (completed.data ?? []).map((row) => row.id as string);
    let orphaned: unknown[] = [];
    if (completedIds.length > 0) {
      const logged = await db.from('automation_delivery_log').select('outbox_id').in('outbox_id', completedIds);
      if (logged.error) return json({ error: 'sweep_failed', reason: 'delivery_log' }, 503);
      const seen = new Set((logged.data ?? []).map((row) => row.outbox_id as string));
      orphaned = (completed.data ?? []).filter((row) => !seen.has(row.id as string));
    }

    const firstError = [stuck, stalePending, failed, completed].find((result) => result.error);
    if (firstError) return json({ error: 'sweep_failed', reason: 'outbox' }, 503);

    const anomalies = {
      stuck_dispatched: stuck.data ?? [],
      stale_pending: stalePending.data ?? [],
      failed: failed.data ?? [],
      completed_without_delivery: orphaned,
    };
    const counts = Object.fromEntries(Object.entries(anomalies).map(([key, rows]) => [key, (rows as unknown[]).length]));
    const total = Object.values(counts).reduce((sum, n) => sum + (n as number), 0);
    return json({
      ok: true,
      workflow_id: SWEEP_WORKFLOW_ID,
      checked_at: new Date().toISOString(),
      window_minutes: windowMinutes,
      healthy: total === 0,
      truncated: Object.values(counts).some((n) => (n as number) >= SWEEP_LIMIT),
      counts,
      anomalies,
    });
  }

  if (body.action === 'ack') {
    const eventId = body.event_id;
    const channel = body.channel;
    const status = body.status;
    const providerMessageId = body.provider_message_id ?? null;
    const errorCode = body.error_code ?? null;
    // Reasons name the field only, never its value.
    if (typeof eventId !== 'string' || !UUID.test(eventId)) return json({ error: 'invalid_payload', reason: 'event_id' }, 400);
    if (channel !== 'telegram' && channel !== 'internal') return json({ error: 'invalid_payload', reason: 'channel' }, 400);
    if (status !== 'sent' && status !== 'failed' && status !== 'skipped') return json({ error: 'invalid_payload', reason: 'status' }, 400);
    if (providerMessageId !== null && (typeof providerMessageId !== 'string' || providerMessageId.length > 256)) return json({ error: 'invalid_payload', reason: 'provider_message_id' }, 400);
    if (errorCode !== null && (typeof errorCode !== 'string' || !ERROR_CODE.test(errorCode))) return json({ error: 'invalid_payload', reason: 'error_code' }, 400);

    let recipientHash: string | null = null;
    if (channel === 'telegram') {
      const { data: row } = await db.from('automation_outbox').select('route_class').eq('id', eventId).maybeSingle();
      const recipient = chatIdFor(row?.route_class ?? null);
      recipientHash = recipient ? await sha256(recipient) : null;
    }
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

  return json({ error: 'invalid_payload', reason: 'action' }, 400);
});
