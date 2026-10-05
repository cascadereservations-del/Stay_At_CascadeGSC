-- Session 70 (SPEC-41 Parts 1 and 3, D-296.2, D-299.1): release calendar_block_triage_20261005.
-- 1. calendar_events says WHY an Airbnb block exists (block_reason, who explained it, when, a short note). The calendar-sync upsert
--    writes none of these columns, so a sync never erases an answer. recon_status stays the single "is it explained" flag.
-- 2. ops_notices.source ('socoteco' | 'ngcp' | 'staff') decides which brownout notices power-watch checks against SOCOTECO's
--    current posts. Backfilled from the title and who entered it; the CHECK follows the backfill.
-- 3. telegram_answer_calendar_block_v2 (six answers, who and when) with v1 as a wrapper, so Finance cards already sent still work,
--    and telegram_note_calendar_block_v1 for the detail typed after Brownout or Something else.
-- 4. get_hospitality_metrics_v1 counts only still-unexplained blocks as "unexplained". The body is production's (md5 0c2bc9ae...,
--    read 2026-10-05, equal to 20260913100000_admin_read_models_v1.sql) with ONE changed predicate in the v_blocked query.
-- No telegram_pending kind is added: the two follow-up questions ride the existing 'awaiting_reply' kind.
begin;

do $stop$
begin
  if (select md5(prosrc) from pg_proc where oid = 'public.get_hospitality_metrics_v1(uuid,date,date)'::regprocedure) <> '0c2bc9aea7cdb418fb646590a2434a76' then
    raise exception 'STOP: public.get_hospitality_metrics_v1 changed in production since SPEC-41 was written (md5 0c2bc9aea7cdb418fb646590a2434a76); re-read production and re-vendor before applying';
  end if;
end;
$stop$;
do $stop$
begin
  if (select md5(prosrc) from pg_proc where oid = 'public.telegram_answer_calendar_block_v1(bigint,text,text)'::regprocedure) <> '7f43ea5dda50f325487aaa9ca04e473c' then
    raise exception 'STOP: public.telegram_answer_calendar_block_v1 changed in production since SPEC-41 was written (md5 7f43ea5dda50f325487aaa9ca04e473c); re-read production and re-vendor before applying';
  end if;
end;
$stop$;

-- 1. why a block exists -------------------------------------------------------------------------------------------
alter table public.calendar_events
  add column if not exists block_reason text
    check (block_reason in ('brownout', 'maintenance', 'owner_use', 'direct', 'other', 'unblock')),
  add column if not exists block_reason_source text
    check (block_reason_source in ('auto', 'assumed', 'staff')),
  add column if not exists block_note text check (char_length(block_note) <= 200),
  add column if not exists block_answered_by uuid,          -- staff_access_profiles.user_id; null for auto and assumed
  add column if not exists block_answered_at timestamptz;
comment on column public.calendar_events.block_reason is
  'SPEC-41: why an Airbnb block exists. block_reason_source: auto = the system found the evidence; assumed = likely maintenance, asked in OPS; staff = a tap.';

-- 2. which notices are checked against SOCOTECO ---------------------------------------------------------------
alter table public.ops_notices add column if not exists source text;
update public.ops_notices
   set source = case when title ~* '\mNGCP\M' then 'ngcp' when title ~* 'SOCOTECO' or posted_by_name like 'Power watch%' then 'socoteco' else 'staff' end
 where notice_type = 'brownout' and source is null;
alter table public.ops_notices drop constraint if exists ops_notices_source_check;
alter table public.ops_notices add constraint ops_notices_source_check check (source in ('socoteco', 'ngcp', 'staff'));
comment on column public.ops_notices.source is
  'SPEC-41 Part 3: socoteco = a SOCOTECO II notice (power-watch frees its nights when SOCOTECO stops listing it); ngcp = a grid outage and staff = a scheduled job, neither is checked against socoteco2.com. Null for non-brownout notices.';

-- 3. the answers -------------------------------------------------------------------------------------------------
create or replace function public.telegram_answer_calendar_block_v2(
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
  v_reason text;
  v_status text;
begin
  if p_answer is null or p_answer not in ('brownout', 'maint', 'owner', 'other', 'direct', 'unblock') then
    raise exception 'answer must be brownout, maint, owner, other, direct or unblock' using errcode = '22023';
  end if;
  if p_telegram_user_id is null then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  select * into p from public.staff_access_profiles where telegram_user_id = p_telegram_user_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  -- A label (brownout, maintenance, owner use, other) carries no money: any active owner, admin or cleaner may tap it.
  -- direct and unblock are availability decisions and stay with owner and admin (D-297.2).
  if p.disabled_at is not null or p.role not in ('owner', 'admin', 'cleaner')
     or (p_answer in ('direct', 'unblock') and p.role not in ('owner', 'admin')) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;

  v_reason := case p_answer when 'maint' then 'maintenance' when 'owner' then 'owner_use' else p_answer end;
  v_status := case when p_answer in ('direct', 'unblock') then 'skipped' else 'admin_block' end;
  -- Open for an answer: still pending, or only assumed by the system (a staff answer is never overwritten).
  update public.calendar_events
     set recon_status = v_status, block_reason = v_reason, block_reason_source = 'staff',
         block_answered_by = p.user_id, block_answered_at = now()
   where uid = p_uid and source = 'airbnb' and status = 'blocked'
     and (recon_status = 'pending' or block_reason_source = 'assumed');
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_pending'); end if;

  return jsonb_build_object('ok', true, 'outcome', p_answer, 'recon_status', v_status, 'by', p.user_id);
end;
$function$;

revoke all on function public.telegram_answer_calendar_block_v2(bigint, text, text) from public, anon, authenticated;
grant execute on function public.telegram_answer_calendar_block_v2(bigint, text, text) to service_role;
comment on function public.telegram_answer_calendar_block_v2(bigint, text, text) is
  'SPEC-41: records why an Airbnb block exists (brownout, maint, owner, other, direct, unblock) with who and when. Labels: owner, admin, cleaner; direct and unblock: owner and admin. Answers a pending or assumed block, never a staff answer. service_role only.';

create or replace function public.telegram_note_calendar_block_v1(
  p_telegram_user_id bigint,
  p_uid              text,
  p_note             text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  p public.staff_access_profiles%rowtype;
begin
  if p_telegram_user_id is null then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  select * into p from public.staff_access_profiles where telegram_user_id = p_telegram_user_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  if p.disabled_at is not null then return jsonb_build_object('ok', false, 'reason', 'not_authorized'); end if;
  -- Only the person who tapped Brownout or Something else may add the detail to that answer.
  update public.calendar_events
     set block_note = nullif(left(trim(p_note), 200), '')
   where uid = p_uid and source = 'airbnb' and block_answered_by = p.user_id and block_reason in ('brownout', 'other');
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_yours'); end if;
  return jsonb_build_object('ok', true);
end;
$function$;

revoke all on function public.telegram_note_calendar_block_v1(bigint, text, text) from public, anon, authenticated;
grant execute on function public.telegram_note_calendar_block_v1(bigint, text, text) to service_role;
comment on function public.telegram_note_calendar_block_v1(bigint, text, text) is
  'SPEC-41: the detail typed after a Brownout or Something else tap, kept on the block (200 characters). Only the person who answered. service_role only.';

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
begin
  -- SPEC-41: the Finance-era wrapper. Cards already sent keep their three buttons; the work is v2's.
  if p_answer is null or p_answer not in ('maint', 'direct', 'unblock') then
    raise exception 'answer must be maint, direct or unblock' using errcode = '22023';
  end if;
  return public.telegram_answer_calendar_block_v2(p_telegram_user_id, p_uid, p_answer);
end;
$function$;
revoke all on function public.telegram_answer_calendar_block_v1(bigint, text, text) from public, anon, authenticated;
grant execute on function public.telegram_answer_calendar_block_v1(bigint, text, text) to service_role;

-- 4. the metrics -------------------------------------------------------------------------------------------------
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
  where c.property_id = p_property_id and c.status = 'blocked'
    and coalesce(c.recon_status, 'pending') = 'pending'          -- SPEC-41: only unexplained blocks are "unexplained"
    and c.checkin_date < p_end_exclusive and c.checkout_date > p_start;

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

commit;
