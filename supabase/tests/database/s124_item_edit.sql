-- Session 124 (lane L1 SQL): release s124_item_edit_20261124. inventory_item_update_v1 (manager or cleaner), inventory_item_price_set_v1 (blind for a cleaner), inventory_item_photo_set_v1,
-- inventory_item_change_undo_v1, get_inventory_catalogue_v1 (updatedAt / updatedBy) and inventory_item_history_v1 (change rows), the closed table inventory_item_changes.
-- Synthetic fixtures only (uuids e1240010-..., property ...01, items "Zz S124 ...", users ...11 admin "Adam Zz", ...12 cleaner "Clea Zz", ...13 second cleaner, ...14 no staff profile);
-- every lookup is scoped to them because a real backup holds real rows. Refusals are tested by calling as the refused role.
-- created_at of a change row is moved by hand where the order or the age matters: every row written inside this one transaction would otherwise carry the same now().
-- Everything rolls back.
begin;
select plan(69);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid), public.current_staff_active(text[]) to authenticated, service_role;
grant execute on function public.admin_require(text, uuid) to authenticated;
grant execute on function public.manila_today() to authenticated, anon;

create temp table _r(k text primary key, v jsonb);
grant all on _r to authenticated, service_role;

-- fixtures -------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values ('e1240010-0000-4000-8000-000000000001', 'Synthetic S124', true);
insert into auth.users(id) values ('e1240010-0000-4000-8000-000000000011'), ('e1240010-0000-4000-8000-000000000012'), ('e1240010-0000-4000-8000-000000000013'), ('e1240010-0000-4000-8000-000000000014'), ('e1240010-0000-4000-8000-000000000015');
update auth.users set raw_app_meta_data = jsonb_build_object('display_name', 'Adam Zz') where id = 'e1240010-0000-4000-8000-000000000011';
update auth.users set raw_app_meta_data = jsonb_build_object('display_name', 'Clea Zz') where id = 'e1240010-0000-4000-8000-000000000012';
insert into public.staff_access_profiles(user_id, role) values ('e1240010-0000-4000-8000-000000000011', 'admin'), ('e1240010-0000-4000-8000-000000000012', 'cleaner'), ('e1240010-0000-4000-8000-000000000013', 'cleaner'), ('e1240010-0000-4000-8000-000000000015', 'maintenance');
insert into public.staff_property_access(user_id, property_id) values ('e1240010-0000-4000-8000-000000000011', 'e1240010-0000-4000-8000-000000000001'), ('e1240010-0000-4000-8000-000000000012', 'e1240010-0000-4000-8000-000000000001'),
  ('e1240010-0000-4000-8000-000000000013', 'e1240010-0000-4000-8000-000000000001'), ('e1240010-0000-4000-8000-000000000015', 'e1240010-0000-4000-8000-000000000001');
-- 101 details (every cleaner key), 102 name clash and category B, 103 inactive with category C, 104 price, 105 undo, 106 too late, 107 changed since, 108 name back, 109 photo, 110 limit 10, 111 admin edit, 112 price undo, 113 untouched
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, reorder_below, par_qty, location, unit_cost, purchase_unit, units_per_purchase) values
  ('e1240010-0000-4000-8000-000000000101', 'e1240010-0000-4000-8000-000000000001', 'Zz S124 Towel',  'Zz S124 Cat A', 'pc', 5, true,  true,  2, 10, 'Shelf', 7.50,  'box', 4),
  ('e1240010-0000-4000-8000-000000000102', 'e1240010-0000-4000-8000-000000000001', 'Zz S124 Rack',   'Zz S124 Cat B', 'pc', 5, false, true,  null, null, null, null, null, 1),
  ('e1240010-0000-4000-8000-000000000103', 'e1240010-0000-4000-8000-000000000001', 'Zz S124 Old',    'Zz S124 Cat C', 'pc', 5, false, false, null, null, null, null, null, 1),
  ('e1240010-0000-4000-8000-000000000104', 'e1240010-0000-4000-8000-000000000001', 'Zz S124 Price',  'Zz S124 Cat A', 'pc', 5, true,  true,  null, null, null, 12.34, null, 1),
  ('e1240010-0000-4000-8000-000000000105', 'e1240010-0000-4000-8000-000000000001', 'Zz S124 Undo',   'Zz S124 Cat A', 'pc', 5, true,  true,  2, null, null, null, null, 1),
  ('e1240010-0000-4000-8000-000000000106', 'e1240010-0000-4000-8000-000000000001', 'Zz S124 Late',   'Zz S124 Cat A', 'pc', 5, true,  true,  2, null, null, null, null, 1),
  ('e1240010-0000-4000-8000-000000000107', 'e1240010-0000-4000-8000-000000000001', 'Zz S124 Race',   'Zz S124 Cat A', 'pc', 5, true,  true,  2, null, null, null, null, 1),
  ('e1240010-0000-4000-8000-000000000108', 'e1240010-0000-4000-8000-000000000001', 'Zz S124 Alpha',  'Zz S124 Cat A', 'pc', 5, true,  true,  2, null, null, null, null, 1),
  ('e1240010-0000-4000-8000-000000000109', 'e1240010-0000-4000-8000-000000000001', 'Zz S124 Photo',  'Zz S124 Cat A', 'pc', 5, true,  true,  2, null, null, null, null, 1),
  ('e1240010-0000-4000-8000-000000000110', 'e1240010-0000-4000-8000-000000000001', 'Zz S124 Limit',  'Zz S124 Cat A', 'pc', 5, true,  true,  2, null, null, null, null, 1),
  ('e1240010-0000-4000-8000-000000000111', 'e1240010-0000-4000-8000-000000000001', 'Zz S124 Admin',  'Zz S124 Cat A', 'pc', 5, true,  true,  2, null, null, null, null, 1),
  ('e1240010-0000-4000-8000-000000000112', 'e1240010-0000-4000-8000-000000000001', 'Zz S124 Cost',   'Zz S124 Cat A', 'pc', 5, true,  true,  2, null, null, 20.00, null, 1),
  ('e1240010-0000-4000-8000-000000000113', 'e1240010-0000-4000-8000-000000000001', 'Zz S124 Plain',  'Zz S124 Cat A', 'pc', 5, true,  true,  2, null, null, null, null, 1);
insert into storage.buckets(id, name) values ('inventory-photos', 'inventory-photos') on conflict (id) do nothing;
insert into storage.objects(bucket_id, name) values
  ('inventory-photos', 'items/e1240010-0000-4000-8000-000000000109/e1240010-0000-4000-8000-000000000a01.webp'),
  ('inventory-photos', 'items/e1240010-0000-4000-8000-000000000109/e1240010-0000-4000-8000-000000000a02.webp');

-- 1-4. shape and grants ----------------------------------------------------------------------------------------------------------------
select ok(to_regclass('public.inventory_item_changes') is not null and (select relrowsecurity from pg_class where oid = 'public.inventory_item_changes'::regclass)
      and not has_table_privilege('anon', 'public.inventory_item_changes', 'select, insert, update, delete')
      and not has_table_privilege('authenticated', 'public.inventory_item_changes', 'select, insert, update, delete')
      and not has_table_privilege('service_role', 'public.inventory_item_changes', 'select, insert, update, delete'),
  'inventory_item_changes exists, row level security is on and no API role has a grant');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000011"}';
select throws_ok($$select count(*) from public.inventory_item_changes$$, '42501', null, 'a signed-in admin cannot read inventory_item_changes directly');
reset role;
select ok((select bool_and(has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute') and not has_function_privilege('service_role', f, 'execute'))
           from unnest(array['public.inventory_item_update_v1(uuid,jsonb)', 'public.inventory_item_price_set_v1(uuid,numeric)', 'public.inventory_item_photo_set_v1(uuid,text)',
                             'public.inventory_item_change_undo_v1(uuid)', 'public.get_inventory_catalogue_v1(uuid)', 'public.inventory_item_history_v1(uuid)']) f)
      and not has_function_privilege('authenticated', 'public.s_inventory_actor_name_v1(uuid)', 'execute') and not has_function_privilege('anon', 'public.s_inventory_actor_name_v1(uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.s_inventory_actor_name_v1(uuid)', 'execute'),
  'the six functions run for signed-in users only (not anon, not service_role) and the name helper has no grant');
select ok(exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'inventory_items' and column_name = 'updated_by' and data_type = 'uuid'),
  'inventory_items.updated_by is a uuid column');

-- 5-10. a cleaner edits every allowed key -------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'c_name', public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"name":"Zz S124 Towel 2"}');
insert into _r select 'c_cat',  public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"category":"zz s124 cat b"}');
insert into _r select 'c_unit', public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"unit":"roll"}');
insert into _r select 'c_rb',   public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"reorder_below":3.5}');
insert into _r select 'c_par',  public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"par_qty":12}');
insert into _r select 'c_loc',  public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"location":"Closet"}');
reset role;
select ok((select (v ->> 'ok')::boolean and v ->> 'change_id' is not null from _r where k = 'c_name') and (select name = 'Zz S124 Towel 2' from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000101'),
  'a cleaner renames an item and gets a change_id');
select ok((select (v ->> 'ok')::boolean and v ->> 'change_id' is not null from _r where k = 'c_cat') and (select category = 'Zz S124 Cat B' from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000101'),
  'a cleaner picks a category already in use (any letter case) and the stored spelling is the existing one');
select ok((select (v ->> 'ok')::boolean and v ->> 'change_id' is not null from _r where k = 'c_unit') and (select unit = 'roll' from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000101'),
  'a cleaner changes the unit');
select ok((select (v ->> 'ok')::boolean and v ->> 'change_id' is not null from _r where k = 'c_rb') and (select reorder_below = 3.5 from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000101'),
  'a cleaner changes the reorder level');
select ok((select (v ->> 'ok')::boolean and v ->> 'change_id' is not null from _r where k = 'c_par') and (select par_qty = 12 from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000101'),
  'a cleaner changes the buy-up-to level');
select ok((select (v ->> 'ok')::boolean and v ->> 'change_id' is not null from _r where k = 'c_loc') and (select location = 'Closet' from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000101'),
  'a cleaner changes the location');
-- 11. the audit rows and the stamp
select ok((select count(*) = 6 and bool_and(actor = 'e1240010-0000-4000-8000-000000000012' and kind = 'details') from public.inventory_item_changes where item_id = 'e1240010-0000-4000-8000-000000000101')
      and (select before = '{"name":"Zz S124 Towel"}'::jsonb and after = '{"name":"Zz S124 Towel 2"}'::jsonb from public.inventory_item_changes where id = (select (v ->> 'change_id')::uuid from _r where k = 'c_name'))
      and (select before = '{"reorder_below":2}'::jsonb and after = '{"reorder_below":3.5}'::jsonb from public.inventory_item_changes where id = (select (v ->> 'change_id')::uuid from _r where k = 'c_rb'))
      and (select updated_by = 'e1240010-0000-4000-8000-000000000012' and updated_at >= now() - interval '1 minute' from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000101'),
  'six change rows for the cleaner, each holding only its own key (before and after), and the item is stamped with updated_by and updated_at');

-- 12-15. a cleaner is refused the owner-only keys ---------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
select throws_ok($$select public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"active":false}')$$, '42501', null, 'a cleaner cannot change active');
select throws_ok($$select public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"consumable":false}')$$, '42501', null, 'a cleaner cannot change consumable');
select throws_ok($$select public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"purchase_unit":"case"}')$$, '42501', null, 'a cleaner cannot change purchase_unit');
select throws_ok($$select public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"units_per_purchase":6}')$$, '42501', null, 'a cleaner cannot change units_per_purchase');
-- 16-17. categories
select throws_ok($$select public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"category":"Zz S124 Brand New"}')$$, '22023', 'category must be one already in use', 'a cleaner cannot start a new category');
select throws_ok($$select public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"category":"Zz S124 Cat C"}')$$, '22023', 'category must be one already in use', 'a category that only an inactive item uses is not in use');
-- 18-19. nothing changed, name clash
insert into _r select 'c_same', public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"name":"  Zz S124 Towel 2 ","location":"Closet"}');
insert into _r select 'c_dupe', public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"name":"zz s124 rack"}');
reset role;
select ok((select (v ->> 'ok')::boolean and v -> 'change_id' = 'null'::jsonb from _r where k = 'c_same') and (select count(*) = 6 from public.inventory_item_changes where item_id = 'e1240010-0000-4000-8000-000000000101'),
  'a patch that changes nothing returns change_id null and writes no row');
select ok((select not (v ->> 'ok')::boolean and v ->> 'reason' = 'name_exists' and v ->> 'item_id' = 'e1240010-0000-4000-8000-000000000102' from _r where k = 'c_dupe')
      and (select name = 'Zz S124 Towel 2' from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000101'),
  'a name another active item has answers name_exists and changes nothing');
-- 20. an admin edits all ten keys
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000011"}';
insert into _r select 'a_all', public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000111', '{"name":"Zz S124 Admin 2","category":"Zz S124 New Cat","unit":"box","consumable":false,"active":false,"reorder_below":null,"par_qty":9,"purchase_unit":"case","units_per_purchase":6,"location":"Attic"}');
reset role;
select ok((select (v ->> 'ok')::boolean from _r where k = 'a_all')
      and (select i.name = 'Zz S124 Admin 2' and i.category = 'Zz S124 New Cat' and i.unit = 'box' and not i.is_consumable and not i.is_active and i.reorder_below is null and i.par_qty = 9 and i.purchase_unit = 'case'
                  and i.units_per_purchase = 6 and i.location = 'Attic' and i.updated_by = 'e1240010-0000-4000-8000-000000000011' from public.inventory_items i where i.id = 'e1240010-0000-4000-8000-000000000111')
      and (select (select count(*) from jsonb_object_keys(c.after)) = 10 and c.before -> 'reorder_below' = '2'::jsonb and c.after -> 'reorder_below' = 'null'::jsonb
                  and c.before ->> 'active' = 'true' and c.after ->> 'active' = 'false' from public.inventory_item_changes c where c.id = (select (v ->> 'change_id')::uuid from _r where k = 'a_all')),
  'an admin edits all ten keys, a new category is fine for an admin, and the change row holds the ten before and after values');
-- 21. no staff profile
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000014"}';
select throws_ok($$select public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"name":"Zz S124 Nope"}')$$, '42501', null, 'a user with no staff profile cannot edit an item');
reset role;

-- 22-31. price: a cleaner sets it blind --------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'p_c1', public.inventory_item_price_set_v1('e1240010-0000-4000-8000-000000000104', 33.33);
insert into _r select 'p_c2', public.inventory_item_price_set_v1('e1240010-0000-4000-8000-000000000104', 33.33);
select throws_ok($$select public.inventory_item_price_set_v1('e1240010-0000-4000-8000-000000000104', null)$$, '22023', 'price is required', 'a cleaner cannot clear a price (null is refused)');
select throws_ok($$select public.inventory_item_price_set_v1('e1240010-0000-4000-8000-000000000104', 0)$$, '22023', null, 'a cleaner price of 0 is refused');
reset role;
select ok((select (select array_agg(key order by key) from jsonb_object_keys(v) key) = array['change_id', 'item_id', 'ok'] and (v ->> 'ok')::boolean and v ->> 'change_id' is not null
                  and position('33.33' in v::text) = 0 and position('12.34' in v::text) = 0 from _r where k = 'p_c1'),
  'a cleaner price set returns only ok, item_id and change_id: no before, no after, no amount');
select ok((select unit_cost = 33.33 and updated_by = 'e1240010-0000-4000-8000-000000000012' from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000104')
      and (select before = '{"unit_cost":12.34}'::jsonb and after = '{"unit_cost":33.33}'::jsonb and kind = 'price' from public.inventory_item_changes where id = (select (v ->> 'change_id')::uuid from _r where k = 'p_c1')),
  'the blind price is stored, the item is stamped, and the closed change row holds the amounts');
select ok((select v ->> 'change_id' is not null and (v ->> 'change_id') <> (select v ->> 'change_id' from _r where k = 'p_c1') from _r where k = 'p_c2'),
  'setting the very same price again still writes a row and returns a change_id (no equal-to-current signal for a blind caller)');
-- finance admin: the old return plus change_id (p_aal is ignored since D-094, so every owner/admin has finance)
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000011","aal":"aal2"}';
insert into _r select 'p_f', public.inventory_item_price_set_v1('e1240010-0000-4000-8000-000000000104', 45.67);
insert into _r select 'p_fnull', public.inventory_item_price_set_v1('e1240010-0000-4000-8000-000000000112', null);
reset role;
select ok((select (v ->> 'ok')::boolean and (v ->> 'before')::numeric = 33.33 and (v ->> 'after')::numeric = 45.67 and v ->> 'change_id' is not null from _r where k = 'p_f'),
  'a finance admin gets ok, before, after and change_id as before');
select ok((select (v ->> 'ok')::boolean and (v ->> 'before')::numeric = 20.00 and v -> 'after' = 'null'::jsonb from _r where k = 'p_fnull') and (select unit_cost is null from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000112'),
  'a finance admin can still clear a price');
-- a maintenance user (read_operations, neither finance nor submit_cleaning) is refused on the price and the details
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000015"}';
select throws_ok($$select public.inventory_item_price_set_v1('e1240010-0000-4000-8000-000000000104', 5)$$, '42501', null, 'a maintenance user cannot set a price');
select throws_ok($$select public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"name":"Zz S124 Nope"}')$$, '42501', null, 'a maintenance user cannot edit an item');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000014"}';
select throws_ok($$select public.inventory_item_price_set_v1('e1240010-0000-4000-8000-000000000104', 5)$$, '42501', null, 'a user with no staff profile cannot set a price');
reset role;

update public.inventory_item_changes c set created_at = now() - (4 - x.n) * interval '1 minute'
from (select id, row_number() over (order by (after ->> 'unit_cost')::numeric, id) n from public.inventory_item_changes where item_id = 'e1240010-0000-4000-8000-000000000104') x where c.id = x.id;
-- 32-35. the catalogue as a cleaner shows no price, with updatedAt and updatedBy ----------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'cat_c', public.get_inventory_catalogue_v1('e1240010-0000-4000-8000-000000000001');
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000011","aal":"aal2"}';
insert into _r select 'cat_f', public.get_inventory_catalogue_v1('e1240010-0000-4000-8000-000000000001');
reset role;
select ok((select jsonb_array_length(v -> 'items') = 13 and not exists (select 1 from jsonb_array_elements(v -> 'items') e where e ->> 'unitCost' is not null)
                  and position('45.67' in v::text) = 0 and position('33.33' in v::text) = 0 and position('12.34' in v::text) = 0 from _r where k = 'cat_c'),
  'the catalogue read as a cleaner has no unitCost on any item and no price anywhere in the text');
select ok((select (select (e ->> 'unitCost')::numeric = 45.67 from jsonb_array_elements(v -> 'items') e where e ->> 'id' = 'e1240010-0000-4000-8000-000000000104') from _r where k = 'cat_f'),
  'the same catalogue read as finance shows the price (the gate is not vacuous)');
select ok((select e ->> 'updatedBy' = 'Adam' and (e ->> 'updatedAt')::timestamptz >= now() - interval '1 minute' from _r, jsonb_array_elements(v -> 'items') e where k = 'cat_c' and e ->> 'id' = 'e1240010-0000-4000-8000-000000000104'),
  'a priced item reads updatedBy Adam (the newest edit, first name only) with a fresh updatedAt');
select ok((select e ->> 'updatedBy' = 'Clea' from _r, jsonb_array_elements(v -> 'items') e where k = 'cat_c' and e ->> 'id' = 'e1240010-0000-4000-8000-000000000101')
      and (select e -> 'updatedAt' = 'null'::jsonb and e -> 'updatedBy' = 'null'::jsonb from _r, jsonb_array_elements(v -> 'items') e where k = 'cat_c' and e ->> 'id' = 'e1240010-0000-4000-8000-000000000102'),
  'the cleaner-edited item reads updatedBy Clea; an untouched item has updatedAt and updatedBy null');

-- 36-39. photo -------------------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'ph1', public.inventory_item_photo_set_v1('e1240010-0000-4000-8000-000000000109', 'items/e1240010-0000-4000-8000-000000000109/e1240010-0000-4000-8000-000000000a01.webp');
insert into _r select 'ph_same', public.inventory_item_photo_set_v1('e1240010-0000-4000-8000-000000000109', 'items/e1240010-0000-4000-8000-000000000109/e1240010-0000-4000-8000-000000000a01.webp');
insert into _r select 'ph_bad', public.inventory_item_photo_set_v1('e1240010-0000-4000-8000-000000000109', 'items/e1240010-0000-4000-8000-000000000109/e1240010-0000-4000-8000-000000000a09.webp');
reset role;
select ok((select (v ->> 'ok')::boolean and v ->> 'change_id' is not null and v -> 'before' = 'null'::jsonb from _r where k = 'ph1')
      and (select photo_path like '%a01.webp' and updated_by = 'e1240010-0000-4000-8000-000000000012' from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000109')
      and (select kind = 'photo' and before = '{"photo_path":null}'::jsonb and after ->> 'photo_path' like '%a01.webp' from public.inventory_item_changes where id = (select (v ->> 'change_id')::uuid from _r where k = 'ph1')),
  'a photo set writes a photo change row, stamps the item and returns change_id');
select ok((select (v ->> 'ok')::boolean and v -> 'change_id' = 'null'::jsonb from _r where k = 'ph_same') and (select count(*) = 1 from public.inventory_item_changes where item_id = 'e1240010-0000-4000-8000-000000000109'),
  'setting the same photo again writes no second row');
select ok((select not (v ->> 'ok')::boolean and v ->> 'reason' = 'bad_path' from _r where k = 'ph_bad'), 'a path that is not in storage is still bad_path');
select ok((select count(*) = 0 from public.inventory_item_changes where item_id = 'e1240010-0000-4000-8000-000000000109' and after ->> 'photo_path' like '%a09.webp'), 'a bad path writes no row');

-- 40-48. history -------------------------------------------------------------------------------------------------------------------------------------
-- 101 has 6 details rows by the cleaner; give them an order: reorder_below row is the newest
update public.inventory_item_changes c set created_at = now() - (7 - x.n) * interval '1 minute'
from (select id, row_number() over (order by (case when after ? 'name' then 1 when after ? 'category' then 2 when after ? 'unit' then 3 when after ? 'reorder_below' then 4 when after ? 'par_qty' then 5 else 6 end)) n
      from public.inventory_item_changes where item_id = 'e1240010-0000-4000-8000-000000000101') x where c.id = x.id;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'h_101', public.inventory_item_history_v1('e1240010-0000-4000-8000-000000000101');
insert into _r select 'h_104c', public.inventory_item_history_v1('e1240010-0000-4000-8000-000000000104');
insert into _r select 'h_109', public.inventory_item_history_v1('e1240010-0000-4000-8000-000000000109');
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000011","aal":"aal2"}';
insert into _r select 'h_104f', public.inventory_item_history_v1('e1240010-0000-4000-8000-000000000104');
reset role;
select ok((select jsonb_array_length(v -> 'changes') = 6 and v #>> '{changes,0,kind}' = 'details' and v #>> '{changes,0,who}' = 'Clea' and v #>> '{changes,5,kind}' = 'details'
                  and v #> '{changes,0,fields}' = '{"location":{"before":"Shelf","after":"Closet"}}'::jsonb and v #> '{changes,5,fields}' = '{"name":{"before":"Zz S124 Towel","after":"Zz S124 Towel 2"}}'::jsonb
                  and (v #> '{changes,0}') ? 'at' and not ((v #> '{changes,0}') ? 'before') from _r where k = 'h_101'),
  'the history lists the details rows newest first as {at, kind, who, fields} with fields {key:{before,after}}');
select ok((select jsonb_array_length(v -> 'changes') = 3 and (select count(*) from jsonb_array_elements(v -> 'changes') e where e ->> 'kind' = 'price') = 3
                  and not exists (select 1 from jsonb_array_elements(v -> 'changes') e where e -> 'fields' <> '{}'::jsonb) and position('45.67' in v::text) = 0 and position('33.33' in v::text) = 0
                  and position('12.34' in v::text) = 0 from _r where k = 'h_104c'),
  'the history read as a cleaner shows the price rows with empty fields and no amount anywhere');
select ok((select (select e -> 'fields' from jsonb_array_elements(v -> 'changes') e where e ->> 'kind' = 'price' and e #>> '{fields,unit_cost,after}' = '45.67') = '{"unit_cost":{"before":33.33,"after":45.67}}'::jsonb
                  and (select count(*) from jsonb_array_elements(v -> 'changes') e where e ->> 'kind' = 'price' and e ->> 'who' in ('Adam', 'Clea')) = 3 from _r where k = 'h_104f'),
  'the same history read as finance carries the before and after amounts');
select ok((select jsonb_array_length(v -> 'changes') = 1 and v #> '{changes,0}' ->> 'kind' = 'photo' and v #> '{changes,0,fields}' = '{}'::jsonb from _r where k = 'h_109'), 'a photo row carries empty fields');
-- 10 newest overall
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000011"}';
insert into _r select 'lim', jsonb_agg(public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000110', jsonb_build_object('reorder_below', g))) from generate_series(3, 14) g;
reset role;
update public.inventory_item_changes c set created_at = now() - (20 - (c.after ->> 'reorder_below')::numeric) * interval '1 minute' where c.item_id = 'e1240010-0000-4000-8000-000000000110';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'h_110', public.inventory_item_history_v1('e1240010-0000-4000-8000-000000000110');
reset role;
select ok((select jsonb_array_length(v -> 'changes') = 10 and (v #>> '{changes,0,fields,reorder_below,after}')::numeric = 14 and (v #>> '{changes,9,fields,reorder_below,after}')::numeric = 5 from _r where k = 'h_110'),
  'the history keeps the 10 newest rows overall, newest first (14 down to 5 of 12 edits)');
-- 50-61. undo --------------------------------------------------------------------------------------------------------------------------------------
-- 105: a cleaner renames, then undoes it
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'u_edit', public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000105', '{"name":"Zz S124 Undo 2","location":"Hall"}');
insert into _r select 'u_ok', public.inventory_item_change_undo_v1((select (v ->> 'change_id')::uuid from _r where k = 'u_edit'));
insert into _r select 'u_again', public.inventory_item_change_undo_v1((select (v ->> 'change_id')::uuid from _r where k = 'u_edit'));
insert into _r select 'u_nf', public.inventory_item_change_undo_v1('e1240010-0000-4000-8000-00000000ffff');
reset role;
select ok((select (v ->> 'ok')::boolean and v ->> 'kind' = 'details' and v ->> 'item_id' = 'e1240010-0000-4000-8000-000000000105' from _r where k = 'u_ok')
      and (select name = 'Zz S124 Undo' and location is null and updated_by = 'e1240010-0000-4000-8000-000000000012' from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000105')
      and (select undone_at is not null from public.inventory_item_changes where id = (select (v ->> 'change_id')::uuid from _r where k = 'u_edit')),
  'a cleaner undoes their own edit: both fields restored, the change is marked undone');
select ok((select not (v ->> 'ok')::boolean and v ->> 'reason' = 'already_undone' from _r where k = 'u_again'), 'undoing again answers already_undone');
select ok((select not (v ->> 'ok')::boolean and v ->> 'reason' = 'not_found' from _r where k = 'u_nf'), 'an unknown change answers not_found');
-- undone rows leave the history and the card
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'h_105', public.inventory_item_history_v1('e1240010-0000-4000-8000-000000000105');
insert into _r select 'cat_u', public.get_inventory_catalogue_v1('e1240010-0000-4000-8000-000000000001');
reset role;
select ok((select jsonb_array_length(v -> 'changes') = 0 from _r where k = 'h_105')
      and (select e -> 'updatedBy' = 'null'::jsonb from _r, jsonb_array_elements(v -> 'items') e where k = 'cat_u' and e ->> 'id' = 'e1240010-0000-4000-8000-000000000105'),
  'an undone change is gone from the history and the item card has no updatedBy any more');
-- a second cleaner and a user with no profile cannot undo someone else's change
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'u2_edit', public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000105', '{"location":"Porch"}');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000013"}';
select throws_ok(format($f$select public.inventory_item_change_undo_v1(%L)$f$, (select v ->> 'change_id' from _r where k = 'u2_edit')), '42501', null, 'a different cleaner cannot undo someone else''s change');
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000014"}';
select throws_ok(format($f$select public.inventory_item_change_undo_v1(%L)$f$, (select v ->> 'change_id' from _r where k = 'u2_edit')), '42501', null, 'a user with no staff profile cannot undo a change');
reset role;
select ok((select location = 'Porch' and undone_at is null from public.inventory_items i, public.inventory_item_changes c where i.id = 'e1240010-0000-4000-8000-000000000105' and c.id = (select (v ->> 'change_id')::uuid from _r where k = 'u2_edit')),
  'the refused undos left the item and the change as they were');
-- a manager may undo someone else's change
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000011"}';
insert into _r select 'u2_mgr', public.inventory_item_change_undo_v1((select (v ->> 'change_id')::uuid from _r where k = 'u2_edit'));
reset role;
select ok((select (v ->> 'ok')::boolean from _r where k = 'u2_mgr') and (select location is null from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000105'), 'an admin (manage_inventory) can undo a cleaner''s change');
-- too late: 40 minutes old, the cleaner is refused, the manager is not
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'l_edit', public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000106', '{"unit":"set"}');
reset role;
update public.inventory_item_changes set created_at = now() - interval '40 minutes' where id = (select (v ->> 'change_id')::uuid from _r where k = 'l_edit');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'l_c', public.inventory_item_change_undo_v1((select (v ->> 'change_id')::uuid from _r where k = 'l_edit'));
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000011"}';
insert into _r select 'l_m', public.inventory_item_change_undo_v1((select (v ->> 'change_id')::uuid from _r where k = 'l_edit'));
reset role;
select ok((select not (v ->> 'ok')::boolean and v ->> 'reason' = 'too_late' from _r where k = 'l_c'), 'a cleaner cannot undo after 30 minutes (too_late)');
select ok((select (v ->> 'ok')::boolean from _r where k = 'l_m') and (select unit = 'pc' from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000106'), 'a manager can undo the same change after 30 minutes');
-- changed since: a newer edit of the same kind, and a value changed outside the app
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'r_a', public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000107', '{"par_qty":3}');
reset role;
update public.inventory_item_changes set created_at = now() - interval '5 minutes' where id = (select (v ->> 'change_id')::uuid from _r where k = 'r_a');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000011"}';
insert into _r select 'r_b', public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000107', '{"par_qty":4}');
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'r_u', public.inventory_item_change_undo_v1((select (v ->> 'change_id')::uuid from _r where k = 'r_a'));
reset role;
select ok((select not (v ->> 'ok')::boolean and v ->> 'reason' = 'changed_since' from _r where k = 'r_u') and (select par_qty = 4 from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000107'),
  'a newer change of the same kind makes the older undo answer changed_since and writes nothing');
-- the newer one can still be undone, which then frees the older one
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000011"}';
insert into _r select 'r_ub', public.inventory_item_change_undo_v1((select (v ->> 'change_id')::uuid from _r where k = 'r_b'));
insert into _r select 'r_ua', public.inventory_item_change_undo_v1((select (v ->> 'change_id')::uuid from _r where k = 'r_a'));
reset role;
select ok((select (v ->> 'ok')::boolean from _r where k = 'r_ub') and (select (v ->> 'ok')::boolean from _r where k = 'r_ua') and (select par_qty is null from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000107'),
  'undoing the newest change first frees the older one, and both restore (par back to null)');
-- a value changed outside the app since the change
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'o_edit', public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000107', '{"reorder_below":6}');
reset role;
update public.inventory_items set reorder_below = 99 where id = 'e1240010-0000-4000-8000-000000000107';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'o_u', public.inventory_item_change_undo_v1((select (v ->> 'change_id')::uuid from _r where k = 'o_edit'));
reset role;
select ok((select not (v ->> 'ok')::boolean and v ->> 'reason' = 'changed_since' from _r where k = 'o_u') and (select reorder_below = 99 from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000107'),
  'a value that no longer equals the change''s after answers changed_since');
-- name_exists on undo
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'n_edit', public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000108', '{"name":"Zz S124 Beta"}');
reset role;
update public.inventory_items set name = 'Zz S124 Alpha' where id = 'e1240010-0000-4000-8000-000000000113';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'n_u', public.inventory_item_change_undo_v1((select (v ->> 'change_id')::uuid from _r where k = 'n_edit'));
reset role;
select ok((select not (v ->> 'ok')::boolean and v ->> 'reason' = 'name_exists' from _r where k = 'n_u') and (select name = 'Zz S124 Beta' from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000108'),
  'undoing a rename back to a name another active item now has answers name_exists');
-- undo of a price and of a photo by a cleaner: nothing priced comes back
update public.inventory_items set name = 'Zz S124 Plain' where id = 'e1240010-0000-4000-8000-000000000113';
update public.inventory_item_changes set created_at = now() - interval '10 minutes' where item_id = 'e1240010-0000-4000-8000-000000000112' and kind = 'price';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1240010-0000-4000-8000-000000000012"}';
insert into _r select 'pr_set', public.inventory_item_price_set_v1('e1240010-0000-4000-8000-000000000112', 61.61);
insert into _r select 'pr_undo', public.inventory_item_change_undo_v1((select (v ->> 'change_id')::uuid from _r where k = 'pr_set'));
insert into _r select 'ph_undo', public.inventory_item_change_undo_v1((select (v ->> 'change_id')::uuid from _r where k = 'ph1'));
reset role;
select ok((select (v ->> 'ok')::boolean and (select array_agg(key order by key) from jsonb_object_keys(v) key) = array['item_id', 'kind', 'ok'] and v ->> 'kind' = 'price' and position('61.61' in v::text) = 0
                  from _r where k = 'pr_undo')
      and (select unit_cost is null from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000112'),
  'a cleaner undoes a blind price: the item goes back to the earlier price (here none: finance had cleared it), and the answer holds no amount');
select ok((select (v ->> 'ok')::boolean and v ->> 'kind' = 'photo' from _r where k = 'ph_undo') and (select photo_path is null from public.inventory_items where id = 'e1240010-0000-4000-8000-000000000109'),
  'a cleaner undoes a photo change and the photo goes back');

-- 72-77. anon is refused on every function -------------------------------------------------------------------------------------------------------
set local role anon;
select throws_ok($$select public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"name":"Zz S124 Anon"}')$$, '42501', null, 'anon cannot call inventory_item_update_v1');
select throws_ok($$select public.inventory_item_price_set_v1('e1240010-0000-4000-8000-000000000104', 1)$$, '42501', null, 'anon cannot call inventory_item_price_set_v1');
select throws_ok($$select public.inventory_item_photo_set_v1('e1240010-0000-4000-8000-000000000109', null)$$, '42501', null, 'anon cannot call inventory_item_photo_set_v1');
select throws_ok($$select public.inventory_item_change_undo_v1('e1240010-0000-4000-8000-00000000ffff')$$, '42501', null, 'anon cannot call inventory_item_change_undo_v1');
select throws_ok($$select public.get_inventory_catalogue_v1('e1240010-0000-4000-8000-000000000001')$$, '42501', null, 'anon cannot call get_inventory_catalogue_v1');
select throws_ok($$select public.inventory_item_history_v1('e1240010-0000-4000-8000-000000000101')$$, '42501', null, 'anon cannot call inventory_item_history_v1');
reset role;
-- signed in but a null user (no sub): the functions that reach admin_require / the undo guard refuse
set local role authenticated;
set local request.jwt.claims = '{}';
select throws_ok($$select public.inventory_item_change_undo_v1('e1240010-0000-4000-8000-00000000ffff')$$, '42501', 'authentication required', 'a call with no user id is refused before anything is looked up');
select throws_ok($$select public.inventory_item_update_v1('e1240010-0000-4000-8000-000000000101', '{"name":"Zz S124 Nobody"}')$$, '42501', null, 'a call with no user id cannot edit');
reset role;

select ok((select count(*) = 0 from public.inventory_item_changes where item_id = 'e1240010-0000-4000-8000-000000000101' and actor <> 'e1240010-0000-4000-8000-000000000012'), 'no anon or profile-less call left a change row on item 101');

select diag(k || ' ' || v::text) from _r order by k;
select * from finish();
rollback;
