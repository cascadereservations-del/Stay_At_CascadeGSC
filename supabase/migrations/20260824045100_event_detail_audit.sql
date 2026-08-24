create table public.automation_event_access_log (
  id uuid primary key default extensions.uuid_generate_v4(),
  outbox_id uuid not null references public.automation_outbox(id) on delete cascade,
  workflow_id text not null,
  credential_hash text not null,
  accessed_at timestamptz not null default now(),
  expires_at timestamptz not null,
  unique (outbox_id, workflow_id, credential_hash)
);
alter table public.automation_event_access_log enable row level security;
revoke all on public.automation_event_access_log from anon, authenticated;
grant all on public.automation_event_access_log to service_role;
