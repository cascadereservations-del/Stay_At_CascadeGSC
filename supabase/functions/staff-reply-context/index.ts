// staff-reply-context v1 (record-booking B5): the Staff reply panel's fill context for one chat. verify_jwt = true; the caller must
// also be an active owner or admin (current_staff_active, called with the caller's own JWT), exactly as host-reply. Read-only: no
// message is sent and nothing is written. Every service-role read below runs only after that check (see logic.ts). The rules live
// in logic.ts and are unit tested there. Imports messenger-concierge/booking.ts (parsers, quote) without editing it.
import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { currentCard, loadCard } from '../_shared/cascade-core/pricing.ts';
import { handleReplyContext, json, type Booking, type Deps, type Thread, type Turn } from './logic.ts';

function realDeps(): Deps | null {
  const url = Deno.env.get('SUPABASE_URL');
  const anon = Deno.env.get('SUPABASE_ANON_KEY');
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !anon || !service) return null;
  const db = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
  return {
    async authenticate(token) {
      const caller = createClient(url, anon, {
        global: { headers: { Authorization: `Bearer ${token}` } },
        auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      });
      const { data, error } = await caller.auth.getUser(token);
      if (error || !data.user) return { ok: false, status: 401, error: 'invalid_or_expired_session' };
      const { data: allowed, error: accessError } = await caller.rpc('current_staff_active', { p_roles: ['owner', 'admin'] });
      if (accessError || allowed !== true) return { ok: false, status: 403, error: 'staff_access_denied' };
      return { ok: true };
    },
    async loadThread(psid) {
      const { data } = await db.from('concierge_threads').select('psid, guest_name, history, booking_flow').eq('psid', psid).maybeSingle();
      return data ? { psid: data.psid as string, guest_name: (data.guest_name ?? null) as string | null, history: (Array.isArray(data.history) ? data.history : []) as Turn[], booking_flow: (data.booking_flow ?? null) as Thread['booking_flow'] } : null;
    },
    async loadBooking(id) {
      const { data } = await db.from('booking_inquiries').select('id, guest_id, guest_name, checkin_date, checkout_date, pax, total_amount, deposit_amount, status').eq('id', id).maybeSingle();
      if (!data) return null;
      // `channel` arrives with the record-booking migration: read it on its own so this function works before and after that deploy.
      let channel: string | null = null;
      try {
        const c = await db.from('booking_inquiries').select('channel').eq('id', id).maybeSingle();
        if (!c.error && typeof c.data?.channel === 'string') channel = c.data.channel;
      } catch { /* column not there yet */ }
      return {
        id: data.id as string, guest_id: (data.guest_id ?? null) as string | null, guest_name: (data.guest_name ?? null) as string | null,
        checkin_date: String(data.checkin_date).slice(0, 10), checkout_date: String(data.checkout_date).slice(0, 10),
        pax: data.pax == null ? null : Number(data.pax), total_amount: data.total_amount == null ? null : Number(data.total_amount),
        deposit_amount: data.deposit_amount == null ? null : Number(data.deposit_amount), status: data.status as string, channel,
      } satisfies Booking;
    },
    async idOnFile(guestId) {
      const { data } = await db.from('guest_profile_details').select('id_on_file').eq('guest_id', guestId).maybeSingle();
      return data?.id_on_file === true;
    },
    async settings() {
      const { data } = await db.from('app_settings').select('key, value').in('key', ['wifi_ssid', 'wifi_password', 'onground_name', 'onground_phone']);
      return (data ?? []) as { key: string; value: unknown }[];
    },
    async rateCard() { await loadCard(db); return currentCard(); },
    now: () => new Date(),
  };
}

Deno.serve(async (req: Request) => {
  const deps = realDeps();
  if (!deps && req.method === 'POST') return json({ ok: false, error: 'staff_reply_context_unavailable' }, 503);
  return handleReplyContext(req, deps ?? ({} as Deps));
});
