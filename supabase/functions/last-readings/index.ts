import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { requireStaffAccess, staffAuthResponse } from '../_shared/staff-auth.ts';
import { withObservability } from '../_shared/observability.ts';
import { meterNeighbours, type MeterRow } from '../_shared/meter-order.ts';

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
    const params = new URL(req.url).searchParams;
    const propertyId = params.get('property_id') ?? '';
    await requireStaffAccess(req, 'read_operations', propertyId);
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false } }
    );

    // The readings either side of the stay being reported, by stay check-out date (2026-10-27), with the same
    // rules submit-cleaning uses (meter-order.ts): flagged-wrong numbers (D-219) and mid-stays (D-160) never count.
    // No checkout_date = today, which gives the newest reading as before.
    const asked = params.get('checkout_date') ?? '';
    const key = /^\d{4}-\d{2}-\d{2}$/.test(asked) ? asked : new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
    const { data, error } = await supabase
      .from('meter_readings')
      .select('electric_curr, water_curr, recorded_at, meter_flag, cleaning_sessions(cleaning_type, checkout_date)')
      .eq('property_id', propertyId)
      .order('recorded_at', { ascending: false })
      .limit(400);

    if (error) throw error;
    const n = meterNeighbours(data as MeterRow[] | null, key);

    const payload = {
      electric: n.prevElec?.value ?? null,
      water:    n.prevWater?.value ?? null,
      date:     n.prevElec?.key ?? n.prevWater?.key ?? null,
      next: (n.nextElec || n.nextWater) ? {
        electric: n.nextElec?.value ?? null,
        water:    n.nextWater?.value ?? null,
        date:     n.nextElec?.key ?? n.nextWater?.key ?? null,
      } : null,
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
