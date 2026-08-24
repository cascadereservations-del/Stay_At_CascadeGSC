
alter table public.transactions drop constraint transactions_source_check;
alter table public.transactions add constraint transactions_source_check
  check (source = any (array['telegram','ocr','booking','manual','import','airbnb']));

alter table public.transactions add column if not exists external_ref text;

create unique index if not exists uq_transactions_external_ref
  on public.transactions (external_ref) where external_ref is not null;
;
