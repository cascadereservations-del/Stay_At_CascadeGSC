-- Compensating rollback for 20261005140000_calendar_block_triage.sql (safe always). Restores the bodies production had before the
-- release (telegram_answer_calendar_block_v1 md5 7f43ea5d..., get_hospitality_metrics_v1 md5 0c2bc9ae...), then drops the two new functions.
-- The columns stay: they are additive and dropping them would lose the answers people gave.
-- Redeploy the previous calendar-sync and telegram-expense first (the cb:block tap calls v2 after this release).
begin;

create or replace function public.telegram_answer_calendar_block_v1(
  p_telegram_user_id bigint,
  p_uid              text,
  p_answer           text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  p public.staff_access_profiles%rowtype;
  v_status text;
begin
  if p_answer is null or p_answer not in ('maint', 'direct', 'unblock') then
    raise exception 'answer must be maint, direct or unblock' using errcode = '22023';
  end if;
  if p_telegram_user_id is null then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  select * into p from public.staff_access_profiles where telegram_user_id = p_telegram_user_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  if p.role not in ('owner', 'admin') or p.disabled_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;

  -- maint: the owner blocked it on purpose. direct: the direct row, when it arrives, is the evidence.
  -- unblock: the reaper cancels the row when the block leaves the feed.
  v_status := case p_answer when 'maint' then 'admin_block' else 'skipped' end;
  update public.calendar_events
     set recon_status = v_status
   where uid = p_uid and source = 'airbnb' and status = 'blocked' and recon_status = 'pending';
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_pending'); end if;

  return jsonb_build_object('ok', true, 'outcome', p_answer, 'recon_status', v_status, 'by', p.user_id);
end;
$function$;
revoke all on function public.telegram_answer_calendar_block_v1(bigint, text, text) from public, anon, authenticated;
grant execute on function public.telegram_answer_calendar_block_v1(bigint, text, text) to service_role;

create or replace function public.get_hospitality_metrics_v1(p_property_id uuid, p_start date, p_end_exclusive date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_fin boolean; v_today date; v_op_start date; v_cap integer; v_blocked integer;
  v_sold integer; v_rev numeric; v_rev_nights integer; v_rev_missing integer; v_rev_stays integer;
  v_alos numeric; v_alos_n integer; v_ret numeric; v_ret_n integer; v_ret_d integer;
  v_cancel_n integer; v_cancel_d integer; v_future integer; v_lead numeric; v_lead_n integer; v_lead_missing integer;
  v_cash numeric; v_cash_n integer; v_expected numeric; v_expected_n integer; v_asof timestamptz;
  v_def text := 'metrics.v1'; v_tok text;
  m jsonb := '{}'::jsonb;
begin
  perform public.admin_require('read_operations', p_property_id);
  v_fin := public.finance_human_authorized(p_property_id);
  if p_start is null or p_end_exclusive is null or p_end_exclusive <= p_start or p_end_exclusive - p_start > 800 then
    raise exception using errcode = '22023', message = 'invalid reporting period';
  end if;
  v_today := public.manila_today();
  select coalesce((select (value #>> '{}')::date from public.app_settings where key = 'operating_start_date'),
                  (select min(checkin) from public.admin_stays_v1(p_property_id) where status <> 'cancelled'))
    into v_op_start;
  v_cap := greatest(0, p_end_exclusive - greatest(p_start, coalesce(v_op_start, p_start)));
  v_tok := 'v1|' || p_property_id::text || '|' || p_start::text || '|' || p_end_exclusive::text;

  select greatest(max(x.asof), (select max(synced_at) from public.calendar_events where property_id = p_property_id)) into v_asof
  from (select max(updated_at) asof from public.airbnb_reservations where property_id = p_property_id
        union all select max(updated_at) from public.booking_inquiries where property_id = p_property_id
        union all select max(updated_at) from public.transactions where property_id = p_property_id) x;

  -- Blocked (imported) nights in period: shown as an exception, never as sold.
  select count(distinct d)::int into v_blocked
  from public.calendar_events c
  cross join lateral generate_series(greatest(c.checkin_date, p_start), least(c.checkout_date, p_end_exclusive) - 1, interval '1 day') d
  where c.property_id = p_property_id and c.status = 'blocked' and c.checkin_date < p_end_exclusive and c.checkout_date > p_start;

  -- Sold nights: distinct calendar nights covered by a non-cancelled stay.
  select count(distinct d)::int into v_sold
  from public.admin_stays_v1(p_property_id) s
  cross join lateral generate_series(greatest(s.checkin, p_start), least(s.checkout, p_end_exclusive) - 1, interval '1 day') d
  where s.status in ('confirmed','completed') and s.checkin < p_end_exclusive and s.checkout > p_start;

  -- Accommodation revenue allocated to nights inside the period.
  with st as (
    select s.*, public.allocate_nightly_v1(s.accommodation_total, s.nights) alloc
    from public.admin_stays_v1(p_property_id) s
    where s.status in ('confirmed','completed') and s.checkin < p_end_exclusive and s.checkout > p_start and s.nights > 0
  ), nights as (
    select st.stay_id, st.accommodation_total, gs.n,
           case when st.alloc is null then null else st.alloc[gs.n + 1] end amt
    from st cross join lateral generate_series(0, st.nights - 1) gs(n)
    where st.checkin + gs.n >= p_start and st.checkin + gs.n < p_end_exclusive
  )
  select coalesce(sum(amt), 0), count(*) filter (where amt is not null), count(*) filter (where amt is null), count(distinct stay_id) filter (where accommodation_total is not null)
    into v_rev, v_rev_nights, v_rev_missing, v_rev_stays
  from nights;

  -- Average length of stay: completed stays checking out in the period.
  select avg(nights), count(*) into v_alos, v_alos_n
  from public.admin_stays_v1(p_property_id) s
  where s.status in ('confirmed','completed') and s.checkout >= p_start and s.checkout < p_end_exclusive and s.checkout <= v_today;

  -- Returning-guest rate by canonical guest_id (A07).
  with done as (
    select distinct guest_id from public.admin_stays_v1(p_property_id) s
    where s.guest_id is not null and s.status in ('confirmed','completed') and s.checkout >= p_start and s.checkout < p_end_exclusive and s.checkout <= v_today
  )
  select count(*) filter (where exists (select 1 from public.admin_stays_v1(p_property_id) p where p.guest_id = done.guest_id and p.status in ('confirmed','completed') and p.checkout < p_start)),
         count(*)
    into v_ret_n, v_ret_d from done;
  v_ret := case when v_ret_d > 0 then round(v_ret_n::numeric / v_ret_d * 100, 2) end;

  -- Cancellation rate: scheduled-arrival cohort.
  select count(*) filter (where status = 'cancelled'), count(*) filter (where status <> 'inquiry') into v_cancel_n, v_cancel_d
  from public.admin_stays_v1(p_property_id) s where s.checkin >= p_start and s.checkin < p_end_exclusive;

  -- Future booked nights (separate from historical performance, A04).
  select coalesce(sum(greatest(0, s.checkout - greatest(s.checkin, v_today))), 0)::int into v_future
  from public.admin_stays_v1(p_property_id) s where s.status = 'confirmed' and s.checkout > v_today;

  -- Booking lead time: one value per booking with a reliable booking date.
  select avg(s.checkin - s.booking_created), count(*) filter (where s.booking_created is not null), count(*) filter (where s.booking_created is null)
    into v_lead, v_lead_n, v_lead_missing
  from public.admin_stays_v1(p_property_id) s where s.checkin >= p_start and s.checkin < p_end_exclusive and s.status <> 'inquiry' and s.stay_kind = 'airbnb';

  if v_fin then
    select coalesce(sum(gross_amount), 0), count(*) into v_cash, v_cash_n
    from public.transactions t
    where t.property_id = p_property_id and t.txn_type = 'income' and t.status = 'confirmed'
      and t.transaction_date >= p_start and t.transaction_date < p_end_exclusive
      and (t.source = 'airbnb_payout_email' or t.source not in ('airbnb','airbnb_email'));
    select coalesce(sum(host_payout), 0), count(*) into v_expected, v_expected_n
    from public.admin_stays_v1(p_property_id) s
    where s.stay_kind = 'airbnb' and s.status in ('confirmed','completed') and s.payout_date is null and s.host_payout is not null
      and s.checkout >= p_start and s.checkout < p_end_exclusive;
  end if;

  m := m || jsonb_build_object('capacity_nights', public.metric_v1('capacity_nights', v_cap::text, 'night', p_start, p_end_exclusive, 'stay', v_def, v_asof, 'complete', v_cap, 0, case when v_op_start > p_start then array['Operating start ' || v_op_start::text || ' is after the period start; capacity counts from it.'] else '{}'::text[] end, v_tok));
  m := m || jsonb_build_object('sellable_nights', public.metric_v1('sellable_nights', v_cap::text, 'night', p_start, p_end_exclusive, 'stay', v_def, v_asof, case when v_blocked > 0 then 'partial' else 'complete' end, v_cap, 0, case when v_blocked > 0 then array[v_blocked::text || ' imported blocked nights are unexplained and remain counted as sellable.'] else '{}'::text[] end, v_tok));
  m := m || jsonb_build_object('sold_nights', public.metric_v1('sold_nights', v_sold::text, 'night', p_start, p_end_exclusive, 'stay', v_def, v_asof, 'complete', v_sold, 0, '{}'::text[], v_tok));
  m := m || jsonb_build_object('occupancy', public.metric_v1('occupancy', case when v_cap > 0 then round(v_sold::numeric / v_cap * 100, 2)::text end, 'percent', p_start, p_end_exclusive, 'stay', v_def, v_asof, case when v_cap > 0 then 'complete' else 'missing' end, v_sold, 0, case when v_cap = 0 then array['No sellable nights in this period.'] else '{}'::text[] end, v_tok));
  m := m || jsonb_build_object('future_booked_nights', public.metric_v1('future_booked_nights', v_future::text, 'night', v_today, v_today + 365, 'stay', v_def, v_asof, 'complete', v_future, 0, '{}'::text[], v_tok));
  m := m || jsonb_build_object('average_length_of_stay', public.metric_v1('average_length_of_stay', case when v_alos_n > 0 then round(v_alos, 2)::text end, 'day', p_start, p_end_exclusive, 'stay', v_def, v_asof, case when v_alos_n > 0 then 'complete' else 'missing' end, v_alos_n, 0, case when v_alos_n = 0 then array['No completed stays checked out in this period.'] else '{}'::text[] end, v_tok));
  m := m || jsonb_build_object('returning_guest_rate', public.metric_v1('returning_guest_rate', v_ret::text, 'percent', p_start, p_end_exclusive, 'stay', v_def, v_asof, case when v_ret_d > 0 then 'complete' else 'missing' end, v_ret_d, 0, case when v_ret_d = 0 then array['No guests completed a stay in this period.'] else '{}'::text[] end, v_tok));
  m := m || jsonb_build_object('cancellation_rate', public.metric_v1('cancellation_rate', case when v_cancel_d > 0 then round(v_cancel_n::numeric / v_cancel_d * 100, 2)::text end, 'percent', p_start, p_end_exclusive, 'booking_cohort', v_def, v_asof, case when v_cancel_d > 0 then 'complete' else 'missing' end, v_cancel_d, 0, '{}'::text[], v_tok));
  m := m || jsonb_build_object('booking_lead_time', public.metric_v1('booking_lead_time', case when v_lead_n > 0 then round(v_lead, 1)::text end, 'day', p_start, p_end_exclusive, 'booking_cohort', v_def, v_asof, case when v_lead_n = 0 then 'missing' when v_lead_missing > 0 then 'partial' else 'complete' end, v_lead_n, v_lead_missing, case when v_lead_missing > 0 then array[v_lead_missing::text || ' bookings have no reliable booking date and are excluded.'] else '{}'::text[] end, v_tok));

  if v_fin then
    m := m || jsonb_build_object('accommodation_revenue', public.metric_v1('accommodation_revenue', round(v_rev, 2)::text, 'PHP', p_start, p_end_exclusive, 'stay', v_def, v_asof, case when v_rev_missing > 0 then 'partial' when v_rev_nights = 0 then 'missing' else 'complete' end, v_rev_nights, v_rev_missing, case when v_rev_missing > 0 then array[v_rev_missing::text || ' sold nights have no accommodation amount and are excluded; the total covers ' || v_rev_nights::text || ' nights.'] else '{}'::text[] end || array['Allocation: even per night, remainder on the earliest nights. Airbnb basis: gross earnings less cleaning fee where the transaction export exists, else host payout plus host fee.'], v_tok));
    m := m || jsonb_build_object('adr', public.metric_v1('adr', case when v_rev_nights > 0 then round(v_rev / v_rev_nights, 2)::text end, 'PHP', p_start, p_end_exclusive, 'stay', v_def, v_asof, case when v_rev_nights = 0 then 'missing' when v_rev_missing > 0 then 'partial' else 'complete' end, v_rev_nights, v_rev_missing, case when v_rev_missing > 0 then array['ADR is computed over the ' || v_rev_nights::text || ' nights with revenue coverage only.'] else '{}'::text[] end, v_tok));
    m := m || jsonb_build_object('revpar', public.metric_v1('revpar', case when v_cap > 0 and v_rev_missing = 0 and v_rev_nights > 0 then round(v_rev / v_cap, 2)::text end, 'PHP', p_start, p_end_exclusive, 'stay', v_def, v_asof, case when v_cap = 0 or v_rev_nights = 0 then 'missing' when v_rev_missing > 0 then 'partial' else 'complete' end, v_rev_nights, v_rev_missing, case when v_rev_missing > 0 then array['RevPAR is withheld: partial revenue must not be divided by all sellable nights.'] else '{}'::text[] end, v_tok));
    m := m || jsonb_build_object('cash_received', public.metric_v1('cash_received', round(v_cash, 2)::text, 'PHP', p_start, p_end_exclusive, 'cash', v_def, v_asof, 'complete', v_cash_n, 0, array['Confirmed income rows by transaction date: Airbnb payout e-mails and direct income. Not accommodation revenue.'], v_tok));
    m := m || jsonb_build_object('expected_payout', public.metric_v1('expected_payout', round(v_expected, 2)::text, 'PHP', p_start, p_end_exclusive, 'accrual', v_def, v_asof, 'complete', v_expected_n, 0, array['Host payout of Airbnb stays checking out in the period with no recorded payout date.'], v_tok));
  else
    m := m || jsonb_build_object('accommodation_revenue', public.metric_v1('accommodation_revenue', null, 'PHP', p_start, p_end_exclusive, 'stay', v_def, v_asof, 'missing', 0, 0, array['Finance metrics need a finance-authorised two-factor session.'], v_tok));
  end if;

  return jsonb_build_object('propertyId', p_property_id, 'periodStart', p_start, 'periodEndExclusive', p_end_exclusive, 'sourceAsOf', v_asof, 'financeVisible', v_fin, 'blockedNights', v_blocked, 'metrics', m);
end;
$$;
revoke all on function public.get_hospitality_metrics_v1(uuid, date, date) from public, anon, service_role;
grant execute on function public.get_hospitality_metrics_v1(uuid, date, date) to authenticated;
comment on function public.get_hospitality_metrics_v1(uuid, date, date) is 'PRD section 6 metric contract. Internal management information; never a tax or statutory output.';

drop function if exists public.telegram_note_calendar_block_v1(bigint, text, text);
drop function if exists public.telegram_answer_calendar_block_v2(bigint, text, text);

do $assert$
begin
  if (select md5(prosrc) from pg_proc where oid = 'public.telegram_answer_calendar_block_v1(bigint,text,text)'::regprocedure) <> '7f43ea5dda50f325487aaa9ca04e473c'
     or (select md5(prosrc) from pg_proc where oid = 'public.get_hospitality_metrics_v1(uuid,date,date)'::regprocedure) <> '0c2bc9aea7cdb418fb646590a2434a76' then
    raise exception 'rollback did not restore the pre-release function bodies';
  end if;
end;
$assert$;

commit;
