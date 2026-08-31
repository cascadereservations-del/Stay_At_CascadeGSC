import { redactLogArguments, redactLogFields, type RedactionRoute } from './redaction.ts';

export type CascadeRoute = RedactionRoute;
export type CascadeConsole = Pick<Console, 'log' | 'warn' | 'error' | 'info' | 'debug'>;
export type ObservabilityOptions = {
  functionName: string;
  route: CascadeRoute;
  consoleTarget?: CascadeConsole;
};

type RequestHandler = (request: Request) => Response | Promise<Response>;

const installedConsoles = new WeakSet<object>();
const levels = ['log', 'warn', 'error', 'info', 'debug'] as const;

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

export function installRedactedConsole(target: CascadeConsole, route: CascadeRoute): CascadeConsole {
  if (installedConsoles.has(target as object)) return target;
  for (const level of levels) {
    const sink = target[level].bind(target);
    target[level] = (...args: unknown[]) => sink(...redactLogArguments(args, route));
  }
  installedConsoles.add(target as object);
  return target;
}

function appendHeaderToken(headers: Headers, name: string, token: string): void {
  const values = (headers.get(name) ?? '').split(',').map((value) => value.trim()).filter(Boolean);
  if (!values.some((value) => value.toLowerCase() === token.toLowerCase())) values.push(token);
  headers.set(name, values.join(', '));
}

function addCorrelationHeaders(response: Response, requestId: string): Response {
  const headers = new Headers(response.headers);
  headers.set('x-cascade-correlation-id', requestId);
  appendHeaderToken(headers, 'Access-Control-Allow-Headers', 'X-Cascade-Correlation-Id');
  appendHeaderToken(headers, 'Access-Control-Expose-Headers', 'X-Cascade-Correlation-Id');
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export function withObservability(options: ObservabilityOptions, handler: RequestHandler): RequestHandler {
  const target = installRedactedConsole(options.consoleTarget ?? console, options.route);
  return async (request: Request): Promise<Response> => {
    const startedAt = Date.now();
    const requestId = correlationId(request.headers);
    const requestHeaders = new Headers(request.headers);
    requestHeaders.set('x-cascade-correlation-id', requestId);
    const observedRequest = new Request(request, { headers: requestHeaders });

    try {
      const response = await handler(observedRequest);
      const reasonCode = response.status >= 200 && response.status < 400 ? 'OK' : `HTTP_${response.status}`;
      target.log(JSON.stringify(safeEvent(`${options.functionName}.request_completed`, options.route, {
        function_name: options.functionName,
        correlation_id: requestId,
        reason_code: reasonCode,
        method: request.method,
        status: response.status,
      }, startedAt)));
      return addCorrelationHeaders(response, requestId);
    } catch (_error) {
      target.error(JSON.stringify(safeEvent(`${options.functionName}.request_failed`, options.route, {
        function_name: options.functionName,
        correlation_id: requestId,
        reason_code: 'UNHANDLED_EXCEPTION',
        method: request.method,
        status: 500,
      }, startedAt)));
      throw _error;
    }
  };
}
