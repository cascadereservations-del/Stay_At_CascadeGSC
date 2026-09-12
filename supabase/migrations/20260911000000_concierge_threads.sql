-- messenger-concierge v1: per-thread state + kill switch. Service-role only; no client access.
create table if not exists public.concierge_threads (
  psid        text primary key,
  guest_name  text,
  human_until timestamptz,
  bot_turns   int not null default 0,
  history     jsonb not null default '[]'::jsonb,
  last_risk   text,
  updated_at  timestamptz not null default now()
);
alter table public.concierge_threads enable row level security;
revoke all on public.concierge_threads from public, anon, authenticated;

-- 'off' | 'suggest' | 'auto'. Start in suggest: drafts go to the ops Telegram chat, guests get an acknowledgement.
insert into public.app_settings (key, value) values ('concierge_mode', '"suggest"'::jsonb)
on conflict (key) do nothing;

comment on table public.concierge_threads is 'Messenger concierge thread state. Retention: purge rows with updated_at older than 90 days.';
