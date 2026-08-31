import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { requireStaffAccess, staffAuthResponse } from '../_shared/staff-auth.ts';
import { withObservability } from '../_shared/observability.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
};

Deno.serve(withObservability({ functionName: 'last-readings', route: 'ops' }, async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS });
  }

  try {
    const propertyId = new URL(req.url).searchParams.get('property_id') ?? '';
    await requireStaffAccess(req, 'read_operations', propertyId);
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false } }
    );

    // Fetch the single most-recent meter_readings row
    const { data, error } = await supabase
      .from('meter_readings')
      .select('electric_curr, water_curr, recorded_at')
      .eq('property_id', propertyId)
      .order('recorded_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (error) throw error;

    const payload = {
      electric: data?.electric_curr ?? null,
      water:    data?.water_curr    ?? null,
      date:     data?.recorded_at   ?? null,
    };

    return new Response(JSON.stringify(payload), {
      status: 200,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });

  } catch (err) {
    const authResponse = staffAuthResponse(err, CORS);
    if (authResponse) return authResponse;
    console.error('last-readings error:', err);
    return new Response(
      JSON.stringify({ electric: null, water: null, error: String(err) }),
      { status: 500, headers: { ...CORS, 'Content-Type': 'application/json' } }
    );
  }
}));
