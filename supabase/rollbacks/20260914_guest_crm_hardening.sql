-- Compensating rollback for 20260914260000_guest_crm_hardening.sql.
-- Restores the four function bodies exactly as deployed before the release
-- (admin_audit_feed_v1 from 20260914250000, preview/merge from 20260913100000,
-- save_guest_profile_v1 from 20260914220000), clears the bucket limits and puts
-- the three storage policies back to their capability-only form. No data changed
-- either way. Prefer a forward fix: this widens guest/ID access again.
begin;

create or replace function public.admin_audit_feed_v1(p_property_id uuid, p_limit integer default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_fin boolean; v_staff boolean; v_rows jsonb;
begin
  perform public.admin_require('read_operations', p_property_id);
  v_fin := public.current_staff_authorized('read_finance', p_property_id);
  v_staff := public.current_staff_authorized('manage_staff', p_property_id);
  with feed as (
    select a.id, a.created_at at, 'admin' src, a.entity_table, a.entity_id::text entity_id, a.action, a.actor_user_id actor, a.reason, a.before_state before_state, a.after_state after_state,
           (a.action <> 'undo' and not exists (select 1 from public.admin_audit_log u where u.undo_of = a.id)) undoable, a.undo_of
    from public.admin_audit_log a where a.property_id = p_property_id and (v_fin or a.entity_table <> 'transactions')
    union all
    select s.id, s.created_at, 'staff', 'staff_access_profiles', s.target_user_id::text, s.action, s.actor_user_id, s.reason, s.before_state, s.after_state, false, null
    from public.staff_access_audit s where v_staff
    union all
    select e.id, e.created_at, 'booking', 'booking_inquiries', e.booking_id::text, e.event_type, e.actor_user_id, e.reason, e.before_state, e.after_state, false, null
    from public.booking_lifecycle_events e where e.property_id = p_property_id
    union all
    select m.id, m.created_at, 'inventory', 'inventory_items', m.item_id::text, m.kind, m.actor_user_id, m.reason, jsonb_build_object('quantity', m.quantity_before), jsonb_build_object('quantity', m.quantity_after), false, null
    from public.inventory_stock_movements m where m.property_id = p_property_id
    union all
    select j.id, j.posted_at, 'journal', 'acct_journals', j.id::text, case when j.reversal_of is not null then 'reversal' else 'posted' end, j.posted_by, coalesce(j.reversal_reason, j.description), null, jsonb_build_object('journalNo', j.journal_no, 'entryDate', j.entry_date, 'status', j.status), false, null
    from public.acct_journals j where j.property_id = p_property_id and v_fin
    union all
    select r.id, r.reviewed_at, 'readiness', 'cleaning_sessions', r.cleaning_session_id::text, 'readiness_' || r.outcome, r.reviewer_user_id, r.reason, null, jsonb_build_object('forCheckin', r.for_checkin_date), false, null
    from public.readiness_reviews r where r.property_id = p_property_id
    union all
    select v.id, v.reviewed_at, 'evidence', 'cleaning_verification_evidence', v.evidence_id::text, 'evidence_' || v.outcome, v.reviewer_user_id, v.reason, null, null, false, null
    from public.cleaning_verification_reviews v where v.property_id = p_property_id
    union all
    select h.id, h.changed_at, 'guest', 'guests', h.guest_id::text, 'profile_update', h.changed_by, h.reason, h.before_state, h.after_state, false, null
    from public.guest_profile_history h join public.guests g on g.id = h.guest_id where g.property_id = p_property_id
    union all
    select sd.id, sd.changed_at, 'staff_details', 'staff_details', sd.user_id::text, 'staff_details_update', sd.changed_by, sd.reason, sd.before_state, sd.after_state, false, null
    from public.staff_details_history sd where v_staff
    union all
    select ch.id, ch.changed_at, 'companion', 'guest_companions', ch.companion_id::text, 'companion_update', ch.changed_by, ch.reason, ch.before_state, ch.after_state, false, null
    from public.guest_companion_history ch join public.guests g2 on g2.id = ch.guest_id where g2.property_id = p_property_id
  )
  select coalesce(jsonb_agg(to_jsonb(f) order by f.at desc), '[]'::jsonb) into v_rows
  from (select * from feed order by at desc limit least(greatest(coalesce(p_limit, 200), 1), 1000)) f;
  return jsonb_build_object('rows', v_rows, 'financeVisible', v_fin, 'staffVisible', v_staff);
end;
$$;

create or replace function public.preview_guest_merge_v1(p_surviving uuid, p_merged uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.guests where id = p_surviving;
  if v_prop is null then raise exception using errcode = 'P0002', message = 'guest not found'; end if;
  perform public.admin_require('manage_operations', v_prop);
  if p_surviving = p_merged then raise exception using errcode = '22023', message = 'cannot merge a guest into itself'; end if;
  return jsonb_build_object(
    'surviving', (select to_jsonb(g) - 'notes' from public.guests g where g.id = p_surviving),
    'merged', (select to_jsonb(g) - 'notes' from public.guests g where g.id = p_merged),
    'reservations', (select count(*) from public.airbnb_reservations where guest_id = p_merged),
    'inquiries', (select count(*) from public.booking_inquiries where guest_id = p_merged),
    'followUps', (select count(*) from public.follow_up_tasks where guest_id = p_merged),
    'conversations', (select count(*) from public.guest_conversations where guest_id = p_merged),
    'sharedContact', (select (a.phone is not null and a.phone = b.phone) or (a.email is not null and lower(a.email) = lower(b.email)) from public.guests a, public.guests b where a.id = p_surviving and b.id = p_merged),
    'nameOnly', (select not ((a.phone is not null and a.phone = b.phone) or (a.email is not null and lower(a.email) = lower(b.email))) and lower(a.name) = lower(b.name) from public.guests a, public.guests b where a.id = p_surviving and b.id = p_merged)
  );
end;
$$;

create or replace function public.merge_guests_v1(p_surviving uuid, p_merged uuid, p_reason text, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_prop uuid; v_preview jsonb; v_existing public.guest_merge_history%rowtype;
begin
  select property_id into v_prop from public.guests where id = p_surviving;
  if v_prop is null then raise exception using errcode = 'P0002', message = 'guest not found'; end if;
  perform public.admin_require('manage_operations', v_prop);
  if p_reason is null or char_length(btrim(p_reason)) < 3 then raise exception using errcode = '22023', message = 'merge reason required'; end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key required'; end if;
  select * into v_existing from public.guest_merge_history where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('ok', true, 'replayed', true, 'id', v_existing.id); end if;
  v_preview := public.preview_guest_merge_v1(p_surviving, p_merged);
  if coalesce((v_preview->>'sharedContact')::boolean, false) = false then
    raise exception using errcode = '22023', message = 'no verified shared contact; name-only similarity cannot be merged';
  end if;
  update public.airbnb_reservations set guest_id = p_surviving where guest_id = p_merged;
  update public.booking_inquiries set guest_id = p_surviving where guest_id = p_merged;
  update public.follow_up_tasks set guest_id = p_surviving where guest_id = p_merged;
  update public.guest_conversations set guest_id = p_surviving where guest_id = p_merged;
  update public.guests set is_active = false, notes = coalesce(notes, '') || E'\nMerged into ' || p_surviving::text || ' on ' || now()::date::text where id = p_merged;
  insert into public.guest_merge_history(property_id, surviving_guest_id, merged_guest_id, preview, reason, merged_by, idempotency_key)
  values (v_prop, p_surviving, p_merged, v_preview, btrim(p_reason), auth.uid(), p_idempotency_key) returning * into v_existing;
  perform public.refresh_guest_stats(p_surviving);
  return jsonb_build_object('ok', true, 'id', v_existing.id, 'preview', v_preview);
end;
$$;

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

update storage.buckets set file_size_limit = null, allowed_mime_types = null where id = 'guest-id-photos';
drop policy if exists "guest id photos manage read" on storage.objects;
drop policy if exists "guest id photos manage write" on storage.objects;
drop policy if exists "guest id photos manage delete" on storage.objects;
create policy "guest id photos manage read" on storage.objects for select to authenticated
  using (bucket_id = 'guest-id-photos' and public.current_staff_authorized('manage_operations'));
create policy "guest id photos manage write" on storage.objects for insert to authenticated
  with check (bucket_id = 'guest-id-photos' and public.current_staff_authorized('manage_operations'));
create policy "guest id photos manage delete" on storage.objects for delete to authenticated
  using (bucket_id = 'guest-id-photos' and public.current_staff_authorized('manage_operations'));

-- Grants are restated so a fresh (no-ACL) restore rehearses the same surface production has.
revoke all on function public.admin_audit_feed_v1(uuid, integer) from public, anon, service_role;
grant execute on function public.admin_audit_feed_v1(uuid, integer) to authenticated;
revoke all on function public.preview_guest_merge_v1(uuid, uuid) from public, anon, service_role;
grant execute on function public.preview_guest_merge_v1(uuid, uuid) to authenticated;
revoke all on function public.merge_guests_v1(uuid, uuid, text, text) from public, anon, service_role;
grant execute on function public.merge_guests_v1(uuid, uuid, text, text) to authenticated;
revoke all on function public.save_guest_profile_v1(uuid, jsonb, integer, text) from public, anon, service_role;
grant execute on function public.save_guest_profile_v1(uuid, jsonb, integer, text) to authenticated;

commit;
