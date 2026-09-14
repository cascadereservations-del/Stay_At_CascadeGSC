-- Companion guests (Lloyd, 2026-09-14): bookings often include people besides the
-- booker. New guest_companions table + audited history, same shape as
-- guest_profile_details/history. ID photos are staff-uploaded directly from the
-- browser to a new private Storage bucket (guest-id-photos) -- the agent never
-- fetches, views or stores a guest's ID image; only the resulting storage path is
-- written to id_photo_path via the same audited RPC.
begin;

create table if not exists public.guest_companions (
  id uuid primary key default gen_random_uuid(),
  guest_id uuid not null references public.guests(id) on delete cascade,
  property_id uuid not null references public.properties(id),
  name text not null,
  contact_number text,
  id_type text check (id_type is null or id_type in ('passport','drivers_license','national_id','other')),
  id_number text,
  id_photo_path text,
  notes text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1
);
create index if not exists guest_companions_guest_idx on public.guest_companions(guest_id);
comment on table public.guest_companions is
  'Companions on a stay besides the booking guest. id_number/id_photo_path are sensitive: RLS-scoped to manage_operations staff only. Photo bytes never pass through the agent -- staff upload directly to storage.guest-id-photos from the browser.';

create table if not exists public.guest_companion_history (
  id uuid primary key default gen_random_uuid(),
  companion_id uuid not null,
  guest_id uuid not null,
  changed_by uuid,
  changed_at timestamptz not null default now(),
  before_state jsonb,
  after_state jsonb,
  reason text
);

alter table public.guest_companions enable row level security;
alter table public.guest_companion_history enable row level security;
revoke all on public.guest_companions, public.guest_companion_history from public, anon, authenticated, service_role;
grant select on public.guest_companions, public.guest_companion_history to authenticated;
create policy guest_companions_manage_read on public.guest_companions for select to authenticated using (public.current_staff_authorized('manage_operations', property_id));
create policy guest_companion_history_manage_read on public.guest_companion_history for select to authenticated using (exists (select 1 from public.guests g where g.id = guest_id and public.current_staff_authorized('manage_operations', g.property_id)));

create or replace function public.save_guest_companion_v1(p_guest_id uuid, p_companion_id uuid, p_patch jsonb, p_expected_version integer, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_prop uuid; v_before jsonb; v_row public.guest_companions%rowtype;
begin
  select property_id into v_prop from public.guests where id = p_guest_id;
  if v_prop is null then raise exception using errcode = 'P0002', message = 'guest not found'; end if;
  if not public.current_staff_authorized('manage_operations', v_prop) then
    raise exception using errcode = '42501', message = 'manage_operations denied';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception using errcode = '22023', message = 'patch must be an object'; end if;
  if p_companion_id is null then
    insert into public.guest_companions(guest_id, property_id, name, created_by, updated_by)
    values (p_guest_id, v_prop, coalesce(nullif(btrim(p_patch->>'name'), ''), 'Companion'), auth.uid(), auth.uid())
    returning * into v_row;
    v_before := null;
  else
    select * into v_row from public.guest_companions where id = p_companion_id and guest_id = p_guest_id for update;
    if v_row.id is null then raise exception using errcode = 'P0002', message = 'companion not found'; end if;
    if p_expected_version is not null and v_row.version <> p_expected_version then
      raise exception using errcode = '40001', message = 'stale version: companion changed since it was loaded';
    end if;
    v_before := to_jsonb(v_row);
  end if;
  update public.guest_companions set
    name = case when p_patch ? 'name' then coalesce(nullif(btrim(p_patch->>'name'), ''), name) else name end,
    contact_number = case when p_patch ? 'contact_number' then nullif(btrim(p_patch->>'contact_number'), '') else contact_number end,
    id_type = case when p_patch ? 'id_type' then nullif(p_patch->>'id_type', '') else id_type end,
    id_number = case when p_patch ? 'id_number' then nullif(btrim(p_patch->>'id_number'), '') else id_number end,
    id_photo_path = case when p_patch ? 'id_photo_path' then nullif(btrim(p_patch->>'id_photo_path'), '') else id_photo_path end,
    notes = case when p_patch ? 'notes' then nullif(btrim(p_patch->>'notes'), '') else notes end,
    updated_by = auth.uid(), updated_at = now(), version = version + 1
  where id = v_row.id returning * into v_row;
  insert into public.guest_companion_history(companion_id, guest_id, changed_by, before_state, after_state, reason) values (v_row.id, p_guest_id, auth.uid(), v_before, to_jsonb(v_row), p_reason);
  return jsonb_build_object('ok', true, 'id', v_row.id, 'version', v_row.version, 'updatedAt', v_row.updated_at);
end;
$$;
revoke all on function public.save_guest_companion_v1(uuid, uuid, jsonb, integer, text) from public, anon, service_role;
grant execute on function public.save_guest_companion_v1(uuid, uuid, jsonb, integer, text) to authenticated;

create or replace function public.delete_guest_companion_v1(p_companion_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_row public.guest_companions%rowtype; v_prop uuid;
begin
  select * into v_row from public.guest_companions where id = p_companion_id;
  if v_row.id is null then raise exception using errcode = 'P0002', message = 'companion not found'; end if;
  select property_id into v_prop from public.guests where id = v_row.guest_id;
  if not public.current_staff_authorized('manage_operations', v_prop) then
    raise exception using errcode = '42501', message = 'manage_operations denied';
  end if;
  insert into public.guest_companion_history(companion_id, guest_id, changed_by, before_state, after_state, reason) values (v_row.id, v_row.guest_id, auth.uid(), to_jsonb(v_row), null, p_reason);
  delete from public.guest_companions where id = p_companion_id;
  return jsonb_build_object('ok', true, 'id', p_companion_id);
end;
$$;
revoke all on function public.delete_guest_companion_v1(uuid, text) from public, anon, service_role;
grant execute on function public.delete_guest_companion_v1(uuid, text) to authenticated;

create or replace function public.list_guest_companions_v1(p_guest_id uuid)
returns setof public.guest_companions language sql stable security definer set search_path = '' as $$
  select c.* from public.guest_companions c
  join public.guests g on g.id = c.guest_id
  where c.guest_id = p_guest_id and public.current_staff_authorized('manage_operations', g.property_id)
  order by c.created_at;
$$;
revoke all on function public.list_guest_companions_v1(uuid) from public, anon, service_role;
grant execute on function public.list_guest_companions_v1(uuid) to authenticated;

-- Private bucket for staff-uploaded ID photos. Direct client upload (RLS-gated),
-- same trust boundary as any other manage_operations write; the agent does not
-- call these storage endpoints.
insert into storage.buckets (id, name, public) values ('guest-id-photos', 'guest-id-photos', false)
on conflict (id) do nothing;

drop policy if exists "guest id photos manage read" on storage.objects;
create policy "guest id photos manage read" on storage.objects for select to authenticated
  using (bucket_id = 'guest-id-photos' and public.current_staff_authorized('manage_operations'));
drop policy if exists "guest id photos manage write" on storage.objects;
create policy "guest id photos manage write" on storage.objects for insert to authenticated
  with check (bucket_id = 'guest-id-photos' and public.current_staff_authorized('manage_operations'));
drop policy if exists "guest id photos manage delete" on storage.objects;
create policy "guest id photos manage delete" on storage.objects for delete to authenticated
  using (bucket_id = 'guest-id-photos' and public.current_staff_authorized('manage_operations'));

-- forward check: table, RPCs, bucket and policies all present
do $$
begin
  if to_regclass('public.guest_companions') is null then raise exception 'guest_companions table missing'; end if;
  if not exists (select 1 from pg_proc where proname = 'save_guest_companion_v1') then raise exception 'save_guest_companion_v1 missing'; end if;
  if not exists (select 1 from storage.buckets where id = 'guest-id-photos' and public = false) then raise exception 'guest-id-photos bucket missing or public'; end if;
  if (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'guest id photos%') <> 3 then
    raise exception 'guest-id-photos storage policies incomplete';
  end if;
end $$;

commit;
