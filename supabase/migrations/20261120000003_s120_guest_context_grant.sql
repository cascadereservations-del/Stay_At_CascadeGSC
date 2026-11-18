-- Session 120 (lane S3, part B): release s120_guest_context_grant_20261120. Closes public.guest_context_v1(uuid, uuid, text) to signed-in users.
-- Production read 2026-11-18: the function is SECURITY DEFINER with no auth check and `authenticated` could execute it (anon could not), so any signed-in user (a cleaner, a
-- guest account) could read a guest's private fields (stay count, last issue, preferences, tags, VIP reason, note, birthday, open follow-ups) by name.
-- Callers (repo search 2026-11-18, current app repos): the edge functions airbnb-email-sync, submit-booking, telegram-cassy and guest-reply-draft, through
-- _shared/cascade-core/tools.ts, all with a service-role client. No front end calls it and no SQL function calls it (intake_guest_context_v1 is another function). So this takes
-- the grant back to service_role only. Nothing else changes: not the body, the signature, the owner or the search_path.
-- The migration states the whole expected ACL itself (revoke from every API role, grant to service_role, then a check that reads it back), so it gives the same result on a
-- production database and on a rehearsal copy restored without grants, where PUBLIC may or may not hold the default EXECUTE.
-- Rollback: supabase/rollbacks/20261120_s120_guest_context_grant.sql (puts the 20260916160000 grants back). Forward checks: supabase/releases/s120_guest_context_grant_20261120.release.json.

begin;

-- ML-21: the grants of this function, restated in full
revoke all on function public.guest_context_v1(uuid, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.guest_context_v1(uuid, uuid, text) to service_role;

-- self-check: only the owner and service_role appear in the ACL, and PUBLIC, anon and authenticated cannot execute
do $v$
begin
  if to_regprocedure('public.guest_context_v1(uuid,uuid,text)') is null then
    raise exception 's120 guest_context: public.guest_context_v1 is missing' using errcode = '55000';
  end if;
  if has_function_privilege('anon', 'public.guest_context_v1(uuid,uuid,text)', 'execute')
     or has_function_privilege('authenticated', 'public.guest_context_v1(uuid,uuid,text)', 'execute')
     or not has_function_privilege('service_role', 'public.guest_context_v1(uuid,uuid,text)', 'execute') then
    raise exception 's120 guest_context: the grants are not service_role only' using errcode = '55000';
  end if;
  if exists (select 1 from pg_proc p cross join lateral aclexplode(p.proacl) a
              where p.oid = 'public.guest_context_v1(uuid,uuid,text)'::regprocedure
                and a.grantee <> p.proowner and a.grantee <> (select r.oid from pg_roles r where r.rolname = 'service_role')) then
    raise exception 's120 guest_context: the ACL holds a grantee other than the owner and service_role (PUBLIC included)' using errcode = '55000';
  end if;
end $v$;

commit;
