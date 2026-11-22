-- Session 131, lane S (SQL): release s131_meter_cycle_20261130. Contract: docs/s131/CONTRACT.md "Lane S" over docs/s131/PLAN.md (Lloyd 2026-11-22, D-393). The meter cycle follows the bill.
--
--   utility_bills                     + reading_date date, reading_value numeric(12,2) (both null unless kind is electric or water; value >= 0; one bill per meter and reading day).
--   app_settings 'utility_billing'    + electric.open_from and water.open_from = 2026-10-21, added only where absent. The cfg falls back to the same default for a key of the wrong type or a date that does not exist.
--   utility_bill_estimate_v1          from = the reading_date of the newest PAID bill of that meter that is not after p_on, else open_from. Counted use runs from the day after it up to p_on (no cut at the 21st).
--                                     Expected reading day cycle_to = from + 1 month; the forecast runs to max(cycle_to, p_on). Billed month = the month of cycle_to (its rate, else the latest earlier one, as before).
--                                     Same keys as before; adds billed_month (YYYY-MM) and overdue (p_on after cycle_to) to electric and water. days_in_cycle = max(cycle_to, p_on) - from.
--   today_bills_v1                    every key kept; adds water_since, waiting_for / water_waiting_for (month name once the expected reading day has passed), can_pay_list and check_bills.
--                                     A role without approve_payment gets due = [] and check_bills = true from the electric or water remind day while this month's bill of that kind is not paid (or skipped).
--   bill_schedule_cfg_v1              a bill with no stored remind_day opens on the 25th (was the pay day). The four stored bills get remind_day 25 only where they have none; pay_day (27) and every payee or account value are untouched.
--   bill_pay_settle_v1                electric and water need p_proof.reading_date (reading_date_required); it must be after the previous paid reading date (open_from while none) and not after Manila today (reading_date_invalid).
--                                     p_proof.reading_value is optional (>= 0, else reading_value_invalid). Both are stored on the row in the same call as the paid status. The answer adds reading_date and reading_warn (a typed
--                                     reading more than 30 kWh / 3 m3 away from the meter log at that date; never blocks).
--   internal helpers                  utility_safe_date_v1, utility_cfg_date_v1, utility_meter_from_v1, utility_reading_warn_v1 (granted to nobody).
-- Callers re-checked (ML-11): kpi_admin_bills_v1 and kpi_tab_v1 read the estimate for today and only keys that are kept; bill_due_open_v1 reads forecast_php of the cycle that closes in the billed month (p_on = that month's 21st), which is the
-- same cycle (from, from + 1 month] for the first bill and for every later one while the reading date is the 21st; bill_daily_v1 reads no estimate key. None of them is replaced.
-- Guard (55000, nothing changes): each replaced function must be the s127 body or this release (md5 of prosrc, CR stripped). Grants restated (ML-21).
-- Rollback: supabase/rollbacks/20261130_s131_meter_cycle.sql (refuses once a bill carries a reading date or value).

begin;

-- 1. guard ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- every function this release replaces must be the body it was cut from (the s127 body, md5 of prosrc with CR stripped) or this release's own body (a second run), else 55000 and nothing changes
do $g$
declare v text; r record;
begin
  for r in select * from (values
    ('public.utility_billing_default_v1()', '93765639cafb84ce5860de301a5ba0af', 'a392b40c92122706aac8074ee8f490d3'),
    ('public.utility_billing_cfg_v1()', '29c5cc443923797670a7b66f51c86781', '20acb9bbe5965c08fa9b317aa9073636'),
    ('public.utility_bill_estimate_v1(uuid,date)', 'f821ade80aafe63d00dc51f8c5700bf4', '563e61f417555730a9294df15c7eca7f'),
    ('public.today_bills_v1(uuid)', '70302291441c8493c622ae66befe6b79', '7fca3fd12b7e372010f8f20b12c491a4'),
    ('public.bill_pay_settle_v1(uuid,jsonb)', 'df687957b354441f0874fac73a53ee9d', '542aa826c034741a2886863ca069c396'),
    ('public.bill_schedule_cfg_v1()', 'c8a259b8e8be8e2dd0b129e62bb8a68a', '14293a6c2efbc387a8d97240321ca839')
  ) t(sig, m_old, m_new) loop
    select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure(r.sig);
    if v is distinct from r.m_old and v is distinct from r.m_new then
      raise exception using errcode = '55000', message = 's131: ' || r.sig || ' is neither the s127 body nor this release (md5 ' || coalesce(v, 'null') || '): re-cut it from the live body';
    end if;
  end loop;
end $g$;

-- 2. new internal helpers (granted to nobody) -----------------------------------------------------------------------------------------------------------------------------------------------
-- a YYYY-MM-DD text as a date, null when it is not a real date (2026-02-31 is null, not an error)
create or replace function public.utility_safe_date_v1(p_text text)
returns date language plpgsql immutable set search_path = '' as $$
declare d date;
begin
  if p_text is null or p_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then return null; end if;
  d := p_text::date;
  if to_char(d, 'YYYY-MM-DD') <> p_text then return null; end if;
  return d;
exception when others then
  return null;
end;
$$;

-- one date setting: a JSON string that is a real YYYY-MM-DD date, else the default (never raises)
create or replace function public.utility_cfg_date_v1(p_val jsonb, p_default jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p_val) = 'string' and public.utility_safe_date_v1(p_val #>> '{}') is not null then p_val else p_default end;
$$;

-- where the open bill of a meter starts: the reading date of the newest PAID bill of that kind that is not after p_on, else the setting open_from
create or replace function public.utility_meter_from_v1(p_property_id uuid, p_kind text, p_on date, p_cfg jsonb)
returns date language sql stable set search_path = '' as $$
  select coalesce((select max(b.reading_date) from public.utility_bills b
                    where b.property_id = p_property_id and b.kind = p_kind and b.status = 'paid' and b.reading_date is not null and b.reading_date <= p_on),
                  (p_cfg -> p_kind ->> 'open_from')::date);
$$;

-- soft check of a typed present reading against the meter log (counted readings, meter_chain_v1): the log value at p_date is interpolated between the counted reading on or before that day and the next one;
-- after the last counted reading it runs on at that reading's own per-day use. More than 30 kWh (electric) or 3 m3 (water) apart = true. Unknown (no value, or no counted reading on or before p_date) = false.
create or replace function public.utility_reading_warn_v1(p_property_id uuid, p_kind text, p_date date, p_value numeric)
returns boolean language sql stable set search_path = '' as $$
  with pts as (
    select m.cd, m.pcd, case p_kind when 'electric' then m.electric_curr else coalesce(mr.water_curr, mr.water_prev + mr.water_delta) end curr,
           case p_kind when 'electric' then m.electric_delta else m.water_delta end delta
      from public.meter_chain_v1(p_property_id) m join public.meter_readings mr on mr.id = m.id where m.chain_ok),
  a as (select * from pts where cd <= p_date order by cd desc, curr desc limit 1),
  b as (select * from pts where cd > p_date order by cd, curr limit 1),
  est as (select case when a.cd is null then null
                      when b.cd is not null then a.curr + (b.curr - a.curr) * (p_date - a.cd)::numeric / nullif(b.cd - a.cd, 0)
                      else a.curr + coalesce(a.delta / nullif(a.cd - a.pcd, 0), 0) * (p_date - a.cd) end e
            from (select 1) x left join a on true left join b on true)
  select coalesce(abs(p_value - est.e) > case p_kind when 'electric' then 30 else 3 end, false) from est;
$$;

-- 3. the table: reading date and value of a paid meter bill -------------------------------------------------------------------------------------------------------------------------------
alter table public.utility_bills add column if not exists reading_date date, add column if not exists reading_value numeric(12,2);
do $c$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.utility_bills'::regclass and conname = 'utility_bills_reading_value_check') then
    alter table public.utility_bills add constraint utility_bills_reading_value_check check (reading_value is null or reading_value >= 0);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.utility_bills'::regclass and conname = 'utility_bills_reading_meter_only') then
    alter table public.utility_bills add constraint utility_bills_reading_meter_only check ((reading_date is null and reading_value is null) or kind in ('electric', 'water'));
  end if;
end $c$;
-- one bill per reading day and meter: a reading date can close only one cycle
create unique index if not exists utility_bills_reading_date_uq on public.utility_bills(property_id, kind, reading_date) where reading_date is not null;
comment on column public.utility_bills.reading_date is 's131: the meter reading date printed on a PAID electric or water bill (required when it is paid from the Staff app). The next cycle of that meter starts the day after it.';
comment on column public.utility_bills.reading_value is 's131: the present reading printed on the bill (kWh or m3 on the meter), optional.';

-- 4. settings (keys only when absent) -------------------------------------------------------------------------------------------------------------------------------------------------------
update public.app_settings set value = jsonb_set(value, '{electric}', (value -> 'electric') || '{"open_from":"2026-10-21"}'::jsonb), updated_at = now()
 where key = 'utility_billing' and jsonb_typeof(value) = 'object' and jsonb_typeof(value -> 'electric') = 'object' and not (value -> 'electric' ? 'open_from');
update public.app_settings set value = jsonb_set(value, '{water}', (value -> 'water') || '{"open_from":"2026-10-21"}'::jsonb), updated_at = now()
 where key = 'utility_billing' and jsonb_typeof(value) = 'object' and jsonb_typeof(value -> 'water') = 'object' and not (value -> 'water' ? 'open_from');
-- remind_day 25, key by key, only where the bill has none: an owner edit survives and no account, payee, number or note value is touched
do $s$
declare k text;
begin
  foreach k in array array['electric', 'water', 'internet', 'netflix'] loop
    update public.app_settings a set value = jsonb_set(a.value, array['bills', k, 'remind_day'], '25'::jsonb, true), updated_at = now()
     where a.key = 'bill_schedule' and jsonb_typeof(a.value) = 'object' and jsonb_typeof(a.value #> array['bills', k]) = 'object' and not (a.value #> array['bills', k] ? 'remind_day');
  end loop;
end $s$;

-- 5. the replaced functions (same names, arguments, security and search_path; keys only added) ------------------------------------------------------------------------------------------
-- default and cfg gain open_from for electric and water
create or replace function public.utility_billing_default_v1()
returns jsonb language sql immutable set search_path = '' as $$
  select '{"electric":{"cycle_day":21,"fixed_php":5.60,"open_from":"2026-10-21"},"water":{"cycle_day":21,"open_from":"2026-10-21","min_php":212,"min_m3":10,"tiers":[{"upto":20,"php":23.05},{"upto":30,"php":26.65},{"upto":40,"php":30.50},{"upto":null,"php":34.50}],"source_url":"https://gensanwater.gov.ph/water-rates/"}}'::jsonb;
$$;

create or replace function public.utility_billing_cfg_v1()
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'electric', jsonb_build_object(
      'cycle_day', case when jsonb_typeof(s.v #> '{electric,cycle_day}') = 'number' then to_jsonb(least(31, greatest(1, trunc((s.v #> '{electric,cycle_day}')::numeric)))) else d.v #> '{electric,cycle_day}' end,
      'fixed_php', public.utility_cfg_num_v1(s.v #> '{electric,fixed_php}', d.v #> '{electric,fixed_php}'),
      'open_from', public.utility_cfg_date_v1(s.v #> '{electric,open_from}', d.v #> '{electric,open_from}')),
    'water', jsonb_build_object(
      'cycle_day', case when jsonb_typeof(s.v #> '{water,cycle_day}') = 'number' then to_jsonb(least(31, greatest(1, trunc((s.v #> '{water,cycle_day}')::numeric)))) else d.v #> '{water,cycle_day}' end,
      'open_from', public.utility_cfg_date_v1(s.v #> '{water,open_from}', d.v #> '{water,open_from}'),
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

-- bills open on the 25th
-- s131: a bill with no stored remind_day opens (and is due by) the 25th, not the pay day (Lloyd 2026-11-22); pay_day itself is unchanged.
create or replace function public.bill_schedule_cfg_v1()
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'reading_day', public.bill_cfg_day_v1(s.v -> 'reading_day', 21), 'pay_day', to_jsonb(s.pd),
    'bills', jsonb_build_object(
      'electric', public.bill_cfg_one_v1(s.v #> '{bills,electric}', 'Electricity (SOCOTECO II)', null, 25),
      'water',    public.bill_cfg_one_v1(s.v #> '{bills,water}', 'Water (Gensan Water District)', null, 25),
      'internet', public.bill_cfg_one_v1(s.v #> '{bills,internet}', 'Internet', public.utility_cfg_num_v1(s.v #> '{bills,internet,amount}', to_jsonb(1500)), 25),
      'netflix',  public.bill_cfg_one_v1(s.v #> '{bills,netflix}', 'Netflix', public.utility_cfg_num_v1(s.v #> '{bills,netflix,amount}', to_jsonb(449)), 25)))
    from (select a.v, (public.bill_cfg_day_v1(a.v -> 'pay_day', 27) #>> '{}')::integer pd
            from (select coalesce((select x.value from public.app_settings x where x.key = 'bill_schedule' and jsonb_typeof(x.value) = 'object'), '{}'::jsonb) v) a) s;
$$;

-- the cycle follows the bill: from the newest paid reading date (else open_from); see the file header
create or replace function public.utility_bill_estimate_v1(p_property_id uuid, p_on date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_cfg jsonb := public.utility_billing_cfg_v1();
  v_ef date := public.utility_meter_from_v1(p_property_id, 'electric', p_on, v_cfg);
  v_wf date := public.utility_meter_from_v1(p_property_id, 'water', p_on, v_cfg);
  v_et date := (v_ef + interval '1 month')::date;
  v_wt date := (v_wf + interval '1 month')::date;
  v_fixed numeric := (v_cfg -> 'electric' ->> 'fixed_php')::numeric;
  v_kwh numeric; v_elast date; v_eat timestamptz; v_ed integer; v_edc integer := greatest(v_et, p_on) - v_ef; v_rate numeric;
  v_fk numeric; v_pdk numeric;
  v_m3 numeric; v_wlast date; v_wd integer; v_wdc integer := greatest(v_wt, p_on) - v_wf; v_fm numeric; v_pdm numeric; v_next jsonb;
begin
  -- s131: every counted reading after the cycle start up to p_on counts (no cut at the 21st); the forecast runs to the expected reading day, or to p_on once that day has passed
  select coalesce(sum(u.kwh), 0), max(u.d) into v_kwh, v_elast from public.utility_daily_use_v1(p_property_id, v_ef + 1, p_on) u;
  select m.recorded_at into v_eat
    from public.meter_chain_v1(p_property_id) m where m.chain_ok and m.cd > v_ef and m.cd <= p_on
   order by m.cd desc, m.recorded_at desc, m.id desc limit 1;
  v_ed := coalesce(v_elast - v_ef, 0);
  -- the billed month is the month the cycle is expected to end in (from + 1 month); no rate for it yet = the latest earlier rate, null only while no rate exists at all (rates dated after today are never read)
  select r.php_per_kwh into v_rate from public.utility_rate_by_month_v1() r where r.rate_month <= date_trunc('month', v_et)::date order by r.rate_month desc limit 1;
  if v_ed > 0 then v_pdk := v_kwh / v_ed; v_fk := v_pdk * v_edc; end if;

  select coalesce(sum(u.m3), 0), max(u.d) into v_m3, v_wlast from public.utility_daily_use_v1(p_property_id, v_wf + 1, p_on) u;
  v_wd := coalesce(v_wlast - v_wf, 0);
  if v_wd > 0 then v_pdm := v_m3 / v_wd; v_fm := v_pdm * v_wdc; end if;
  v_next := public.utility_water_next_v1(v_m3, v_cfg);

  return jsonb_build_object(
    'electric', jsonb_build_object(
      'cycle_from', v_ef, 'cycle_to', v_et, 'days', v_ed, 'days_in_cycle', v_edc, 'kwh', round(v_kwh, 2), 'rate', v_rate, 'fixed_php', v_fixed,
      'so_far_php', case when v_rate is not null then round(v_kwh * v_rate + v_fixed, 2) end,
      'forecast_kwh', case when v_ed > 0 then round(v_fk, 2) end,
      'forecast_php', case when v_ed > 0 and v_rate is not null then round(v_fk * v_rate + v_fixed, 2) end,
      'per_day_kwh', case when v_ed > 0 then round(v_pdk, 2) end,
      'per_day_php', case when v_ed > 0 and v_rate is not null then round(v_pdk * v_rate, 2) end,
      'last_reading_at', v_eat,
      'billed_month', to_char(v_et, 'YYYY-MM'), 'overdue', p_on > v_et),
    'water', jsonb_build_object(
      'cycle_from', v_wf, 'cycle_to', v_wt, 'days', v_wd, 'm3', round(v_m3, 2),
      'so_far_php', public.utility_water_php_v1(v_m3, v_cfg),
      'forecast_m3', case when v_wd > 0 then round(v_fm, 2) end,
      'forecast_php', case when v_wd > 0 then public.utility_water_php_v1(v_fm, v_cfg) end,
      'per_day_m3', case when v_wd > 0 then round(v_pdm, 2) end,
      'min_php', (v_cfg -> 'water' ->> 'min_php')::numeric, 'min_m3', (v_cfg -> 'water' ->> 'min_m3')::numeric,
      'next_php', v_next -> 'php', 'next_upto', v_next -> 'upto',
      'billed_month', to_char(v_wt, 'YYYY-MM'), 'overdue', p_on > v_wt));
end;
$$;

-- the Today card: since per meter, what it is waiting for, and who may see the To pay list
create or replace function public.today_bills_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v jsonb; v_cfg jsonb; v_ok boolean; v_uid uuid := auth.uid(); v_e jsonb; v_w jsonb;
  v_today date := public.manila_today(); v_per text := to_char(public.manila_today(), 'YYYY-MM'); v_check boolean := false;
begin
  if v_uid is null or p_property_id is null or not public.current_staff_authorized('read_operations', p_property_id) then
    raise exception using errcode = '42501', message = 'not authorized';
  end if;
  v := public.utility_bill_estimate_v1(p_property_id, v_today);
  v_e := v -> 'electric'; v_w := v -> 'water';
  v_cfg := public.bill_schedule_cfg_v1();
  v_ok := public.current_staff_authorized('approve_payment', p_property_id);
  -- s131: a role that cannot pay gets no list, only a reminder to look for the paper bills from the remind day on while this month's electric or water bill is not paid (or skipped)
  if not v_ok then
    v_check := (extract(day from v_today)::integer >= (v_cfg -> 'bills' -> 'electric' ->> 'remind_day')::integer
                  and not exists (select 1 from public.utility_bills b where b.property_id = p_property_id and b.kind = 'electric' and b.period = v_per and b.status in ('paid', 'skipped')))
            or (extract(day from v_today)::integer >= (v_cfg -> 'bills' -> 'water' ->> 'remind_day')::integer
                  and not exists (select 1 from public.utility_bills b where b.property_id = p_property_id and b.kind = 'water' and b.period = v_per and b.status in ('paid', 'skipped')));
  end if;
  return jsonb_build_object(
    'since', (v_e ->> 'cycle_from')::date,
    'water_since', (v_w ->> 'cycle_from')::date,
    'waiting_for', case when (v_e ->> 'overdue')::boolean then to_char(to_date((v_e ->> 'billed_month') || '-01', 'YYYY-MM-DD'), 'FMMonth') end,
    'water_waiting_for', case when (v_w ->> 'overdue')::boolean then to_char(to_date((v_w ->> 'billed_month') || '-01', 'YYYY-MM-DD'), 'FMMonth') end,
    'last_reading_at', v_e -> 'last_reading_at',
    'electric', jsonb_build_object('php', v_e -> 'so_far_php', 'kwh', v_e -> 'kwh'),
    'water', jsonb_build_object('php', v_w -> 'so_far_php', 'm3', v_w -> 'm3'),
    'can_pay_list', v_ok,
    'check_bills', v_check,
    'due', case when not v_ok then '[]'::jsonb else coalesce((select jsonb_agg(public.bill_entry_v1(b, v_cfg, v_ok, v_uid)
                                      order by (b.status = 'paid'), b.period, array_position(array['electric', 'water', 'internet', 'netflix'], b.kind))
                       from public.utility_bills b where b.property_id = p_property_id
                        and (b.status in ('due', 'paying') or (b.status = 'paid' and b.period = v_per))), '[]'::jsonb) end);
end;
$$;

-- pay a bill from the Staff app: a meter bill also takes its reading date and optional present reading
create or replace function public.bill_pay_settle_v1(p_bill_id uuid, p_proof jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_prop uuid; v_b public.utility_bills%rowtype; v_cfg jsonb; v_res jsonb;
  v_path text; v_client_sha text; v_sha text; v_prefix text;
  v_rd date; v_rv numeric; v_prev date; v_warn boolean;
begin
  select b.property_id into v_prop from public.utility_bills b where b.id = p_bill_id;
  if v_uid is null or not public.bill_can_v1(v_prop) then return jsonb_build_object('ok', false, 'reason', 'not_authorized'); end if;
  select * into v_b from public.utility_bills where id = p_bill_id for update;
  if not found or v_b.status = 'skipped' then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  v_cfg := public.bill_schedule_cfg_v1();
  if v_b.status = 'paid' then return jsonb_build_object('ok', false, 'reason', 'already_paid', 'bill', public.bill_entry_v1(v_b, v_cfg, true, v_uid)); end if;
  if v_b.status = 'paying' and v_b.paying_by is distinct from v_uid then return jsonb_build_object('ok', false, 'reason', 'not_payer', 'name', v_b.paying_by_name); end if;

  if p_proof is null or jsonb_typeof(p_proof) <> 'object' then return jsonb_build_object('ok', false, 'reason', 'bad_proof'); end if;
  -- s131: a meter bill carries the reading date printed on it (required) and, optionally, the present reading. The date must move the cycle forward: later than the previous paid reading date
  -- (the setting open_from while none is paid yet) and not after Manila today. Nothing is stored here; the row gets both only when the bill is paid, in this same call.
  if v_b.kind in ('electric', 'water') then
    perform pg_advisory_xact_lock(hashtextextended('bill_reading:' || v_b.property_id::text || ':' || v_b.kind, 0));
    if jsonb_typeof(p_proof -> 'reading_date') is distinct from 'string' or btrim(p_proof ->> 'reading_date') = '' then
      return jsonb_build_object('ok', false, 'reason', 'reading_date_required');
    end if;
    v_rd := public.utility_safe_date_v1(btrim(p_proof ->> 'reading_date'));
    v_prev := coalesce((select max(o.reading_date) from public.utility_bills o where o.property_id = v_b.property_id and o.kind = v_b.kind and o.status = 'paid' and o.reading_date is not null and o.id <> v_b.id),
                       (public.utility_billing_cfg_v1() -> v_b.kind ->> 'open_from')::date);
    if v_rd is null or v_rd <= v_prev or v_rd > public.manila_today() then
      return jsonb_build_object('ok', false, 'reason', 'reading_date_invalid', 'after', v_prev);
    end if;
    if jsonb_typeof(p_proof -> 'reading_value') in ('number', 'string') and btrim(p_proof ->> 'reading_value') <> '' then
      v_rv := case when btrim(p_proof ->> 'reading_value') ~ '^[0-9]{1,10}(\.[0-9]{1,6})?$' then round(btrim(p_proof ->> 'reading_value')::numeric, 2) end;
      if v_rv is null or v_rv >= 10000000000 then return jsonb_build_object('ok', false, 'reason', 'reading_value_invalid'); end if;
    elsif jsonb_typeof(p_proof -> 'reading_value') in ('boolean', 'array', 'object') then
      return jsonb_build_object('ok', false, 'reason', 'reading_value_invalid');
    end if;
  end if;
  v_path := btrim(coalesce(p_proof ->> 'path', ''));
  v_client_sha := lower(coalesce(p_proof ->> 'sha256', ''));
  v_prefix := v_b.property_id::text || '/' || v_uid::text || '/';
  if (v_client_sha <> '' and v_client_sha !~ '^[0-9a-f]{64}$') or char_length(v_path) not between 40 and 300
     or left(v_path, length(v_prefix)) <> v_prefix or position('..' in v_path) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_proof');
  end if;
  -- stored proof: the object exists in the private bucket and upload-photo recorded the hash of the bytes it stored
  select h.sha256 into v_sha from public.staff_upload_hashes h where h.path = v_path;
  if v_sha is null or not exists (select 1 from storage.objects o where o.bucket_id = 'cleaning-photos' and o.name = v_path) then
    return jsonb_build_object('ok', false, 'reason', 'no_stored_proof');
  end if;
  if v_client_sha <> '' and v_client_sha <> v_sha then return jsonb_build_object('ok', false, 'reason', 'sha_mismatch'); end if;

  v_res := public.bill_step_v1(v_b.id, 'paid', v_uid, public.bill_actor_name_v1(v_uid),
    jsonb_build_object('file_unique_id', 'web:' || v_path, 'file_id', v_path, 'path', v_path, 'sha256', v_sha, 'amount', p_proof -> 'amount', 'verdict', 'read',
                       'confirmed', coalesce(p_proof -> 'confirmed' = 'true'::jsonb, false), 'read', jsonb_build_object('source', 'staff_app', 'typed_by', v_uid)));
  if v_res ->> 'reason' = 'confirm_amount' then v_res := v_res || jsonb_build_object('estimate_php', v_b.estimate_php); end if;
  -- s131: stored with the paid bill in this same call (a refusal above stores nothing); the warning never blocks
  if coalesce((v_res ->> 'ok')::boolean, false) and v_b.kind in ('electric', 'water') then
    update public.utility_bills set reading_date = v_rd, reading_value = v_rv where id = v_b.id;
    v_warn := public.utility_reading_warn_v1(v_b.property_id, v_b.kind, v_rd, v_rv);
    v_res := v_res || jsonb_build_object('reading_date', v_rd, 'reading_warn', v_warn);
  end if;
  return public.bill_reply_v1(v_res, v_b.id);
end $$;

-- 6. grants (ML-21), restated -----------------------------------------------------------------------------------------------------------------------------------------------------------------
revoke all on function public.utility_safe_date_v1(text) from public, anon, authenticated, service_role;
revoke all on function public.utility_cfg_date_v1(jsonb, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.utility_meter_from_v1(uuid, text, date, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.utility_reading_warn_v1(uuid, text, date, numeric) from public, anon, authenticated, service_role;
revoke all on function public.utility_billing_default_v1() from public, anon, authenticated, service_role;
revoke all on function public.utility_billing_cfg_v1() from public, anon, authenticated, service_role;
revoke all on function public.bill_schedule_cfg_v1() from public, anon, authenticated, service_role;
revoke all on function public.utility_bill_estimate_v1(uuid, date) from public, anon, authenticated, service_role;
revoke all on function public.today_bills_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.today_bills_v1(uuid) to authenticated;
revoke all on function public.bill_pay_settle_v1(uuid, jsonb) from public, anon, service_role;
grant execute on function public.bill_pay_settle_v1(uuid, jsonb) to authenticated;

comment on function public.utility_bill_estimate_v1(uuid, date) is 's131: internal. The open bill of each meter: from = the reading date of the newest paid bill of that kind (else the setting open_from), counted use from the day after it up to p_on, forecast to from + 1 month or p_on once that has passed. Keys cycle_from, cycle_to (= from + 1 month), days, days_in_cycle, billed_month (YYYY-MM) and overdue (p_on after cycle_to). Counted readings = meter_chain_v1.';
comment on function public.today_bills_v1(uuid) is 's131: the electricity and water bill so far for the Today tab (since per meter, waiting_for / water_waiting_for month name once the expected reading day has passed) plus the bills to pay (due) for roles with approve_payment (can_pay_list true); other roles get due [] and check_bills (from the remind day while this month''s electric or water bill is not paid or skipped). Every active staff role of the property (read_operations); anyone else 42501.';
comment on function public.bill_pay_settle_v1(uuid, jsonb) is 's131: approve_payment. p_proof {path, sha256, amount, confirmed, reading_date (required for electric and water), reading_value (optional)}; one expense row. Refusals: not_authorized, not_found, already_paid, not_payer, bad_proof, reading_date_required, reading_date_invalid, reading_value_invalid, no_stored_proof, sha_mismatch, duplicate_proof, bad_amount, confirm_amount. Adds reading_date and reading_warn.';

-- forward check ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'utility_bills' and column_name = 'reading_date') then raise exception 's131: utility_bills.reading_date missing'; end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'utility_bills' and column_name = 'reading_value') then raise exception 's131: utility_bills.reading_value missing'; end if;
  if (public.utility_billing_cfg_v1() #>> '{electric,open_from}') is null or (public.utility_billing_cfg_v1() #>> '{water,open_from}') is null then raise exception 's131: open_from missing from the cfg'; end if;
  if (public.bill_schedule_cfg_v1() #>> '{bills,electric,remind_day}')::integer <> 25 and exists (select 1 from public.app_settings where key = 'bill_schedule' and not (value #> '{bills,electric}' ? 'remind_day')) then raise exception 's131: remind_day default is not 25'; end if;
  if has_function_privilege('anon', 'public.utility_bill_estimate_v1(uuid,date)', 'execute') or has_function_privilege('authenticated', 'public.utility_bill_estimate_v1(uuid,date)', 'execute') then raise exception 's131: an API role can run utility_bill_estimate_v1'; end if;
  if not has_function_privilege('authenticated', 'public.today_bills_v1(uuid)', 'execute') or not has_function_privilege('authenticated', 'public.bill_pay_settle_v1(uuid,jsonb)', 'execute') then raise exception 's131: authenticated lost a grant'; end if;
  if has_function_privilege('anon', 'public.today_bills_v1(uuid)', 'execute') or has_function_privilege('anon', 'public.bill_pay_settle_v1(uuid,jsonb)', 'execute') then raise exception 's131: anon can run a Staff app bill function'; end if;
end $$;

commit;
