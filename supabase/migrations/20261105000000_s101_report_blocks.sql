-- 20261105000000_s101_report_blocks.sql
-- Cascade Hideaway - s101: the "Cleaning reports on hold" admin card, database half (contract: docs/s101/CONTRACT-report-blocks.md).
--
-- Why. Honey's turnover report was refused by submit-cleaning (409 meter_followup_unresolved) because an unresolved meter photo mismatch was still on file
-- (reading 4292 kWh / 81.852 m3 typed; the photo reader returned 431.2 / 806, two decimal misreads; the photo shows about 4312 / 80.7). The only way out was the
-- cleaner's own sign-in notice. An admin needs to see every report on hold and clear it from the dashboard.
--
-- What holds a report: a meter_readings row of the property with vision_verdict = 'mismatch', vision_resolved_at is null and recorded_at within 14 days
-- (submit-cleaning index.ts, METER_BLOCKING_TYPES). Clearing = setting vision_resolved_at / _by / _note, exactly as resolve_meter_followup_v1 does.
--
-- Two new functions, additive only (no column, table, trigger or cron change):
--  (1) public.admin_report_blocks_v1(property, lookback): the held readings, newest first, with the photo reader's numbers, notes and photo paths.
--      Gate inspect_cleaning, the same as the answer (admins, owner and inspector; never cleaners).
--  (2) public.admin_resolve_report_block_v1(reading, action, electric, water, note): 'typed_is_right' clears the block; 'correct_numbers' replaces the typed
--      numbers (never below the previous reading, never above the next stay's reading: D-219; refused on a row already flagged misread / re_entry / duplicate), recomputes this row's usage and re-points the next stay's usage
--      EXACTLY as submit-cleaning does (_shared/meter-order.ts repointNext, index.ts delta lines), then clears the block. Gate inspect_cleaning (the capability
--      admin_table_action_v1 names for meter_readings, used by review_meter_reading_v1). The write is audited by the existing admin_audit_row trigger on
--      meter_readings (reason set through admin_audit_context_v1), so it shows in Settings -> Audit history.
--
-- Grants are restated in full for both functions (ML-21): the rehearsal restore is --no-acl, production has default privileges.

begin;

-- 1. the list ------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.admin_report_blocks_v1(
  p_property_id uuid    default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid,
  p_lookback    integer default 14
)
returns table (
  reading_id          uuid,
  session_id          uuid,
  cleaner_name        text,
  checkout_date       date,
  recorded_at         timestamptz,
  typed_electric      numeric,
  typed_water         numeric,
  prev_electric       numeric,
  prev_water          numeric,
  photo_electric      numeric,
  photo_water         numeric,
  photo_note_electric text,
  photo_note_water    text,
  photo_path_electric text,
  photo_path_water    text
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
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
    nullif(mr.vision_raw -> 'paths' ->> 'water', '')
  from public.meter_readings mr
  left join public.cleaning_sessions cs on cs.id = mr.session_id
  where mr.property_id = p_property_id
    and mr.vision_verdict = 'mismatch'
    and mr.vision_resolved_at is null
    and mr.recorded_at >= (now() - make_interval(days => greatest(coalesce(p_lookback, 14), 1)))
  order by mr.recorded_at desc, mr.id;
end;
$function$;

-- 2. the answer ----------------------------------------------------------------------------------------------------------------------------------
create or replace function public.admin_resolve_report_block_v1(
  p_reading_id uuid,
  p_action     text,
  p_electric   numeric default null,
  p_water      numeric default null,
  p_note       text    default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
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
    raise exception 'That reading was not found.' using errcode = '22023';
  end if;
  perform public.admin_require('inspect_cleaning', v_prop);

  select mr.id, mr.property_id, mr.meter_flag, mr.vision_verdict, mr.vision_resolved_at, mr.recorded_at,
         mr.electric_prev, mr.water_prev, cs.checkout_date, cs.nights_stayed
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
  if v_r.vision_verdict is distinct from 'mismatch' then
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
  -- or estimate_pending (no photo) are never neighbours.
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
   where x.k > v_key
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
   where x.k > v_key
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
$function$;

-- 3. grants (ML-21: restated in full) ------------------------------------------------------------------------------------------------------------
revoke all on function public.admin_report_blocks_v1(uuid, integer) from public, anon, authenticated, service_role;
revoke all on function public.admin_resolve_report_block_v1(uuid, text, numeric, numeric, text) from public, anon, authenticated, service_role;
grant execute on function public.admin_report_blocks_v1(uuid, integer) to authenticated;
grant execute on function public.admin_resolve_report_block_v1(uuid, text, numeric, numeric, text) to authenticated;

comment on function public.admin_report_blocks_v1(uuid, integer) is
  's101: the meter photo mismatches that hold up the next cleaning report (unresolved, within the lookback), newest first, with the photo reader numbers, notes and photo paths. inspect_cleaning.';
comment on function public.admin_resolve_report_block_v1(uuid, text, numeric, numeric, text) is
  's101: clear a held cleaning report. typed_is_right confirms the typed numbers; correct_numbers replaces them (never backwards: D-219), recomputes usage and re-points the next stay as submit-cleaning does. inspect_cleaning; audited.';

-- 4. in-migration check (a failed assert rolls the whole migration back) ------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.admin_report_blocks_v1(uuid,integer)') is null
     or to_regprocedure('public.admin_resolve_report_block_v1(uuid,text,numeric,numeric,text)') is null then
    raise exception 's101: a function is missing';
  end if;
  if has_function_privilege('anon', 'public.admin_report_blocks_v1(uuid,integer)', 'execute')
     or has_function_privilege('anon', 'public.admin_resolve_report_block_v1(uuid,text,numeric,numeric,text)', 'execute')
     or has_function_privilege('service_role', 'public.admin_report_blocks_v1(uuid,integer)', 'execute')
     or has_function_privilege('service_role', 'public.admin_resolve_report_block_v1(uuid,text,numeric,numeric,text)', 'execute') then
    raise exception 's101: a grant is wider than intended';
  end if;
end $$;

commit;