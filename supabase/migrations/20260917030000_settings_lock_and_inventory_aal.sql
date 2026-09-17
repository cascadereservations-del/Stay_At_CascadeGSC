-- Session 30 (2026-09-17), two verified holes, one release.
--
-- 1. app_settings: the policy "auth all" was FOR ALL TO authenticated USING (true), so ANY signed-in staff
--    account (the cleaner's included) could read and rewrite every row: concierge_mode, nightly_rate_php,
--    wifi_password, admin_pin_hash, airbnb_ical_url (whose ?t= is a live secret). No front end writes this
--    table with a staff login (grep of the dashboard, legacy admin, checklist, guide, manual, 2026-09-17);
--    Edge Functions write it with the service role, which bypasses RLS. Now: staff read what the public
--    reads, an owner or admin reads the rest and writes, and admin_pin_hash is never writable through the
--    API (it is rotated by reviewed SQL, FACTS). The anon policy is untouched (guide Wi-Fi, B27 / D-010).
--    Owner / admin test = current_staff_authorized('manage_staff'): that action is owner / admin only in
--    staff_access_allowed and needs no property, and it keeps the disabled / revoked-session checks.
--
-- 2. inventory_human_authorized still demanded aal2. D-094 (release admin_access_simplification_20260913)
--    removed the two-factor step everywhere else (B50), so every dashboard stock count and receipt
--    (reconcile_inventory_baseline_v1 / record_inventory_receipt_v1 -> record_inventory_movement) has been
--    refused since 2026-09-13. Same body, minus the aal line.
begin;

drop policy if exists "auth all" on public.app_settings;
drop policy if exists app_settings_staff_read on public.app_settings;
drop policy if exists app_settings_admin_write on public.app_settings;

create policy app_settings_staff_read on public.app_settings for select to authenticated using (
  coalesce(public.current_staff_authorized('manage_staff'), false)
  or (key !~~* '%token%' and key !~~* '%secret%' and key !~~* '%pin_hash%' and key !~~* '%ical%'
      and key !~~* '%chat_id%' and key <> all (array['email_recipients', 'users']))
);

create policy app_settings_admin_write on public.app_settings for all to authenticated
  using (coalesce(public.current_staff_authorized('manage_staff'), false) and key <> 'admin_pin_hash')
  with check (coalesce(public.current_staff_authorized('manage_staff'), false) and key <> 'admin_pin_hash');

-- Production already has these table grants (verified 2026-09-17); restated so the policies are what
-- decides in a --no-acl rehearsal restore too.
grant select, insert, update, delete on public.app_settings to authenticated;
grant select on public.app_settings to anon;

create or replace function public.inventory_human_authorized(p_property_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
 select exists(
   select 1
   from public.staff_access_profiles p
   where p.user_id=auth.uid()
     and p.role in ('owner','admin')
     and p.disabled_at is null
     and (p.sessions_revoked_after is null
       or to_timestamp(coalesce((auth.jwt()->>'iat')::bigint,0))>p.sessions_revoked_after)
     and (p.role='owner' or exists(
       select 1 from public.staff_property_access s
       where s.user_id=p.user_id and s.property_id=p_property_id
     ))
 );
$$;

commit;
