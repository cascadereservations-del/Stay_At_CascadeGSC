-- s135b (D-420): staff_payout_change_notices grants for service_role, written down so the migration chain matches production.
-- 20261024000000_s89_backlog_qr.sql:51-53 revoked the table from public, anon and authenticated, then granted service_role
-- select plus update (finance_sent_at, staff_sent_at). It never revoked service_role itself, so a fresh stack whose default
-- privileges give service_role everything on new public tables (local Supabase, CI) ends with insert/delete/update on top.
-- Production holds exactly select + the two column updates (live read 2026-11-24), so on production this file is a no-op:
-- revoke all, then grant the same two privileges back, in one transaction.
-- Rollback: none needed (production state is unchanged); supabase/rollbacks/20261204_s135_pay_extras_fix.sql covers the release.

revoke all on table public.staff_payout_change_notices from service_role;
grant select on table public.staff_payout_change_notices to service_role;
grant update (finance_sent_at, staff_sent_at) on table public.staff_payout_change_notices to service_role;

do $chk$
begin
  if not has_table_privilege('service_role', 'public.staff_payout_change_notices', 'select')
     or has_table_privilege('service_role', 'public.staff_payout_change_notices', 'insert')
     or has_table_privilege('service_role', 'public.staff_payout_change_notices', 'update')
     or has_table_privilege('service_role', 'public.staff_payout_change_notices', 'delete')
     or not has_column_privilege('service_role', 'public.staff_payout_change_notices', 'finance_sent_at', 'update')
     or not has_column_privilege('service_role', 'public.staff_payout_change_notices', 'staff_sent_at', 'update')
     or has_column_privilege('service_role', 'public.staff_payout_change_notices', 'finance_text', 'update') then
    raise exception 's135b: service_role grants on staff_payout_change_notices are not select + the two sent columns' using errcode = '55000';
  end if;
end $chk$;
