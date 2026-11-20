-- Session 127, lane A (SQL): release s127_utility_bills_20261127. Contract: docs/s127/CONTRACT.md "Facts" and "Lane A". Utility bills, usage tracking and the Today bills card.
--
--   app_settings 'utility_billing'              inserted only when absent (electric cycle day and fixed charge, water minimum, tiers and source url). Every function below reads it and falls
--                                                back to the same defaults (utility_billing_default_v1, one copy).
--   utility_bill_estimate_v1(uuid, date)        internal. The electricity and water bill of the cycle that contains p_on: so far, forecast, per day. Cycles run 21st to 21st and a cycle that ends on
--                                                21 Nov is billed at the November rate. A cycle is (cycle_from, cycle_to]: a reading checked out ON the 21st closes the cycle ending that day,
--                                                so 20 and 21 Nov belong to the cycle ending 21 Nov and 22 Nov starts the next one. Counted readings = public.meter_chain_v1 chain_ok rows (s115, the one rule).
--   today_bills_v1(uuid)                        every active staff role of the property (read_operations, the same gate as kpi_tab_v1 non-admin); anyone else 42501. so-far figures only.
--   kpi_tab_v1(uuid, date)                      the s115 body plus three statements: utility.usage_months (no money), admin.bills / rate_year_avg / rate_history / water_rate / stays and admin.rate.checked_at
--                                                (read_finance only). Every existing key, grant, security setting and search_path is unchanged.
--   internal helpers                            utility_billing_default_v1, utility_cfg_num_v1, utility_billing_cfg_v1 (never raises: a key of the wrong JSON type falls back to its default), utility_cycle_day_v1 + utility_cycle_v1
--                                                (the cycle day is clamped per month to that month's last day), utility_rate_by_month_v1 (the ONE rate precedence: manual before auto, then newest, one rate per month, same order
--                                                as the inline ordering in kpi_tab_v1; rows dated after Manila today are never read), utility_daily_use_v1 (THE per-day use rule: a counted reading's delta is spread evenly over the
--                                                days after the previous counted reading up to its own day; cycles, usage_months and the per-night figures all read it), utility_water_php_v1, utility_water_next_v1,
--                                                kpi_usage_months_v1 (with guest_nights and per-night figures from confirmed calendar_events), kpi_admin_bills_v1.
-- Money rule: the new peso keys exist only under admin (kpi_tab_v1, read_finance) and in today_bills_v1 (Lloyd approved the Today card for every signed-in staff account). No phone, e-mail or ID number in any payload.
-- app_settings has an anon read policy for keys that do not look secret: 'utility_billing' holds only the public Gensan Water District tariff and the fixed charge.
-- Guard (55000, nothing changes): the live kpi_tab_v1 must be the s115 body or this release (md5 of prosrc, CR stripped). Grants restated (ML-21).
-- Rollback: supabase/rollbacks/20261127_s127_utility_bills.sql (puts the s115 body back and drops the new functions and the settings row).

begin;

-- 1. guard ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
do $g$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.kpi_tab_v1(uuid,date)');
  if v is distinct from '229c75a34209e1820c3e0209e8d67adf' and v is distinct from '80efd89e916bcd6107c681baf86f143f' then
    raise exception using errcode = '55000', message = 's127: public.kpi_tab_v1(uuid,date) is neither the s115 body nor this release (md5 ' || coalesce(v, 'null') || '): re-cut it from the live body';
  end if;
end $g$;

-- 2. settings and helpers ---------------------------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.utility_billing_default_v1()
returns jsonb language sql immutable set search_path = '' as $$
  select '{"electric":{"cycle_day":21,"fixed_php":5.60},"water":{"cycle_day":21,"min_php":212,"min_m3":10,"tiers":[{"upto":20,"php":23.05},{"upto":30,"php":26.65},{"upto":40,"php":30.50},{"upto":null,"php":34.50}],"source_url":"https://gensanwater.gov.ph/water-rates/"}}'::jsonb;
$$;

insert into public.app_settings(key, value)
select 'utility_billing', public.utility_billing_default_v1()
 where not exists (select 1 from public.app_settings a where a.key = 'utility_billing');

-- one numeric setting: a JSON number that is not negative, else the default for that key (a setting of the wrong type never raises)
create or replace function public.utility_cfg_num_v1(p_val jsonb, p_default jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p_val) = 'number' and p_val::numeric >= 0 then p_val else p_default end;
$$;

-- the stored setting wins key by key; a key of the wrong JSON type (or a setting that is not an object, or a tiers list that is not a list of {upto number|null, php number}) falls back to the default for that key.
-- A cycle day is held to 1..31 and cut to a whole number. This function never raises.
create or replace function public.utility_billing_cfg_v1()
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'electric', jsonb_build_object(
      'cycle_day', case when jsonb_typeof(s.v #> '{electric,cycle_day}') = 'number' then to_jsonb(least(31, greatest(1, trunc((s.v #> '{electric,cycle_day}')::numeric)))) else d.v #> '{electric,cycle_day}' end,
      'fixed_php', public.utility_cfg_num_v1(s.v #> '{electric,fixed_php}', d.v #> '{electric,fixed_php}')),
    'water', jsonb_build_object(
      'cycle_day', case when jsonb_typeof(s.v #> '{water,cycle_day}') = 'number' then to_jsonb(least(31, greatest(1, trunc((s.v #> '{water,cycle_day}')::numeric)))) else d.v #> '{water,cycle_day}' end,
      'min_php', public.utility_cfg_num_v1(s.v #> '{water,min_php}', d.v #> '{water,min_php}'),
      'min_m3', public.utility_cfg_num_v1(s.v #> '{water,min_m3}', d.v #> '{water,min_m3}'),
      'tiers', case when case when jsonb_typeof(s.v #> '{water,tiers}') = 'array'
                              then jsonb_array_length(s.v #> '{water,tiers}') > 0
                                   and not exists (select 1 from jsonb_array_elements(s.v #> '{water,tiers}') e
                                                    where case when jsonb_typeof(e) <> 'object' then true
                                                               when jsonb_typeof(e -> 'php') is distinct from 'number' then true
                                                               when (e -> 'php')::numeric < 0 then true
                                                               when coalesce(jsonb_typeof(e -> 'upto'), 'null') not in ('number', 'null') then true
                                                               else false end)
                              else false end
                    then s.v #> '{water,tiers}' else d.v #> '{water,tiers}' end,
      'source_url', case when jsonb_typeof(s.v #> '{water,source_url}') = 'string' then s.v #> '{water,source_url}' else d.v #> '{water,source_url}' end))
    from (select public.utility_billing_default_v1() v) d,
         (select coalesce((select a.value from public.app_settings a where a.key = 'utility_billing' and jsonb_typeof(a.value) = 'object'), '{}'::jsonb) v) s;
$$;

-- the cycle day of the month that starts on p_month, held to that month's last day (day 31 in February is the 28th or 29th)
create or replace function public.utility_cycle_day_v1(p_month date, p_day integer)
returns date language sql immutable set search_path = '' as $$
  select p_month + (least(greatest(1, p_day), (p_month + interval '1 month')::date - p_month) - 1);
$$;

-- the cycle (from, to] that contains p_on: to = the first cycle day on or after p_on; from = the cycle day of the month before. Each month clamps the cycle day to its own last day.
create or replace function public.utility_cycle_v1(p_on date, p_day integer)
returns date[] language sql immutable set search_path = '' as $$
  select array[public.utility_cycle_day_v1((y.mt - interval '1 month')::date, p_day), public.utility_cycle_day_v1(y.mt, p_day)]
    from (select case when p_on <= public.utility_cycle_day_v1(date_trunc('month', p_on)::date, p_day) then date_trunc('month', p_on)::date
                      else (date_trunc('month', p_on) + interval '1 month')::date end mt) y;
$$;

-- the ONE rate per calendar month: manual before auto, then the newest (the same order kpi_tab_v1 uses to pick the rate in force). A row dated after Manila today is not in force yet and is never read.
create or replace function public.utility_rate_by_month_v1()
returns table(rate_month date, php_per_kwh numeric, source text, source_url text, effective_from date)
language sql stable set search_path = '' as $$
  select distinct on (date_trunc('month', r.effective_from)) date_trunc('month', r.effective_from)::date, r.php_per_kwh, r.source, r.source_url, r.effective_from
    from public.utility_rates r
   where r.effective_from <= public.manila_today()
   order by date_trunc('month', r.effective_from), (r.source = 'manual') desc, r.effective_from desc, r.created_at desc;
$$;

-- THE use-per-day rule (one place). A counted reading (public.meter_chain_v1 chain_ok, the s115 rule) spreads its delta evenly over the days after the previous counted reading's day up to and including its own day;
-- a reading with no previous counted reading, or one that is not later than the previous one, lands on its own day only. Returns the days of p_from..p_to that a reading covers, with that day's share.
create or replace function public.utility_daily_use_v1(p_property_id uuid, p_from date, p_to date)
returns table(d date, kwh numeric, m3 numeric)
language sql stable set search_path = '' as $$
  with s as (
    select m.cd, m.electric_delta e, m.water_delta w, case when m.pcd is null or m.cd <= m.pcd then m.cd else m.pcd + 1 end st
      from public.meter_chain_v1(p_property_id) m where m.chain_ok)
  select s.st + k, sum(s.e / (s.cd - s.st + 1)), sum(s.w / (s.cd - s.st + 1))
    from s cross join lateral generate_series(greatest(s.st, p_from) - s.st, least(s.cd, p_to) - s.st) k
   group by 1;
$$;

-- water peso for p_m3 under the tariff: the minimum covers 0..min_m3, then each tier charges its rate for the cubic metres inside it. Never below min_php.
create or replace function public.utility_water_php_v1(p_m3 numeric, p_cfg jsonb)
returns numeric language sql immutable set search_path = '' as $$
  select round((p_cfg -> 'water' ->> 'min_php')::numeric
               + coalesce(sum(greatest(0, least(p_m3, coalesce(t.upto, p_m3)) - t.lo) * t.php), 0), 2)
    from (select (e.value ->> 'upto')::numeric upto, (e.value ->> 'php')::numeric php,
                 coalesce(lag((e.value ->> 'upto')::numeric) over (order by e.ord), (p_cfg -> 'water' ->> 'min_m3')::numeric) lo
            from jsonb_array_elements(p_cfg -> 'water' -> 'tiers') with ordinality e(value, ord)) t;
$$;

-- the tier the next cubic metre is charged at: {php, upto} (upto null = no ceiling); the minimum is used up first
create or replace function public.utility_water_next_v1(p_m3 numeric, p_cfg jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object('php', (e.value ->> 'php')::numeric, 'upto', (e.value ->> 'upto')::numeric)
    from jsonb_array_elements(p_cfg -> 'water' -> 'tiers') with ordinality e(value, ord)
   where (e.value ->> 'upto') is null or (e.value ->> 'upto')::numeric > greatest(coalesce(p_m3, 0), (p_cfg -> 'water' ->> 'min_m3')::numeric)
   order by e.ord limit 1;
$$;

-- 3. utility_bill_estimate_v1 ---------------------------------------------------------------------------------------------------------------------------------------------------------
-- Use is read per day from utility_daily_use_v1: the cycle takes only the share of each reading's days that fall in (cycle_from, cycle_to]. days = cycle_from to the last day a counted reading covers inside the cycle.
create or replace function public.utility_bill_estimate_v1(p_property_id uuid, p_on date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_cfg jsonb := public.utility_billing_cfg_v1();
  v_ec date[] := public.utility_cycle_v1(p_on, (v_cfg -> 'electric' ->> 'cycle_day')::integer);
  v_wc date[] := public.utility_cycle_v1(p_on, (v_cfg -> 'water' ->> 'cycle_day')::integer);
  v_fixed numeric := (v_cfg -> 'electric' ->> 'fixed_php')::numeric;
  v_kwh numeric; v_elast date; v_eat timestamptz; v_ed integer; v_edc integer := v_ec[2] - v_ec[1]; v_rate numeric;
  v_fk numeric; v_pdk numeric;
  v_m3 numeric; v_wlast date; v_wd integer; v_wdc integer := v_wc[2] - v_wc[1]; v_fm numeric; v_pdm numeric; v_next jsonb;
begin
  select coalesce(sum(u.kwh), 0), max(u.d) into v_kwh, v_elast from public.utility_daily_use_v1(p_property_id, v_ec[1] + 1, v_ec[2]) u;
  select m.recorded_at into v_eat
    from public.meter_chain_v1(p_property_id) m where m.chain_ok and m.cd > v_ec[1] and m.cd <= v_ec[2]
   order by m.cd desc, m.recorded_at desc, m.id desc limit 1;
  v_ed := coalesce(v_elast - v_ec[1], 0);
  -- the billed month is the month the cycle ends in; no rate for it yet = the latest earlier rate, null only while no rate exists at all (rates dated after today are never read)
  select r.php_per_kwh into v_rate from public.utility_rate_by_month_v1() r where r.rate_month <= date_trunc('month', v_ec[2])::date order by r.rate_month desc limit 1;
  if v_ed > 0 then v_pdk := v_kwh / v_ed; v_fk := v_pdk * v_edc; end if;

  select coalesce(sum(u.m3), 0), max(u.d) into v_m3, v_wlast from public.utility_daily_use_v1(p_property_id, v_wc[1] + 1, v_wc[2]) u;
  v_wd := coalesce(v_wlast - v_wc[1], 0);
  if v_wd > 0 then v_pdm := v_m3 / v_wd; v_fm := v_pdm * v_wdc; end if;
  v_next := public.utility_water_next_v1(v_m3, v_cfg);

  return jsonb_build_object(
    'electric', jsonb_build_object(
      'cycle_from', v_ec[1], 'cycle_to', v_ec[2], 'days', v_ed, 'days_in_cycle', v_edc, 'kwh', round(v_kwh, 2), 'rate', v_rate, 'fixed_php', v_fixed,
      'so_far_php', case when v_rate is not null then round(v_kwh * v_rate + v_fixed, 2) end,
      'forecast_kwh', case when v_ed > 0 then round(v_fk, 2) end,
      'forecast_php', case when v_ed > 0 and v_rate is not null then round(v_fk * v_rate + v_fixed, 2) end,
      'per_day_kwh', case when v_ed > 0 then round(v_pdk, 2) end,
      'per_day_php', case when v_ed > 0 and v_rate is not null then round(v_pdk * v_rate, 2) end,
      'last_reading_at', v_eat),
    'water', jsonb_build_object(
      'cycle_from', v_wc[1], 'cycle_to', v_wc[2], 'days', v_wd, 'm3', round(v_m3, 2),
      'so_far_php', public.utility_water_php_v1(v_m3, v_cfg),
      'forecast_m3', case when v_wd > 0 then round(v_fm, 2) end,
      'forecast_php', case when v_wd > 0 then public.utility_water_php_v1(v_fm, v_cfg) end,
      'per_day_m3', case when v_wd > 0 then round(v_pdm, 2) end,
      'min_php', (v_cfg -> 'water' ->> 'min_php')::numeric, 'min_m3', (v_cfg -> 'water' ->> 'min_m3')::numeric,
      'next_php', v_next -> 'php', 'next_upto', v_next -> 'upto'));
end;
$$;

-- 4. today_bills_v1 ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.today_bills_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  if auth.uid() is null or p_property_id is null or not public.current_staff_authorized('read_operations', p_property_id) then
    raise exception using errcode = '42501', message = 'not authorized';
  end if;
  v := public.utility_bill_estimate_v1(p_property_id, public.manila_today());
  return jsonb_build_object(
    'since', (v -> 'electric' ->> 'cycle_from')::date,
    'last_reading_at', v -> 'electric' -> 'last_reading_at',
    'electric', jsonb_build_object('php', v -> 'electric' -> 'so_far_php', 'kwh', v -> 'electric' -> 'kwh'),
    'water', jsonb_build_object('php', v -> 'water' -> 'so_far_php', 'm3', v -> 'water' -> 'm3'));
end;
$$;

-- 5. utility.usage_months (no money) ------------------------------------------------------------------------------------------------------------------------------------------------
-- kwh / m3 of a month = that month's share of the per-day use (utility_daily_use_v1); the current month is the share so far, forecast = so far / days elapsed x days in the month.
-- guest_nights = days of the month (up to p_today) inside a confirmed calendar_events stay: checkin_date <= day < checkout_date; blocked and cancelled rows never count. Per night = month use / guest nights
-- (the current month: so far / guest nights so far, never the forecast), null at zero nights. Changes are against the previous month that has a value, from the unrounded figures.
create or replace function public.kpi_usage_months_v1(p_property_id uuid, p_today date)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  v_cur date := date_trunc('month', p_today)::date;
  v_dim integer := ((v_cur + interval '1 month')::date - v_cur);
  v_el integer := extract(day from p_today)::integer;
  v_out jsonb;
begin
  with g as (select (v_cur - (k * interval '1 month'))::date m from generate_series(0, 5) k),
  u as (select x.d, x.kwh, x.m3 from public.utility_daily_use_v1(p_property_id, (v_cur - interval '5 months')::date, p_today) x),
  a as (select g.m, (select count(*) from u where date_trunc('month', u.d)::date = g.m) n,
               (select sum(u.kwh) from u where date_trunc('month', u.d)::date = g.m) e, (select sum(u.m3) from u where date_trunc('month', u.d)::date = g.m) w,
               (select count(*) from generate_series(0, least(((g.m + interval '1 month')::date - 1), p_today) - g.m) k
                 where exists (select 1 from public.calendar_events ce where ce.property_id = p_property_id and ce.status = 'confirmed'
                                  and ce.checkin_date <= g.m + k and g.m + k < ce.checkout_date))::integer gn
          from g),
  v as (select a.m, (a.m = v_cur) as is_cur, a.n, a.e, a.w, a.gn,
               case when a.n = 0 then null when a.m = v_cur then round(a.e / v_el * v_dim, 2) else round(a.e, 2) end kwh,
               case when a.n = 0 then null when a.m = v_cur then round(a.w / v_el * v_dim, 2) else round(a.w, 2) end m3,
               case when a.n > 0 and a.gn > 0 then a.e / a.gn end pke,
               case when a.n > 0 and a.gn > 0 then a.w / a.gn end pkw
          from a)
  select jsonb_agg(jsonb_build_object(
           'month', to_char(v.m, 'YYYY-MM'), 'kwh', v.kwh, 'm3', v.m3,
           'kwh_change_pct', case when v.kwh is not null and pk.kwh > 0 then round((v.kwh - pk.kwh) / pk.kwh * 100) end,
           'm3_change_pct',  case when v.m3 is not null and pm.m3 > 0 then round((v.m3 - pm.m3) / pm.m3 * 100) end,
           'forecast', v.is_cur,
           'kwh_so_far', case when v.is_cur and v.n > 0 then round(v.e, 2) end,
           'm3_so_far',  case when v.is_cur and v.n > 0 then round(v.w, 2) end,
           'guest_nights', v.gn,
           'kwh_per_night', round(v.pke, 1), 'm3_per_night', round(v.pkw, 2),
           'kwh_night_change_pct', case when v.pke is not null and pe.pke > 0 then round((v.pke - pe.pke) / pe.pke * 100) end,
           'm3_night_change_pct',  case when v.pkw is not null and pw.pkw > 0 then round((v.pkw - pw.pkw) / pw.pkw * 100) end) order by v.m)
    into v_out
    from v
    left join lateral (select x.kwh from v x where x.m < v.m and x.kwh is not null order by x.m desc limit 1) pk on true
    left join lateral (select x.m3 from v x where x.m < v.m and x.m3 is not null order by x.m desc limit 1) pm on true
    left join lateral (select x.pke from v x where x.m < v.m and x.pke is not null order by x.m desc limit 1) pe on true
    left join lateral (select x.pkw from v x where x.m < v.m and x.pkw is not null order by x.m desc limit 1) pw on true;
  return v_out;
end;
$$;

-- 6. admin.bills, rate_year_avg, rate_history, water_rate, stays (read_finance only, called from kpi_tab_v1) ---------------------------------------------------------------------------
-- The guest of a stay and the ID photo fields are resolved exactly as staff_home_v1 / staff_guest_card_v1 do: staff_stay_guest_id_v1 on the confirmed calendar stay that checks out on the
-- reading's checkout day (cd = the cleaning session's checkout date when the reading has a session, so that is the event preferred; a reading with no session and no event that checks out that day is no stay),
-- from / to / nights are the event's check-in, check-out and nights (a session reading with no event falls back to the previous counted reading's day), then staff_primary_id_path_v1 and the id_face_box of that companion row, behind staff_may_see_guest_id_v1 (20261115000000_s116_guest_photo_name.sql lines 53-57).
create or replace function public.kpi_admin_bills_v1(p_property_id uuid, p_rate numeric)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  v_today date := public.manila_today(); v_cfg jsonb := public.utility_billing_cfg_v1(); v_cm date := date_trunc('month', public.manila_today())::date;
  v_n jsonb := public.utility_water_next_v1(0, v_cfg); v_out jsonb;
begin
  with rbm as (select r.rate_month, r.php_per_kwh from public.utility_rate_by_month_v1() r where r.rate_month <= v_cm),
  ch as (select x.rate_month, x.php_per_kwh,
                case when lag(x.php_per_kwh) over w > 0 then round((x.php_per_kwh - lag(x.php_per_kwh) over w) / lag(x.php_per_kwh) over w * 100, 1) end chg
           from rbm x window w as (order by x.rate_month)),
  sy as (
    select c.id, c.cd, c.recorded_at,
           jsonb_build_object(
             'from', coalesce(e.checkin_date, c.pcd, c.cd), 'to', coalesce(e.checkout_date, c.cd),
             'nights', case when e.uid is not null then e.checkout_date - e.checkin_date when c.pcd is not null then greatest(1, c.cd - c.pcd) end,
             'kwh', c.electric_delta, 'm3', round(c.water_delta, 2),
             'cost_php', case when p_rate is not null then round(c.electric_delta * p_rate, 2) end,
             'guest_name', coalesce(public.staff_redact_v1(nullif(btrim(g.name), '')), public.staff_redact_v1(nullif(btrim(e.guest_name), ''))),
             'tier', g.tier,
             'id_photo_path', case when g.id is not null and public.staff_may_see_guest_id_v1(p_property_id) then public.staff_primary_id_path_v1(g.id) end,
             'id_face_box', case when g.id is not null and public.staff_may_see_guest_id_v1(p_property_id)
                                 then (select cc.id_face_box from public.guest_companions cc where cc.guest_id = g.id and cc.id_photo_path = public.staff_primary_id_path_v1(g.id) limit 1) end) j
      from public.meter_chain_v1(p_property_id) c
      left join public.meter_readings mr on mr.id = c.id
      left join public.cleaning_sessions cs on cs.id = mr.session_id
      left join lateral (select ce.uid, ce.guest_name, ce.linked_reservation_id, ce.checkin_date, ce.checkout_date
                           from public.calendar_events ce
                          where ce.property_id = p_property_id and ce.status = 'confirmed' and ce.checkout_date = c.cd
                          order by ce.checkin_date desc, ce.uid limit 1) e on true
      left join public.guests g on e.uid is not null and g.property_id = p_property_id
        and g.id = public.staff_stay_guest_id_v1(p_property_id, e.uid, e.linked_reservation_id, e.checkin_date, e.checkout_date)
     where c.chain_ok and coalesce(cs.cleaning_type, 'checkout') <> 'mid_stay' and (e.uid is not null or c.checkout_date is not null)
     order by c.cd desc, c.recorded_at desc, c.id desc limit 5)
  select jsonb_build_object(
           'bills', public.utility_bill_estimate_v1(p_property_id, v_today),
           'rate_year_avg', (select round(avg(x.php_per_kwh), 2) from rbm x where x.rate_month >= date_trunc('year', v_today)::date),
           'rate_history', coalesce((select jsonb_agg(jsonb_build_object('month', to_char(h.rate_month, 'YYYY-MM'), 'php_per_kwh', h.php_per_kwh, 'change_pct', h.chg) order by h.rate_month desc)
                                       from (select * from ch order by rate_month desc limit 6) h), '[]'::jsonb),
           'water_rate', jsonb_build_object('min_php', (v_cfg -> 'water' ->> 'min_php')::numeric, 'min_m3', (v_cfg -> 'water' ->> 'min_m3')::numeric,
                                            'next_php', v_n -> 'php', 'next_upto', v_n -> 'upto', 'source_url', v_cfg -> 'water' ->> 'source_url'),
           'stays', coalesce((select jsonb_agg(sy.j order by sy.cd desc, sy.recorded_at desc, sy.id desc) from sy), '[]'::jsonb))
    into v_out;
  return v_out;
end;
$$;

-- 7. kpi_tab_v1: the s115 body plus three statements --------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.kpi_tab_v1(p_property_id uuid, p_month date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $body$
declare
  v_today date := public.manila_today(); v_m0 date; v_m1 date; v_fin boolean;
  v_kwh numeric; v_nights numeric; v_last jsonb; v_per jsonb; v_bo jsonb; v_wc jsonb; v_inv jsonb; v_out jsonb;
  v_turn integer; v_turn90 integer; v_rate public.utility_rates%rowtype; v_lastd numeric; v_usage_cost numeric; v_ic jsonb;
  v_fs jsonb; v_hm jsonb; v_sold numeric; v_dn numeric; v_mcost numeric;
  v_m3 numeric; v_kpd numeric; v_mpd numeric; v_pm jsonb; v_nb integer;
  v_tnet numeric; v_tat timestamptz; v_tby text; v_cb numeric; v_rn numeric; v_adr numeric;
  v_cset jsonb;
begin
  if auth.uid() is null or not public.current_staff_authorized('read_operations', p_property_id) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  v_fin := public.current_staff_authorized('read_finance', p_property_id);
  v_m0 := date_trunc('month', coalesce(p_month, v_today))::date;
  v_m1 := (v_m0 + interval '1 month')::date;

  -- s115 utility block (Lloyd 2026-11-11: one sharp day in the chart). The s111 days ran from the previous REPORT to this one, so late reports filed together gave a 2-night reading
  -- "1 day", and meter ranges that overlap counted one stretch of use twice. Now: the eligible readings (the s111 filters: both prev > 0, both deltas >= 0, flag null / typed_accepted / estimated)
  -- are ordered by their meter chain (electric_prev, checkout day, recorded_at, id) in public.meter_chain_v1, the one chain V23 also reads. cd = the checkout day of the reading's cleaning session, the recorded Manila day only when it has none.
  -- days = cd minus the previous eligible reading's cd, at least 1, null for the first. A reading whose electric_prev is not the previous eligible reading's electric_curr
  -- (an overlap or a gap) is left out of every figure here; V23 in run_system_verifier_v1 reports it. Months are the checkout month.
  with c as (
    select m.*, case when m.pcd is not null then greatest(1, m.cd - m.pcd) end days
      from public.meter_chain_v1(p_property_id) m where m.chain_ok
  )
  select (select coalesce(sum(c.electric_delta), 0) from c where c.cd >= v_m0 and c.cd < v_m1),
         (select coalesce(sum(c.water_delta), 0) from c where c.cd >= v_m0 and c.cd < v_m1),
         (select case when sum(c.days) > 0 then round(sum(c.electric_delta) filter (where c.days is not null) / sum(c.days), 2) end from c where c.cd >= v_m0 and c.cd < v_m1),
         (select case when sum(c.days) > 0 then round(sum(c.water_delta) filter (where c.days is not null) / sum(c.days), 2) end from c where c.cd >= v_m0 and c.cd < v_m1),
         (select jsonb_build_object('recorded_at', c.recorded_at, 'delta_kwh', c.electric_delta, 'days', c.days, 'kwh_per_day', round(c.electric_delta / c.days, 2),
                                    'delta_m3', c.water_delta, 'm3_per_day', round(c.water_delta / c.days, 2), 'flag', c.meter_flag)
            from c order by c.recorded_at desc, c.id limit 1),
         (select coalesce(jsonb_agg(jsonb_build_object('checkout_date', y.checkout_date, 'recorded_at', y.recorded_at, 'from', y.pcd, 'to', y.cd, 'days', y.days,
                                                       'kwh', y.electric_delta, 'kwh_per_day', round(y.electric_delta / y.days, 2),
                                                       'm3', y.water_delta, 'm3_per_day', round(y.water_delta / y.days, 2)) order by y.cd, y.recorded_at, y.id), '[]'::jsonb)
            from (select * from c order by c.cd desc, c.recorded_at desc, c.id desc limit 8) y),
         (select jsonb_agg(jsonb_build_object('month', to_char(g.m, 'YYYY-MM'), 'stays', coalesce(a.n, 0), 'kwh', round(a.e, 2), 'm3', round(a.w, 2),
                                              'kwh_per_stay', case when a.n > 0 then round(a.e / a.n, 1) end, 'm3_per_stay', case when a.n > 0 then round(a.w / a.n, 2) end,
                                              'kwh_per_day', case when a.dd > 0 then round(a.ed / a.dd, 2) end, 'm3_per_day', case when a.dd > 0 then round(a.wd / a.dd, 2) end) order by g.m)
            from (select (v_m0 - (k * interval '1 month'))::date m from generate_series(0, 11) k) g
            left join (select date_trunc('month', c.cd)::date m, count(*)::integer n, sum(c.electric_delta) e, sum(c.water_delta) w,
                              sum(c.electric_delta) filter (where c.days is not null) ed, sum(c.water_delta) filter (where c.days is not null) wd, sum(c.days) dd
                         from c where c.cd >= (v_m0 - interval '11 months')::date and c.cd < v_m1 group by 1) a on a.m = g.m),
         (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'cd', c.cd)), '[]'::jsonb) from c)
    into v_kwh, v_m3, v_kpd, v_mpd, v_last, v_per, v_pm, v_cset;
  v_lastd := (v_last ->> 'delta_kwh')::numeric;
  -- nights_booked: get_hospitality_metrics_v1 sold_nights replicated exactly (hospitality_metrics_core_v1 20261026010000 over admin_stays_v1 20261026000000):
  -- distinct nights of the month covered by a confirmed / completed stay. The core cannot be called here: admin_stays_v1 raises not_authorized for cleaner and laundry.
  select count(distinct d)::integer into v_nb
    from (select r.checkin_date ci, r.checkout_date co from public.airbnb_reservations r
           where r.property_id = p_property_id and r.checkin_date is not null and r.checkout_date is not null and r.source is distinct from 'direct'
             and r.status in ('confirmed', 'completed')
          union all
          select i.checkin_date, i.checkout_date from public.booking_inquiries i
           where i.property_id = p_property_id and i.status in ('confirmed', 'completed')) s
    cross join lateral generate_series(greatest(s.ci, v_m0), least(s.co, v_m1) - 1, interval '1 day') d
   where s.ci < v_m1 and s.co > v_m0;

  select jsonb_build_object('count', count(*), 'hours', coalesce(round(sum(n.duration_hours), 1), 0)) into v_bo
    from public.ops_notices n
   where n.property_id = p_property_id and n.notice_type = 'brownout' and n.is_active and n.effective_date >= v_m0 and n.effective_date < v_m1;
  select jsonb_build_object('count', count(*), 'hours', coalesce(round(sum(n.duration_hours), 1), 0)) into v_wc
    from public.ops_notices n
   where n.property_id = p_property_id and n.notice_type = 'water' and n.is_active and n.effective_date >= v_m0 and n.effective_date < v_m1;

  -- internet: the same rule as lib.js isInternetNotice (an internet word AND an outage word in the title or text of a note / maintenance notice)
  select jsonb_build_object('count', count(*), 'hours', coalesce(round(sum(n.duration_hours), 1), 0)) into v_ic
    from public.ops_notices n
   where n.property_id = p_property_id and n.notice_type in ('note', 'maintenance') and n.is_active and n.effective_date >= v_m0 and n.effective_date < v_m1
     and lower(coalesce(n.title, '') || ' ' || coalesce(n.description, '')) ~ '\m(internet|wi-?fi|fiber|fibre|pldt|converge|globe at home|sky ?fiber|modem|router)\M'
     and lower(coalesce(n.title, '') || ' ' || coalesce(n.description, '')) ~ '\m(no|down|outage|interrupt\w*|offline|maintenance|repair\w*|cut|walang|wala|mawawala|disconnect\w*)\M';

  select count(*) into v_turn from public.cleaning_sessions cs
   where cs.property_id = p_property_id and coalesce(cs.cleaning_type, 'turnover') in ('turnover', 'deep_clean')
     and (cs.cleaned_at at time zone 'Asia/Manila')::date >= v_m0 and (cs.cleaned_at at time zone 'Asia/Manila')::date < v_m1;
  select count(*) into v_turn90 from public.cleaning_sessions cs
   where cs.property_id = p_property_id and coalesce(cs.cleaning_type, 'turnover') in ('turnover', 'deep_clean')
     and (cs.cleaned_at at time zone 'Asia/Manila')::date > v_today - 90;

  select jsonb_build_object(
    'low_now', (select count(*) from public.inventory_items i where i.property_id = p_property_id and i.is_active and i.reorder_below is not null and i.qty_on_hand <= i.reorder_below),
    'restocks_month', (select count(*) from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
                        where i.property_id = p_property_id and p.purchased_at >= v_m0 and p.purchased_at < v_m1),
    'turnovers_month', v_turn,
    'per_turnover', coalesce((
      select jsonb_agg(jsonb_build_object('item_id', t.id, 'name', t.name, 'used_per_turnover', case when v_turn > 0 then round(t.used / v_turn, 2) end,
                                          'usual', case when v_turn90 > 0 then round(t.used90 / v_turn90, 2) end) order by t.used desc, t.name)
        from (select * from (
                select i.id, i.name, sum(u.used_qty) filter (where u.session_date >= v_m0 and u.session_date < v_m1) used,
                       sum(u.used_qty) filter (where u.session_date > v_today - 90) used90
                  from public.inventory_items i join public.inventory_usage u on u.item_id = i.id
                 where i.property_id = p_property_id and i.is_active and i.is_consumable group by i.id, i.name) z
               where z.used > 0 order by z.used desc, z.name limit 6) t), '[]'::jsonb),
    'runs_out', coalesce((
      select jsonb_agg(jsonb_build_object('item_id', r.id, 'name', r.name, 'days_left', r.days_left) order by r.days_left, r.name)
        from (select i.id, i.name, floor(i.qty_on_hand / (sum(u.used_qty) / 30.0))::integer days_left
                from public.inventory_items i join public.inventory_usage u on u.item_id = i.id
               where i.property_id = p_property_id and i.is_active and i.is_consumable and i.qty_on_hand is not null and i.qty_on_hand >= 0
                 and u.session_date > v_today - 30
               group by i.id, i.name, i.qty_on_hand having sum(u.used_qty) > 0 order by days_left, i.name limit 3) r), '[]'::jsonb))
    into v_inv;

  v_out := jsonb_build_object('ok', true, 'month', v_m0,
    'utility', jsonb_build_object('kwh_month', round(v_kwh, 2), 'kwh_per_day', v_kpd, 'm3_month', round(v_m3, 2), 'm3_per_day', v_mpd,
                                  'nights_booked', v_nb, 'nights_in_month', v_m1 - v_m0,
                                  'last_reading', v_last, 'per_stay', v_per, 'per_month', v_pm, 'brownouts', v_bo, 'water_cuts', v_wc, 'internet_cuts', v_ic),
    'inventory', v_inv);
  -- s127: the last 6 calendar months of counted kWh and m3 (no money, so outside admin)
  v_out := jsonb_set(v_out, '{utility,usage_months}', public.kpi_usage_months_v1(p_property_id, v_today));

  if v_fin then
    select * into v_rate from public.utility_rates r where r.effective_from <= v_today
     order by date_trunc('month', r.effective_from) desc, (r.source = 'manual') desc, r.effective_from desc, r.created_at desc limit 1;
    -- s115: the same counted readings as kwh_month (v_cset), each costed at the rate in force on its checkout day (latest month first, a manual correction beats an auto read of the same month)
    select sum(mr.electric_delta * rt.php_per_kwh) into v_mcost
      from jsonb_to_recordset(coalesce(v_cset, '[]'::jsonb)) x(id uuid, cd date)
      join public.meter_readings mr on mr.id = x.id
      cross join lateral (select r.php_per_kwh from public.utility_rates r where r.effective_from <= x.cd
                           order by date_trunc('month', r.effective_from) desc, (r.source = 'manual') desc, r.effective_from desc, r.created_at desc limit 1) rt
     where x.cd >= v_m0 and x.cd < v_m1;
    select coalesce(sum(u.used_qty * coalesce(i.unit_cost, 0)), 0) into v_usage_cost
      from public.inventory_usage u join public.inventory_items i on i.id = u.item_id
     where i.property_id = p_property_id and u.session_date >= v_m0 and u.session_date < v_m1;
    v_fs := public.get_finance_summary(v_m0, p_property_id);
    v_hm := public.hospitality_metrics_core_v1(p_property_id, v_m0, v_m1, true) -> 'metrics';
    v_sold := (v_hm -> 'sold_nights' ->> 'value')::numeric;
    select coalesce(sum(greatest(0, least(i.checkout_date, v_m1) - greatest(i.checkin_date, v_m0))), 0) into v_dn
      from public.booking_inquiries i
     where i.property_id = p_property_id and i.status in ('confirmed', 'completed') and coalesce(i.guest_name, '') !~* '^synthetic';
    v_out := v_out || jsonb_build_object('admin', jsonb_build_object(
      'revenue_month', (v_fs ->> 'income')::numeric, 'costs_month', (v_fs ->> 'expenses')::numeric, 'net_month', (v_fs ->> 'net')::numeric,
      'occupancy', case when (v_hm -> 'occupancy' ->> 'value') is not null then round((v_hm -> 'occupancy' ->> 'value')::numeric / 100, 4) end,
      'adr', (v_hm -> 'adr' ->> 'value')::numeric, 'sold_nights', v_sold, 'sellable_nights', (v_hm -> 'capacity_nights' ->> 'value')::numeric,
      'direct_share', case when v_sold > 0 then least(1, round(v_dn / v_sold, 4)) end,
      'rate', case when v_rate.id is null then null else jsonb_build_object('php_per_kwh', v_rate.php_per_kwh, 'effective_from', v_rate.effective_from,
                                                                            'source', v_rate.source, 'source_url', v_rate.source_url) end,
      'last_reading_cost', case when v_rate.id is not null and v_lastd is not null then round(v_lastd * v_rate.php_per_kwh, 2) end,
      'month_kwh_cost', case when v_rate.id is not null then round(coalesce(v_mcost, 0), 2) end,
      'supplies_month', (select coalesce(sum(p.qty * p.unit_cost), 0) from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
                          where i.property_id = p_property_id and p.purchased_at >= v_m0 and p.purchased_at < v_m1),
      'supply_cost_per_turnover', case when v_turn > 0 then round(v_usage_cost / v_turn, 2) end,
      'cleaning_pay_month', (select coalesce(sum(q.total_amount), 0) from public.staff_pay_requests q
                              where q.property_id = p_property_id and q.status in ('requested', 'paying', 'paid')
                                and (q.created_at at time zone 'Asia/Manila')::date >= v_m0 and (q.created_at at time zone 'Asia/Manila')::date < v_m1)));
    -- s111 admin.target. costs_basis = average get_finance_summary expenses of the 3 full months before the selected one, over the months that have any (null if none).
    -- nights_on_books = the core's sold_nights, which already counts every confirmed or completed night of the month, past and future. set_by = the setter's role.
    select t.monthly_net_target, t.set_at, p.role into v_tnet, v_tat, v_tby
      from public.kpi_targets t left join public.staff_access_profiles p on p.user_id = t.set_by
        and (p.role = 'owner' or exists (select 1 from public.staff_property_access s where s.user_id = p.user_id and s.property_id = t.property_id))
     where t.property_id = p_property_id;
    select round(avg(x.e), 2) into v_cb
      from (select (public.get_finance_summary((v_m0 - (k * interval '1 month'))::date, p_property_id) ->> 'expenses')::numeric e from generate_series(1, 3) k) x
     where x.e > 0;
    v_rn := v_cb + coalesce(v_tnet, 0);
    v_adr := (v_hm -> 'adr' ->> 'value')::numeric;
    v_out := jsonb_set(v_out, '{admin,target}', jsonb_build_object(
      'net_target', coalesce(v_tnet, 0), 'costs_basis', v_cb, 'revenue_needed', v_rn, 'adr', v_adr,
      'nights_in_month', v_m1 - v_m0, 'nights_on_books', v_sold,
      'needed_occupancy', case when v_adr > 0 and v_rn is not null then round(v_rn / (v_adr * (v_m1 - v_m0)), 4) end,
      'needed_adr', case when v_sold > 0 and v_rn is not null then round(v_rn / v_sold, 2) end,
      'set_by', v_tby, 'set_at', v_tat));
    -- s127: admin.bills, rate_year_avg, rate_history, water_rate, stays (read_finance only) and admin.rate.checked_at (only while a rate exists)
    v_out := jsonb_set(v_out, '{admin}', (v_out -> 'admin') || public.kpi_admin_bills_v1(p_property_id, v_rate.php_per_kwh));
    if v_rate.id is not null then
      v_out := jsonb_set(v_out, '{admin,rate,checked_at}', coalesce((select to_jsonb(s.value ->> 'checked_at') from public.app_settings s where s.key = 'power_watch_rate_day'), 'null'::jsonb));
    end if;
  end if;
  return v_out;
end;
$body$
;

-- 8. grants (ML-21): the internal helpers run for nobody but the owner and the definer functions above; today_bills_v1 for signed-in users only -----------------------------------------------------
revoke all on function public.utility_billing_default_v1() from public, anon, authenticated, service_role;
revoke all on function public.utility_cfg_num_v1(jsonb, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.utility_billing_cfg_v1() from public, anon, authenticated, service_role;
revoke all on function public.utility_cycle_day_v1(date, integer) from public, anon, authenticated, service_role;
revoke all on function public.utility_cycle_v1(date, integer) from public, anon, authenticated, service_role;
revoke all on function public.utility_daily_use_v1(uuid, date, date) from public, anon, authenticated, service_role;
revoke all on function public.utility_rate_by_month_v1() from public, anon, authenticated, service_role;
revoke all on function public.utility_water_php_v1(numeric, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.utility_water_next_v1(numeric, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.utility_bill_estimate_v1(uuid, date) from public, anon, authenticated, service_role;
revoke all on function public.kpi_usage_months_v1(uuid, date) from public, anon, authenticated, service_role;
revoke all on function public.kpi_admin_bills_v1(uuid, numeric) from public, anon, authenticated, service_role;
revoke all on function public.today_bills_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.today_bills_v1(uuid) to authenticated;
revoke all on function public.kpi_tab_v1(uuid,date) from public, anon, service_role;
grant execute on function public.kpi_tab_v1(uuid,date) to authenticated;

comment on function public.today_bills_v1(uuid) is 's127: the electricity and water bill so far for the Today tab. Every active staff role of the property (read_operations); anyone else 42501. Money by design (Lloyd 2026-11-20).';
comment on function public.utility_bill_estimate_v1(uuid, date) is 's127: internal. The cycle (from, to] that contains p_on: so far, forecast and per day for electricity (rate of the month the cycle ends in plus the fixed charge) and water (tiered tariff, never below the minimum). Counted readings = meter_chain_v1.';

commit;
