-- Named-cleaner cutover: bind operational writes to an authenticated user and
-- property, remove anonymous inventory/photo access, and route cleaner expenses
-- to a Finance review queue instead of the confirmed ledger.

alter table public.cleaning_sessions
  add column if not exists submitted_by_user_id uuid references auth.users(id);

alter table public.meter_readings
  add column if not exists submitted_by_user_id uuid references auth.users(id);

alter table public.inventory_usage
  add column if not exists property_id uuid references public.properties(id),
  add column if not exists cleaning_session_id uuid references public.cleaning_sessions(id),
  add column if not exists submitted_by_user_id uuid references auth.users(id);

update public.inventory_usage u
set property_id = i.property_id
from public.inventory_items i
where u.item_id = i.id
  and u.property_id is null;

do $$
declare
  v_property_id uuid;
begin
  if exists (select 1 from public.inventory_usage where property_id is null) then
    select id into v_property_id
    from public.properties
    where is_active
    order by created_at, id
    limit 1;

    if v_property_id is null
      or (select count(*) from public.properties where is_active) <> 1 then
      raise exception using
        errcode = '23514',
        message = 'inventory usage backfill requires exactly one active property';
    end if;
    update public.inventory_usage set property_id = v_property_id where property_id is null;
  end if;
end;
$$;

alter table public.inventory_usage alter column property_id set not null;

create index if not exists inventory_usage_property_date_idx
  on public.inventory_usage(property_id, session_date desc);
create index if not exists cleaning_sessions_submitter_idx
  on public.cleaning_sessions(submitted_by_user_id, cleaned_at desc);
create index if not exists meter_readings_submitter_idx
  on public.meter_readings(submitted_by_user_id, recorded_at desc);

drop policy if exists cleaning_staff_insert on public.cleaning_sessions;
drop policy if exists cleaning_staff_update on public.cleaning_sessions;
drop policy if exists meters_staff_insert on public.meter_readings;
drop policy if exists meters_staff_update on public.meter_readings;

create policy cleaning_staff_insert on public.cleaning_sessions
  for insert to authenticated
  with check (
    public.current_staff_authorized('submit_cleaning', property_id)
    and submitted_by_user_id = auth.uid()
  );

create policy cleaning_staff_update on public.cleaning_sessions
  for update to authenticated
  using (
    public.current_staff_authorized('submit_cleaning', property_id)
    and submitted_by_user_id = auth.uid()
  )
  with check (
    public.current_staff_authorized('submit_cleaning', property_id)
    and submitted_by_user_id = auth.uid()
  );

create policy meters_staff_insert on public.meter_readings
  for insert to authenticated
  with check (
    public.current_staff_authorized('submit_cleaning', property_id)
    and submitted_by_user_id = auth.uid()
  );

create policy meters_staff_update on public.meter_readings
  for update to authenticated
  using (
    public.current_staff_authorized('submit_cleaning', property_id)
    and submitted_by_user_id = auth.uid()
  )
  with check (
    public.current_staff_authorized('submit_cleaning', property_id)
    and submitted_by_user_id = auth.uid()
  );

drop policy if exists "anon insert" on public.inventory_usage;
drop policy if exists "anon select" on public.inventory_usage;
drop policy if exists inventory_usage_staff_read on public.inventory_usage;
drop policy if exists inventory_usage_staff_insert on public.inventory_usage;
drop policy if exists inventory_usage_management on public.inventory_usage;

revoke all on table public.inventory_usage from anon, authenticated;
grant select, insert, update, delete on table public.inventory_usage to authenticated;
grant all on table public.inventory_usage to service_role;
alter table public.inventory_usage enable row level security;

create policy inventory_usage_staff_read on public.inventory_usage
  for select to authenticated
  using (public.current_staff_authorized('read_operations', property_id));

create policy inventory_usage_staff_insert on public.inventory_usage
  for insert to authenticated
  with check (
    public.current_staff_authorized('submit_cleaning', property_id)
    and submitted_by_user_id = auth.uid()
  );

create policy inventory_usage_management on public.inventory_usage
  for all to authenticated
  using (public.current_staff_authorized('manage_inventory', property_id))
  with check (public.current_staff_authorized('manage_inventory', property_id));

create table if not exists public.cleaning_expense_claims (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  cleaning_session_id uuid not null references public.cleaning_sessions(id) on delete cascade,
  submitted_by_user_id uuid not null references auth.users(id),
  expense_date date not null,
  description text not null check (char_length(btrim(description)) between 3 and 500),
  amount numeric(12,2) not null check (amount > 0),
  currency text not null default 'PHP' check (currency = 'PHP'),
  status text not null default 'pending_review'
    check (status in ('pending_review','approved','rejected','paid')),
  reviewed_by_user_id uuid references auth.users(id),
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.cleaning_expense_claims enable row level security;
revoke all on table public.cleaning_expense_claims from public, anon, authenticated;
grant select on table public.cleaning_expense_claims to authenticated;
grant all on table public.cleaning_expense_claims to service_role;

drop policy if exists expense_claim_submitter_read on public.cleaning_expense_claims;
drop policy if exists expense_claim_finance_read on public.cleaning_expense_claims;

create policy expense_claim_submitter_read on public.cleaning_expense_claims
  for select to authenticated
  using (
    submitted_by_user_id = auth.uid()
    and public.current_staff_authorized('submit_cleaning', property_id)
  );

create policy expense_claim_finance_read on public.cleaning_expense_claims
  for select to authenticated
  using (public.current_staff_authorized('read_finance', property_id));

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values (
  'cleaning-photos',
  'cleaning-photos',
  false,
  5242880,
  array['image/jpeg','image/png','image/webp']::text[]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "anon read cleaning photos" on storage.objects;
drop policy if exists "anon upload cleaning photos" on storage.objects;
drop policy if exists "authenticated all cleaning photos" on storage.objects;
drop policy if exists public_read_cleaning_photos on storage.objects;
drop policy if exists service_insert_cleaning_photos on storage.objects;

comment on table public.cleaning_expense_claims is
  'Cleaner-submitted expenses awaiting Finance review; rows are never ledger confirmation.';
comment on column public.cleaning_sessions.submitted_by_user_id is
  'Named Supabase Auth identity that submitted the cleaning report.';
