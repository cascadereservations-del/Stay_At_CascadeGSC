-- Rollback for release ops_notices_rls_20261007: restores the policies and grants read on 2026-10-07 before the release.
-- This reopens the public write path (anyone with the anon key can create a brownout notice). Use only if a signed-in
-- writer breaks and cannot be fixed forward.
begin;
drop policy if exists ops_notices_staff_read on public.ops_notices;
drop policy if exists ops_notices_manage on public.ops_notices;
create policy ops_notices_anon_insert on public.ops_notices for insert to anon with check (true);
create policy ops_notices_anon_select on public.ops_notices for select to anon using (is_active = true);
create policy ops_notices_auth_all on public.ops_notices for all to authenticated using (true) with check (true);
grant all on table public.ops_notices to anon, authenticated;
commit;
