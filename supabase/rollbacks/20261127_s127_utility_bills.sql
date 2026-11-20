-- Rollback of s127_utility_bills_20261127: puts the s115 kpi_tab_v1 body back (md5 229c75a34209e1820c3e0209e8d67adf, CR stripped), drops the new functions and removes the utility_billing setting.
-- Roll the staff app back first (an old build ignores the extra keys, so this is safe in either order for old builds). Grants restated as before this release.
begin;

do $g$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.kpi_tab_v1(uuid,date)');
  if v is distinct from '80efd89e916bcd6107c681baf86f143f' and v is distinct from '229c75a34209e1820c3e0209e8d67adf' then
    raise exception using errcode = '55000', message = 'rollback s127: public.kpi_tab_v1(uuid,date) is neither this release nor the s115 body (md5 ' || coalesce(v, 'null') || ')';
  end if;
end $g$;

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
  end if;
  return v_out;
end;
$body$
;
revoke all on function public.kpi_tab_v1(uuid,date) from public, anon, service_role;
grant execute on function public.kpi_tab_v1(uuid,date) to authenticated;

drop function if exists public.today_bills_v1(uuid);
drop function if exists public.kpi_admin_bills_v1(uuid, numeric);
drop function if exists public.kpi_usage_months_v1(uuid, date);
drop function if exists public.utility_bill_estimate_v1(uuid, date);
drop function if exists public.utility_water_next_v1(numeric, jsonb);
drop function if exists public.utility_water_php_v1(numeric, jsonb);
drop function if exists public.utility_daily_use_v1(uuid, date, date);
drop function if exists public.utility_rate_by_month_v1();
drop function if exists public.utility_cycle_v1(date, integer);
drop function if exists public.utility_cycle_day_v1(date, integer);
drop function if exists public.utility_billing_cfg_v1();
drop function if exists public.utility_cfg_num_v1(jsonb, jsonb);
drop function if exists public.utility_billing_default_v1();
delete from public.app_settings where key = 'utility_billing';

do $v$
begin
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.kpi_tab_v1(uuid,date)')) is distinct from '229c75a34209e1820c3e0209e8d67adf' then
    raise exception using errcode = '55000', message = 'rollback s127: kpi_tab_v1 is not back to the s115 body';
  end if;
end $v$;

commit;
