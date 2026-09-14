-- Compensating rollback for 20260914220000_guest_profile_contact_and_id.sql.
-- Restores save_guest_profile_v1 to its pre-extension body and drops the nine new columns.
-- Refuses to run while any of them holds real data, so a rollback never silently discards a
-- guest's contact number, birthday, address, Airbnb profile id or ID-on-file record.
begin;

do $$
begin
  if exists (
    select 1 from public.guest_profile_details
    where contact_number is not null or birthday is not null or address is not null
       or airbnb_profile_id is not null or id_on_file or id_type is not null
       or id_number is not null or id_drive_url is not null or id_verified_at is not null
  ) then
    raise exception 'guest contact/ID data exists; clear or migrate it out before rolling back';
  end if;
end $$;

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
    contact_provenance = contact_provenance || jsonb_build_object('last_change', jsonb_build_object('by', auth.uid(), 'at', now(), 'fields', (select jsonb_agg(k) from jsonb_object_keys(p_patch) k))),
    updated_by = auth.uid(), updated_at = now(), version = version + 1
  where guest_id = p_guest_id returning * into v_row;
  insert into public.guest_profile_history(guest_id, changed_by, before_state, after_state, reason) values (p_guest_id, auth.uid(), v_before, to_jsonb(v_row), p_reason);
  return jsonb_build_object('ok', true, 'guestId', p_guest_id, 'version', v_row.version, 'updatedAt', v_row.updated_at);
end;
$$;

alter table public.guest_profile_details
  drop column if exists contact_number,
  drop column if exists birthday,
  drop column if exists address,
  drop column if exists airbnb_profile_id,
  drop column if exists id_on_file,
  drop column if exists id_type,
  drop column if exists id_number,
  drop column if exists id_drive_url,
  drop column if exists id_verified_at;

commit;
