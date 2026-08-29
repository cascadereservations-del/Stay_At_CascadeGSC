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
