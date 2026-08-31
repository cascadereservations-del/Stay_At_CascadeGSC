import { cronSecretMatches } from '../_shared/cron-auth.ts';

export type HeartbeatRow = { last_succeeded_at: string | null };
export type HeartbeatLivenessDependencies = {
  loadHeartbeat: () => Promise<HeartbeatRow | null>;
  now: () => Date;
  maxAgeSeconds: number;
  configuredSecret: string | undefined;
};

export function createHeartbeatLivenessHandler(
  dependencies: HeartbeatLivenessDependencies,
): (request: Request) => Promise<Response> {
  const respond = (request: Request, ok: boolean, reasonCode: string, status: number): Response => new Response(
    request.method === 'HEAD' ? null : JSON.stringify({ ok, reason_code: reasonCode }),
    {
      status,
      headers: {
        'Content-Type': 'application/json',
        'Cache-Control': 'no-store',
      },
    },
  );

  return async (request: Request) => {
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return respond(request, false, 'METHOD_NOT_ALLOWED', 405);
    }
    if (!cronSecretMatches(dependencies.configuredSecret, request.headers.get('x-cascade-liveness-secret'))) {
      return respond(request, false, 'UNAUTHORIZED', 401);
    }
    try {
      const row = await dependencies.loadHeartbeat();
      if (!row?.last_succeeded_at) return respond(request, false, 'MONITOR_MISSING', 503);
      const succeededAt = Date.parse(row.last_succeeded_at);
      const ageSeconds = (dependencies.now().getTime() - succeededAt) / 1000;
      if (!Number.isFinite(ageSeconds) || ageSeconds < -60 || ageSeconds > dependencies.maxAgeSeconds) {
        return respond(request, false, 'MONITOR_STALE', 503);
      }
      return respond(request, true, 'MONITOR_HEALTHY', 200);
    } catch {
      return respond(request, false, 'PROBE_UNAVAILABLE', 503);
    }
  };
}
