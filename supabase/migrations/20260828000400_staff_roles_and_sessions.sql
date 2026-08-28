create table public.staff_access_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','admin','finance','inspector','cleaner','maintenance')),
  property_ids uuid[] not null default '{}',
  disabled_at timestamptz,
  sessions_revoked_after timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.staff_access_audit (
  id uuid primary key default extensions.uuid_generate_v4(),
  actor_user_id uuid references auth.users(id),
  target_user_id uuid not null references auth.users(id),
  action text not null check (action in ('created','role_changed','disabled','enabled','sessions_revoked')),
  before_state jsonb not null default '{}'::jsonb,
  after_state jsonb not null default '{}'::jsonb,
  reason text,
  created_at timestamptz not null default now()
);

alter table public.staff_access_profiles enable row level security;
alter table public.staff_access_audit enable row level security;
revoke all on public.staff_access_profiles, public.staff_access_audit from public, anon, authenticated;
grant all on public.staff_access_profiles, public.staff_access_audit to service_role;

create or replace function public.staff_access_allowed(
  p_role text,
  p_action text,
  p_disabled_at timestamptz,
  p_aal text
) returns boolean
language sql immutable set search_path = '' as $$
  select case
    when p_disabled_at is not null then false
    when p_action in ('manage_staff','approve_payment','read_finance') and p_aal <> 'aal2' then false
    when p_role in ('owner','admin') then p_action in ('manage_staff','approve_payment','read_finance','inspect_cleaning','submit_cleaning','manage_maintenance')
    when p_role = 'finance' then p_action in ('approve_payment','read_finance')
    when p_role = 'inspector' then p_action = 'inspect_cleaning'
    when p_role = 'cleaner' then p_action = 'submit_cleaning'
    when p_role = 'maintenance' then p_action = 'manage_maintenance'
    else false
  end;
$$;

revoke all on function public.staff_access_allowed(text,text,timestamptz,text) from public, anon, authenticated;
grant execute on function public.staff_access_allowed(text,text,timestamptz,text) to service_role;

comment on table public.staff_access_profiles is 'Named Cascade staff identities. Do not use editable user_metadata for authorization.';
comment on table public.staff_access_audit is 'Immutable administrative trail for staff access, disablement and session revocation.';
