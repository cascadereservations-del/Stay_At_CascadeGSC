import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { cronSecretMatches } from '../_shared/cron-auth.ts';
import { buildStaleJobNotifications, findStaleHeartbeats, type JobHeartbeat } from './logic.ts';

const JSON_HEADERS = { 'Content-Type': 'application/json' };
const json = (body: Record<string, unknown>, status = 200) => new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });

async function recordHeartbeat(client: any, phase: 'started' | 'succeeded' | 'failed', errorCode?: string): Promise<void> {
  const { error } = await client.rpc('record_job_heartbeat', {
    p_job_name: 'job-heartbeat-monitor-every-15m',
    p_phase: phase,
    p_error_code: errorCode ?? null,
  });
  if (error) console.warn('[job-heartbeat-monitor] heartbeat write failed:', error.message);
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const configuredSecret = Deno.env.get('CASCADE_CRON_SHARED_SECRET');
  if (!cronSecretMatches(configuredSecret, request.headers.get('x-cascade-cron-secret'))) {
    return json({ error: 'unauthorized' }, 401);
  }

  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return json({ error: 'configuration_unavailable' }, 503);
  const client = createClient(url, key, { auth: { persistSession: false } });
  await recordHeartbeat(client, 'started');

  const correlationId = request.headers.get('x-cascade-correlation-id') ?? crypto.randomUUID();
  try {
    const { data, error } = await client
      .from('job_heartbeats')
      .select('job_name,expected_interval_seconds,last_started_at,last_succeeded_at,last_error_code,consecutive_failures,ops_risk')
      .neq('job_name', 'job-heartbeat-monitor-every-15m');
    if (error) throw new Error('heartbeat_query_failed');

    const stale = findStaleHeartbeats((data ?? []) as JobHeartbeat[]);
    const notifications = buildStaleJobNotifications(stale, correlationId);
    for (const notification of notifications) {
      const { error: insertError } = await client.from('automation_outbox').upsert({
        event_type: 'system.job_stale',
        aggregate_type: 'scheduled_job',
        aggregate_id: crypto.randomUUID(),
        idempotency_key: notification.idempotency_key,
        route_class: notification.route_class,
        template_key: notification.template_key,
        payload: notification.payload,
      }, { onConflict: 'idempotency_key', ignoreDuplicates: true });
      if (insertError) throw new Error('outbox_enqueue_failed');
    }

    await recordHeartbeat(client, 'succeeded');
    return json({ ok: true, stale_jobs: stale.length, notifications: notifications.length, correlation_id: correlationId });
  } catch (error) {
    console.error('[job-heartbeat-monitor] failed:', error);
    await recordHeartbeat(client, 'failed', 'MONITOR_FAILED');
    return json({ ok: false, error: 'monitor_failed', correlation_id: correlationId }, 500);
  }
});
