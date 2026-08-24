-- P0 #2 — receipt photo persistence
alter table inventory_purchases add column if not exists receipt_path text;

-- P0 #5 — inventory_usage lookup index
create index if not exists inventory_usage_item_date_idx
  on inventory_usage (item_id, session_date desc);

-- P0 #4 — settings keys
insert into app_settings (key, value) values
  ('avg_bookings_per_month', '8'::jsonb),
  ('inactivity_alerts',      'true'::jsonb),
  ('users', '["Marifel","Honey","Lloyd","Others"]'::jsonb)
on conflict (key) do nothing;

drop policy if exists "anon update settings" on app_settings;
create policy "anon update settings" on app_settings
  for update to anon
  using (key <> 'admin_pin_hash')
  with check (key <> 'admin_pin_hash');

drop policy if exists "anon insert settings" on app_settings;
create policy "anon insert settings" on app_settings
  for insert to anon
  with check (key <> 'admin_pin_hash');

-- P0 #3 — admin PIN bcrypt hash + RPC
insert into app_settings (key, value)
values ('admin_pin_hash',
        to_jsonb(extensions.crypt('cascade123', extensions.gen_salt('bf'))))
on conflict (key) do nothing;

drop policy if exists "anon select" on app_settings;
create policy "anon select" on app_settings
  for select to anon
  using (key <> 'admin_pin_hash');

create or replace function verify_admin_pin(pin text)
returns boolean
language sql
security definer
set search_path = public, extensions
as $$
  select exists (
    select 1 from app_settings
    where key = 'admin_pin_hash'
      and value #>> '{}' = extensions.crypt(pin, value #>> '{}')
  );
$$;

revoke all on function verify_admin_pin(text) from public;
grant execute on function verify_admin_pin(text) to anon, authenticated;;
