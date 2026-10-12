-- Session 80 (security lane): release s80_rls_tighten_20261013. Who can read and write telegram_chat_history, inventory_purchases,
-- inventory_audit_log, and who can read booking_inquiries / airbnb_reservations, as anon, cleaner, admin, finance and service_role.
-- Synthetic fixtures only (uuids e8000000-...); every lookup is scoped to them. Grant assertions need ACLs, so the forward checks in the
-- release contract repeat them (a --no-acl rehearsal cannot prove grants). Everything rolls back.
begin;
select plan(37);

-- fixtures (as the superuser running the suite) ----------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values ('e8000000-0000-4000-8000-0000000000a1', 'Synthetic S80 Rls', true);
insert into public.inventory_items(id, property_id, name, category, qty_on_hand) values
  ('e8000000-0000-4000-8000-0000000000b1', 'e8000000-0000-4000-8000-0000000000a1', 'Zz S80 soap', 'Supplies', 5);
insert into public.inventory_purchases(id, item_id, qty, unit_cost, supplier) values
  ('e8000000-0000-4000-8000-0000000000c1', 'e8000000-0000-4000-8000-0000000000b1', 2, 99, 'Zz S80 supplier');
insert into public.inventory_audit_log(id, entity_type, entity_id, action, actor) values
  ('e8000000-0000-4000-8000-0000000000c2', 'inventory_items', 'e8000000-0000-4000-8000-0000000000b1', 'zz_s80', 'zz');
insert into public.telegram_chat_history(id, chat_id, role, parts) values
  ('e8000000-0000-4000-8000-0000000000c3', 'zz-s80-chat', 'user', '[{"text":"zz s80"}]');
insert into public.booking_inquiries(id, property_id, guest_name, guest_email, checkin_date, checkout_date, status) values
  ('e8000000-0000-4000-8000-0000000000d1', 'e8000000-0000-4000-8000-0000000000a1', 'Zz S80 Guest', 'zz80@example.com', '2030-06-01', '2030-06-04', 'confirmed');
insert into public.airbnb_reservations(id, property_id, confirmation_code, status, guest_name, checkin_date, checkout_date) values
  ('e8000000-0000-4000-8000-0000000000d2', 'e8000000-0000-4000-8000-0000000000a1', 'ZZS80CODE', 'confirmed', 'Zz S80 Airbnb', '2030-07-01', '2030-07-04');
insert into auth.users(id) values
  ('e8000000-0000-4000-8000-0000000000e1'), ('e8000000-0000-4000-8000-0000000000e2'), ('e8000000-0000-4000-8000-0000000000e3');
insert into public.staff_access_profiles(user_id, role) values
  ('e8000000-0000-4000-8000-0000000000e1', 'cleaner'),
  ('e8000000-0000-4000-8000-0000000000e2', 'admin'),
  ('e8000000-0000-4000-8000-0000000000e3', 'finance');
insert into public.staff_property_access(user_id, property_id) values
  ('e8000000-0000-4000-8000-0000000000e1', 'e8000000-0000-4000-8000-0000000000a1'),
  ('e8000000-0000-4000-8000-0000000000e2', 'e8000000-0000-4000-8000-0000000000a1'),
  ('e8000000-0000-4000-8000-0000000000e3', 'e8000000-0000-4000-8000-0000000000a1');

-- policies and grants (catalog) --------------------------------------------------------------------------------------------------------
select is((select count(*)::int from pg_policies where schemaname = 'public'
  and tablename in ('telegram_chat_history', 'inventory_purchases', 'inventory_audit_log') and roles && array['anon', 'public']::name[]), 0,
  'no anon or public policy left on the three tables');
select is((select count(*)::int from pg_policies where schemaname = 'public' and policyname in ('booking_inquiries_staff_read', 'airbnb_reservations_staff_read')), 0,
  'the read_operations staff_read policies are gone');
select is((select count(*)::int from pg_policies where schemaname = 'public' and policyname in ('booking_inquiries_finance_read', 'airbnb_reservations_finance_read')
  and qual like '%read_finance%' and qual not like '%read_operations%'), 2, 'finance_read policies use read_finance only');
select is((select count(*)::int from pg_policies where schemaname = 'public' and policyname in ('booking_inquiries_owner_admin_select', 'airbnb_reservations_owner_admin_all')), 2,
  'owner/admin policies are untouched');
select ok(not has_table_privilege('anon', 'public.telegram_chat_history', 'select,insert,update,delete,truncate,references,trigger')
      and not has_table_privilege('anon', 'public.inventory_purchases', 'select,insert,update,delete,truncate,references,trigger')
      and not has_table_privilege('anon', 'public.inventory_audit_log', 'select,insert,update,delete,truncate,references,trigger'), 'anon holds no privilege on the three tables');
select ok(not has_table_privilege('authenticated', 'public.telegram_chat_history', 'select,insert,update,delete,truncate,references,trigger')
      and not has_table_privilege('authenticated', 'public.inventory_audit_log', 'select,insert,update,delete,truncate,references,trigger'), 'authenticated holds nothing on chat history and audit log');
select ok(has_table_privilege('authenticated', 'public.inventory_purchases', 'select,insert,update,delete')
      and not has_table_privilege('authenticated', 'public.inventory_purchases', 'truncate,references,trigger'), 'authenticated keeps RLS-gated DML on purchases, not truncate');
select ok(has_table_privilege('service_role', 'public.telegram_chat_history', 'select,insert,update,delete')
      and has_table_privilege('service_role', 'public.inventory_purchases', 'select,insert,update,delete')
      and has_table_privilege('service_role', 'public.inventory_audit_log', 'select,insert,update,delete'), 'service_role keeps DML on the three tables');
select ok(has_table_privilege('authenticated', 'public.inventory_usage', 'insert') and has_table_privilege('authenticated', 'public.inventory_items', 'select'),
  'the cleaner submit path (inventory_usage insert, inventory_items read) is untouched');
select ok(not has_table_privilege('anon', 'public.booking_inquiries', 'select') and not has_table_privilege('anon', 'public.airbnb_reservations', 'select'), 'anon cannot read the booking tables');

-- anon ----------------------------------------------------------------------------------------------------------------------------------
set local role anon;
select throws_ok($$select 1 from public.telegram_chat_history$$, '42501', null, 'anon cannot read chat history');
select throws_ok($$insert into public.telegram_chat_history(chat_id, role, parts) values ('zz-s80-anon', 'user', '[]')$$, '42501', null, 'anon cannot write chat history');
select throws_ok($$select 1 from public.inventory_purchases$$, '42501', null, 'anon cannot read purchases');
select throws_ok($$insert into public.inventory_purchases(item_id, qty) values ('e8000000-0000-4000-8000-0000000000b1', 1)$$, '42501', null, 'anon cannot write purchases');
select throws_ok($$select 1 from public.inventory_audit_log$$, '42501', null, 'anon cannot read the audit log');
select throws_ok($$select 1 from public.booking_inquiries$$, '42501', null, 'anon cannot read booking_inquiries');
reset role;

-- cleaner -------------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e8000000-0000-4000-8000-0000000000e1"}';
select throws_ok($$select 1 from public.telegram_chat_history$$, '42501', null, 'cleaner cannot read chat history');
select throws_ok($$select 1 from public.inventory_audit_log$$, '42501', null, 'cleaner cannot read the audit log');
select is((select count(*)::int from public.inventory_purchases), 0, 'cleaner reads no purchases');
select throws_ok($$insert into public.inventory_purchases(item_id, qty) values ('e8000000-0000-4000-8000-0000000000b1', 1)$$, '42501', null, 'cleaner cannot write purchases');
select is((select count(*)::int from public.booking_inquiries where id = 'e8000000-0000-4000-8000-0000000000d1'), 0, 'cleaner no longer reads direct bookings (contacts, money)');
select is((select count(*)::int from public.airbnb_reservations where id = 'e8000000-0000-4000-8000-0000000000d2'), 0, 'cleaner no longer reads Airbnb reservations (payouts)');
select is((select count(*)::int from public.inventory_items where id = 'e8000000-0000-4000-8000-0000000000b1'), 1, 'cleaner still reads inventory_items for the usage log');
reset role;

-- admin (role from DB rows; the claim feeds the owner/admin booking policies) -----------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e8000000-0000-4000-8000-0000000000e2","app_metadata":{"role":"admin"}}';
select is((select count(*)::int from public.inventory_purchases where id = 'e8000000-0000-4000-8000-0000000000c1'), 1, 'admin reads purchases');
select lives_ok($$insert into public.inventory_purchases(id, item_id, qty, unit_cost) values ('e8000000-0000-4000-8000-0000000000c9', 'e8000000-0000-4000-8000-0000000000b1', 1, 50)$$, 'admin writes purchases');
select is((select count(*)::int from public.booking_inquiries where id = 'e8000000-0000-4000-8000-0000000000d1'), 1, 'admin reads direct bookings');
select is((select count(*)::int from public.airbnb_reservations where id = 'e8000000-0000-4000-8000-0000000000d2'), 1, 'admin reads Airbnb reservations');
select throws_ok($$select 1 from public.telegram_chat_history$$, '42501', null, 'admin cannot read chat history through the API either');
reset role;

-- finance (read_finance, no manage_inventory) ------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e8000000-0000-4000-8000-0000000000e3"}';
select is((select count(*)::int from public.booking_inquiries where id = 'e8000000-0000-4000-8000-0000000000d1'), 1, 'finance reads direct bookings');
select is((select count(*)::int from public.airbnb_reservations where id = 'e8000000-0000-4000-8000-0000000000d2'), 1, 'finance reads Airbnb reservations');
select is((select count(*)::int from public.inventory_purchases), 0, 'finance reads no purchases');
reset role;

-- service_role ---------------------------------------------------------------------------------------------------------------------------
set local role service_role;
select is((select count(*)::int from public.telegram_chat_history where id = 'e8000000-0000-4000-8000-0000000000c3'), 1, 'service_role reads chat history');
select lives_ok($$insert into public.telegram_chat_history(chat_id, role, parts) values ('zz-s80-svc', 'user', '[]')$$, 'service_role writes chat history');
select is((select count(*)::int from public.inventory_purchases where id = 'e8000000-0000-4000-8000-0000000000c1'), 1, 'service_role reads purchases');
select lives_ok($$insert into public.inventory_audit_log(entity_type, entity_id, action, actor) values ('inventory_items', 'e8000000-0000-4000-8000-0000000000b1', 'zz_s80_svc', 'zz')$$, 'service_role writes the audit log');
select is((select count(*)::int from public.booking_inquiries where id = 'e8000000-0000-4000-8000-0000000000d1'), 1, 'service_role reads booking_inquiries');
select is((select count(*)::int from public.airbnb_reservations where id = 'e8000000-0000-4000-8000-0000000000d2'), 1, 'service_role reads airbnb_reservations');
reset role;

select * from finish();
rollback;
