// staff-guest-details v1 (s77): the staff app's "Add guest details" page (guest/). verify_jwt = true; the caller must also be an active
// owner or admin (current_staff_active with the caller's own JWT), and every write runs as the caller so the database checks
// manage_operations again and writes the history rows. The rules are in logic.ts and tested there. BUNDLES telegram-expense/guest.ts,
// guest-intake/validate.ts and _shared/cascade-core/vision.ts + providers.ts: a change to any of them must redeploy this function too.
import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { chatJson } from '../_shared/cascade-core/providers.ts';
import { visionExtractText } from '../_shared/cascade-core/vision.ts';
import { handle, json, READ_PROMPT, REASON, type Deps, type OnFile } from './logic.ts';

const BUCKET = 'guest-id-photos';
const TITLE = 'Cascade Guest Details';

function realDeps(): Deps | null {
  const url = Deno.env.get('SUPABASE_URL'), anon = Deno.env.get('SUPABASE_ANON_KEY'), service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !anon || !service) return null;
  const db = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
  return {
    async authenticate(token) {
      const me = createClient(url, anon, {
        global: { headers: { Authorization: `Bearer ${token}` } },
        auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      });
      const { data, error } = await me.auth.getUser(token);
      if (error || !data.user) return { ok: false, status: 401, error: 'invalid_or_expired_session' };
      const { data: allowed, error: accessError } = await me.rpc('current_staff_active', { p_roles: ['owner', 'admin'] });
      if (accessError || allowed !== true) return { ok: false, status: 403, error: 'staff_access_denied' };
      return {
        ok: true,
        ops: {
          async loadGuest(guestId): Promise<OnFile | null> {
            const [g, d, c] = await Promise.all([
              me.from('guests').select('id, name, email').eq('id', guestId).maybeSingle(),
              me.from('guest_profile_details').select('contact_number, id_on_file, id_type, stay_preferences, version').eq('guest_id', guestId).maybeSingle(),
              me.from('guest_companions').select('id, name, id_photo_path').eq('guest_id', guestId).order('created_at'),
            ]);
            if (g.error || !g.data || d.error || c.error) return null;
            return {
              guestId, name: g.data.name, email: g.data.email ?? null, phone: d.data?.contact_number ?? null, idOnFile: !!d.data?.id_on_file,
              idType: d.data?.id_type ?? null, notes: d.data?.stay_preferences ?? null, version: d.data?.version ?? null,
              companions: (c.data ?? []).map((x) => ({ id: x.id, name: x.name, hasPhoto: !!x.id_photo_path })),
            };
          },
          saveProfile: async (guestId, patch, version) =>
            await me.rpc('save_guest_profile_v1', { p_guest_id: guestId, p_patch: patch, p_expected_version: version, p_reason: REASON }),
          saveCompanion: async (guestId, companionId, patch) =>
            await me.rpc('save_guest_companion_v1', { p_guest_id: guestId, p_companion_id: companionId, p_patch: patch, p_expected_version: null, p_reason: REASON }),
          async setEmail(guestId, email) {
            const { data, error } = await me.from('guests').update({ email, email_normalized: email, updated_at: new Date().toISOString() }).eq('id', guestId).is('email', null).select('id');
            return error ? error.message : (data?.length ?? 0) === 1 ? null : 'not_updated';
          },
          upload: async (path, bytes, mime) => (await me.storage.from(BUCKET).upload(path, bytes, { contentType: mime, upsert: false })).error?.message ?? null,
          async remove(path) { await me.storage.from(BUCKET).remove([path]); },
        },
      };
    },
    async stay(uid) {
      const { data: e } = await db.from('calendar_events').select('uid, property_id, guest_name, source, checkin_date, checkout_date, linked_reservation_id')
        .eq('uid', uid).eq('status', 'confirmed').maybeSingle();
      if (!e) return null;
      const { data: gid } = await db.rpc('staff_stay_guest_id_v1', { p_property_id: e.property_id, p_uid: e.uid, p_linked: e.linked_reservation_id, p_checkin: e.checkin_date, p_checkout: e.checkout_date });
      return { uid: e.uid, guestId: (gid as string | null) ?? null, guestName: e.guest_name, checkin: e.checkin_date, checkout: e.checkout_date, source: e.source };
    },
    readImage: (bytes, mime) => visionExtractText(READ_PROMPT, bytes, mime, TITLE),
    // Paid route on purpose (tier full): the free 'routine' tier must never see guest data (providers.ts routineFirst).
    readText: (text) => chatJson({ system: READ_PROMPT, history: [], question: `Guest text:\n"""${text}"""`, title: TITLE, temperature: 0, maxTokens: 600, timeoutMs: 30_000 }),
    uuid: () => crypto.randomUUID(),
    log: (line) => console.log(line),
  };
}

Deno.serve(async (req: Request) => {
  const deps = realDeps();
  if (!deps && req.method === 'POST') return json({ ok: false, error: 'guest_details_unavailable' }, 503);
  return handle(req, deps ?? ({} as Deps));
});
