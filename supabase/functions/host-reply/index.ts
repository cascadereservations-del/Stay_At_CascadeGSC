// host-reply v1 (SPEC-42 section 7): the Conversations panel's Send button. verify_jwt = true; the caller must also be an active
// owner or admin (current_staff_active, called with the caller's own JWT so a revoked session is refused). A guest is messaged only
// when the page posts action 'send' for one thread, never on its own. The rules live in logic.ts and are unit tested there.
// Sends with the HUMAN_AGENT tag through the shared Messenger helper; messenger-concierge is not touched or imported.
import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { fbSendText } from '../_shared/cascade-core/messenger.ts';
import { appendHostTurn, handleHostReply, json, signOffName, type Deps, type Turn } from './logic.ts';

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
      const u = data.user;
      const display = (u.app_metadata?.display_name ?? u.user_metadata?.display_name ?? (u.email ?? '').split('@')[0].replace(/\./g, ' ')) as string;
      return { ok: true, staff: { name: signOffName(display) } };
    },
    async loadThread(psid) {
      const { data } = await db.from('concierge_threads').select('psid, history').eq('psid', psid).maybeSingle();
      return data ? { psid: data.psid as string, history: (Array.isArray(data.history) ? data.history : []) as Turn[] } : null;
    },
    async loadHandoff(id) {
      const { data } = await db.from('concierge_handoffs').select('id, psid, status').eq('id', id).maybeSingle();
      return data ? { id: data.id as string, psid: data.psid as string, status: data.status as string } : null;
    },
    send: (psid, text) => fbSendText(psid, text, true),
    async record({ psid, final, name, handoffId, nowIso }) {
      // The guest already has the message. A failed write here is reported (recorded: false), never retried into a second send.
      let thread = false, handoff = false;
      try {
        const { data: t } = await db.from('concierge_threads').select('history').eq('psid', psid).maybeSingle();
        const { error } = await db.from('concierge_threads').update({ history: appendHostTurn((t?.history ?? []) as Turn[], final, nowIso), updated_at: nowIso }).eq('psid', psid);
        thread = !error;
      } catch (e) { console.error('host_reply_history_failed', String(e).slice(0, 120)); }
      if (handoffId) {
        try {
          const { data, error } = await db.from('concierge_handoffs')
            .update({ status: 'sent', sent_text: final, resolved_by: name, resolved_at: nowIso }).eq('id', handoffId).eq('status', 'open').select('id');
          handoff = !error && (data?.length ?? 0) === 1;
        } catch (e) { console.error('host_reply_handoff_failed', String(e).slice(0, 120)); }
      }
      console.log('host_reply_sent', JSON.stringify({ by: name, thread, handoff }));
      return { thread, handoff };
    },
    now: () => new Date(),
  };
}

Deno.serve(async (req: Request) => {
  const deps = realDeps();
  if (!deps && req.method === 'POST') return json({ ok: false, error: 'host_reply_unavailable' }, 503);
  return handleHostReply(req, deps ?? ({} as Deps));
});
