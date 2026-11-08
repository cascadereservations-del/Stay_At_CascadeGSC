-- Rollback for s111_kpi_stay_avg_20261113: puts kpi_tab_v1 back to its s110 body (20261112000000_s110_kpi_supply_laundry.sql, section 4) exactly, then drops kpi_target_set_v1 and the kpi_targets table (rev 2; the owner's monthly target is lost and must be set again after a re-apply).
begin;

create or replace function public.kpi_tab_v1(p_property_id uuid, p_month date default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_today date := public.manila_today(); v_m0 date; v_m1 date; v_fin boolean;
  v_kwh numeric; v_nights numeric; v_last jsonb; v_per jsonb; v_bo jsonb; v_wc jsonb; v_inv jsonb; v_out jsonb;
  v_turn integer; v_turn90 integer; v_rate public.utility_rates%rowtype; v_lastd numeric; v_usage_cost numeric; v_ic jsonb;
  v_fs jsonb; v_hm jsonb; v_sold numeric; v_dn numeric; v_mcost numeric;
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

  select jsonb_build_object('recorded_at', x.recorded_at, 'delta_kwh', x.electric_delta, 'nights', x.nights_stayed, 'kwh_per_night', x.kwh_per_night, 'flag', x.meter_flag)
    into v_last
    from (select mr.recorded_at, mr.electric_delta, cs.nights_stayed, mr.kwh_per_night, mr.meter_flag
            from public.meter_readings mr left join public.cleaning_sessions cs on cs.id = mr.session_id
           where mr.property_id = p_property_id and mr.electric_delta is not null and mr.electric_delta >= 0
             and (mr.meter_flag is null or mr.meter_flag in ('typed_accepted', 'estimated'))
           order by mr.recorded_at desc, mr.id limit 1) x;
  v_lastd := (v_last ->> 'delta_kwh')::numeric;

  select coalesce(jsonb_agg(jsonb_build_object('checkout_date', y.checkout_date, 'kwh_per_night', y.kwh_per_night) order by y.sort_d, y.recorded_at), '[]'::jsonb) into v_per
    from (select cs.checkout_date, mr.kwh_per_night, mr.recorded_at, coalesce(cs.checkout_date, (mr.recorded_at at time zone 'Asia/Manila')::date) sort_d
            from public.meter_readings mr left join public.cleaning_sessions cs on cs.id = mr.session_id
           where mr.property_id = p_property_id and mr.kwh_per_night is not null and mr.kwh_per_night >= 0
             and (mr.meter_flag is null or mr.meter_flag in ('typed_accepted', 'estimated'))
           order by coalesce(cs.checkout_date, (mr.recorded_at at time zone 'Asia/Manila')::date) desc, mr.recorded_at desc limit 8) y;

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
                                  'last_reading', v_last, 'per_stay', v_per, 'brownouts', v_bo, 'water_cuts', v_wc, 'internet_cuts', v_ic),
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

comment on function public.kpi_tab_v1(uuid, date) is 's110: the KPI tab. read_operations; the `admin` key (rate, costs, supplies, cleaning pay) exists only with read_finance. No booking income.';

drop function if exists public.kpi_target_set_v1(uuid, numeric);
drop table if exists public.kpi_targets;

commit;
