-- 20261106000000_s102_task_sweep.sql
-- Cascade Hideaway - s102: system tasks close themselves when the problem is gone (contract: docs/s102/CONTRACT-task-sweep.md).
-- Lloyd 2026-10-31: "notifications and tasks should auto close once detected completed or fixed".
--
-- Why. Four kinds of system task in Follow-ups were never closed by anything, or could not close once their ref aged out of a job's lookback:
--   guest_details          (ref <checkin date>:<guest uuid>)  closed only by a Telegram tap, although the details were often already on file
--   missed_cleaning        (ref <checkout date>)              closed by missed-cleaning-alert only within 13 days, and never when the stay itself vanished
--   meter_no_photo         (ref cleaning_sessions.id)         opened by s100, closed by nothing
--   meter_estimate_waiting (ref first session of the gap)     opened by s100, closed by nothing
-- low_stock (weekly) and verifier findings (apply_verifier_run_v1) already close themselves and are left alone.
--
-- What this adds:
--  (1) public.system_tasks_sweep_v1(): hourly, closes OPEN system tasks of those four kinds whose condition is gone, with a plain-sentence completion_note.
--      It never touches a task that is already done, a task of another kind, or a ref it cannot parse. No grants to anyone (only cron as postgres calls it).
--  (2) pg_cron job system-tasks-sweep at minute 50 of every hour (no-op where pg_cron is absent, e.g. a rehearsal copy).
--  (3) public.meter_settle_estimates_v1(uuid) replaced with the LIVE body changed in ONE place: the B reading also counts when its photo verdict is
--      'mismatch' but an admin has answered it (vision_resolved_at is not null). s101's "Typed numbers are right" / "Correct the numbers" stamp
--      vision_resolved_at and leave the verdict 'mismatch', so the next stay's answered reading never counted as B and the estimates (and their task) waited forever.
--      Live md5(replace(prosrc, chr(13), '')) before this change: e3eaf07237d1fdfb39ac3d643d0bd6a3. Grants restated exactly as s100 set them (ML-21).

begin;

-- 1. the sweep ---------------------------------------------------------------------------------------------------------------------------------------
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
  v_date date;
  v_guest uuid;
  v_note text;
begin
  for t in
    select f.id, f.property_id, f.source_kind, f.source_ref
      from public.follow_up_tasks f
     where f.status = 'open'
       and f.idempotency_key like 'system:%'
       and f.source_kind in ('guest_details', 'missed_cleaning', 'meter_no_photo', 'meter_estimate_waiting')
  loop
    v_note := null;
    -- a ref that does not parse (or is not a real date) is skipped, never an error
    begin
      if t.source_kind = 'guest_details' then
        if t.source_ref ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
          v_date := split_part(t.source_ref, ':', 1)::date;
          v_guest := split_part(t.source_ref, ':', 2)::uuid;
          if not exists (select 1 from public.guests_missing_details_v1(array[v_guest])) then
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
                      where cs.property_id = t.property_id and cs.checkout_date = v_date) then
            v_note := 'Closed automatically: the cleaning report for this checkout is now on file.';
          elsif not exists (select 1 from public.calendar_events ce
                             where ce.property_id = t.property_id and ce.status = 'confirmed' and ce.checkout_date = v_date) then
            v_note := 'Closed automatically: no confirmed stay checks out on this day any more.';
          end if;
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
    exception when others then
      v_note := null;
    end;

    if v_note is not null then
      update public.follow_up_tasks
         set status = 'done', completed_at = now(), completion_note = v_note
       where id = t.id and status = 'open';
      if t.source_kind = 'guest_details' then v_gd := v_gd + 1;
      elsif t.source_kind = 'missed_cleaning' then v_mc := v_mc + 1;
      else v_me := v_me + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('guest_details', v_gd, 'missed_cleaning', v_mc, 'meter', v_me);
end;
$function$;

revoke all on function public.system_tasks_sweep_v1() from public, anon, authenticated, service_role;
comment on function public.system_tasks_sweep_v1() is
  's102: closes open system tasks (guest_details, missed_cleaning, meter_no_photo, meter_estimate_waiting) whose problem is gone. Hourly cron system-tasks-sweep as postgres; no grants.';

-- 2. cron: system-tasks-sweep at minute 50 every hour (no-op where pg_cron is absent) -------------------------------------------------------------------
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron absent (rehearsal copy) - system-tasks-sweep wiring skipped';
    return;
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'system-tasks-sweep';
  perform cron.schedule('system-tasks-sweep', '50 * * * *', $cmd$select public.system_tasks_sweep_v1();$cmd$);
  if (select count(*) from cron.job where jobname = 'system-tasks-sweep' and active and schedule = '50 * * * *'
        and command like '%system_tasks_sweep_v1%') <> 1 then
    raise exception 'system-tasks-sweep not scheduled';
  end if;
end $$;

-- 3. meter_settle_estimates_v1: the live body, B also counts an admin-answered mismatch ----------------------------------------------------------------
-- Guarded: replaces ONLY the live s100 body (md5 of prosrc, CR stripped) or this release's own body on a re-run; 55000 if it changed since.
do $g$
declare v_src text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.meter_settle_estimates_v1(uuid)');
  if md5(v_src) is distinct from 'e3eaf07237d1fdfb39ac3d643d0bd6a3' and position('mr.vision_resolved_at is not null' in coalesce(v_src, '')) = 0 then
    raise exception 's102: public.meter_settle_estimates_v1 is not the body this release was cut from (md5 %)', md5(v_src) using errcode = '55000';
  end if;
end $g$;

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
         where mr.property_id = v_prop and cs.checkout_date = v_b_stay and mr.meter_flag is null and (mr.vision_verdict = 'ok' or (mr.vision_verdict = 'mismatch' and mr.vision_resolved_at is not null))
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

revoke all on function public.meter_settle_estimates_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.meter_settle_estimates_v1(uuid) to service_role;
comment on function public.meter_settle_estimates_v1(uuid) is
  'D-352: settles estimate_pending readings once the next stay has a verified reading: typed kept if in order, else a per-night average. Idempotent. service_role only (cron meter-settle-estimates).';

-- 4. final check ---------------------------------------------------------------------------------------------------------------------------------------
do $$
begin
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('system_tasks_sweep_v1', 'meter_settle_estimates_v1')) <> 2 then
    raise exception 's102: a function is missing or has more than one overload';
  end if;
  if position('vision_resolved_at is not null' in (select prosrc from pg_proc where oid = 'public.meter_settle_estimates_v1(uuid)'::regprocedure)) = 0 then
    raise exception 's102: meter_settle_estimates_v1 lacks the answered-mismatch rule';
  end if;
  if has_function_privilege('anon', 'public.system_tasks_sweep_v1()', 'execute')
     or has_function_privilege('authenticated', 'public.system_tasks_sweep_v1()', 'execute')
     or has_function_privilege('service_role', 'public.system_tasks_sweep_v1()', 'execute')
     or has_function_privilege('authenticated', 'public.meter_settle_estimates_v1(uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.meter_settle_estimates_v1(uuid)', 'execute') then
    raise exception 's102: a grant is not as intended';
  end if;
end $$;

commit;
