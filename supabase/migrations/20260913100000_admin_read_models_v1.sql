-- Admin modernisation, packet P08/P09/P10/P14/P15/P19/P20 backend (PRD section 8).
-- Additive only: new tables for follow-ups, work orders, readiness reviews,
-- guest profile details and merge history; versioned read-model and metric
-- RPCs. Nothing existing is dropped or redefined. Every function is
-- SECURITY DEFINER with an explicit capability check through
-- current_staff_authorized / finance_human_authorized, so RLS on the older
-- app_metadata-keyed tables is not the boundary for these reads.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------

create table if not exists public.follow_up_tasks (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  guest_id uuid references public.guests(id),
  booking_kind text check (booking_kind in ('airbnb','direct')),
  booking_id uuid,
  purpose text not null check (purpose in ('pre_arrival_question','service_recovery','promised_item','post_stay_follow_up','returning_guest_enquiry','other')),
  title text not null check (char_length(btrim(title)) between 3 and 200),
  detail text,
  assignee_user_id uuid,
  due_at timestamptz,
  priority text not null default 'normal' check (priority in ('low','normal','high','urgent')),
  status text not null default 'open' check (status in ('open','in_progress','done','cancelled')),
  completion_note text,
  completed_at timestamptz,
  completed_by uuid,
  source_kind text,
  source_ref text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  idempotency_key text unique check (idempotency_key is null or char_length(idempotency_key) between 16 and 160)
);
create index if not exists follow_up_tasks_open_idx on public.follow_up_tasks(property_id, status, due_at);
create index if not exists follow_up_tasks_guest_idx on public.follow_up_tasks(guest_id);
comment on table public.follow_up_tasks is 'CRM04 operational follow-ups. A source event creates one task; resolving the source updates the task (TOD02).';

create table if not exists public.work_orders (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  source_kind text not null default 'manual' check (source_kind in ('manual','cleaning_issue','inventory_condition','guest_report')),
  source_ref text,
  title text not null check (char_length(btrim(title)) between 3 and 200),
  description text,
  priority text not null default 'normal' check (priority in ('low','normal','high','urgent')),
  assignee_user_id uuid,
  due_at timestamptz,
  blocks_arrival boolean not null default false,
  status text not null default 'open' check (status in ('open','in_progress','awaiting_external','resolved','cancelled')),
  evidence jsonb not null default '[]'::jsonb,
  resolution text,
  resolved_at timestamptz,
  resolved_by uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  idempotency_key text unique check (idempotency_key is null or char_length(idempotency_key) between 16 and 160)
);
create index if not exists work_orders_open_idx on public.work_orders(property_id, status, blocks_arrival);
comment on table public.work_orders is 'OPS01 maintenance work orders. blocks_arrival feeds readiness (CLN05).';

create table if not exists public.readiness_reviews (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  for_checkin_date date not null,
  cleaning_session_id uuid references public.cleaning_sessions(id),
  outcome text not null check (outcome in ('ready','not_ready','override_ready')),
  reason text check (reason is null or char_length(btrim(reason)) between 3 and 2000),
  reviewer_user_id uuid not null,
  reviewed_at timestamptz not null default now(),
  idempotency_key text not null unique check (char_length(idempotency_key) between 16 and 160),
  constraint readiness_override_needs_reason check (outcome <> 'override_ready' or reason is not null)
);
create index if not exists readiness_reviews_date_idx on public.readiness_reviews(property_id, for_checkin_date desc, reviewed_at desc);
comment on table public.readiness_reviews is 'CLN05 human readiness decision per arrival. An override requires a reason and is visible in the timeline.';

create table if not exists public.guest_profile_details (
  guest_id uuid primary key references public.guests(id) on delete cascade,
  property_id uuid not null references public.properties(id),
  display_name text,
  preferred_channel text check (preferred_channel is null or preferred_channel in ('messenger','phone','email','airbnb','other')),
  language text,
  messenger_psid text,
  messenger_link text,
  stay_preferences text,
  tags text[] not null default '{}',
  vip boolean not null default false,
  vip_reason text,
  contact_provenance jsonb not null default '{}'::jsonb,
  updated_by uuid,
  updated_at timestamptz not null default now(),
  version integer not null default 1
);
comment on table public.guest_profile_details is 'CRM01 extension of guests. No additional personal data is required to render a profile; every field is optional and carries provenance.';

create table if not exists public.guest_profile_history (
  id uuid primary key default gen_random_uuid(),
  guest_id uuid not null,
  changed_by uuid,
  changed_at timestamptz not null default now(),
  before_state jsonb,
  after_state jsonb,
  reason text
);

create table if not exists public.guest_merge_history (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null,
  surviving_guest_id uuid not null,
  merged_guest_id uuid not null,
  preview jsonb not null,
  reason text not null,
  merged_by uuid not null,
  merged_at timestamptz not null default now(),
  idempotency_key text not null unique
);
comment on table public.guest_merge_history is 'CRM03. Merges are reviewed and never automatic from names; original source references survive here.';

alter table public.ops_notices add column if not exists audience text not null default 'staff';
alter table public.ops_notices add column if not exists expires_at timestamptz;
comment on column public.ops_notices.expires_at is 'OPS02: expired notices stop appearing automatically (see get_admin_overview_v1).';

-- ---------------------------------------------------------------------------
-- 2. Grants and RLS (reads are through RPCs; direct table access is limited)
-- ---------------------------------------------------------------------------

alter table public.follow_up_tasks enable row level security;
alter table public.work_orders enable row level security;
alter table public.readiness_reviews enable row level security;
alter table public.guest_profile_details enable row level security;
alter table public.guest_profile_history enable row level security;
alter table public.guest_merge_history enable row level security;
revoke all on public.follow_up_tasks, public.work_orders, public.readiness_reviews, public.guest_profile_details, public.guest_profile_history, public.guest_merge_history from public, anon, authenticated, service_role;
grant select on public.follow_up_tasks, public.work_orders, public.readiness_reviews to authenticated;
grant select on public.guest_profile_details, public.guest_profile_history, public.guest_merge_history to authenticated;
create policy follow_up_tasks_ops_read on public.follow_up_tasks for select to authenticated using (public.current_staff_authorized('read_operations', property_id));
create policy work_orders_ops_read on public.work_orders for select to authenticated using (public.current_staff_authorized('read_operations', property_id));
create policy readiness_reviews_ops_read on public.readiness_reviews for select to authenticated using (public.current_staff_authorized('read_operations', property_id));
create policy guest_profile_details_manage_read on public.guest_profile_details for select to authenticated using (public.current_staff_authorized('manage_operations', property_id));
create policy guest_profile_history_manage_read on public.guest_profile_history for select to authenticated using (exists (select 1 from public.guests g where g.id = guest_id and public.current_staff_authorized('manage_operations', g.property_id)));
create policy guest_merge_history_manage_read on public.guest_merge_history for select to authenticated using (public.current_staff_authorized('manage_operations', property_id));

-- ---------------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------------

create or replace function public.admin_require(p_action text, p_property_id uuid)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if not public.current_staff_authorized(p_action, p_property_id) then
    raise exception using errcode = '42501', message = format('%s denied', p_action);
  end if;
end;
$$;
revoke all on function public.admin_require(text, uuid) from public, anon, service_role;
grant execute on function public.admin_require(text, uuid) to authenticated;

create or replace function public.manila_today()
returns date language sql stable set search_path = '' as $$
  select (now() at time zone 'Asia/Manila')::date;
$$;
grant execute on function public.manila_today() to authenticated, anon;

-- Canonical stay set: one row per stay, Airbnb reservations and direct
-- bookings, with status normalised. Calendar blocks are NOT stays.
create or replace function public.admin_stays_v1(p_property_id uuid)
returns table (
  stay_kind text, stay_id uuid, code text, guest_id uuid, guest_name text,
  checkin date, checkout date, nights integer, status text,
  accommodation_total numeric, allocation_method text, booking_created date, payout_date date, host_payout numeric
) language sql stable security definer set search_path = '' as $$
  select 'airbnb', r.id, r.confirmation_code, r.guest_id, r.guest_name, r.checkin_date, r.checkout_date,
         (r.checkout_date - r.checkin_date), r.status,
         case
           when t.gross_earnings is not null then round(t.gross_earnings - coalesce(t.cleaning_fee, 0), 2)
           when r.host_payout is not null then round(r.host_payout + coalesce(r.host_service_fee, 0), 2)
           else null end,
         case
           when t.gross_earnings is not null then 'airbnb_transactions_gross_less_cleaning'
           when r.host_payout is not null then 'host_payout_plus_host_fee'
           else 'missing' end,
         t.booking_date, r.payout_date, r.host_payout
  from public.airbnb_reservations r
  left join lateral (
    select max(x.gross_earnings) gross_earnings, max(x.cleaning_fee) cleaning_fee, min(x.booking_date) booking_date
    from public.airbnb_transactions x
    where x.property_id = r.property_id and x.confirmation_code = r.confirmation_code and x.row_type = 'reservation'
  ) t on true
  where r.property_id = p_property_id and r.checkin_date is not null and r.checkout_date is not null
  union all
  select 'direct', i.id, 'DIR-' || upper(left(i.id::text, 8)), i.guest_id, i.guest_name, i.checkin_date, i.checkout_date,
         (i.checkout_date - i.checkin_date),
         case when i.status in ('confirmed','completed') then i.status when i.status in ('cancelled','declined') then 'cancelled' else 'inquiry' end,
         i.total_amount, case when i.total_amount is not null then 'direct_quoted_total' else 'missing' end,
         i.submitted_at::date, null, null
  from public.booking_inquiries i
  where i.property_id = p_property_id;
$$;
revoke all on function public.admin_stays_v1(uuid) from public, anon, service_role;
grant execute on function public.admin_stays_v1(uuid) to authenticated;

-- Even nightly allocation with the rounding remainder placed on the earliest
-- nights (PRD section 6, revenue allocation).
create or replace function public.allocate_nightly_v1(p_total numeric, p_nights integer)
returns numeric[] language plpgsql immutable set search_path = '' as $$
declare v_cents bigint; v_base bigint; v_rem bigint; v_out numeric[] := '{}'; i integer;
begin
  if p_total is null or p_nights is null or p_nights <= 0 then return null; end if;
  v_cents := round(p_total * 100)::bigint;
  v_base := v_cents / p_nights; v_rem := v_cents - v_base * p_nights;
  for i in 1..p_nights loop
    v_out := v_out || ((v_base + case when i <= v_rem then 1 else 0 end)::numeric / 100);
  end loop;
  return v_out;
end;
$$;
grant execute on function public.allocate_nightly_v1(numeric, integer) to authenticated;

create or replace function public.metric_v1(p_key text, p_value text, p_unit text, p_start date, p_end date, p_basis text, p_def text, p_asof timestamptz, p_coverage text, p_inc integer, p_exc integer, p_warn text[], p_tok text)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object('key', p_key, 'value', p_value, 'unit', p_unit, 'periodStart', p_start, 'periodEndExclusive', p_end, 'basis', p_basis,
    'definitionVersion', p_def, 'sourceAsOf', p_asof, 'coverage', p_coverage, 'includedCount', p_inc, 'excludedCount', p_exc,
    'warnings', to_jsonb(coalesce(p_warn, '{}'::text[])), 'drilldownToken', p_key || '|' || p_tok);
$$;
grant execute on function public.metric_v1(text, text, text, date, date, text, text, timestamptz, text, integer, integer, text[], text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Hospitality metrics (P09). Period is [p_start, p_end_exclusive).
-- ---------------------------------------------------------------------------

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

-- Drill-down: the supporting stays for a metric token. Authorised again here.
create or replace function public.get_report_drilldown_v1(p_property_id uuid, p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_key text; v_start date; v_end date; v_rows jsonb; v_fin boolean;
begin
  perform public.admin_require('read_operations', p_property_id);
  v_fin := public.finance_human_authorized(p_property_id);
  v_key := split_part(p_token, '|', 1);
  if split_part(p_token, '|', 3) <> p_property_id::text then raise exception using errcode = '42501', message = 'drilldown scope mismatch'; end if;
  v_start := split_part(p_token, '|', 4)::date; v_end := split_part(p_token, '|', 5)::date;
  if v_key in ('accommodation_revenue','adr','revpar','cash_received','expected_payout') and not v_fin then
    raise exception using errcode = '42501', message = 'finance drilldown denied';
  end if;
  if v_key = 'cash_received' then
    select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'date', t.transaction_date, 'source', t.source, 'category', t.category, 'amount', t.gross_amount, 'reference', t.external_ref) order by t.transaction_date), '[]'::jsonb) into v_rows
    from public.transactions t where t.property_id = p_property_id and t.txn_type = 'income' and t.status = 'confirmed' and t.transaction_date >= v_start and t.transaction_date < v_end and (t.source = 'airbnb_payout_email' or t.source not in ('airbnb','airbnb_email'));
  else
    select coalesce(jsonb_agg(jsonb_build_object('kind', s.stay_kind, 'id', s.stay_id, 'code', s.code, 'guest', s.guest_name, 'checkin', s.checkin, 'checkout', s.checkout, 'nights', s.nights, 'status', s.status,
      'nightsInPeriod', greatest(0, least(s.checkout, v_end) - greatest(s.checkin, v_start)),
      'accommodationTotal', case when v_fin then s.accommodation_total end,
      'allocation', s.allocation_method, 'bookingCreated', s.booking_created, 'payoutDate', s.payout_date) order by s.checkin), '[]'::jsonb) into v_rows
    from public.admin_stays_v1(p_property_id) s
    where s.checkin < v_end and s.checkout > v_start and (v_key = 'cancellation_rate' or s.status in ('confirmed','completed'));
  end if;
  return jsonb_build_object('key', v_key, 'periodStart', v_start, 'periodEndExclusive', v_end, 'rows', v_rows);
end;
$$;
revoke all on function public.get_report_drilldown_v1(uuid, text) from public, anon, service_role;
grant execute on function public.get_report_drilldown_v1(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Today overview and action queue (P10)
-- ---------------------------------------------------------------------------

create or replace function public.get_admin_overview_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_today date; v_fin boolean; v_manage boolean; v_current jsonb; v_arrivals jsonb; v_departures jsonb; v_next jsonb;
  v_readiness jsonb; v_blockers jsonb; v_stock jsonb; v_followups jsonb; v_handoffs jsonb; v_finance jsonb; v_actions jsonb := '[]'::jsonb;
  v_notices jsonb; v_asof timestamptz; v_sync jsonb; v_next_checkin date; v_last_checkout date; v_clean jsonb; v_review jsonb;
begin
  perform public.admin_require('read_operations', p_property_id);
  v_fin := public.finance_human_authorized(p_property_id);
  v_manage := public.current_staff_authorized('manage_operations', p_property_id);
  v_today := public.manila_today();

  select coalesce(jsonb_agg(jsonb_build_object('kind', s.stay_kind, 'id', s.stay_id, 'code', s.code, 'guest', s.guest_name, 'guestId', s.guest_id, 'checkin', s.checkin, 'checkout', s.checkout, 'nights', s.nights, 'actualState', 'unknown')), '[]'::jsonb) into v_current
  from public.admin_stays_v1(p_property_id) s where s.status in ('confirmed','completed') and s.checkin <= v_today and s.checkout > v_today;
  select coalesce(jsonb_agg(jsonb_build_object('kind', s.stay_kind, 'id', s.stay_id, 'code', s.code, 'guest', s.guest_name, 'guestId', s.guest_id, 'checkin', s.checkin, 'checkout', s.checkout, 'nights', s.nights) order by s.checkin), '[]'::jsonb) into v_arrivals
  from public.admin_stays_v1(p_property_id) s where s.status = 'confirmed' and s.checkin = v_today;
  select coalesce(jsonb_agg(jsonb_build_object('kind', s.stay_kind, 'id', s.stay_id, 'code', s.code, 'guest', s.guest_name, 'guestId', s.guest_id, 'checkin', s.checkin, 'checkout', s.checkout) order by s.checkout), '[]'::jsonb) into v_departures
  from public.admin_stays_v1(p_property_id) s where s.status in ('confirmed','completed') and s.checkout = v_today;
  select jsonb_build_object('kind', s.stay_kind, 'id', s.stay_id, 'code', s.code, 'guest', s.guest_name, 'guestId', s.guest_id, 'checkin', s.checkin, 'checkout', s.checkout, 'nights', s.nights, 'daysUntil', s.checkin - v_today), s.checkin
    into v_next, v_next_checkin
  from public.admin_stays_v1(p_property_id) s where s.status = 'confirmed' and s.checkin > v_today order by s.checkin limit 1;
  select max(s.checkout) into v_last_checkout from public.admin_stays_v1(p_property_id) s where s.status in ('confirmed','completed') and s.checkout <= v_today;

  -- Readiness: latest cleaning since the last checkout, latest human review for the next arrival, open blocking work.
  select jsonb_build_object('id', c.id, 'cleanedAt', c.cleaned_at, 'cleaner', c.cleaner_name, 'complete', c.is_complete, 'completionPct', c.completion_pct, 'issues', c.issue_count, 'meterPhotos', c.meter_photo_count) into v_clean
  from public.cleaning_sessions c where c.property_id = p_property_id and (v_last_checkout is null or c.cleaned_at::date >= v_last_checkout) order by c.cleaned_at desc limit 1;
  select jsonb_build_object('id', r.id, 'outcome', r.outcome, 'reason', r.reason, 'reviewedAt', r.reviewed_at, 'forCheckin', r.for_checkin_date) into v_review
  from public.readiness_reviews r where r.property_id = p_property_id and r.for_checkin_date = coalesce(v_next_checkin, v_today) order by r.reviewed_at desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'title', w.title, 'priority', w.priority, 'status', w.status, 'dueAt', w.due_at, 'assignee', w.assignee_user_id) order by w.due_at nulls last), '[]'::jsonb) into v_blockers
  from public.work_orders w where w.property_id = p_property_id and w.blocks_arrival and w.status not in ('resolved','cancelled');
  v_readiness := jsonb_build_object(
    'state', case when v_review->>'outcome' in ('ready','override_ready') and jsonb_array_length(v_blockers) = 0 then 'ready'
                  when v_review->>'outcome' = 'not_ready' or jsonb_array_length(v_blockers) > 0 then 'not_ready'
                  when v_clean is null then 'unknown' else 'awaiting_review' end,
    'lastCleaning', v_clean, 'review', v_review, 'blockingWorkOrders', jsonb_array_length(v_blockers), 'lastCheckout', v_last_checkout, 'nextCheckin', v_next_checkin);

  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'qty', i.qty_on_hand, 'unit', i.unit, 'reorderBelow', i.reorder_below, 'out', i.qty_on_hand <= 0) order by i.qty_on_hand), '[]'::jsonb) into v_stock
  from public.inventory_items i where i.property_id = p_property_id and i.is_active and i.reorder_below is not null and i.qty_on_hand <= i.reorder_below;
  select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'title', f.title, 'purpose', f.purpose, 'priority', f.priority, 'dueAt', f.due_at, 'guestId', f.guest_id, 'status', f.status) order by f.due_at nulls last), '[]'::jsonb) into v_followups
  from public.follow_up_tasks f where f.property_id = p_property_id and f.status in ('open','in_progress');
  if v_manage then
    select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'guest', h.guest_name, 'risk', h.risk, 'status', h.status, 'createdAt', h.created_at, 'excerpt', left(h.guest_text, 120)) order by h.created_at desc), '[]'::jsonb) into v_handoffs
    from public.concierge_handoffs h where h.status = 'pending';
  else
    v_handoffs := null;
  end if;
  if v_fin then
    select jsonb_build_object(
      'pendingReviewCount', (select count(*) from public.transactions t where t.property_id = p_property_id and t.status = 'pending_review'),
      'pendingReviewAmount', (select coalesce(sum(gross_amount), 0)::text from public.transactions t where t.property_id = p_property_id and t.status = 'pending_review'),
      'paymentReviewCount', (select count(*) from public.payment_evidence_comparisons c where c.property_id = p_property_id and not exists (select 1 from public.payment_finance_reviews r where r.comparison_id = c.id)),
      'unpaidCleanerFees', (select count(*) from public.cleaning_sessions c where c.property_id = p_property_id and c.fee_amount > 0 and c.fee_paid_at is null)
    ) into v_finance;
  else
    v_finance := null; -- never "all clear"; the client renders "not available for this role"
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'type', n.notice_type, 'title', n.title, 'effectiveDate', n.effective_date, 'expiresAt', n.expires_at, 'audience', n.audience) order by n.effective_date), '[]'::jsonb) into v_notices
  from public.ops_notices n where n.property_id = p_property_id and n.is_active and (n.expires_at is null or n.expires_at > now()) and n.effective_date >= v_today - 1;
  select jsonb_build_object('syncedAt', l.synced_at, 'status', l.status, 'error', l.error_msg) into v_sync from public.calendar_sync_log l where l.property_id = p_property_id order by l.synced_at desc limit 1;
  select greatest((select max(updated_at) from public.airbnb_reservations where property_id = p_property_id), (select max(cleaned_at) from public.cleaning_sessions where property_id = p_property_id), (select max(updated_at) from public.inventory_items where property_id = p_property_id)) into v_asof;

  -- Action queue (TOD02): 1 arrival blocked, 2 overdue work, 3 pending decisions, 4 follow-ups, 5 stock/admin.
  if v_next_checkin is not null and v_next_checkin - v_today <= 2 and v_readiness->>'state' <> 'ready' then
    v_actions := v_actions || jsonb_build_object('priority', 1, 'kind', 'arrival_readiness', 'title', 'Arrival on ' || v_next_checkin::text || ' is not confirmed ready', 'reason', 'Readiness state is ' || replace(v_readiness->>'state', '_', ' '), 'href', '/operations', 'dueAt', v_next_checkin, 'sourceKind', 'readiness', 'sourceId', null);
  end if;
  v_actions := v_actions || coalesce((select jsonb_agg(jsonb_build_object('priority', case when w.blocks_arrival then 1 else 2 end, 'kind', 'work_order', 'title', w.title, 'reason', case when w.blocks_arrival then 'Blocks the next arrival' when w.due_at < now() then 'Overdue' else 'Open ' || w.priority || ' work' end, 'href', '/operations/work-orders?id=' || w.id::text, 'dueAt', w.due_at, 'assignee', w.assignee_user_id, 'sourceKind', 'work_order', 'sourceId', w.id))
    from public.work_orders w where w.property_id = p_property_id and w.status not in ('resolved','cancelled') and (w.blocks_arrival or w.due_at < now() or w.priority in ('high','urgent'))), '[]'::jsonb);
  v_actions := v_actions || coalesce((select jsonb_agg(jsonb_build_object('priority', 3, 'kind', 'inquiry', 'title', 'Decide inquiry from ' || s.guest_name, 'reason', 'Direct booking request for ' || s.checkin::text, 'href', '/bookings/inquiries', 'dueAt', s.checkin, 'sourceKind', 'booking_inquiry', 'sourceId', s.stay_id))
    from public.admin_stays_v1(p_property_id) s where s.status = 'inquiry' and s.checkin >= v_today), '[]'::jsonb);
  if v_fin and (v_finance->>'pendingReviewCount')::int > 0 then
    v_actions := v_actions || jsonb_build_object('priority', 3, 'kind', 'finance_review', 'title', (v_finance->>'pendingReviewCount') || ' transactions await finance review', 'reason', 'Displayed totals exclude them', 'href', '/finance', 'dueAt', null, 'sourceKind', 'transactions', 'sourceId', null);
  end if;
  v_actions := v_actions || coalesce((select jsonb_agg(jsonb_build_object('priority', 4, 'kind', 'follow_up', 'title', f.title, 'reason', replace(f.purpose, '_', ' ') || case when f.due_at < now() then ' (overdue)' else '' end, 'href', '/guests/' || coalesce(f.guest_id::text, '') || '?task=' || f.id::text, 'dueAt', f.due_at, 'assignee', f.assignee_user_id, 'sourceKind', 'follow_up_task', 'sourceId', f.id))
    from public.follow_up_tasks f where f.property_id = p_property_id and f.status in ('open','in_progress')), '[]'::jsonb);
  if v_handoffs is not null and jsonb_array_length(v_handoffs) > 0 then
    v_actions := v_actions || jsonb_build_object('priority', 4, 'kind', 'concierge_handoff', 'title', jsonb_array_length(v_handoffs)::text || ' Messenger handoffs need a human reply', 'reason', 'Concierge escalated to staff', 'href', '/guests?handoffs=1', 'dueAt', null, 'sourceKind', 'concierge_handoffs', 'sourceId', null);
  end if;
  v_actions := v_actions || coalesce((select jsonb_agg(jsonb_build_object('priority', 5, 'kind', 'low_stock', 'title', i.name || ' is ' || case when i.qty_on_hand <= 0 then 'out of stock' else 'low (' || i.qty_on_hand::text || ' ' || i.unit || ')' end, 'reason', 'Below reorder level ' || i.reorder_below::text, 'href', '/inventory?attention=low', 'dueAt', null, 'sourceKind', 'inventory_item', 'sourceId', i.id))
    from public.inventory_items i where i.property_id = p_property_id and i.is_active and i.reorder_below is not null and i.qty_on_hand <= i.reorder_below), '[]'::jsonb);

  return jsonb_build_object('today', v_today, 'sourceAsOf', v_asof, 'calendarSync', v_sync, 'currentStays', v_current, 'arrivals', v_arrivals, 'departures', v_departures, 'nextArrival', v_next,
    'readiness', v_readiness, 'blockingWorkOrders', v_blockers, 'lowStock', v_stock, 'followUps', v_followups, 'handoffs', v_handoffs, 'finance', v_finance, 'notices', v_notices,
    'actions', (select coalesce(jsonb_agg(a order by (a->>'priority')::int, a->>'dueAt' nulls last), '[]'::jsonb) from jsonb_array_elements(v_actions) a));
end;
$$;
revoke all on function public.get_admin_overview_v1(uuid) from public, anon, service_role;
grant execute on function public.get_admin_overview_v1(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Guest timeline, profile, follow-ups, readiness, work orders (writes)
-- ---------------------------------------------------------------------------

create or replace function public.get_guest_timeline_v1(p_guest_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_prop uuid; v_fin boolean; v_events jsonb;
begin
  select property_id into v_prop from public.guests where id = p_guest_id;
  if v_prop is null then raise exception using errcode = 'P0002', message = 'guest not found'; end if;
  perform public.admin_require('manage_operations', v_prop);
  v_fin := public.finance_human_authorized(v_prop);
  with ev as (
    select 'stay' kind, s.checkin::timestamptz at, jsonb_build_object('code', s.code, 'stayKind', s.stay_kind, 'id', s.stay_id, 'checkin', s.checkin, 'checkout', s.checkout, 'nights', s.nights, 'status', s.status, 'accommodationTotal', case when v_fin then s.accommodation_total end) body, s.stay_kind source
    from public.admin_stays_v1(v_prop) s where s.guest_id = p_guest_id
    union all
    select 'follow_up', coalesce(f.completed_at, f.created_at), jsonb_build_object('id', f.id, 'title', f.title, 'purpose', f.purpose, 'status', f.status, 'dueAt', f.due_at, 'completionNote', f.completion_note), 'follow_up_tasks'
    from public.follow_up_tasks f where f.guest_id = p_guest_id
    union all
    select 'conversation', c.updated_at, jsonb_build_object('id', c.id, 'channel', c.channel, 'purpose', c.purpose, 'status', c.status, 'bookingId', c.booking_id), 'guest_conversations'
    from public.guest_conversations c where c.guest_id = p_guest_id
    union all
    select 'consent', ce.effective_at, jsonb_build_object('purpose', ce.purpose, 'status', ce.status, 'reason', ce.reason), 'crm_consent_events'
    from public.crm_consent_events ce join public.crm_guest_profiles gp on gp.id = ce.profile_id where gp.guest_id = p_guest_id
    union all
    select 'lifecycle', le.occurred_at, jsonb_build_object('eventType', le.event_type, 'code', le.event_code, 'bookingId', le.booking_id, 'reason', le.reason), 'crm_lifecycle_events'
    from public.crm_lifecycle_events le join public.crm_guest_profiles gp on gp.id = le.profile_id where gp.guest_id = p_guest_id
    union all
    select 'refund', t.transaction_date::timestamptz, jsonb_build_object('id', t.id, 'amount', t.gross_amount, 'rail', t.refund_rail, 'reference', t.refund_ref, 'status', t.status), 'transactions'
    from public.transactions t where v_fin and t.source = 'refund' and t.booking_id in (select stay_id from public.admin_stays_v1(v_prop) where guest_id = p_guest_id)
    union all
    select 'profile_change', h.changed_at, jsonb_build_object('reason', h.reason, 'after', h.after_state), 'guest_profile_history'
    from public.guest_profile_history h where h.guest_id = p_guest_id
    union all
    select 'merge', m.merged_at, jsonb_build_object('mergedGuestId', m.merged_guest_id, 'reason', m.reason), 'guest_merge_history'
    from public.guest_merge_history m where m.surviving_guest_id = p_guest_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'at', at, 'source', source, 'body', body) order by at desc), '[]'::jsonb) into v_events from ev;
  return jsonb_build_object('guestId', p_guest_id, 'financeVisible', v_fin, 'events', v_events);
end;
$$;
revoke all on function public.get_guest_timeline_v1(uuid) from public, anon, service_role;
grant execute on function public.get_guest_timeline_v1(uuid) to authenticated;

create or replace function public.save_guest_profile_v1(p_guest_id uuid, p_patch jsonb, p_expected_version integer, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_prop uuid; v_before jsonb; v_row public.guest_profile_details%rowtype;
begin
  select property_id into v_prop from public.guests where id = p_guest_id;
  if v_prop is null then raise exception using errcode = 'P0002', message = 'guest not found'; end if;
  perform public.admin_require('manage_operations', v_prop);
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception using errcode = '22023', message = 'patch must be an object'; end if;
  insert into public.guest_profile_details(guest_id, property_id) values (p_guest_id, v_prop) on conflict (guest_id) do nothing;
  select * into v_row from public.guest_profile_details where guest_id = p_guest_id for update;
  if p_expected_version is not null and v_row.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'stale version: profile changed since it was loaded';
  end if;
  v_before := to_jsonb(v_row);
  update public.guest_profile_details set
    display_name = case when p_patch ? 'display_name' then nullif(btrim(p_patch->>'display_name'), '') else display_name end,
    preferred_channel = case when p_patch ? 'preferred_channel' then nullif(p_patch->>'preferred_channel', '') else preferred_channel end,
    language = case when p_patch ? 'language' then nullif(btrim(p_patch->>'language'), '') else language end,
    messenger_psid = case when p_patch ? 'messenger_psid' then nullif(btrim(p_patch->>'messenger_psid'), '') else messenger_psid end,
    messenger_link = case when p_patch ? 'messenger_link' then nullif(btrim(p_patch->>'messenger_link'), '') else messenger_link end,
    stay_preferences = case when p_patch ? 'stay_preferences' then nullif(btrim(p_patch->>'stay_preferences'), '') else stay_preferences end,
    tags = case when p_patch ? 'tags' then coalesce((select array_agg(x) from jsonb_array_elements_text(p_patch->'tags') x), '{}') else tags end,
    vip = case when p_patch ? 'vip' then (p_patch->>'vip')::boolean else vip end,
    vip_reason = case when p_patch ? 'vip_reason' then nullif(btrim(p_patch->>'vip_reason'), '') else vip_reason end,
    contact_provenance = contact_provenance || jsonb_build_object('last_change', jsonb_build_object('by', auth.uid(), 'at', now(), 'fields', (select jsonb_agg(k) from jsonb_object_keys(p_patch) k))),
    updated_by = auth.uid(), updated_at = now(), version = version + 1
  where guest_id = p_guest_id returning * into v_row;
  insert into public.guest_profile_history(guest_id, changed_by, before_state, after_state, reason) values (p_guest_id, auth.uid(), v_before, to_jsonb(v_row), p_reason);
  return jsonb_build_object('ok', true, 'guestId', p_guest_id, 'version', v_row.version, 'updatedAt', v_row.updated_at);
end;
$$;
revoke all on function public.save_guest_profile_v1(uuid, jsonb, integer, text) from public, anon, service_role;
grant execute on function public.save_guest_profile_v1(uuid, jsonb, integer, text) to authenticated;

create or replace function public.save_follow_up_v1(p_property_id uuid, p_task jsonb, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_row public.follow_up_tasks%rowtype; v_status text; v_expected integer;
begin
  perform public.admin_require('manage_operations', p_property_id);
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key required'; end if;
  v_id := nullif(p_task->>'id', '')::uuid;
  v_expected := nullif(p_task->>'expected_version', '')::integer;
  if v_id is null then
    select * into v_row from public.follow_up_tasks where idempotency_key = p_idempotency_key;
    if found then return jsonb_build_object('ok', true, 'id', v_row.id, 'version', v_row.version, 'replayed', true); end if;
    insert into public.follow_up_tasks(property_id, guest_id, booking_kind, booking_id, purpose, title, detail, assignee_user_id, due_at, priority, source_kind, source_ref, created_by, idempotency_key)
    values (p_property_id, nullif(p_task->>'guest_id', '')::uuid, nullif(p_task->>'booking_kind', ''), nullif(p_task->>'booking_id', '')::uuid, coalesce(p_task->>'purpose', 'other'), p_task->>'title', p_task->>'detail',
            nullif(p_task->>'assignee_user_id', '')::uuid, nullif(p_task->>'due_at', '')::timestamptz, coalesce(p_task->>'priority', 'normal'), p_task->>'source_kind', p_task->>'source_ref', auth.uid(), p_idempotency_key)
    returning * into v_row;
  else
    select * into v_row from public.follow_up_tasks where id = v_id and property_id = p_property_id for update;
    if not found then raise exception using errcode = 'P0002', message = 'task not found'; end if;
    if v_expected is not null and v_row.version <> v_expected then raise exception using errcode = '40001', message = 'stale version: task changed since it was loaded'; end if;
    v_status := coalesce(p_task->>'status', v_row.status);
    if v_status = 'done' and v_row.status <> 'done' and coalesce(btrim(p_task->>'completion_note'), '') = '' then
      raise exception using errcode = '22023', message = 'a completion note is required to close a follow-up';
    end if;
    update public.follow_up_tasks set
      title = coalesce(nullif(p_task->>'title', ''), title), detail = coalesce(p_task->>'detail', detail), purpose = coalesce(p_task->>'purpose', purpose),
      assignee_user_id = case when p_task ? 'assignee_user_id' then nullif(p_task->>'assignee_user_id', '')::uuid else assignee_user_id end,
      due_at = case when p_task ? 'due_at' then nullif(p_task->>'due_at', '')::timestamptz else due_at end,
      priority = coalesce(p_task->>'priority', priority), status = v_status,
      completion_note = case when v_status = 'done' then coalesce(p_task->>'completion_note', completion_note) else completion_note end,
      completed_at = case when v_status = 'done' and completed_at is null then now() when v_status <> 'done' then null else completed_at end,
      completed_by = case when v_status = 'done' and completed_by is null then auth.uid() when v_status <> 'done' then null else completed_by end,
      updated_at = now(), version = version + 1
    where id = v_id returning * into v_row;
  end if;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'version', v_row.version, 'status', v_row.status, 'completedAt', v_row.completed_at);
end;
$$;
revoke all on function public.save_follow_up_v1(uuid, jsonb, text) from public, anon, service_role;
grant execute on function public.save_follow_up_v1(uuid, jsonb, text) to authenticated;

create or replace function public.save_work_order_v1(p_property_id uuid, p_order jsonb, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_row public.work_orders%rowtype; v_status text; v_expected integer;
begin
  perform public.admin_require('manage_maintenance', p_property_id);
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key required'; end if;
  v_id := nullif(p_order->>'id', '')::uuid;
  v_expected := nullif(p_order->>'expected_version', '')::integer;
  if v_id is null then
    select * into v_row from public.work_orders where idempotency_key = p_idempotency_key;
    if found then return jsonb_build_object('ok', true, 'id', v_row.id, 'version', v_row.version, 'replayed', true); end if;
    insert into public.work_orders(property_id, source_kind, source_ref, title, description, priority, assignee_user_id, due_at, blocks_arrival, created_by, idempotency_key)
    values (p_property_id, coalesce(p_order->>'source_kind', 'manual'), p_order->>'source_ref', p_order->>'title', p_order->>'description', coalesce(p_order->>'priority', 'normal'),
            nullif(p_order->>'assignee_user_id', '')::uuid, nullif(p_order->>'due_at', '')::timestamptz, coalesce((p_order->>'blocks_arrival')::boolean, false), auth.uid(), p_idempotency_key)
    returning * into v_row;
  else
    select * into v_row from public.work_orders where id = v_id and property_id = p_property_id for update;
    if not found then raise exception using errcode = 'P0002', message = 'work order not found'; end if;
    if v_expected is not null and v_row.version <> v_expected then raise exception using errcode = '40001', message = 'stale version: work order changed since it was loaded'; end if;
    v_status := coalesce(p_order->>'status', v_row.status);
    if v_status = 'resolved' and coalesce(nullif(btrim(p_order->>'resolution'), ''), v_row.resolution) is null then
      raise exception using errcode = '22023', message = 'a resolution note is required to resolve a work order';
    end if;
    update public.work_orders set
      title = coalesce(nullif(p_order->>'title', ''), title), description = coalesce(p_order->>'description', description), priority = coalesce(p_order->>'priority', priority),
      assignee_user_id = case when p_order ? 'assignee_user_id' then nullif(p_order->>'assignee_user_id', '')::uuid else assignee_user_id end,
      due_at = case when p_order ? 'due_at' then nullif(p_order->>'due_at', '')::timestamptz else due_at end,
      blocks_arrival = coalesce((p_order->>'blocks_arrival')::boolean, blocks_arrival), status = v_status,
      evidence = case when p_order ? 'evidence' then p_order->'evidence' else evidence end,
      resolution = coalesce(p_order->>'resolution', resolution),
      resolved_at = case when v_status = 'resolved' and resolved_at is null then now() when v_status <> 'resolved' then null else resolved_at end,
      resolved_by = case when v_status = 'resolved' and resolved_by is null then auth.uid() when v_status <> 'resolved' then null else resolved_by end,
      updated_at = now(), version = version + 1
    where id = v_id returning * into v_row;
  end if;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'version', v_row.version, 'status', v_row.status, 'blocksArrival', v_row.blocks_arrival);
end;
$$;
revoke all on function public.save_work_order_v1(uuid, jsonb, text) from public, anon, service_role;
grant execute on function public.save_work_order_v1(uuid, jsonb, text) to authenticated;

create or replace function public.review_property_readiness_v1(p_property_id uuid, p_for_checkin date, p_outcome text, p_reason text, p_cleaning_session_id uuid, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_row public.readiness_reviews%rowtype; v_blockers integer;
begin
  perform public.admin_require('inspect_cleaning', p_property_id);
  if p_outcome not in ('ready','not_ready','override_ready') then raise exception using errcode = '22023', message = 'invalid readiness outcome'; end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key required'; end if;
  select * into v_row from public.readiness_reviews where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('ok', true, 'id', v_row.id, 'outcome', v_row.outcome, 'replayed', true); end if;
  select count(*) into v_blockers from public.work_orders w where w.property_id = p_property_id and w.blocks_arrival and w.status not in ('resolved','cancelled');
  if p_outcome = 'ready' and v_blockers > 0 then
    raise exception using errcode = '22023', message = format('%s blocking work orders are open; resolve them or record a reasoned override', v_blockers);
  end if;
  if p_outcome = 'override_ready' and not public.current_staff_authorized('manage_operations', p_property_id) then
    raise exception using errcode = '42501', message = 'override requires manage_operations';
  end if;
  insert into public.readiness_reviews(property_id, for_checkin_date, cleaning_session_id, outcome, reason, reviewer_user_id, idempotency_key)
  values (p_property_id, p_for_checkin, p_cleaning_session_id, p_outcome, nullif(btrim(p_reason), ''), auth.uid(), p_idempotency_key) returning * into v_row;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'outcome', v_row.outcome, 'reviewedAt', v_row.reviewed_at, 'openBlockers', v_blockers);
end;
$$;
revoke all on function public.review_property_readiness_v1(uuid, date, text, text, uuid, text) from public, anon, service_role;
grant execute on function public.review_property_readiness_v1(uuid, date, text, text, uuid, text) to authenticated;

-- Reviewed merge (CRM03): never automatic. The preview is computed on the
-- server and stored verbatim with the merge.
create or replace function public.preview_guest_merge_v1(p_surviving uuid, p_merged uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.guests where id = p_surviving;
  if v_prop is null then raise exception using errcode = 'P0002', message = 'guest not found'; end if;
  perform public.admin_require('manage_operations', v_prop);
  if p_surviving = p_merged then raise exception using errcode = '22023', message = 'cannot merge a guest into itself'; end if;
  return jsonb_build_object(
    'surviving', (select to_jsonb(g) - 'notes' from public.guests g where g.id = p_surviving),
    'merged', (select to_jsonb(g) - 'notes' from public.guests g where g.id = p_merged),
    'reservations', (select count(*) from public.airbnb_reservations where guest_id = p_merged),
    'inquiries', (select count(*) from public.booking_inquiries where guest_id = p_merged),
    'followUps', (select count(*) from public.follow_up_tasks where guest_id = p_merged),
    'conversations', (select count(*) from public.guest_conversations where guest_id = p_merged),
    'sharedContact', (select (a.phone is not null and a.phone = b.phone) or (a.email is not null and lower(a.email) = lower(b.email)) from public.guests a, public.guests b where a.id = p_surviving and b.id = p_merged),
    'nameOnly', (select not ((a.phone is not null and a.phone = b.phone) or (a.email is not null and lower(a.email) = lower(b.email))) and lower(a.name) = lower(b.name) from public.guests a, public.guests b where a.id = p_surviving and b.id = p_merged)
  );
end;
$$;
revoke all on function public.preview_guest_merge_v1(uuid, uuid) from public, anon, service_role;
grant execute on function public.preview_guest_merge_v1(uuid, uuid) to authenticated;

create or replace function public.merge_guests_v1(p_surviving uuid, p_merged uuid, p_reason text, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_prop uuid; v_preview jsonb; v_existing public.guest_merge_history%rowtype;
begin
  select property_id into v_prop from public.guests where id = p_surviving;
  if v_prop is null then raise exception using errcode = 'P0002', message = 'guest not found'; end if;
  perform public.admin_require('manage_operations', v_prop);
  if p_reason is null or char_length(btrim(p_reason)) < 3 then raise exception using errcode = '22023', message = 'merge reason required'; end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key required'; end if;
  select * into v_existing from public.guest_merge_history where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('ok', true, 'replayed', true, 'id', v_existing.id); end if;
  v_preview := public.preview_guest_merge_v1(p_surviving, p_merged);
  if coalesce((v_preview->>'sharedContact')::boolean, false) = false then
    raise exception using errcode = '22023', message = 'no verified shared contact; name-only similarity cannot be merged';
  end if;
  update public.airbnb_reservations set guest_id = p_surviving where guest_id = p_merged;
  update public.booking_inquiries set guest_id = p_surviving where guest_id = p_merged;
  update public.follow_up_tasks set guest_id = p_surviving where guest_id = p_merged;
  update public.guest_conversations set guest_id = p_surviving where guest_id = p_merged;
  update public.guests set is_active = false, notes = coalesce(notes, '') || E'\nMerged into ' || p_surviving::text || ' on ' || now()::date::text where id = p_merged;
  insert into public.guest_merge_history(property_id, surviving_guest_id, merged_guest_id, preview, reason, merged_by, idempotency_key)
  values (v_prop, p_surviving, p_merged, v_preview, btrim(p_reason), auth.uid(), p_idempotency_key) returning * into v_existing;
  perform public.refresh_guest_stats(p_surviving);
  return jsonb_build_object('ok', true, 'id', v_existing.id, 'preview', v_preview);
end;
$$;
revoke all on function public.merge_guests_v1(uuid, uuid, text, text) from public, anon, service_role;
grant execute on function public.merge_guests_v1(uuid, uuid, text, text) to authenticated;
