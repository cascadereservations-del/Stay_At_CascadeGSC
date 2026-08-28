import { createNotification } from '../_shared/notifications.ts';

export type JobHeartbeat = {
  job_name: string;
  expected_interval_seconds: number;
  last_started_at: string | null;
  last_succeeded_at: string | null;
  last_error_code: string | null;
  consecutive_failures: number;
  ops_risk: boolean;
};

export type StaleHeartbeat = JobHeartbeat & {
  reason_code: 'JOB_NEVER_SUCCEEDED' | 'JOB_CONSECUTIVE_FAILURE' | 'JOB_HEARTBEAT_STALE';
  stale_reference: string;
};

export type StaleJobNotification = {
  idempotency_key: string;
  route_class: 'finance' | 'ops';
  template_key: string;
  payload: Record<string, unknown>;
};

function parsedTime(value: string | null): number | null {
  if (!value) return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

export function findStaleHeartbeats(rows: JobHeartbeat[], now = new Date()): StaleHeartbeat[] {
  const nowMs = now.getTime();
  return rows.flatMap((row) => {
    if (!Number.isInteger(row.expected_interval_seconds) || row.expected_interval_seconds < 60) return [];
    const lastStarted = parsedTime(row.last_started_at);
    const lastSucceeded = parsedTime(row.last_succeeded_at);
    const reference = lastSucceeded ?? lastStarted;
    if (reference === null) {
      return [{ ...row, reason_code: 'JOB_NEVER_SUCCEEDED' as const, stale_reference: 'never' }];
    }

    const graceMs = row.expected_interval_seconds * 1.5 * 1000;
    const failedAfterSuccess = row.consecutive_failures > 0
      && lastStarted !== null
      && (lastSucceeded === null || lastStarted > lastSucceeded);
    if (!failedAfterSuccess && nowMs - reference <= graceMs) return [];

    const reason = lastSucceeded === null
      ? 'JOB_NEVER_SUCCEEDED' as const
      : failedAfterSuccess
        ? 'JOB_CONSECUTIVE_FAILURE' as const
        : 'JOB_HEARTBEAT_STALE' as const;
    return [{ ...row, reason_code: reason, stale_reference: row.last_succeeded_at ?? row.last_started_at ?? 'never' }];
  });
}

function safeJobKey(jobName: string): string {
  return jobName.toLowerCase().replace(/[^a-z0-9_-]+/g, '-').slice(0, 64);
}

export function buildStaleJobNotifications(
  rows: StaleHeartbeat[],
  correlationId: string,
): StaleJobNotification[] {
  return rows.flatMap((row) => {
    const fingerprint = `${safeJobKey(row.job_name)}:${row.reason_code}:${row.stale_reference}`;
    const finance = createNotification({
      route: 'finance',
      template: 'finance.system_failure',
      fields: {
        job_name: row.job_name,
        reason_code: row.reason_code,
        correlation_id: correlationId,
        last_succeeded_at: row.last_succeeded_at ?? 'never',
        consecutive_failures: row.consecutive_failures,
      },
    });
    const notifications: StaleJobNotification[] = [{
      idempotency_key: `job.stale:finance:${fingerprint}`.slice(0, 160),
      route_class: 'finance',
      template_key: finance.template,
      payload: { ...finance.fields, rendered_text: finance.text },
    }];

    if (row.ops_risk) {
      const ops = createNotification({
        route: 'ops',
        template: 'ops.operational_risk',
        fields: {
          job_name: row.job_name,
          reason_code: row.reason_code,
          correlation_id: correlationId,
          impact: 'Scheduled operational checks require manual review.',
        },
      });
      notifications.push({
        idempotency_key: `job.stale:ops:${fingerprint}`.slice(0, 160),
        route_class: 'ops',
        template_key: ops.template,
        payload: { ...ops.fields, rendered_text: ops.text },
      });
    }
    return notifications;
  });
}
