-- Module A window: the five migrations in order, one paste for the Supabase SQL editor (database-owner session).
-- Generated 2026-09-08 from the locked contract files; do not edit the migration bodies.
begin;

-- ===== 20260828000200_operational_rls_lockdown.sql =====
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
drop policy if exists inventory_owner_admin_all on public.inventory_items;
drop policy if exists inventory_staff_read on public.inventory_items;
drop policy if exists "anon insert" on public.cleaning_sessions;
drop policy if exists "anon select" on public.cleaning_sessions;
drop policy if exists "authenticated_all_cleaning_sessions" on public.cleaning_sessions;
drop policy if exists cleaning_owner_admin_all on public.cleaning_sessions;
drop policy if exists cleaning_staff_read on public.cleaning_sessions;
drop policy if exists cleaning_staff_insert on public.cleaning_sessions;
drop policy if exists cleaning_staff_update on public.cleaning_sessions;
drop policy if exists "anon insert" on public.meter_readings;
drop policy if exists "anon select" on public.meter_readings;
drop policy if exists "authenticated_all_meter_readings" on public.meter_readings;
drop policy if exists meters_owner_admin_all on public.meter_readings;
drop policy if exists meters_staff_read on public.meter_readings;
drop policy if exists meters_staff_insert on public.meter_readings;
drop policy if exists meters_staff_update on public.meter_readings;

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


-- ===== 20260828000400_staff_roles_and_sessions.sql =====
create table public.staff_access_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','admin','finance','inspector','cleaner','maintenance')),
  disabled_at timestamptz,
  sessions_revoked_after timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.staff_property_access (
  user_id uuid not null references public.staff_access_profiles(user_id) on delete cascade,
  property_id uuid not null references public.properties(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, property_id)
);

create table public.staff_access_audit (
  id uuid primary key default extensions.uuid_generate_v4(),
  actor_user_id uuid,
  target_user_id uuid not null,
  action text not null check (action in ('created','role_changed','disabled','enabled','sessions_revoked')),
  before_state jsonb not null default '{}'::jsonb,
  after_state jsonb not null default '{}'::jsonb,
  reason text not null check (char_length(reason) between 3 and 500),
  created_at timestamptz not null default now()
);

alter table public.staff_access_profiles enable row level security;
alter table public.staff_property_access enable row level security;
alter table public.staff_access_audit enable row level security;
revoke all on public.staff_access_profiles, public.staff_property_access, public.staff_access_audit from public, anon, authenticated, service_role;
grant select on public.staff_access_profiles, public.staff_property_access to service_role;
grant select, insert on public.staff_access_audit to service_role;

create or replace function public.staff_access_allowed(p_role text, p_action text, p_disabled_at timestamptz, p_aal text)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when p_disabled_at is not null then false
    when p_action in ('manage_staff','approve_payment','read_finance') and p_aal is distinct from 'aal2' then false
    when p_role in ('owner','admin') then p_action in ('manage_staff','approve_payment','read_finance','inspect_cleaning','submit_cleaning','manage_maintenance')
    when p_role = 'finance' then p_action in ('approve_payment','read_finance')
    when p_role = 'inspector' then p_action = 'inspect_cleaning'
    when p_role = 'cleaner' then p_action = 'submit_cleaning'
    when p_role = 'maintenance' then p_action = 'manage_maintenance'
    else false end;
$$;

create or replace function public.current_staff_authorized(p_action text, p_property_id uuid default null)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.staff_access_profiles p
    where p.user_id = auth.uid()
      and public.staff_access_allowed(p.role, p_action, p.disabled_at, auth.jwt() ->> 'aal')
      and (p.sessions_revoked_after is null or to_timestamp(coalesce((auth.jwt() ->> 'iat')::bigint, 0)) > p.sessions_revoked_after)
      and (p.role = 'owner' or p_action = 'manage_staff' or (
        p_property_id is not null and exists (
          select 1 from public.staff_property_access s where s.user_id = p.user_id and s.property_id = p_property_id
        )
      ))
  );
$$;

create or replace function public.current_staff_access()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'user_id', p.user_id,
    'role', p.role,
    'property_ids', coalesce(array_agg(s.property_id order by s.property_id), '{}'::uuid[]),
    'disabled', p.disabled_at is not null,
    'session_current', p.sessions_revoked_after is null
      or to_timestamp(coalesce((auth.jwt() ->> 'iat')::bigint, 0)) > p.sessions_revoked_after
  )
  from public.staff_access_profiles p
  left join public.staff_property_access s on s.user_id = p.user_id
  where p.user_id = auth.uid()
  group by p.user_id;
$$;

create or replace function public.manage_staff_access(
  p_target_user_id uuid,
  p_action text,
  p_role text default null,
  p_property_ids uuid[] default null,
  p_reason text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor public.staff_access_profiles%rowtype;
  v_target public.staff_access_profiles%rowtype;
  v_target_found boolean := false;
  v_properties uuid[] := '{}'::uuid[];
  v_before jsonb := '{}'::jsonb;
  v_after jsonb := '{}'::jsonb;
  v_audit_action text;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if p_reason is null or char_length(btrim(p_reason)) < 3 then raise exception using errcode = '22023', message = 'reason required'; end if;
  if p_action not in ('upsert','disable','enable','revoke_sessions') then raise exception using errcode = '22023', message = 'invalid staff action'; end if;

  select * into v_actor from public.staff_access_profiles where user_id = auth.uid() for update;
  if not found or v_actor.disabled_at is not null or v_actor.role not in ('owner','admin') then
    raise exception using errcode = '42501', message = 'staff management denied';
  end if;
  if auth.jwt() ->> 'aal' is distinct from 'aal2' then raise exception using errcode = '42501', message = 'mfa required'; end if;
  if v_actor.sessions_revoked_after is not null and to_timestamp(coalesce((auth.jwt() ->> 'iat')::bigint, 0)) <= v_actor.sessions_revoked_after then
    raise exception using errcode = '42501', message = 'session revoked';
  end if;
  if p_target_user_id = auth.uid() then raise exception using errcode = '42501', message = 'self management denied'; end if;
  if not exists (select 1 from auth.users where id = p_target_user_id) then raise exception using errcode = '22023', message = 'target user not found'; end if;

  select * into v_target from public.staff_access_profiles where user_id = p_target_user_id for update;
  v_target_found := found;
  if v_target_found then
    select to_jsonb(v_target) || jsonb_build_object('property_ids', coalesce(array_agg(s.property_id order by s.property_id), '{}'::uuid[]))
      into v_before from public.staff_property_access s where s.user_id = p_target_user_id;
  elsif p_action <> 'upsert' then
    raise exception using errcode = '22023', message = 'target profile not found';
  end if;

  if v_actor.role = 'admin' and ((v_target_found and v_target.role = 'owner') or p_role = 'owner') then
    raise exception using errcode = '42501', message = 'owner access denied';
  end if;

  if p_action = 'upsert' then
    if p_role not in ('owner','admin','finance','inspector','cleaner','maintenance') then raise exception using errcode = '22023', message = 'invalid staff role'; end if;
    select coalesce(array_agg(distinct x order by x), '{}'::uuid[]) into v_properties from unnest(coalesce(p_property_ids, '{}'::uuid[])) x;
    if p_role <> 'owner' and cardinality(v_properties) = 0 then raise exception using errcode = '22023', message = 'property scope required'; end if;
    if exists (select 1 from unnest(v_properties) x where not exists (select 1 from public.properties p where p.id = x)) then
      raise exception using errcode = '22023', message = 'unknown property scope';
    end if;
    if v_actor.role = 'admin' and exists (
      select 1 from unnest(v_properties) x where not exists (
        select 1 from public.staff_property_access s where s.user_id = v_actor.user_id and s.property_id = x
      )
    ) then raise exception using errcode = '42501', message = 'property scope denied'; end if;

    insert into public.staff_access_profiles(user_id, role, sessions_revoked_after)
    values (p_target_user_id, p_role, now())
    on conflict (user_id) do update set role = excluded.role, disabled_at = null, sessions_revoked_after = now(), updated_at = now();
    delete from public.staff_property_access where user_id = p_target_user_id;
    insert into public.staff_property_access(user_id, property_id) select p_target_user_id, unnest(v_properties);
    v_audit_action := case when v_target_found then 'role_changed' else 'created' end;
  elsif p_action = 'disable' then
    update public.staff_access_profiles set disabled_at = now(), sessions_revoked_after = now(), updated_at = now() where user_id = p_target_user_id;
    v_audit_action := 'disabled';
  elsif p_action = 'enable' then
    update public.staff_access_profiles set disabled_at = null, sessions_revoked_after = now(), updated_at = now() where user_id = p_target_user_id;
    v_audit_action := 'enabled';
  else
    update public.staff_access_profiles set sessions_revoked_after = now(), updated_at = now() where user_id = p_target_user_id;
    v_audit_action := 'sessions_revoked';
  end if;

  select to_jsonb(p) || jsonb_build_object('property_ids', coalesce(array_agg(s.property_id order by s.property_id), '{}'::uuid[]))
    into v_after from public.staff_access_profiles p left join public.staff_property_access s on s.user_id = p.user_id
    where p.user_id = p_target_user_id group by p.user_id;

  update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object(
    'role', v_after ->> 'role', 'property_ids', v_after -> 'property_ids',
    'cascade_disabled', (v_after ->> 'disabled_at') is not null,
    'cascade_sessions_revoked_after', v_after ->> 'sessions_revoked_after'
  ), updated_at = now() where id = p_target_user_id;

  insert into public.staff_access_audit(actor_user_id,target_user_id,action,before_state,after_state,reason)
  values (auth.uid(),p_target_user_id,v_audit_action,coalesce(v_before,'{}'::jsonb),v_after,btrim(p_reason));
  return jsonb_build_object('ok',true,'target_user_id',p_target_user_id,'action',v_audit_action,'session_reauthentication_required',true);
end;
$$;

create or replace function public.bootstrap_cascade_owner(p_user_id uuid, p_property_ids uuid[], p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_properties uuid[] := '{}'::uuid[];
begin
  if exists (select 1 from public.staff_access_profiles where role = 'owner') then raise exception using errcode = '23505', message = 'cascade owner already exists'; end if;
  if not exists (select 1 from auth.users where id = p_user_id) then raise exception using errcode = '22023', message = 'target user not found'; end if;
  if p_reason is null or char_length(btrim(p_reason)) < 3 then raise exception using errcode = '22023', message = 'reason required'; end if;
  select coalesce(array_agg(distinct x order by x), '{}'::uuid[]) into v_properties from unnest(coalesce(p_property_ids,'{}'::uuid[])) x;
  if exists (select 1 from unnest(v_properties) x where not exists (select 1 from public.properties p where p.id = x)) then
    raise exception using errcode = '22023', message = 'unknown property scope';
  end if;
  insert into public.staff_access_profiles(user_id,role,sessions_revoked_after) values (p_user_id,'owner',now());
  insert into public.staff_property_access(user_id,property_id) select p_user_id, unnest(v_properties);
  update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data,'{}'::jsonb) || jsonb_build_object(
    'role','owner','property_ids',to_jsonb(v_properties),'cascade_disabled',false,'cascade_sessions_revoked_after',now()::text
  ), updated_at = now() where id = p_user_id;
  insert into public.staff_access_audit(actor_user_id,target_user_id,action,after_state,reason)
  values (null,p_user_id,'created',jsonb_build_object('role','owner','property_ids',v_properties),btrim(p_reason));
end;
$$;

revoke all on function public.staff_access_allowed(text,text,timestamptz,text) from public, anon, authenticated, service_role;
grant execute on function public.staff_access_allowed(text,text,timestamptz,text) to service_role;
revoke all on function public.current_staff_authorized(text,uuid) from public, anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text,uuid) to authenticated, service_role;
revoke all on function public.current_staff_access() from public, anon, authenticated, service_role;
grant execute on function public.current_staff_access() to authenticated;
revoke all on function public.manage_staff_access(uuid,text,text,uuid[],text) from public, anon, authenticated, service_role;
grant execute on function public.manage_staff_access(uuid,text,text,uuid[],text) to authenticated;
revoke all on function public.bootstrap_cascade_owner(uuid,uuid[],text) from public, anon, authenticated, service_role;

comment on table public.staff_access_profiles is 'Named Cascade staff identities. Authorization is server-owned; user_metadata is never trusted.';
comment on table public.staff_property_access is 'Normalized property scope for named Cascade staff identities.';
comment on table public.staff_access_audit is 'Append-only administrative trail for staff access, disablement and session revocation.';
comment on function public.bootstrap_cascade_owner(uuid,uuid[],text) is 'Database-owner-only, one-time bootstrap. Never expose to client or service roles.';


-- ===== 20260828000500_db_backed_operational_authorization.sql =====
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


-- ===== 20260830002347_named_cleaner_access_boundary.sql =====
-- Named-cleaner cutover: bind operational writes to an authenticated user and
-- property, remove anonymous inventory/photo access, and route cleaner expenses
-- to a Finance review queue instead of the confirmed ledger.

alter table public.cleaning_sessions
  add column if not exists submitted_by_user_id uuid references auth.users(id);

alter table public.meter_readings
  add column if not exists submitted_by_user_id uuid references auth.users(id);

alter table public.inventory_usage
  add column if not exists property_id uuid references public.properties(id),
  add column if not exists cleaning_session_id uuid references public.cleaning_sessions(id),
  add column if not exists submitted_by_user_id uuid references auth.users(id);

update public.inventory_usage u
set property_id = i.property_id
from public.inventory_items i
where u.item_id = i.id
  and u.property_id is null;

do $$
declare
  v_property_id uuid;
begin
  if exists (select 1 from public.inventory_usage where property_id is null) then
    select id into v_property_id
    from public.properties
    where is_active
    order by created_at, id
    limit 1;

    if v_property_id is null
      or (select count(*) from public.properties where is_active) <> 1 then
      raise exception using
        errcode = '23514',
        message = 'inventory usage backfill requires exactly one active property';
    end if;
    update public.inventory_usage set property_id = v_property_id where property_id is null;
  end if;
end;
$$;

alter table public.inventory_usage alter column property_id set not null;

create index if not exists inventory_usage_property_date_idx
  on public.inventory_usage(property_id, session_date desc);
create index if not exists cleaning_sessions_submitter_idx
  on public.cleaning_sessions(submitted_by_user_id, cleaned_at desc);
create index if not exists meter_readings_submitter_idx
  on public.meter_readings(submitted_by_user_id, recorded_at desc);

drop policy if exists cleaning_staff_insert on public.cleaning_sessions;
drop policy if exists cleaning_staff_update on public.cleaning_sessions;
drop policy if exists meters_staff_insert on public.meter_readings;
drop policy if exists meters_staff_update on public.meter_readings;

create policy cleaning_staff_insert on public.cleaning_sessions
  for insert to authenticated
  with check (
    public.current_staff_authorized('submit_cleaning', property_id)
    and submitted_by_user_id = auth.uid()
  );

create policy cleaning_staff_update on public.cleaning_sessions
  for update to authenticated
  using (
    public.current_staff_authorized('submit_cleaning', property_id)
    and submitted_by_user_id = auth.uid()
  )
  with check (
    public.current_staff_authorized('submit_cleaning', property_id)
    and submitted_by_user_id = auth.uid()
  );

create policy meters_staff_insert on public.meter_readings
  for insert to authenticated
  with check (
    public.current_staff_authorized('submit_cleaning', property_id)
    and submitted_by_user_id = auth.uid()
  );

create policy meters_staff_update on public.meter_readings
  for update to authenticated
  using (
    public.current_staff_authorized('submit_cleaning', property_id)
    and submitted_by_user_id = auth.uid()
  )
  with check (
    public.current_staff_authorized('submit_cleaning', property_id)
    and submitted_by_user_id = auth.uid()
  );

drop policy if exists "anon insert" on public.inventory_usage;
drop policy if exists "anon select" on public.inventory_usage;
drop policy if exists inventory_usage_staff_read on public.inventory_usage;
drop policy if exists inventory_usage_staff_insert on public.inventory_usage;
drop policy if exists inventory_usage_management on public.inventory_usage;

revoke all on table public.inventory_usage from anon, authenticated;
grant select, insert, update, delete on table public.inventory_usage to authenticated;
grant all on table public.inventory_usage to service_role;
alter table public.inventory_usage enable row level security;

create policy inventory_usage_staff_read on public.inventory_usage
  for select to authenticated
  using (public.current_staff_authorized('read_operations', property_id));

create policy inventory_usage_staff_insert on public.inventory_usage
  for insert to authenticated
  with check (
    public.current_staff_authorized('submit_cleaning', property_id)
    and submitted_by_user_id = auth.uid()
  );

create policy inventory_usage_management on public.inventory_usage
  for all to authenticated
  using (public.current_staff_authorized('manage_inventory', property_id))
  with check (public.current_staff_authorized('manage_inventory', property_id));

create table if not exists public.cleaning_expense_claims (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  cleaning_session_id uuid not null references public.cleaning_sessions(id) on delete cascade,
  submitted_by_user_id uuid not null references auth.users(id),
  expense_date date not null,
  description text not null check (char_length(btrim(description)) between 3 and 500),
  amount numeric(12,2) not null check (amount > 0),
  currency text not null default 'PHP' check (currency = 'PHP'),
  status text not null default 'pending_review'
    check (status in ('pending_review','approved','rejected','paid')),
  reviewed_by_user_id uuid references auth.users(id),
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.cleaning_expense_claims enable row level security;
revoke all on table public.cleaning_expense_claims from public, anon, authenticated;
grant select on table public.cleaning_expense_claims to authenticated;
grant all on table public.cleaning_expense_claims to service_role;

drop policy if exists expense_claim_submitter_read on public.cleaning_expense_claims;
drop policy if exists expense_claim_finance_read on public.cleaning_expense_claims;

create policy expense_claim_submitter_read on public.cleaning_expense_claims
  for select to authenticated
  using (
    submitted_by_user_id = auth.uid()
    and public.current_staff_authorized('submit_cleaning', property_id)
  );

create policy expense_claim_finance_read on public.cleaning_expense_claims
  for select to authenticated
  using (public.current_staff_authorized('read_finance', property_id));

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values (
  'cleaning-photos',
  'cleaning-photos',
  false,
  5242880,
  array['image/jpeg','image/png','image/webp']::text[]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "anon read cleaning photos" on storage.objects;
drop policy if exists "anon upload cleaning photos" on storage.objects;
drop policy if exists "authenticated all cleaning photos" on storage.objects;
drop policy if exists public_read_cleaning_photos on storage.objects;
drop policy if exists service_insert_cleaning_photos on storage.objects;

comment on table public.cleaning_expense_claims is
  'Cleaner-submitted expenses awaiting Finance review; rows are never ledger confirmation.';
comment on column public.cleaning_sessions.submitted_by_user_id is
  'Named Supabase Auth identity that submitted the cleaning report.';


-- ===== 20260908000100_record_inventory_usage_rpc.sql =====
-- Module A follow-on (D-031): the Inventory app's session save used to update
-- inventory_items.qty_on_hand directly and then insert inventory_usage rows.
-- Under the named-staff RLS a cleaner may insert usage but may not update
-- items, so the decrement would silently stop. This RPC does both in one
-- transaction under the caller's staff authorization and stamps the submitter.

create or replace function public.record_inventory_usage(
  p_property_id uuid,
  p_session_date date,
  p_logged_by text,
  p_notes text,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row jsonb;
  v_item uuid;
  v_qty numeric;
  v_count integer := 0;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'authentication required';
  end if;
  if not public.current_staff_authorized('submit_cleaning', p_property_id) then
    raise exception using errcode = '42501', message = 'staff access denied';
  end if;
  if p_session_date is null then
    raise exception using errcode = '22023', message = 'session_date required';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception using errcode = '22023', message = 'rows required';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_item := (v_row ->> 'item_id')::uuid;
    v_qty  := (v_row ->> 'used_qty')::numeric;
    if v_item is null or v_qty is null or v_qty <= 0 then
      raise exception using errcode = '22023', message = 'each row needs item_id and a positive used_qty';
    end if;
    if not exists (
      select 1 from public.inventory_items i where i.id = v_item and i.property_id = p_property_id
    ) then
      raise exception using errcode = '22023', message = 'unknown item for property';
    end if;

    insert into public.inventory_usage(item_id, used_qty, session_date, logged_by, notes, property_id, submitted_by_user_id)
    values (v_item, v_qty, p_session_date, nullif(btrim(coalesce(p_logged_by, '')), ''), nullif(btrim(coalesce(p_notes, '')), ''), p_property_id, auth.uid());

    update public.inventory_items
    set qty_on_hand = greatest(0, coalesce(qty_on_hand, 0) - v_qty)
    where id = v_item;

    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('ok', true, 'rows', v_count);
end;
$$;

revoke all on function public.record_inventory_usage(uuid, date, text, text, jsonb) from public, anon;
grant execute on function public.record_inventory_usage(uuid, date, text, text, jsonb) to authenticated, service_role;

comment on function public.record_inventory_usage(uuid, date, text, text, jsonb) is
  'Attributed inventory usage for named staff: inserts usage rows and decrements stock in one transaction. Requires submit_cleaning on the property.';

commit;

-- ===== ledger (run after the commit above succeeded; if this errors on a missing column, skip it and tell Claude) =====
insert into supabase_migrations.schema_migrations(version, name) values
  ('20260828000200','operational_rls_lockdown'),
  ('20260828000400','staff_roles_and_sessions'),
  ('20260828000500','db_backed_operational_authorization'),
  ('20260830002347','named_cleaner_access_boundary'),
  ('20260908000100','record_inventory_usage_rpc');
