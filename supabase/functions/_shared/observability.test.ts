import { correlationId, safeEvent } from './observability.ts';

Deno.test('accepts a safe correlation ID and replaces unsafe input', () => {
  if (correlationId(new Headers({ 'x-cascade-correlation-id': 'cascade_12345678' })) !== 'cascade_12345678') throw new Error('safe ID lost');
  if (correlationId(new Headers({ 'x-cascade-correlation-id': 'bad id' })) === 'bad id') throw new Error('unsafe ID accepted');
});

Deno.test('safe event includes duration and redacts OPS finance data', () => {
  const event = safeEvent('delivery.failed', 'ops', { message: 'payment PHP 500' }, Date.now() - 2);
  if (typeof event.duration_ms !== 'number' || String(event.message).includes('PHP 500')) throw new Error('unsafe event');
});
