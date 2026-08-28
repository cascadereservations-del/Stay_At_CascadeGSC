create or replace function public.staff_has_property_access(
  p_property_id uuid,
  p_allowed_roles text[]
)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select case
    when auth.jwt() -> 'app_metadata' ->> 'role' in ('owner', 'admin') then true
    when not ((auth.jwt() -> 'app_metadata' ->> 'role') = any (p_allowed_roles)) then false
    else exists (
      select 1
      from pg_catalog.jsonb_array_elements_text(
        coalesce(auth.jwt() -> 'app_metadata' -> 'property_ids', '[]'::jsonb)
      ) as assigned(property_id)
      where assigned.property_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        and assigned.property_id::uuid = p_property_id
    )
  end;
$$;

revoke all on function public.staff_has_property_access(uuid, text[]) from public, anon;
grant execute on function public.staff_has_property_access(uuid, text[]) to authenticated, service_role;

alter table public.inventory_items
  add column if not exists property_id uuid;

do $$
declare
  v_active_property_count integer;
  v_property_id uuid;
begin
  if exists (select 1 from public.inventory_items where property_id is null)
    or exists (select 1 from public.cleaning_sessions where property_id is null)
    or exists (select 1 from public.meter_readings where property_id is null)
  then
    select count(*) into v_active_property_count
    from public.properties
    where is_active;

    if v_active_property_count <> 1 then
      raise exception using
        errcode = '23514',
        message = 'operational property backfill requires exactly one active property';
    end if;

    select id into strict v_property_id
    from public.properties
    where is_active
    order by created_at, id
    limit 1;

    update public.inventory_items set property_id = v_property_id where property_id is null;
    update public.cleaning_sessions set property_id = v_property_id where property_id is null;
    update public.meter_readings set property_id = v_property_id where property_id is null;
  end if;
end;
$$;

alter table public.inventory_items
  drop constraint if exists inventory_items_property_id_fkey,
  add constraint inventory_items_property_id_fkey
    foreign key (property_id) references public.properties(id) not valid;

alter table public.inventory_items validate constraint inventory_items_property_id_fkey;

alter table public.inventory_items alter column property_id set not null;
alter table public.cleaning_sessions alter column property_id set not null;
alter table public.meter_readings alter column property_id set not null;

create index if not exists inventory_items_property_idx
  on public.inventory_items (property_id, is_active, sort_order);

drop policy if exists "anon all" on public.inventory_items;
drop policy if exists "authenticated all" on public.inventory_items;
drop policy if exists "anon insert" on public.cleaning_sessions;
drop policy if exists "anon select" on public.cleaning_sessions;
drop policy if exists "authenticated_all_cleaning_sessions" on public.cleaning_sessions;
drop policy if exists "anon insert" on public.meter_readings;
drop policy if exists "anon select" on public.meter_readings;
drop policy if exists "authenticated_all_meter_readings" on public.meter_readings;

revoke all on table public.inventory_items, public.cleaning_sessions, public.meter_readings from anon, authenticated;
grant select, insert, update, delete on table public.inventory_items, public.cleaning_sessions, public.meter_readings to authenticated;
grant all on table public.inventory_items, public.cleaning_sessions, public.meter_readings to service_role;

alter table public.inventory_items enable row level security;
alter table public.cleaning_sessions enable row level security;
alter table public.meter_readings enable row level security;

create policy inventory_owner_admin_all on public.inventory_items
  for all to authenticated
  using ((auth.jwt() -> 'app_metadata' ->> 'role') in ('owner', 'admin'))
  with check ((auth.jwt() -> 'app_metadata' ->> 'role') in ('owner', 'admin'));

create policy inventory_staff_read on public.inventory_items
  for select to authenticated
  using (public.staff_has_property_access(property_id, array['finance', 'inspector', 'cleaner', 'maintenance']));

create policy cleaning_owner_admin_all on public.cleaning_sessions
  for all to authenticated
  using ((auth.jwt() -> 'app_metadata' ->> 'role') in ('owner', 'admin'))
  with check ((auth.jwt() -> 'app_metadata' ->> 'role') in ('owner', 'admin'));

create policy cleaning_staff_read on public.cleaning_sessions
  for select to authenticated
  using (public.staff_has_property_access(property_id, array['finance', 'inspector', 'cleaner', 'maintenance']));

create policy cleaning_staff_insert on public.cleaning_sessions
  for insert to authenticated
  with check (public.staff_has_property_access(property_id, array['cleaner', 'inspector']));

create policy cleaning_staff_update on public.cleaning_sessions
  for update to authenticated
  using (public.staff_has_property_access(property_id, array['cleaner', 'inspector']))
  with check (public.staff_has_property_access(property_id, array['cleaner', 'inspector']));

create policy meters_owner_admin_all on public.meter_readings
  for all to authenticated
  using ((auth.jwt() -> 'app_metadata' ->> 'role') in ('owner', 'admin'))
  with check ((auth.jwt() -> 'app_metadata' ->> 'role') in ('owner', 'admin'));

create policy meters_staff_read on public.meter_readings
  for select to authenticated
  using (public.staff_has_property_access(property_id, array['finance', 'inspector', 'cleaner', 'maintenance']));

create policy meters_staff_insert on public.meter_readings
  for insert to authenticated
  with check (public.staff_has_property_access(property_id, array['cleaner', 'inspector']));

create policy meters_staff_update on public.meter_readings
  for update to authenticated
  using (public.staff_has_property_access(property_id, array['cleaner', 'inspector']))
  with check (public.staff_has_property_access(property_id, array['cleaner', 'inspector']));

comment on function public.staff_has_property_access(uuid, text[]) is
  'Checks the authenticated staff role and property_ids JWT claim; owner/admin may access all properties.';
