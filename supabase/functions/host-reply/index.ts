// host-reply v1 (SPEC-42 section 7): the Conversations panel's Send button. verify_jwt = true; the caller must also be an active
// owner or admin (current_staff_active, called with the caller's own JWT so a revoked session is refused). A guest is messaged only
// when the page posts action 'send' for one thread, never on its own. The rules live in logic.ts and are unit tested there.
// Sends with the HUMAN_AGENT tag through the shared Messenger helper; messenger-concierge is not touched or imported. A handoff is claimed
// (open -> sent) before the send and put back if Messenger refuses; the OPS card is edited afterwards with every text through maskMoney (D-306).
import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { fbSendText, HOST_HOLD_MS, laterOf } from '../_shared/cascade-core/messenger.ts';
import { appendHostTurn, handleHostReply, json, staffNameFromUser, type Deps, type Turn } from './logic.ts';

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
      return { ok: true, staff: { name: staffNameFromUser(u) } };
    },
    async loadThread(psid) {
      const { data } = await db.from('concierge_threads').select('psid, history').eq('psid', psid).maybeSingle();
      return data ? { psid: data.psid as string, history: (Array.isArray(data.history) ? data.history : []) as Turn[] } : null;
    },
    async loadHandoff(id) {
      const { data } = await db.from('concierge_handoffs').select('id, psid, status, guest_name, guest_text, tg_message_id').eq('id', id).maybeSingle();
      return data ? { id: data.id as string, psid: data.psid as string, status: data.status as string, guest_name: data.guest_name as string | null, guest_text: data.guest_text as string | null, tg_message_id: data.tg_message_id as number | null } : null;
    },
    send: (psid, text) => fbSendText(psid, text, true),
    async claim({ handoffId, final, name, nowIso }) {
      const { data, error } = await db.from('concierge_handoffs')
        .update({ status: 'sent', sent_text: final, resolved_by: name, resolved_at: nowIso }).eq('id', handoffId).eq('status', 'open').select('id');
      return !error && (data?.length ?? 0) === 1;
    },
    async unclaim(handoffId, final) {
      try {
        await db.from('concierge_handoffs').update({ status: 'open', sent_text: null, resolved_by: null, resolved_at: null }).eq('id', handoffId).eq('sent_text', final);
      } catch (e) { console.error('host_reply_unclaim_failed', String(e).slice(0, 120)); }
    },
    async editCard(tgMessageId, text) {
      // Best effort and silent: no bot token or chat id, or a Telegram error, never changes the reply result. No reply_markup removes the buttons.
      const token = Deno.env.get('TELEGRAM_BOT_TOKEN'), chat = Deno.env.get('TELEGRAM_CHAT_ID');
      if (!token || !chat) return;
      await fetch(`https://api.telegram.org/bot${token}/editMessageText`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(10_000),
        body: JSON.stringify({ chat_id: chat, message_id: tgMessageId, text }),
      }).catch(() => null);
    },
    async record({ psid, final, nowIso }) {
      // The guest already has the message. A failed write here is reported (recorded: false), never retried into a second send.
      let thread = false;
      try {
        const { data: t } = await db.from('concierge_threads').select('history, human_until').eq('psid', psid).maybeSingle();
        // D-317: a person replied from the admin - Cassy stays quiet on this chat from now on (our app id, so no echo hold).
        const { error } = await db.from('concierge_threads').update({ history: appendHostTurn((t?.history ?? []) as Turn[], final, nowIso), human_until: laterOf(t?.human_until, Date.parse(nowIso) + HOST_HOLD_MS), updated_at: nowIso }).eq('psid', psid);
        thread = !error;
      } catch (e) { console.error('host_reply_history_failed', String(e).slice(0, 120)); }
      console.log('host_reply_sent', JSON.stringify({ thread }));
      return { thread };
    },
    now: () => new Date(),
  };
}

Deno.serve(async (req: Request) => {
  const deps = realDeps();
  if (!deps && req.method === 'POST') return json({ ok: false, error: 'host_reply_unavailable' }, 503);
  return handleHostReply(req, deps ?? ({} as Deps));
});
