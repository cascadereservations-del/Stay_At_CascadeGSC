-- 20261009030000_concierge_save_guest_id.sql
-- Session 79 (lane B, SQL): release s79_guest_id_20261009. The Messenger concierge (Cassy) can receive a guest's ID photo and file it.
-- concierge_save_guest_id_v1 is the Messenger twin of telegram_save_guest_companion_v1 / telegram_save_guest_details_v1
-- (20261002020000) and intake_save_guest_companion_v1 (20261007130000): same tables (guest_companions, guest_companion_history,
-- guest_profile_details, guest_profile_history), same validation (name, id type set, 12 people per guest, photo path
-- <companion id>/<uuid>.(jpg|png|webp), object present in storage bucket guest-id-photos), but no human actor. The bot has no staff
-- identity, so history rows carry changed_by null (the system actor, as the guest form does) and reason 'messenger-auto'.
-- The edge function mints the companion id and uploads the object first; this RPC then creates the companion with that id.
-- Reasons come back as data ({ok:false, reason}), never as exceptions, so the bot can say what went wrong:
--   no_booking | not_confirmed | bad_path | photo_missing | too_many | bad_id_type | bad_name
-- Idempotent on p_companion_id: a second call with the same id and guest returns ok with the existing row and writes nothing.
-- Never written: id_number, birthday, address, contact. service_role only. Expand only: one function, no table, no data change.
-- Rollback: supabase/rollbacks/20261009_s79_guest_id.sql

begin;

create or replace function public.concierge_save_guest_id_v1(
  p_booking_id uuid, p_companion_id uuid, p_name text, p_id_type text, p_path text, p_mark_id_on_file boolean)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  b record; v_name text; v_path text; v_row public.guest_companions%rowtype; v_prof public.guest_profile_details%rowtype;
  v_before jsonb; v_on_file boolean;
begin
  select bi.id, bi.guest_id, bi.property_id, bi.status into b from public.booking_inquiries bi where bi.id = p_booking_id;
  if not found or b.guest_id is null then return jsonb_build_object('ok', false, 'reason', 'no_booking'); end if;
  if b.status <> 'confirmed' then return jsonb_build_object('ok', false, 'reason', 'not_confirmed'); end if;
  if p_companion_id is null then return jsonb_build_object('ok', false, 'reason', 'bad_path'); end if;

  -- One lock on the guest row serialises two photos arriving together (the 12-people count, the companion insert).
  perform 1 from public.guests where id = b.guest_id for update;

  -- Idempotent: the companion already exists.
  select * into v_row from public.guest_companions where id = p_companion_id;
  if found then
    if v_row.guest_id <> b.guest_id then return jsonb_build_object('ok', false, 'reason', 'bad_path'); end if;
    return jsonb_build_object('ok', true, 'companion_id', v_row.id,
      'id_on_file', coalesce((select d.id_on_file from public.guest_profile_details d where d.guest_id = b.guest_id), false));
  end if;

  v_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  if char_length(v_name) not between 2 and 120 or v_name ~ '[0-9]{4}' then
    return jsonb_build_object('ok', false, 'reason', 'bad_name');
  end if;
  if p_id_type is not null and p_id_type not in ('passport', 'drivers_license', 'national_id', 'other') then
    return jsonb_build_object('ok', false, 'reason', 'bad_id_type');
  end if;
  v_path := nullif(btrim(coalesce(p_path, '')), '');
  if v_path is null
     or v_path !~ ('^' || p_companion_id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|png|webp)$') then
    return jsonb_build_object('ok', false, 'reason', 'bad_path');
  end if;
  if not exists (select 1 from storage.objects where bucket_id = 'guest-id-photos' and name = v_path) then
    return jsonb_build_object('ok', false, 'reason', 'photo_missing');
  end if;
  if (select count(*) from public.guest_companions where guest_id = b.guest_id) >= 12 then
    return jsonb_build_object('ok', false, 'reason', 'too_many');
  end if;

  insert into public.guest_companions(id, guest_id, property_id, name, id_type, id_photo_path, notes, created_by, updated_by)
  values (p_companion_id, b.guest_id, b.property_id, v_name, p_id_type, v_path, 'Sent in Messenger', null, null)
  returning * into v_row;
  insert into public.guest_companion_history(companion_id, guest_id, changed_by, before_state, after_state, reason)
  values (v_row.id, b.guest_id, null, null, to_jsonb(v_row), 'messenger-auto');

  insert into public.guest_profile_details(guest_id, property_id) values (b.guest_id, b.property_id) on conflict (guest_id) do nothing;
  select * into v_prof from public.guest_profile_details where guest_id = b.guest_id for update;
  v_on_file := v_prof.id_on_file;
  if coalesce(p_mark_id_on_file, false) and not coalesce(v_prof.id_on_file, false) then
    v_before := to_jsonb(v_prof);
    update public.guest_profile_details set
      id_on_file = true,
      contact_provenance = contact_provenance || jsonb_build_object('last_change',
        jsonb_build_object('via', 'messenger', 'at', now(), 'fields', jsonb_build_array('id_on_file'))),
      updated_by = null, updated_at = now(), version = version + 1
    where guest_id = b.guest_id returning * into v_prof;
    insert into public.guest_profile_history(guest_id, changed_by, before_state, after_state, reason)
    values (b.guest_id, null, v_before, to_jsonb(v_prof), 'messenger-auto');
    v_on_file := true;
  end if;

  return jsonb_build_object('ok', true, 'companion_id', v_row.id, 'id_on_file', coalesce(v_on_file, false));
end $$;

revoke all on function public.concierge_save_guest_id_v1(uuid, uuid, text, text, text, boolean) from public, anon, authenticated;
grant execute on function public.concierge_save_guest_id_v1(uuid, uuid, text, text, text, boolean) to service_role;

comment on function public.concierge_save_guest_id_v1(uuid, uuid, text, text, text, boolean) is
  'S79: files an ID photo the guest sent in Messenger as a companion row on the confirmed direct booking''s guest (id = p_companion_id, notes ''Sent in Messenger''), optionally marking id_on_file. History reason ''messenger-auto'', changed_by null. Reasons as data: no_booking, not_confirmed, bad_path, photo_missing, too_many, bad_id_type, bad_name. Idempotent on p_companion_id. service_role only.';

commit;
