create table public.automation_outbox (
  id uuid primary key default extensions.uuid_generate_v4(),
  schema_version integer not null default 1 check (schema_version = 1),
  event_type text not null check (event_type in ('booking.requested','booking.receipt_uploaded','booking.confirmed','booking.cancelled','guest.returning_detected','guest.identity_conflict','calendar.projection_requested','calendar.conflict')),
  aggregate_type text not null check (aggregate_type in ('booking_inquiry','reservation','guest','calendar_event')),
  aggregate_id uuid not null,
  idempotency_key text not null unique check (char_length(idempotency_key) between 1 and 160),
  payload jsonb not null default '{}'::jsonb check (jsonb_typeof(payload) = 'object'),
  status text not null default 'pending' check (status in ('pending','dispatched','completed','failed','dead_letter')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  next_attempt_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  dispatched_at timestamptz,
  completed_at timestamptz,
  last_error_code text check (last_error_code is null or last_error_code ~ '^[A-Za-z0-9_]{1,64}$')
);
create table public.automation_delivery_log (
  id uuid primary key default extensions.uuid_generate_v4(),
  outbox_id uuid not null references public.automation_outbox(id) on delete cascade,
  workflow_id text not null check (workflow_id in ('CH-S01','CH-W01','CH-W02','CH-W03','CH-W04','CH-W05','CH-W06','CH-W07','CH-W08','CH-W09','CH-W10','CH-W11','CH-W12')),
  channel text not null check (channel in ('email','telegram','whatsapp','internal')),
  recipient_hash text,
  provider_message_id text,
  status text not null check (status in ('pending','sent','failed','skipped')),
  attempted_at timestamptz not null default now(),
  completed_at timestamptz,
  error_code text check (error_code is null or error_code ~ '^[A-Za-z0-9_]{1,64}$')
);
create index automation_outbox_pending_idx on public.automation_outbox (status, next_attempt_at) where status in ('pending','dispatched','failed');
create index automation_delivery_log_outbox_idx on public.automation_delivery_log (outbox_id, attempted_at desc);
alter table public.automation_outbox enable row level security;
alter table public.automation_delivery_log enable row level security;
revoke all on public.automation_outbox, public.automation_delivery_log from anon, authenticated;
grant all on public.automation_outbox, public.automation_delivery_log to service_role;
