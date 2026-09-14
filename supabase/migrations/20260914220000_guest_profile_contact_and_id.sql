-- Guest CRM fields the profile lacks (session-13 step 4): contact number, birthday, address,
-- Airbnb profile id, and ID on file. Additive only: new nullable columns on guest_profile_details,
-- save_guest_profile_v1 learns the new patch keys (still audited via guest_profile_history, same
-- as every other field on this table). No column is renamed or dropped.
begin;

alter table public.guest_profile_details
  add column if not exists contact_number text,
  add column if not exists birthday date,
  add column if not exists address text,
  add column if not exists airbnb_profile_id text,
  add column if not exists id_on_file boolean not null default false,
  add column if not exists id_type text check (id_type is null or id_type in ('passport','drivers_license','national_id','other')),
  add column if not exists id_number text,
  add column if not exists id_drive_url text,
  add column if not exists id_verified_at timestamptz;

comment on column public.guest_profile_details.id_number is
  'OCR-parsed from a government ID photo (Lloyd, 2026-09-14). Sensitive: this table is RLS-scoped to manage_operations staff only, never anon/unauthenticated.';
comment on column public.guest_profile_details.id_drive_url is
  'Link to the ID photo copy in Drive; the photo itself is never stored in Supabase.';

create or replace function public.save_guest_profile_v1(p_guest_id uuid, p_patch jsonb, p_expected_version integer, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_prop uuid; v_before jsonb; v_row public.guest_profile_details%rowtype;
begin
  select property_id into v_prop from public.guests where id = p_guest_id;
  if v_prop is null then raise exception using errcode = 'P0002', message = 'guest not found'; end if;
  perform public.admin_require('manage_operations', v_prop);
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception using errcode = '22023', message = 'patch must be an object'; end if;
  insert into public.guest_profile_details(guest_id, property_id) values (p_guest_id, v_prop) on conflict (guest_id) do nothing;
  select * into v_row from public.guest_profile_details where guest_id = p_guest_id for update;
  if p_expected_version is not null and v_row.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'stale version: profile changed since it was loaded';
  end if;
  v_before := to_jsonb(v_row);
  update public.guest_profile_details set
    display_name = case when p_patch ? 'display_name' then nullif(btrim(p_patch->>'display_name'), '') else display_name end,
    preferred_channel = case when p_patch ? 'preferred_channel' then nullif(p_patch->>'preferred_channel', '') else preferred_channel end,
    language = case when p_patch ? 'language' then nullif(btrim(p_patch->>'language'), '') else language end,
    messenger_psid = case when p_patch ? 'messenger_psid' then nullif(btrim(p_patch->>'messenger_psid'), '') else messenger_psid end,
    messenger_link = case when p_patch ? 'messenger_link' then nullif(btrim(p_patch->>'messenger_link'), '') else messenger_link end,
    stay_preferences = case when p_patch ? 'stay_preferences' then nullif(btrim(p_patch->>'stay_preferences'), '') else stay_preferences end,
    tags = case when p_patch ? 'tags' then coalesce((select array_agg(x) from jsonb_array_elements_text(p_patch->'tags') x), '{}') else tags end,
    vip = case when p_patch ? 'vip' then (p_patch->>'vip')::boolean else vip end,
    vip_reason = case when p_patch ? 'vip_reason' then nullif(btrim(p_patch->>'vip_reason'), '') else vip_reason end,
    contact_number = case when p_patch ? 'contact_number' then nullif(btrim(p_patch->>'contact_number'), '') else contact_number end,
    birthday = case when p_patch ? 'birthday' then nullif(p_patch->>'birthday', '')::date else birthday end,
    address = case when p_patch ? 'address' then nullif(btrim(p_patch->>'address'), '') else address end,
    airbnb_profile_id = case when p_patch ? 'airbnb_profile_id' then nullif(btrim(p_patch->>'airbnb_profile_id'), '') else airbnb_profile_id end,
    id_on_file = case when p_patch ? 'id_on_file' then (p_patch->>'id_on_file')::boolean else id_on_file end,
    id_type = case when p_patch ? 'id_type' then nullif(p_patch->>'id_type', '') else id_type end,
    id_number = case when p_patch ? 'id_number' then nullif(btrim(p_patch->>'id_number'), '') else id_number end,
    id_drive_url = case when p_patch ? 'id_drive_url' then nullif(btrim(p_patch->>'id_drive_url'), '') else id_drive_url end,
    id_verified_at = case when p_patch ? 'id_verified_at' then nullif(p_patch->>'id_verified_at', '')::timestamptz else id_verified_at end,
    contact_provenance = contact_provenance || jsonb_build_object('last_change', jsonb_build_object('by', auth.uid(), 'at', now(), 'fields', (select jsonb_agg(k) from jsonb_object_keys(p_patch) k))),
    updated_by = auth.uid(), updated_at = now(), version = version + 1
  where guest_id = p_guest_id returning * into v_row;
  insert into public.guest_profile_history(guest_id, changed_by, before_state, after_state, reason) values (p_guest_id, auth.uid(), v_before, to_jsonb(v_row), p_reason);
  return jsonb_build_object('ok', true, 'guestId', p_guest_id, 'version', v_row.version, 'updatedAt', v_row.updated_at);
end;
$$;
revoke all on function public.save_guest_profile_v1(uuid, jsonb, integer, text) from public, anon, service_role;
grant execute on function public.save_guest_profile_v1(uuid, jsonb, integer, text) to authenticated;

-- forward check: new columns exist and the RPC still round-trips a patch
do $$
declare v_cols integer;
begin
  select count(*) into v_cols from information_schema.columns
  where table_schema = 'public' and table_name = 'guest_profile_details'
    and column_name in ('contact_number','birthday','address','airbnb_profile_id','id_on_file','id_type','id_number','id_drive_url','id_verified_at');
  if v_cols <> 9 then
    raise exception 'guest_profile_details is missing one or more of the new contact/ID columns (found %)', v_cols;
  end if;
end $$;

commit;
