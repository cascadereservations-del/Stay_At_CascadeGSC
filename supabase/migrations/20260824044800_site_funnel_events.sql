create table if not exists public.site_funnel_events (
  id uuid primary key default extensions.uuid_generate_v4(),
  session_id uuid not null,
  event_name text not null check (event_name in ('page_view','hero_check_dates','date_range_selected','guest_details_started','guest_details_valid','payment_method_viewed','receipt_selected','reservation_submit','reservation_success','reservation_error','airbnb_outbound','airbnb_embed_view','airbnb_embed_error','contact_outbound')),
  occurred_at timestamptz not null default now(),
  viewport_group text check (viewport_group in ('mobile','tablet','desktop')),
  referrer_group text check (referrer_group in ('direct','search','social','referral','other')),
  nights_bucket text check (nights_bucket in ('1','2-4','5-6','7-13','14-27','28+')),
  lead_time_bucket text check (lead_time_bucket in ('0-2','3-7','8-30','31+')),
  payment_method text check (payment_method in ('bank_transfer','gcash','cash_on_arrival')),
  error_code text check (error_code ~ '^[A-Za-z0-9_]{1,64}$'),
  page_version text check (char_length(page_version) between 1 and 64),
  created_at timestamptz not null default now()
);

create index if not exists site_funnel_events_session_created_idx on public.site_funnel_events (session_id, created_at desc);
alter table public.site_funnel_events enable row level security;
revoke all on table public.site_funnel_events from anon, authenticated;
grant all on table public.site_funnel_events to service_role;
