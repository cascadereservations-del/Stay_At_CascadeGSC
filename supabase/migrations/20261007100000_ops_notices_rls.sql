-- 20261007100000_ops_notices_rls.sql
-- Session 74 (Opus 5.5): release ops_notices_rls_20261007 - close the public write path on ops_notices.
--
-- Read 2026-10-07 before writing (pg_policies, information_schema.role_table_grants, edge logs):
--   * ops_notices_anon_insert (INSERT to anon, WITH CHECK true), ops_notices_anon_select (SELECT to anon, is_active),
--     ops_notices_auth_all (ALL to authenticated, USING true); anon and authenticated hold every table privilege.
--   * The anon key is public (guest guide, booking site), so anyone could insert an active brownout notice. power-watch
--     and calendar-sync act on active brownout rows (night blocks on the direct-booking calendar, OPS cards); the anon
--     select also exposed posted_by_chat_id / posted_by_name (staff Telegram ids).
--   * Every legitimate writer is service_role (power-watch, telegram-expense incl. /brownout and the poster flow,
--     _shared/cascade-core/brownout.ts) or the signed-in admin dashboard (owner/admin). No anon reader or writer in any
--     repo; the guest guide reads app_settings and four RPCs only. Edge logs 09-28, 10-04, 10-05, 10-06/07: every
--     /rest/v1/ops_notices request used the secret key.
--   * The signed-in staff accounts include a cleaner, who could write notices through auth_all.
-- After: anon has nothing; signed-in staff read with read_operations and insert/update with manage_operations (owner/admin),
-- the same action admin_table_action_v1 already names for ops_notices; service_role unchanged.

begin;

drop policy if exists ops_notices_anon_insert on public.ops_notices;
drop policy if exists ops_notices_anon_select on public.ops_notices;
drop policy if exists ops_notices_auth_all on public.ops_notices;

create policy ops_notices_staff_read on public.ops_notices for select to authenticated
  using (public.current_staff_authorized('read_operations', property_id));
create policy ops_notices_manage on public.ops_notices for all to authenticated
  using (public.current_staff_authorized('manage_operations', property_id))
  with check (public.current_staff_authorized('manage_operations', property_id));

-- State the end state, not the start (a --no-acl restore starts from default privileges; see security_grants_20260925).
revoke all on table public.ops_notices from public, anon, authenticated;
grant select, insert, update on table public.ops_notices to authenticated;  -- no delete: the dashboard soft-deletes via admin_soft_delete_v1
grant all on table public.ops_notices to service_role;

commit;
