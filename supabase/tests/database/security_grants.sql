-- Session 49: release security_grants_20260925 (SPEC-26, D-228). Who may execute what after the release, and that
-- the three search_path-pinned functions still work. Fixtures are rolled back.
begin;
select plan(12);

select ok(not has_function_privilege('anon', 'public.get_cleanable_bookings(date, uuid, integer, integer)', 'execute')
      and not has_function_privilege('anon', 'public.get_meter_photo_followups(uuid, integer)', 'execute')
      and not has_function_privilege('anon', 'public.can_skip_meter_photos(uuid)', 'execute'),
  'anon cannot run the three checklist functions');
select ok(has_function_privilege('authenticated', 'public.get_cleanable_bookings(date, uuid, integer, integer)', 'execute')
      and has_function_privilege('authenticated', 'public.get_meter_photo_followups(uuid, integer)', 'execute')
      and has_function_privilege('authenticated', 'public.can_skip_meter_photos(uuid)', 'execute'),
  'a signed-in cleaner still can (the checklist picker, B32)');
select ok(not has_function_privilege('anon', 'public.get_meter_photo_objects(text, timestamptz, integer)', 'execute')
      and not has_function_privilege('authenticated', 'public.get_meter_photo_objects(text, timestamptz, integer)', 'execute')
      and not has_function_privilege('anon', 'public.get_meter_sessions_pending_vision(uuid, integer, integer)', 'execute')
      and not has_function_privilege('authenticated', 'public.get_meter_sessions_pending_vision(uuid, integer, integer)', 'execute'),
  'the two meter-vision reads are service_role only');
select ok(has_function_privilege('service_role', 'public.get_meter_photo_objects(text, timestamptz, integer)', 'execute')
      and has_function_privilege('service_role', 'public.get_meter_sessions_pending_vision(uuid, integer, integer)', 'execute'),
  'verify-meter-photo keeps them');
select ok(not has_function_privilege('anon', 'public.get_welcome_info(date, uuid)', 'execute')
      and not has_function_privilege('anon', 'public.get_usage_medians()', 'execute'),
  'the two uncalled functions are off anon, PUBLIC included');
select ok(not has_function_privilege('anon', 'public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid)', 'execute')
      and not has_function_privilege('anon', 'public.match_inventory_item(text, integer, real, boolean)', 'execute')
      and not has_function_privilege('anon', 'public.try_uuid(text)', 'execute'),
  'the three telegram-expense helpers are off anon, PUBLIC included');
select ok(has_function_privilege('service_role', 'public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid)', 'execute')
      and has_function_privilege('service_role', 'public.match_inventory_item(text, integer, real, boolean)', 'execute')
      and has_function_privilege('service_role', 'public.try_uuid(text)', 'execute'),
  'telegram-expense (service_role) keeps them');
select ok(has_function_privilege('anon', 'public.verify_booking(date, text, uuid)', 'execute')
      and has_function_privilege('anon', 'public.get_checklist_staff_names()', 'execute'),
  'the deliberate anon functions are untouched (D-228)');
select ok((select bool_and(p.proconfig is not null) from pg_proc p where p.pronamespace = 'public'::regnamespace
            and p.proname in ('apply_inventory_purchase', 'match_inventory_item', 'try_uuid')),
  'all three have a pinned search_path');
select is(public.try_uuid('not-a-uuid'), null, 'try_uuid still answers null for junk');
insert into public.properties(id, name, is_active) values ('e1000000-0000-4000-8000-000000000026', 'Synthetic Security 26', true);
insert into public.inventory_items(id, property_id, name, category, is_active, is_consumable, qty_on_hand)
values ('e9000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000026', 'Synthetic Liquid Hand Soap', 'cleaning', true, true, 3);
select ok(exists (select 1 from public.match_inventory_item('Synthetic Liquid Hand Soap', 3, 0.3, false) m where m.id = 'e9000000-0000-4000-8000-000000000001'),
  'match_inventory_item still finds similarity() through the pinned search_path');
select ok(not has_table_privilege('anon', 'public.app_secrets', 'select')
      and not has_table_privilege('authenticated', 'public.telegram_pending', 'select')
      and not has_table_privilege('anon', 'public.admin_auth_attempts', 'insert')
      and not has_table_privilege('authenticated', 'public.telegram_processed_updates', 'delete'),
  'the dead table grants are gone');

select * from finish();
rollback;
