-- Pending transaction confirmations for the Telegram finance bot.
-- Holds payloads that require user confirmation (duplicates, large amounts, photo re-upload)
-- before being written to public.transactions. Expires after 10 minutes.

create table if not exists public.telegram_pending (
  id          uuid primary key default extensions.uuid_generate_v4(),
  chat_id     bigint not null,
  kind        text not null check (kind in ('duplicate','large_amount','photo_dup')),
  payload     jsonb not null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default (now() + interval '10 minutes')
);

alter table public.telegram_pending enable row level security;
-- Service role only — no public access. EF uses service role (bypasses RLS).
-- No policies added intentionally.

create index if not exists telegram_pending_expires_idx on public.telegram_pending(expires_at);
create index if not exists telegram_pending_chat_idx    on public.telegram_pending(chat_id);;
