import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { correlationId, safeEvent } from '../_shared/observability.ts';
import { handleStaffAccessRequest, type StaffAccessDependencies } from './handler.ts';

Deno.serve(async (request) => {
  const startedAt = Date.now();
  const requestId = correlationId(request.headers);
  const url = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  if (!url || !anonKey) {
    return new Response(JSON.stringify({ error: 'staff_access_unavailable' }), {
      status: 503,
      headers: { 'Content-Type': 'application/json', 'x-cascade-correlation-id': requestId },
    });
  }

  const authorization = request.headers.get('authorization') ?? '';
  const db = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const dependencies: StaffAccessDependencies = {
    verifyUser: async (token) => {
      const { data, error } = await db.auth.getUser(token);
      return !error && Boolean(data.user);
    },
    currentAccess: async () => {
      const { data, error } = await db.rpc('current_staff_access');
      return { data, errorCode: error?.code ?? null };
    },
    manageAccess: async (params) => {
      const { data, error } = await db.rpc('manage_staff_access', params);
      return { data, errorCode: error?.code ?? null };
    },
  };

  const response = await handleStaffAccessRequest(request, dependencies);
  response.headers.set('x-cascade-correlation-id', requestId);
  console.log(JSON.stringify(safeEvent('staff_access_request', 'internal', {
    correlation_id: requestId,
    method: request.method,
    status: response.status,
    outcome: response.ok ? 'success' : 'rejected',
  }, startedAt)));
  return response;
});
