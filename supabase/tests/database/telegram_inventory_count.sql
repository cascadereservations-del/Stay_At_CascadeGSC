-- SPEC-03: the Telegram count RPC. Authorisation is at the Apply tap, so most of this is about who is
-- refused and about a count that must not half-apply.
begin;
select plan(18);

select has_function('public','telegram_apply_inventory_count_v1',array['bigint','jsonb','text'],'the count RPC exists');
select ok(has_function_privilege('service_role','public.telegram_apply_inventory_count_v1(bigint,jsonb,text)','execute'), 'service_role may call it');
select ok(not has_function_privilege('authenticated','public.telegram_apply_inventory_count_v1(bigint,jsonb,text)','execute'), 'a signed-in staff session may not call it directly');
select ok(not has_function_privilege('anon','public.telegram_apply_inventory_count_v1(bigint,jsonb,text)','execute'), 'anon may not call it');
select ok((select p.prosecdef and p.proconfig = array['search_path=""']
             from pg_proc p where p.oid = 'public.telegram_apply_inventory_count_v1(bigint,jsonb,text)'::regprocedure),
          'definer with an empty search_path');

-- Synthetic fixtures: an admin and a cleaner, each with a Telegram id, plus three items.
insert into auth.users(id) values
  ('f3300000-0000-4000-8000-0000000000a1'),('f3300000-0000-4000-8000-0000000000a2');
insert into public.staff_access_profiles(user_id,role,telegram_user_id) values
  ('f3300000-0000-4000-8000-0000000000a1','admin',9000000001),
  ('f3300000-0000-4000-8000-0000000000a2','cleaner',9000000002);
insert into public.staff_property_access(user_id,property_id) values
  ('f3300000-0000-4000-8000-0000000000a1','6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'),
  ('f3300000-0000-4000-8000-0000000000a2','6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');

insert into public.inventory_items(id,name,category,unit,qty_on_hand,is_consumable,is_active,sort_order,property_id,movement_controlled_at) values
  ('f3300000-0000-4000-8000-0000000000b1','Count Fixture A','Consumables','pc',10,true,true,9001,'6ae230f4-c189-4547-84b1-cb6e0b2cc9bd',null),
  ('f3300000-0000-4000-8000-0000000000b2','Count Fixture B','Consumables','pc',4,true,true,9002,'6ae230f4-c189-4547-84b1-cb6e0b2cc9bd',null),
  ('f3300000-0000-4000-8000-0000000000b3','Count Fixture Controlled','Consumables','pc',7,true,true,9003,'6ae230f4-c189-4547-84b1-cb6e0b2cc9bd',now());

-- An id nobody is mapped to, and a cleaner who is mapped but lacks manage_inventory.
select is((public.telegram_apply_inventory_count_v1(9000000003,
  '[{"item_id":"f3300000-0000-4000-8000-0000000000b1","counted":9,"expected_before":10}]'::jsonb)->>'reason'),
  'unmapped_telegram_user', 'an unmapped Telegram id is refused');
select is((public.telegram_apply_inventory_count_v1(9000000002,
  '[{"item_id":"f3300000-0000-4000-8000-0000000000b1","counted":9,"expected_before":10}]'::jsonb)->>'reason'),
  'not_authorized', 'a mapped cleaner cannot apply a count');

-- Shape and value rules.
select is((public.telegram_apply_inventory_count_v1(9000000001,'[]'::jsonb)->>'reason'),
  'bad_row_count', 'an empty count is refused');
select is((public.telegram_apply_inventory_count_v1(9000000001,
  '[{"item_id":"f3300000-0000-4000-8000-0000000000b1","counted":-1,"expected_before":10}]'::jsonb)->>'reason'),
  'bad_count', 'a negative count is refused');
select is((public.telegram_apply_inventory_count_v1(9000000001,
  '[{"item_id":"f3300000-0000-4000-8000-0000000000b1","counted":9.005,"expected_before":10}]'::jsonb)->>'reason'),
  'bad_count', 'more than two decimals is refused');
select is((public.telegram_apply_inventory_count_v1(9000000001,
  '[{"item_id":"f3300000-0000-4000-8000-0000000000b1","counted":9,"expected_before":10},
    {"item_id":"f3300000-0000-4000-8000-0000000000b1","counted":8,"expected_before":10}]'::jsonb)->>'reason'),
  'duplicate_item', 'the same item twice is refused');
select is((public.telegram_apply_inventory_count_v1(9000000001,
  '[{"item_id":"f3300000-0000-4000-8000-0000000000b3","counted":6,"expected_before":7}]'::jsonb)->>'reason'),
  'movement_controlled', 'a movement-controlled item is refused');

-- A stale list aborts the WHOLE count, not just the row that moved.
select is((public.telegram_apply_inventory_count_v1(9000000001,
  '[{"item_id":"f3300000-0000-4000-8000-0000000000b1","counted":9,"expected_before":10},
    {"item_id":"f3300000-0000-4000-8000-0000000000b2","counted":3,"expected_before":99}]'::jsonb)->>'reason'),
  'stock_changed', 'a changed expected_before is refused');
select is((select qty_on_hand from public.inventory_items where id='f3300000-0000-4000-8000-0000000000b1'), 10::numeric,
  'the good row in a refused count was NOT applied');

-- The happy path: an admin applies two rows.
select is((public.telegram_apply_inventory_count_v1(9000000001,
  '[{"item_id":"f3300000-0000-4000-8000-0000000000b1","counted":9,"expected_before":10},
    {"item_id":"f3300000-0000-4000-8000-0000000000b2","counted":0,"expected_before":4}]'::jsonb,
  'pgTAP count')->>'updated'), '2', 'an admin applies two rows');
select is((select qty_on_hand from public.inventory_items where id='f3300000-0000-4000-8000-0000000000b2'), 0::numeric,
  'a count of zero is applied, not treated as missing');
select is((select count(*) from public.inventory_audit_log
            where action='telegram_count' and entity_id in
              ('f3300000-0000-4000-8000-0000000000b1','f3300000-0000-4000-8000-0000000000b2')), 2::bigint,
  'every applied row is audited');
-- Compared as a number: jsonb keeps the column's numeric scale, so the text is '10.00', not '10'.
select is((select (before->>'qty_on_hand')::numeric from public.inventory_audit_log
            where action='telegram_count' and entity_id='f3300000-0000-4000-8000-0000000000b1'), 10::numeric,
  'the audit row records the figure that was replaced');

select * from finish();
rollback;
