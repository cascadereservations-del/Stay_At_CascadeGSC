
-- Cleaner rate schedule (rates Lloyd provided; effective_from for Jary's cutover is a placeholder to be set)
create table if not exists public.cleaner_rate_schedule (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id) default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd',
  effective_from date not null,
  regular_rate numeric not null,
  general_rate numeric,
  note text,
  created_at timestamptz not null default now()
);
alter table public.cleaner_rate_schedule enable row level security;
create policy cleaner_rate_owner_admin_all on public.cleaner_rate_schedule
  for all to authenticated
  using ((((auth.jwt() -> 'user_metadata') ->> 'role') = any (array['owner','admin'])))
  with check ((((auth.jwt() -> 'user_metadata') ->> 'role') = any (array['owner','admin'])));

-- Seed: pre-Jary flat 250; post-Jary 500 regular / 1000 general.
-- 1900-01-01 = "since launch"; 2099-01-01 = placeholder until Jary's true start date is known.
insert into public.cleaner_rate_schedule (effective_from, regular_rate, general_rate, note)
values
  ('1900-01-01', 250, 250, 'Pre-Jary: flat PHP 250 per clean'),
  ('2099-01-01', 500, 1000, 'Jary era: PHP 500 regular / PHP 1000 general cleaning. effective_from is a PLACEHOLDER - set to Jary''s actual start date.')
on conflict do nothing;

-- Cleaner-payout reference: one row per checkout (cleaning event), with the rate that applied on that date.
create or replace view public.airbnb_cleans as
select
  r.confirmation_code,
  r.guest_name,
  r.start_date,
  r.end_date as clean_date,
  r.nights,
  (select s.regular_rate
     from public.cleaner_rate_schedule s
    where s.property_id = r.property_id
      and s.effective_from <= r.end_date
    order by s.effective_from desc
    limit 1) as applicable_regular_rate,
  (select s.general_rate
     from public.cleaner_rate_schedule s
    where s.property_id = r.property_id
      and s.effective_from <= r.end_date
    order by s.effective_from desc
    limit 1) as applicable_general_rate
from public.airbnb_transactions r
where r.row_type = 'reservation' and r.end_date is not null;

-- Monthly revenue analytics (cash-basis on host net, plus gross + fees) keyed by checkout month.
create or replace view public.airbnb_monthly_revenue as
select
  to_char(date_trunc('month', end_date), 'YYYY-MM') as month,
  count(*)                          as stays,
  sum(nights)                       as room_nights,
  round(sum(gross_earnings), 2)     as gross_earnings,
  round(sum(service_fee), 2)        as airbnb_service_fees,
  round(sum(amount), 2)             as host_net,
  round(avg(amount / nullif(nights,0)), 2) as avg_net_per_night
from public.airbnb_transactions
where row_type = 'reservation' and end_date is not null
group by 1
order by 1;

-- Per-guest summary (repeat-guest analytics)
create or replace view public.airbnb_guest_summary as
select
  guest_name,
  count(*)                       as stays,
  sum(nights)                    as total_nights,
  round(sum(amount), 2)          as total_host_net,
  min(start_date)                as first_stay,
  max(end_date)                  as last_checkout
from public.airbnb_transactions
where row_type = 'reservation' and guest_name is not null
group by guest_name
order by total_host_net desc;
;
