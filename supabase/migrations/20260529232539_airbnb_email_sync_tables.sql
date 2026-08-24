
-- ============================================================
-- Migration: airbnb_email_sync_tables
-- Creates airbnb_email_events and airbnb_reservations
-- ============================================================

-- -------------------------------------------------------
-- 1. airbnb_email_events
--    Master idempotency log for all processed Gmail messages
-- -------------------------------------------------------
create table public.airbnb_email_events (
  id                uuid primary key default uuid_generate_v4(),
  property_id       uuid not null references public.properties(id)
                      default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd',
  gmail_message_id  text unique not null,
  email_type        text not null
                      check (email_type in ('payout','booking','cancellation')),
  email_date        timestamptz not null,
  subject           text,
  raw_payload       jsonb,
  processed_at      timestamptz default now(),
  created_at        timestamptz default now()
);

comment on table public.airbnb_email_events is
  'Idempotency log for all Airbnb emails processed by AirbnbEmailSync.gs. '
  'gmail_message_id is the dedup key — re-runs are always safe.';

-- RLS: service role only (EF writes, no client access needed)
alter table public.airbnb_email_events enable row level security;

create policy "service role full access"
  on public.airbnb_email_events
  for all
  to service_role
  using (true)
  with check (true);

-- -------------------------------------------------------
-- 2. airbnb_reservations
--    CRM record per booking, keyed by confirmation_code
-- -------------------------------------------------------
create table public.airbnb_reservations (
  id                        uuid primary key default uuid_generate_v4(),
  property_id               uuid not null references public.properties(id)
                              default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd',
  created_at                timestamptz default now() not null,
  updated_at                timestamptz default now() not null,

  -- identity
  confirmation_code         text unique not null,
  source                    text not null default 'airbnb'
                              check (source in ('airbnb','direct','other')),
  status                    text not null default 'confirmed'
                              check (status in ('confirmed','cancelled','completed')),

  -- guest (denormalised from booking email; guest_id linked after lookup/upsert)
  guest_id                  uuid references public.guests(id),
  guest_name                text,
  guest_count               integer,

  -- dates & times (parsed from email)
  checkin_date              date,
  checkout_date             date,
  checkin_time              text,
  checkout_time             text,
  nights                    integer generated always as
                              (checkout_date - checkin_date) stored,

  -- financials (from booking confirmation email)
  guest_paid                numeric(12,2),
  host_service_fee          numeric(12,2),
  host_payout               numeric(12,2),

  -- payout linkage (populated when payout email matches this code)
  payout_amount             numeric(12,2),
  payout_date               date,
  payout_email_message_id   text,

  -- cancellation
  cancelled_at              timestamptz,
  refund_type               text,   -- 'complete' | 'partial' | 'none'

  -- audit trail
  booking_email_message_id  text,
  cancel_email_message_id   text
);

comment on table public.airbnb_reservations is
  'One row per Airbnb reservation. Created from booking confirmation email, '
  'enriched by payout email, marked cancelled by cancellation email. '
  'confirmation_code is the universal join key across all email types.';

-- updated_at trigger
create trigger trg_airbnb_reservations_updated_at
  before update on public.airbnb_reservations
  for each row execute function public.set_updated_at();

-- Indexes
create index idx_airbnb_reservations_checkin
  on public.airbnb_reservations (checkin_date);
create index idx_airbnb_reservations_status
  on public.airbnb_reservations (status);
create index idx_airbnb_reservations_guest_id
  on public.airbnb_reservations (guest_id);

-- RLS
alter table public.airbnb_reservations enable row level security;

-- Anon: read-only (needed for calendar/availability queries from frontend)
create policy "anon read"
  on public.airbnb_reservations
  for select
  to anon
  using (true);

-- Service role: full access (EF writes)
create policy "service role full access"
  on public.airbnb_reservations
  for all
  to service_role
  using (true)
  with check (true);

-- Authenticated: full access (owner/admin UI)
create policy "authenticated full access"
  on public.airbnb_reservations
  for all
  to authenticated
  using (true)
  with check (true);
;
