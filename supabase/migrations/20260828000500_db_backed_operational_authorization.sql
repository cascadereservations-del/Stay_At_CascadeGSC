create or replace function public.staff_access_allowed(
  p_role text,
  p_action text,
  p_disabled_at timestamptz,
  p_aal text
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when p_disabled_at is not null then false
    when p_action in ('manage_staff','approve_payment','read_finance')
      and p_aal is distinct from 'aal2' then false
    when p_role in ('owner','admin') then p_action in (
      'manage_staff',
      'approve_payment',
      'read_finance',
      'read_operations',
      'manage_operations',
      'inspect_cleaning',
      'submit_cleaning',
      'manage_inventory',
      'manage_maintenance'
    )
    when p_role = 'finance' then p_action in (
      'approve_payment',
      'read_finance',
      'read_operations'
    )
    when p_role = 'inspector' then p_action in (
      'read_operations',
      'inspect_cleaning',
      'submit_cleaning'
    )
    when p_role = 'cleaner' then p_action in (
      'read_operations',
      'submit_cleaning'
    )
    when p_role = 'maintenance' then p_action in (
      'read_operations',
      'manage_maintenance'
    )
    else false
  end;
$$;

-- Retained for callers created by the earlier operational migration, but the
-- decision is now based on server-owned staff rows and session revocation.
-- JWT role and property_ids claims are deliberately ignored.
create or replace function public.staff_has_property_access(
  p_property_id uuid,
  p_allowed_roles text[]
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.staff_access_profiles p
    where p.user_id = auth.uid()
      and p.disabled_at is null
      and p.role = any (p_allowed_roles)
      and (
        p.sessions_revoked_after is null
        or to_timestamp(coalesce((auth.jwt() ->> 'iat')::bigint, 0)) > p.sessions_revoked_after
      )
      and (
        p.role = 'owner'
        or exists (
          select 1
          from public.staff_property_access s
          where s.user_id = p.user_id
            and s.property_id = p_property_id
        )
      )
  );
$$;

revoke all on function public.staff_has_property_access(uuid, text[])
  from public, anon;
grant execute on function public.staff_has_property_access(uuid, text[])
  to authenticated, service_role;

drop policy if exists inventory_owner_admin_all on public.inventory_items;
drop policy if exists inventory_staff_read on public.inventory_items;
drop policy if exists cleaning_owner_admin_all on public.cleaning_sessions;
drop policy if exists cleaning_staff_read on public.cleaning_sessions;
drop policy if exists cleaning_staff_insert on public.cleaning_sessions;
drop policy if exists cleaning_staff_update on public.cleaning_sessions;
drop policy if exists meters_owner_admin_all on public.meter_readings;
drop policy if exists meters_staff_read on public.meter_readings;
drop policy if exists meters_staff_insert on public.meter_readings;
drop policy if exists meters_staff_update on public.meter_readings;
drop policy if exists inventory_management on public.inventory_items;
drop policy if exists cleaning_management on public.cleaning_sessions;
drop policy if exists meters_management on public.meter_readings;

create policy inventory_management on public.inventory_items
  for all to authenticated
  using (public.current_staff_authorized('manage_inventory', property_id))
  with check (public.current_staff_authorized('manage_inventory', property_id));

create policy inventory_staff_read on public.inventory_items
  for select to authenticated
  using (public.current_staff_authorized('read_operations', property_id));

create policy cleaning_management on public.cleaning_sessions
  for all to authenticated
  using (public.current_staff_authorized('manage_operations', property_id))
  with check (public.current_staff_authorized('manage_operations', property_id));

create policy cleaning_staff_read on public.cleaning_sessions
  for select to authenticated
  using (public.current_staff_authorized('read_operations', property_id));

create policy cleaning_staff_insert on public.cleaning_sessions
  for insert to authenticated
  with check (public.current_staff_authorized('submit_cleaning', property_id));

create policy cleaning_staff_update on public.cleaning_sessions
  for update to authenticated
  using (public.current_staff_authorized('submit_cleaning', property_id))
  with check (public.current_staff_authorized('submit_cleaning', property_id));

create policy meters_management on public.meter_readings
  for all to authenticated
  using (public.current_staff_authorized('manage_operations', property_id))
  with check (public.current_staff_authorized('manage_operations', property_id));

create policy meters_staff_read on public.meter_readings
  for select to authenticated
  using (public.current_staff_authorized('read_operations', property_id));

create policy meters_staff_insert on public.meter_readings
  for insert to authenticated
  with check (public.current_staff_authorized('submit_cleaning', property_id));

create policy meters_staff_update on public.meter_readings
  for update to authenticated
  using (public.current_staff_authorized('submit_cleaning', property_id))
  with check (public.current_staff_authorized('submit_cleaning', property_id));

comment on function public.staff_has_property_access(uuid, text[]) is
  'DB-backed staff/property authorization with disabled-account and session-revocation enforcement; JWT role/property claims are not trusted.';
