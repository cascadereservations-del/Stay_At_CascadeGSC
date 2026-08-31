import { createHeartbeatLivenessHandler } from './logic.ts';

type Row = { last_succeeded_at: string | null };
const now = () => new Date('2026-08-31T00:00:00.000Z');
const secret = 'cascade-liveness-test-secret';

function request(method = 'GET', suppliedSecret: string | null = secret): Request {
  const headers = new Headers();
  if (suppliedSecret) headers.set('x-cascade-liveness-secret', suppliedSecret);
  return new Request('https://probe.test', { method, headers });
}

function handler(result: Row | null | Error) {
  return createHeartbeatLivenessHandler({
    now,
    maxAgeSeconds: 1800,
    configuredSecret: secret,
    loadHeartbeat: async () => {
      if (result instanceof Error) throw result;
      return result;
    },
  } as unknown as Parameters<typeof createHeartbeatLivenessHandler>[0]);
}

async function body(response: Response): Promise<Record<string, unknown>> {
  return JSON.parse(await response.text());
}

Deno.test('fresh monitor heartbeat is healthy', async () => {
  const response = await handler({ last_succeeded_at: '2026-08-30T23:45:01.000Z' })(request());
  const payload = await body(response);
  if (response.status !== 200 || payload.ok !== true || payload.reason_code !== 'MONITOR_HEALTHY') throw new Error('fresh verdict');
});

Deno.test('stale monitor heartbeat is unavailable without leaking timestamps', async () => {
  const response = await handler({ last_succeeded_at: '2026-08-30T23:29:59.000Z' })(request());
  const text = await response.text();
  const payload = JSON.parse(text);
  if (response.status !== 503 || payload.ok !== false || payload.reason_code !== 'MONITOR_STALE') throw new Error('stale verdict');
  if (text.includes('2026-08-30')) throw new Error('timestamp leaked');
});

Deno.test('missing heartbeat returns a closed unavailable reason', async () => {
  const response = await handler(null)(request());
  const payload = await body(response);
  if (response.status !== 503 || payload.reason_code !== 'MONITOR_MISSING') throw new Error('missing verdict');
});

Deno.test('database failure returns a generic unavailable reason', async () => {
  const response = await handler(new Error('database host and secret details'))(request());
  const text = await response.text();
  const payload = JSON.parse(text);
  if (response.status !== 503 || payload.reason_code !== 'PROBE_UNAVAILABLE') throw new Error('failure verdict');
  if (text.includes('database') || text.includes('secret')) throw new Error('database failure leaked');
});

Deno.test('HEAD has no body and unsupported methods are denied', async () => {
  const live = handler({ last_succeeded_at: '2026-08-30T23:45:01.000Z' });
  const head = await live(request('HEAD'));
  if (head.status !== 200 || (await head.text()) !== '') throw new Error('HEAD response');
  const post = await live(request('POST'));
  const payload = await body(post);
  if (post.status !== 405 || payload.reason_code !== 'METHOD_NOT_ALLOWED') throw new Error('method boundary');
});

Deno.test('missing or invalid probe secret is rejected before database access', async () => {
  let loads = 0;
  const probe = createHeartbeatLivenessHandler({
    now,
    maxAgeSeconds: 1800,
    configuredSecret: secret,
    loadHeartbeat: async () => {
      loads += 1;
      return { last_succeeded_at: '2026-08-30T23:45:01.000Z' };
    },
  } as unknown as Parameters<typeof createHeartbeatLivenessHandler>[0]);
  const missing = await probe(request('GET', null));
  const invalid = await probe(request('GET', 'wrong-secret'));
  if (missing.status !== 401 || invalid.status !== 401 || loads !== 0) throw new Error('probe authorization boundary');
});
