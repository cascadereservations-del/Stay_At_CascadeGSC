import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { createHeartbeatLivenessHandler, type HeartbeatRow } from './logic.ts';

const MONITOR_JOB = 'job-heartbeat-monitor-every-15m';

const handler = createHeartbeatLivenessHandler({
  now: () => new Date(),
  maxAgeSeconds: 1800,
  configuredSecret: Deno.env.get('CASCADE_LIVENESS_SHARED_SECRET'),
  loadHeartbeat: async (): Promise<HeartbeatRow | null> => {
    const url = Deno.env.get('SUPABASE_URL');
    const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!url || !key) throw new Error('probe_configuration_unavailable');
    const client = createClient(url, key, { auth: { persistSession: false } });
    const { data, error } = await client
      .from('job_heartbeats')
      .select('last_succeeded_at')
      .eq('job_name', MONITOR_JOB)
      .maybeSingle();
    if (error) throw new Error('probe_query_unavailable');
    return data as HeartbeatRow | null;
  },
});

Deno.serve(withObservability({ functionName: 'job-heartbeat-liveness', route: 'internal' }, handler));
