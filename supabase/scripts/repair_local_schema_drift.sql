-- LOCAL DEVELOPMENT ONLY.
--
-- The local Docker database can report historical migrations as applied while
-- `properties` and `meter_readings` are absent. This script restores only the
-- missing baseline objects needed to verify later migrations. Never run it on
-- the hosted Cascade project; production is authoritative there.

begin;

create table if not exists public.properties (
  id uuid primary key default extensions.uuid_generate_v4(),
  name text not null,
  address text,
  city text,
  country text not null default 'PH',
  is_active boolean not null default true,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

insert into public.properties (id, name, address, city)
values (
  '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd',
  'Cascade Bria',
  'Block 47 Lot 39, General Santos City',
  'General Santos City'
)
on conflict (id) do update
set name = excluded.name,
    address = excluded.address,
    city = excluded.city;

do $$
begin
  if not exists (
    select 1 from pg_trigger
    where tgname = 'properties_set_updated_at'
      and tgrelid = 'public.properties'::regclass
      and not tgisinternal
  ) then
    create trigger properties_set_updated_at
      before update on public.properties
      for each row execute function public.set_updated_at();
  end if;
end
$$;

alter table public.properties enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'properties'
      and policyname = 'anon_select_active_properties'
  ) then
    create policy anon_select_active_properties on public.properties
      for select to anon using (is_active = true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'properties'
      and policyname = 'authenticated_all_properties'
  ) then
    create policy authenticated_all_properties on public.properties
      for all to authenticated using (true) with check (true);
  end if;
end
$$;

grant all on table public.properties to anon, authenticated, service_role;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.inventory_items'::regclass
      and contype = 'p'
  ) then
    alter table public.inventory_items
      add constraint inventory_items_pkey primary key (id);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.cleaning_sessions'::regclass
      and contype = 'p'
  ) then
    alter table public.cleaning_sessions
      add constraint cleaning_sessions_pkey primary key (id);
  end if;
end
$$;

update public.cleaning_sessions
set property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
where property_id is null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.cleaning_sessions'::regclass
      and conname = 'cleaning_sessions_property_id_fkey'
  ) then
    alter table public.cleaning_sessions
      add constraint cleaning_sessions_property_id_fkey
      foreign key (property_id) references public.properties(id);
  end if;
end
$$;

create table if not exists public.meter_readings (
  id uuid primary key default extensions.uuid_generate_v4(),
  session_id uuid references public.cleaning_sessions(id) on delete cascade,
  electric_prev numeric(10,2),
  electric_curr numeric(10,2),
  electric_delta numeric(10,2),
  water_prev numeric(10,4),
  water_curr numeric(10,4),
  water_delta numeric(10,4),
  kwh_per_night numeric(10,4),
  m3_per_night numeric(10,4),
  recorded_at timestamptz not null default now(),
  property_id uuid references public.properties(id),
  meter_flag text,
  meter_override_note text
);

alter table public.meter_readings enable row level security;

do $$
begin
  -- Once the operational RLS migration exists, do not restore the legacy
  -- anonymous policies that migration deliberately removes.
  if to_regprocedure('public.staff_has_property_access(uuid,text[])') is null
    and not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'meter_readings'
      and policyname = 'anon insert'
  ) then
    create policy "anon insert" on public.meter_readings
      for insert to anon with check (true);
  end if;

  if to_regprocedure('public.staff_has_property_access(uuid,text[])') is null
    and not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'meter_readings'
      and policyname = 'anon select'
  ) then
    create policy "anon select" on public.meter_readings
      for select to anon using (true);
  end if;

  if to_regprocedure('public.staff_has_property_access(uuid,text[])') is null
    and not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'meter_readings'
      and policyname = 'authenticated_all_meter_readings'
  ) then
    create policy authenticated_all_meter_readings on public.meter_readings
      to authenticated using (true) with check (true);
  end if;
end
$$;

do $$
begin
  if to_regprocedure('public.staff_has_property_access(uuid,text[])') is null then
    grant all on table public.meter_readings to anon, authenticated, service_role;
  else
    revoke all on table public.meter_readings from anon, authenticated;
    grant select, insert, update, delete on table public.meter_readings to authenticated;
    grant all on table public.meter_readings to service_role;
  end if;
end
$$;

commit;
