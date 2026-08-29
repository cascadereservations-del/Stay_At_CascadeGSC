import { parseManagementRequest } from './validation.ts';

type RpcResult = { data: unknown; errorCode: string | null };

export type StaffAccessDependencies = {
  verifyUser(token: string): Promise<boolean>;
  currentAccess(): Promise<RpcResult>;
  manageAccess(params: {
    p_target_user_id: string;
    p_action: string;
    p_role: string | null;
    p_property_ids: string[] | null;
    p_reason: string;
  }): Promise<RpcResult>;
};

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

function rpcFailure(errorCode: string | null): Response {
  if (errorCode === '42501') return json({ error: 'staff_access_denied' }, 403);
  if (errorCode === '22023' || errorCode === '22P02') return json({ error: 'invalid_request' }, 400);
  return json({ error: 'staff_access_unavailable' }, 503);
}

export async function handleStaffAccessRequest(request: Request, dependencies: StaffAccessDependencies): Promise<Response> {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (request.method !== 'GET' && request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const authorization = request.headers.get('authorization') ?? '';
  const match = /^Bearer\s+([^\s]+)$/i.exec(authorization);
  if (!match) return json({ error: 'authentication_required' }, 401);
  try {
    if (!await dependencies.verifyUser(match[1])) return json({ error: 'authentication_required' }, 401);
  } catch {
    return json({ error: 'authentication_required' }, 401);
  }

  if (request.method === 'GET') {
    let result: RpcResult;
    try {
      result = await dependencies.currentAccess();
    } catch {
      return json({ error: 'staff_access_unavailable' }, 503);
    }
    if (result.errorCode) return rpcFailure(result.errorCode);
    if (!result.data) return json({ error: 'staff_access_denied' }, 403);
    return json({ ok: true, access: result.data });
  }

  const declaredLength = Number(request.headers.get('content-length') ?? '0');
  if (Number.isFinite(declaredLength) && declaredLength > 8192) return json({ error: 'invalid_request' }, 400);
  let input: unknown;
  try {
    const raw = await request.text();
    if (raw.length > 8192) return json({ error: 'invalid_request' }, 400);
    input = JSON.parse(raw);
  } catch {
    return json({ error: 'invalid_request' }, 400);
  }
  const parsed = parseManagementRequest(input);
  if (!parsed.ok) return json({ error: parsed.error }, 400);
  let result: RpcResult;
  try {
    result = await dependencies.manageAccess({
      p_target_user_id: parsed.value.target_user_id,
      p_action: parsed.value.action,
      p_role: parsed.value.role,
      p_property_ids: parsed.value.property_ids,
      p_reason: parsed.value.reason,
    });
  } catch {
    return json({ error: 'staff_access_unavailable' }, 503);
  }
  if (result.errorCode) return rpcFailure(result.errorCode);
  return json({ ok: true, result: result.data });
}
