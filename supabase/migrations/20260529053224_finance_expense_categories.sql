-- Expense category taxonomy for the Smart Finance Layer.
-- Multi-property (property_id), keyword aliases drive Telegram/OCR classification.
create table if not exists public.expense_categories (
  id          uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
              references public.properties(id) on delete cascade,
  slug        text not null,                       -- canonical value written to transactions.category
  label       text not null,                       -- human display
  keywords    text[] not null default '{}',        -- aliases matched by the parser/OCR
  sort_order  int  not null default 100,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (property_id, slug)
);

drop trigger if exists set_updated_at on public.expense_categories;
create trigger set_updated_at before update on public.expense_categories
  for each row execute function public.set_updated_at();

alter table public.expense_categories enable row level security;

-- Mirror the transactions/guests pattern: owner+admin only (finance is restricted).
drop policy if exists expense_categories_owner_admin_all on public.expense_categories;
create policy expense_categories_owner_admin_all on public.expense_categories
  for all to authenticated
  using      ((((auth.jwt() -> 'user_metadata') ->> 'role') = any (array['owner','admin'])))
  with check ((((auth.jwt() -> 'user_metadata') ->> 'role') = any (array['owner','admin'])));

-- Seed standard categories (task list + 'other' fallback). Keywords cover PH vendors/terms.
insert into public.expense_categories (slug, label, keywords, sort_order) values
  ('supplies',      'Supplies',          array['supplies','supply','puregold','gaisano','kcc','grocery','groceries','toiletries','amenities','consumables','sm','savemore'], 10),
  ('utilities',     'Utilities',         array['utilities','utility','electric','electricity','meralco','soccsargen','power','water','gscwd','internet','wifi','wi-fi','converge','pldt','globe','load','bill'], 20),
  ('cleaning',      'Cleaning',          array['cleaning','cleaner','detergent','soap','bleach','zonrox','laundry','housekeeping'], 30),
  ('maintenance',   'Maintenance',       array['maintenance','aircon','ac service','cleaning aircon','pest','garden','upkeep','service'], 40),
  ('repairs',       'Repairs',           array['repair','repairs','fix','plumber','plumbing','electrician','parts','replace','replacement'], 50),
  ('platform_fees', 'Platform Fees',     array['platform','airbnb','commission','fee','fees','service fee','booking fee','transaction fee'], 60),
  ('other',         'Other',             array['other','misc','miscellaneous'], 999)
on conflict (property_id, slug) do nothing;;
