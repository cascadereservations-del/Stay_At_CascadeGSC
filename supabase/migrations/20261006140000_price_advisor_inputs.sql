-- Session 72, SPEC-35 / SPEC-42 item 1: the price advisor's read-only inputs.
-- price_advisor_inputs_v1(property, from, to) returns, for each calendar month in the range, what the same month last year looked
-- like (nights sold on Airbnb and direct, nights we could actually sell, money paid out per Airbnb night), how many nights are
-- held this year (brownout / maintenance / owner use), plus the trailing-12-month expenses by category and the fee Airbnb took.
-- It only reads. The advisor (admin dashboard, features/pricing/advisor.ts) does all the arithmetic and only suggests a number.
--
-- Rules baked in here, each one tested in supabase/tests/database/price_advisor_inputs.sql:
--   * A night is occupied once: Airbnb reservations, confirmed direct inquiries and confirmed calendar events are merged per DATE,
--     so a direct stay that has both an inquiry and a calendar row is not counted twice.
--   * Held nights (blocked + brownout / maintenance / owner_use, explained by the system or a person - not "assumed") are not
--     sellable capacity (SPEC-41 Q1, recommended answer). A held night that is also occupied is counted as occupied only.
--   * History starts at the first stay on record. Days of last year before that, and days not yet over, are not counted as
--     capacity; with none left the month's last-year figures are null (unknown), never 0.
--   * Expenses: every non-void expense in the 12 months before the first target month (or this month, if earlier). The page decides
--     which categories to include; rows before acct_settings.accounting_start are totalled separately as estimates.
-- Read-only, security definer, empty search_path, gated on read_finance (owner / admin / finance), authenticated only.
-- Rollback: supabase/rollbacks/20261006_price_advisor_inputs.sql

begin;

create or replace function public.price_advisor_inputs_v1(p_property_id uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_today date := public.manila_today();
  v_from date; v_to date; v_hist date; v_start date;
  v_win_end date; v_win_start date; v_first_exp date; v_exp_months int;
  v_months jsonb; v_cats jsonb; v_fee jsonb;
begin
  perform public.admin_require('read_finance', p_property_id);
  if p_from is null or p_to is null or p_to < p_from then
    raise exception using errcode = '22023', message = 'p_from and p_to must be dates with p_to on or after p_from';
  end if;
  v_from := date_trunc('month', p_from)::date;
  v_to := date_trunc('month', p_to)::date;
  if v_to > (v_from + interval '11 months')::date then
    raise exception using errcode = '22023', message = 'at most 12 months at a time';
  end if;

  -- First night on record: nothing before it is known, so it is not capacity.
  select min(d) into v_hist from (
    select min(checkin_date) d from public.airbnb_reservations where property_id = p_property_id and status in ('completed', 'confirmed')
    union all select min(checkin_date) from public.booking_inquiries where property_id = p_property_id and status = 'confirmed'
    union all select min(checkin_date) from public.calendar_events where property_id = p_property_id and status = 'confirmed'
  ) h;
  select accounting_start into v_start from public.acct_settings where property_id = p_property_id;

  with m as (
    select g::date as ms, (g + interval '1 month')::date as me, (g - interval '1 year')::date as ls, (g - interval '1 year' + interval '1 month')::date as le
    from generate_series(v_from::timestamp, v_to::timestamp, interval '1 month') g
  ),
  src as (
    select checkin_date ci, checkout_date co, 'airbnb'::text ch from public.airbnb_reservations
      where property_id = p_property_id and status in ('completed', 'confirmed')
    union all select checkin_date, checkout_date, 'direct' from public.booking_inquiries
      where property_id = p_property_id and status = 'confirmed'
    union all select checkin_date, checkout_date, case when source = 'airbnb' then 'airbnb' else 'direct' end from public.calendar_events
      where property_id = p_property_id and status = 'confirmed'
  ),
  nights as (
    select d::date as night, bool_or(s.ch = 'airbnb') as is_airbnb
    from src s, generate_series(s.ci::timestamp, (s.co - 1)::timestamp, interval '1 day') d
    where s.co > s.ci group by 1
  ),
  held as (
    select distinct d::date as night
    from public.calendar_events e, generate_series(e.checkin_date::timestamp, (e.checkout_date - 1)::timestamp, interval '1 day') d
    where e.property_id = p_property_id and e.status = 'blocked' and e.checkout_date > e.checkin_date
      and e.block_reason in ('brownout', 'maintenance', 'owner_use') and e.block_reason_source in ('auto', 'staff')
  ),
  held_free as (select h.night from held h where not exists (select 1 from nights n where n.night = h.night)),
  pay as (
    select d::date as night, r.host_payout / (r.checkout_date - r.checkin_date) as per_night
    from public.airbnb_reservations r, generate_series(r.checkin_date::timestamp, (r.checkout_date - 1)::timestamp, interval '1 day') d
    where r.property_id = p_property_id and r.status in ('completed', 'confirmed') and r.host_payout is not null and r.checkout_date > r.checkin_date
  ),
  cov as (select m.*, case when v_hist is null then 0 else greatest(0, least(m.le, v_today) - greatest(m.ls, v_hist)) end as covered from m)
  select coalesce(jsonb_agg(jsonb_build_object(
    'month', c.ms,
    'days', c.me - c.ms,
    'held_nights', (select count(*) from held_free f where f.night >= c.ms and f.night < c.me),
    'ly_month', c.ls,
    'ly_days_covered', c.covered,
    'ly_airbnb_nights', case when c.covered = 0 then null else (select count(*) from nights n where n.is_airbnb and n.night >= greatest(c.ls, v_hist) and n.night < least(c.le, v_today)) end,
    'ly_direct_nights', case when c.covered = 0 then null else (select count(*) from nights n where not n.is_airbnb and n.night >= greatest(c.ls, v_hist) and n.night < least(c.le, v_today)) end,
    'ly_held_nights', case when c.covered = 0 then null else (select count(*) from held_free f where f.night >= greatest(c.ls, v_hist) and f.night < least(c.le, v_today)) end,
    'ly_stays', (select count(*) from public.airbnb_reservations r where r.property_id = p_property_id and r.status in ('completed', 'confirmed') and r.checkin_date < c.le and r.checkout_date > c.ls)
              + (select count(*) from public.booking_inquiries b where b.property_id = p_property_id and b.status = 'confirmed' and b.checkin_date < c.le and b.checkout_date > c.ls)
              + (select count(*) from public.calendar_events e where e.property_id = p_property_id and e.status = 'confirmed' and e.source <> 'airbnb' and e.checkin_date < c.le and e.checkout_date > c.ls
                   and not exists (select 1 from public.booking_inquiries b where b.property_id = p_property_id and b.status = 'confirmed' and b.checkin_date = e.checkin_date and b.checkout_date = e.checkout_date)),
    'ly_payout_total', (select sum(p.per_night) from pay p where p.night >= c.ls and p.night < c.le),
    'ly_paid_nights', (select count(*) from pay p where p.night >= c.ls and p.night < c.le)
  ) order by c.ms), '[]'::jsonb) into v_months from cov c;

  v_win_end := least(v_from, date_trunc('month', v_today)::date);
  v_win_start := (v_win_end - interval '12 months')::date;
  select min(transaction_date) into v_first_exp from public.transactions
    where property_id = p_property_id and txn_type = 'expense' and status <> 'void' and transaction_date >= v_win_start and transaction_date < v_win_end;
  if v_first_exp is not null then
    v_exp_months := greatest(1, (extract(year from v_win_end)::int - extract(year from v_first_exp)::int) * 12 + extract(month from v_win_end)::int - extract(month from v_first_exp)::int);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('category', category, 'total', total, 'rows', n, 'estimate_total', est) order by category), '[]'::jsonb) into v_cats from (
    select t.category, sum(t.gross_amount) as total, count(*) as n,
           coalesce(sum(t.gross_amount) filter (where v_start is null or t.transaction_date < v_start), 0) as est
    from public.transactions t
    where t.property_id = p_property_id and t.txn_type = 'expense' and t.status <> 'void' and t.transaction_date >= v_win_start and t.transaction_date < v_win_end
    group by t.category
  ) x;

  -- The share of the gross Airbnb kept as its fee, over stays that have both figures.
  select jsonb_build_object('rate', case when sum(r.host_payout + r.host_service_fee) > 0 then sum(r.host_service_fee) / sum(r.host_payout + r.host_service_fee) end, 'stays', count(*)) into v_fee
  from public.airbnb_reservations r
  where r.property_id = p_property_id and r.status in ('completed', 'confirmed') and r.host_payout is not null and r.host_service_fee is not null
    and r.checkin_date >= v_win_start and r.checkin_date < v_win_end;

  return jsonb_build_object(
    'from', v_from, 'to', v_to, 'today', v_today, 'history_start', v_hist, 'accounting_start', v_start,
    'months', v_months,
    'expenses', jsonb_build_object('window_start', v_win_start, 'window_end', v_win_end, 'months_covered', v_exp_months, 'categories', v_cats),
    'airbnb_fee', v_fee);
end;
$$;
revoke all on function public.price_advisor_inputs_v1(uuid, date, date) from public, anon, service_role;
grant execute on function public.price_advisor_inputs_v1(uuid, date, date) to authenticated;
comment on function public.price_advisor_inputs_v1(uuid, date, date) is 'SPEC-35 price advisor: last-year occupancy, held nights, payout per night, trailing expenses and Airbnb fee share per month. Read-only; read_finance only.';

commit;
