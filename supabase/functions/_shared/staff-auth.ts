import { createClient } from 'jsr:@supabase/supabase-js@2';

export interface StaffIdentity {
  userId: string;
  accessToken: string;
}

export class StaffAuthError extends Error {
  constructor(public status: number, public code: string) {
    super(code);
  }
}

export function bearerToken(request: Request): string {
  const value = request.headers.get('authorization') ?? '';
  const match = /^Bearer\s+([^\s]+)$/i.exec(value);
  if (!match) throw new StaffAuthError(401, 'authentication_required');
  return match[1];
}

export async function requireStaffAccess(
  request: Request,
  action: string,
  propertyId: string,
): Promise<StaffIdentity> {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(propertyId)) {
    throw new StaffAuthError(400, 'invalid_property_id');
  }
  const url = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  if (!url || !anonKey) throw new StaffAuthError(503, 'staff_auth_unavailable');

  const accessToken = bearerToken(request);
  const client = createClient(url, anonKey, {
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data: userData, error: userError } = await client.auth.getUser(accessToken);
  if (userError || !userData.user) throw new StaffAuthError(401, 'invalid_or_expired_session');

  const { data: allowed, error: accessError } = await client.rpc('current_staff_authorized', {
    p_action: action,
    p_property_id: propertyId,
  });
  if (accessError || allowed !== true) throw new StaffAuthError(403, 'staff_access_denied');
  return { userId: userData.user.id, accessToken };
}

export function staffAuthResponse(error: unknown, cors: Record<string, string>): Response | null {
  if (!(error instanceof StaffAuthError)) return null;
  return new Response(JSON.stringify({ ok: false, error: error.code }), {
    status: error.status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}
