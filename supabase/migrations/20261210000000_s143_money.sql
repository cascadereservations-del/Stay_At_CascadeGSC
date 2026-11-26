-- Session 143, lane S (SQL): release s143_money_20261210. Contract: docs/s143/CONTRACT.md "SQL (lane S)" over docs/s143/PLAN-finance.md sections 3-4. Money consolidation, server side.
--
--   boundary model                    A meter cycle boundary is the REAL reading_date of a bill (any status, a skipped bill keeps it), else ASSUMED = the latest real reading (else the setting open_from) + n months, month end clamped,
--                                     the anchor day kept (31 Jan -> 28 Feb -> 31 Mar). Each bill row of a meter uses one slot (utility_meter_rows_v1); the open cycle on a day comes from utility_meter_cycle_v1.
--   utility_bill_estimate_v1          from / to = the open cycle above (was: newest PAID reading + 1 month). Same keys; overdue is always false.
--   bill_entry_v1                     + from, to, to_assumed (meter bills; null / false otherwise), paid_on (the ledger date of a paid bill).
--   bill_due_open_v1                  the estimate of a new meter bill = the use counted in its own span (so far at the reading date).
--   bill_daily_v1                     the "Meter reading due today (<day>)" notice fires on an assumed reading day of either meter (was: the fixed 21st).
--   today_bills_v1                    every key kept; the meter objects gain cycle_from, cycle_from_assumed, next_reading; last_bill and last_paid only when can_pay_list; due[] holds due and paying only.
--   bill_pay_open_v1                  + bill.reading_date, bill.reading_date_assumed, pay.method_default (+ the new bill_entry keys, among them bill.from).
--   bill_pay_settle_v1                reading date from the proof else the date already set on the bill; the previous / next bounds count a bill of ANY status; + paid_on (not after today, not before the reading date;
--                                     paid_on_invalid), + method (bad_method); reading_value = coalesce(new, stored). bill_step_v1 writes the ledger row on paid_on with the method, and the category by kind
--                                     (electric / water utilities, internet internet, netflix subscription).
--   bill_reading_set_v1               NEW. Sets the reading date of the oldest open bill (or creates the row of the cycle being closed); preview writes nothing.
--   transactions.payment_method       NEW nullable column, check: gcash, bank, cash, card, other. admin_save_transaction_v2 accepts payment_method (bad_method).
--   expenses_screen_v1                rows + by, method, covers {from, to} | null, title.
--   internal helpers                  utility_add_months_v1, utility_meter_rows_v1, utility_meter_cycle_v1, utility_cycle_php_v1, utility_bill_span_v1, utility_last_bill_v1 (granted to nobody).
-- NOT in this migration: the category back-fill of old bill rows (docs/s143/laneS/backfill_category.sql, run separately with Lloyd's yes). utility_meter_from_v1 stays in place, unused.
-- Callers re-checked (ML-11): kpi_admin_bills_v1 and kpi_tab_v1 read utility_bill_estimate_v1 for today and only keys that are kept; no function outside the bill family calls bill_step_v1, bill_entry_v1 or bill_due_open_v1.
-- Guard (55000, nothing changes): each replaced function must be the body it was cut from (s127 / s131 / s131b / s134, md5 of prosrc with CR stripped) or this release's own body (a second run). Grants restated (ML-21).
-- No begin/commit here: apply-release-on-host.sh wraps each migration with its ledger row in one transaction (as s141); the rollback carries its own.
-- Rollback: supabase/rollbacks/20261210_s143_money.sql (puts the exact previous bodies back, drops the new functions; refuses once a ledger row carries a payment_method).

-- 1. guard ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
do $g$
declare v text; r record;
begin
  for r in select * from (values
    ('public.utility_bill_estimate_v1(uuid,date)', '563e61f417555730a9294df15c7eca7f', '615c5e6719f1d35872e885c6f5084587'),
    ('public.bill_entry_v1(public.utility_bills,jsonb,boolean,uuid)', '64e749cf8ed30afc9c4475bcd398685a', 'b9445c74b9de12d095258176dbba99df'),
    ('public.bill_due_open_v1(uuid,date,text)', '51c1bca21bbacbba9d214f963e3806d1', 'c5781b6c5b7c59e8621b17fef0a2d29a'),
    ('public.bill_daily_v1(date,uuid)', '91a6d8a62fafd25894310e522de23494', '1726ac329d265f98a9c345aae083d729'),
    ('public.bill_step_v1(uuid,text,uuid,text,jsonb)', '36c9347d29f4b964540ca973af8cac19', '44d8d6670985d060556cd772cc61b3c4'),
    ('public.bill_pay_open_v1(uuid)', 'dba3b83d4e7cd0f9dcf192b0c925644e', 'b090554ca873215100d9167579c0facc'),
    ('public.bill_pay_settle_v1(uuid,jsonb)', '9784e8619b3aeb3d6b19c5fd7f679c79', '591176b334a7f6089a25b79ee2a4b245'),
    ('public.today_bills_v1(uuid)', '7fca3fd12b7e372010f8f20b12c491a4', '563053ef8469130428e9d35f09cc7762'),
    ('public.expenses_screen_v1(uuid,date,integer,timestamptz,text,uuid)', '0a94343249946154b709a4a7f9e407b9', '87d5b34bc801736104bf69da5019b792'),
    ('public.admin_save_transaction_v2(uuid,jsonb,text)', '3f6547827d1cd04c8875c6fc2fe8a154', '2eebbce5a512ddf389b6361ff85ae74d')
  ) t(sig, m_old, m_new) loop
    select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure(r.sig);
    if v is distinct from r.m_old and v is distinct from r.m_new then
      raise exception using errcode = '55000', message = 's143: ' || r.sig || ' is neither the body it was cut from nor this release (md5 ' || coalesce(v, 'null') || '): re-cut it from the live body';
    end if;
  end loop;
end $g$;

-- 2. the column: how a ledger row was paid -------------------------------------------------------------------------------------------------------------------------------------------------
alter table public.transactions add column if not exists payment_method text;
do $c$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.transactions'::regclass and conname = 'transactions_payment_method_check') then
    alter table public.transactions add constraint transactions_payment_method_check check (payment_method is null or payment_method in ('gcash', 'bank', 'cash', 'card', 'other'));
  end if;
end $c$;
comment on column public.transactions.payment_method is 's143: how the expense was paid (gcash, bank, cash, card, other); null = not recorded.';

-- 3. new internal helpers (granted to nobody) -----------------------------------------------------------------------------------------------------------------------------------------------

-- a date plus n months with the anchor day kept and clamped to month end: 31 Jan + 1 = 28 Feb, 31 Jan + 2 = 31 Mar (never chained, so a clamped day is not carried on)
create or replace function public.utility_add_months_v1(p_d date, p_n integer)
returns date language sql immutable set search_path = '' as $$
  select case when p_d is null or p_n is null then null
              else make_date(extract(year from y.m)::integer, extract(month from y.m)::integer,
                             least(extract(day from p_d)::integer, extract(day from (y.m + interval '1 month' - interval '1 day'))::integer)) end
    from (select date_trunc('month', p_d::timestamp) + make_interval(months => coalesce(p_n, 0)) m) y;
$$;

-- the bills of one meter in period order with their reading span: a row ends on its real reading_date (any status, a skipped bill keeps it) else on an ASSUMED date = the latest real reading before it
-- (else the setting open_from) + k months, k = the number of rows without a date since that reading (a skipped row without a date still uses its slot). A row starts where the row before it ends (open_from for the first).
-- p_extra adds a virtual row of that period (when no bill has it) so the caller can see the span a new bill would get.
create or replace function public.utility_meter_rows_v1(p_property_id uuid, p_kind text, p_extra text default null)
returns table(id uuid, period text, status text, reading_date date, row_from date, row_to date, to_assumed boolean)
language sql stable set search_path = '' as $$
  with o as (select (public.utility_billing_cfg_v1() -> p_kind ->> 'open_from')::date d),
  r as (
    select b.id, b.period, b.status, b.reading_date from public.utility_bills b where b.property_id = p_property_id and b.kind = p_kind
    union all
    select null::uuid, p_extra, 'due'::text, null::date
     where p_extra is not null and not exists (select 1 from public.utility_bills b where b.property_id = p_property_id and b.kind = p_kind and b.period = p_extra)
  ),
  g as (
    select r.*, count(r.reading_date) over w grp, max(r.reading_date) over w prev_real
      from r window w as (order by r.period rows between unbounded preceding and 1 preceding)
  ),
  k as (
    select g.*, count(*) filter (where g.reading_date is null) over (partition by g.grp order by g.period) n from g
  ),
  t as (
    select k.*, coalesce(k.reading_date, public.utility_add_months_v1(coalesce(k.prev_real, o.d), k.n::integer)) to_d from k cross join o
  )
  select t.id, t.period, t.status, t.reading_date, coalesce(lag(t.to_d) over (order by t.period), o.d), t.to_d, t.reading_date is null
    from t cross join o order by t.period;
$$;

-- the open cycle of a meter on p_on: from = the newest real reading_date (any bill status) on or before p_on, else open_from, plus the whole months that fit before p_on (assumed once at least one month was added);
-- to = one month after it
create or replace function public.utility_meter_cycle_v1(p_property_id uuid, p_kind text, p_on date, p_cfg jsonb)
returns table(cycle_from date, from_assumed boolean, cycle_to date)
language sql stable set search_path = '' as $$
  with a as (
    select coalesce((select max(b.reading_date) from public.utility_bills b where b.property_id = p_property_id and b.kind = p_kind and b.reading_date is not null and b.reading_date <= p_on),
                    (p_cfg -> p_kind ->> 'open_from')::date) d),
  n as (select coalesce(max(k), 0) k from a, generate_series(0, 1200) k where public.utility_add_months_v1(a.d, k) <= p_on)
  select public.utility_add_months_v1(a.d, n.k), n.k > 0, public.utility_add_months_v1(a.d, n.k + 1) from a, n;
$$;

-- the bill so far for the use counted on the days from+1 .. to: electricity at the rate of the month of `to` (else the latest earlier rate) plus the fixed charge, water by the tiered tariff; null while no rate exists or no use was counted in the span (a bill with nothing counted has no estimate, never 0)
create or replace function public.utility_cycle_php_v1(p_property_id uuid, p_kind text, p_from date, p_to date, p_cfg jsonb)
returns numeric language plpgsql stable set search_path = '' as $$
declare v_use numeric; v_rate numeric; v_last date;
begin
  if p_kind = 'electric' then
    select coalesce(sum(u.kwh), 0), max(u.d) into v_use, v_last from public.utility_daily_use_v1(p_property_id, p_from + 1, p_to) u;
    if v_last is null then return null; end if;
    select r.php_per_kwh into v_rate from public.utility_rate_by_month_v1() r where r.rate_month <= date_trunc('month', p_to::timestamp)::date order by r.rate_month desc limit 1;
    return case when v_rate is not null then round(v_use * v_rate + (p_cfg -> 'electric' ->> 'fixed_php')::numeric, 2) end;
  elsif p_kind = 'water' then
    select coalesce(sum(u.m3), 0), max(u.d) into v_use, v_last from public.utility_daily_use_v1(p_property_id, p_from + 1, p_to) u;
    if v_last is null then return null; end if;
    return public.utility_water_php_v1(v_use, p_cfg);
  end if;
  return null;
end $$;

-- the reading span of one meter bill (no row for a bill that is not electric or water)
create or replace function public.utility_bill_span_v1(p_property_id uuid, p_kind text, p_id uuid)
returns table(row_from date, row_to date, to_assumed boolean)
language sql stable set search_path = '' as $$
  select r.row_from, r.row_to, r.to_assumed from public.utility_meter_rows_v1(p_property_id, p_kind) r where p_kind in ('electric', 'water') and r.id = p_id;
$$;

-- the newest bill row of one meter as the Today card shows it (money: only for roles that can pay)
create or replace function public.utility_last_bill_v1(p_property_id uuid, p_kind text)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
           'id', b.id, 'period', b.period, 'from', s.row_from, 'to', s.row_to, 'to_assumed', s.to_assumed,
           'usage', (select round(case p_kind when 'electric' then coalesce(sum(u.kwh), 0) else coalesce(sum(u.m3), 0) end, 2) from public.utility_daily_use_v1(p_property_id, s.row_from + 1, s.row_to) u),
           'estimate_php', b.estimate_php, 'paid_php', b.paid_php, 'paid_on', case when b.status = 'paid' then t.transaction_date end,
           'paid_by_name', case when b.status = 'paid' then b.paid_by_name end, 'status', b.status, 'has_proof', b.proof_path is not null)
    from public.utility_bills b
    join public.utility_meter_rows_v1(p_property_id, p_kind) s on s.id = b.id
    left join public.transactions t on t.id = b.txn_id
   where b.property_id = p_property_id and b.kind = p_kind and p_kind in ('electric', 'water')
   order by b.period desc limit 1;
$$;

-- 4. the replaced functions (same names, arguments, security and search_path) ----------------------------------------------------------------------------------------------------------------------
create or replace function public.utility_bill_estimate_v1(p_property_id uuid, p_on date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_cfg jsonb := public.utility_billing_cfg_v1();
  v_ef date := (select c.cycle_from from public.utility_meter_cycle_v1(p_property_id, 'electric', p_on, v_cfg) c);
  v_wf date := (select c.cycle_from from public.utility_meter_cycle_v1(p_property_id, 'water', p_on, v_cfg) c);
  v_et date := (select c.cycle_to from public.utility_meter_cycle_v1(p_property_id, 'electric', p_on, v_cfg) c);
  v_wt date := (select c.cycle_to from public.utility_meter_cycle_v1(p_property_id, 'water', p_on, v_cfg) c);
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

create or replace function public.bill_entry_v1(b public.utility_bills, p_cfg jsonb, p_approve boolean, p_uid uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', b.id, 'kind', b.kind, 'label', p_cfg -> 'bills' -> b.kind ->> 'label', 'period', b.period, 'status', b.status,
    'estimate_php', b.estimate_php, 'paid_php', b.paid_php, 'is_estimate', b.kind in ('electric', 'water'),
    'due_day', greatest((p_cfg -> 'bills' -> b.kind ->> 'remind_day')::integer, (p_cfg ->> 'pay_day')::integer),
    'paying_by_name', case when b.status = 'paying' then b.paying_by_name end,
    'paid_by_name', case when b.status = 'paid' then b.paid_by_name end, 'paid_at', b.paid_at,
    'can_pay', coalesce(p_approve, false) and (b.status = 'due' or (b.status = 'paying' and b.paying_by is not distinct from p_uid)),
    'from', s.row_from, 'to', s.row_to, 'to_assumed', coalesce(s.to_assumed, false), 'paid_on', case when b.status = 'paid' then t.transaction_date end)
    from (select 1) x
    left join lateral public.utility_bill_span_v1(b.property_id, b.kind, b.id) s on true
    left join public.transactions t on t.id = b.txn_id;
$$;

create or replace function public.bill_due_open_v1(p_property_id uuid, p_on date, p_min_period text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_cfg jsonb := public.bill_schedule_cfg_v1();
  v_ucfg jsonb := public.utility_billing_cfg_v1();
  v_day integer;
  v_ids uuid[]; v_new jsonb;
begin
  if p_property_id is null or p_on is null then
    return jsonb_build_object('new', '[]'::jsonb);
  end if;
  v_day := extract(day from p_on)::integer;
  perform pg_advisory_xact_lock(hashtextextended('bill_due_open:' || p_property_id::text, 0));

  with k as (
    select x.kind, to_char(m.d, 'YYYY-MM') period, m.d
      from (select kk.kind, (v_cfg -> 'bills' -> kk.kind ->> 'remind_day')::integer rd from unnest(array['electric', 'water', 'internet', 'netflix']) as kk(kind)) x,
           lateral (select case when v_day >= x.rd then date_trunc('month', p_on)::date else (date_trunc('month', p_on) - interval '1 month')::date end d) m),
  ins as (
    insert into public.utility_bills(property_id, kind, period, estimate_php)
    select p_property_id, k.kind, k.period,
           case k.kind
             when 'electric' then public.utility_cycle_php_v1(p_property_id, 'electric', ss.row_from, least(ss.row_to, p_on), v_ucfg)
             when 'water'    then public.utility_cycle_php_v1(p_property_id, 'water', ss.row_from, least(ss.row_to, p_on), v_ucfg)
             else (v_cfg -> 'bills' -> k.kind ->> 'amount')::numeric end
      from k
      left join lateral (select r.row_from, r.row_to from public.utility_meter_rows_v1(p_property_id, k.kind, k.period) r where k.kind in ('electric', 'water') and r.period = k.period) ss on true
     where (p_min_period is null or k.period >= p_min_period)
       and not exists (select 1 from public.utility_bills b where b.property_id = p_property_id and b.kind = k.kind and b.period = k.period)
    on conflict (property_id, kind, period) do nothing
    returning id)
  select array_agg(i.id) into v_ids from ins i;
  v_ids := coalesce(v_ids, '{}');

  select coalesce(jsonb_agg(public.bill_json_v1(b) order by array_position(array['electric', 'water', 'internet', 'netflix'], b.kind)), '[]'::jsonb) into v_new from public.utility_bills b where b.id = any (v_ids);
  return jsonb_build_object('new', v_new);
end;
$$;

create or replace function public.bill_daily_v1(p_on date default null, p_property_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_floor constant text := '2026-11'; -- the release month: October 2026 and earlier stay closed
  v_today date := coalesce(p_on, public.manila_today());
  v_cfg jsonb := public.bill_schedule_cfg_v1();
  v_read integer := (v_cfg ->> 'reading_day')::integer;
  v_prop uuid; v_res jsonb; v_bill jsonb; v_nid uuid; v_title text; v_opened integer := 0; v_notices integer := 0; v_po integer; v_pn integer;
begin
  for v_prop in select p.id from public.properties p where p.is_active and (p_property_id is null or p.id = p_property_id) order by p.id loop
    begin
      v_po := 0; v_pn := 0;
      -- s143: the reading day is the assumed boundary of a meter (anchor + n months, month end clamped), not a fixed day of the month; a real reading that moved the boundary moves the notice
      if exists (select 1 from unnest(array['electric', 'water']) k(kind), lateral public.utility_meter_cycle_v1(v_prop, k.kind, v_today, public.utility_billing_cfg_v1()) c where c.from_assumed and c.cycle_from = v_today) then
        v_title := 'Meter reading due today (' || to_char(v_today, 'FMDDth') || ')';
        if not exists (select 1 from public.ops_notices n where n.property_id = v_prop and n.notice_type = 'reminder' and n.source = 'system' and n.effective_date = v_today and n.title = v_title) then
          insert into public.ops_notices(property_id, notice_type, title, description, effective_date, source, audience)
          values (v_prop, 'reminder', v_title, 'Read the electricity and water meters.', v_today, 'system', 'staff');
          v_pn := v_pn + 1;
        end if;
      end if;

      v_res := public.bill_due_open_v1(v_prop, v_today, c_floor);
      for v_bill in select e from jsonb_array_elements(v_res -> 'new') e loop
        v_po := v_po + 1;
        v_title := case when (v_bill ->> 'period') < to_char(v_today, 'YYYY-MM') then (v_bill ->> 'label') || ' is overdue.'
                        else (v_bill ->> 'label') || ' bill: due by the ' || to_char(make_date(2001, 1, greatest((v_bill ->> 'remind_day')::integer, (v_cfg ->> 'pay_day')::integer)), 'FMDDth') || '.' end;
        insert into public.ops_notices(property_id, notice_type, title, description, effective_date, source, audience)
        values (v_prop, 'reminder', v_title, '', v_today, 'system', 'staff') returning id into v_nid;
        update public.utility_bills set notice_id = v_nid where id = (v_bill ->> 'id')::uuid;
        v_pn := v_pn + 1;
      end loop;

      -- an unpaid bill stays on Today: its one notice is dated today (notices_v1 ends a notice at the end of its date)
      update public.ops_notices n set effective_date = v_today
       where n.is_active and n.effective_date < v_today
         and n.id in (select b.notice_id from public.utility_bills b where b.property_id = v_prop and b.status in ('due', 'paying') and b.notice_id is not null);
      v_opened := v_opened + v_po; v_notices := v_notices + v_pn;
    exception when others then
      raise warning 'bill_daily_v1: property % skipped (sqlstate %)', v_prop, sqlstate;
    end;
  end loop;
  return jsonb_build_object('on', v_today, 'bills_opened', v_opened, 'notices_written', v_notices);
end $$;

create or replace function public.bill_step_v1(p_id uuid, p_step text, p_actor_uid uuid, p_actor_name text, p_proof jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_b public.utility_bills%rowtype;
  v_actor text := coalesce(nullif(btrim(p_actor_name), ''), 'Finance');
  v_amt numeric; v_other text; v_ref text; v_label text; v_txn uuid;
  v_t record; v_why text; v_con text;
begin
  if p_actor_uid is null or p_step is null or p_step not in ('pay', 'cancel', 'skip', 'paid') then return jsonb_build_object('ok', false, 'reason', 'bad_step'); end if;

  select * into v_b from public.utility_bills where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_b.status = 'paid' then return jsonb_build_object('ok', false, 'reason', 'already_paid', 'bill', public.bill_json_v1(v_b)); end if;
  -- while the bill is paying, only the person who tapped pay may settle or skip it
  if v_b.status = 'paying' and p_step in ('skip', 'paid') and v_b.paying_by is distinct from p_actor_uid then
    return jsonb_build_object('ok', false, 'reason', 'bad_step', 'bill', public.bill_json_v1(v_b));
  end if;

  case p_step
    when 'pay' then
      if v_b.status = 'due' then
        update public.utility_bills set status = 'paying', paying_by = p_actor_uid, paying_by_name = v_actor, paying_at = now() where id = v_b.id returning * into v_b;
      elsif not (v_b.status = 'paying' and v_b.paying_by is not distinct from p_actor_uid) then -- the same person again re-opens her own payment
        return jsonb_build_object('ok', false, 'reason', 'bad_step', 'bill', public.bill_json_v1(v_b));
      end if;
      return jsonb_build_object('ok', true, 'bill', public.bill_json_v1(v_b));

    when 'cancel' then
      if v_b.status <> 'paying' then return jsonb_build_object('ok', false, 'reason', 'bad_step', 'bill', public.bill_json_v1(v_b)); end if;
      update public.utility_bills set status = 'due', paying_by = null, paying_by_name = null, paying_at = null where id = v_b.id returning * into v_b;
      return jsonb_build_object('ok', true, 'bill', public.bill_json_v1(v_b));

    when 'skip' then
      if v_b.status <> 'skipped' then
        update public.utility_bills set status = 'skipped' where id = v_b.id returning * into v_b;
      end if;
      update public.ops_notices set is_active = false where id = v_b.notice_id and is_active;
      return jsonb_build_object('ok', true, 'bill', public.bill_json_v1(v_b));

    else -- 'paid'
      if v_b.status = 'skipped' then return jsonb_build_object('ok', false, 'reason', 'bad_step', 'bill', public.bill_json_v1(v_b)); end if;
      if p_proof is null or jsonb_typeof(p_proof) <> 'object' then return jsonb_build_object('ok', false, 'reason', 'bad_step', 'bill', public.bill_json_v1(v_b)); end if;
      v_amt := case jsonb_typeof(p_proof -> 'amount')
                 when 'number' then (p_proof ->> 'amount')::numeric
                 when 'string' then case when (p_proof ->> 'amount') ~ '^[0-9]{1,6}(\.[0-9]{1,2})?$' then (p_proof ->> 'amount')::numeric end
               end;
      v_amt := round(v_amt, 2);
      if v_amt is null or v_amt <= 0 or v_amt > 100000 then return jsonb_build_object('ok', false, 'reason', 'bad_amount'); end if;
      if coalesce(p_proof ->> 'sha256', '') = '' or coalesce(p_proof ->> 'file_unique_id', '') = '' then
        return jsonb_build_object('ok', false, 'reason', 'bad_step', 'bill', public.bill_json_v1(v_b));
      end if;
      select o.ref into v_other from public.utility_bills o
       where o.id <> v_b.id and (o.proof_file_unique_id = p_proof ->> 'file_unique_id' or o.proof_sha256 = p_proof ->> 'sha256') limit 1;
      if not found then -- a screenshot that settled a staff payment cannot settle a bill either (staff_pay_admin_settle_v1 refuses the reverse)
        select o.ref into v_other from public.staff_pay_requests o
         where o.proof_file_unique_id = p_proof ->> 'file_unique_id' or o.proof_sha256 = p_proof ->> 'sha256' limit 1;
      end if;
      if found then return jsonb_build_object('ok', false, 'reason', 'duplicate_proof', 'other_ref', v_other); end if;
      -- amount band (Addendum 1): fixed bills amount .. amount + 50, meter bills half .. double the estimate; an unknown estimate has no band, so it always asks
      if coalesce(p_proof -> 'confirmed' = 'true'::jsonb, false) is false and not coalesce(
           case when v_b.kind in ('internet', 'netflix') then v_amt between v_b.estimate_php and v_b.estimate_php + 50
                else v_amt between v_b.estimate_php / 2 and v_b.estimate_php * 2 end, false) then
        return jsonb_build_object('ok', false, 'reason', 'confirm_amount', 'read', v_amt);
      end if;

      v_ref := 'bill:' || v_b.kind || ':' || v_b.period;
      v_label := public.bill_schedule_cfg_v1() -> 'bills' -> v_b.kind ->> 'label';
      perform set_config('cascade.audit_reason', 'bill ' || v_b.ref || ' paid by ' || v_actor, true);
      -- found again by its ref (the unique index counts void rows too): a second pass never writes twice, and a row that is not this bill's is never linked
      select t.id, t.status, t.property_id, t.source, t.gross_amount into v_t from public.transactions t where t.external_ref = v_ref;
      if found then
        if v_t.status = 'void' then
          raise exception using errcode = '55000', message = 'The ledger already holds a voided row for ' || v_ref || ' (id ' || v_t.id || '). Delete that row or give it another reference, then log the bill again.';
        end if;
        v_why := concat_ws(', ', case when v_t.property_id is distinct from v_b.property_id then 'another property' end,
                                 case when v_t.source is distinct from 'bill' then 'source ' || coalesce(v_t.source, 'none') end,
                                 case when v_t.gross_amount is distinct from v_amt then 'amount ' || coalesce(v_t.gross_amount::text, 'none') end);
        if v_why <> '' then
          raise exception using errcode = '55000', message = 'The ledger already holds a row for ' || v_ref || ' (id ' || v_t.id || ') that does not match this bill: ' || v_why || '. Fix or delete that row, then log the bill again.';
        end if;
        v_txn := v_t.id;
      end if;
      begin
      if v_txn is null then
        insert into public.transactions(property_id, txn_type, category, status, source, gross_amount, payee_name, transaction_date, external_ref, notes, logged_by, payment_method)
        values (v_b.property_id, 'expense', case v_b.kind when 'internet' then 'internet' when 'netflix' then 'subscription' else 'utilities' end, 'confirmed', 'bill', v_amt, v_label,
                coalesce(public.utility_safe_date_v1(p_proof ->> 'paid_on'), public.manila_today()), v_ref,
                'Utility bill ' || v_b.kind || ' ' || v_b.period || ' (' || v_label || '). Bill ' || v_b.ref || '.', 'Staff app: ' || v_actor,
                case when lower(btrim(coalesce(p_proof ->> 'method', ''))) in ('gcash', 'bank', 'cash', 'card', 'other') then lower(btrim(p_proof ->> 'method')) end)
        returning id into v_txn;
      end if;
      update public.utility_bills set
        status = 'paid', paid_php = v_amt, paid_at = now(), paid_by = p_actor_uid, paid_by_name = v_actor, txn_id = v_txn,
        paying_by = coalesce(paying_by, p_actor_uid), paying_by_name = coalesce(paying_by_name, v_actor), paying_at = coalesce(paying_at, now()),
        proof_file_unique_id = p_proof ->> 'file_unique_id',
        proof_file_id = nullif(p_proof ->> 'file_id', ''),
        proof_sha256 = p_proof ->> 'sha256',
        proof_path = nullif(p_proof ->> 'path', ''),
        proof_amount = v_amt,
        proof_reference = nullif(p_proof ->> 'reference', ''),
        proof_read = jsonb_build_object('read', p_proof -> 'read', 'verdict', 'read'),
        proof_verdict = 'read'
       where id = v_b.id returning * into v_b;
      exception when unique_violation then -- the sub-transaction undoes the ledger insert too
        get stacked diagnostics v_con = constraint_name;
        if v_con in ('utility_bills_proof_file_uq', 'utility_bills_proof_sha_uq') then
          select o.ref into v_other from public.utility_bills o where o.id <> v_b.id and (o.proof_file_unique_id = p_proof ->> 'file_unique_id' or o.proof_sha256 = p_proof ->> 'sha256') limit 1;
          return jsonb_build_object('ok', false, 'reason', 'duplicate_proof', 'other_ref', v_other);
        end if;
        raise exception using errcode = '55000', message = 'The ledger already holds a row for ' || v_ref || ' that was written a moment ago. Check it, then log the bill again.';
      end;
      update public.ops_notices set is_active = false where id = v_b.notice_id and is_active;
      return jsonb_build_object('ok', true, 'bill', public.bill_json_v1(v_b), 'paid_php', v_amt);
  end case;
end;
$$;

create or replace function public.bill_pay_open_v1(p_bill_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_prop uuid; v_b public.utility_bills%rowtype; v_cfg jsonb; v_info jsonb;
begin
  select b.property_id into v_prop from public.utility_bills b where b.id = p_bill_id;
  if v_uid is null or not public.bill_can_v1(v_prop) then return jsonb_build_object('ok', false, 'reason', 'not_authorized'); end if;
  select * into v_b from public.utility_bills where id = p_bill_id for update;
  if not found or v_b.status = 'skipped' then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  v_cfg := public.bill_schedule_cfg_v1();
  if v_b.status = 'paid' then return jsonb_build_object('ok', false, 'reason', 'already_paid', 'bill', public.bill_entry_v1(v_b, v_cfg, true, v_uid)); end if;
  if v_b.status = 'paying' and v_b.paying_by is distinct from v_uid then
    return jsonb_build_object('ok', false, 'reason', 'paying_by_other', 'name', v_b.paying_by_name);
  end if;
  if v_b.status = 'due' then
    perform public.bill_step_v1(v_b.id, 'pay', v_uid, public.bill_actor_name_v1(v_uid));
    select * into v_b from public.utility_bills where id = p_bill_id;
  end if;
  v_info := public.bill_pay_info_v1(v_cfg, v_b.kind, v_b.period);
  return jsonb_build_object('ok', true,
    'bill', public.bill_entry_v1(v_b, v_cfg, true, v_uid)
      || jsonb_build_object('reading_date', case when v_b.kind in ('electric', 'water') then coalesce(v_b.reading_date, (select s.row_to from public.utility_bill_span_v1(v_b.property_id, v_b.kind, v_b.id) s)) end,
                            'reading_date_assumed', v_b.kind in ('electric', 'water') and v_b.reading_date is null),
    'pay', jsonb_build_object('payee_name', v_info -> 'payee_name', 'number_label', v_info -> 'number_label', 'number', v_info -> 'number', 'note', v_info -> 'note',
                              'amount_php', v_b.estimate_php, 'amount_editable', v_b.kind in ('electric', 'water'),
                              'method_default', coalesce((select t.payment_method from public.utility_bills ub join public.transactions t on t.id = ub.txn_id
                                                           where ub.property_id = v_b.property_id and ub.kind = v_b.kind and t.payment_method is not null
                                                           order by t.transaction_date desc, t.created_at desc limit 1), 'gcash')),
    'can_edit', public.current_staff_authorized('manage_staff', v_b.property_id));
end $$;

create or replace function public.bill_pay_settle_v1(p_bill_id uuid, p_proof jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_prop uuid; v_b public.utility_bills%rowtype; v_cfg jsonb; v_res jsonb;
  v_path text; v_client_sha text; v_sha text; v_prefix text;
  v_rd date; v_rv numeric; v_prev date; v_low date; v_warn boolean; v_next date; v_paid_on date; v_meth text;
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
  -- (the setting open_from while none is paid yet) of an EARLIER period, not before the 1st of the month before the billed period, and not after Manila today. Nothing is stored here; the row gets both only when the bill is paid, in this same call.
  if v_b.kind in ('electric', 'water') then
    perform pg_advisory_xact_lock(hashtextextended('bill_reading:' || v_b.property_id::text || ':' || v_b.kind, 0));
    -- an older bill of the same meter that is still due or paying must be settled first: the cycle follows the bills in order
    if exists (select 1 from public.utility_bills o where o.property_id = v_b.property_id and o.kind = v_b.kind and o.period < v_b.period and o.status not in ('paid', 'skipped')) then
      return jsonb_build_object('ok', false, 'reason', 'older_bill_open');
    end if;
    -- s143: a reading date already set on the bill (bill_reading_set_v1) is kept when the proof carries none; a date in the proof wins
    if jsonb_typeof(p_proof -> 'reading_date') = 'string' and btrim(p_proof ->> 'reading_date') <> '' then
      v_rd := public.utility_safe_date_v1(btrim(p_proof ->> 'reading_date'));
    elsif v_b.reading_date is not null and (not (p_proof ? 'reading_date') or jsonb_typeof(p_proof -> 'reading_date') = 'null'
                                            or (jsonb_typeof(p_proof -> 'reading_date') = 'string' and btrim(p_proof ->> 'reading_date') = '')) then
      v_rd := v_b.reading_date;
    else
      return jsonb_build_object('ok', false, 'reason', 'reading_date_required');
    end if;
    v_prev := coalesce((select max(o.reading_date) from public.utility_bills o where o.property_id = v_b.property_id and o.kind = v_b.kind and o.reading_date is not null and o.period < v_b.period),
                       (public.utility_billing_cfg_v1() -> v_b.kind ->> 'open_from')::date);
    -- not before the 1st of the month before the billed period (a bill for November is read in October or November)
    v_low := (public.utility_safe_date_v1(v_b.period || '-01') - interval '1 month')::date;
    if v_rd is null or v_rd <= v_prev or v_rd < v_low or v_rd > public.manila_today() then
      return jsonb_build_object('ok', false, 'reason', 'reading_date_invalid', 'after', greatest(v_prev, v_low - 1));
    end if;
    -- s131b: and it must stay before the earliest reading date of a PAID bill of a LATER period of the same meter (a later bill paid before this older one, reachable through a skipped-then-reopened older bill or rows written
    -- outside the app, must not have its cycle start moved by this date)
    v_next := (select min(o.reading_date) from public.utility_bills o where o.property_id = v_b.property_id and o.kind = v_b.kind and o.reading_date is not null and o.period > v_b.period);
    if v_next is not null and v_rd >= v_next then
      return jsonb_build_object('ok', false, 'reason', 'reading_date_invalid', 'before', v_next);
    end if;
    if jsonb_typeof(p_proof -> 'reading_value') in ('number', 'string') and btrim(p_proof ->> 'reading_value') <> '' then
      v_rv := case when btrim(p_proof ->> 'reading_value') ~ '^[0-9]{1,10}(\.[0-9]{1,6})?$' then round(btrim(p_proof ->> 'reading_value')::numeric, 2) end;
      if v_rv is null or v_rv >= 10000000000 then return jsonb_build_object('ok', false, 'reason', 'reading_value_invalid'); end if;
    elsif jsonb_typeof(p_proof -> 'reading_value') in ('boolean', 'array', 'object') then
      return jsonb_build_object('ok', false, 'reason', 'reading_value_invalid');
    end if;
  end if;
  -- s143: paid on (the ledger date: a safe date, not after Manila today, not before the reading date of a meter bill; absent = today) and how it was paid
  v_paid_on := public.manila_today();
  if p_proof ? 'paid_on' and jsonb_typeof(p_proof -> 'paid_on') <> 'null' then
    v_paid_on := case when jsonb_typeof(p_proof -> 'paid_on') = 'string' then public.utility_safe_date_v1(btrim(p_proof ->> 'paid_on')) end;
    if v_paid_on is null or v_paid_on > public.manila_today() or (v_rd is not null and v_paid_on < v_rd) then
      return jsonb_build_object('ok', false, 'reason', 'paid_on_invalid');
    end if;
  end if;
  if p_proof ? 'method' and jsonb_typeof(p_proof -> 'method') <> 'null' then
    v_meth := case when jsonb_typeof(p_proof -> 'method') = 'string' then lower(btrim(p_proof ->> 'method')) end;
    if v_meth is null or v_meth not in ('gcash', 'bank', 'cash', 'card', 'other') then return jsonb_build_object('ok', false, 'reason', 'bad_method'); end if;
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
                       'confirmed', coalesce(p_proof -> 'confirmed' = 'true'::jsonb, false), 'paid_on', to_char(v_paid_on, 'YYYY-MM-DD'), 'method', v_meth,
                       'read', jsonb_build_object('source', 'staff_app', 'typed_by', v_uid)));
  if v_res ->> 'reason' = 'confirm_amount' then v_res := v_res || jsonb_build_object('estimate_php', v_b.estimate_php); end if;
  -- s131: stored with the paid bill in this same call (a refusal above stores nothing); the warning never blocks
  if coalesce((v_res ->> 'ok')::boolean, false) and v_b.kind in ('electric', 'water') then
    update public.utility_bills set reading_date = v_rd, reading_value = coalesce(v_rv, reading_value) where id = v_b.id;
    v_warn := public.utility_reading_warn_v1(v_b.property_id, v_b.kind, v_rd, v_rv);
    v_res := v_res || jsonb_build_object('reading_date', v_rd, 'reading_warn', v_warn);
  end if;
  return public.bill_reply_v1(v_res, v_b.id);
end $$;

create or replace function public.today_bills_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v jsonb; v_cfg jsonb; v_ok boolean; v_uid uuid := auth.uid(); v_e jsonb; v_w jsonb;
  v_ec record; v_wc record; v_today date := public.manila_today(); v_per text := to_char(public.manila_today(), 'YYYY-MM'); v_check boolean := false;
begin
  if v_uid is null or p_property_id is null or not public.current_staff_authorized('read_operations', p_property_id) then
    raise exception using errcode = '42501', message = 'not authorized';
  end if;
  v := public.utility_bill_estimate_v1(p_property_id, v_today);
  v_e := v -> 'electric'; v_w := v -> 'water';
  select * into v_ec from public.utility_meter_cycle_v1(p_property_id, 'electric', v_today, public.utility_billing_cfg_v1());
  select * into v_wc from public.utility_meter_cycle_v1(p_property_id, 'water', v_today, public.utility_billing_cfg_v1());
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
    'electric', jsonb_build_object('php', v_e -> 'so_far_php', 'kwh', v_e -> 'kwh', 'cycle_from', v_ec.cycle_from, 'cycle_from_assumed', v_ec.from_assumed, 'next_reading', v_ec.cycle_to)
                  || case when v_ok then jsonb_build_object('last_bill', public.utility_last_bill_v1(p_property_id, 'electric')) else '{}'::jsonb end,
    'water', jsonb_build_object('php', v_w -> 'so_far_php', 'm3', v_w -> 'm3', 'cycle_from', v_wc.cycle_from, 'cycle_from_assumed', v_wc.from_assumed, 'next_reading', v_wc.cycle_to)
                  || case when v_ok then jsonb_build_object('last_bill', public.utility_last_bill_v1(p_property_id, 'water')) else '{}'::jsonb end,
    'can_pay_list', v_ok,
    'check_bills', v_check,
    'due', case when not v_ok then '[]'::jsonb else coalesce((select jsonb_agg(public.bill_entry_v1(b, v_cfg, v_ok, v_uid)
                                      order by (b.status = 'paid'), b.period, array_position(array['electric', 'water', 'internet', 'netflix'], b.kind))
                       from public.utility_bills b where b.property_id = p_property_id
                        and b.status in ('due', 'paying')), '[]'::jsonb) end)
  || case when v_ok then jsonb_build_object('last_paid', coalesce((
        select jsonb_agg(jsonb_build_object('kind', x.kind, 'period', x.period, 'paid_php', x.paid_php, 'paid_on', x.paid_on) order by array_position(array['electric', 'water', 'internet', 'netflix'], x.kind))
          from (select distinct on (b.kind) b.kind, b.period, b.paid_php, t.transaction_date paid_on
                  from public.utility_bills b left join public.transactions t on t.id = b.txn_id
                 where b.property_id = p_property_id and b.status = 'paid' order by b.kind, b.period desc, b.paid_at desc nulls last) x), '[]'::jsonb)) else '{}'::jsonb end;
end;
$$;

create or replace function public.expenses_screen_v1(p_property_id uuid, p_month date default null, p_limit integer default 100, p_before timestamptz default null, p_filter text default null, p_before_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_m0 date; v_m1 date; v_fs jsonb; v_lim integer := least(greatest(coalesce(p_limit, 100), 0), 200); v_cut timestamptz; v_rows jsonb; v_more boolean := false;
  v_basis numeric; v_bm integer; v_pend jsonb; v_pend_all jsonb; v_unp jsonb; v_unl integer; v_cats jsonb; v_cnt integer; v_flt text := nullif(btrim(coalesce(p_filter, '')), '');
begin
  if auth.uid() is null or not public.current_staff_authorized('read_finance', p_property_id) then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  v_m0 := date_trunc('month', coalesce(p_month, public.manila_today()))::date;
  v_m1 := (v_m0 + interval '1 month')::date;
  v_fs := public.get_finance_summary(v_m0, p_property_id);
  select round(avg(x.e), 2), count(*) into v_basis, v_bm
    from (select (public.get_finance_summary((v_m0 - (k * interval '1 month'))::date, p_property_id) ->> 'expenses')::numeric e from generate_series(1, 3) k) x where x.e > 0;
  select count(*) into v_cnt from public.transactions t where t.property_id = p_property_id and t.txn_type = 'expense' and t.status = 'confirmed' and t.source not in ('airbnb', 'airbnb_email')
     and t.transaction_date >= v_m0 and t.transaction_date < v_m1;
  select jsonb_build_object('count', count(*), 'total', coalesce(sum(t.gross_amount), 0)) into v_pend from public.transactions t
   where t.property_id = p_property_id and t.txn_type = 'expense' and t.status = 'pending_review' and t.source not in ('airbnb', 'airbnb_email') and t.transaction_date >= v_m0 and t.transaction_date < v_m1;
  select jsonb_build_object('count', count(*), 'total', coalesce(sum(t.gross_amount), 0)) into v_pend_all from public.transactions t
   where t.property_id = p_property_id and t.txn_type = 'expense' and t.status = 'pending_review' and t.source not in ('airbnb', 'airbnb_email');
  v_cut := (select (s.value #>> '{}')::timestamptz from public.app_settings s where s.key = 's134_stock_expense_from');

  if v_lim > 0 then
    with base as (
      select t.*, public.s_expense_receipt_v1(t.id) rc,
             exists (select 1 from public.inventory_purchases ip where ip.transaction_id = t.id) has_stock,
             t.source in ('bill', 'cleaner_fee', 'refund', 'direct_booking', 'airbnb', 'airbnb_email', 'airbnb_payout_email') locked
        from public.transactions t
       where t.property_id = p_property_id and t.txn_type = 'expense' and t.status in ('confirmed', 'pending_review') and t.source not in ('airbnb', 'airbnb_email')
         and t.transaction_date >= v_m0 and t.transaction_date < v_m1 and (p_before is null or (case when p_before_id is null then t.created_at < p_before else (t.created_at, t.id) < (p_before, p_before_id) end))
    ), chipped as (
      select b.*, public.s_expense_chip_v1(b.source, b.has_stock, b.rc is not null) chip from base b
    ), picked as (
      select c.* from chipped c
       where v_flt is null or v_flt = 'all' or (v_flt = 'review' and c.status = 'pending_review') or (v_flt like 'cat:%' and c.category = substr(v_flt, 5)) or c.chip = v_flt
       order by c.created_at desc, c.id desc limit v_lim + 1
    ), numbered as (
      select p.*, row_number() over (order by p.created_at desc, p.id desc) rn, public.s_expense_lookalike_v1(p.id) lk from picked p
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', n.id, 'date', n.transaction_date, 'amount', n.gross_amount, 'category', n.category,
             'label', coalesce(ec.label, initcap(replace(n.category, '_', ' '))), 'payee', n.payee_name, 'notes', n.notes, 'status', n.status, 'chip', n.chip, 'source', n.source,
             'hidden', n.hidden_at is not null,
             'has_receipt', n.rc is not null,
             'receipt_ref', case when n.rc is null then null else jsonb_build_object('kind', n.rc ->> 'kind', 'id', n.rc ->> 'id', 'mime', n.rc ->> 'mime') end,
             'receipt_can', jsonb_build_object(
                 'add', (not n.locked and n.source in ('manual', 'telegram', 'ocr', 'inventory') and n.rc is null),
                 'replace', (not n.locked and n.source in ('manual', 'telegram', 'ocr', 'inventory') and n.rc ->> 'kind' = 'txn'),
                 'remove', (not n.locked and n.source in ('manual', 'telegram', 'ocr', 'inventory') and n.rc ->> 'kind' = 'txn')),
             'locked', n.locked,
             'amount_locked', (n.locked or (n.has_stock and public.s_stock_expense_owned_v1(n.id))),
             'stock', case when n.has_stock then (select jsonb_build_object('lines', count(*), 'items', count(distinct ip.item_id)) from public.inventory_purchases ip where ip.transaction_id = n.id) end,
             'lookalike_id', n.lk ->> 'id', 'lookalike', n.lk,
             's134_incomplete', coalesce((n.ocr_raw ->> 's134_incomplete') = 'true', false),
             'created_at', n.created_at,
             'method', n.payment_method,
             'by', case when n.source = 'bill' then (select ub.paid_by_name from public.utility_bills ub where ub.txn_id = n.id limit 1)
                        else nullif(btrim(regexp_replace(regexp_replace(regexp_replace(coalesce(n.logged_by, ''), '^(Staff app|Telegram): ', ''), ' via Staff app$', ''), '^(admin|system|telegram|manual|ocr|inventory)$', '', 'i')), '') end,
             'covers', (select jsonb_build_object('from', s.row_from, 'to', s.row_to) from public.utility_bills ub, lateral public.utility_bill_span_v1(ub.property_id, ub.kind, ub.id) s where ub.txn_id = n.id limit 1),
             'title', case when n.source = 'bill' then case split_part(coalesce(n.external_ref, ''), ':', 2) when 'electric' then 'Electricity bill' when 'water' then 'Water bill' when 'internet' then 'Internet bill' when 'netflix' then 'Netflix bill'
                                                           else coalesce(nullif(n.payee_name, ''), coalesce(ec.label, initcap(replace(n.category, '_', ' ')))) end
                           when n.source = 'cleaner_fee' then 'Cleaning fee'
                           when n.has_stock and n.notes like 'Stock bought: %' then substr(n.notes, 15)
                           else coalesce(nullif(n.payee_name, ''), coalesce(ec.label, initcap(replace(n.category, '_', ' ')))) end) order by n.rn), '[]'::jsonb),
           coalesce(bool_or(n.rn > v_lim), false)
      into v_rows, v_more
      from numbered n left join public.expense_categories ec on ec.property_id = p_property_id and ec.slug = n.category
     where n.rn <= v_lim or true;
    -- the +1 row only proves there is more: drop it
    if v_more then v_rows := (select coalesce(jsonb_agg(e.value order by e.ord), '[]'::jsonb) from jsonb_array_elements(v_rows) with ordinality e(value, ord) where e.ord <= v_lim); end if;
  else
    v_rows := '[]'::jsonb;
  end if;

  -- purchases with no price (no priced line, no draft total, no ledger row) whose receipt falls in the month
  with g as (
    select p.expense_group, min(p.purchased_at) d, (array_agg(i.name order by p.created_at, p.id))[1] name, (array_agg(p.item_id order by p.created_at, p.id))[1] item_id
      from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
     where i.property_id = p_property_id and p.expense_group is not null and p.purchased_at >= v_m0 and p.purchased_at < v_m1
     group by p.expense_group
    having count(*) filter (where p.unit_cost > 0) = 0 and bool_and(p.transaction_id is null)
       and not exists (select 1 from public.inventory_receipt_drafts dr where p.expense_group like 'draft:%' and dr.id::text = substr(p.expense_group, 7) and dr.total > 0)
  )
  select jsonb_build_object('count', (select count(*) from g),
                            'items', coalesce((select jsonb_agg(jsonb_build_object('item_id', x.item_id, 'name', x.name, 'date', x.d) order by x.d desc, x.name) from (select * from g order by d desc, name limit 20) x), '[]'::jsonb))
    into v_unp;
  select count(*) into v_unl from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
   where i.property_id = p_property_id and v_cut is not null and p.created_at >= v_cut and p.unit_cost > 0 and p.transaction_id is null;
  select coalesce(jsonb_agg(jsonb_build_object('slug', c.slug, 'label', c.label) order by c.sort_order, c.label), '[]'::jsonb) into v_cats
    from public.expense_categories c where c.property_id = p_property_id and c.is_active and c.slug not in ('guest_refund', 'airbnb_adjustment');

  return jsonb_build_object('ok', true, 'month', v_m0, 'total', (v_fs ->> 'expenses')::numeric, 'count', v_cnt,
    'prev_total', (public.get_finance_summary((v_m0 - interval '1 month')::date, p_property_id) ->> 'expenses')::numeric,
    'basis', v_basis, 'basis_months', v_bm, 'pending', v_pend, 'pending_all', v_pend_all,
    'by_category', coalesce((select jsonb_agg(e.value) from jsonb_array_elements(v_fs -> 'by_category') e where e.value ->> 'txn_type' = 'expense'), '[]'::jsonb),
    'rows', v_rows, 'unpriced', v_unp, 'unlinked', v_unl, 'categories', v_cats,
    'can_write', public.current_staff_authorized('approve_payment', p_property_id), 'more', v_more);
end $$;

create or replace function public.admin_save_transaction_v2(p_property_id uuid, p_txn jsonb, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid; v_row public.transactions%rowtype; v_type text; v_amount numeric; v_date date; v_ref text; v_reason text; v_cat text; v_receipt text; v_conf numeric; v_raw jsonb;
  v_gate jsonb; v_status text; v_where text; v_locked boolean; v_meth text; v_has_meth boolean := false;
  c_system constant text[] := array['guest_refund', 'airbnb_adjustment'];
begin
  perform public.admin_require('approve_payment', p_property_id);
  if p_txn is null or jsonb_typeof(p_txn) <> 'object' then return jsonb_build_object('ok', false, 'error', 'bad_request'); end if;
  begin
    v_amount := nullif(p_txn ->> 'gross_amount', '')::numeric;
    v_date := nullif(p_txn ->> 'transaction_date', '')::date;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end;
  if nullif(p_txn ->> 'id', '') is not null then
    v_id := public.try_uuid(p_txn ->> 'id');
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'bad_request'); end if;
  end if;
  v_type := coalesce(nullif(p_txn ->> 'txn_type', ''), 'expense');
  if v_type not in ('income', 'expense', 'drawing') then return jsonb_build_object('ok', false, 'error', 'bad_type'); end if;
  v_reason := nullif(btrim(coalesce(p_txn ->> 'reason', '')), '');
  v_cat := nullif(btrim(coalesce(p_txn ->> 'category', '')), '');
  -- s143: how it was paid; a key that is present and empty clears it on edit
  if p_txn ? 'payment_method' then
    v_has_meth := true;
    v_meth := nullif(lower(btrim(coalesce(p_txn ->> 'payment_method', ''))), '');
    if v_meth is not null and v_meth not in ('gcash', 'bank', 'cash', 'card', 'other') then return jsonb_build_object('ok', false, 'error', 'bad_method'); end if;
  end if;

  if v_id is null then
    -- create ------------------------------------------------------------------------------------------------------------------------------------------------
    if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then return jsonb_build_object('ok', false, 'error', 'key_required'); end if;
    perform pg_advisory_xact_lock(hashtextextended('s134:save:' || p_property_id::text || ':' || p_idempotency_key, 0));
    v_ref := 'admin:' || p_idempotency_key;
    select * into v_row from public.transactions where property_id = p_property_id and external_ref = v_ref;
    if found then return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status, 'replayed', true); end if;
    if v_date is null then return jsonb_build_object('ok', false, 'error', 'date_required'); end if;
    if v_type = 'expense' then
      if v_cat is null then return jsonb_build_object('ok', false, 'error', 'category_required'); end if;
      if v_cat = any (c_system) then return jsonb_build_object('ok', false, 'error', 'system_category'); end if;
      if not exists (select 1 from public.expense_categories c where c.property_id = p_property_id and c.slug = v_cat and c.is_active) then return jsonb_build_object('ok', false, 'error', 'bad_category'); end if;
      if v_amount is null or v_amount <= 0 then return jsonb_build_object('ok', false, 'error', 'bad_amount'); end if;
      if v_date > public.manila_today() + 1 then return jsonb_build_object('ok', false, 'error', 'future_date'); end if;
    elsif v_amount is null or v_amount < 0 then
      return jsonb_build_object('ok', false, 'error', 'bad_amount');
    end if;
    v_status := coalesce(nullif(p_txn ->> 'status', ''), 'confirmed');
    if v_status not in ('confirmed', 'pending_review') then return jsonb_build_object('ok', false, 'error', 'status_not_allowed'); end if;
    v_receipt := nullif(btrim(coalesce(p_txn ->> 'receipt_image_path', '')), '');
    if v_receipt is not null then
      v_gate := public.s_expense_receipt_gate_v1(p_property_id, v_receipt, null);
      if (v_gate ->> 'ok')::boolean is not true then return v_gate; end if;
      if nullif(p_txn ->> 'ocr_confidence', '') is not null then
        begin v_conf := (p_txn ->> 'ocr_confidence')::numeric; exception when others then return jsonb_build_object('ok', false, 'error', 'bad_confidence'); end;
        if v_conf < 0 or v_conf > 1 then return jsonb_build_object('ok', false, 'error', 'bad_confidence'); end if;
      end if;
      v_raw := '{}'::jsonb;
      if p_txn ? 'ocr_raw' and jsonb_typeof(p_txn -> 'ocr_raw') = 'object' then
        if char_length((p_txn -> 'ocr_raw')::text) > 20000 then return jsonb_build_object('ok', false, 'error', 'ocr_raw_too_large'); end if;
        v_raw := (p_txn -> 'ocr_raw') - 'receipt_sha256' - 'receipt_mime' - 's134_auto' - 's134_amount' - 's134_group' - 's134_backfill' - 's134_incomplete' - 'draft_id' - 'source';
      end if;
      v_raw := v_raw || jsonb_build_object('receipt_sha256', v_gate ->> 'sha256', 'receipt_mime', v_gate ->> 'mime');
    end if;
    perform public.admin_audit_context_v1(coalesce(v_reason, 'created in admin'), null, null);
    insert into public.transactions(property_id, txn_type, category, status, source, transaction_date, gross_amount, currency, or_number, payee_name, notes, external_ref, income_stage, reservation_id, booking_id, logged_by, receipt_image_path, ocr_confidence, ocr_raw, payment_method)
    values (p_property_id, v_type, coalesce(v_cat, case v_type when 'drawing' then 'owner_drawing' else 'other' end), v_status, 'manual', v_date, v_amount, 'PHP',
            nullif(p_txn ->> 'or_number', ''), nullif(p_txn ->> 'payee_name', ''), nullif(p_txn ->> 'notes', ''), v_ref, case when v_type = 'income' then 'confirmed' end,
            public.try_uuid(p_txn ->> 'reservation_id'), public.try_uuid(p_txn ->> 'booking_id'), 'admin', v_receipt, case when v_receipt is not null then v_conf end, v_raw, v_meth)
    returning * into v_row;
    return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status,
                              'auditId', (select a.id from public.admin_audit_log a where a.entity_table = 'transactions' and a.entity_id = v_row.id order by a.created_at desc limit 1),
                              'lookalike', public.s_expense_lookalike_v1(v_row.id));
  end if;

  -- edit ------------------------------------------------------------------------------------------------------------------------------------------------------
  select * into v_row from public.transactions where id = v_id and property_id = p_property_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_row.status = 'void' then return jsonb_build_object('ok', false, 'error', 'void'); end if;
  if p_txn ? 'receipt_image_path' or p_txn ? 'ocr_raw' or p_txn ? 'ocr_confidence' then return jsonb_build_object('ok', false, 'error', 'use_receipt_control'); end if;
  if v_reason is null then return jsonb_build_object('ok', false, 'error', 'reason_required'); end if;
  if p_txn ? 'txn_type' and v_type is distinct from v_row.txn_type then return jsonb_build_object('ok', false, 'error', 'type_locked'); end if;
  v_locked := v_row.source in ('bill', 'cleaner_fee', 'refund', 'direct_booking', 'airbnb', 'airbnb_email', 'airbnb_payout_email');
  v_where := case v_row.source when 'bill' then 'Bills' when 'cleaner_fee' then 'Pay staff' end;
  if p_txn ? 'status' and p_txn ->> 'status' is distinct from v_row.status then
    return case when v_locked then jsonb_build_object('ok', false, 'error', 'locked', 'where', v_where) else jsonb_build_object('ok', false, 'error', 'status_not_allowed') end;
  end if;
  if v_locked and ((p_txn ? 'gross_amount' and v_amount is distinct from v_row.gross_amount)
                or (p_txn ? 'transaction_date' and v_date is distinct from v_row.transaction_date)
                or (p_txn ? 'payee_name' and nullif(p_txn ->> 'payee_name', '') is distinct from v_row.payee_name)
                or (p_txn ? 'or_number' and nullif(p_txn ->> 'or_number', '') is distinct from v_row.or_number)
                or (p_txn ? 'reservation_id' and public.try_uuid(p_txn ->> 'reservation_id') is distinct from v_row.reservation_id)
                -- a staff pay row keeps its category: the cleaning-pay month figure and the V19 reconciliation read category 'cleaning'
                or (v_row.source = 'cleaner_fee' and v_cat is not null and v_cat is distinct from v_row.category)) then
    return jsonb_build_object('ok', false, 'error', 'locked', 'where', v_where);
  end if;
  if v_row.txn_type = 'expense' then
    if v_cat is not null and v_cat is distinct from v_row.category then
      if v_cat = any (c_system) then return jsonb_build_object('ok', false, 'error', 'system_category'); end if;
      if not exists (select 1 from public.expense_categories c where c.property_id = p_property_id and c.slug = v_cat and c.is_active) then return jsonb_build_object('ok', false, 'error', 'bad_category'); end if;
    end if;
    if p_txn ? 'gross_amount' and (v_amount is null or v_amount <= 0) then return jsonb_build_object('ok', false, 'error', 'bad_amount'); end if;
    if p_txn ? 'transaction_date' and (v_date is null or (v_date is distinct from v_row.transaction_date and v_date > public.manila_today() + 1)) then
      return jsonb_build_object('ok', false, 'error', case when v_date is null then 'date_required' else 'future_date' end);
    end if;
    -- a sync-owned stock row with linked purchases: the purchases decide amount, date and payee (the sync rewrites them); a person may change the category and the note only
    if ((p_txn ? 'gross_amount' and v_amount is distinct from v_row.gross_amount)
        or (p_txn ? 'transaction_date' and v_date is distinct from v_row.transaction_date)
        or (p_txn ? 'payee_name' and nullif(p_txn ->> 'payee_name', '') is distinct from v_row.payee_name)
        or (p_txn ? 'or_number' and nullif(p_txn ->> 'or_number', '') is distinct from v_row.or_number)
        or (p_txn ? 'reservation_id' and public.try_uuid(p_txn ->> 'reservation_id') is distinct from v_row.reservation_id))
       and public.s_stock_expense_owned_v1(v_row.id)
       and exists (select 1 from public.inventory_purchases ip where ip.transaction_id = v_row.id) then
      return jsonb_build_object('ok', false, 'error', 'amount_locked', 'where', 'Inventory');
    end if;
  end if;
  perform public.admin_audit_context_v1(v_reason, null, null);
  update public.transactions set
    category = coalesce(v_cat, category),
    transaction_date = coalesce(v_date, transaction_date),
    gross_amount = coalesce(v_amount, gross_amount),
    or_number = case when p_txn ? 'or_number' then nullif(p_txn ->> 'or_number', '') else or_number end,
    payee_name = case when p_txn ? 'payee_name' then nullif(p_txn ->> 'payee_name', '') else payee_name end,
    notes = case when p_txn ? 'notes' then nullif(p_txn ->> 'notes', '') else notes end,
    reservation_id = case when p_txn ? 'reservation_id' then public.try_uuid(p_txn ->> 'reservation_id') else reservation_id end,
    payment_method = case when v_has_meth then v_meth else payment_method end,
    updated_at = now()
  where id = v_id returning * into v_row;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status,
                            'auditId', (select a.id from public.admin_audit_log a where a.entity_table = 'transactions' and a.entity_id = v_row.id order by a.created_at desc limit 1));
end $$;

-- 5. the new Staff app function ---------------------------------------------------------------------------------------------------------------------------------------------------------------

-- set the reading date (and optionally the present reading) of the oldest open bill of a meter; no open bill = a new row for the cycle being closed. The reading moves the next cycle (the boundary is the real date).
-- preview writes nothing. Refusals {ok:false, reason}: not_authorized, bad_kind, reading_date_invalid (after | before), reading_value_invalid, already_paid, older_bill_open.
create or replace function public.bill_reading_set_v1(p_property_id uuid, p_kind text, p_reading_date date, p_reading_value numeric default null, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_today date := public.manila_today(); v_ucfg jsonb; v_open date; v_b public.utility_bills%rowtype; v_id uuid; v_id2 uuid;
  v_period text; v_max text; v_from date; v_to date; v_prev date; v_low date; v_next date; v_est numeric; v_warn boolean; v_rv numeric; v_new uuid;
begin
  if v_uid is null or p_property_id is null or not public.bill_can_v1(p_property_id) then return jsonb_build_object('ok', false, 'reason', 'not_authorized'); end if;
  if p_kind is null or p_kind not in ('electric', 'water') then return jsonb_build_object('ok', false, 'reason', 'bad_kind'); end if;
  if p_reading_value is not null then
    v_rv := round(p_reading_value, 2);
    if p_reading_value < 0 or v_rv >= 10000000000 then return jsonb_build_object('ok', false, 'reason', 'reading_value_invalid'); end if;
  end if;
  v_ucfg := public.utility_billing_cfg_v1();
  v_open := (v_ucfg -> p_kind ->> 'open_from')::date;
  -- same lock order as settle: the bill row first, then the meter lock; the oldest open bill is looked up again once both are held
  select b.id into v_id from public.utility_bills b where b.property_id = p_property_id and b.kind = p_kind and b.status in ('due', 'paying') order by b.period limit 1;
  if v_id is not null then select * into v_b from public.utility_bills where id = v_id for update; end if;
  perform pg_advisory_xact_lock(hashtextextended('bill_reading:' || p_property_id::text || ':' || p_kind, 0));
  select b.id into v_id2 from public.utility_bills b where b.property_id = p_property_id and b.kind = p_kind and b.status in ('due', 'paying') order by b.period limit 1;
  if v_id2 is distinct from v_id then
    return jsonb_build_object('ok', false, 'reason', case when v_id is not null and coalesce((select o.status from public.utility_bills o where o.id = v_id), '') = 'paid' then 'already_paid' else 'older_bill_open' end);
  end if;
  -- the reading date of a bill that is already paid is closed
  if p_reading_date is not null and exists (select 1 from public.utility_bills o where o.property_id = p_property_id and o.kind = p_kind and o.status = 'paid' and o.reading_date = p_reading_date) then
    return jsonb_build_object('ok', false, 'reason', 'already_paid');
  end if;

  if v_b.id is not null then
    v_period := v_b.period;
    select r.row_from, r.row_to into v_from, v_to from public.utility_meter_rows_v1(p_property_id, p_kind) r where r.id = v_b.id;
  else
    -- no open bill: the new row is the cycle being closed, i.e. the month of the ASSUMED reading date of the next slot (a reading that slips over a month end stays in that month); never a month that already has a row
    select r.row_from, r.row_to into v_from, v_to from public.utility_meter_rows_v1(p_property_id, p_kind, 'zzzz-99') r where r.period = 'zzzz-99';
    v_period := to_char(v_to, 'YYYY-MM');
    select max(b.period) into v_max from public.utility_bills b where b.property_id = p_property_id and b.kind = p_kind;
    if v_max is not null and v_period <= v_max then v_period := to_char(public.utility_safe_date_v1(v_max || '-01') + interval '1 month', 'YYYY-MM'); end if;
  end if;

  -- the date must move the cycle forward: after the previous real reading of an earlier period (open_from while none), not before the 1st of the month before the billed period, not after Manila today,
  -- and before the earliest real reading of a later period (any bill status)
  v_prev := coalesce((select max(o.reading_date) from public.utility_bills o where o.property_id = p_property_id and o.kind = p_kind and o.reading_date is not null and o.period < v_period), v_open);
  v_low := (public.utility_safe_date_v1(v_period || '-01') - interval '1 month')::date;
  v_next := (select min(o.reading_date) from public.utility_bills o where o.property_id = p_property_id and o.kind = p_kind and o.reading_date is not null and o.period > v_period);
  if p_reading_date is null or p_reading_date <= v_prev or p_reading_date < v_low then
    return jsonb_build_object('ok', false, 'reason', 'reading_date_invalid', 'after', greatest(v_prev, v_low - 1));
  end if;
  if p_reading_date > v_today then return jsonb_build_object('ok', false, 'reason', 'reading_date_invalid', 'before', v_today + 1); end if;
  if v_next is not null and p_reading_date >= v_next then return jsonb_build_object('ok', false, 'reason', 'reading_date_invalid', 'before', v_next); end if;
  -- an open bill with no date yet cannot take a reading that already belongs to the next cycle: that bill is the one still waiting
  if v_b.id is not null and v_b.reading_date is null and p_reading_date >= public.utility_add_months_v1(v_to, 1) then
    return jsonb_build_object('ok', false, 'reason', 'older_bill_open');
  end if;

  v_est := public.utility_cycle_php_v1(p_property_id, p_kind, v_from, p_reading_date, v_ucfg);
  v_warn := public.utility_reading_warn_v1(p_property_id, p_kind, p_reading_date, v_rv);
  v_new := v_b.id;
  if not coalesce(p_preview, false) then
    perform set_config('cascade.audit_reason', 'bill reading set by ' || public.bill_actor_name_v1(v_uid), true);
    begin
      if v_b.id is not null then
        update public.utility_bills set reading_date = p_reading_date, reading_value = coalesce(v_rv, reading_value), estimate_php = coalesce(v_est, estimate_php) where id = v_b.id;
      else
        insert into public.utility_bills(property_id, kind, period, estimate_php, reading_date, reading_value) values (p_property_id, p_kind, v_period, v_est, p_reading_date, v_rv) returning id into v_new;
      end if;
    exception when unique_violation then
      return jsonb_build_object('ok', false, 'reason', 'older_bill_open');
    end;
  end if;
  return jsonb_build_object('ok', true, 'bill_id', v_new, 'period', v_period, 'from', v_from, 'to', p_reading_date, 'estimate_php', v_est,
                            'next_reading', public.utility_add_months_v1(p_reading_date, 1), 'reading_warn', coalesce(v_warn, false), 'preview', coalesce(p_preview, false));
end $$;

-- 6. grants (ML-21), restated -----------------------------------------------------------------------------------------------------------------------------------------------------------------
revoke all on function public.utility_add_months_v1(date, integer) from public, anon, authenticated, service_role;
revoke all on function public.utility_meter_rows_v1(uuid, text, text) from public, anon, authenticated, service_role;
revoke all on function public.utility_meter_cycle_v1(uuid, text, date, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.utility_cycle_php_v1(uuid, text, date, date, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.utility_bill_span_v1(uuid, text, uuid) from public, anon, authenticated, service_role;
revoke all on function public.utility_last_bill_v1(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.bill_reading_set_v1(uuid, text, date, numeric, boolean) from public, anon, service_role;
grant execute on function public.bill_reading_set_v1(uuid, text, date, numeric, boolean) to authenticated;
revoke all on function public.utility_bill_estimate_v1(uuid, date) from public, anon, authenticated, service_role;
revoke all on function public.bill_entry_v1(public.utility_bills, jsonb, boolean, uuid) from public, anon, authenticated, service_role;
revoke all on function public.bill_due_open_v1(uuid, date, text) from public, anon, authenticated, service_role;
revoke all on function public.bill_daily_v1(date, uuid) from public, anon, authenticated, service_role;
revoke all on function public.bill_step_v1(uuid, text, uuid, text, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.bill_pay_open_v1(uuid) from public, anon, service_role;
grant execute on function public.bill_pay_open_v1(uuid) to authenticated;
revoke all on function public.bill_pay_settle_v1(uuid, jsonb) from public, anon, service_role;
grant execute on function public.bill_pay_settle_v1(uuid, jsonb) to authenticated;
revoke all on function public.today_bills_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.today_bills_v1(uuid) to authenticated;
revoke all on function public.expenses_screen_v1(uuid, date, integer, timestamptz, text, uuid) from public, anon, service_role;
grant execute on function public.expenses_screen_v1(uuid, date, integer, timestamptz, text, uuid) to authenticated;
revoke all on function public.admin_save_transaction_v2(uuid, jsonb, text) from public, anon, service_role;
grant execute on function public.admin_save_transaction_v2(uuid, jsonb, text) to authenticated;

comment on function public.utility_bill_estimate_v1(uuid, date) is 's143: internal. The open cycle of each meter: from = the newest REAL reading_date of that kind (any bill status) on or before p_on, else the setting open_from, plus the whole months that fit before p_on (an assumed date: anchor + n months, month end clamped, anchor day kept); to = one month after from. Same keys as s131 (overdue is now always false). Counted readings = meter_chain_v1.';
comment on function public.today_bills_v1(uuid) is 's143: the electricity and water bill so far for the Today tab (since per meter, cycle_from, cycle_from_assumed, next_reading; last_bill per meter and last_paid only for roles with approve_payment) plus the bills to pay (due: status due or paying only) for those roles (can_pay_list true); other roles get due [] and check_bills. waiting_for / water_waiting_for stay as keys and are null (a cycle is never overdue: the boundary moves on). Every active staff role of the property (read_operations); anyone else 42501.';
comment on function public.bill_pay_settle_v1(uuid, jsonb) is 's143: approve_payment. p_proof {path, sha256, amount, confirmed, reading_date (electric and water; else the date already set by bill_reading_set_v1), reading_value (optional, never wipes a stored one), paid_on (YYYY-MM-DD, default today), method (gcash|bank|cash|card|other)}; one expense row. Refusals: not_authorized, not_found, already_paid, not_payer, bad_proof, older_bill_open, reading_date_required, reading_date_invalid (after / before, any bill status), reading_value_invalid, paid_on_invalid, bad_method, no_stored_proof, sha_mismatch, duplicate_proof, bad_amount, confirm_amount. Adds reading_date and reading_warn.';
comment on function public.bill_reading_set_v1(uuid, text, date, numeric, boolean) is 's143: approve_payment. Sets the reading date (and optionally the present reading) of the oldest open bill of electric or water (creates the row of the cycle being closed when none is open); p_preview writes nothing. Answer {ok, bill_id, period, from, to, estimate_php, next_reading, reading_warn, preview}. Refusals: not_authorized, bad_kind, reading_date_invalid (after | before), reading_value_invalid, already_paid, older_bill_open.';

-- forward check ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
do $$
declare r record; v text;
begin
  for r in select * from (values
    ('public.utility_bill_estimate_v1(uuid,date)', '615c5e6719f1d35872e885c6f5084587'),
    ('public.bill_entry_v1(public.utility_bills,jsonb,boolean,uuid)', 'b9445c74b9de12d095258176dbba99df'),
    ('public.bill_due_open_v1(uuid,date,text)', 'c5781b6c5b7c59e8621b17fef0a2d29a'),
    ('public.bill_daily_v1(date,uuid)', '1726ac329d265f98a9c345aae083d729'),
    ('public.bill_step_v1(uuid,text,uuid,text,jsonb)', '44d8d6670985d060556cd772cc61b3c4'),
    ('public.bill_pay_open_v1(uuid)', 'b090554ca873215100d9167579c0facc'),
    ('public.bill_pay_settle_v1(uuid,jsonb)', '591176b334a7f6089a25b79ee2a4b245'),
    ('public.today_bills_v1(uuid)', '563053ef8469130428e9d35f09cc7762'),
    ('public.expenses_screen_v1(uuid,date,integer,timestamptz,text,uuid)', '87d5b34bc801736104bf69da5019b792'),
    ('public.admin_save_transaction_v2(uuid,jsonb,text)', '2eebbce5a512ddf389b6361ff85ae74d')
  ) t(sig, m) loop
    select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure(r.sig);
    if v is distinct from r.m then raise exception 's143: % is not the s143 body (md5 %)', r.sig, coalesce(v, 'null'); end if;
  end loop;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'transactions' and column_name = 'payment_method') then raise exception 's143: transactions.payment_method missing'; end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.transactions'::regclass and conname = 'transactions_payment_method_check') then raise exception 's143: payment_method check missing'; end if;
  if has_function_privilege('anon', 'public.utility_add_months_v1(date,integer)', 'execute') or has_function_privilege('authenticated', 'public.utility_add_months_v1(date,integer)', 'execute') or has_function_privilege('service_role', 'public.utility_add_months_v1(date,integer)', 'execute') then raise exception 's143: an API role can run public.utility_add_months_v1(date,integer)'; end if;
  if has_function_privilege('anon', 'public.utility_meter_rows_v1(uuid,text,text)', 'execute') or has_function_privilege('authenticated', 'public.utility_meter_rows_v1(uuid,text,text)', 'execute') or has_function_privilege('service_role', 'public.utility_meter_rows_v1(uuid,text,text)', 'execute') then raise exception 's143: an API role can run public.utility_meter_rows_v1(uuid,text,text)'; end if;
  if has_function_privilege('anon', 'public.utility_meter_cycle_v1(uuid,text,date,jsonb)', 'execute') or has_function_privilege('authenticated', 'public.utility_meter_cycle_v1(uuid,text,date,jsonb)', 'execute') or has_function_privilege('service_role', 'public.utility_meter_cycle_v1(uuid,text,date,jsonb)', 'execute') then raise exception 's143: an API role can run public.utility_meter_cycle_v1(uuid,text,date,jsonb)'; end if;
  if has_function_privilege('anon', 'public.utility_cycle_php_v1(uuid,text,date,date,jsonb)', 'execute') or has_function_privilege('authenticated', 'public.utility_cycle_php_v1(uuid,text,date,date,jsonb)', 'execute') or has_function_privilege('service_role', 'public.utility_cycle_php_v1(uuid,text,date,date,jsonb)', 'execute') then raise exception 's143: an API role can run public.utility_cycle_php_v1(uuid,text,date,date,jsonb)'; end if;
  if has_function_privilege('anon', 'public.utility_bill_span_v1(uuid,text,uuid)', 'execute') or has_function_privilege('authenticated', 'public.utility_bill_span_v1(uuid,text,uuid)', 'execute') or has_function_privilege('service_role', 'public.utility_bill_span_v1(uuid,text,uuid)', 'execute') then raise exception 's143: an API role can run public.utility_bill_span_v1(uuid,text,uuid)'; end if;
  if has_function_privilege('anon', 'public.utility_last_bill_v1(uuid,text)', 'execute') or has_function_privilege('authenticated', 'public.utility_last_bill_v1(uuid,text)', 'execute') or has_function_privilege('service_role', 'public.utility_last_bill_v1(uuid,text)', 'execute') then raise exception 's143: an API role can run public.utility_last_bill_v1(uuid,text)'; end if;
  if has_function_privilege('anon', 'public.bill_reading_set_v1(uuid,text,date,numeric,boolean)', 'execute') or has_function_privilege('service_role', 'public.bill_reading_set_v1(uuid,text,date,numeric,boolean)', 'execute') or not has_function_privilege('authenticated', 'public.bill_reading_set_v1(uuid,text,date,numeric,boolean)', 'execute') then raise exception 's143: wrong grants on public.bill_reading_set_v1(uuid,text,date,numeric,boolean)'; end if;
  if has_function_privilege('anon', 'public.utility_bill_estimate_v1(uuid,date)', 'execute') or has_function_privilege('authenticated', 'public.utility_bill_estimate_v1(uuid,date)', 'execute') or has_function_privilege('service_role', 'public.utility_bill_estimate_v1(uuid,date)', 'execute') then raise exception 's143: an API role can run public.utility_bill_estimate_v1(uuid,date)'; end if;
  if has_function_privilege('anon', 'public.bill_entry_v1(public.utility_bills,jsonb,boolean,uuid)', 'execute') or has_function_privilege('authenticated', 'public.bill_entry_v1(public.utility_bills,jsonb,boolean,uuid)', 'execute') or has_function_privilege('service_role', 'public.bill_entry_v1(public.utility_bills,jsonb,boolean,uuid)', 'execute') then raise exception 's143: an API role can run public.bill_entry_v1(public.utility_bills,jsonb,boolean,uuid)'; end if;
  if has_function_privilege('anon', 'public.bill_due_open_v1(uuid,date,text)', 'execute') or has_function_privilege('authenticated', 'public.bill_due_open_v1(uuid,date,text)', 'execute') or has_function_privilege('service_role', 'public.bill_due_open_v1(uuid,date,text)', 'execute') then raise exception 's143: an API role can run public.bill_due_open_v1(uuid,date,text)'; end if;
  if has_function_privilege('anon', 'public.bill_daily_v1(date,uuid)', 'execute') or has_function_privilege('authenticated', 'public.bill_daily_v1(date,uuid)', 'execute') or has_function_privilege('service_role', 'public.bill_daily_v1(date,uuid)', 'execute') then raise exception 's143: an API role can run public.bill_daily_v1(date,uuid)'; end if;
  if has_function_privilege('anon', 'public.bill_step_v1(uuid,text,uuid,text,jsonb)', 'execute') or has_function_privilege('authenticated', 'public.bill_step_v1(uuid,text,uuid,text,jsonb)', 'execute') or has_function_privilege('service_role', 'public.bill_step_v1(uuid,text,uuid,text,jsonb)', 'execute') then raise exception 's143: an API role can run public.bill_step_v1(uuid,text,uuid,text,jsonb)'; end if;
  if has_function_privilege('anon', 'public.bill_pay_open_v1(uuid)', 'execute') or has_function_privilege('service_role', 'public.bill_pay_open_v1(uuid)', 'execute') or not has_function_privilege('authenticated', 'public.bill_pay_open_v1(uuid)', 'execute') then raise exception 's143: wrong grants on public.bill_pay_open_v1(uuid)'; end if;
  if has_function_privilege('anon', 'public.bill_pay_settle_v1(uuid,jsonb)', 'execute') or has_function_privilege('service_role', 'public.bill_pay_settle_v1(uuid,jsonb)', 'execute') or not has_function_privilege('authenticated', 'public.bill_pay_settle_v1(uuid,jsonb)', 'execute') then raise exception 's143: wrong grants on public.bill_pay_settle_v1(uuid,jsonb)'; end if;
  if has_function_privilege('anon', 'public.today_bills_v1(uuid)', 'execute') or has_function_privilege('service_role', 'public.today_bills_v1(uuid)', 'execute') or not has_function_privilege('authenticated', 'public.today_bills_v1(uuid)', 'execute') then raise exception 's143: wrong grants on public.today_bills_v1(uuid)'; end if;
  if has_function_privilege('anon', 'public.expenses_screen_v1(uuid,date,integer,timestamptz,text,uuid)', 'execute') or has_function_privilege('service_role', 'public.expenses_screen_v1(uuid,date,integer,timestamptz,text,uuid)', 'execute') or not has_function_privilege('authenticated', 'public.expenses_screen_v1(uuid,date,integer,timestamptz,text,uuid)', 'execute') then raise exception 's143: wrong grants on public.expenses_screen_v1(uuid,date,integer,timestamptz,text,uuid)'; end if;
  if has_function_privilege('anon', 'public.admin_save_transaction_v2(uuid,jsonb,text)', 'execute') or has_function_privilege('service_role', 'public.admin_save_transaction_v2(uuid,jsonb,text)', 'execute') or not has_function_privilege('authenticated', 'public.admin_save_transaction_v2(uuid,jsonb,text)', 'execute') then raise exception 's143: wrong grants on public.admin_save_transaction_v2(uuid,jsonb,text)'; end if;
  if public.utility_add_months_v1(date '2027-01-31', 1) <> date '2027-02-28' or public.utility_add_months_v1(date '2027-01-31', 2) <> date '2027-03-31' then raise exception 's143: month-end anchors are wrong'; end if;
end $$;
