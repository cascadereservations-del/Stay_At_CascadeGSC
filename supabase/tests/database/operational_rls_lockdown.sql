begin;
select plan(24);

select has_column('public', 'inventory_items', 'property_id', 'inventory is property scoped');
select col_not_null('public', 'inventory_items', 'property_id', 'inventory property is required');
select col_is_fk('public', 'inventory_items', 'property_id', 'inventory property references properties');
select col_not_null('public', 'cleaning_sessions', 'property_id', 'cleaning property is required');
select col_not_null('public', 'meter_readings', 'property_id', 'meter property is required');
select has_function('public', 'staff_has_property_access', array['uuid', 'text[]'], 'property access helper exists');

select ok(not has_table_privilege('anon', 'public.inventory_items', 'select'), 'anon cannot read inventory');
select ok(not has_table_privilege('anon', 'public.inventory_items', 'insert'), 'anon cannot write inventory');
select ok(not has_table_privilege('anon', 'public.cleaning_sessions', 'select'), 'anon cannot read cleaning sessions');
select ok(not has_table_privilege('anon', 'public.cleaning_sessions', 'insert'), 'anon cannot submit cleaning directly');
select ok(not has_table_privilege('anon', 'public.meter_readings', 'select'), 'anon cannot read meters');
select ok(not has_table_privilege('anon', 'public.meter_readings', 'insert'), 'anon cannot write meters');

select ok(has_table_privilege('authenticated', 'public.inventory_items', 'select'), 'authenticated inventory reads are RLS gated');
select ok(has_table_privilege('authenticated', 'public.cleaning_sessions', 'insert'), 'authenticated cleaning writes are RLS gated');
select ok(has_table_privilege('authenticated', 'public.meter_readings', 'insert'), 'authenticated meter writes are RLS gated');
select ok(has_table_privilege('service_role', 'public.inventory_items', 'insert'), 'service role retains inventory writes');
select ok(has_table_privilege('service_role', 'public.cleaning_sessions', 'insert'), 'service role retains cleaning writes');
select ok(has_table_privilege('service_role', 'public.meter_readings', 'insert'), 'service role retains meter writes');
select ok(not has_table_privilege('anon', 'public.calendar_events', 'select'), 'public availability does not expose calendar rows');

insert into public.properties (id, name, is_active) values
  ('30000000-0000-4000-8000-000000000001', 'RLS Fixture One', true),
  ('30000000-0000-4000-8000-000000000002', 'RLS Fixture Two', true)
on conflict (id) do nothing;

insert into public.inventory_items (id, property_id, name, category, unit) values
  ('31000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001', 'RLS Fixture Item One', 'fixture', 'pc'),
  ('31000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000002', 'RLS Fixture Item Two', 'fixture', 'pc')
on conflict (id) do nothing;

insert into auth.users (id) values
  ('32000000-0000-4000-8000-000000000001'),
  ('32000000-0000-4000-8000-000000000002')
on conflict (id) do nothing;

insert into public.staff_access_profiles (user_id, role) values
  ('32000000-0000-4000-8000-000000000001', 'cleaner'),
  ('32000000-0000-4000-8000-000000000002', 'owner')
on conflict (user_id) do update
set role = excluded.role,
    disabled_at = null,
    sessions_revoked_after = null;

insert into public.staff_property_access (user_id, property_id) values
  ('32000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001')
on conflict do nothing;

set local role authenticated;
-- Deliberately poisoned claims prove authorization comes from DB-owned rows.
set local request.jwt.claims = '{"sub":"32000000-0000-4000-8000-000000000001","app_metadata":{"role":"owner","property_ids":["30000000-0000-4000-8000-000000000002"]}}';

select results_eq(
  $$select id from public.inventory_items where id in ('31000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000002') order by id$$,
  $$values ('31000000-0000-4000-8000-000000000001'::uuid)$$,
  'cleaner sees only assigned-property inventory'
);

select lives_ok(
  $$insert into public.cleaning_sessions (id, submission_id, cleaner_name, property_id) values ('33000000-0000-4000-8000-000000000001', 'rls-allowed', 'Fixture Cleaner', '30000000-0000-4000-8000-000000000001')$$,
  'cleaner may submit for an assigned property'
);

select throws_ok(
  $$insert into public.cleaning_sessions (id, submission_id, cleaner_name, property_id) values ('33000000-0000-4000-8000-000000000002', 'rls-denied', 'Fixture Cleaner', '30000000-0000-4000-8000-000000000002')$$,
  '42501',
  null,
  'cleaner cannot submit for another property'
);

reset role;
update public.staff_access_profiles
set disabled_at = now()
where user_id = '32000000-0000-4000-8000-000000000001';
set local role authenticated;
select is(
  (select count(*) from public.inventory_items where id in ('31000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000002')),
  0::bigint,
  'disabled staff immediately lose operational access despite stale JWT claims'
);

set local request.jwt.claims = '{"sub":"32000000-0000-4000-8000-000000000002","app_metadata":{"role":"cleaner","property_ids":[]}}';
select is(
  (select count(*) from public.inventory_items where id in ('31000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000002')),
  2::bigint,
  'owner sees inventory across properties'
);

reset role;
select * from finish();
rollback;
