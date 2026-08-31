import * as observability from './observability.ts';

const api = observability as unknown as Record<string, unknown>;
const correlationId = observability.correlationId;
const safeEvent = observability.safeEvent;

type TestConsole = Pick<Console, 'log' | 'warn' | 'error' | 'info' | 'debug'>;
type Wrapper = (
  options: { functionName: string; route: 'ops'; consoleTarget?: TestConsole },
  handler: (request: Request) => Response | Promise<Response>,
) => (request: Request) => Promise<Response>;

function wrapper(): Wrapper {
  if (typeof api.withObservability !== 'function') throw new Error('withObservability must be exported');
  return api.withObservability as Wrapper;
}

function captureConsole(): { target: TestConsole; entries: unknown[][] } {
  const entries: unknown[][] = [];
  const capture = (...args: unknown[]) => entries.push(args);
  return {
    target: { log: capture, warn: capture, error: capture, info: capture, debug: capture },
    entries,
  };
}

Deno.test('accepts a safe correlation ID and replaces unsafe input', () => {
  if (correlationId(new Headers({ 'x-cascade-correlation-id': 'cascade_12345678' })) !== 'cascade_12345678') throw new Error('safe ID lost');
  if (correlationId(new Headers({ 'x-cascade-correlation-id': 'bad id' })) === 'bad id') throw new Error('unsafe ID accepted');
});

Deno.test('safe event includes duration and redacts OPS finance data', () => {
  const event = safeEvent('delivery.failed', 'ops', { message: 'payment PHP 500' }, Date.now() - 2);
  if (typeof event.duration_ms !== 'number' || String(event.message).includes('PHP 500')) throw new Error('unsafe event');
});

Deno.test('request wrapper propagates a safe correlation ID and CORS headers', async () => {
  const capture = captureConsole();
  let handlerCorrelation = '';
  const handler = wrapper()({ functionName: 'fixture', route: 'ops', consoleTarget: capture.target }, (request) => {
    handlerCorrelation = request.headers.get('x-cascade-correlation-id') ?? '';
    return new Response('ok', {
      status: 200,
      headers: {
        'Access-Control-Allow-Headers': 'authorization, content-type',
        'Access-Control-Expose-Headers': 'etag',
      },
    });
  });
  const response = await handler(new Request('https://fixture.test', {
    headers: { 'x-cascade-correlation-id': 'cascade_12345678' },
  }));

  if (handlerCorrelation !== 'cascade_12345678') throw new Error('handler correlation missing');
  if (response.headers.get('x-cascade-correlation-id') !== 'cascade_12345678') throw new Error('response correlation missing');
  if (!response.headers.get('access-control-allow-headers')?.toLowerCase().includes('x-cascade-correlation-id')) throw new Error('CORS allow header missing');
  if (!response.headers.get('access-control-expose-headers')?.toLowerCase().includes('x-cascade-correlation-id')) throw new Error('CORS expose header missing');

  const eventLine = capture.entries.at(-1)?.[0];
  if (typeof eventLine !== 'string') throw new Error('completion event must be one JSON log line');
  const event = JSON.parse(eventLine) as Record<string, unknown>;
  if (event.event !== 'fixture.request_completed' || event.reason_code !== 'OK' || event.status !== 200) throw new Error('completion event mismatch');
  if (event.function_name !== 'fixture' || event.correlation_id !== 'cascade_12345678') throw new Error('completion identifiers missing');
});

Deno.test('request wrapper replaces unsafe IDs and rethrows failures after safe logging', async () => {
  const capture = captureConsole();
  const handler = wrapper()({ functionName: 'fixture', route: 'ops', consoleTarget: capture.target }, () => {
    capture.target.error({ nested: { email: 'guest@example.com' }, amount: 'PHP 500' });
    throw new Error('guest@example.com private failure');
  });

  let failed = false;
  try {
    await handler(new Request('https://fixture.test', { headers: { 'x-cascade-correlation-id': 'bad id' } }));
  } catch {
    failed = true;
  }
  if (!failed) throw new Error('handler failure was swallowed');

  const serialized = JSON.stringify(capture.entries);
  if (serialized.includes('guest@example.com') || serialized.includes('PHP 500') || serialized.includes('bad id')) throw new Error('unsafe console value retained');
  if (!serialized.includes('UNHANDLED_EXCEPTION')) throw new Error('safe failure reason missing');
});
