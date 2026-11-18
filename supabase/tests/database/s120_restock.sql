-- Session 120 (lane S6): release s120_restock_20261120. restock_context_v1, record_restock_v1, restock_remind_admin_v1 and the two closed tables.
-- Synthetic fixtures only (global keys e1200002-..., property ...b0 and ...b1, items "Zz S120R ...", uids zz-s120r-*); every lookup is scoped to them because a real backup holds real rows.
-- Refusals are tested by calling as the refused role. Hand-computed values: stock A 10, B 5, Zero 0; Manila dates throughout; calendar_events.nights is generated and never sent.
-- Everything rolls back.
begin;
select plan(54);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid), public.current_staff_active(text[]) to authenticated, service_role;

create temp table _r(k text primary key, v jsonb);
grant all on _r to authenticated, service_role;

-- fixtures -------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values
  ('e1200002-0000-4000-8000-0000000000b0', 'Synthetic S120R A', true),
  ('e1200002-0000-4000-8000-0000000000b1', 'Synthetic S120R B', true);
insert into auth.users(id) values ('e1200002-0000-4000-8000-000000000001'), ('e1200002-0000-4000-8000-000000000002'), ('e1200002-0000-4000-8000-000000000003');
insert into public.staff_access_profiles(user_id, role) values
  ('e1200002-0000-4000-8000-000000000001', 'cleaner'),
  ('e1200002-0000-4000-8000-000000000003', 'laundry');
-- 02 has no staff profile at all
insert into public.staff_property_access(user_id, property_id) values
  ('e1200002-0000-4000-8000-000000000001', 'e1200002-0000-4000-8000-0000000000b0'),
  ('e1200002-0000-4000-8000-000000000003', 'e1200002-0000-4000-8000-0000000000b0');
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active) values
  ('e1200002-0000-4000-8000-0000000000a1', 'e1200002-0000-4000-8000-0000000000b0', 'Zz S120R A',        'Other', 'pc', 10, true,  true),
  ('e1200002-0000-4000-8000-0000000000a2', 'e1200002-0000-4000-8000-0000000000b0', 'Zz S120R B',        'Other', 'pc', 5,  true,  true),
  ('e1200002-0000-4000-8000-0000000000a3', 'e1200002-0000-4000-8000-0000000000b0', 'Zz S120R Zero',     'Other', 'pc', 0,  true,  true),
  ('e1200002-0000-4000-8000-0000000000a4', 'e1200002-0000-4000-8000-0000000000b0', 'Zz S120R Inactive', 'Other', 'pc', 8,  true,  false),
  ('e1200002-0000-4000-8000-0000000000a5', 'e1200002-0000-4000-8000-0000000000b0', 'Zz S120R Fixture',  'Other', 'pc', 8,  false, true),
  ('e1200002-0000-4000-8000-0000000000a6', 'e1200002-0000-4000-8000-0000000000b1', 'Zz S120R Other',    'Other', 'pc', 8,  true,  true);
-- an old remembered amount for the inactive item: it must never come back out
insert into public.restock_remembered_amounts(property_id, item_id, amount) values ('e1200002-0000-4000-8000-0000000000b0', 'e1200002-0000-4000-8000-0000000000a4', 6);

-- guests, stays: g2 (regular) arrives today, g1 (no tier) in five days; a blocked event today must be ignored
insert into public.guests(id, property_id, name) values
  ('e1200002-0000-4000-8000-0000000000c1', 'e1200002-0000-4000-8000-0000000000b0', 'Zz S120R Guest One'),
  ('e1200002-0000-4000-8000-0000000000c2', 'e1200002-0000-4000-8000-0000000000b0', 'Zz S120R Guest Two');
update public.guests set tier = 'regular', tier_manual = 'vip' where id = 'e1200002-0000-4000-8000-0000000000c2';
insert into public.airbnb_reservations(id, property_id, confirmation_code, source, status, guest_id, guest_name, guest_count, checkin_date, checkout_date) values
  ('e1200002-0000-4000-8000-0000000000d1', 'e1200002-0000-4000-8000-0000000000b0', 'ZZS120R1', 'airbnb', 'confirmed', 'e1200002-0000-4000-8000-0000000000c2', 'Zz S120R Guest Two',
     2, (now() at time zone 'Asia/Manila')::date, (now() at time zone 'Asia/Manila')::date + 2),
  ('e1200002-0000-4000-8000-0000000000d2', 'e1200002-0000-4000-8000-0000000000b0', 'ZZS120R2', 'airbnb', 'confirmed', 'e1200002-0000-4000-8000-0000000000c1', 'Zz S120R Guest One',
     2, (now() at time zone 'Asia/Manila')::date + 5, (now() at time zone 'Asia/Manila')::date + 7);
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date, linked_reservation_id) values
  ('e1200002-0000-4000-8000-0000000000b0', 'zz-s120r-today', 'airbnb', 'confirmed', 'Zz S120R Guest Two', (now() at time zone 'Asia/Manila')::date,     (now() at time zone 'Asia/Manila')::date + 2, 'e1200002-0000-4000-8000-0000000000d1'),
  ('e1200002-0000-4000-8000-0000000000b0', 'zz-s120r-later', 'airbnb', 'confirmed', 'Zz S120R Guest One', (now() at time zone 'Asia/Manila')::date + 5, (now() at time zone 'Asia/Manila')::date + 7, 'e1200002-0000-4000-8000-0000000000d2');
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  ('e1200002-0000-4000-8000-0000000000b0', 'zz-s120r-blk', 'airbnb', 'blocked', null, (now() at time zone 'Asia/Manila')::date, (now() at time zone 'Asia/Manila')::date + 1);

-- upkeep: the last "changed" answer of both kinds was 20 days ago; sessions: one turnover before it, two turnovers and a mid-stay after it
insert into public.restock_upkeep_checks(property_id, kind, changed, session_date, check_key, created_at) values
  ('e1200002-0000-4000-8000-0000000000b0', 'dish_soap',   true, current_date - 20, 'zz-s120r-base-soap',   now() - interval '20 days'),
  ('e1200002-0000-4000-8000-0000000000b0', 'dish_sponge', true, current_date - 20, 'zz-s120r-base-sponge', now() - interval '20 days');
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type) values
  ('e1200002-0000-4000-8000-0000000000b0', 'zz-s120r-s30', 'Fixture', now() - interval '30 days', 'turnover'),
  ('e1200002-0000-4000-8000-0000000000b0', 'zz-s120r-s10', 'Fixture', now() - interval '10 days', 'turnover'),
  ('e1200002-0000-4000-8000-0000000000b0', 'zz-s120r-s9',  'Fixture', now() - interval '9 days',  'turnover'),
  ('e1200002-0000-4000-8000-0000000000b0', 'zz-s120r-s8',  'Fixture', now() - interval '8 days',  'mid_stay');

-- 1-4. closed tables, grants, shape --------------------------------------------------------------------------------------------------------
select ok((select bool_and(relrowsecurity) from pg_class where oid in ('public.restock_remembered_amounts'::regclass, 'public.restock_upkeep_checks'::regclass)), 'RLS is on for both restock tables');
select ok(not has_table_privilege('anon', 'public.restock_remembered_amounts', 'select, insert, update, delete') and not has_table_privilege('authenticated', 'public.restock_remembered_amounts', 'select, insert, update, delete')
      and not has_table_privilege('service_role', 'public.restock_remembered_amounts', 'select, insert, update, delete') and not has_table_privilege('anon', 'public.restock_upkeep_checks', 'select, insert, update, delete')
      and not has_table_privilege('authenticated', 'public.restock_upkeep_checks', 'select, insert, update, delete') and not has_table_privilege('service_role', 'public.restock_upkeep_checks', 'select, insert, update, delete'),
  'neither restock table has a direct grant for any API role');
select ok(not has_function_privilege('anon', 'public.restock_context_v1(uuid)', 'execute') and not has_function_privilege('anon', 'public.record_restock_v1(uuid,date,text,text,jsonb,jsonb,jsonb)', 'execute')
      and not has_function_privilege('anon', 'public.restock_remind_admin_v1(uuid,uuid)', 'execute') and has_function_privilege('authenticated', 'public.restock_context_v1(uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.record_restock_v1(uuid,date,text,text,jsonb,jsonb,jsonb)', 'execute') and has_function_privilege('authenticated', 'public.restock_remind_admin_v1(uuid,uuid)', 'execute')
      and has_function_privilege('service_role', 'public.restock_context_v1(uuid)', 'execute'), 'the three RPCs: no anon, signed-in and service_role may execute');
select ok((select bool_and(prosecdef and proconfig = array['search_path=""']) from pg_proc where oid in ('public.restock_context_v1(uuid)'::regprocedure,
            'public.record_restock_v1(uuid,date,text,text,jsonb,jsonb,jsonb)'::regprocedure, 'public.restock_remind_admin_v1(uuid,uuid)'::regprocedure)), 'all three are security definer with an empty search_path');

-- 5-9. the gate: a user with no staff profile and a call with no session are refused; a laundry user (report_supply) is let in -------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200002-0000-4000-8000-000000000002"}';
select throws_ok($$select public.restock_context_v1('e1200002-0000-4000-8000-0000000000b0')$$, '42501', null, 'no staff profile: the context is refused');
select throws_ok($$select public.record_restock_v1('e1200002-0000-4000-8000-0000000000b0', current_date, 'x', null, '[]', '{}', '[]')$$, '42501', null, 'no staff profile: the save is refused');
select throws_ok($$select public.restock_remind_admin_v1('e1200002-0000-4000-8000-0000000000b0', 'e1200002-0000-4000-8000-0000000000a1')$$, '42501', null, 'no staff profile: the reminder is refused');
reset role;
set local role authenticated;
set local request.jwt.claims = '{}';
select throws_ok($$select public.restock_context_v1('e1200002-0000-4000-8000-0000000000b0')$$, '42501', null, 'no session: the context is refused');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200002-0000-4000-8000-000000000003"}';
select lives_ok($$select public.restock_context_v1('e1200002-0000-4000-8000-0000000000b0')$$, 'a laundry user (report_supply) may read the context');
reset role;

-- 10-13. context: exact keys, no guest field, active consumables only ------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200002-0000-4000-8000-000000000001"}';
insert into _r select 'c1', public.restock_context_v1('e1200002-0000-4000-8000-0000000000b0');
reset role;
select is((select array_agg(k order by k) from jsonb_object_keys((select v from _r where k = 'c1')) k), array['next_tier', 'ok', 'remembered', 'stock', 'upkeep_due'], 'the context holds exactly ok, stock, remembered, upkeep_due, next_tier');
select ok((select v::text from _r where k = 'c1') !~* '(guest|e1200002-0000-4000-8000-0000000000c|zz-s120r|ZZS120R|20[0-9]{2}-[0-9]{2}-[0-9]{2})', 'no guest name, id, uid, confirmation code or date in the context');
select is((select jsonb_array_length(v -> 'stock') from _r where k = 'c1'), 3, 'stock lists the three active consumables only');
select ok(not (select v -> 'stock' from _r where k = 'c1') @> '[{"item_id": "e1200002-0000-4000-8000-0000000000a4"}]'
      and not (select v -> 'stock' from _r where k = 'c1') @> '[{"item_id": "e1200002-0000-4000-8000-0000000000a5"}]' and not (select v -> 'stock' from _r where k = 'c1') @> '[{"item_id": "e1200002-0000-4000-8000-0000000000a6"}]'
      and (select v -> 'remembered' from _r where k = 'c1') = '{}'::jsonb, 'the inactive, non-consumable and other-property items are absent, and the inactive item''s remembered amount stays hidden');

-- 14-16. next_tier: a same-day arrival counts, an unlinked stay and a first stay give null ---------------------------------------------------
select is((select v ->> 'next_tier' from _r where k = 'c1'), (select tier from public.guests where id = 'e1200002-0000-4000-8000-0000000000c2'), 'a guest arriving today is the next guest: their tier comes back');
select isnt((select tier from public.guests where id = 'e1200002-0000-4000-8000-0000000000c2'), null, 'fixture check: the same-day guest has a tier');
update public.calendar_events set linked_reservation_id = null, checkout_date = (now() at time zone 'Asia/Manila')::date + 3 where property_id = 'e1200002-0000-4000-8000-0000000000b0' and uid = 'zz-s120r-today';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200002-0000-4000-8000-000000000001"}';
insert into _r select 'c2', public.restock_context_v1('e1200002-0000-4000-8000-0000000000b0');
reset role;
select is((select v ->> 'next_tier' from _r where k = 'c2'), null, 'an unlinked arrival gives null, not a guess');
update public.calendar_events set checkin_date = (now() at time zone 'Asia/Manila')::date - 1 where property_id = 'e1200002-0000-4000-8000-0000000000b0' and uid = 'zz-s120r-today';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200002-0000-4000-8000-000000000001"}';
insert into _r select 'c3', public.restock_context_v1('e1200002-0000-4000-8000-0000000000b0');
reset role;
select is((select v ->> 'next_tier' from _r where k = 'c3'), null, 'once today''s arrival is in the house the next guest is a first stay: null');

-- 17-23. upkeep due: 2 turnovers after the last change = not due, 3 = due, a No never resets, a Yes resets one kind --------------------------
select is((select v #>> '{upkeep_due,dish_soap}' from _r where k = 'c3'), 'false', 'dish soap is not due after two turnovers (the 3rd report); a mid-stay and an older turnover do not count');
select is((select v #>> '{upkeep_due,dish_sponge}' from _r where k = 'c3'), 'false', 'the dish sponge is not due either');
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type) values ('e1200002-0000-4000-8000-0000000000b0', 'zz-s120r-s7', 'Fixture', now() - interval '7 days', 'turnover');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200002-0000-4000-8000-000000000001"}';
insert into _r select 'c4', public.restock_context_v1('e1200002-0000-4000-8000-0000000000b0');
insert into _r select 'no1', public.record_restock_v1('e1200002-0000-4000-8000-0000000000b0', current_date, 'Zz Cleaner', null, '[]', '{}', '[{"kind":"dish_soap","changed":false,"check_key":"zz-s120r-no-soap-1"}]');
insert into _r select 'c5', public.restock_context_v1('e1200002-0000-4000-8000-0000000000b0');
insert into _r select 'yes1', public.record_restock_v1('e1200002-0000-4000-8000-0000000000b0', current_date, 'Zz Cleaner', null, null, null, '[{"kind":"dish_soap","changed":true,"check_key":"zz-s120r-yes-soap-1"}]');
insert into _r select 'c6', public.restock_context_v1('e1200002-0000-4000-8000-0000000000b0');
reset role;
select is((select v #>> '{upkeep_due,dish_soap}' from _r where k = 'c4'), 'true', 'dish soap is due after the third turnover (the 4th report)');
select is((select v #>> '{upkeep_due,dish_sponge}' from _r where k = 'c4'), 'true', 'the dish sponge is due too');
select is((select v #>> '{upkeep_due,dish_soap}' from _r where k = 'c5'), 'true', 'a No does not reset the question');
select is((select v #>> '{upkeep_due,dish_soap}' from _r where k = 'c6') || ',' || (select v #>> '{upkeep_due,dish_sponge}' from _r where k = 'c6'), 'false,true', 'a Yes resets dish soap only; the sponge is still due');
insert into public.cleaning_sessions(property_id, submission_id, cleaner_name, cleaned_at, cleaning_type) values
  ('e1200002-0000-4000-8000-0000000000b0', 'zz-s120r-n1', 'Fixture', now() + interval '1 hour', 'turnover'),
  ('e1200002-0000-4000-8000-0000000000b0', 'zz-s120r-n2', 'Fixture', now() + interval '2 hours', 'deep_clean'),
  ('e1200002-0000-4000-8000-0000000000b0', 'zz-s120r-n3', 'Fixture', now() + interval '3 hours', 'turnover');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200002-0000-4000-8000-000000000001"}';
insert into _r select 'c7', public.restock_context_v1('e1200002-0000-4000-8000-0000000000b0');
reset role;
select is((select v #>> '{upkeep_due,dish_soap}' from _r where k = 'c7'), 'true', 'three turnovers after the Yes make dish soap due again');

-- 24-30. short stock writes nothing: a main row plus a treat row are added up --------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200002-0000-4000-8000-000000000001"}';
insert into _r select 's1', public.record_restock_v1('e1200002-0000-4000-8000-0000000000b0', current_date, 'Zz Cleaner', null,
  '[{"item_id":"e1200002-0000-4000-8000-0000000000a1","used_qty":6,"usage_key":"zz-s120r-k1"},{"item_id":"e1200002-0000-4000-8000-0000000000a1","used_qty":5,"usage_key":"zz-s120r-k2"}]',
  '{"e1200002-0000-4000-8000-0000000000a1": 3}', '[{"kind":"dish_sponge","changed":true,"check_key":"zz-s120r-short-sponge"}]');
insert into _r select 's2', public.record_restock_v1('e1200002-0000-4000-8000-0000000000b0', current_date, 'Zz Cleaner', null,
  '[{"item_id":"e1200002-0000-4000-8000-0000000000a1","used_qty":2,"usage_key":"zz-s120r-k3"},{"item_id":"e1200002-0000-4000-8000-0000000000a2","used_qty":9,"usage_key":"zz-s120r-k4"},{"item_id":"e1200002-0000-4000-8000-0000000000a3","used_qty":1,"usage_key":"zz-s120r-k5"}]', '{}', '[]');
reset role;
select is((select v ->> 'error' from _r where k = 's1'), 'short_stock', 'a main row (6) plus a treat row (5) on a shelf of 10 is refused as short_stock');
select is((select v -> 'short' from _r where k = 's1'), jsonb_build_array(jsonb_build_object('item_id', 'e1200002-0000-4000-8000-0000000000a1', 'name', 'Zz S120R A', 'on_hand', 10, 'asked', 11)), 'the refusal names the item, the shelf (10) and the sum asked (11)');
select is((select qty_on_hand from public.inventory_items where id = 'e1200002-0000-4000-8000-0000000000a1'), 10::numeric, 'the shelf is unchanged after the refusal');
select is((select (select count(*) from public.inventory_usage where item_id = 'e1200002-0000-4000-8000-0000000000a1') + (select count(*) from public.restock_remembered_amounts where item_id = 'e1200002-0000-4000-8000-0000000000a1')
          + (select count(*) from public.restock_upkeep_checks where check_key = 'zz-s120r-short-sponge'), 0::bigint, 'the refusal wrote no usage row, no remembered amount and no upkeep answer');
select is((select jsonb_agg(x ->> 'name' order by x ->> 'name') from jsonb_array_elements((select v -> 'short' from _r where k = 's2')) x), '["Zz S120R B", "Zz S120R Zero"]'::jsonb, 'only the items that are short are listed: B (9 of 5) and the empty one (1 of 0)');
select is((select qty_on_hand from public.inventory_items where id = 'e1200002-0000-4000-8000-0000000000a1'), 10::numeric, 'an item that was not short is untouched when another is');

-- 31-37. a good save, then a full replay changes nothing ---------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200002-0000-4000-8000-000000000001"}';
insert into _r select 'g1', public.record_restock_v1('e1200002-0000-4000-8000-0000000000b0', current_date, 'Zz Cleaner', 'zz note',
  '[{"item_id":"e1200002-0000-4000-8000-0000000000a1","used_qty":3,"usage_key":"zz-s120r-m1"},{"item_id":"e1200002-0000-4000-8000-0000000000a1","used_qty":2,"usage_key":"zz-s120r-m2"}]',
  '{"e1200002-0000-4000-8000-0000000000a1": 4, "e1200002-0000-4000-8000-0000000000a2": 7}', '[{"kind":"dish_sponge","changed":false,"check_key":"zz-s120r-good-sponge"}]');
reset role;
update public.restock_remembered_amounts set updated_at = now() - interval '1 day' where item_id = 'e1200002-0000-4000-8000-0000000000a1';
create temp table _snap as select (select count(*) from public.inventory_usage where item_id = 'e1200002-0000-4000-8000-0000000000a1') u,
  (select max(updated_at) from public.restock_remembered_amounts where item_id = 'e1200002-0000-4000-8000-0000000000a1') t;
select is((select v::text from _r where k = 'g1'), '{"ok": true, "rows": 2, "replayed": 0}', 'the save reports two rows written and none replayed');
select is((select qty_on_hand from public.inventory_items where id = 'e1200002-0000-4000-8000-0000000000a1'), 5::numeric, 'the shelf went 10 - 3 - 2 = 5');
select is((select count(*) from public.inventory_usage where item_id = 'e1200002-0000-4000-8000-0000000000a1'), 2::bigint, 'two usage rows were written');
select is((select amount from public.restock_remembered_amounts where item_id = 'e1200002-0000-4000-8000-0000000000a1') * 10 + (select amount from public.restock_remembered_amounts where item_id = 'e1200002-0000-4000-8000-0000000000a2'), 47, 'the remembered amounts are 4 and 7');
select is((select count(*) from public.restock_upkeep_checks where check_key = 'zz-s120r-good-sponge' and not changed and kind = 'dish_sponge'), 1::bigint, 'the upkeep answer was stored');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200002-0000-4000-8000-000000000001"}';
insert into _r select 'g2', public.record_restock_v1('e1200002-0000-4000-8000-0000000000b0', current_date, 'Zz Cleaner', 'zz note',
  '[{"item_id":"e1200002-0000-4000-8000-0000000000a1","used_qty":3,"usage_key":"zz-s120r-m1"},{"item_id":"e1200002-0000-4000-8000-0000000000a1","used_qty":2,"usage_key":"zz-s120r-m2"}]',
  '{"e1200002-0000-4000-8000-0000000000a1": 4, "e1200002-0000-4000-8000-0000000000a2": 7}', '[{"kind":"dish_sponge","changed":false,"check_key":"zz-s120r-good-sponge"}]');
reset role;
select is((select v::text from _r where k = 'g2'), '{"ok": true, "rows": 0, "replayed": 2}', 'a full replay is ok, writes no row and reports two replayed');
select is((select qty_on_hand from public.inventory_items where id = 'e1200002-0000-4000-8000-0000000000a1')::text || ',' || (select count(*) from public.inventory_usage where item_id = 'e1200002-0000-4000-8000-0000000000a1')::text
          || ',' || (select count(*) from public.restock_upkeep_checks where check_key = 'zz-s120r-good-sponge')::text
          || ',' || ((select max(updated_at) from public.restock_remembered_amounts where item_id = 'e1200002-0000-4000-8000-0000000000a1') = (select t from _snap))::text, '5,2,1,true', 'the replay left the shelf, the usage rows, the upkeep answer and the remembered stamp as they were');

-- 38-45. remembered amounts: bounds and ownership ------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200002-0000-4000-8000-000000000001"}';
select throws_ok($$select public.record_restock_v1('e1200002-0000-4000-8000-0000000000b0', current_date, 'x', null, '[]', '{"e1200002-0000-4000-8000-0000000000a1": 100}', '[]')$$, '22023', null, '100 is refused');
select throws_ok($$select public.record_restock_v1('e1200002-0000-4000-8000-0000000000b0', current_date, 'x', null, '[]', '{"e1200002-0000-4000-8000-0000000000a1": -1}', '[]')$$, '22023', null, '-1 is refused');
select throws_ok($$select public.record_restock_v1('e1200002-0000-4000-8000-0000000000b0', current_date, 'x', null, '[]', '{"e1200002-0000-4000-8000-0000000000a1": 2.5}', '[]')$$, '22023', null, 'a fraction is refused');
select throws_ok($$select public.record_restock_v1('e1200002-0000-4000-8000-0000000000b0', current_date, 'x', null, '[]', '{"e1200002-0000-4000-8000-0000000000a4": 3}', '[]')$$, '22023', null, 'an inactive item is refused');
select throws_ok($$select public.record_restock_v1('e1200002-0000-4000-8000-0000000000b0', current_date, 'x', null, '[]', '{"e1200002-0000-4000-8000-0000000000a6": 3}', '[]')$$, '22023', null, 'an item of another property is refused');
select throws_ok($$select public.record_restock_v1('e1200002-0000-4000-8000-0000000000b0', current_date, 'x', null, '[{"item_id":"e1200002-0000-4000-8000-0000000000a6","used_qty":1}]', '{}', '[]')$$, '22023', null, 'a usage row for an item of another property is refused');
select lives_ok($$select public.record_restock_v1('e1200002-0000-4000-8000-0000000000b0', current_date, 'x', null, '[]', '{"e1200002-0000-4000-8000-0000000000a1": 99, "e1200002-0000-4000-8000-0000000000a2": 0}', '[]')$$, '0 and 99 are accepted');
insert into _r select 'c8', public.restock_context_v1('e1200002-0000-4000-8000-0000000000b0');
reset role;
select is((select v -> 'remembered' from _r where k = 'c8'), jsonb_build_object('e1200002-0000-4000-8000-0000000000a1', 99, 'e1200002-0000-4000-8000-0000000000a2', 0), 'the context returns the new remembered amounts and still hides the inactive item''s');

-- 46-54. the admin reminder -------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200002-0000-4000-8000-000000000002"}';
select throws_ok($$select public.restock_remind_admin_v1('e1200002-0000-4000-8000-0000000000b0', 'e1200002-0000-4000-8000-0000000000a3')$$, '42501', null, 'a user with no staff profile cannot ask for a reminder');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200002-0000-4000-8000-000000000001"}';
insert into _r select 'r1', public.restock_remind_admin_v1('e1200002-0000-4000-8000-0000000000b0', 'e1200002-0000-4000-8000-0000000000a3');
insert into _r select 'r2', public.restock_remind_admin_v1('e1200002-0000-4000-8000-0000000000b0', 'e1200002-0000-4000-8000-0000000000a3');
insert into _r select 'r3', public.restock_remind_admin_v1('e1200002-0000-4000-8000-0000000000b0', 'e1200002-0000-4000-8000-0000000000a2');
select throws_ok($$select public.restock_remind_admin_v1('e1200002-0000-4000-8000-0000000000b0', 'e1200002-0000-4000-8000-0000000000a4')$$, '22023', null, 'an inactive item cannot be reminded');
select throws_ok($$select public.restock_remind_admin_v1('e1200002-0000-4000-8000-0000000000b0', 'e1200002-0000-4000-8000-0000000000a5')$$, '22023', null, 'a non-consumable item cannot be reminded');
select throws_ok($$select public.restock_remind_admin_v1('e1200002-0000-4000-8000-0000000000b0', 'e1200002-0000-4000-8000-0000000000a6')$$, '22023', null, 'an item of another property cannot be reminded');
reset role;
select is((select v::text from _r where k = 'r1') || (select v::text from _r where k = 'r2'), '{"ok": true}{"ok": true}', 'the first reminder and a repeat both return ok');
select is((select count(*) from public.follow_up_tasks where property_id = 'e1200002-0000-4000-8000-0000000000b0' and source_kind = 'restock_reminder'
            and source_ref = 'e1200002-0000-4000-8000-0000000000a3:' || public.manila_today()::text), 1::bigint, 'one task for the empty item for the Manila day, however often it is asked');
select is((select title || '|' || detail || '|' || priority || '|' || status from public.follow_up_tasks where source_kind = 'restock_reminder' and source_ref like 'e1200002-0000-4000-8000-0000000000a3:%'),
  'Restock: Zz S120R Zero is running out|Only 0 left in inventory. A cleaner asked for a reminder.|high|open', 'title, detail, high priority at zero and open status are as the approved copy says');
select is((select priority || '|' || detail || '|' || coalesce(created_by::text, 'no-actor') from public.follow_up_tasks where source_kind = 'restock_reminder' and source_ref like 'e1200002-0000-4000-8000-0000000000a2:%'),
  'normal|Only 5 left in inventory. A cleaner asked for a reminder.|no-actor', 'a shelf of 5 is normal priority and the task carries no cleaner');

-- 55. a service_role call has no signed-in user and is refused ----------------------------------------------------------------------------------
set local role service_role;
set local request.jwt.claims = '{}';
select throws_ok($$select public.restock_context_v1('e1200002-0000-4000-8000-0000000000b0')$$, '42501', null, 'service_role without a user is refused');
reset role;

select * from finish();
rollback;
