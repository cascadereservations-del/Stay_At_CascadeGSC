-- Host handoff cards for the Messenger concierge (D-071). One row per guest message that the
-- bot handed to a human; the Telegram card's buttons resolve it. Service-role only.
create table if not exists public.concierge_handoffs (
  id            uuid primary key default gen_random_uuid(),
  psid          text not null,
  guest_name    text,
  guest_text    text not null,
  risk          text not null,
  options       jsonb not null default '[]'::jsonb,
  status        text not null default 'open' check (status in ('open', 'sent', 'dismissed')),
  tg_message_id bigint,
  resolved_by   text,
  resolved_at   timestamptz,
  sent_text     text,
  created_at    timestamptz not null default now()
);

create index if not exists concierge_handoffs_open_idx on public.concierge_handoffs (status, created_at desc);

alter table public.concierge_handoffs enable row level security;
revoke all on table public.concierge_handoffs from public, anon, authenticated;

comment on table public.concierge_handoffs is
  'Messenger concierge -> host handoff cards. Written by the messenger-concierge Edge Function; resolved by Telegram button taps forwarded from telegram-expense. Service-role only.';
