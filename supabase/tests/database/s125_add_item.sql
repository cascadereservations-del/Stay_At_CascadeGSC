-- Session 125 (lane L1 SQL): release s125_add_item_20261125. inventory_item_create_v1 (manager or cleaner, one 'created' change row), inventory_item_change_undo_v1 for kind 'created',
-- inventory_option_request_v1 (a cleaner's product add on an item they just created applies at once), get_inventory_catalogue_v1 (updatedKind) and the history row of a created item.
-- Synthetic fixtures only (uuids e1250010-..., property ...01, items "Zz S125 ...", users ...11 admin "Adam Zz", ...12 cleaner "Clea Zz", ...13 second cleaner, ...14 no staff profile,
-- ...17 cleaner of another property); every lookup is scoped to them because a real backup holds real rows. Refusals are tested by calling as the refused role.
-- created_at of a change row is moved by hand where the age matters. Everything rolls back.
begin;
select plan(67);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid), public.current_staff_active(text[]) to authenticated, service_role;
grant execute on function public.admin_require(text, uuid) to authenticated;
grant execute on function public.manila_today() to authenticated, anon;
grant execute on function public.reconcile_inventory_baseline_v1(uuid, numeric, text, text) to authenticated;

create function pg_temp.as_user(p_uid text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', ('e1250010-0000-4000-8000-0000000000' || p_uid)::uuid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.try(p text) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  execute p into r;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.iid(p text) returns uuid language sql stable as $$ select (v ->> 'item_id')::uuid from _t where k = p $$;
create function pg_temp.cid(p text) returns uuid language sql stable as $$ select (v ->> 'change_id')::uuid from _t where k = p $$;

-- fixtures -------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values ('e1250010-0000-4000-8000-000000000001', 'Synthetic S125', true), ('e1250010-0000-4000-8000-000000000002', 'Synthetic S125 Other', true);
insert into auth.users(id) values ('e1250010-0000-4000-8000-000000000011'), ('e1250010-0000-4000-8000-000000000012'), ('e1250010-0000-4000-8000-000000000013'), ('e1250010-0000-4000-8000-000000000014'), ('e1250010-0000-4000-8000-000000000017');
update auth.users set raw_app_meta_data = jsonb_build_object('display_name', 'Adam Zz') where id = 'e1250010-0000-4000-8000-000000000011';
update auth.users set raw_app_meta_data = jsonb_build_object('display_name', 'Clea Zz') where id = 'e1250010-0000-4000-8000-000000000012';
insert into public.staff_access_profiles(user_id, role) values ('e1250010-0000-4000-8000-000000000011', 'admin'), ('e1250010-0000-4000-8000-000000000012', 'cleaner'),
  ('e1250010-0000-4000-8000-000000000013', 'cleaner'), ('e1250010-0000-4000-8000-000000000017', 'cleaner');
insert into public.staff_property_access(user_id, property_id) values ('e1250010-0000-4000-8000-000000000011', 'e1250010-0000-4000-8000-000000000001'), ('e1250010-0000-4000-8000-000000000012', 'e1250010-0000-4000-8000-000000000001'),
  ('e1250010-0000-4000-8000-000000000013', 'e1250010-0000-4000-8000-000000000001'), ('e1250010-0000-4000-8000-000000000017', 'e1250010-0000-4000-8000-000000000002');
-- 101 active Cat A, 102 inactive Cat C (a category only an inactive item uses), 103 an old item with a price
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, units_per_purchase, unit_cost) values
  ('e1250010-0000-4000-8000-000000000101', 'e1250010-0000-4000-8000-000000000001', 'Zz S125 Towel', 'Zz S125 Cat A', 'pc', 5, true,  true,  1, null),
  ('e1250010-0000-4000-8000-000000000102', 'e1250010-0000-4000-8000-000000000001', 'Zz S125 Old',   'Zz S125 Cat C', 'pc', 5, false, false, 1, null),
  ('e1250010-0000-4000-8000-000000000103', 'e1250010-0000-4000-8000-000000000001', 'Zz S125 Priced', 'Zz S125 Cat A', 'pc', 5, true, true,  1, 7.77);
insert into public.inventory_suppliers(id, property_id, name, payment_method, is_active) values ('e1250010-0000-4000-8000-0000000000a1', 'e1250010-0000-4000-8000-000000000001', 'Zz S125 Shop', 'online', true);
insert into storage.buckets(id, name) values ('inventory-photos', 'inventory-photos') on conflict (id) do nothing;

-- 1-3. shape and grants ----------------------------------------------------------------------------------------------------------------------
select ok((select pg_get_constraintdef(oid) like '%created%' and pg_get_constraintdef(oid) like '%details%' from pg_constraint where conrelid = 'public.inventory_item_changes'::regclass and conname = 'inventory_item_changes_kind_check'),
  'the change kinds now include created (and still details)');
select ok((select bool_and(has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute') and not has_function_privilege('service_role', f, 'execute'))
           from unnest(array['public.inventory_item_create_v1(uuid,jsonb,text,text,text)', 'public.inventory_item_change_undo_v1(uuid)', 'public.get_inventory_catalogue_v1(uuid)',
                             'public.inventory_option_request_v1(uuid,text,uuid,jsonb,text,text)']) f),
  'the four replaced functions run for signed-in users only (not anon, not service_role)');
select is((select count(*)::int from pg_proc where prosecdef and proconfig = array['search_path=""'] and oid in ('public.inventory_item_create_v1(uuid,jsonb,text,text,text)'::regprocedure, 'public.inventory_item_change_undo_v1(uuid)'::regprocedure,
            'public.get_inventory_catalogue_v1(uuid)'::regprocedure, 'public.inventory_option_request_v1(uuid,text,uuid,jsonb,text,text)'::regprocedure)), 4, 'the four are security definer with an empty search_path');

-- 4-9. a cleaner adds an item ------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('12');
insert into _t select 'c1', pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"  Zz S125 Mop ","category":"zz s125 cat a","unit":"roll","consumable":false,"reorder_below":2,"qty":4,"location":"Closet"}')$$);
insert into _t select 'c2', pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Bucket","category":"Zz S125 Cat A"}')$$);
insert into _t select 'c1_dupe', pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"zz s125 mop","category":"Zz S125 Cat A"}')$$);
reset role;
select ok((select (v ->> 'ok')::boolean and v ->> 'item_id' is not null and v ->> 'change_id' is not null and (select array_agg(key order by key) from jsonb_object_keys(v) key) = array['change_id', 'item_id', 'ok'] from _t where k = 'c1'),
  'a cleaner creates an item and gets ok, item_id and change_id');
select ok((select i.name = 'Zz S125 Mop' and i.category = 'Zz S125 Cat A' and i.unit = 'roll' and not i.is_consumable and i.is_active and i.reorder_below = 2 and i.location = 'Closet'
                  and i.qty_on_hand = 4 and i.updated_by = 'e1250010-0000-4000-8000-000000000012' and i.updated_at >= now() - interval '1 minute' and i.par_qty is null and i.unit_cost is null
           from public.inventory_items i where i.id = pg_temp.iid('c1')),
  'the item is trimmed, takes the existing spelling of the category, is stamped updated_by / updated_at and holds the first count');
select ok((select c.kind = 'created' and c.actor = 'e1250010-0000-4000-8000-000000000012' and c.before = '{}'::jsonb and c.undone_at is null
                  and c.after = '{"name":"Zz S125 Mop","category":"Zz S125 Cat A","unit":"roll","active":true}'::jsonb and c.property_id = 'e1250010-0000-4000-8000-000000000001'
           from public.inventory_item_changes c where c.id = pg_temp.cid('c1')),
  'one created change row: before {}, after holds name, category, unit and active only');
select ok((select count(*) = 1 and bool_and(kind = 'reconcile' and quantity_before = 0 and quantity_after = 4 and actor_user_id = 'e1250010-0000-4000-8000-000000000012' and idempotency_key = 'stk-create-' || replace(pg_temp.iid('c1')::text, '-', ''))
           from public.inventory_stock_movements where item_id = pg_temp.iid('c1')),
  'the first count is one reconcile movement keyed stk-create-<id>');
select ok((select (v ->> 'ok')::boolean from _t where k = 'c2') and (select unit = 'pc' and qty_on_hand = 0 and location is null from public.inventory_items where id = pg_temp.iid('c2'))
      and not exists (select 1 from public.inventory_stock_movements where item_id = pg_temp.iid('c2')),
  'with no count and no unit the item gets unit pc, qty 0, no location and no movement');
select ok((select not (v ->> 'ok')::boolean and v ->> 'reason' = 'name_exists' and v ->> 'item_id' = pg_temp.iid('c1')::text and not (v ? 'change_id') from _t where k = 'c1_dupe')
      and (select count(*) = 2 from public.inventory_item_changes where property_id = 'e1250010-0000-4000-8000-000000000001' and kind = 'created'),
  'the same name in another letter case answers name_exists and writes no row');

-- 10-21. a cleaner is refused what only the owner may do ---------------------------------------------------------------------------------------
select pg_temp.as_user('12');
select is(pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Nope","category":"Zz S125 Cat A","par_qty":5}')$$) ->> 'err', '42501', 'a cleaner cannot send par_qty');
select is(pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Nope","category":"Zz S125 Cat A","purchase_unit":"box"}')$$) ->> 'err', '42501', 'a cleaner cannot send purchase_unit');
select is(pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Nope","category":"Zz S125 Cat A","units_per_purchase":6}')$$) ->> 'err', '42501', 'a cleaner cannot send units_per_purchase');
select is(pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Nope","category":"Zz S125 Cat A","bogus":1}')$$) ->> 'err', '42501', 'a cleaner sending any other key is refused 42501');
select is(pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Nope","category":"Zz S125 Cat A","unit_cost":5}')$$) ->> 'err', '42501', 'a cleaner cannot send a price');
select is(pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Nope","category":"Zz S125 Cat A"}', 'ZZ125NOPE')$$) ->> 'err', '42501', 'a cleaner linking a barcode (p_code) is refused 42501');
select is(pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Nope","category":"Zz S125 Brand New"}')$$) ->> 'msg', 'category must be one already in use', 'a cleaner cannot start a new category');
select is(pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Nope","category":"Zz S125 Cat C"}')$$) ->> 'msg', 'category must be one already in use', 'a category only an inactive item uses is not in use');
select is(pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Z","category":"Zz S125 Cat A"}')$$) ->> 'err', '22023', 'a one-letter name is refused 22023');
select is(pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', jsonb_build_object('name', 'Zz S125 Nope', 'category', 'Zz S125 Cat A', 'location', repeat('x', 61)))$$) ->> 'err', '22023', 'a location of 61 characters is refused 22023');
select is(pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Nope","category":"Zz S125 Cat A","qty":-1}')$$) ->> 'err', '22023', 'a negative count is refused 22023');
reset role;
select ok(not exists (select 1 from public.inventory_items where property_id = 'e1250010-0000-4000-8000-000000000001' and name = 'Zz S125 Nope')
      and (select count(*) = 2 from public.inventory_item_changes where property_id = 'e1250010-0000-4000-8000-000000000001' and kind = 'created'), 'every refusal wrote no item and no row');

-- 22-24. other callers are refused -------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('14');
select is(pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Nope","category":"Zz S125 Cat A"}')$$) ->> 'err', '42501', 'a user with no staff profile cannot add an item');
select pg_temp.as_user('17');
select is(pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Nope","category":"Zz S125 Cat A"}')$$) ->> 'err', '42501', 'a cleaner of another property cannot add an item');
reset role;
set local role anon;
select throws_ok($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Nope","category":"Zz S125 Cat A"}')$$, '42501', null, 'anon cannot add an item');
reset role;

-- 25-30. the owner/admin path ------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('11');
insert into _t select 'a1', pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Admin","category":"Zz S125 New Cat","unit":"box","consumable":true,"reorder_below":1,"par_qty":9,"purchase_unit":"case","units_per_purchase":6,"location":"Attic"}', 'ZZ125CODE1', 'ean13')$$);
insert into _t select 'a_taken', pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Admin Two","category":"Zz S125 Cat A"}', 'ZZ125CODE1')$$);
insert into _t select 'a_bad', pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Admin Three","category":"Zz S125 Cat A"}', 'ZZ 125 BAD')$$);
insert into _t select 'a_key', pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Admin Key","category":"Zz S125 Cat A","qty":7}', null, null, 'zz125-create-key-0001')$$);
select is(pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Admin Bogus","category":"Zz S125 Cat A","bogus":1}')$$) ->> 'err', '22023', 'an owner/admin sending an unknown key is refused 22023');
reset role;
select ok((select (v ->> 'ok')::boolean and v ->> 'change_id' is not null from _t where k = 'a1')
      and (select i.name = 'Zz S125 Admin' and i.category = 'Zz S125 New Cat' and i.unit = 'box' and i.is_consumable and i.reorder_below = 1 and i.par_qty = 9 and i.purchase_unit = 'case' and i.units_per_purchase = 6
                  and i.location = 'Attic' and i.updated_by = 'e1250010-0000-4000-8000-000000000011' from public.inventory_items i where i.id = pg_temp.iid('a1'))
      and (select count(*) = 1 from public.inventory_item_codes where item_id = pg_temp.iid('a1') and code = 'ZZ125CODE1' and format = 'ean13'),
  'an admin adds an item with every key, a new category and a barcode, and gets a change_id');
select ok((select c.kind = 'created' and c.after = '{"name":"Zz S125 Admin","category":"Zz S125 New Cat","unit":"box","active":true}'::jsonb and c.before = '{}'::jsonb from public.inventory_item_changes c where c.id = pg_temp.cid('a1')),
  'the admin change row holds the same four keys (no par, pack or location)');
select ok((select not (v ->> 'ok')::boolean and v ->> 'reason' = 'code_taken' and not (v ? 'change_id') from _t where k = 'a_taken')
      and (select not (v ->> 'ok')::boolean and v ->> 'reason' = 'bad_code' and not (v ? 'change_id') from _t where k = 'a_bad')
      and not exists (select 1 from public.inventory_items where name in ('Zz S125 Admin Two', 'Zz S125 Admin Three')),
  'a barcode already linked (code_taken) and a malformed barcode (bad_code) write no item and no row');
select ok((select (v ->> 'ok')::boolean from _t where k = 'a_key') and (select idempotency_key = 'zz125-create-key-0001' and quantity_after = 7 from public.inventory_stock_movements where item_id = pg_temp.iid('a_key')),
  'the idempotency key becomes the key of the first count');

-- 31-40. undo of a created item ---------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('12');
insert into _t select 'u1', pg_temp.try(format($$select public.inventory_item_change_undo_v1(%L)$$, pg_temp.cid('c1')));
insert into _t select 'u1_again', pg_temp.try(format($$select public.inventory_item_change_undo_v1(%L)$$, pg_temp.cid('c1')));
reset role;
select ok((select (v ->> 'ok')::boolean and v ->> 'kind' = 'created' and v ->> 'item_id' = pg_temp.iid('c1')::text from _t where k = 'u1')
      and (select not i.is_active and i.updated_by = 'e1250010-0000-4000-8000-000000000012' and i.name = 'Zz S125 Mop' from public.inventory_items i where i.id = pg_temp.iid('c1'))
      and (select undone_at is not null from public.inventory_item_changes where id = pg_temp.cid('c1')),
  'a cleaner undoes their new item within 30 minutes (it still holds its first count): the item is hidden, not deleted, and the row is marked undone');
select ok((select count(*) = 1 from public.inventory_stock_movements where item_id = pg_temp.iid('c1')), 'the first-count movement is still there after the undo');
select ok((select not (v ->> 'ok')::boolean and v ->> 'reason' = 'already_undone' from _t where k = 'u1_again'), 'undoing again answers already_undone');
-- the name is free again
select pg_temp.as_user('12');
insert into _t select 'c1b', pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Mop","category":"Zz S125 Cat A"}')$$);
reset role;
select ok((select (v ->> 'ok')::boolean and v ->> 'item_id' <> pg_temp.iid('c1')::text from _t where k = 'c1b'), 'after the undo the same name can be added again (a new item)');
-- other cleaner, no profile, other property, anon
select pg_temp.as_user('13');
select is(pg_temp.try(format($$select public.inventory_item_change_undo_v1(%L)$$, pg_temp.cid('c2'))) ->> 'err', '42501', 'a different cleaner cannot undo someone else''s new item');
select pg_temp.as_user('14');
select is(pg_temp.try(format($$select public.inventory_item_change_undo_v1(%L)$$, pg_temp.cid('c2'))) ->> 'err', '42501', 'a user with no staff profile cannot undo');
select pg_temp.as_user('17');
select is(pg_temp.try(format($$select public.inventory_item_change_undo_v1(%L)$$, pg_temp.cid('c2'))) ->> 'err', '42501', 'a cleaner of another property cannot undo');
reset role;
set local role anon;
select throws_ok(format($$select public.inventory_item_change_undo_v1(%L)$$, pg_temp.cid('c2')), '42501', null, 'anon cannot undo');
reset role;
select ok((select is_active and undone_at is null from public.inventory_items i, public.inventory_item_changes c where i.id = pg_temp.iid('c2') and c.id = pg_temp.cid('c2')), 'the refused undos left the item and the row as they were');
-- too late, and a manager may still undo
select pg_temp.as_user('12');
insert into _t select 'late', pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Late","category":"Zz S125 Cat A"}')$$);
reset role;
update public.inventory_item_changes set created_at = now() - interval '40 minutes' where id = pg_temp.cid('late');
select pg_temp.as_user('12');
insert into _t select 'late_c', pg_temp.try(format($$select public.inventory_item_change_undo_v1(%L)$$, pg_temp.cid('late')));
select pg_temp.as_user('11');
insert into _t select 'late_m', pg_temp.try(format($$select public.inventory_item_change_undo_v1(%L)$$, pg_temp.cid('late')));
reset role;
select ok((select not (v ->> 'ok')::boolean and v ->> 'reason' = 'too_late' from _t where k = 'late_c'), 'a cleaner cannot undo a new item after 30 minutes (too_late)');
select ok((select (v ->> 'ok')::boolean from _t where k = 'late_m') and (select not is_active from public.inventory_items where id = pg_temp.iid('late')), 'an admin (manage_inventory) can undo the same item after 30 minutes');

-- 41-48. the undo is refused once the item was used or changed -------------------------------------------------------------------------------
select pg_temp.as_user('12');
insert into _t select 'cnt', pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Counted","category":"Zz S125 Cat A","qty":5}')$$);
insert into _t select 'mv', pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Moved","category":"Zz S125 Cat A","qty":4}')$$);
insert into _t select 'ed', pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Edited","category":"Zz S125 Cat A"}')$$);
insert into _t select 'ph1', pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Photo Same","category":"Zz S125 Cat A"}')$$);
insert into _t select 'ph2', pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Photo Other","category":"Zz S125 Cat A"}')$$);
insert into _t select 'own', pg_temp.try($$select public.inventory_item_create_v1('e1250010-0000-4000-8000-000000000001', '{"name":"Zz S125 Own Products","category":"Zz S125 Cat A"}')$$);
-- a second count after the first
insert into _t select 'recount', pg_temp.try(format($$select public.reconcile_inventory_baseline_v1(%L, 3, 'Counted again by the cleaner', 'zz125-recount-key-001')$$, pg_temp.iid('cnt')));
-- a newer details edit
insert into _t select 'edit1', pg_temp.try(format($$select public.inventory_item_update_v1(%L, '{"location":"Shelf"}')$$, pg_temp.iid('ed')));
reset role;
-- a move between items (written as the owner of the table: the closed table has no client grant)
insert into public.inventory_item_moves(property_id, kind, from_item_id, to_item_id, qty, actor_user_id, idempotency_key, before_from, after_from, before_to, after_to)
values ('e1250010-0000-4000-8000-000000000001', 'stock', pg_temp.iid('mv'), 'e1250010-0000-4000-8000-000000000101', 1, 'e1250010-0000-4000-8000-000000000012', 'zz125-move-key-00001', 4, 3, 5, 6);
-- photos: the same person right after the create, and another person
insert into storage.objects(bucket_id, name) values
  ('inventory-photos', 'items/' || pg_temp.iid('ph1') || '/e1250010-0000-4000-8000-000000000a01.webp'),
  ('inventory-photos', 'items/' || pg_temp.iid('ph2') || '/e1250010-0000-4000-8000-000000000a02.webp');
select pg_temp.as_user('12');
insert into _t select 'ph1_set', pg_temp.try(format($$select public.inventory_item_photo_set_v1(%L, %L)$$, pg_temp.iid('ph1'), 'items/' || pg_temp.iid('ph1') || '/e1250010-0000-4000-8000-000000000a01.webp'));
select pg_temp.as_user('13');
insert into _t select 'ph2_set', pg_temp.try(format($$select public.inventory_item_photo_set_v1(%L, %L)$$, pg_temp.iid('ph2'), 'items/' || pg_temp.iid('ph2') || '/e1250010-0000-4000-8000-000000000a02.webp'));
select pg_temp.as_user('12');
insert into _t select 'u_cnt', pg_temp.try(format($$select public.inventory_item_change_undo_v1(%L)$$, pg_temp.cid('cnt')));
insert into _t select 'u_mv', pg_temp.try(format($$select public.inventory_item_change_undo_v1(%L)$$, pg_temp.cid('mv')));
insert into _t select 'u_ed', pg_temp.try(format($$select public.inventory_item_change_undo_v1(%L)$$, pg_temp.cid('ed')));
insert into _t select 'u_ph1', pg_temp.try(format($$select public.inventory_item_change_undo_v1(%L)$$, pg_temp.cid('ph1')));
insert into _t select 'u_ph2', pg_temp.try(format($$select public.inventory_item_change_undo_v1(%L)$$, pg_temp.cid('ph2')));
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'recount') and (select count(*) = 2 from public.inventory_stock_movements where item_id = pg_temp.iid('cnt')), 'fixture: the item has its first count and a second one');
select ok((select not (v ->> 'ok')::boolean and v ->> 'reason' = 'changed_since' from _t where k = 'u_cnt') and (select is_active from public.inventory_items where id = pg_temp.iid('cnt')),
  'undo answers changed_since once the item was counted again, and leaves it active');
select ok((select not (v ->> 'ok')::boolean and v ->> 'reason' = 'changed_since' from _t where k = 'u_mv') and (select is_active from public.inventory_items where id = pg_temp.iid('mv')),
  'undo answers changed_since once stock was moved from the item (inventory_item_moves), and leaves it active');
select ok((select (v ->> 'ok')::boolean and v ->> 'change_id' is not null from _t where k = 'edit1') and (select not (v ->> 'ok')::boolean and v ->> 'reason' = 'changed_since' from _t where k = 'u_ed')
      and (select is_active from public.inventory_items where id = pg_temp.iid('ed')),
  'undo answers changed_since once a newer details edit exists (any kind of newer change blocks a created row)');
select ok((select (v ->> 'ok')::boolean and v ->> 'change_id' is not null from _t where k = 'ph1_set') and (select (v ->> 'ok')::boolean and v ->> 'kind' = 'created' from _t where k = 'u_ph1')
      and (select not is_active from public.inventory_items where id = pg_temp.iid('ph1')),
  'a photo the same person set right after the create does not block the undo');
select ok((select (v ->> 'ok')::boolean from _t where k = 'ph2_set') and (select not (v ->> 'ok')::boolean and v ->> 'reason' = 'changed_since' from _t where k = 'u_ph2')
      and (select is_active from public.inventory_items where id = pg_temp.iid('ph2')),
  'a photo another person set blocks the undo (changed_since)');
select ok((select count(*) = 1 from public.inventory_item_changes where item_id = pg_temp.iid('ph1') and kind = 'photo' and undone_at is null)
      and (select undone_at is not null from public.inventory_item_changes where id = pg_temp.cid('ph1')), 'the created row is marked undone and the photo row stays as it is');

-- 49-62. products on a new item --------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('12');
insert into _t select 'o1', pg_temp.try(format($$select public.inventory_option_request_v1(%L, 'add', null, '{"title":"Zz S125 Gel","supplier_id":"e1250010-0000-4000-8000-0000000000a1","source_url":"https://shopsuki.ph/products/zz125"}', null, 'zz125-opt-key-000001')$$, pg_temp.iid('own')));
insert into _t select 'o1_replay', pg_temp.try(format($$select public.inventory_option_request_v1(%L, 'add', null, '{"title":"Zz S125 Gel","supplier_id":"e1250010-0000-4000-8000-0000000000a1","source_url":"https://shopsuki.ph/products/zz125"}', null, 'zz125-opt-key-000001')$$, pg_temp.iid('own')));
insert into _t select 'o_price', pg_temp.try(format($$select public.inventory_option_request_v1(%L, 'add', null, '{"title":"Zz S125 Priced Gel","supplier_id":"e1250010-0000-4000-8000-0000000000a1","price":99}', null, 'zz125-opt-key-000002')$$, pg_temp.iid('own')));
insert into _t select 'o_old', pg_temp.try($$select public.inventory_option_request_v1('e1250010-0000-4000-8000-000000000103', 'add', null, '{"title":"Zz S125 Old Gel","supplier_id":"e1250010-0000-4000-8000-0000000000a1"}', null, 'zz125-opt-key-000003')$$);
insert into _t select 'o_undone', pg_temp.try(format($$select public.inventory_option_request_v1(%L, 'add', null, '{"title":"Zz S125 Undone Gel","supplier_id":"e1250010-0000-4000-8000-0000000000a1"}', null, 'zz125-opt-key-000004')$$, pg_temp.iid('c1')));
insert into _t select 'o_edit', pg_temp.try(format($$select public.inventory_option_request_v1(%L, 'edit', %L, '{"title":"Zz S125 Gel 2"}', null, 'zz125-opt-key-000005')$$, pg_temp.iid('own'), (select (v ->> 'option_id')::uuid from _t where k = 'o1')));
insert into _t select 'o_del', pg_temp.try(format($$select public.inventory_option_request_v1(%L, 'delete', %L, null, null, 'zz125-opt-key-000006')$$, pg_temp.iid('own'), (select (v ->> 'option_id')::uuid from _t where k = 'o1')));
select pg_temp.as_user('13');
insert into _t select 'o_other', pg_temp.try(format($$select public.inventory_option_request_v1(%L, 'add', null, '{"title":"Zz S125 Other Gel","supplier_id":"e1250010-0000-4000-8000-0000000000a1"}', null, 'zz125-opt-key-000007')$$, pg_temp.iid('own')));
reset role;
select ok((select (v ->> 'ok')::boolean and (v ->> 'applied')::boolean and v ->> 'option_id' is not null from _t where k = 'o1')
      and (select count(*) = 1 from public.inventory_item_options where item_id = pg_temp.iid('own') and title = 'Zz S125 Gel' and created_by = 'e1250010-0000-4000-8000-000000000012')
      and (select status = 'approved' and decided_by = 'e1250010-0000-4000-8000-000000000012' and result_option_id is not null from public.inventory_option_requests where idempotency_key = 'zz125-opt-key-000001'),
  'a cleaner adding a product to the item they just created applies at once: applied true, the option exists, the request is approved');
select ok((select (v ->> 'replay')::boolean and (v ->> 'applied')::boolean and v ->> 'option_id' = (select v ->> 'option_id' from _t where k = 'o1') from _t where k = 'o1_replay')
      and (select count(*) = 1 from public.inventory_item_options where item_id = pg_temp.iid('own')), 'the same idempotency key replays: one option, applied true');
select ok((select v ->> 'err' = '22023' and v ->> 'msg' = 'price_not_allowed' from _t where k = 'o_price') and not exists (select 1 from public.inventory_item_options where item_id = pg_temp.iid('own') and price is not null),
  'a cleaner still cannot send a price, even on their own new item');
select ok((select (v ->> 'ok')::boolean and not (v ->> 'applied')::boolean from _t where k = 'o_old') and (select status = 'pending' from public.inventory_option_requests where idempotency_key = 'zz125-opt-key-000003')
      and not exists (select 1 from public.inventory_item_options where item_id = 'e1250010-0000-4000-8000-000000000103'),
  'a cleaner adding a product to an old item still waits for the owner (applied false, pending, no option)');
select ok((select (v ->> 'ok')::boolean and not (v ->> 'applied')::boolean from _t where k = 'o_undone') and not exists (select 1 from public.inventory_item_options where item_id = pg_temp.iid('c1')),
  'a product on an item whose creation was undone waits (applied false)');
select ok((select (v ->> 'ok')::boolean and not (v ->> 'applied')::boolean from _t where k = 'o_edit') and (select title = 'Zz S125 Gel' from public.inventory_item_options where id = (select (v ->> 'option_id')::uuid from _t where k = 'o1')),
  'a cleaner editing a product on their new item still goes to the owner (applied false, title unchanged)');
select ok((select (v ->> 'ok')::boolean and not (v ->> 'applied')::boolean from _t where k = 'o_del') and exists (select 1 from public.inventory_item_options where id = (select (v ->> 'option_id')::uuid from _t where k = 'o1')),
  'a cleaner deleting a product on their new item still goes to the owner (applied false, option kept)');
select ok((select (v ->> 'ok')::boolean and not (v ->> 'applied')::boolean from _t where k = 'o_other') and not exists (select 1 from public.inventory_item_options where item_id = pg_temp.iid('own') and title = 'Zz S125 Other Gel'),
  'another cleaner adding a product to that new item waits (only the person who created it applies at once)');
-- after 40 minutes the creator waits too
update public.inventory_item_changes set created_at = now() - interval '40 minutes' where id = pg_temp.cid('own');
select pg_temp.as_user('12');
insert into _t select 'o_late', pg_temp.try(format($$select public.inventory_option_request_v1(%L, 'add', null, '{"title":"Zz S125 Late Gel","supplier_id":"e1250010-0000-4000-8000-0000000000a1"}', null, 'zz125-opt-key-000008')$$, pg_temp.iid('own')));
select pg_temp.as_user('11');
insert into _t select 'o_admin', pg_temp.try($$select public.inventory_option_request_v1('e1250010-0000-4000-8000-000000000103', 'add', null, '{"title":"Zz S125 Admin Gel","supplier_id":"e1250010-0000-4000-8000-0000000000a1","price":55}', null, 'zz125-opt-key-000009')$$);
reset role;
select ok((select (v ->> 'ok')::boolean and not (v ->> 'applied')::boolean from _t where k = 'o_late') and not exists (select 1 from public.inventory_item_options where title = 'Zz S125 Late Gel'),
  'after 30 minutes even the creator waits for the owner');
select ok((select (v ->> 'ok')::boolean and (v ->> 'applied')::boolean from _t where k = 'o_admin') and (select price = 55 from public.inventory_item_options where title = 'Zz S125 Admin Gel'),
  'an admin adding a product applies at once with a price, as before');

-- 63-70. the catalogue and the history ----------------------------------------------------------------------------------------------------------
select pg_temp.as_user('12');
insert into _t select 'cat_c', pg_temp.try($$select public.get_inventory_catalogue_v1('e1250010-0000-4000-8000-000000000001')$$);
insert into _t select 'h_ed', pg_temp.try(format($$select public.inventory_item_history_v1(%L)$$, pg_temp.iid('ed')));
insert into _t select 'h_ph1', pg_temp.try(format($$select public.inventory_item_history_v1(%L)$$, pg_temp.iid('ph2')));
select pg_temp.as_user('11');
insert into _t select 'h_a1', pg_temp.try(format($$select public.inventory_item_history_v1(%L)$$, pg_temp.iid('a1')));
reset role;
select ok((select e ->> 'updatedKind' = 'created' and e ->> 'updatedBy' = 'Adam' from _t, jsonb_array_elements(v -> 'items') e where k = 'cat_c' and e ->> 'id' = pg_temp.iid('a1')::text),
  'a newly added item reads updatedKind created and updatedBy Adam');
select ok((select e ->> 'updatedKind' = 'details' and e ->> 'updatedBy' = 'Clea' from _t, jsonb_array_elements(v -> 'items') e where k = 'cat_c' and e ->> 'id' = pg_temp.iid('ed')::text),
  'an item edited after it was added reads updatedKind details (the newest change)');
select ok((select e ->> 'updatedKind' = 'photo' from _t, jsonb_array_elements(v -> 'items') e where k = 'cat_c' and e ->> 'id' = pg_temp.iid('ph2')::text),
  'an item whose newest change is a photo reads updatedKind photo');
select ok((select e -> 'updatedKind' = 'null'::jsonb and e -> 'updatedAt' = 'null'::jsonb from _t, jsonb_array_elements(v -> 'items') e where k = 'cat_c' and e ->> 'id' = 'e1250010-0000-4000-8000-000000000101')
      and (select e -> 'updatedKind' = 'null'::jsonb from _t, jsonb_array_elements(v -> 'items') e where k = 'cat_c' and e ->> 'id' = pg_temp.iid('c1')::text),
  'an untouched item and an item whose creation was undone have updatedKind null');
select ok((select position('7.77' in v::text) = 0 and not exists (select 1 from jsonb_array_elements(v -> 'items') e where e ->> 'unitCost' is not null) from _t where k = 'cat_c'),
  'the catalogue read as a cleaner shows no price anywhere');
select ok((select jsonb_array_length(v -> 'changes') = 2 and v #>> '{changes,0,kind}' = 'details' and v #>> '{changes,1,kind}' = 'created' and v #>> '{changes,1,who}' = 'Clea' and v #> '{changes,1,fields}' = '{}'::jsonb
                  and not ((v #> '{changes,1}') ? 'before') from _t where k = 'h_ed'),
  'the history lists a created row as {at, kind created, who, fields {}} below the newer edit');
select ok((select jsonb_array_length(v -> 'changes') = 1 and v #>> '{changes,0,kind}' = 'created' and v #>> '{changes,0,who}' = 'Adam' and v #> '{changes,0,fields}' = '{}'::jsonb from _t where k = 'h_a1'),
  'the owner''s history of an item they added holds one created row with empty fields');
select ok((select jsonb_array_length(v -> 'changes') = 2 and v #>> '{changes,0,kind}' = 'photo' and v #>> '{changes,1,kind}' = 'created' from _t where k = 'h_ph1'),
  'a created row and a photo row sit side by side in the history');
-- no price in any created row
select ok(not exists (select 1 from public.inventory_item_changes c where c.kind = 'created' and (c.before <> '{}'::jsonb or (select array_agg(k order by k) from jsonb_object_keys(c.after) k) is distinct from array['active', 'category', 'name', 'unit']))
      and not exists (select 1 from public.inventory_item_changes c where c.kind = 'created' and (c.after::text ~* 'cost|price' or c.before::text ~* 'cost|price')),
  'no created row ever carries a price or any key beyond name, category, unit and active');
select ok((select count(*) = 0 from public.inventory_item_changes where kind = 'created' and item_id = 'e1250010-0000-4000-8000-000000000103'), 'an item that was not added through the app has no created row');

select * from finish();
rollback;
