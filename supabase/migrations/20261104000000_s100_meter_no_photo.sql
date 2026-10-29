-- 20261104000000_s100_meter_no_photo.sql
-- Cascade Hideaway - s100 (D-352): "No meter photo was taken".
--
-- Why. The checklist offered to skip the meter photos only when an uploaded photo looked wrong (2026-09-13), so a cleaner with NO photo had no way through:
-- she attached other photos, vision called the reading a mismatch and the next turnover report was refused (meter_followup_unresolved). The never-two-in-a-row
-- rule also read the latest session by cleaned_at (filing order), which is wrong when reports are filed late.
--
-- What this adds (the contract is docs/s100/CONTRACT-meter-no-photo.md):
--  (1) public.meter_skip_exceptions: an admin exception for a pair of stays (RLS on, no policy, service_role only).
--  (2) public.can_skip_meter_photos_v2(property, checkout_date): never two stays in a row, judged by STAY order (the confirmed calendar stays either side by
--      check-out date), lifted only when BOTH stays hold an exception. A null date falls back to the v1 rule. can_skip_meter_photos (v1) is untouched.
--  (3) public.report_no_meter_photo_v1(session, note): the cleaner (or an admin) declares there is no photo; the reading is flagged estimate_pending.
--  (4) public.meter_no_photo_notice_v1(session): one follow-up task for the admins (idempotent per session).
--  (5) public.meter_settle_estimates_v1(property): when the next stay has a photo-verified reading, keep the typed numbers if they sit in order between the
--      verified readings either side, else replace the whole gap by a per-night share of the usage between them. Cron meter-settle-estimates every 30 minutes.
--  (5b) public.review_meter_reading_v1 (admin flag review) accepts the three new flags: same body, longer whitelist (md5-guarded).
--  (6) two internal helpers, no grants to anyone: s_meter_skip_check_v1 (the shared rule) and s_meter_nights_v1 (nights of a stay).
--
-- Additive only: one table, six new functions and one replaced (review_meter_reading_v1), one cron job. No column is added, no value is rejected (meter_readings.meter_flag has no CHECK and gets none:
-- new values estimate_pending, typed_accepted, estimated). Old Staff app + new SQL is safe: the v1 functions are not touched.
-- Grants are restated in full for every function (ML-21): the rehearsal restore is --no-acl, production has default privileges.

begin;

-- 1. exceptions ------------------------------------------------------------------------------------------------------------------------------
create table if not exists public.meter_skip_exceptions (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references public.properties(id),
  checkout_date date not null,
  note          text not null check (char_length(note) between 4 and 300),
  created_at    timestamptz not null default now(),
  unique (property_id, checkout_date)
);
alter table public.meter_skip_exceptions enable row level security;
revoke all on table public.meter_skip_exceptions from public, anon, authenticated, service_role;
grant select, insert, update, delete on table public.meter_skip_exceptions to service_role;
comment on table public.meter_skip_exceptions is
  'D-352: an admin exception for the stay that checked out on this date. The never-two-stays-in-a-row rule is lifted between two neighbouring stays only when BOTH hold a row here. RLS on, no policy: service_role only.';

-- 2. helpers (internal: no grants to anyone) ---------------------------------------------------------------------------------------------------
-- Nights of a stay: the session's nights_stayed, else the confirmed calendar stay that checks out on the session's date, else 1.
create or replace function public.s_meter_nights_v1(p_session_id uuid)
returns integer language sql stable security definer set search_path to '' as $function$
  select coalesce(
    (select nullif(cs.nights_stayed, 0)
       from public.cleaning_sessions cs where cs.id = p_session_id),
    (select max(ce.nights)
       from public.cleaning_sessions cs
       join public.calendar_events ce on ce.property_id = cs.property_id and ce.status = 'confirmed' and ce.checkout_date = cs.checkout_date
      where cs.id = p_session_id and ce.nights > 0),
    1);
$function$;

-- The never-two-in-a-row rule, stay order. p_ignore_session lets a session ask about itself without counting itself.
-- Neighbours = the confirmed calendar stays that check out immediately before and after p_checkout_date.
-- A neighbour whose turnover/deep_clean session declared no meter photos refuses, unless meter_skip_exceptions holds BOTH dates.
-- A null date falls back to the v1 rule: the latest turnover/deep_clean session by cleaned_at.
create or replace function public.s_meter_skip_check_v1(p_property_id uuid, p_checkout_date date, p_ignore_session uuid)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_prev date;
  v_next date;
  v_n    date;
  v_skipped boolean;
  v_last_co date;
begin
  if p_checkout_date is null then
    select cs.meter_photos_skipped, cs.checkout_date into v_skipped, v_last_co
      from public.cleaning_sessions cs
     where cs.property_id = p_property_id
       and cs.cleaning_type in ('turnover', 'deep_clean')
       and (p_ignore_session is null or cs.id <> p_ignore_session)
     order by cs.cleaned_at desc nulls last
     limit 1;
    if coalesce(v_skipped, false) then
      return jsonb_build_object('allowed', false, 'reason', 'neighbour_skipped', 'neighbour_checkout', v_last_co);
    end if;
    return jsonb_build_object('allowed', true, 'reason', null, 'neighbour_checkout', null);
  end if;

  select max(ce.checkout_date) into v_prev from public.calendar_events ce
   where ce.property_id = p_property_id and ce.status = 'confirmed' and ce.checkout_date < p_checkout_date;
  select min(ce.checkout_date) into v_next from public.calendar_events ce
   where ce.property_id = p_property_id and ce.status = 'confirmed' and ce.checkout_date > p_checkout_date;

  foreach v_n in array array[v_prev, v_next] loop
    continue when v_n is null;
    if exists (select 1 from public.cleaning_sessions cs
                where cs.property_id = p_property_id and cs.cleaning_type in ('turnover', 'deep_clean')
                  and cs.checkout_date = v_n and cs.meter_photos_skipped
                  and (p_ignore_session is null or cs.id <> p_ignore_session))
       and not (exists (select 1 from public.meter_skip_exceptions x where x.property_id = p_property_id and x.checkout_date = p_checkout_date)
            and exists (select 1 from public.meter_skip_exceptions x where x.property_id = p_property_id and x.checkout_date = v_n)) then
      return jsonb_build_object('allowed', false, 'reason', 'neighbour_skipped', 'neighbour_checkout', v_n);
    end if;
  end loop;
  return jsonb_build_object('allowed', true, 'reason', null, 'neighbour_checkout', null);
end;
$function$;

-- 3. may this stay skip its meter photos? ---------------------------------------------------------------------------------------------------
create or replace function public.can_skip_meter_photos_v2(p_property_id uuid, p_checkout_date date)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.current_staff_authorized('read_operations', p_property_id)) then
    raise exception 'not authorized to read operations for this property' using errcode = '42501';
  end if;
  return public.s_meter_skip_check_v1(p_property_id, p_checkout_date, null);
end;
$function$;

-- 4. the admin notice ----------------------------------------------------------------------------------------------------------------------------
create or replace function public.meter_no_photo_notice_v1(p_session_id uuid)
returns uuid language plpgsql volatile security definer set search_path to '' as $function$
declare
  cs public.cleaning_sessions%rowtype;
begin
  select * into cs from public.cleaning_sessions where id = p_session_id;
  if not found or cs.property_id is null then return null; end if;
  return public.system_task_open_v1(
    cs.property_id, 'meter_no_photo', cs.id::text,
    'No meter photo: ' || coalesce(nullif(btrim(cs.last_guest_name), ''), 'guest')
      || ' (checked out ' || coalesce(to_char(cs.checkout_date, 'FMDD Mon'), 'date unknown') || ')',
    coalesce(nullif(btrim(cs.cleaner_name), ''), 'The cleaner') || ' said: ' || coalesce(cs.meter_photo_skip_note, 'no reason given')
      || '. The typed reading is kept until the next verified reading, then checked and averaged if it does not fit.',
    'normal');
end;
$function$;

-- 5. the cleaner's report --------------------------------------------------------------------------------------------------------------------------
-- Caller: the session's own submitter, or an admin/owner (manage_operations). Anyone else is refused with 42501.
create or replace function public.report_no_meter_photo_v1(p_session_id uuid, p_note text)
returns jsonb language plpgsql volatile security definer set search_path to '' as $function$
declare
  cs     public.cleaning_sessions%rowtype;
  v_note text := btrim(coalesce(p_note, ''));
  v_chk  jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into cs from public.cleaning_sessions where id = p_session_id for update;
  if not found or cs.cleaning_type not in ('turnover', 'deep_clean') then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', 'That report was not found, or it does not need meter photos.');
  end if;

  if not (coalesce(cs.submitted_by_user_id = auth.uid(), false) and public.current_staff_authorized('submit_cleaning', cs.property_id))
     and not public.current_staff_authorized('manage_operations', cs.property_id) then
    raise exception 'not authorized to report on this cleaning' using errcode = '42501';
  end if;

  if char_length(v_note) not between 4 and 300 then
    return jsonb_build_object('ok', false, 'reason', 'note_required', 'message', 'Please say in a few words why there is no meter photo.');
  end if;

  -- A second tap changes nothing.
  if cs.meter_photos_skipped then
    return jsonb_build_object('ok', true);
  end if;

  v_chk := public.s_meter_skip_check_v1(cs.property_id, cs.checkout_date, cs.id);
  if not (v_chk ->> 'allowed')::boolean then
    return jsonb_build_object('ok', false, 'reason', 'neighbour_skipped',
      'message', 'The stay next to this one also has no meter photo, so this one needs them. If you truly cannot, message Lloyd.');
  end if;

  update public.cleaning_sessions
     set meter_photos_skipped = true, meter_photo_skip_note = v_note
   where id = cs.id;

  update public.meter_readings mr
     set meter_flag           = case when mr.meter_flag in ('misread', 're_entry', 'duplicate') then mr.meter_flag else 'estimate_pending' end,
         vision_resolved_at   = now(),
         vision_resolved_by   = auth.uid(),
         vision_resolved_note = 'No meter photo was taken: ' || v_note
   where mr.session_id = cs.id;

  perform public.meter_no_photo_notice_v1(cs.id);
  return jsonb_build_object('ok', true);
end;
$function$;

-- 6. settle the estimates --------------------------------------------------------------------------------------------------------------------------
-- Per property, per meter (electric, water) independently. Stay order = the session's checkout_date (fallback: Manila date of recorded_at), then recorded_at, id.
-- A gap = a maximal run of consecutive estimate_pending rows. A = nearest earlier row with flag null/typed_accepted/estimated and a number.
-- B = the reading of the NEXT confirmed calendar stay after the last pending row's stay, only if it is vision ok and unflagged; otherwise the gap waits.
-- Pass A <= p1 <= .. <= pn <= B: keep typed, flag typed_accepted. Fail: pending rows get A + (B - A) * cumulative nights / total nights (B's stay included),
-- electric 2 dp, water 3 dp, flag estimated. A typed value that is null stays null. Either way prev/delta/per-night are recomputed for every pending row and for B.
-- A gap whose A or B number is missing, or where B is below A, does not change (the last case also opens a low-priority task). Idempotent.
create or replace function public.meter_settle_estimates_v1(p_property_id uuid default null)
returns jsonb language plpgsql volatile security definer set search_path to '' as $function$
declare
  v_prop   uuid;
  v_ids    uuid[];
  v_n      int;
  v_first  record;
  v_last_stay date;
  v_b_stay date;
  b        public.meter_readings%rowtype;
  v_b_nights int;
  v_nights int[];
  v_names  text[];
  v_typed  numeric[];
  v_new    numeric[];
  v_vals   numeric[];
  v_m      int;
  v_a      numeric;
  v_a_date date;
  v_bv     numeric;
  v_scale  int;
  v_ok     boolean;
  v_prevv  numeric;
  v_total  int;
  v_cum    int;
  v_i      int;
  v_have   boolean[] := array[false, false];
  v_wait   boolean;
  v_stuck  boolean;
  v_repl   boolean[];
  v_a_dates date[] := array[null, null]::date[];
  v_e_new  numeric[]; v_w_new numeric[];
  v_e_typed numeric[]; v_w_typed numeric[];
  v_prev   numeric; v_delta numeric; v_pn numeric;
  v_detail text;
  v_guests text;
  v_gaps_settled int := 0; v_gaps_waiting int := 0; v_rows int := 0;
begin
  for v_prop in
    select distinct mr.property_id from public.meter_readings mr
     where mr.meter_flag = 'estimate_pending' and mr.property_id is not null and (p_property_id is null or mr.property_id = p_property_id)
  loop
    perform pg_advisory_xact_lock(hashtextextended('s100_meter_settle:' || v_prop::text, 0));

    for v_ids in
      select array_agg(g.id order by g.rn)
        from (select s.id, s.rn, s.rn - row_number() over (order by s.rn) as grp
                from (select mr.id, mr.meter_flag,
                             row_number() over (order by coalesce(cs.checkout_date, (mr.recorded_at at time zone 'Asia/Manila')::date), mr.recorded_at, mr.id) as rn
                        from public.meter_readings mr left join public.cleaning_sessions cs on cs.id = mr.session_id
                       where mr.property_id = v_prop) s
               where s.meter_flag = 'estimate_pending') g
       group by g.grp
       order by min(g.rn)
    loop
      v_n := array_length(v_ids, 1);
      perform 1 from public.meter_readings where id = any (v_ids) for update;
      -- re-read: another run may have settled these rows since the gap list was built
      if exists (select 1 from public.meter_readings where id = any (v_ids) and meter_flag is distinct from 'estimate_pending') then continue; end if;

      -- the gap's rows in order
      select array_agg(public.s_meter_nights_v1(mr.session_id) order by array_position(v_ids, mr.id)),
             array_agg(cs.last_guest_name order by array_position(v_ids, mr.id)),
             array_agg(mr.electric_curr order by array_position(v_ids, mr.id)),
             array_agg(mr.water_curr order by array_position(v_ids, mr.id))
        into v_nights, v_names, v_e_typed, v_w_typed
        from public.meter_readings mr left join public.cleaning_sessions cs on cs.id = mr.session_id
       where mr.id = any (v_ids);

      select coalesce(cs.checkout_date, (mr.recorded_at at time zone 'Asia/Manila')::date) as stay, mr.recorded_at as rec, mr.id as id
        into v_first
        from public.meter_readings mr left join public.cleaning_sessions cs on cs.id = mr.session_id
       where mr.id = v_ids[1];
      select coalesce(cs.checkout_date, (mr.recorded_at at time zone 'Asia/Manila')::date) into v_last_stay
        from public.meter_readings mr left join public.cleaning_sessions cs on cs.id = mr.session_id
       where mr.id = v_ids[v_n];

      -- B: the next confirmed stay's verified reading
      select min(ce.checkout_date) into v_b_stay from public.calendar_events ce
       where ce.property_id = v_prop and ce.status = 'confirmed' and ce.checkout_date > v_last_stay;
      b := null;
      if v_b_stay is not null then
        select mr.* into b
          from public.meter_readings mr join public.cleaning_sessions cs on cs.id = mr.session_id
         where mr.property_id = v_prop and cs.checkout_date = v_b_stay and mr.meter_flag is null and mr.vision_verdict = 'ok'
         order by mr.recorded_at desc, mr.id limit 1;
      end if;
      if b.id is null then v_gaps_waiting := v_gaps_waiting + 1; continue; end if;
      v_b_nights := public.s_meter_nights_v1(b.session_id);

      v_wait := false; v_stuck := false;
      v_e_new := v_e_typed; v_w_new := v_w_typed;
      v_repl := array[false, false];
      v_have := array[false, false];
      v_a_dates := array[null, null]::date[];

      -- the two meters, independently (1 electric, 2 water)
      for v_m in 1..2 loop
        v_vals := case v_m when 1 then v_e_typed else v_w_typed end;
        v_scale := case v_m when 1 then 2 else 3 end;
        v_bv := case v_m when 1 then b.electric_curr else b.water_curr end;
        if (select count(*) from unnest(v_vals) x where x is not null) = 0 then continue; end if;
        v_have[v_m] := true;

        select case v_m when 1 then x.electric_curr else x.water_curr end, x.stay into v_a, v_a_date
          from (select mr.electric_curr, mr.water_curr, mr.meter_flag, mr.recorded_at, mr.id,
                       coalesce(cs.checkout_date, (mr.recorded_at at time zone 'Asia/Manila')::date) as stay
                  from public.meter_readings mr left join public.cleaning_sessions cs on cs.id = mr.session_id
                 where mr.property_id = v_prop) x
         where (x.stay, x.recorded_at, x.id) < (v_first.stay, v_first.rec, v_first.id)
           and (x.meter_flag is null or x.meter_flag in ('typed_accepted', 'estimated'))
           and (case v_m when 1 then x.electric_curr else x.water_curr end) is not null
         order by x.stay desc, x.recorded_at desc, x.id desc
         limit 1;
        if not found or v_a is null or v_bv is null then v_wait := true; continue; end if;
        v_a_dates[v_m] := v_a_date;

        v_ok := true; v_prevv := v_a;
        for v_i in 1..v_n loop
          if v_vals[v_i] is null then continue; end if;
          if v_vals[v_i] < v_prevv then v_ok := false; end if;
          v_prevv := v_vals[v_i];
        end loop;
        if v_bv < v_prevv then v_ok := false; end if;

        if not v_ok then
          if v_bv < v_a then v_stuck := true; continue; end if;
          v_total := v_b_nights; foreach v_cum in array v_nights loop v_total := v_total + v_cum; end loop;
          v_cum := 0;
          for v_i in 1..v_n loop
            v_cum := v_cum + v_nights[v_i];
            if v_vals[v_i] is not null then
              v_vals[v_i] := round(v_a + (v_bv - v_a) * v_cum / v_total, v_scale);
            end if;
          end loop;
          v_repl[v_m] := true;
          if v_m = 1 then v_e_new := v_vals; else v_w_new := v_vals; end if;
        end if;
      end loop;

      if v_stuck then
        perform public.system_task_open_v1(v_prop, 'meter_estimate_blocked', v_ids[1]::text,
          'Meter readings could not be settled',
          'The verified reading after the stays without a meter photo is lower than the verified reading before them, so they cannot be averaged. Please check the meter readings by hand.',
          'low');
      end if;
      if v_wait or v_stuck then v_gaps_waiting := v_gaps_waiting + 1; continue; end if;

      -- apply: chain prev/delta/per-night from A through the gap to B
      v_detail := '';
      for v_m in 1..2 loop
        continue when not v_have[v_m];
        v_vals := case v_m when 1 then v_e_new else v_w_new end;
        v_scale := case v_m when 1 then 2 else 3 end;
        select case v_m when 1 then x.electric_curr else x.water_curr end into v_prev
          from (select mr.electric_curr, mr.water_curr, mr.meter_flag, mr.recorded_at, mr.id,
                       coalesce(cs.checkout_date, (mr.recorded_at at time zone 'Asia/Manila')::date) as stay
                  from public.meter_readings mr left join public.cleaning_sessions cs on cs.id = mr.session_id
                 where mr.property_id = v_prop) x
         where (x.stay, x.recorded_at, x.id) < (v_first.stay, v_first.rec, v_first.id)
           and (x.meter_flag is null or x.meter_flag in ('typed_accepted', 'estimated'))
           and (case v_m when 1 then x.electric_curr else x.water_curr end) is not null
         order by x.stay desc, x.recorded_at desc, x.id desc
         limit 1;
        for v_i in 1..v_n loop
          if v_vals[v_i] is null then
            v_delta := null; v_pn := null;
          else
            v_delta := v_vals[v_i] - v_prev;
            v_pn := round(v_delta / v_nights[v_i], case v_m when 1 then 2 else 3 end);
          end if;
          if v_m = 1 then
            update public.meter_readings set electric_curr = v_vals[v_i], electric_prev = v_prev, electric_delta = v_delta, kwh_per_night = v_pn where id = v_ids[v_i];
          else
            update public.meter_readings set water_curr = v_vals[v_i], water_prev = v_prev, water_delta = v_delta, m3_per_night = v_pn where id = v_ids[v_i];
          end if;
          if v_vals[v_i] is not null then v_prev := v_vals[v_i]; end if;
        end loop;
        v_delta := (case v_m when 1 then b.electric_curr else b.water_curr end) - v_prev;
        v_pn := round(v_delta / v_b_nights, case v_m when 1 then 2 else 3 end);
        if v_m = 1 then
          update public.meter_readings set electric_prev = v_prev, electric_delta = v_delta, kwh_per_night = v_pn where id = b.id;
        else
          update public.meter_readings set water_prev = v_prev, water_delta = v_delta, m3_per_night = v_pn where id = b.id;
        end if;
      end loop;

      for v_i in 1..v_n loop
        update public.meter_readings
           set meter_flag = case when v_repl[1] or v_repl[2] then 'estimated' else 'typed_accepted' end,
               meter_override_note = case when v_repl[1] or v_repl[2]
                 then 'D-352 per-night average between ' || to_char(coalesce(v_a_dates[1], v_a_dates[2]), 'YYYY-MM-DD') || ' and ' || to_char(v_b_stay, 'YYYY-MM-DD')
                 else meter_override_note end
         where id = v_ids[v_i];
        v_rows := v_rows + 1;
        v_detail := v_detail || coalesce(nullif(btrim(v_names[v_i]), ''), 'A guest') || ': electric '
          || coalesce(v_e_typed[v_i]::text, 'none') || case when v_repl[1] and v_e_typed[v_i] is not null then ' became ' || v_e_new[v_i]::text else ' kept' end
          || ', water ' || coalesce(v_w_typed[v_i]::text, 'none') || case when v_repl[2] and v_w_typed[v_i] is not null then ' became ' || v_w_new[v_i]::text else ' kept' end || '. ';
      end loop;

      select string_agg(distinct coalesce(nullif(btrim(n), ''), 'a guest'), ', ') into v_guests from unnest(v_names) n;
      perform public.system_task_open_v1(v_prop, 'meter_estimate_settled', b.session_id::text,
        'Meter readings settled for ' || coalesce(v_guests, 'a guest'),
        btrim(v_detail) || ' Checked against the verified reading of the next stay.', 'low');
      v_gaps_settled := v_gaps_settled + 1;
    end loop;
  end loop;
  return jsonb_build_object('settled', v_gaps_settled, 'waiting', v_gaps_waiting, 'rows', v_rows);
end;
$function$;

-- 6b. review_meter_reading_v1: the admin review whitelist learns the three new flags (same body, three more values) -----------------------------------------
-- Guarded: replaces ONLY the 20260914200000 body (md5 of prosrc, CR stripped, 1b23dc6085db7eeee408fe63bc0f50be); 55000 if it changed since.
do $g$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.review_meter_reading_v1(uuid,text,text)');
  if v_got is distinct from '1b23dc6085db7eeee408fe63bc0f50be' and v_got is distinct from 'daaff99a3e67b8a156669973f5f8733a' then
    raise exception 's100: public.review_meter_reading_v1 is not the body this release was cut from (md5 %)', v_got using errcode = '55000';
  end if;
end $g$;

create or replace function public.review_meter_reading_v1(p_reading_id uuid, p_flag text, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $
declare v_prop uuid; v_flag text := nullif(btrim(coalesce(p_flag, '')), '');
begin
  select property_id into v_prop from public.meter_readings where id = p_reading_id;
  if v_prop is null then raise exception using errcode = 'P0002', message = 'meter reading not found'; end if;
  perform public.admin_require('inspect_cleaning', v_prop);
  if v_flag is not null and v_flag not in ('first_reading','re_entry','misread','duplicate','under_review','estimate_pending','typed_accepted','estimated') then raise exception using errcode = '22023', message = 'unknown meter flag'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 3 then raise exception using errcode = '22023', message = 'a reason is required'; end if;
  perform public.admin_audit_context_v1(btrim(p_reason), null, null);
  update public.meter_readings set meter_flag = v_flag, meter_override_note = btrim(p_reason) where id = p_reading_id;
  return jsonb_build_object('ok', true, 'id', p_reading_id, 'flag', v_flag, 'auditId', (select id from public.admin_audit_log where entity_table = 'meter_readings' and entity_id = p_reading_id order by created_at desc limit 1));
end;
$;
revoke all on function public.review_meter_reading_v1(uuid, text, text) from public, anon, authenticated, service_role;
grant execute on function public.review_meter_reading_v1(uuid, text, text) to authenticated;

-- 7. grants (ML-21: restated in full) -------------------------------------------------------------------------------------------------------------
revoke all on function public.s_meter_nights_v1(uuid) from public, anon, authenticated, service_role;
revoke all on function public.s_meter_skip_check_v1(uuid, date, uuid) from public, anon, authenticated, service_role;
revoke all on function public.can_skip_meter_photos_v2(uuid, date) from public, anon, authenticated, service_role;
revoke all on function public.report_no_meter_photo_v1(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.meter_no_photo_notice_v1(uuid) from public, anon, authenticated, service_role;
revoke all on function public.meter_settle_estimates_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.can_skip_meter_photos_v2(uuid, date) to authenticated, service_role;
grant execute on function public.report_no_meter_photo_v1(uuid, text) to authenticated;
grant execute on function public.meter_no_photo_notice_v1(uuid) to service_role;
grant execute on function public.meter_settle_estimates_v1(uuid) to service_role;

comment on function public.can_skip_meter_photos_v2(uuid, date) is
  'D-352: may the stay that checks out on this date skip its meter photos? Never two neighbouring stays (calendar order), unless both hold a meter_skip_exceptions row. Null date = the v1 rule.';
comment on function public.report_no_meter_photo_v1(uuid, text) is
  'D-352: the cleaner (or an admin) reports that no meter photo was taken. Flags the reading estimate_pending, lifts the follow-up block, opens an admin task.';
comment on function public.meter_no_photo_notice_v1(uuid) is
  'D-352: one follow-up task per session that reported no meter photo. service_role only.';
comment on function public.meter_settle_estimates_v1(uuid) is
  'D-352: settles estimate_pending readings once the next stay has a verified reading: typed kept if in order, else a per-night average. Idempotent. service_role only (cron meter-settle-estimates).';

-- 8. cron: meter-settle-estimates every 30 minutes (no-op where pg_cron is absent, e.g. a rehearsal copy) -----------------------------------------
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron absent (rehearsal copy) - meter-settle-estimates wiring skipped';
    return;
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'meter-settle-estimates';
  perform cron.schedule('meter-settle-estimates', '*/30 * * * *', $cmd$select public.meter_settle_estimates_v1();$cmd$);
  if (select count(*) from cron.job where jobname = 'meter-settle-estimates' and active and schedule = '*/30 * * * *'
        and command like '%meter_settle_estimates_v1%') <> 1 then
    raise exception 'meter-settle-estimates not scheduled';
  end if;
end $$;

-- 9. final check -------------------------------------------------------------------------------------------------------------------------------------
do $$
begin
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
        and proname in ('s_meter_nights_v1', 's_meter_skip_check_v1', 'can_skip_meter_photos_v2', 'report_no_meter_photo_v1', 'meter_no_photo_notice_v1', 'meter_settle_estimates_v1')) <> 6 then
    raise exception 's100: a function is missing or has more than one overload';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.meter_skip_exceptions'::regclass) then raise exception 's100: meter_skip_exceptions RLS not enabled'; end if;
  if has_table_privilege('authenticated', 'public.meter_skip_exceptions', 'select,insert,update,delete')
     or has_table_privilege('anon', 'public.meter_skip_exceptions', 'select,insert,update,delete') then
    raise exception 's100: meter_skip_exceptions is open to an API role';
  end if;
  if has_function_privilege('anon', 'public.can_skip_meter_photos_v2(uuid,date)', 'execute')
     or has_function_privilege('anon', 'public.report_no_meter_photo_v1(uuid,text)', 'execute')
     or has_function_privilege('authenticated', 'public.meter_settle_estimates_v1(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.meter_no_photo_notice_v1(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.s_meter_skip_check_v1(uuid,date,uuid)', 'execute')
     or has_function_privilege('service_role', 'public.s_meter_skip_check_v1(uuid,date,uuid)', 'execute') then
    raise exception 's100: a grant is wider than intended';
  end if;
end $$;

commit;
