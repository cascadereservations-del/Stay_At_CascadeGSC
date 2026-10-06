-- 20261007111000_cleaner_rate_schedule_rls.sql
-- Session 74, lane G3 (money): release money_fixes_20261007, part 2 - cleaner_rate_schedule is read-only to staff.
--
-- Before: one policy, cleaner_rate_owner_admin_all (ALL to authenticated, USING/WITH CHECK on the JWT app_metadata role being owner or
-- admin), and ALL table privileges to anon and authenticated. An owner or admin could therefore INSERT a rate row straight through
-- PostgREST: no validation (positive amounts, a start date after the latest one), no typed reason in the audit row (D-301 reads the
-- reason from admin_audit_context_v1). The trigger cleaner_rate_schedule_append_only already refuses UPDATE and DELETE.
-- After: staff SELECT only, scoped like ops_notices (read_operations on the row's property; owner/admin/finance/cleaner all hold it).
-- Nobody writes through the API: the only writer is admin_add_pay_rate_v1 (SECURITY DEFINER, manage_staff, owner/admin), which the
-- dashboard Settings > Pay rates page calls with admin_pay_rates_v1 (both definer RPCs, no table access needed). The staff app reads
-- rates through the definer helper staff_pay_rate_v1. service_role keeps its grants (telegram-expense reads the schedule).
-- The airbnb_cleans / airbnb_cleaner_summary views read the table as the caller (security_invoker): signed-in staff with a profile and
-- read_operations still read it; a user with no staff profile reads nothing (the JWT-metadata admin path is retired).
-- Every policy on the table is dropped by name from pg_policies, so a hand-added policy cannot survive and keep the write path open.

begin;

do $$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'cleaner_rate_schedule' loop
    execute format('drop policy %I on public.cleaner_rate_schedule', p.policyname);
  end loop;
end $$;

alter table public.cleaner_rate_schedule enable row level security;

create policy cleaner_rate_staff_read on public.cleaner_rate_schedule for select to authenticated
  using (public.current_staff_authorized('read_operations', property_id));

-- State the end state, not the start (a --no-acl restore starts from default privileges).
revoke all on table public.cleaner_rate_schedule from public, anon, authenticated;
grant select on table public.cleaner_rate_schedule to authenticated;
grant all on table public.cleaner_rate_schedule to service_role;

commit;
