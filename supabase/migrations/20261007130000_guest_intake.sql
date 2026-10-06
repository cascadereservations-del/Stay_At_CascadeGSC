-- Session 74, SPEC-42 s4b: guest self-service intake ("Before you arrive" on the booking status page). A guest with a capability link
-- (guest_access_tokens, stored hashed, minted by submit-booking) adds each person's name, optional mobile, ID type and one ID photo.
-- The guest-intake Edge Function verifies nothing itself: every read and write goes through these definer RPCs, which take the SHA-256
-- of the token and resolve it to ONE confirmed direct booking (not revoked, not expired, not cancelled, not past check-out). A token that
-- opens nothing returns null / {ok:false,reason:'invalid_token'}; nothing is written.
--   intake_resolve_v1            internal: token hash -> the booking, its guest and its ref. Owner only.
--   intake_uploads_today_v1      internal: ID photos linked for this booking in the last 24 h (the 12 a day limit). Owner only.
--   intake_guest_context_v1      what the page may show: ref, dates, headcount, the people already on the stay (name, has_id, id_type).
--                                Never a phone, e-mail, address, door code, ID number or storage path.
--   intake_save_guest_details_v1 contact_number, id_on_file (true only), id_type for the booking guest. Same validation as the staff RPCs.
--   intake_save_guest_companion_v1 create-or-update a person by name; attaches an ID photo path that must be <companion id>/<uuid>.(jpg|png|webp)
--                                and exist in guest-id-photos. Photo storage follows SPEC-40 / D-292: the bucket, its policies and the
--                                purge trigger are untouched; the Edge Function writes the object with the service key, never a guest JWT.
-- Provenance: history rows carry changed_by null and reason 'guest form <ref>' (written here, never taken from the caller).
-- Never written here: id_number, birthday, address, notes. The patch is a whitelist. Expand only: five functions, no table, no data change.
-- Rollback: supabase/rollbacks/20261007_guest_intake.sql

begin;

create or replace function public.intake_resolve_v1(p_token_hash text)
returns table (booking_id uuid, property_id uuid, guest_id uuid, ref text, checkin_date date, checkout_date date, pax integer, guest_name text)
language sql stable security definer set search_path = '' as $$
  select b.id, b.property_id, b.guest_id, upper(left(b.id::text, 8)), b.checkin_date, b.checkout_date, b.pax::integer, g.name
    from public.guest_access_tokens t
    join public.booking_inquiries b on b.id = t.booking_id and b.source = 'direct'
    left join public.guests g on g.id = b.guest_id
   where p_token_hash ~ '^[a-f0-9]{64}$'
     and t.token_hash = p_token_hash and t.booking_type = 'direct' and t.revoked_at is null and t.expires_at > now()
     and b.status = 'confirmed'
     and b.checkout_date >= (now() at time zone 'Asia/Manila')::date;
$$;

create or replace function public.intake_uploads_today_v1(p_guest_id uuid, p_ref text)
returns integer
language sql stable security definer set search_path = '' as $$
  select count(*)::integer from public.guest_companion_history h
   where h.guest_id = p_guest_id and h.reason = 'guest form ' || p_ref and h.changed_at > now() - interval '1 day'
     and (h.after_state ->> 'id_photo_path') is distinct from (h.before_state ->> 'id_photo_path');
$$;

create or replace function public.intake_guest_context_v1(p_token_hash text)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r record;
begin
  select * into r from public.intake_resolve_v1(p_token_hash);
  if not found then return null; end if;
  return jsonb_build_object(
    'ref', r.ref, 'checkin_date', r.checkin_date, 'checkout_date', r.checkout_date, 'pax', r.pax,
    'can_save', r.guest_id is not null,
    'guest_name', r.guest_name,
    'max_uploads_per_day', 12,
    'uploads_today', case when r.guest_id is null then 0 else public.intake_uploads_today_v1(r.guest_id, r.ref) end,
    'people', case when r.guest_id is null then '[]'::jsonb else coalesce((
        select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'has_id', c.id_photo_path is not null, 'id_type', c.id_type) order by c.created_at)
          from public.guest_companions c where c.guest_id = r.guest_id), '[]'::jsonb) end);
end $$;

create or replace function public.intake_save_guest_details_v1(p_token_hash text, p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  r record; v_bad text; v_before jsonb; v_keys jsonb;
  v_row public.guest_profile_details%rowtype;
  v_contact text; v_id_type text; v_on_file boolean;
begin
  select * into r from public.intake_resolve_v1(p_token_hash);
  if not found then return jsonb_build_object('ok', false, 'reason', 'invalid_token'); end if;
  if r.guest_id is null then return jsonb_build_object('ok', false, 'reason', 'no_guest_record'); end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception using errcode = '22023', message = 'patch must be a non-empty object';
  end if;
  select k into v_bad from jsonb_object_keys(p_patch) k where k not in ('contact_number', 'id_on_file', 'id_type') limit 1;
  if v_bad is not null then raise exception using errcode = '22023', message = format('field not allowed from the guest form: %s', v_bad); end if;

  insert into public.guest_profile_details(guest_id, property_id) values (r.guest_id, r.property_id) on conflict (guest_id) do nothing;
  select * into v_row from public.guest_profile_details where guest_id = r.guest_id for update;
  v_before := to_jsonb(v_row);

  v_contact := v_row.contact_number;
  if p_patch ? 'contact_number' then
    v_contact := nullif(regexp_replace(btrim(coalesce(p_patch ->> 'contact_number', '')), '[ -]', '', 'g'), '');
    if v_contact is not null and v_contact !~ '^[+]?[0-9]{7,15}$' then
      raise exception using errcode = '22023', message = 'contact number looks invalid';
    end if;
  end if;
  v_id_type := v_row.id_type;
  if p_patch ? 'id_type' then
    v_id_type := nullif(p_patch ->> 'id_type', '');
    if v_id_type is not null and v_id_type not in ('passport', 'drivers_license', 'national_id', 'other') then
      raise exception using errcode = '22023', message = 'id type not recognised';
    end if;
  end if;
  v_on_file := v_row.id_on_file;
  if p_patch ? 'id_on_file' then
    -- A guest can say "I sent my ID", never "remove it".
    if p_patch ->> 'id_on_file' is distinct from 'true' then raise exception using errcode = '22023', message = 'id_on_file can only be set to true'; end if;
    v_on_file := true;
  end if;

  if v_contact is not distinct from v_row.contact_number and v_id_type is not distinct from v_row.id_type and v_on_file is not distinct from v_row.id_on_file then
    return jsonb_build_object('ok', true, 'unchanged', true, 'guestId', r.guest_id);
  end if;

  select jsonb_agg(k) into v_keys from jsonb_object_keys(p_patch) k;
  update public.guest_profile_details set
    contact_number = v_contact, id_type = v_id_type, id_on_file = v_on_file,
    contact_provenance = contact_provenance || jsonb_build_object('last_change',
      jsonb_build_object('via', 'guest_form', 'ref', r.ref, 'at', now(), 'fields', v_keys)),
    updated_by = null, updated_at = now(), version = version + 1
  where guest_id = r.guest_id returning * into v_row;
  insert into public.guest_profile_history(guest_id, changed_by, before_state, after_state, reason)
  values (r.guest_id, null, v_before, to_jsonb(v_row), 'guest form ' || r.ref);
  return jsonb_build_object('ok', true, 'unchanged', false, 'guestId', r.guest_id, 'version', v_row.version);
end $$;

create or replace function public.intake_save_guest_companion_v1(
  p_token_hash text, p_name text, p_id_type text, p_id_photo_path text, p_contact text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  r record; v_name text; v_contact text; v_path text; v_before jsonb;
  v_row public.guest_companions%rowtype;
  n_contact text; n_type text; n_path text;
begin
  select * into r from public.intake_resolve_v1(p_token_hash);
  if not found then return jsonb_build_object('ok', false, 'reason', 'invalid_token'); end if;
  if r.guest_id is null then return jsonb_build_object('ok', false, 'reason', 'no_guest_record'); end if;
  v_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  if char_length(v_name) not between 2 and 120 or v_name ~ '[0-9]{4}' then
    raise exception using errcode = '22023', message = 'name invalid';
  end if;
  if p_id_type is not null and p_id_type not in ('passport', 'drivers_license', 'national_id', 'other') then
    raise exception using errcode = '22023', message = 'id type not recognised';
  end if;
  v_contact := nullif(regexp_replace(btrim(coalesce(p_contact, '')), '[ -]', '', 'g'), '');
  if v_contact is not null and v_contact !~ '^[+]?[0-9]{7,15}$' then
    raise exception using errcode = '22023', message = 'contact number looks invalid';
  end if;
  v_path := nullif(btrim(coalesce(p_id_photo_path, '')), '');

  select * into v_row from public.guest_companions
   where guest_id = r.guest_id and lower(regexp_replace(btrim(name), '\s+', ' ', 'g')) = lower(v_name)
   order by created_at limit 1 for update;

  if v_row.id is null then
    if v_path is not null then
      raise exception using errcode = '22023', message = 'create the person first, then attach the photo';
    end if;
    if (select count(*) from public.guest_companions where guest_id = r.guest_id) >= 12 then
      raise exception using errcode = '22023', message = 'too many people on this stay';
    end if;
    insert into public.guest_companions(guest_id, property_id, name, contact_number, id_type, created_by, updated_by)
    values (r.guest_id, r.property_id, v_name, v_contact, p_id_type, null, null)
    returning * into v_row;
    insert into public.guest_companion_history(companion_id, guest_id, changed_by, before_state, after_state, reason)
    values (v_row.id, r.guest_id, null, null, to_jsonb(v_row), 'guest form ' || r.ref);
    return jsonb_build_object('ok', true, 'created', true, 'unchanged', false, 'id', v_row.id, 'version', v_row.version);
  end if;

  if v_path is not null then
    if v_path !~ ('^' || v_row.id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|png|webp)$') then
      raise exception using errcode = '22023', message = 'photo path is not this person''s';
    end if;
    if not exists (select 1 from storage.objects where bucket_id = 'guest-id-photos' and name = v_path) then
      raise exception using errcode = 'P0002', message = 'photo object not found in guest-id-photos';
    end if;
    -- 12 ID photos a day per booking, counted from the history this RPC writes; the Edge Function checks first, this is the backstop.
    if public.intake_uploads_today_v1(r.guest_id, r.ref) >= 12 then
      return jsonb_build_object('ok', false, 'reason', 'rate_limited');
    end if;
  end if;
  v_before := to_jsonb(v_row);
  n_contact := coalesce(v_contact, v_row.contact_number);
  n_type := coalesce(p_id_type, v_row.id_type);
  n_path := coalesce(v_path, v_row.id_photo_path);
  if n_contact is not distinct from v_row.contact_number and n_type is not distinct from v_row.id_type and n_path is not distinct from v_row.id_photo_path then
    return jsonb_build_object('ok', true, 'created', false, 'unchanged', true, 'id', v_row.id, 'version', v_row.version);
  end if;
  update public.guest_companions set
    contact_number = n_contact, id_type = n_type, id_photo_path = n_path,
    updated_by = null, updated_at = now(), version = version + 1
  where id = v_row.id returning * into v_row;
  insert into public.guest_companion_history(companion_id, guest_id, changed_by, before_state, after_state, reason)
  values (v_row.id, r.guest_id, null, v_before, to_jsonb(v_row), 'guest form ' || r.ref);
  return jsonb_build_object('ok', true, 'created', false, 'unchanged', false, 'id', v_row.id, 'version', v_row.version);
end $$;

revoke all on function public.intake_resolve_v1(text) from public, anon, authenticated, service_role;
revoke all on function public.intake_uploads_today_v1(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.intake_guest_context_v1(text) from public, anon, authenticated;
revoke all on function public.intake_save_guest_details_v1(text, jsonb) from public, anon, authenticated;
revoke all on function public.intake_save_guest_companion_v1(text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.intake_guest_context_v1(text) to service_role;
grant execute on function public.intake_save_guest_details_v1(text, jsonb) to service_role;
grant execute on function public.intake_save_guest_companion_v1(text, text, text, text, text) to service_role;

comment on function public.intake_resolve_v1(text) is 'SPEC-42 s4b: token hash -> the one confirmed direct booking it opens (not revoked, expired, cancelled or past check-out). Internal.';
comment on function public.intake_uploads_today_v1(uuid, text) is 'SPEC-42 s4b: ID photos the guest form linked for this booking in the last 24 h. Internal.';
comment on function public.intake_guest_context_v1(text) is 'SPEC-42 s4b: what the Before you arrive section may show for one token. Null for any invalid token. Never a contact, ID number or storage path. service_role only.';
comment on function public.intake_save_guest_details_v1(text, jsonb) is 'SPEC-42 s4b: guest-form write of contact_number, id_on_file (true only) and id_type. Provenance guest form <ref>. service_role only.';
comment on function public.intake_save_guest_companion_v1(text, text, text, text, text) is 'SPEC-42 s4b: guest-form create-or-update of a person by name; photo path must be <companion id>/<uuid>.(jpg|png|webp) and exist in guest-id-photos; 12 photos a day. service_role only.';

commit;
