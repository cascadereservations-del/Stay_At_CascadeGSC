-- s89 fix-up: release s89_backlog_20261024 forward check 'notice_table_is_closed_to_the_apps' failed on production (12/13).
-- Cause: Supabase's default privileges give service_role ALL on every new public table; the rehearsal restores with --no-acl,
-- so it never saw that. anon and authenticated were already fully closed (live read 2026-10-16: every privilege false).
-- The sender (release-expired-holds payout-notices.ts) only selects rows and stamps finance_sent_at / staff_sent_at.
-- Revoking table-level UPDATE also drops column UPDATE, so the two column grants are given back.
begin;
revoke insert, update, delete, truncate, references, trigger on public.staff_payout_change_notices from service_role;
grant select on public.staff_payout_change_notices to service_role;
grant update (finance_sent_at, staff_sent_at) on public.staff_payout_change_notices to service_role;
do $$
begin
  if not ((select relrowsecurity from pg_class where oid = 'public.staff_payout_change_notices'::regclass)
     and not has_table_privilege('anon', 'public.staff_payout_change_notices', 'select')
     and not has_table_privilege('authenticated', 'public.staff_payout_change_notices', 'select')
     and has_table_privilege('service_role', 'public.staff_payout_change_notices', 'select')
     and not has_table_privilege('service_role', 'public.staff_payout_change_notices', 'insert')
     and has_column_privilege('service_role', 'public.staff_payout_change_notices', 'finance_sent_at', 'update')
     and has_column_privilege('service_role', 'public.staff_payout_change_notices', 'staff_sent_at', 'update')) then
    raise exception 's89 notice grants check failed';
  end if;
end $$;
commit;
select 'notice_table_is_closed_to_the_apps: ok' as result;
