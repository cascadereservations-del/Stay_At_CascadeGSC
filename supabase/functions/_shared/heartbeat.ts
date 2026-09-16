// Job heartbeat helper (Sprint 0, 2026-09-16). Copied from turnover-verifier's inline
// recordHeartbeat so every scheduled function reports liveness the same way and the
// job-heartbeat-monitor can see it die. record_job_heartbeat refuses an unknown
// job_name, so a new job needs its job_heartbeats row seeded first (see
// stay-site/supabase/sql/2026-09-16-sprint0-heartbeats-and-cron.sql).
// ponytail: a failed heartbeat write only warns; liveness must never break the job.
export function heartbeat(db: { rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<{ error: { message: string } | null }> }, jobName: string) {
  return async (phase: 'started' | 'succeeded' | 'failed', errorCode: string | null = null): Promise<void> => {
    try {
      const { error } = await db.rpc('record_job_heartbeat', { p_job_name: jobName, p_phase: phase, p_error_code: errorCode });
      if (error) console.warn(`[${jobName}] heartbeat write failed:`, error.message);
    } catch (e) {
      console.warn(`[${jobName}] heartbeat write threw:`, String(e).slice(0, 200));
    }
  };
}
