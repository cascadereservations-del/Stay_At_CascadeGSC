create table public.notification_routes (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null,
  event_type text not null,
  channel text not null check (channel in ('email','telegram','whatsapp')),
  enabled boolean not null default false,
  minimum_severity text not null default 'operational' check (minimum_severity in ('operational','urgent','critical')),
  recipient_secret_name text not null check (recipient_secret_name ~ '^CASCADE_[A-Z0-9_]+$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (property_id, event_type, channel)
);
alter table public.notification_routes enable row level security;
create policy notification_routes_owner_read on public.notification_routes for select to authenticated using ((auth.jwt() -> 'app_metadata' ->> 'role') in ('owner','admin'));
revoke all on public.notification_routes from anon, authenticated;
grant all on public.notification_routes to service_role;
