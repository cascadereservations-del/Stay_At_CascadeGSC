alter table public.guests add column if not exists phone_e164 text;
alter table public.guests add column if not exists email_normalized text;
alter table public.guests add column if not exists transactional_email_allowed boolean not null default false;
alter table public.guests add column if not exists transactional_whatsapp_allowed boolean not null default false;
alter table public.guests add column if not exists marketing_email_consent_at timestamptz;
alter table public.guests add column if not exists marketing_whatsapp_consent_at timestamptz;
alter table public.guests add constraint guests_marketing_email_after_created check (marketing_email_consent_at is null or marketing_email_consent_at >= created_at);
alter table public.guests add constraint guests_marketing_whatsapp_after_created check (marketing_whatsapp_consent_at is null or marketing_whatsapp_consent_at >= created_at);
create index if not exists guests_phone_e164_lookup_idx on public.guests (property_id, phone_e164) where phone_e164 is not null;
create index if not exists guests_email_normalized_lookup_idx on public.guests (property_id, email_normalized) where email_normalized is not null;

create table public.guest_identity_conflicts (
  id uuid primary key default extensions.uuid_generate_v4(),
  booking_key text not null,
  phone_guest_id uuid references public.guests(id),
  email_guest_id uuid references public.guests(id),
  match_bases text[] not null,
  status text not null default 'open' check (status in ('open','resolved','dismissed')),
  resolved_by uuid,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  check (phone_guest_id is distinct from email_guest_id)
);
create unique index guest_identity_conflicts_one_open_idx on public.guest_identity_conflicts (booking_key) where status = 'open';

create table public.guest_access_tokens (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null,
  booking_type text not null check (booking_type in ('direct','airbnb')),
  booking_id uuid not null,
  token_hash text not null unique,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  check (expires_at > created_at)
);
alter table public.guest_identity_conflicts enable row level security;
alter table public.guest_access_tokens enable row level security;
revoke all on public.guest_identity_conflicts, public.guest_access_tokens from anon, authenticated;
grant all on public.guest_identity_conflicts, public.guest_access_tokens to service_role;
