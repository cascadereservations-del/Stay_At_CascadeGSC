-- Compensating rollback for release s120_guest_context_grant_20261120 (session 120, migration 20261120000003_s120_guest_context_grant.sql).
-- Puts the grants of migration 20260916160000_work_orders_and_guest_context.sql back on public.guest_context_v1(uuid, uuid, text): revoked from PUBLIC and anon,
-- execute for service_role and authenticated. That reopens the private-guest-fields read to every signed-in user: roll back only if an app is found that calls
-- the function with a user token, and fix that caller instead as soon as it is read. Apply with run-sql-on-host.sh.

begin;

-- ML-21: the grants of this function, restated in full
revoke all on function public.guest_context_v1(uuid, uuid, text) from public, anon;
grant execute on function public.guest_context_v1(uuid, uuid, text) to service_role, authenticated;

do $v$
begin
  if to_regprocedure('public.guest_context_v1(uuid,uuid,text)') is null then
    raise exception 's120 guest_context rollback: public.guest_context_v1 is missing' using errcode = '55000';
  end if;
  if has_function_privilege('anon', 'public.guest_context_v1(uuid,uuid,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.guest_context_v1(uuid,uuid,text)', 'execute')
     or not has_function_privilege('service_role', 'public.guest_context_v1(uuid,uuid,text)', 'execute') then
    raise exception 's120 guest_context rollback: the grants are not service_role and authenticated only' using errcode = '55000';
  end if;
end $v$;

commit;
