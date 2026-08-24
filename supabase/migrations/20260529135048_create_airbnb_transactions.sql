
create table if not exists public.airbnb_transactions (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id) default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd',
  row_type text not null check (row_type in ('payout','reservation','adjustment','cohost_payout')),
  txn_date date not null,
  arriving_by_date date,
  confirmation_code text,
  booking_date date,
  start_date date,
  end_date date,
  nights integer,
  guest_name text,
  listing text,
  details text,
  reference_code text,
  currency text default 'PHP',
  amount numeric,
  paid_out numeric,
  service_fee numeric,
  fast_pay_fee numeric,
  cleaning_fee numeric,
  gross_earnings numeric,
  airbnb_remitted_tax numeric,
  earnings_year integer,
  payout_account text,
  source_file text,
  row_hash text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_airbnb_txn_confcode on public.airbnb_transactions (confirmation_code);
create index if not exists idx_airbnb_txn_rowtype on public.airbnb_transactions (row_type);
create index if not exists idx_airbnb_txn_enddate on public.airbnb_transactions (end_date);
create index if not exists idx_airbnb_txn_date on public.airbnb_transactions (txn_date);

create trigger set_airbnb_transactions_updated_at
  before update on public.airbnb_transactions
  for each row execute function public.set_updated_at();

alter table public.airbnb_transactions enable row level security;

create policy airbnb_txn_owner_admin_all on public.airbnb_transactions
  for all to authenticated
  using ((((auth.jwt() -> 'user_metadata') ->> 'role') = any (array['owner','admin'])))
  with check ((((auth.jwt() -> 'user_metadata') ->> 'role') = any (array['owner','admin'])));
;
