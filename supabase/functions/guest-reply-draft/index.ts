// guest-reply-draft v1 (s76): Cassy's draft replies for the admin dashboard and the staff app. verify_jwt = true; the caller must also
// be an active owner or admin (current_staff_active, called with the caller's own JWT so a revoked session is refused). Drafting is
// telegram-cassy/draft.ts (draftGuestReply, transcribeChat), reused as is. It BUNDLES telegram-cassy/draft.ts and everything that imports,
// so a change there must redeploy this function too (check-deploy-drift.mjs). Nothing is sent to a guest. Rules and tests: logic.ts.
import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { draftGuestReply, transcribeChat } from '../telegram-cassy/draft.ts';
import { handleGuestReplyDraft, json, type Deps } from './logic.ts';

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
    draft: (guestText, guestName, thread) => draftGuestReply(db, guestText, guestName, thread),
    transcribe: transcribeChat,
    now: () => Date.now(),
    log: (line) => console.log(line),
    logError: (line) => console.error(line),
  };
}

Deno.serve(async (req: Request) => {
  const deps = realDeps();
  if (!deps && req.method === 'POST') return json({ ok: false, error: 'guest_reply_draft_unavailable' }, 503);
  return handleGuestReplyDraft(req, deps ?? ({} as Deps));
});
