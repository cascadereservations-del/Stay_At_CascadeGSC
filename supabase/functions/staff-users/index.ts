// staff-users v1 — owner/admin management of named staff accounts.
// Called by the admin dashboard with the caller's bearer token. The caller must be
// an enabled owner or admin in staff_access_profiles. Uses the service-role key to
// create/update Auth users; every change writes staff_access_audit. Staff sign in
// with a NAME; the Auth e-mail behind it is <slug>@staff.cascade.invalid and no
// mail is ever sent to it.
import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const STAFF_DOMAIN = 'staff.cascade.invalid';
const ROLES = ['admin', 'finance', 'inspector', 'cleaner', 'maintenance'];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}
export function slugify(name: string): string {
  return name.normalize('NFKD').replace(/[^\x00-\x7F]/g, '').toLowerCase().trim()
    .replace(/[^a-z0-9]+/g, '.').replace(/^\.+|\.+$/g, '');
}
export function staffEmail(name: string): string {
  return `${slugify(name)}@${STAFF_DOMAIN}`;
}
function displayName(email: string | undefined, meta: Record<string, unknown> | undefined): string {
  const n = meta?.display_name;
  if (typeof n === 'string' && n.trim()) return n.trim();
  return (email ?? '').split('@')[0].replace(/\./g, ' ');
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'method_not_allowed' }, 405);

  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !serviceKey) return json({ ok: false, error: 'staff_admin_unavailable' }, 503);

  const m = /^Bearer\s+(\S+)$/i.exec(req.headers.get('authorization') ?? '');
  if (!m) return json({ ok: false, error: 'authentication_required' }, 401);
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: who, error: whoErr } = await admin.auth.getUser(m[1]);
  if (whoErr || !who.user) return json({ ok: false, error: 'invalid_or_expired_session' }, 401);
  const actorId = who.user.id;

  const { data: actor } = await admin.from('staff_access_profiles')
    .select('role, disabled_at').eq('user_id', actorId).maybeSingle();
  if (!actor || actor.disabled_at || !['owner', 'admin'].includes(actor.role)) {
    return json({ ok: false, error: 'staff_access_denied' }, 403);
  }
  const actorIsOwner = actor.role === 'owner';

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'invalid_json' }, 400); }
  const action = String(body.action ?? '');

  async function audit(target: string, act: string, before: unknown, after: unknown, reason: string) {
    await admin.from('staff_access_audit').insert({
      actor_user_id: actorId, target_user_id: target, action: act,
      before_state: before ?? {}, after_state: after ?? {}, reason,
    });
  }
  async function syncMeta(userId: string, role: string, propertyIds: string[], disabled: boolean, extra: Record<string, unknown> = {}) {
    const { data: u } = await admin.auth.admin.getUserById(userId);
    const meta = { ...(u?.user?.app_metadata ?? {}), role, property_ids: propertyIds, cascade_disabled: disabled, ...extra };
    await admin.auth.admin.updateUserById(userId, { app_metadata: meta });
  }
  async function profileOf(userId: string) {
    const { data: p } = await admin.from('staff_access_profiles')
      .select('user_id, role, disabled_at, sessions_revoked_after').eq('user_id', userId).maybeSingle();
    const { data: s } = await admin.from('staff_property_access').select('property_id').eq('user_id', userId);
    return p ? { ...p, property_ids: (s ?? []).map((x: { property_id: string }) => x.property_id) } : null;
  }

  try {
    if (action === 'list') {
      const { data: profiles, error } = await admin.from('staff_access_profiles')
        .select('user_id, role, disabled_at, created_at').order('created_at');
      if (error) throw error;
      const { data: users } = await admin.auth.admin.listUsers({ perPage: 200 });
      const byId = new Map((users?.users ?? []).map(u => [u.id, u]));
      const rows = (profiles ?? []).map(p => {
        const u = byId.get(p.user_id);
        const meta = (u?.app_metadata ?? {}) as Record<string, unknown>;
        const isStaffLogin = (u?.email ?? '').endsWith('@' + STAFF_DOMAIN);
        return {
          user_id: p.user_id, role: p.role, disabled: !!p.disabled_at,
          name: displayName(u?.email, meta),
          sign_in_name: isStaffLogin ? (u?.email ?? '').split('@')[0] : null,
          is_mailbox_login: !isStaffLogin,
          last_sign_in_at: u?.last_sign_in_at ?? null, created_at: p.created_at,
        };
      });
      return json({ ok: true, staff: rows, staff_domain: STAFF_DOMAIN });
    }

    if (action === 'create') {
      const name = String(body.name ?? '').trim();
      const password = String(body.password ?? '');
      const role = String(body.role ?? 'cleaner');
      const propertyId = String(body.propertyId ?? '');
      if (name.length < 2 || !slugify(name)) return json({ ok: false, error: 'name_required' }, 400);
      if (password.length < 8) return json({ ok: false, error: 'password_min_8' }, 400);
      if (!ROLES.includes(role)) return json({ ok: false, error: 'invalid_role' }, 400);
      if (role === 'admin' && !actorIsOwner) return json({ ok: false, error: 'owner_only' }, 403);
      if (!UUID_RE.test(propertyId)) return json({ ok: false, error: 'invalid_property_id' }, 400);
      const email = staffEmail(name);
      const { data: created, error: cErr } = await admin.auth.admin.createUser({
        email, password, email_confirm: true,
        app_metadata: { role, property_ids: [propertyId], cascade_disabled: false, display_name: name },
        user_metadata: { display_name: name },
      });
      if (cErr || !created.user) {
        return json({ ok: false, error: /already|exists|registered/i.test(cErr?.message ?? '') ? 'name_taken' : 'create_failed' }, 409);
      }
      const uid = created.user.id;
      const { error: pErr } = await admin.from('staff_access_profiles').insert({ user_id: uid, role });
      if (pErr) throw pErr;
      const { error: sErr } = await admin.from('staff_property_access').insert({ user_id: uid, property_id: propertyId });
      if (sErr) throw sErr;
      await audit(uid, 'created', {}, { role, property_ids: [propertyId], display_name: name }, `Created by staff-users (${actor.role})`);
      return json({ ok: true, user_id: uid, sign_in_name: slugify(name), role });
    }

    const targetId = String(body.userId ?? '');
    if (!UUID_RE.test(targetId)) return json({ ok: false, error: 'invalid_user_id' }, 400);
    if (targetId === actorId) return json({ ok: false, error: 'self_management_denied' }, 403);
    const before = await profileOf(targetId);
    if (!before) return json({ ok: false, error: 'target_profile_not_found' }, 404);
    if (before.role === 'owner') return json({ ok: false, error: 'owner_protected' }, 403);
    if (before.role === 'admin' && !actorIsOwner) return json({ ok: false, error: 'owner_only' }, 403);
    const nowIso = new Date().toISOString();

    if (action === 'update') {
      const newPassword = typeof body.password === 'string' ? body.password : '';
      const newRole = typeof body.role === 'string' ? body.role : '';
      const newName = typeof body.name === 'string' ? body.name.trim() : '';
      const updates: Record<string, unknown> = {};
      if (newPassword) {
        if (newPassword.length < 8) return json({ ok: false, error: 'password_min_8' }, 400);
        updates.password = newPassword;
      }
      if (newName) updates.user_metadata = { display_name: newName };
      let role = before.role;
      if (newRole) {
        if (!ROLES.includes(newRole)) return json({ ok: false, error: 'invalid_role' }, 400);
        if (newRole === 'admin' && !actorIsOwner) return json({ ok: false, error: 'owner_only' }, 403);
        role = newRole;
      }
      if (Object.keys(updates).length) {
        const { error } = await admin.auth.admin.updateUserById(targetId, updates);
        if (error) throw error;
      }
      if (role !== before.role) {
        const { error } = await admin.from('staff_access_profiles')
          .update({ role, sessions_revoked_after: nowIso, updated_at: nowIso }).eq('user_id', targetId);
        if (error) throw error;
      }
      await syncMeta(targetId, role, before.property_ids, !!before.disabled_at, newName ? { display_name: newName } : {});
      const after = await profileOf(targetId);
      await audit(targetId, 'role_changed', before, { ...after, password_changed: !!newPassword, display_name: newName || undefined },
        `Updated by staff-users (${actor.role})`);
      return json({ ok: true, user_id: targetId, role, password_changed: !!newPassword });
    }

    if (action === 'disable' || action === 'enable') {
      const disabled = action === 'disable';
      const { error } = await admin.from('staff_access_profiles').update({
        disabled_at: disabled ? nowIso : null, sessions_revoked_after: nowIso, updated_at: nowIso,
      }).eq('user_id', targetId);
      if (error) throw error;
      await syncMeta(targetId, before.role, before.property_ids, disabled);
      // Ban in Auth too so the refresh token stops working, not only the RLS gate.
      await admin.auth.admin.updateUserById(targetId, { ban_duration: disabled ? '876000h' : 'none' });
      const after = await profileOf(targetId);
      await audit(targetId, disabled ? 'disabled' : 'enabled', before, after, `${disabled ? 'Disabled' : 'Enabled'} by staff-users (${actor.role})`);
      return json({ ok: true, user_id: targetId, disabled });
    }

    if (action === 'delete') {
      // Audit first, then remove the profile rows and the Auth user so the name can be reused.
      // submitted_by_user_id references are nullable FKs; historical rows keep their data.
      await audit(targetId, 'disabled', before, { ...before, deleted: true }, `Deleted by staff-users (${actor.role})`);
      await admin.from('staff_property_access').delete().eq('user_id', targetId);
      await admin.from('staff_access_profiles').delete().eq('user_id', targetId);
      const { error } = await admin.auth.admin.deleteUser(targetId);
      if (error) throw error;
      return json({ ok: true, user_id: targetId, deleted: true });
    }

    return json({ ok: false, error: 'unknown_action' }, 400);
  } catch (err) {
    console.error('staff-users error:', String(err));
    return json({ ok: false, error: 'staff_admin_failed' }, 500);
  }
});
