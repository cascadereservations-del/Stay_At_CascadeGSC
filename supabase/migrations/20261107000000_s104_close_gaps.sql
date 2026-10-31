-- 20261107000000_s104_close_gaps.sql
-- Cascade Hideaway - s104: close the remaining meter-check gaps (contract: docs/s104/CONTRACT-close-gaps.md, Lane Q; Lloyd 2026-10-31: "close these and all possible remaining gaps").
--
-- Why. s101 gave admins a card for reports held by a photo mismatch, s102 closes system tasks by itself, s103 made verify-meter-photo record date findings
-- (meter_readings.vision_raw -> 'photo_date_lines', e.g. "Electric photo taken Oct 23, checkout Oct 21") while the verdict stays 'ok'. Nothing showed those findings,
-- and five smaller gaps were left open. Every function below is replaced with its LIVE text (read 2026-10-31, md5 of replace(prosrc, chr(13), '') in the guard) changed only where listed:
--  (1) admin_report_blocks_v1 (DROP + CREATE: RETURNS TABLE gains three columns at the END, the 15 existing ones unchanged): reason ('mismatch' | 'photo_date'),
--      photo_date_lines text[], photo_archived boolean (a photo path is on file but the storage object in bucket cleaning-photos is gone). A row is listed when it is an
--      unresolved mismatch (as before) OR it is unresolved and carries a non-empty photo_date_lines array; both inside the lookback. Gate unchanged (inspect_cleaning).
--  (2) admin_resolve_report_block_v1: also answers a row whose only finding is photo_date_lines (verdict not mismatch); both actions work on it. A missing id and a refusal
--      are the same 42501 'inspect_cleaning denied' (ids cannot be probed). Fixes the s101 known gap: the NEXT reading is the first by (stay date, recorded_at, id), so a later
--      reading of the SAME checkout day (a deep clean after the turnover) is re-pointed instead of being skipped for the following stay.
--  (3) meter_settle_estimates_v1: the s102 note-prefix test for an answered mismatch stays, and vision_resolved_by must be a staff user who may inspect_cleaning
--      (staff_access_profiles + staff_access_allowed(role, 'inspect_cleaning', null, 'aal2'); an answer given while the admin was active keeps counting after a later disable; inspect_cleaning has no aal rule, 'aal2' only keeps a future rule from refusing an admin).
--      A cleaner who typed the admin sentence through resolve_meter_followup_v1 no longer makes B.
--  (4) system_tasks_sweep_v1: also closes OPEN meter_estimate_settled tasks older than 3 days ("Information only - closed after 3 days."); a ref that matches the pattern but is not a
--      real date (invalid_datetime_format / datetime_field_overflow) is skipped silently, only other errors raise the warning. Returns the same keys plus "info".
--  (5) get_meter_photo_followups (DROP + CREATE): checkout_date date and guest_name text (cleaning_sessions.last_guest_name, trimmed, null if blank) at the END of the return table.
-- Grants are restated in full (ML-21: the rehearsal restore is --no-acl, production has default privileges). No table, column, trigger or cron change.
-- New body md5s (md5 of replace(prosrc, chr(13), '')): admin_report_blocks_v1 7b716ca816ea57de257faa7643a24278, admin_resolve_report_block_v1 3c46fb55f19a4edfa82e383eb5642744, meter_settle_estimates_v1 c6f2a465cbf6ad7694a4281e5fa13190,
--   system_tasks_sweep_v1 0fdd80d252523c39cc30003475fb21bb, get_meter_photo_followups 361b27faff2200dadbca86c30ac78e1a.

begin;

-- 0. guard: every replaced function is the live body or this release's own (55000 if it moved since) ---------------------------------------------------------
do $g$
declare v_md5 text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_md5 from pg_proc p where p.oid = to_regprocedure('public.admin_report_blocks_v1(uuid,integer)');
  if v_md5 is distinct from 'e1093804346d7488d3c2b617ceae2205' and v_md5 is distinct from '7b716ca816ea57de257faa7643a24278' then
    raise exception 's104: public.admin_report_blocks_v1(uuid,integer) is not the body this release was cut from (md5 %)', v_md5 using errcode = '55000';
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v_md5 from pg_proc p where p.oid = to_regprocedure('public.admin_resolve_report_block_v1(uuid,text,numeric,numeric,text)');
  if v_md5 is distinct from 'f23647ef6a039daf1999faf9c33e35fd' and v_md5 is distinct from '3c46fb55f19a4edfa82e383eb5642744' then
    raise exception 's104: public.admin_resolve_report_block_v1(uuid,text,numeric,numeric,text) is not the body this release was cut from (md5 %)', v_md5 using errcode = '55000';
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v_md5 from pg_proc p where p.oid = to_regprocedure('public.meter_settle_estimates_v1(uuid)');
  if v_md5 is distinct from '36726d52dccd5911ac473f607f4aab06' and v_md5 is distinct from 'c6f2a465cbf6ad7694a4281e5fa13190' then
    raise exception 's104: public.meter_settle_estimates_v1(uuid) is not the body this release was cut from (md5 %)', v_md5 using errcode = '55000';
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v_md5 from pg_proc p where p.oid = to_regprocedure('public.system_tasks_sweep_v1()');
  if v_md5 is distinct from 'e92e15b99917ab19cd8c9bf3c6510b44' and v_md5 is distinct from '0fdd80d252523c39cc30003475fb21bb' then
    raise exception 's104: public.system_tasks_sweep_v1() is not the body this release was cut from (md5 %)', v_md5 using errcode = '55000';
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v_md5 from pg_proc p where p.oid = to_regprocedure('public.get_meter_photo_followups(uuid,integer)');
  if v_md5 is distinct from '05c12c435acd72f5f1f04e6f657f0b66' and v_md5 is distinct from '361b27faff2200dadbca86c30ac78e1a' then
    raise exception 's104: public.get_meter_photo_followups(uuid,integer) is not the body this release was cut from (md5 %)', v_md5 using errcode = '55000';
  end if;
end $g$;

-- 1. admin_report_blocks_v1 (return table changes: drop + create, then re-grant) ----------------------------------------------------------------------------
drop function public.admin_report_blocks_v1(uuid, integer);
CREATE OR REPLACE FUNCTION public.admin_report_blocks_v1(p_property_id uuid DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid, p_lookback integer DEFAULT 14)
 RETURNS TABLE(reading_id uuid, session_id uuid, cleaner_name text, checkout_date date, recorded_at timestamp with time zone, typed_electric numeric, typed_water numeric, prev_electric numeric, prev_water numeric, photo_electric numeric, photo_water numeric, photo_note_electric text, photo_note_water text, photo_path_electric text, photo_path_water text, reason text, photo_date_lines text[], photo_archived boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not public.current_staff_authorized('inspect_cleaning', p_property_id) then
    raise exception 'not authorized to inspect cleaning for this property'
      using errcode = '42501';
  end if;

  return query
  select
    mr.id,
    mr.session_id,
    cs.cleaner_name,
    cs.checkout_date,
    mr.recorded_at,
    mr.electric_curr,
    mr.water_curr,
    mr.electric_prev,
    mr.water_prev,
    -- the reader's own number from vision_raw; the vision_* column holds the same value and covers a row whose vision_raw lacks it
    coalesce(case when mr.vision_raw -> 'electric' ->> 'reading' ~ '^-?[0-9]+(\.[0-9]+)?$' then (mr.vision_raw -> 'electric' ->> 'reading')::numeric end, mr.vision_electric),
    coalesce(case when mr.vision_raw -> 'water' ->> 'reading' ~ '^-?[0-9]+(\.[0-9]+)?$' then (mr.vision_raw -> 'water' ->> 'reading')::numeric end, mr.vision_water),
    nullif(mr.vision_raw -> 'electric' ->> 'note', ''),
    nullif(mr.vision_raw -> 'water' ->> 'note', ''),
    nullif(mr.vision_raw -> 'paths' ->> 'electric', ''),
    nullif(mr.vision_raw -> 'paths' ->> 'water', ''),
    -- s104: a mismatch is a hold; a photo that is only the wrong day (vision_raw.photo_date_lines, verdict still ok) is listed for a look and never holds a report
    case when mr.vision_verdict = 'mismatch' then 'mismatch' else 'photo_date' end,
    array(select jsonb_array_elements_text(case when jsonb_typeof(mr.vision_raw -> 'photo_date_lines') = 'array' then mr.vision_raw -> 'photo_date_lines' else '[]'::jsonb end)),
    -- archived: a photo path is on file but its storage object is gone (the photo moved to the Drive archive); a meter with no path is not archived
    ((nullif(mr.vision_raw -> 'paths' ->> 'electric', '') is not null
        and not exists (select 1 from storage.objects o where o.bucket_id = 'cleaning-photos' and o.name = (mr.vision_raw -> 'paths' ->> 'electric')))
     or (nullif(mr.vision_raw -> 'paths' ->> 'water', '') is not null
        and not exists (select 1 from storage.objects o where o.bucket_id = 'cleaning-photos' and o.name = (mr.vision_raw -> 'paths' ->> 'water'))))
  from public.meter_readings mr
  left join public.cleaning_sessions cs on cs.id = mr.session_id
  where mr.property_id = p_property_id
    and mr.vision_resolved_at is null
    and (mr.vision_verdict = 'mismatch'
         or (case when jsonb_typeof(mr.vision_raw -> 'photo_date_lines') = 'array' then jsonb_array_length(mr.vision_raw -> 'photo_date_lines') else 0 end) > 0)
    and mr.recorded_at >= (now() - make_interval(days => greatest(coalesce(p_lookback, 14), 1)))
  order by mr.recorded_at desc, mr.id;
end;
$function$
;

-- 2. admin_resolve_report_block_v1 ---------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_resolve_report_block_v1(p_reading_id uuid, p_action text, p_electric numeric DEFAULT NULL::numeric, p_water numeric DEFAULT NULL::numeric, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_action  text := btrim(coalesce(p_action, ''));
  v_note    text := nullif(btrim(coalesce(p_note, '')), '');
  v_prop    uuid;
  v_r       record;
  v_reason  text;
  v_day     date;
  v_key     date;
  v_nights  integer;
  v_de      numeric;
  v_dw      numeric;
  v_ne      record;
  v_nw      record;
begin
  if v_action not in ('typed_is_right', 'correct_numbers') then
    raise exception 'unknown action' using errcode = '22023';
  end if;
  if v_note is not null and length(v_note) > 300 then
    raise exception 'a note is at most 300 characters' using errcode = '22023';
  end if;

  select mr.property_id into v_prop from public.meter_readings mr where mr.id = p_reading_id;
  if v_prop is null then
    -- s104: a missing id answers exactly like a refusal (same code, same message as admin_require), so ids cannot be probed
    raise exception using errcode = '42501', message = case when auth.uid() is null then 'authentication required' else 'inspect_cleaning denied' end;
  end if;
  perform public.admin_require('inspect_cleaning', v_prop);

  select mr.id, mr.property_id, mr.meter_flag, mr.vision_verdict, mr.vision_resolved_at, mr.recorded_at,
         mr.electric_prev, mr.water_prev, cs.checkout_date, cs.nights_stayed,
         case when jsonb_typeof(mr.vision_raw -> 'photo_date_lines') = 'array' then jsonb_array_length(mr.vision_raw -> 'photo_date_lines') else 0 end as n_date_lines
    into v_r
    from public.meter_readings mr
    left join public.cleaning_sessions cs on cs.id = mr.session_id
   where mr.id = p_reading_id
     for update of mr;
  if not found then
    raise exception 'That reading was not found.' using errcode = '22023';
  end if;
  if v_r.vision_resolved_at is not null then
    raise exception 'That reading has already been answered.' using errcode = '22023';
  end if;
  -- s104: a reading whose only finding is the photo date (vision_raw.photo_date_lines) can be answered too
  if v_r.vision_verdict is distinct from 'mismatch' and v_r.n_date_lines = 0 then
    raise exception 'That reading is not holding up a report.' using errcode = '22023';
  end if;

  if v_action = 'typed_is_right' then
    v_reason := 'Typed numbers confirmed by an admin' || coalesce(': ' || v_note, '');
    perform public.admin_audit_context_v1(v_reason, null, null);
    update public.meter_readings
       set vision_resolved_at = now(), vision_resolved_by = auth.uid(), vision_resolved_note = v_reason
     where id = p_reading_id;
    return jsonb_build_object('ok', true, 'action', v_action, 'reading_id', p_reading_id);
  end if;

  -- correct_numbers ------------------------------------------------------------------------------------------------------------------------------
  -- a row already flagged as wrong numbers is not a reading to correct (it is never a neighbour either): release the report, then fix it from the cleaning detail
  if v_r.meter_flag in ('misread', 're_entry', 'duplicate') then
    raise exception 'This reading is already marked as wrong numbers. Use Typed numbers are right to release the report, then fix the numbers from the cleaning detail.'
      using errcode = '22023';
  end if;
  if p_electric is null or p_water is null then
    raise exception 'Both the electric and the water number are required.' using errcode = '22023';
  end if;
  if p_electric <= 0 or p_water <= 0 then
    raise exception 'The electric and water numbers must be more than zero.' using errcode = '22023';
  end if;
  -- a meter does not run backwards (D-219): not below the stay before ...
  if v_r.electric_prev is not null and p_electric < v_r.electric_prev then
    raise exception 'The electric number % is lower than the last reading on file (%). A meter does not run backwards.', p_electric, v_r.electric_prev
      using errcode = '22023';
  end if;
  if v_r.water_prev is not null and p_water < v_r.water_prev then
    raise exception 'The water number % is lower than the last reading on file (%). A meter does not run backwards.', p_water, v_r.water_prev
      using errcode = '22023';
  end if;

  -- The stay this reading belongs to and the readings after it: meter-order.ts stayKey / meterNeighbours (server mode, mid-stays included). A reading
  -- belongs to its session's check-out date, never later than the Manila day it was recorded; rows flagged misread / re_entry / duplicate (wrong numbers)
  -- or estimate_pending (no photo) are never neighbours. s104: the order is (stay date, recorded_at, id), so a later reading of the SAME stay date (a deep clean after the turnover) is the next one.
  v_day := (v_r.recorded_at at time zone 'Asia/Manila')::date;
  v_key := case when v_r.checkout_date is not null and v_r.checkout_date < v_day then v_r.checkout_date else v_day end;

  select x.id, x.electric_curr as val, x.electric_prev as prev, coalesce(x.nights_stayed, 0) as nights
    into v_ne
    from (select mr.id, mr.electric_curr, mr.electric_prev, mr.recorded_at, cs.nights_stayed,
                 case when cs.checkout_date is not null and cs.checkout_date < (mr.recorded_at at time zone 'Asia/Manila')::date
                      then cs.checkout_date else (mr.recorded_at at time zone 'Asia/Manila')::date end as k
            from public.meter_readings mr
            left join public.cleaning_sessions cs on cs.id = mr.session_id
           where mr.property_id = v_r.property_id and mr.id <> p_reading_id and mr.electric_curr > 0
             and (mr.meter_flag is null or mr.meter_flag not in ('misread', 're_entry', 'duplicate', 'estimate_pending'))) x
   where (x.k, x.recorded_at, x.id) > (v_key, v_r.recorded_at, v_r.id)
   order by x.k, x.recorded_at, x.id
   limit 1;
  select x.id, x.water_curr as val, x.water_prev as prev, coalesce(x.nights_stayed, 0) as nights
    into v_nw
    from (select mr.id, mr.water_curr, mr.water_prev, mr.recorded_at, cs.nights_stayed,
                 case when cs.checkout_date is not null and cs.checkout_date < (mr.recorded_at at time zone 'Asia/Manila')::date
                      then cs.checkout_date else (mr.recorded_at at time zone 'Asia/Manila')::date end as k
            from public.meter_readings mr
            left join public.cleaning_sessions cs on cs.id = mr.session_id
           where mr.property_id = v_r.property_id and mr.id <> p_reading_id and mr.water_curr > 0
             and (mr.meter_flag is null or mr.meter_flag not in ('misread', 're_entry', 'duplicate', 'estimate_pending'))) x
   where (x.k, x.recorded_at, x.id) > (v_key, v_r.recorded_at, v_r.id)
   order by x.k, x.recorded_at, x.id
   limit 1;

  -- ... and not above the stay after it (meterOrderMessage)
  if v_ne.id is not null and p_electric > v_ne.val then
    raise exception 'The electric number % is higher than the reading for the later stay (%). A meter does not run backwards.', p_electric, v_ne.val
      using errcode = '22023';
  end if;
  if v_nw.id is not null and p_water > v_nw.val then
    raise exception 'The water number % is higher than the reading for the later stay (%). A meter does not run backwards.', p_water, v_nw.val
      using errcode = '22023';
  end if;

  v_reason := 'Numbers corrected by an admin from the photo' || coalesce(': ' || v_note, '');
  perform public.admin_audit_context_v1(v_reason, null, null);

  -- this row's usage: submit-cleaning index.ts deltaKwh / deltaM3 / kwhPerNight / m3PerNight (the previous reading stays as stored; nights = the session's)
  v_nights := coalesce(v_r.nights_stayed, 0);
  v_de := case when v_r.electric_prev is not null then round(p_electric - v_r.electric_prev, 2) end;
  v_dw := case when v_r.water_prev    is not null then round(p_water    - v_r.water_prev,    3) end;
  update public.meter_readings
     set electric_curr = p_electric,
         water_curr = p_water,
         electric_delta = v_de,
         water_delta = v_dw,
         kwh_per_night = case when v_de is not null and v_nights > 0 then round(v_de / v_nights, 2) end,
         m3_per_night  = case when v_dw is not null and v_nights > 0 then round(v_dw / v_nights, 3) end,
         vision_resolved_at = now(),
         vision_resolved_by = auth.uid(),
         vision_resolved_note = v_reason
   where id = p_reading_id;

  -- the later stay's usage was measured from the old number: re-point it (meter-order.ts repointNext). A row that is not a usable neighbour
  -- (misread / re_entry / duplicate / estimate_pending, meter-order.ts usableRows) never moves it; first_reading / typed_accepted / estimated rows do.
  -- Fires whenever the next row's previous differs from the new number (repointNext semantics), not only when it equalled the old typed number.
  -- A next row that already points at the new number is left alone.
  if v_r.meter_flag is null or v_r.meter_flag not in ('misread', 're_entry', 'duplicate', 'estimate_pending') then
    if v_ne.id is not null and v_ne.val >= p_electric and v_ne.prev is distinct from p_electric then
      update public.meter_readings
         set electric_prev = p_electric,
             electric_delta = round(v_ne.val - p_electric, 2),
             kwh_per_night = case when v_ne.nights > 0 then round(round(v_ne.val - p_electric, 2) / v_ne.nights, 2) end
       where id = v_ne.id and property_id = v_r.property_id;
    end if;
    if v_nw.id is not null and v_nw.val >= p_water and v_nw.prev is distinct from p_water then
      update public.meter_readings
         set water_prev = p_water,
             water_delta = round(v_nw.val - p_water, 3),
             m3_per_night = case when v_nw.nights > 0 then round(round(v_nw.val - p_water, 3) / v_nw.nights, 3) end
       where id = v_nw.id and property_id = v_r.property_id;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'action', v_action, 'reading_id', p_reading_id);
end;
$function$
;

-- 3. meter_settle_estimates_v1 -------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.meter_settle_estimates_v1(p_property_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
         where mr.property_id = v_prop and cs.checkout_date = v_b_stay and mr.meter_flag is null and (mr.vision_verdict = 'ok' or (mr.vision_verdict = 'mismatch' and mr.vision_resolved_at is not null and (mr.vision_resolved_note like 'Typed numbers confirmed by an admin%' or mr.vision_resolved_note like 'Numbers corrected by an admin%') and exists (select 1 from public.staff_access_profiles sp where sp.user_id = mr.vision_resolved_by and public.staff_access_allowed(sp.role, 'inspect_cleaning', null, 'aal2'))))
         order by mr.recorded_at desc, mr.id limit 1;
      end if;
      if b.id is null then
        v_gaps_waiting := v_gaps_waiting + 1;
        if v_last_stay < (now() at time zone 'Asia/Manila')::date - 7 then
          select string_agg(distinct coalesce(nullif(btrim(n), ''), 'a guest'), ', ') into v_guests from unnest(v_names) n;
          perform public.system_task_open_v1(v_prop, 'meter_estimate_waiting',
            coalesce((select mr.session_id from public.meter_readings mr where mr.id = v_ids[1]), v_ids[1])::text,
            'Meter readings waiting for the next stay''s report',
            'The meter readings of ' || coalesce(v_guests, 'a guest') || ' are still estimates. The report for the next stay'
              || case when v_b_stay is not null then ' (checking out ' || to_char(v_b_stay, 'FMDD Mon') || ')' else '' end
              || ' has not been filed, or its meter photo has not been verified. They settle on their own once it is.',
            'low');
        end if;
        continue;
      end if;
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
                 then 'D-352 ' || concat_ws('; ',
                        case when v_repl[1] then 'electric per-night average between ' || to_char(v_a_dates[1], 'YYYY-MM-DD') || ' and ' || to_char(v_b_stay, 'YYYY-MM-DD') end,
                        case when v_repl[2] then 'water per-night average between ' || to_char(v_a_dates[2], 'YYYY-MM-DD') || ' and ' || to_char(v_b_stay, 'YYYY-MM-DD') end)
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
$function$
;

-- 4. system_tasks_sweep_v1 ----------------------------------------------------------------------------------------------------------------------------------
create or replace function public.system_tasks_sweep_v1()
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  t      record;
  v_gd   integer := 0;
  v_mc   integer := 0;
  v_me   integer := 0;
  v_info integer := 0;
  v_date date;
  v_guest uuid;
  v_note text;
begin
  for t in
    select f.id, f.property_id, f.source_kind, f.source_ref, f.created_at
      from public.follow_up_tasks f
     where f.status in ('open', 'in_progress')
       and f.idempotency_key like 'system:%'
       and f.source_kind in ('guest_details', 'missed_cleaning', 'meter_no_photo', 'meter_estimate_waiting', 'meter_estimate_settled')
  loop
    v_note := null;
    -- a ref that does not parse (or is not a real date) is skipped, never an error
    begin
      if t.source_kind = 'guest_details' then
        if t.source_ref ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
          v_date := split_part(t.source_ref, ':', 1)::date;
          v_guest := split_part(t.source_ref, ':', 2)::uuid;
          if exists (select 1 from public.guests g where g.id = v_guest)
             and not exists (select 1 from public.guests_missing_details_v1(array[v_guest])) then
            v_note := 'Closed automatically: the guest''s ID or contact details are now on file.';
          elsif not exists (select 1 from public.calendar_events ce
                             where ce.property_id = t.property_id and ce.status = 'confirmed' and ce.checkin_date = v_date) then
            v_note := 'Closed automatically: this stay is no longer on the calendar.';
          end if;
        end if;
      elsif t.source_kind = 'missed_cleaning' then
        if t.source_ref ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
          v_date := t.source_ref::date;
          if exists (select 1 from public.cleaning_sessions cs
                      where cs.property_id = t.property_id and cs.checkout_date = v_date
                        -- a mid-stay clean carries the stay's checkout date but is not the turnover report (get_missed_cleanings excludes it too)
                        and coalesce(cs.cleaning_type, 'checkout') <> 'mid_stay') then
            v_note := 'Closed automatically: the cleaning report for this checkout is now on file.';
          elsif not exists (select 1 from public.calendar_events ce
                             where ce.property_id = t.property_id and ce.status = 'confirmed' and ce.checkout_date = v_date) then
            v_note := 'Closed automatically: no confirmed stay checks out on this day any more.';
          end if;
        end if;
      elsif t.source_kind = 'meter_estimate_settled' then
        -- s104: an information-only task ("readings settled for X") has nothing left to do after 3 days
        if t.created_at < now() - interval '3 days' then
          v_note := 'Information only - closed after 3 days.';
        end if;
      else
        -- meter_no_photo / meter_estimate_waiting: the reading(s) of that session are no longer waiting for an estimate
        if t.source_ref ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
          if not exists (select 1 from public.meter_readings mr
                          -- s100 falls back to the reading id when the gap's first row has no session
                          where (mr.session_id = t.source_ref::uuid or mr.id = t.source_ref::uuid) and mr.meter_flag = 'estimate_pending') then
            v_note := 'Closed automatically: the meter readings have settled.';
          end if;
        end if;
      end if;
    exception
      -- s104: a ref that matches the pattern but is not a real date (2026-13-45) is skipped silently; only other errors raise the warning
      when invalid_datetime_format or datetime_field_overflow then
        v_note := null;
      when others then
      raise warning 's102 sweep skipped task % (%): %', t.id, t.source_kind, sqlerrm;
      v_note := null;
    end;

    if v_note is not null then
      update public.follow_up_tasks
         set status = 'done', completed_at = now(), completion_note = v_note
       where id = t.id and status in ('open', 'in_progress');
      if t.source_kind = 'guest_details' then v_gd := v_gd + 1;
      elsif t.source_kind = 'missed_cleaning' then v_mc := v_mc + 1;
      elsif t.source_kind = 'meter_estimate_settled' then v_info := v_info + 1;
      else v_me := v_me + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('guest_details', v_gd, 'missed_cleaning', v_mc, 'meter', v_me, 'info', v_info);
end;
$function$
;

-- 5. get_meter_photo_followups (return table changes: drop + create, then re-grant) --------------------------------------------------------------------------
drop function public.get_meter_photo_followups(uuid, integer);
CREATE OR REPLACE FUNCTION public.get_meter_photo_followups(p_property_id uuid DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid, p_lookback integer DEFAULT 14)
 RETURNS TABLE(session_id uuid, submission_id text, cleaned_at timestamp with time zone, cleaner_name text, reason text, typed_electric numeric, typed_water numeric, vision_electric numeric, vision_water numeric, vision_verdict text, checkout_date date, guest_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not public.current_staff_authorized('read_operations', p_property_id) then
    raise exception 'not authorized to read operations for this property'
      using errcode = '42501';
  end if;

  return query
  select
    cs.id,
    cs.submission_id,
    cs.cleaned_at,
    cs.cleaner_name,
    case
      when cs.meter_photos_skipped              then 'no meter photos were attached'
      when mr.vision_verdict = 'mismatch'       then 'the photo does not show the number that was typed'
      when mr.vision_verdict = 'not_a_meter'    then 'the photo does not look like a meter'
      when mr.vision_verdict = 'unreadable'     then 'the photo could not be read'
      else 'needs another look'
    end,
    mr.electric_curr,
    mr.water_curr,
    mr.vision_electric,
    mr.vision_water,
    mr.vision_verdict,
    cs.checkout_date,
    nullif(btrim(cs.last_guest_name), '')
  from public.cleaning_sessions cs
  left join public.meter_readings mr on mr.session_id = cs.id
  where cs.property_id = p_property_id
    and cs.cleaned_at >= (now() - make_interval(days => greatest(p_lookback, 1)))
    and mr.vision_resolved_at is null
    and cs.fee_paid_at is null -- S94: a settled session (paid in full) needs no photo follow-up
    and (
      cs.meter_photos_skipped
      or mr.vision_verdict in ('mismatch', 'not_a_meter', 'unreadable')
    )
  order by cs.cleaned_at desc;
end;
$function$
;

-- 6. grants restated in full (ML-21) and comments ----------------------------------------------------------------------------------------------------------
revoke all on function public.admin_report_blocks_v1(uuid, integer) from public, anon, authenticated, service_role;
revoke all on function public.admin_resolve_report_block_v1(uuid, text, numeric, numeric, text) from public, anon, authenticated, service_role;
revoke all on function public.meter_settle_estimates_v1(uuid) from public, anon, authenticated, service_role;
revoke all on function public.system_tasks_sweep_v1() from public, anon, authenticated, service_role;
revoke all on function public.get_meter_photo_followups(uuid, integer) from public, anon, authenticated, service_role;
grant execute on function public.admin_report_blocks_v1(uuid, integer) to authenticated;
grant execute on function public.admin_resolve_report_block_v1(uuid, text, numeric, numeric, text) to authenticated;
grant execute on function public.meter_settle_estimates_v1(uuid) to service_role;
grant execute on function public.get_meter_photo_followups(uuid, integer) to authenticated, service_role;

comment on function public.admin_report_blocks_v1(uuid, integer) is
  's101/s104: the meter photo mismatches that hold up the next cleaning report, plus readings whose photo date is far from the checkout day (reason photo_date, photo_date_lines, photo_archived), unresolved and within the lookback, newest first. inspect_cleaning.';
comment on function public.admin_resolve_report_block_v1(uuid, text, numeric, numeric, text) is
  's101/s104: clear a held cleaning report or a photo-date finding. typed_is_right confirms the typed numbers; correct_numbers replaces them (never backwards: D-219), recomputes usage and re-points the next reading (stay date, recorded_at, id) as submit-cleaning does. A missing id looks like a refusal (42501). inspect_cleaning.';
comment on function public.meter_settle_estimates_v1(uuid) is
  'D-352: settles estimate_pending readings once the next stay has a verified reading (or an answer by a staff user who may inspect_cleaning): typed kept if in order, else a per-night average. Idempotent. service_role only (cron meter-settle-estimates).';
comment on function public.system_tasks_sweep_v1() is
  's102/s104: closes open system tasks (guest_details, missed_cleaning, meter_no_photo, meter_estimate_waiting) whose problem is gone, and meter_estimate_settled information tasks after 3 days. Hourly cron system-tasks-sweep as postgres; no grants.';
comment on function public.get_meter_photo_followups(uuid, integer) is
  'Meter photo follow-ups raised at sign-in and in the staff app; s104 adds the checkout date and the guest name (last_guest_name, trimmed). read_operations.';

-- 7. in-migration check (a failed assert rolls the whole migration back) -------------------------------------------------------------------------------------
do $$
declare v_blocks text[] := array[
  'public.admin_report_blocks_v1(uuid,integer)|7b716ca816ea57de257faa7643a24278',
  'public.admin_resolve_report_block_v1(uuid,text,numeric,numeric,text)|3c46fb55f19a4edfa82e383eb5642744',
  'public.meter_settle_estimates_v1(uuid)|c6f2a465cbf6ad7694a4281e5fa13190',
  'public.system_tasks_sweep_v1()|0fdd80d252523c39cc30003475fb21bb',
  'public.get_meter_photo_followups(uuid,integer)|361b27faff2200dadbca86c30ac78e1a'];
  v_e text;
begin
  foreach v_e in array v_blocks loop
    if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = to_regprocedure(split_part(v_e, '|', 1))) is distinct from split_part(v_e, '|', 2) then
      raise exception 's104: % is not the intended body', split_part(v_e, '|', 1);
    end if;
  end loop;
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
        and proname in ('admin_report_blocks_v1', 'admin_resolve_report_block_v1', 'meter_settle_estimates_v1', 'system_tasks_sweep_v1', 'get_meter_photo_followups')) <> 5 then
    raise exception 's104: a function is missing or has more than one overload';
  end if;
  if has_function_privilege('anon', 'public.admin_report_blocks_v1(uuid,integer)', 'execute')
     or has_function_privilege('service_role', 'public.admin_report_blocks_v1(uuid,integer)', 'execute')
     or not has_function_privilege('authenticated', 'public.admin_report_blocks_v1(uuid,integer)', 'execute')
     or has_function_privilege('anon', 'public.admin_resolve_report_block_v1(uuid,text,numeric,numeric,text)', 'execute')
     or has_function_privilege('service_role', 'public.admin_resolve_report_block_v1(uuid,text,numeric,numeric,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.admin_resolve_report_block_v1(uuid,text,numeric,numeric,text)', 'execute')
     or has_function_privilege('anon', 'public.get_meter_photo_followups(uuid,integer)', 'execute')
     or not has_function_privilege('authenticated', 'public.get_meter_photo_followups(uuid,integer)', 'execute')
     or not has_function_privilege('service_role', 'public.get_meter_photo_followups(uuid,integer)', 'execute')
     or has_function_privilege('authenticated', 'public.meter_settle_estimates_v1(uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.meter_settle_estimates_v1(uuid)', 'execute')
     or has_function_privilege('anon', 'public.system_tasks_sweep_v1()', 'execute')
     or has_function_privilege('authenticated', 'public.system_tasks_sweep_v1()', 'execute')
     or has_function_privilege('service_role', 'public.system_tasks_sweep_v1()', 'execute') then
    raise exception 's104: a grant is not as intended';
  end if;
end $$;

commit;
