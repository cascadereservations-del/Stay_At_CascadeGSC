-- Session 67b: Telegram guest intake (Lloyd 2026-10-02: "verify and confirm Cassy has the abilities to process photos and update guest
-- details accordingly via Telegram"). D-126 planned a /guest intake that was never built; D-118/D-128 allow only human-initiated,
-- one-photo-at-a-time, confirm-before-save work, no ID numbers anywhere, photos only in the private guest-id-photos bucket.
--
-- The bot has no auth.uid(), so save_guest_profile_v1 / save_guest_companion_v1 (admin_require / current_staff_authorized) cannot be
-- called by it. This release adds a service_role-only RPC set that does the same audited writes on behalf of a Telegram user who maps
-- to an active staff_access_profiles row (telegram_user_id) whose role allows manage_operations (owner, admin) with access to the
-- property. An unmapped or disabled user gets {ok:false, reason:'unmapped_telegram_user'} and nothing is written.
--
-- New (all SECURITY DEFINER, search_path '', service_role only):
--   telegram_staff_actor_v1(bigint, uuid)         internal: the staff user_id for a Telegram id, or null. Not callable by anyone but owner.
--   telegram_guest_candidates_v1(...)             the guests the picker offers: stays overlapping [from,to], or a name search. Read only.
--   telegram_save_guest_details_v1(...)           contact_number, id_on_file, id_type, stay_preferences (appended). One history row.
--   telegram_save_guest_companion_v1(...)         create-or-update a companion by name (contact, id_type, notes, id_photo_path).
-- Never written here: id_number, birthday, address, anything else. The patch is a whitelist; any other key is refused.
-- Audit: guest_profile_history / guest_companion_history rows with changed_by = the staff user_id and reason 'telegram: <reason>',
-- the same shape as the dashboard RPCs. A save that would change nothing returns {ok:true, unchanged:true} and writes nothing.
-- No table, column, policy or data change; nothing is dropped.

begin;

create or replace function public.telegram_staff_actor_v1(p_actor_telegram_id bigint, p_property_id uuid)
returns uuid
language sql stable security definer set search_path to '' as $$
  select p.user_id
    from public.staff_access_profiles p
   where p_actor_telegram_id is not null
     and p.telegram_user_id = p_actor_telegram_id
     and public.staff_access_allowed(p.role, 'manage_operations', p.disabled_at, null)
     and (p.role = 'owner' or exists (
           select 1 from public.staff_property_access s where s.user_id = p.user_id and s.property_id = p_property_id))
   order by p.created_at
   limit 1;
$$;

create or replace function public.telegram_guest_candidates_v1(
  p_actor_telegram_id bigint, p_property_id uuid, p_from date, p_to date, p_search text)
returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare
  v_actor uuid := public.telegram_staff_actor_v1(p_actor_telegram_id, p_property_id);
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
  v_rows jsonb;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  if v_q is not null then
    if char_length(v_q) < 2 then return jsonb_build_object('ok', false, 'reason', 'search_too_short'); end if;
    select coalesce(jsonb_agg(jsonb_build_object(
             'guest_id', x.id, 'name', x.name, 'checkin', null, 'checkout', null, 'last_stay', x.last_stay_date,
             'id_on_file', coalesce(d.id_on_file, false),
             'has_contact', coalesce(btrim(d.contact_number), '') <> '',
             'companions', coalesce((select jsonb_agg(c.name order by c.created_at) from public.guest_companions c where c.guest_id = x.id), '[]'::jsonb)
           ) order by x.last_stay_date desc nulls last, x.name), '[]'::jsonb)
      into v_rows
      from (select g.id, g.name, g.last_stay_date
              from public.guests g
             where g.property_id = p_property_id
               and g.name ilike '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%'
             order by g.last_stay_date desc nulls last, g.name
             limit 8) x
      left join public.guest_profile_details d on d.guest_id = x.id;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
             'guest_id', x.gid, 'name', g.name, 'checkin', x.checkin_date, 'checkout', x.checkout_date, 'last_stay', g.last_stay_date,
             'id_on_file', coalesce(d.id_on_file, false),
             'has_contact', coalesce(btrim(d.contact_number), '') <> '',
             'companions', coalesce((select jsonb_agg(c.name order by c.created_at) from public.guest_companions c where c.guest_id = g.id), '[]'::jsonb)
           ) order by x.checkin_date, g.name), '[]'::jsonb)
      into v_rows
      from (select s.gid, s.checkin_date, s.checkout_date
              from (select distinct on (st.gid) st.gid, st.checkin_date, st.checkout_date
                      from (select coalesce(r.guest_id, bi.guest_id) as gid, ce.checkin_date, ce.checkout_date
                              from public.calendar_events ce
                              left join public.airbnb_reservations r on r.id = ce.linked_reservation_id
                              left join public.booking_inquiries bi on bi.id = public.stay_uid_inquiry_v1(ce.uid)
                             where ce.property_id = p_property_id
                               and ce.status = 'confirmed'
                               and ce.checkin_date <= p_to
                               and ce.checkout_date > p_from) st
                     where st.gid is not null
                     order by st.gid, st.checkin_date) s
             order by s.checkin_date
             limit 12) x
      join public.guests g on g.id = x.gid and g.property_id = p_property_id
      left join public.guest_profile_details d on d.guest_id = g.id;
  end if;
  return jsonb_build_object('ok', true, 'guests', v_rows);
end;
$$;

create or replace function public.telegram_save_guest_details_v1(
  p_guest_id uuid, p_patch jsonb, p_actor_telegram_id bigint, p_reason text)
returns jsonb
language plpgsql security definer set search_path to '' as $$
declare
  v_prop uuid; v_actor uuid; v_bad text; v_before jsonb;
  v_row public.guest_profile_details%rowtype;
  v_contact text; v_id_type text; v_pref_new text; v_pref text; v_on_file boolean; v_keys jsonb;
begin
  select property_id into v_prop from public.guests where id = p_guest_id;
  if v_prop is null then raise exception using errcode = 'P0002', message = 'guest not found'; end if;
  v_actor := public.telegram_staff_actor_v1(p_actor_telegram_id, v_prop);
  if v_actor is null then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception using errcode = '22023', message = 'patch must be a non-empty object';
  end if;
  select k into v_bad from jsonb_object_keys(p_patch) k
   where k not in ('contact_number', 'id_on_file', 'id_type', 'stay_preferences') limit 1;
  if v_bad is not null then raise exception using errcode = '22023', message = format('field not allowed from Telegram: %s', v_bad); end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 3 and 500 then
    raise exception using errcode = '22023', message = 'profile change reason required';
  end if;
  if exists (select 1 from jsonb_each_text(p_patch) f where char_length(f.value) > 4000) then
    raise exception using errcode = '22023', message = 'profile field too long';
  end if;

  insert into public.guest_profile_details(guest_id, property_id) values (p_guest_id, v_prop) on conflict (guest_id) do nothing;
  select * into v_row from public.guest_profile_details where guest_id = p_guest_id for update;
  v_before := to_jsonb(v_row);

  v_contact := v_row.contact_number;
  if p_patch ? 'contact_number' then
    v_contact := nullif(regexp_replace(btrim(coalesce(p_patch->>'contact_number', '')), '[ -]', '', 'g'), '');
    if v_contact is not null and v_contact !~ '^[+]?[0-9]{7,15}$' then
      raise exception using errcode = '22023', message = 'contact number looks invalid';
    end if;
  end if;
  v_id_type := v_row.id_type;
  if p_patch ? 'id_type' then
    v_id_type := nullif(p_patch->>'id_type', '');
    if v_id_type is not null and v_id_type not in ('passport', 'drivers_license', 'national_id', 'other') then
      raise exception using errcode = '22023', message = 'id type not recognised';
    end if;
  end if;
  v_on_file := v_row.id_on_file;
  if p_patch ? 'id_on_file' then v_on_file := (p_patch->>'id_on_file')::boolean; end if;
  v_pref := v_row.stay_preferences;
  if p_patch ? 'stay_preferences' then
    v_pref_new := nullif(btrim(coalesce(p_patch->>'stay_preferences', '')), '');
    if v_pref_new is not null and (v_pref is null or position(v_pref_new in v_pref) = 0) then
      v_pref := case when v_pref is null then v_pref_new else v_pref || E'\n' || v_pref_new end;
      if char_length(v_pref) > 4000 then raise exception using errcode = '22023', message = 'stay preferences too long'; end if;
    end if;
  end if;

  if v_contact is not distinct from v_row.contact_number and v_id_type is not distinct from v_row.id_type
     and v_on_file is not distinct from v_row.id_on_file and v_pref is not distinct from v_row.stay_preferences then
    return jsonb_build_object('ok', true, 'unchanged', true, 'guestId', p_guest_id, 'version', v_row.version);
  end if;

  select jsonb_agg(k) into v_keys from jsonb_object_keys(p_patch) k;
  update public.guest_profile_details set
    contact_number = v_contact, id_type = v_id_type, id_on_file = v_on_file, stay_preferences = v_pref,
    contact_provenance = contact_provenance || jsonb_build_object('last_change',
      jsonb_build_object('by', v_actor, 'via', 'telegram', 'at', now(), 'fields', v_keys)),
    updated_by = v_actor, updated_at = now(), version = version + 1
  where guest_id = p_guest_id returning * into v_row;
  insert into public.guest_profile_history(guest_id, changed_by, before_state, after_state, reason)
  values (p_guest_id, v_actor, v_before, to_jsonb(v_row), 'telegram: ' || btrim(p_reason));
  return jsonb_build_object('ok', true, 'unchanged', false, 'guestId', p_guest_id, 'version', v_row.version, 'updatedAt', v_row.updated_at);
end;
$$;

create or replace function public.telegram_save_guest_companion_v1(
  p_guest_id uuid, p_name text, p_id_type text, p_id_photo_path text, p_contact text, p_notes text,
  p_actor_telegram_id bigint, p_reason text)
returns jsonb
language plpgsql security definer set search_path to '' as $$
declare
  v_prop uuid; v_actor uuid; v_name text; v_contact text; v_notes text; v_path text; v_before jsonb;
  v_row public.guest_companions%rowtype;
  n_contact text; n_type text; n_path text; n_notes text;
begin
  select property_id into v_prop from public.guests where id = p_guest_id;
  if v_prop is null then raise exception using errcode = 'P0002', message = 'guest not found'; end if;
  v_actor := public.telegram_staff_actor_v1(p_actor_telegram_id, v_prop);
  if v_actor is null then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  v_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  if char_length(v_name) not between 2 and 120 or v_name ~ '[0-9]{4}' then
    raise exception using errcode = '22023', message = 'companion name invalid';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 3 and 500 then
    raise exception using errcode = '22023', message = 'change reason required';
  end if;
  if p_id_type is not null and p_id_type not in ('passport', 'drivers_license', 'national_id', 'other') then
    raise exception using errcode = '22023', message = 'id type not recognised';
  end if;
  v_contact := nullif(regexp_replace(btrim(coalesce(p_contact, '')), '[ -]', '', 'g'), '');
  if v_contact is not null and v_contact !~ '^[+]?[0-9]{7,15}$' then
    raise exception using errcode = '22023', message = 'contact number looks invalid';
  end if;
  v_notes := nullif(btrim(coalesce(p_notes, '')), '');
  if v_notes is not null and char_length(v_notes) > 1000 then raise exception using errcode = '22023', message = 'notes too long'; end if;
  v_path := nullif(btrim(coalesce(p_id_photo_path, '')), '');

  select * into v_row from public.guest_companions
   where guest_id = p_guest_id and lower(regexp_replace(btrim(name), '\s+', ' ', 'g')) = lower(v_name)
   order by created_at limit 1 for update;

  if v_row.id is null then
    if v_path is not null then
      raise exception using errcode = '22023', message = 'create the companion first, then attach the photo';
    end if;
    if (select count(*) from public.guest_companions where guest_id = p_guest_id) >= 12 then
      raise exception using errcode = '22023', message = 'too many companions on this guest';
    end if;
    insert into public.guest_companions(guest_id, property_id, name, contact_number, id_type, notes, created_by, updated_by)
    values (p_guest_id, v_prop, v_name, v_contact, p_id_type, v_notes, v_actor, v_actor)
    returning * into v_row;
    insert into public.guest_companion_history(companion_id, guest_id, changed_by, before_state, after_state, reason)
    values (v_row.id, p_guest_id, v_actor, null, to_jsonb(v_row), 'telegram: ' || btrim(p_reason));
    return jsonb_build_object('ok', true, 'created', true, 'unchanged', false, 'id', v_row.id, 'version', v_row.version);
  end if;

  if v_path is not null then
    if v_path !~ ('^' || v_row.id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|png|webp)$') then
      raise exception using errcode = '22023', message = 'photo path is not this companion''s';
    end if;
    if not exists (select 1 from storage.objects where bucket_id = 'guest-id-photos' and name = v_path) then
      raise exception using errcode = 'P0002', message = 'photo object not found in guest-id-photos';
    end if;
  end if;
  v_before := to_jsonb(v_row);
  n_contact := coalesce(v_contact, v_row.contact_number);
  n_type := coalesce(p_id_type, v_row.id_type);
  n_path := coalesce(v_path, v_row.id_photo_path);
  n_notes := case when v_notes is null then v_row.notes
                  when v_row.notes is null then v_notes
                  when position(v_notes in v_row.notes) > 0 then v_row.notes
                  else v_row.notes || E'\n' || v_notes end;
  if n_contact is not distinct from v_row.contact_number and n_type is not distinct from v_row.id_type
     and n_path is not distinct from v_row.id_photo_path and n_notes is not distinct from v_row.notes then
    return jsonb_build_object('ok', true, 'created', false, 'unchanged', true, 'id', v_row.id, 'version', v_row.version);
  end if;
  update public.guest_companions set
    contact_number = n_contact, id_type = n_type, id_photo_path = n_path, notes = n_notes,
    updated_by = v_actor, updated_at = now(), version = version + 1
  where id = v_row.id returning * into v_row;
  insert into public.guest_companion_history(companion_id, guest_id, changed_by, before_state, after_state, reason)
  values (v_row.id, p_guest_id, v_actor, v_before, to_jsonb(v_row), 'telegram: ' || btrim(p_reason));
  return jsonb_build_object('ok', true, 'created', false, 'unchanged', false, 'id', v_row.id, 'version', v_row.version);
end;
$$;

revoke all on function public.telegram_staff_actor_v1(bigint, uuid) from public, anon, authenticated, service_role;
revoke all on function public.telegram_guest_candidates_v1(bigint, uuid, date, date, text) from public, anon, authenticated;
revoke all on function public.telegram_save_guest_details_v1(uuid, jsonb, bigint, text) from public, anon, authenticated;
revoke all on function public.telegram_save_guest_companion_v1(uuid, text, text, text, text, text, bigint, text) from public, anon, authenticated;
grant execute on function public.telegram_guest_candidates_v1(bigint, uuid, date, date, text) to service_role;
grant execute on function public.telegram_save_guest_details_v1(uuid, jsonb, bigint, text) to service_role;
grant execute on function public.telegram_save_guest_companion_v1(uuid, text, text, text, text, text, bigint, text) to service_role;

comment on function public.telegram_staff_actor_v1(bigint, uuid) is
  'Session 67b: the staff user_id for a Telegram id (active, role allows manage_operations, has the property), else null. Internal.';
comment on function public.telegram_guest_candidates_v1(bigint, uuid, date, date, text) is
  'Session 67b: guests the Telegram /guest picker offers (stays overlapping the window, or a name search, max 8). {ok:false,reason:unmapped_telegram_user} for an unmapped user. service_role only.';
comment on function public.telegram_save_guest_details_v1(uuid, jsonb, bigint, text) is
  'Session 67b: audited guest profile save from Telegram. Whitelist: contact_number, id_on_file, id_type, stay_preferences (appended). Never an ID number. service_role only.';
comment on function public.telegram_save_guest_companion_v1(uuid, text, text, text, text, text, bigint, text) is
  'Session 67b: audited create-or-update of a companion by name from Telegram; the photo path must be <companion id>/<uuid>.(jpg|png|webp) and exist in guest-id-photos. service_role only.';

commit;
