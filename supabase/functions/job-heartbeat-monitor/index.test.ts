import { assertRoutePayloadSafe } from '../_shared/notifications.ts';
import {
  buildStaleJobNotifications,
  findStaleHeartbeats,
  type JobHeartbeat,
} from './logic.ts';

function equal(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) throw new Error(`${message}: expected ${expected}, got ${actual}`);
}

function heartbeat(overrides: Partial<JobHeartbeat> = {}): JobHeartbeat {
  return {
    job_name: 'turnover-verifier-daily',
    expected_interval_seconds: 86400,
    last_started_at: '2026-08-28T00:00:00.000Z',
    last_succeeded_at: '2026-08-28T00:00:10.000Z',
    last_error_code: null,
    consecutive_failures: 0,
    ops_risk: false,
    ...overrides,
  };
}

Deno.test('fresh heartbeats do not alert', () => {
  const stale = findStaleHeartbeats([heartbeat()], new Date('2026-08-28T12:00:00.000Z'));
  equal(stale.length, 0, 'stale count');
});

Deno.test('stale heartbeat creates one deterministic Finance notification', () => {
  const stale = findStaleHeartbeats([heartbeat()], new Date('2026-08-30T12:00:00.000Z'));
  const first = buildStaleJobNotifications(stale, 'correlation-1');
  const retry = buildStaleJobNotifications(stale, 'correlation-2');

  equal(first.length, 1, 'Finance-only alert count');
  equal(first[0].route_class, 'finance', 'route');
  equal(first[0].template_key, 'finance.system_failure', 'template');
  equal(first[0].idempotency_key, retry[0].idempotency_key, 'retry idempotency');
});

Deno.test('operational-risk heartbeat adds an OPS-safe alert', () => {
  const stale = findStaleHeartbeats([
    heartbeat({ ops_risk: true, last_error_code: 'TURNOVER_JOB_STALE', consecutive_failures: 2 }),
  ], new Date('2026-08-30T12:00:00.000Z'));
  const alerts = buildStaleJobNotifications(stale, 'correlation-3');

  equal(alerts.length, 2, 'Finance and OPS alert count');
  const ops = alerts.find((alert) => alert.route_class === 'ops');
  if (!ops) throw new Error('OPS alert missing');
  equal(ops.template_key, 'ops.operational_risk', 'OPS template');
  assertRoutePayloadSafe('ops', ops.payload);
});

Deno.test('never-succeeded heartbeat becomes stale after its interval', () => {
  const stale = findStaleHeartbeats([
    heartbeat({ last_started_at: '2026-08-28T00:00:00.000Z', last_succeeded_at: null }),
  ], new Date('2026-08-30T12:00:00.000Z'));
  equal(stale.length, 1, 'never-succeeded stale count');
  equal(stale[0].reason_code, 'JOB_NEVER_SUCCEEDED', 'reason');
});
