-- Session 111, lane S (SQL): release s111_kpi_stay_avg_20261113. Lloyd 2026-11-08: the KPI tab shows the average electricity and water per stay, ported from the admin Insights utilities chart.
-- kpi_tab_v1 is redefined from its LIVE body (20261112000000_s110_kpi_supply_laundry.sql, section 4); ONLY the utility block changes, every other key, gate and grant is as in s110:
--   utility.m3_month / m3_per_night (water, same month and reading rule as kwh_month / kwh_per_night), utility.per_stay[].m3_per_night, and the new utility.per_month:
--   12 Manila months ending with the selected one, oldest first, [{month 'YYYY-MM', stays, kwh_per_stay (1 dp), m3_per_stay (2 dp), kwh_per_night, m3_per_night}], null figures for an empty month.
-- No money in these keys; every role with read_operations sees them. The admin key stays absent without read_finance. Expand only: the old app ignores the new keys.
begin;

create or replace function public.kpi_tab_v1(p_property_id uuid, p_month date default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_today date := public.manila_today(); v_m0 date; v_m1 date; v_fin boolean;
  v_kwh numeric; v_nights numeric; v_last jsonb; v_per jsonb; v_bo jsonb; v_wc jsonb; v_inv jsonb; v_out jsonb;
  v_turn integer; v_turn90 integer; v_rate public.utility_rates%rowtype; v_lastd numeric; v_usage_cost numeric; v_ic jsonb;
  v_fs jsonb; v_hm jsonb; v_sold numeric; v_dn numeric; v_mcost numeric; v_m3 numeric; v_nights_w numeric; v_pm jsonb;
begin
  if auth.uid() is null or not public.current_staff_authorized('read_operations', p_property_id) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  v_fin := public.current_staff_authorized('read_finance', p_property_id);
  v_m0 := date_trunc('month', coalesce(p_month, v_today))::date;
  v_m1 := (v_m0 + interval '1 month')::date;

  select coalesce(sum(mr.electric_delta), 0), coalesce(sum(cs.nights_stayed), 0) into v_kwh, v_nights
    from public.meter_readings mr join public.cleaning_sessions cs on cs.id = mr.session_id
   where mr.property_id = p_property_id and mr.electric_delta >= 0 and coalesce(cs.nights_stayed, 0) > 0
     and (mr.meter_flag is null or mr.meter_flag in ('typed_accepted', 'estimated'))
     and (mr.recorded_at at time zone 'Asia/Manila')::date >= v_m0 and (mr.recorded_at at time zone 'Asia/Manila')::date < v_m1;

  select coalesce(sum(mr.water_delta), 0), coalesce(sum(cs.nights_stayed), 0) into v_m3, v_nights_w
    from public.meter_readings mr join public.cleaning_sessions cs on cs.id = mr.session_id
   where mr.property_id = p_property_id and mr.water_delta >= 0 and coalesce(cs.nights_stayed, 0) > 0
     and (mr.meter_flag is null or mr.meter_flag in ('typed_accepted', 'estimated'))
     and (mr.recorded_at at time zone 'Asia/Manila')::date >= v_m0 and (mr.recorded_at at time zone 'Asia/Manila')::date < v_m1;

  select jsonb_build_object('recorded_at', x.recorded_at, 'delta_kwh', x.electric_delta, 'nights', x.nights_stayed, 'kwh_per_night', x.kwh_per_night, 'flag', x.meter_flag)
    into v_last
    from (select mr.recorded_at, mr.electric_delta, cs.nights_stayed, mr.kwh_per_night, mr.meter_flag
            from public.meter_readings mr left join public.cleaning_sessions cs on cs.id = mr.session_id
           where mr.property_id = p_property_id and mr.electric_delta is not null and mr.electric_delta >= 0
             and (mr.meter_flag is null or mr.meter_flag in ('typed_accepted', 'estimated'))
           order by mr.recorded_at desc, mr.id limit 1) x;
  v_lastd := (v_last ->> 'delta_kwh')::numeric;

  select coalesce(jsonb_agg(jsonb_build_object('checkout_date', y.checkout_date, 'kwh_per_night', y.kwh_per_night, 'm3_per_night', case when y.m3_per_night >= 0 then y.m3_per_night end) order by y.sort_d, y.recorded_at), '[]'::jsonb) into v_per
    from (select cs.checkout_date, mr.kwh_per_night, mr.m3_per_night, mr.recorded_at, coalesce(cs.checkout_date, (mr.recorded_at at time zone 'Asia/Manila')::date) sort_d
            from public.meter_readings mr left join public.cleaning_sessions cs on cs.id = mr.session_id
           where mr.property_id = p_property_id and mr.kwh_per_night is not null and mr.kwh_per_night >= 0
             and (mr.meter_flag is null or mr.meter_flag in ('typed_accepted', 'estimated'))
           order by coalesce(cs.checkout_date, (mr.recorded_at at time zone 'Asia/Manila')::date) desc, mr.recorded_at desc limit 8) y;

  -- per_month: the last 12 Manila months ending with the selected one, oldest first, one row per month. A consumption reading (the admin Insights rule plus the s100 flag allowlist):
  -- both previous meter values > 0, both deltas >= 0. stays = those readings; per_stay = sum(delta) / stays; per_night = sum(delta) / sum(nights) over the readings whose stay has nights > 0.
  select jsonb_agg(jsonb_build_object('month', to_char(g.m, 'YYYY-MM'), 'stays', coalesce(a.n, 0),
                                      'kwh_per_stay', case when a.n > 0 then round(a.e / a.n, 1) end, 'm3_per_stay', case when a.n > 0 then round(a.w / a.n, 2) end,
                                      'kwh_per_night', case when a.nn > 0 then round(a.en / a.nn, 2) end, 'm3_per_night', case when a.nn > 0 then round(a.wn / a.nn, 2) end) order by g.m) into v_pm
    from (select (v_m0 - (k * interval '1 month'))::date m from generate_series(0, 11) k) g
    left join (select date_trunc('month', mr.recorded_at at time zone 'Asia/Manila')::date m, count(*)::integer n, sum(mr.electric_delta) e, sum(mr.water_delta) w,
                      sum(mr.electric_delta) filter (where coalesce(cs.nights_stayed, 0) > 0) en, sum(mr.water_delta) filter (where coalesce(cs.nights_stayed, 0) > 0) wn,
                      sum(cs.nights_stayed) filter (where coalesce(cs.nights_stayed, 0) > 0) nn
                 from public.meter_readings mr left join public.cleaning_sessions cs on cs.id = mr.session_id
                where mr.property_id = p_property_id and mr.electric_prev > 0 and mr.water_prev > 0 and mr.electric_delta >= 0 and mr.water_delta >= 0
                  and (mr.meter_flag is null or mr.meter_flag in ('typed_accepted', 'estimated'))
                  and (mr.recorded_at at time zone 'Asia/Manila')::date >= (v_m0 - interval '11 months')::date and (mr.recorded_at at time zone 'Asia/Manila')::date < v_m1
                group by 1) a on a.m = g.m;

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
    'utility', jsonb_build_object('kwh_month', round(v_kwh, 2), 'nights_month', v_nights, 'kwh_per_night', case when v_nights > 0 then round(v_kwh / v_nights, 2) end,
                                  'm3_month', round(v_m3, 2), 'm3_per_night', case when v_nights_w > 0 then round(v_m3 / v_nights_w, 2) end,
                                  'last_reading', v_last, 'per_stay', v_per, 'per_month', v_pm, 'brownouts', v_bo, 'water_cuts', v_wc, 'internet_cuts', v_ic),
    'inventory', v_inv);

  if v_fin then
    select * into v_rate from public.utility_rates r where r.effective_from <= v_today
     order by date_trunc('month', r.effective_from) desc, (r.source = 'manual') desc, r.effective_from desc, r.created_at desc limit 1;
    -- each usable reading is costed at the rate in force on its own day (latest month first, a manual correction beats an auto read of the same month)
    select sum(mr.electric_delta * rt.php_per_kwh) into v_mcost
      from public.meter_readings mr join public.cleaning_sessions cs on cs.id = mr.session_id
      cross join lateral (select r.php_per_kwh from public.utility_rates r where r.effective_from <= (mr.recorded_at at time zone 'Asia/Manila')::date
                           order by date_trunc('month', r.effective_from) desc, (r.source = 'manual') desc, r.effective_from desc, r.created_at desc limit 1) rt
     where mr.property_id = p_property_id and mr.electric_delta >= 0 and coalesce(cs.nights_stayed, 0) > 0
       and (mr.meter_flag is null or mr.meter_flag in ('typed_accepted', 'estimated'))
       and (mr.recorded_at at time zone 'Asia/Manila')::date >= v_m0 and (mr.recorded_at at time zone 'Asia/Manila')::date < v_m1;
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
  end if;
  return v_out;
end;
$$;

revoke all on function public.kpi_tab_v1(uuid, date) from public, anon, authenticated, service_role;
grant execute on function public.kpi_tab_v1(uuid, date) to authenticated;

comment on function public.kpi_tab_v1(uuid, date) is 's111: the KPI tab. read_operations; utility carries m3 and per_month (average kWh and m3 per stay, 12 months); the `admin` key exists only with read_finance. No booking income.';

commit;
