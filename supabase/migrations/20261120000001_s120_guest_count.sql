-- 20261120000001_s120_guest_count.sql
-- Session 120, lane SC: release s120_guest_count_20261120. Number of guests per stay (contract docs/s120/CONTRACT-guest-count.md, D-373).
-- The stay holds the number of guests. The booked number comes from the Airbnb reservation (airbnb_reservations.guest_count, read through calendar_events.linked_reservation_id,
-- never written: airbnb-email-sync upserts over it); a staff correction (stay_staying.guest_count) overrides it. Range 1 to 3 (stay-site/booking-terms.html:36).
-- Display order everywhere: guest_count (correction), then booked_guests, then the old fallback of 1 + companions on file.
--
-- WHAT THIS ADDS (all additive; no existing signature, grant or result key changes; it does NOT depend on the usage-learning release)
--   stay_staying.guest_count   nullable integer, check 1..3. A row may hold a count with no names: stay_staying_names_source (names null iff source null) still holds.
--   stay_staying_history.action also allows 'count'.
--   set_stay_guest_count_v1(property, uid, count, expected_version, reason, idempotency_key)   authenticated, gate manage_operations (owner/admin), else 42501.
--       Same advisory lock, optimistic version lock (0 = no row yet, else 40001) and idempotent replay as set_stay_staying_v1. 22023 for a count outside 1..3, a blank uid,
--       a missing or over-long key, or a key that was already used for another count or another kind of write. Unknown stay (not a confirmed calendar event): P0002.
--       Success { ok, guest_count, version }; a replay returns the same shape plus replay true.
--   staff_guest_stay_v1(property, guest_id)   authenticated, gate manage_operations, else 42501. The guest's current stay (checked in, not yet out), otherwise the next one,
--       otherwise SQL null. Past stays are never returned. The guest of a stay is resolved with staff_stay_guest_id_v1 exactly as staff_home_v1 does.
--       { uid, checkin_date, checkout_date, booked_guests, guest_count, version } with version 0 when the stay has no stay_staying row.
--   stay_guest_count_json_v1(property, uid)   internal helper, no grants: { guest_count, booked_guests } (integers or null), the two keys staff_home_v1 adds to `staying`.
--   staff_home_v1: current_guest.staying and next_guest.staying gain guest_count and booked_guests (version is already there). Cut by patching the LIVE body (each anchor must
--       occur exactly 2 times, one per slot) after an md5 guard: the s119 body, md5 18f5723d01ce20788d6fb2f114129ed8 (read live 2026-11-18). The diff is the two
--       `|| public.stay_guest_count_json_v1(p_property_id, s.uid)` additions and the two `, 'guest_id', s.guest_id` additions inside the v_priv arrival_ready object, and nothing else;
--       the body after the patch must be md5 b85530233f55696b136e4a49d1ed255c (s119 body rebuilt from the s91 body plus the s119 patch, which reproduced 18f5723d..., then this patch).
--       Both counts are integers: a cleaner reads no more personal data than before.
--       current_guest and next_guest also gain `guest_id` for owner and admin only (v_priv, the same flag as arrival_ready: staff_access_profiles role owner/admin, not disabled):
--       the Staff app's Guests tile links to #guests/<guest_id>/stay and production sent no such key. Cleaner, laundry and every other role get no guest_id key at all.
--
-- GRANTS (ML-21: the end state is restated for every function this file creates or replaces): the two RPCs go to `authenticated` only (the s119 pattern of set_stay_staying_v1:
-- revoke from public, anon, service_role; grant to authenticated), the helper to nobody, staff_home_v1 back to authenticated and service_role. RLS stays on, stay_staying and
-- stay_staying_history keep no grant to any API role. Every gate is an explicit check at the top of the function, never an unreferenced lateral.
--
-- GUARD (55000, nothing changes): staff_home_v1 must be the live s119 body. Rollback: supabase/rollbacks/20261120_s120_guest_count.sql (DATA LOSS by design: every typed guest count).
--
-- FORWARD CHECKS (also in supabase/releases/s120_guest_count_20261120.release.json):
--   select md5(replace(prosrc, chr(13), '')) = 'b85530233f55696b136e4a49d1ed255c' from pg_proc where oid = 'public.staff_home_v1(uuid)'::regprocedure;
--   select count(*) = 1 from information_schema.columns where table_schema = 'public' and table_name = 'stay_staying' and column_name = 'guest_count';
--   select pg_get_constraintdef(oid) like '%count%' from pg_constraint where conrelid = 'public.stay_staying_history'::regclass and contype = 'c' and conname = 'stay_staying_history_action_check';

begin;

do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.staff_home_v1(uuid)');
  if v_got is distinct from '18f5723d01ce20788d6fb2f114129ed8' then
    raise exception 's120 guest count: staff_home_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
end $$;

-- 1. columns ---------------------------------------------------------------------------------------------------------------------------------
alter table public.stay_staying add column if not exists guest_count integer constraint stay_staying_guest_count_range check (guest_count between 1 and 3);
comment on column public.stay_staying.guest_count is 'S120: the number of guests, 1 to 3, as corrected by an owner or admin. NULL = nobody corrected it (the booked number applies). A row may hold a count with no names.';

-- history action: the existing check (set, accept, reject, suggest) is found by what it checks, replaced by one that also allows count
do $$
declare v_con text;
begin
  for v_con in select c.conname from pg_constraint c
                where c.conrelid = 'public.stay_staying_history'::regclass and c.contype = 'c' and pg_get_constraintdef(c.oid) like '%suggest%' loop
    execute format('alter table public.stay_staying_history drop constraint %I', v_con);
  end loop;
  alter table public.stay_staying_history add constraint stay_staying_history_action_check check (action in ('set', 'accept', 'reject', 'suggest', 'count'));
end $$;

-- 2. owner/admin corrects the number of guests -------------------------------------------------------------------------------------------------
create or replace function public.set_stay_guest_count_v1(p_property uuid, p_uid text, p_count integer, p_expected_version integer, p_reason text, p_idempotency_key text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_key text := btrim(p_idempotency_key);
  v_row public.stay_staying%rowtype;
  v_before jsonb;
  v_hist public.stay_staying_history%rowtype;
begin
  if auth.uid() is null or p_property is null or not public.current_staff_authorized('manage_operations', p_property) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_count is null or p_count < 1 or p_count > 3 then raise exception 'count_invalid' using errcode = '22023'; end if;
  if p_uid is null or btrim(p_uid) = '' then raise exception 'uid_required' using errcode = '22023'; end if;
  if v_key is null or v_key = '' or char_length(v_key) > 100 then raise exception 'idempotency_key_invalid' using errcode = '22023'; end if;
  if p_reason is not null and char_length(p_reason) > 500 then raise exception 'reason_too_long' using errcode = '22023'; end if;
  if not exists (select 1 from public.calendar_events e where e.property_id = p_property and e.uid = p_uid and e.status = 'confirmed') then
    raise exception 'stay_not_found' using errcode = 'P0002';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_property::text || '/' || p_uid, 0));

  select * into v_hist from public.stay_staying_history h where h.property_id = p_property and h.stay_uid = p_uid and h.idempotency_key = v_key;
  if found then
    -- a key belongs to one write: the same key with another count, or one first used for names, is a mistake, never a replay
    if v_hist.action is distinct from 'count' or (v_hist.after_state ->> 'guest_count')::integer is distinct from p_count then
      raise exception 'idempotency_key_reused' using errcode = '22023';
    end if;
    return jsonb_build_object('ok', true, 'guest_count', (v_hist.after_state ->> 'guest_count')::integer, 'version', (v_hist.after_state ->> 'version')::integer, 'replay', true);
  end if;

  select * into v_row from public.stay_staying s where s.property_id = p_property and s.stay_uid = p_uid for update;
  if coalesce(p_expected_version, -1) <> coalesce(v_row.version, 0) then
    raise exception 'stale version: the guest count changed since it was loaded' using errcode = '40001';
  end if;

  if v_row.stay_uid is null then
    v_before := null;
    insert into public.stay_staying(property_id, stay_uid, guest_count, version, updated_by)
    values (p_property, p_uid, p_count, 1, auth.uid())
    returning * into v_row;
  else
    v_before := to_jsonb(v_row);
    update public.stay_staying set guest_count = p_count, version = version + 1, updated_by = auth.uid(), updated_at = now()
    where property_id = p_property and stay_uid = p_uid
    returning * into v_row;
  end if;
  insert into public.stay_staying_history(property_id, stay_uid, action, before_state, after_state, changed_by, reason, idempotency_key)
  values (p_property, p_uid, 'count', v_before, to_jsonb(v_row), auth.uid(), p_reason, v_key);
  return jsonb_build_object('ok', true, 'guest_count', v_row.guest_count, 'version', v_row.version);
end $$;
revoke all on function public.set_stay_guest_count_v1(uuid, text, integer, integer, text, text) from public, anon, service_role;
grant execute on function public.set_stay_guest_count_v1(uuid, text, integer, integer, text, text) to authenticated;

-- 3. the guest's current or next stay, for the admin guest page -------------------------------------------------------------------------------------
create or replace function public.staff_guest_stay_v1(p_property uuid, p_guest_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_e public.calendar_events%rowtype;
  v_s public.stay_staying%rowtype;
  v_booked integer;
begin
  if auth.uid() is null or p_property is null or not public.current_staff_authorized('manage_operations', p_property) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_guest_id is null then return null; end if;

  -- current first (checked in, not yet out; the latest check-in if two overlap), else the nearest arrival; a stay that has ended is never a candidate
  select e.* into v_e
    from public.calendar_events e
   where e.property_id = p_property and e.status = 'confirmed' and e.checkout_date > v_today
     and public.staff_stay_guest_id_v1(p_property, e.uid, e.linked_reservation_id, e.checkin_date, e.checkout_date) = p_guest_id
   order by (e.checkin_date > v_today), abs(e.checkin_date - v_today), e.uid
   limit 1;
  if not found then return null; end if;

  select r.guest_count into v_booked from public.airbnb_reservations r where r.id = v_e.linked_reservation_id;
  select * into v_s from public.stay_staying s where s.property_id = p_property and s.stay_uid = v_e.uid;
  return jsonb_build_object('uid', v_e.uid, 'checkin_date', v_e.checkin_date, 'checkout_date', v_e.checkout_date,
                            'booked_guests', v_booked, 'guest_count', v_s.guest_count, 'version', coalesce(v_s.version, 0));
end $$;
revoke all on function public.staff_guest_stay_v1(uuid, uuid) from public, anon, service_role;
grant execute on function public.staff_guest_stay_v1(uuid, uuid) to authenticated;

-- 4. staff_home_v1: guest_count and booked_guests on the current and next guest's `staying` ------------------------------------------------------------
-- Not granted to any API role: staff_home_v1 (security definer, same owner) is the only caller. Two integers (or null), no free text, so no redaction is needed.
create or replace function public.stay_guest_count_json_v1(p_property uuid, p_uid text)
returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'guest_count', (select s.guest_count from public.stay_staying s where s.property_id = p_property and s.stay_uid = p_uid),
    'booked_guests', (select r.guest_count from public.calendar_events e join public.airbnb_reservations r on r.id = e.linked_reservation_id
                       where e.property_id = p_property and e.uid = p_uid));
$$;
revoke all on function public.stay_guest_count_json_v1(uuid, text) from public, anon, authenticated, service_role;

do $$
declare v_def text; v_a text; v_to text; v_got text; v_g text; v_g2 text;
begin
  v_def := replace(pg_get_functiondef(to_regprocedure('public.staff_home_v1(uuid)')), chr(13), '');
  v_a := 'jsonb_build_object(''staying'', public.stay_staying_json_v1(p_property_id, s.uid))';
  if (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a) <> 2 then
    raise exception 's120 guest count: the staying anchor in staff_home_v1 was not found exactly twice; re-cut from the live body' using errcode = '55000';
  end if;
  v_to := 'jsonb_build_object(''staying'', public.stay_staying_json_v1(p_property_id, s.uid) || public.stay_guest_count_json_v1(p_property_id, s.uid))';
  v_def := replace(v_def, v_a, v_to);
  -- guest_id: owner and admin only, inside the existing v_priv object next to arrival_ready (one per slot)
  v_g := 'jsonb_build_object(''arrival_ready'', public.s_arrival_ready_v1(s.guest_id, s.source))';
  if (length(v_def) - length(replace(v_def, v_g, ''))) / length(v_g) <> 2 then
    raise exception 's120 guest count: the arrival_ready anchor in staff_home_v1 was not found exactly twice; re-cut from the live body' using errcode = '55000';
  end if;
  v_g2 := 'jsonb_build_object(''arrival_ready'', public.s_arrival_ready_v1(s.guest_id, s.source), ''guest_id'', s.guest_id)';
  execute replace(v_def, v_g, v_g2);
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.staff_home_v1(uuid)');
  if v_got is distinct from 'b85530233f55696b136e4a49d1ed255c' then
    raise exception 's120 guest count: staff_home_v1 after the patch has md5 %, expected b85530233f55696b136e4a49d1ed255c', v_got using errcode = '55000';
  end if;
end $$;

-- 5. grants: state the end state ------------------------------------------------------------------------------------------------------------------
revoke all on function public.staff_home_v1(uuid) from public, anon;
grant execute on function public.staff_home_v1(uuid) to authenticated, service_role;

comment on function public.set_stay_guest_count_v1(uuid, text, integer, integer, text, text) is 'S120: owner/admin (manage_operations) set the number of guests of a stay, 1 to 3. Optimistic lock on version (0 = no row yet, else 40001); idempotency key required (same key + same count = replay). 22023 outside 1..3.';
comment on function public.staff_guest_stay_v1(uuid, uuid) is 'S120: owner/admin read the guest''s current stay, else the next one, else null: { uid, checkin_date, checkout_date, booked_guests, guest_count, version }. Past stays are never returned.';

commit;
