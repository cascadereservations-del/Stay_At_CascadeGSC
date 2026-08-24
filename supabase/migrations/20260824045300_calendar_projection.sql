create table public.external_calendar_events (
  id uuid primary key default extensions.uuid_generate_v4(),
  provider text not null check (provider in ('google_calendar')),
  calendar_id_hash text not null,
  calendar_event_id text,
  booking_type text not null check (booking_type in ('direct','airbnb','manual_block')),
  booking_id uuid not null,
  sync_hash text not null,
  sync_status text not null default 'pending' check (sync_status in ('pending','synced','failed','cancelled')),
  last_synced_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider, calendar_id_hash, booking_type, booking_id)
);
alter table public.external_calendar_events enable row level security;
create policy external_calendar_events_owner_read on public.external_calendar_events for select to authenticated using ((auth.jwt() -> 'app_metadata' ->> 'role') in ('owner','admin'));
revoke all on public.external_calendar_events from anon, authenticated;
grant all on public.external_calendar_events to service_role;
