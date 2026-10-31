-- Compensating rollback for release s102_task_sweep_20261106 (migration 20261106000000_s102_task_sweep.sql).
-- Unschedules the hourly sweep, drops system_tasks_sweep_v1 and restores the LIVE meter_settle_estimates_v1 body verbatim
-- (md5(replace(prosrc, chr(13), '')) = e3eaf07237d1fdfb39ac3d643d0bd6a3). NOT undone: tasks the sweep already closed stay done (reopen by hand from Follow-ups if one was wrong).
-- Apply with run-sql-on-host.sh.

begin;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.unschedule(jobid) from cron.job where jobname = 'system-tasks-sweep';
  end if;
end $$;

drop function if exists public.system_tasks_sweep_v1();

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
         where mr.property_id = v_prop and cs.checkout_date = v_b_stay and mr.meter_flag is null and mr.vision_verdict = 'ok'
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

commit;
