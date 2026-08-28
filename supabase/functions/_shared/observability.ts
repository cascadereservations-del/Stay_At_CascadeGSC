import { redactLogFields } from './redaction.ts';

export type CascadeRoute = 'finance' | 'ops' | 'guest' | 'internal';

export function correlationId(headers: Headers): string {
  const supplied = headers.get('x-cascade-correlation-id')?.trim();
  return supplied && /^[A-Za-z0-9_-]{8,128}$/.test(supplied) ? supplied : crypto.randomUUID();
}

export function safeEvent(
  name: string,
  route: CascadeRoute,
  fields: Record<string, unknown>,
  startedAt: number,
): Record<string, unknown> {
  return {
    event: name,
    route,
    duration_ms: Math.max(0, Date.now() - startedAt),
    ...redactLogFields(fields, route),
  };
}
