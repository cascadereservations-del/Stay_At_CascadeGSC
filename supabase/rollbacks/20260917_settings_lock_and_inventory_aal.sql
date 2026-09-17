-- Compensating rollback for 20260917030000_settings_lock_and_inventory_aal.sql. Restores the two objects
-- exactly as production had them on 2026-09-17 (read with pg_policies / pg_get_functiondef). Not
-- recommended: it re-opens app_settings to every staff login and re-breaks dashboard stock counts.
begin;
drop policy if exists app_settings_staff_read on public.app_settings;
drop policy if exists app_settings_admin_write on public.app_settings;
drop policy if exists "auth all" on public.app_settings;
create policy "auth all" on public.app_settings for all to authenticated using (true);

create or replace function public.inventory_human_authorized(p_property_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
 select exists(
   select 1
   from public.staff_access_profiles p
   where p.user_id=auth.uid()
     and p.role in ('owner','admin')
     and p.disabled_at is null
     and auth.jwt()->>'aal'='aal2'
     and (p.sessions_revoked_after is null
       or to_timestamp(coalesce((auth.jwt()->>'iat')::bigint,0))>p.sessions_revoked_after)
     and (p.role='owner' or exists(
       select 1 from public.staff_property_access s
       where s.user_id=p.user_id and s.property_id=p_property_id
     ))
 );
$$;
commit;
