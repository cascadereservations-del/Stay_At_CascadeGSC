-- Richer Staff tab (session-13 step 3): contact, ID and fee-structure fields staff_access_profiles
-- lacks. New table keyed by user_id, same audited-history shape as guest_profile_details/history
-- (CRM01), written only through save_staff_details_v1 -- never a direct table write. Fee columns are
-- descriptive defaults for display/edit only; cleaner_rate_schedule (already read by
-- submit-cleaning/notify-cleaner-payment) remains the source of truth actually booked into
-- cleaner_fee rows.
begin;

create table if not exists public.staff_details (
  user_id uuid primary key references public.staff_access_profiles(user_id) on delete cascade,
  contact_number text,
  alternate_contact text,
  address text,
  id_type text check (id_type is null or id_type in ('passport','drivers_license','national_id','other')),
  id_number text,
  id_drive_url text,
  emergency_contact_name text,
  emergency_contact_number text,
  start_date date,
  fee_turnover numeric,
  fee_transport numeric,
  fee_deep_clean numeric,
  updated_by uuid,
  updated_at timestamptz not null default now(),
  version integer not null default 1
);
comment on table public.staff_details is
  'OPS03 extension of staff_access_profiles. Every field optional. id_number/id_drive_url follow the same sensitivity note as guest_profile_details: RLS-scoped to manage_staff only.';

create table if not exists public.staff_details_history (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  changed_by uuid,
  changed_at timestamptz not null default now(),
  before_state jsonb,
  after_state jsonb,
  reason text
);

alter table public.staff_details enable row level security;
alter table public.staff_details_history enable row level security;
revoke all on public.staff_details, public.staff_details_history from public, anon, authenticated, service_role;
grant select on public.staff_details, public.staff_details_history to authenticated;
create policy staff_details_manage_read on public.staff_details for select to authenticated using (public.current_staff_authorized('manage_staff'));
create policy staff_details_history_manage_read on public.staff_details_history for select to authenticated using (public.current_staff_authorized('manage_staff'));

create or replace function public.save_staff_details_v1(p_user_id uuid, p_patch jsonb, p_expected_version integer, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_before jsonb; v_row public.staff_details%rowtype;
begin
  if not public.current_staff_authorized('manage_staff') then
    raise exception using errcode = '42501', message = 'manage_staff denied';
  end if;
  if not exists (select 1 from public.staff_access_profiles where user_id = p_user_id) then
    raise exception using errcode = 'P0002', message = 'staff member not found';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception using errcode = '22023', message = 'patch must be an object'; end if;
  insert into public.staff_details(user_id) values (p_user_id) on conflict (user_id) do nothing;
  select * into v_row from public.staff_details where user_id = p_user_id for update;
  if p_expected_version is not null and v_row.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'stale version: staff details changed since they were loaded';
  end if;
  v_before := to_jsonb(v_row);
  update public.staff_details set
    contact_number = case when p_patch ? 'contact_number' then nullif(btrim(p_patch->>'contact_number'), '') else contact_number end,
    alternate_contact = case when p_patch ? 'alternate_contact' then nullif(btrim(p_patch->>'alternate_contact'), '') else alternate_contact end,
    address = case when p_patch ? 'address' then nullif(btrim(p_patch->>'address'), '') else address end,
    id_type = case when p_patch ? 'id_type' then nullif(p_patch->>'id_type', '') else id_type end,
    id_number = case when p_patch ? 'id_number' then nullif(btrim(p_patch->>'id_number'), '') else id_number end,
    id_drive_url = case when p_patch ? 'id_drive_url' then nullif(btrim(p_patch->>'id_drive_url'), '') else id_drive_url end,
    emergency_contact_name = case when p_patch ? 'emergency_contact_name' then nullif(btrim(p_patch->>'emergency_contact_name'), '') else emergency_contact_name end,
    emergency_contact_number = case when p_patch ? 'emergency_contact_number' then nullif(btrim(p_patch->>'emergency_contact_number'), '') else emergency_contact_number end,
    start_date = case when p_patch ? 'start_date' then nullif(p_patch->>'start_date', '')::date else start_date end,
    fee_turnover = case when p_patch ? 'fee_turnover' then nullif(p_patch->>'fee_turnover', '')::numeric else fee_turnover end,
    fee_transport = case when p_patch ? 'fee_transport' then nullif(p_patch->>'fee_transport', '')::numeric else fee_transport end,
    fee_deep_clean = case when p_patch ? 'fee_deep_clean' then nullif(p_patch->>'fee_deep_clean', '')::numeric else fee_deep_clean end,
    updated_by = auth.uid(), updated_at = now(), version = version + 1
  where user_id = p_user_id returning * into v_row;
  insert into public.staff_details_history(user_id, changed_by, before_state, after_state, reason) values (p_user_id, auth.uid(), v_before, to_jsonb(v_row), p_reason);
  return jsonb_build_object('ok', true, 'userId', p_user_id, 'version', v_row.version, 'updatedAt', v_row.updated_at);
end;
$$;
revoke all on function public.save_staff_details_v1(uuid, jsonb, integer, text) from public, anon, service_role;
grant execute on function public.save_staff_details_v1(uuid, jsonb, integer, text) to authenticated;

create or replace function public.list_staff_details_v1()
returns setof public.staff_details language sql stable security definer set search_path = '' as $$
  select * from public.staff_details where public.current_staff_authorized('manage_staff');
$$;
revoke all on function public.list_staff_details_v1() from public, anon, service_role;
grant execute on function public.list_staff_details_v1() to authenticated;

-- forward check: table, RPCs and RLS all present
do $$
begin
  if to_regclass('public.staff_details') is null then raise exception 'staff_details table missing'; end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'save_staff_details_v1') then
    raise exception 'save_staff_details_v1 missing';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.staff_details'::regclass) then
    raise exception 'staff_details RLS not enabled';
  end if;
end $$;

commit;
