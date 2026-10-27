-- Session 99f (lane SQL): release s99f_count_as_of_20261103. inventory_qty_at_v1 and telegram_apply_inventory_count_v2 (count taken AS OF a past time), v1 as a wrapper.
-- Hand-computed expectations. T = now() - 2 days. "after T" rows are stamped T + 1 day, "before T" rows T - 1 day (explicit created_at).
--   A  now 10, usage 3 after T                                  qty_at 13   count 20 -> 20 + (10 - 13) = 17
--   B  now 8,  purchase 6 after T (admin receipt), usage 5 BEFORE T ignored   qty_at 2    count 5  -> 5 + 6 = 11
--   C  now 1,  usage 5 after T                                  qty_at 6    count 0  -> 0 + (1 - 6) = -5 -> clamped 0
--   D  now 14, OCR restock after T: purchase row (qty 2 packs) + audit qty_added 12; a second OCR audit row whose purchase is gone (qty_added 100) is ignored
--                                                               qty_at 2    count 3  -> 3 + 12 = 15
--   E  now 8,  an earlier count after T: audit telegram_count 5 -> 8 (+3)        qty_at 5    count 10 -> 10 + 3 = 13
--   N1 now 10, counted through v1 (wrapper) -> 9;  N2 now 10, v2 with a null time -> 9, since_delta 0
--   K  movement-controlled: refused by v1 and v2
begin;
select plan(44);

select has_function('public', 'inventory_qty_at_v1', array['uuid', 'timestamp with time zone'], 'qty_at exists');
select has_function('public', 'telegram_apply_inventory_count_v2', array['bigint', 'jsonb', 'text', 'timestamp with time zone'], 'the as-of count RPC exists');
select ok(has_function_privilege('service_role', 'public.telegram_apply_inventory_count_v2(bigint,jsonb,text,timestamptz)', 'execute'), 'v2: service_role may call it');
select ok(not has_function_privilege('authenticated', 'public.telegram_apply_inventory_count_v2(bigint,jsonb,text,timestamptz)', 'execute'), 'v2: a signed-in session may not call it');
select ok(not has_function_privilege('anon', 'public.telegram_apply_inventory_count_v2(bigint,jsonb,text,timestamptz)', 'execute'), 'v2: anon may not call it');
select ok(has_function_privilege('service_role', 'public.inventory_qty_at_v1(uuid,timestamptz)', 'execute')
      and not has_function_privilege('authenticated', 'public.inventory_qty_at_v1(uuid,timestamptz)', 'execute')
      and not has_function_privilege('anon', 'public.inventory_qty_at_v1(uuid,timestamptz)', 'execute'), 'qty_at: service_role only');
select ok(has_function_privilege('service_role', 'public.telegram_apply_inventory_count_v1(bigint,jsonb,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.telegram_apply_inventory_count_v1(bigint,jsonb,text)', 'execute')
      and not has_function_privilege('anon', 'public.telegram_apply_inventory_count_v1(bigint,jsonb,text)', 'execute'), 'v1 wrapper: grants unchanged (service_role only)');
select ok((select bool_and(p.prosecdef and p.proconfig = array['search_path=""']) from pg_proc p
            where p.oid in ('public.telegram_apply_inventory_count_v2(bigint,jsonb,text,timestamptz)'::regprocedure,
                            'public.inventory_qty_at_v1(uuid,timestamptz)'::regprocedure,
                            'public.telegram_apply_inventory_count_v1(bigint,jsonb,text)'::regprocedure)), 'all three: definer with an empty search_path');

insert into public.properties(id, name, is_active) values ('f99f0000-0000-4000-8000-0000000000f1', 'Synthetic s99f count', true);
insert into auth.users(id) values ('f99f0000-0000-4000-8000-0000000000a1'), ('f99f0000-0000-4000-8000-0000000000a2');
insert into public.staff_access_profiles(user_id, role, telegram_user_id) values
  ('f99f0000-0000-4000-8000-0000000000a1', 'admin', 9900000001),
  ('f99f0000-0000-4000-8000-0000000000a2', 'cleaner', 9900000002);
insert into public.staff_property_access(user_id, property_id) values
  ('f99f0000-0000-4000-8000-0000000000a1', 'f99f0000-0000-4000-8000-0000000000f1'),
  ('f99f0000-0000-4000-8000-0000000000a2', 'f99f0000-0000-4000-8000-0000000000f1');

insert into public.inventory_items(id, name, category, unit, qty_on_hand, is_consumable, is_active, sort_order, property_id, movement_controlled_at) values
  ('f99f0000-0000-4000-8000-0000000000b1', 'Zz s99f A', 'Consumables', 'pc', 10, true, true, 9901, 'f99f0000-0000-4000-8000-0000000000f1', null),
  ('f99f0000-0000-4000-8000-0000000000b2', 'Zz s99f B', 'Consumables', 'pc', 8,  true, true, 9902, 'f99f0000-0000-4000-8000-0000000000f1', null),
  ('f99f0000-0000-4000-8000-0000000000b3', 'Zz s99f C', 'Consumables', 'pc', 1,  true, true, 9903, 'f99f0000-0000-4000-8000-0000000000f1', null),
  ('f99f0000-0000-4000-8000-0000000000b4', 'Zz s99f D', 'Consumables', 'pc', 14, true, true, 9904, 'f99f0000-0000-4000-8000-0000000000f1', null),
  ('f99f0000-0000-4000-8000-0000000000b5', 'Zz s99f E', 'Consumables', 'pc', 8,  true, true, 9905, 'f99f0000-0000-4000-8000-0000000000f1', null),
  ('f99f0000-0000-4000-8000-0000000000b6', 'Zz s99f N1', 'Consumables', 'pc', 10, true, true, 9906, 'f99f0000-0000-4000-8000-0000000000f1', null),
  ('f99f0000-0000-4000-8000-0000000000b7', 'Zz s99f N2', 'Consumables', 'pc', 10, true, true, 9907, 'f99f0000-0000-4000-8000-0000000000f1', null),
  ('f99f0000-0000-4000-8000-0000000000b8', 'Zz s99f K', 'Consumables', 'pc', 7,  true, true, 9908, 'f99f0000-0000-4000-8000-0000000000f1', now());

insert into public.inventory_usage(property_id, item_id, used_qty, session_date, created_at) values
  ('f99f0000-0000-4000-8000-0000000000f1', 'f99f0000-0000-4000-8000-0000000000b1', 3, public.manila_today() - 1, now() - interval '1 day'),
  ('f99f0000-0000-4000-8000-0000000000f1', 'f99f0000-0000-4000-8000-0000000000b2', 5, public.manila_today() - 3, now() - interval '3 days'),
  ('f99f0000-0000-4000-8000-0000000000f1', 'f99f0000-0000-4000-8000-0000000000b3', 5, public.manila_today() - 1, now() - interval '1 day');
insert into public.inventory_purchases(item_id, qty, notes, created_at) values
  ('f99f0000-0000-4000-8000-0000000000b2', 6, 'Admin receipt [key:zz-s99f-b]', now() - interval '1 day');
insert into public.inventory_purchases(id, item_id, qty, notes, created_at) values
  ('f99f0000-0000-4000-8000-0000000000c1', 'f99f0000-0000-4000-8000-0000000000b4', 2, 'Auto-restock from receipt OCR (txn zz)', now() - interval '1 day');
insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor, created_at) values
  ('inventory_items', 'f99f0000-0000-4000-8000-0000000000b4', 'ocr_restock', '{"qty_on_hand": 2}'::jsonb,
   '{"qty_on_hand": 14, "purchase_id": "f99f0000-0000-4000-8000-0000000000c1", "qty_added": 12}'::jsonb, 'telegram-ocr', now() - interval '1 day'),
  ('inventory_items', 'f99f0000-0000-4000-8000-0000000000b4', 'ocr_restock', '{"qty_on_hand": 2}'::jsonb,
   '{"qty_on_hand": 102, "purchase_id": "f99f0000-0000-4000-8000-0000000000c2", "qty_added": 100}'::jsonb, 'telegram-ocr', now() - interval '1 day'),
  ('inventory_items', 'f99f0000-0000-4000-8000-0000000000b5', 'telegram_count', '{"qty_on_hand": 5}'::jsonb, '{"qty_on_hand": 8}'::jsonb, 'telegram:1:admin', now() - interval '1 day');

-- the internal core: nobody may call it (the migration's own revokes run even under --no-acl)
select has_function('public', 's_apply_inventory_count_core_v1', array['text', 'jsonb', 'text', 'timestamp with time zone', 'uuid'], 'the internal core exists');
select ok(not has_function_privilege('anon', 'public.s_apply_inventory_count_core_v1(text,jsonb,text,timestamptz,uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.s_apply_inventory_count_core_v1(text,jsonb,text,timestamptz,uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.s_apply_inventory_count_core_v1(text,jsonb,text,timestamptz,uuid)', 'execute'), 'core: not executable by anon, authenticated or service_role');
select ok((select p.prosecdef and p.proconfig = array['search_path=""'] and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)
             from pg_proc p where p.oid = 'public.s_apply_inventory_count_core_v1(text,jsonb,text,timestamptz,uuid)'::regprocedure), 'core: definer, empty search_path, nothing granted to PUBLIC');

-- qty_at, hand-computed
select is(public.inventory_qty_at_v1('f99f0000-0000-4000-8000-0000000000b1', now() - interval '2 days'), 13::numeric, 'qty_at A: 10 now + 3 used after T = 13');
select is(public.inventory_qty_at_v1('f99f0000-0000-4000-8000-0000000000b2', now() - interval '2 days'), 2::numeric, 'qty_at B: 8 now - 6 bought after T = 2 (usage before T ignored)');
select is(public.inventory_qty_at_v1('f99f0000-0000-4000-8000-0000000000b4', now() - interval '2 days'), 2::numeric, 'qty_at D: 14 now - 12 OCR units = 2 (the OCR audit row whose purchase is gone is ignored)');
select is(public.inventory_qty_at_v1('f99f0000-0000-4000-8000-0000000000b5', now() - interval '2 days'), 5::numeric, 'qty_at E: 8 now - 3 from an earlier count = 5');
select is(public.inventory_qty_at_v1('f99f0000-0000-4000-8000-0000000000b1', null), 10::numeric, 'qty_at with a null time is qty_now');
select is(public.inventory_qty_at_v1('f99f0000-0000-4000-8000-0000000000b1', now() - interval '30 minutes'), 10::numeric, 'qty_at after the last change is qty_now');
select is(public.inventory_qty_at_v1('f99f0000-0000-4000-8000-0000000000ff', now() - interval '2 days'), null::numeric, 'qty_at of an unknown item is null');

-- refusals
select is(public.telegram_apply_inventory_count_v2(9900000009, '[{"item_id":"f99f0000-0000-4000-8000-0000000000b1","counted":9,"expected_before":10}]'::jsonb, 'x', now() - interval '2 days') ->> 'reason',
  'unmapped_telegram_user', 'v2: an unmapped Telegram id is refused');
select is(public.telegram_apply_inventory_count_v2(9900000002, '[{"item_id":"f99f0000-0000-4000-8000-0000000000b1","counted":9,"expected_before":10}]'::jsonb, 'x', now() - interval '2 days') ->> 'reason',
  'not_authorized', 'v2: a mapped cleaner cannot apply a count');
select is(public.telegram_apply_inventory_count_v2(9900000001, '[{"item_id":"f99f0000-0000-4000-8000-0000000000b1","counted":9,"expected_before":10}]'::jsonb, 'x', now() + interval '1 hour') ->> 'reason',
  'bad_as_of', 'v2: a time in the future is bad_as_of');
select is(public.telegram_apply_inventory_count_v2(9900000001, '[{"item_id":"f99f0000-0000-4000-8000-0000000000b1","counted":9,"expected_before":10}]'::jsonb, 'x', now() - interval '61 days') ->> 'reason',
  'bad_as_of', 'v2: a time older than 60 days is bad_as_of');
select is(public.telegram_apply_inventory_count_v2(9900000001, '[{"item_id":"f99f0000-0000-4000-8000-0000000000b8","counted":6,"expected_before":7}]'::jsonb, 'x', now() - interval '2 days') ->> 'reason',
  'movement_controlled', 'v2: a movement-controlled item is refused');
select is(public.telegram_apply_inventory_count_v2(9900000001, '[{"item_id":"f99f0000-0000-4000-8000-0000000000b1","counted":1,"expected_before":10},{"item_id":"f99f0000-0000-4000-8000-0000000000b1","counted":2,"expected_before":10}]'::jsonb, 'x', now() - interval '2 days') ->> 'reason',
  'duplicate_item', 'v2: the same item twice is refused');
select is(public.telegram_apply_inventory_count_v2(9900000001, '[{"item_id":"f99f0000-0000-4000-8000-0000000000b1","counted":-1,"expected_before":10}]'::jsonb, 'x', now() - interval '2 days') ->> 'reason',
  'bad_count', 'v2: a negative count is refused');
select is(public.telegram_apply_inventory_count_v2(9900000001,
  '[{"item_id":"f99f0000-0000-4000-8000-0000000000b1","counted":20,"expected_before":10},{"item_id":"f99f0000-0000-4000-8000-0000000000b2","counted":5,"expected_before":99}]'::jsonb, 'x', now() - interval '2 days') ->> 'reason',
  'stock_changed', 'v2: a stale expected_before aborts the whole as-of count');
select is((select qty_on_hand from public.inventory_items where id = 'f99f0000-0000-4000-8000-0000000000b1'), 10::numeric, 'the good row in a refused as-of count was NOT applied');

-- v1 wrapper behaves as before (null time = counted as given)
select is(public.telegram_apply_inventory_count_v1(9900000001, '[{"item_id":"f99f0000-0000-4000-8000-0000000000b6","counted":9,"expected_before":10}]'::jsonb, 'pgTAP v1') ->> 'updated', '1', 'v1 wrapper: applies one row');
select is((select qty_on_hand from public.inventory_items where id = 'f99f0000-0000-4000-8000-0000000000b6'), 9::numeric, 'v1 wrapper: the counted figure is stored as given');
select is(public.telegram_apply_inventory_count_v1(9900000001, '[{"item_id":"f99f0000-0000-4000-8000-0000000000b8","counted":6,"expected_before":7}]'::jsonb) ->> 'reason', 'movement_controlled', 'v1 wrapper: a controlled item is still refused');

-- v2 with a null time equals v1
select is((public.telegram_apply_inventory_count_v2(9900000001, '[{"item_id":"f99f0000-0000-4000-8000-0000000000b7","counted":9,"expected_before":10}]'::jsonb, 'pgTAP v2 null') #>> '{rows,0,since_delta}')::numeric, 0::numeric, 'v2 with no time: since_delta is 0');
select is((select qty_on_hand from public.inventory_items where id = 'f99f0000-0000-4000-8000-0000000000b7'), 9::numeric, 'v2 with no time: stored as counted, exactly like v1');

-- the as-of count: five rows, hand-computed results
create temp table _r on commit drop as
select public.telegram_apply_inventory_count_v2(9900000001,
  '[{"item_id":"f99f0000-0000-4000-8000-0000000000b1","counted":20,"expected_before":10},
    {"item_id":"f99f0000-0000-4000-8000-0000000000b2","counted":5,"expected_before":8},
    {"item_id":"f99f0000-0000-4000-8000-0000000000b3","counted":0,"expected_before":1},
    {"item_id":"f99f0000-0000-4000-8000-0000000000b4","counted":3,"expected_before":14},
    {"item_id":"f99f0000-0000-4000-8000-0000000000b5","counted":10,"expected_before":8}]'::jsonb,
  'pgTAP as of', now() - interval '2 days') as j;
select is((select j ->> 'updated' from _r), '5', 'as-of count: five rows applied');
select is((select qty_on_hand from public.inventory_items where id = 'f99f0000-0000-4000-8000-0000000000b1'), 17::numeric, 'A: 20 + (10 - 13) = 17');
select is((select qty_on_hand from public.inventory_items where id = 'f99f0000-0000-4000-8000-0000000000b2'), 11::numeric, 'B: 5 + 6 = 11');
select is((select qty_on_hand from public.inventory_items where id = 'f99f0000-0000-4000-8000-0000000000b3'), 0::numeric, 'C: 0 + (1 - 6) = -5 is clamped at 0');
select is((select qty_on_hand from public.inventory_items where id = 'f99f0000-0000-4000-8000-0000000000b4'), 15::numeric, 'D: 3 + 12 = 15');
select is((select qty_on_hand from public.inventory_items where id = 'f99f0000-0000-4000-8000-0000000000b5'), 13::numeric, 'E: 10 + 3 = 13');
select ok((select (j #>> '{rows,2,clamped}')::boolean and (j #>> '{rows,2,since_delta}')::numeric = -5 and (j #>> '{rows,2,counted}')::numeric = 0 and not (j #>> '{rows,0,clamped}')::boolean from _r),
  'the result reports counted, since_delta and clamped per row');
select ok((select a.after ->> 'note' = 'pgTAP as of' and (a.after ->> 'counted')::numeric = 20 and (a.after ->> 'since_delta')::numeric = -3
                   and (a.after ->> 'as_of')::timestamptz between now() - interval '2 days 1 minute' and now() - interval '1 day 23 hours'
                   and (a.before ->> 'qty_on_hand')::numeric = 10 and (a.after ->> 'qty_on_hand')::numeric = 17
             from public.inventory_audit_log a where a.entity_id = 'f99f0000-0000-4000-8000-0000000000b1' and a.action = 'telegram_count' and a.after ? 'as_of'),
  'the audit row carries note, as_of, counted and since_delta');

-- the Telegram path still writes the 'telegram:<id>:<role>' actor (A: the as-of count above); the core run directly (owner data step) writes its own actor
select is((select a.actor from public.inventory_audit_log a where a.entity_id = 'f99f0000-0000-4000-8000-0000000000b1' and a.action = 'telegram_count' and a.after ? 'as_of'),
  'telegram:9900000001:admin', 'v2 path: the audit actor is telegram:<id>:<role>');
select is((select j ->> 'by_role' from _r), 'admin', 'v2 path: the result still carries by_role');
select is(public.s_apply_inventory_count_core_v1('owner:test:s99f-data-step',
  '[{"item_id":"f99f0000-0000-4000-8000-0000000000b6","counted":4,"expected_before":9}]'::jsonb, 'pgTAP core', now() - interval '2 days') ->> 'updated', '1', 'core: a direct call applies a row with no Telegram id');
select is((select a.actor from public.inventory_audit_log a where a.entity_id = 'f99f0000-0000-4000-8000-0000000000b6' and a.after ->> 'note' = 'pgTAP core'),
  'owner:test:s99f-data-step', 'core: the audit actor is the one passed in');

select * from finish();
rollback;
