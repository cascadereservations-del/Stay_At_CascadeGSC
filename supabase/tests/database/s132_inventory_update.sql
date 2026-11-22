-- Session 132: release s132_inventory_update_20261202 (D-396). The server side of the inventory Update sheet: record_inventory_damage_v1 and its undo, undo_inventory_usage_v1, undo_linen_stain_v1, the laundry
-- recount (report_supply on reconcile / undo / staff movement), the staff supply entry with total paid + receipt photo + note, record_inventory_receipt_v1 p_note, the history notes and sources, linen reason /
-- note / photo, and the lasting default for Kitchen utensils and Appliances. Synthetic fixtures only (uuids e1320000-..., names "Zz S132 ..."); everything rolls back.
-- Fixture rows and the reads run as the owner role (a --no-acl restore gives authenticated no table grants); only the RPC calls run as the staff roles.
-- NOT RUN when it was written (the builder has no local Postgres): the rehearsal (scripts/recovery/p6/migration-rehearsal-on-host.sh <backup> <release.json> <this file>) is the first run.
begin;
select plan(107);

-- baseline grants for a --no-acl rehearsal restore (idempotent, rolled back with the suite)
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt(), auth.role() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
alter role service_role bypassrls;

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal1', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
grant execute on function pg_temp.as_user(uuid) to public;
create function pg_temp.try(p text) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  execute p into r;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
create function pg_temp.id(p text) returns uuid language sql immutable as $$ select ('e1320000-0000-4000-8000-0000000000' || p)::uuid $$;
-- one damage row
create function pg_temp.rw(i text, q int, r text default 'broken', n text default null) returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('item_id', pg_temp.id(i), 'qty', q, 'reason', r, 'note', n))
$$;
-- record_inventory_damage_v1 as the signed-in user; an exception comes back as {err, msg}
create function pg_temp.dm(p_key text, p_rows jsonb, p_photo text default null, p_booking uuid default null, p_list boolean default true, p_note text default null) returns jsonb language plpgsql as $f$
begin
  return public.record_inventory_damage_v1(pg_temp.id('b1'), p_rows, p_photo, p_booking, p_list, 'update', p_note, p_key);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
-- record_inventory_usage, one row, with the client usage_key
create function pg_temp.use(i text, q numeric, k text, n text default 'zz s132 usage note') returns jsonb language plpgsql as $f$
begin
  return public.record_inventory_usage(pg_temp.id('b1'), public.manila_today(), 'Zz Tester', n,
    jsonb_build_array(jsonb_build_object('item_id', pg_temp.id(i), 'used_qty', q, 'usage_key', k)));
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
-- record_linen_stains_v1, one row
create function pg_temp.ln(k text, i text, q int, o text, r text default null, n text default null, ph text default null) returns jsonb language plpgsql as $f$
begin
  return public.record_linen_stains_v1(pg_temp.id('b1'), public.manila_today(), 'Zz Tester', k,
    jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('item_id', pg_temp.id(i), 'qty', q, 'outcome', o, 'reason', r, 'note', n))), ph);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
-- the report id kept under a key
create function pg_temp.rid(k text) returns text language sql stable as $$ select v ->> 'report_id' from _t where _t.k = $1 $$;
-- the history rows of an item, as the owner
create function pg_temp.hist(i text) returns jsonb language sql stable as $$ select public.inventory_item_history_v1(pg_temp.id(i)) -> 'changes' $$;

-- =============================================================================================================================================
-- Fixtures: 01 owner, 02 admin, 03 cleaner, 04 second cleaner, 05 laundry, 06 finance, 07 maintenance, 08 inspector; house b1 (everyone but the owner has access), house b2 unused
-- =============================================================================================================================================
insert into auth.users(id, email) values
  (pg_temp.id('01'), 'zz132-owner@example.com'), (pg_temp.id('02'), 'zz132-admin@example.com'), (pg_temp.id('03'), 'zz132-cleaner@example.com'), (pg_temp.id('04'), 'zz132-cleaner2@example.com'),
  (pg_temp.id('05'), 'zz132-laundry@example.com'), (pg_temp.id('06'), 'zz132-finance@example.com'), (pg_temp.id('07'), 'zz132-maint@example.com'), (pg_temp.id('08'), 'zz132-inspector@example.com');
insert into public.properties(id, name, is_active) values (pg_temp.id('b1'), 'Zz S132 House', true), (pg_temp.id('b2'), 'Zz S132 Other House', true);
insert into public.staff_access_profiles(user_id, role) values
  (pg_temp.id('01'), 'owner'), (pg_temp.id('02'), 'admin'), (pg_temp.id('03'), 'cleaner'), (pg_temp.id('04'), 'cleaner'), (pg_temp.id('05'), 'laundry'),
  (pg_temp.id('06'), 'finance'), (pg_temp.id('07'), 'maintenance'), (pg_temp.id('08'), 'inspector');
insert into public.staff_property_access(user_id, property_id) select pg_temp.id(u), pg_temp.id('b1') from unnest(array['02', '03', '04', '05', '06', '07', '08']) u;
-- c1 whisk 20 (lasting), c2 pan 4 controlled, c3 soap 10 (used up), c4 towel 10 (Linen), c5 spoon 1, c6 fork 1 controlled, c7 bleach 20, c8 tissue 20 controlled, c9 mixer 5,
-- ca ladle 10 (history), cb sheet 6 (Linen, recount), cc to cf: category moves
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, units_per_purchase, movement_controlled_at) values
  (pg_temp.id('c1'), pg_temp.id('b1'), 'Zz S132 Whisk', 'Kitchen utensils', 'pc', 20, false, true, 1, null),
  (pg_temp.id('c2'), pg_temp.id('b1'), 'Zz S132 Pan', 'Kitchen utensils', 'pc', 4, false, true, 1, now()),
  (pg_temp.id('c3'), pg_temp.id('b1'), 'Zz S132 Soap', 'Toiletries', 'pc', 10, true, true, 1, null),
  (pg_temp.id('c4'), pg_temp.id('b1'), 'Zz S132 Towel', 'Linen', 'pc', 10, false, true, 1, null),
  (pg_temp.id('c5'), pg_temp.id('b1'), 'Zz S132 Spoon', 'Kitchen utensils', 'pc', 1, false, true, 1, null),
  (pg_temp.id('c6'), pg_temp.id('b1'), 'Zz S132 Fork', 'Kitchen utensils', 'pc', 1, false, true, 1, now()),
  (pg_temp.id('c7'), pg_temp.id('b1'), 'Zz S132 Bleach', 'Cleaning', 'pc', 20, true, true, 1, null),
  (pg_temp.id('c8'), pg_temp.id('b1'), 'Zz S132 Tissue', 'Toiletries', 'pc', 20, true, true, 1, now()),
  (pg_temp.id('c9'), pg_temp.id('b1'), 'Zz S132 Mixer', 'Toiletries', 'pc', 5, true, true, 1, null),
  (pg_temp.id('ca'), pg_temp.id('b1'), 'Zz S132 Ladle', 'Kitchen utensils', 'pc', 10, false, true, 1, null),
  (pg_temp.id('cb'), pg_temp.id('b1'), 'Zz S132 Sheet', 'Linen', 'pc', 6, false, true, 1, null),
  (pg_temp.id('cc'), pg_temp.id('b1'), 'Zz S132 Brush', 'Toiletries', 'pc', 3, true, true, 1, null),
  (pg_temp.id('cd'), pg_temp.id('b1'), 'Zz S132 Sponge', 'Toiletries', 'pc', 3, true, true, 1, null),
  (pg_temp.id('ce'), pg_temp.id('b1'), 'Zz S132 Mop', 'Toiletries', 'pc', 3, true, true, 1, null),
  (pg_temp.id('cf'), pg_temp.id('b1'), 'Zz S132 Cup', 'Toiletries', 'pc', 3, true, true, 1, null);
-- d1 cloth 1 (used up, clamp test of the usage undo), d2 colander 5 (lasting, bought by the box)
insert into public.inventory_items(id, property_id, name, category, unit, purchase_unit, qty_on_hand, is_consumable, is_active, units_per_purchase, movement_controlled_at) values
  (pg_temp.id('d1'), pg_temp.id('b1'), 'Zz S132 Cloth', 'Toiletries', 'pc', null, 1, true, true, 1, null),
  (pg_temp.id('d2'), pg_temp.id('b1'), 'Zz S132 Colander', 'Kitchen utensils', 'pc', 'box', 5, false, true, 1, null);
insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key) values
  (pg_temp.id('c2'), pg_temp.id('b1'), 'reconcile', 4, 4, 'Baseline count: zz s132 baseline', pg_temp.id('01'), 'zz-s132-baseline-c2-0001'),
  (pg_temp.id('c6'), pg_temp.id('b1'), 'reconcile', 1, 1, 'Baseline count: zz s132 baseline', pg_temp.id('01'), 'zz-s132-baseline-c6-0001'),
  (pg_temp.id('c8'), pg_temp.id('b1'), 'reconcile', 20, 20, 'Baseline count: zz s132 baseline', pg_temp.id('01'), 'zz-s132-baseline-c8-0001');

-- =============================================================================================================================================
-- 1. grants, signatures, the table
-- =============================================================================================================================================
select ok((select bool_and(has_function_privilege('authenticated', s, 'execute') and not has_function_privilege('anon', s, 'execute') and not has_function_privilege('service_role', s, 'execute'))
             from unnest(array['public.record_inventory_damage_v1(uuid,jsonb,text,uuid,boolean,text,text,text)', 'public.undo_inventory_damage_v1(uuid)', 'public.undo_inventory_usage_v1(text)', 'public.undo_linen_stain_v1(text)']) s),
  'grants: the four new functions are authenticated only');
select ok((select bool_and(has_function_privilege('authenticated', s, 'execute') and not has_function_privilege('anon', s, 'execute') and not has_function_privilege('service_role', s, 'execute'))
             from unnest(array['public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid,text)', 'public.inventory_receipt_manual_v1(jsonb,date,text,text,numeric,text,text)',
                               'public.record_linen_stains_v1(uuid,date,text,text,jsonb,text)', 'public.inventory_item_history_v1(uuid)', 'public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)',
                               'public.inventory_undo_v1(uuid,uuid)', 'public.inventory_item_update_v1(uuid,jsonb)']) s),
  'grants: the changed functions keep authenticated only');
select ok(to_regprocedure('public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid)') is null
      and to_regprocedure('public.inventory_receipt_manual_v1(jsonb,date,text,text)') is null
      and to_regprocedure('public.record_linen_stains_v1(uuid,date,text,text,jsonb)') is null, 'the three old signatures are gone (no ambiguous overload)');
select ok(not has_function_privilege('authenticated', 'public.s_inventory_purchase_note_v1(text)', 'execute')
      and not has_table_privilege('authenticated', 'public.inventory_damage_reports', 'select')
      and not has_table_privilege('anon', 'public.inventory_damage_reports', 'insert')
      and (select c.relrowsecurity from pg_class c where c.oid = 'public.inventory_damage_reports'::regclass), 'the damage table: RLS on, no API grant; the history helper has no grant');

-- =============================================================================================================================================
-- 2. damage: roles
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('01')); insert into _t select 'dm_role_owner', pg_temp.dm('zz-s132-dmg-owner-0001', jsonb_build_array(pg_temp.rw('c1', 1))); reset role;
select pg_temp.as_user(pg_temp.id('02')); insert into _t select 'dm_role_admin', pg_temp.dm('zz-s132-dmg-admin-0001', jsonb_build_array(pg_temp.rw('c1', 1))); reset role;
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'dm_role_cleaner', pg_temp.dm('zz-s132-dmg-cleaner-0001', jsonb_build_array(pg_temp.rw('c1', 1))); reset role;
select pg_temp.as_user(pg_temp.id('05')); insert into _t select 'dm_role_laundry', pg_temp.dm('zz-s132-dmg-laundry-0001', jsonb_build_array(pg_temp.rw('c1', 1))); reset role;
select pg_temp.as_user(pg_temp.id('08')); insert into _t select 'dm_role_inspector', pg_temp.dm('zz-s132-dmg-inspector-0001', jsonb_build_array(pg_temp.rw('c1', 1))); reset role;
select pg_temp.as_user(pg_temp.id('06')); insert into _t select 'dm_fin', pg_temp.dm('zz-s132-dmg-finance-0001', jsonb_build_array(pg_temp.rw('c1', 1))); reset role;
select pg_temp.as_user(pg_temp.id('07')); insert into _t select 'dm_mnt', pg_temp.dm('zz-s132-dmg-maint-0001', jsonb_build_array(pg_temp.rw('c1', 1))); reset role;
select is((select string_agg(k || ':' || (v ->> 'ok'), ',' order by k) from _t where left(k, 8) = 'dm_role_'),
  'dm_role_admin:true,dm_role_cleaner:true,dm_role_inspector:true,dm_role_laundry:true,dm_role_owner:true', 'damage: owner, admin, cleaner, laundry and inspector may report');
select ok((select bool_and((v ->> 'ok') = 'false' and (v ->> 'reason') = 'not_allowed') from _t where k in ('dm_fin', 'dm_mnt')), 'damage: finance and maintenance are refused (not_allowed)');
select is((select qty_on_hand from public.inventory_items where id = pg_temp.id('c1')), 15::numeric, 'damage: five reports of 1 took the whisk from 20 to 15, the refused ones changed nothing');

-- the refusals of the whole call
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'dm_cons', pg_temp.dm('zz-s132-dmg-cons-0001', jsonb_build_array(pg_temp.rw('c3', 1)));
insert into _t select 'dm_lin', pg_temp.dm('zz-s132-dmg-linen-0001', jsonb_build_array(pg_temp.rw('c4', 1)));
insert into _t select 'dm_mix', pg_temp.dm('zz-s132-dmg-mixed-0001', jsonb_build_array(pg_temp.rw('c1', 1), pg_temp.rw('c3', 1)));
insert into _t select 'dm_q0', pg_temp.dm('zz-s132-dmg-q0-000001', jsonb_build_array(pg_temp.rw('c1', 0)));
insert into _t select 'dm_q100', pg_temp.dm('zz-s132-dmg-q100-00001', jsonb_build_array(pg_temp.rw('c1', 100)));
insert into _t select 'dm_badreason', pg_temp.dm('zz-s132-dmg-reason-0001', jsonb_build_array(pg_temp.rw('c1', 1, 'smashed')));
reset role;
select is((select (v ->> 'reason') from _t where k = 'dm_cons'), 'consumable_item', 'damage: a used-up (consumable) item is refused: consumable_item');
select is((select (v ->> 'reason') from _t where k = 'dm_lin'), 'linen_item', 'damage: a linen item is refused: linen_item');
select ok((select (v ->> 'reason') = 'consumable_item' from _t where k = 'dm_mix') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c1')) = 15
      and not exists (select 1 from public.inventory_damage_reports where idempotency_key = 'zz-s132-dmg-mixed-0001'), 'damage: one bad row refuses the whole call and writes nothing');
select is((select string_agg(k || ':' || (v ->> 'reason'), ',' order by k) from _t where k in ('dm_q0', 'dm_q100', 'dm_badreason')),
  'dm_badreason:rows_invalid,dm_q0:qty_invalid,dm_q100:qty_invalid', 'damage: qty 0 and 100 are qty_invalid, an unknown reason is rows_invalid');

-- =============================================================================================================================================
-- 3. damage: clamp, ledger, audit, shopping list, task, idempotency
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'dm_clamp_u', pg_temp.dm('zz-s132-dmg-clampu-0001', jsonb_build_array(pg_temp.rw('c5', 3, 'missing')));
insert into _t select 'dm_clamp_c', pg_temp.dm('zz-s132-dmg-clampc-0001', jsonb_build_array(pg_temp.rw('c6', 2, 'broken')));
insert into _t select 'dm_ctl', pg_temp.dm('zz-s132-dmg-ctl-000001', jsonb_build_array(pg_temp.rw('c2', 1, 'broken', 'zz s132 pan handle')));
reset role;
select ok((select (v -> 'rows' -> 0 ->> 'clamped')::boolean and (v -> 'rows' -> 0 ->> 'before')::numeric = 1 and (v -> 'rows' -> 0 ->> 'after')::numeric = 0 from _t where k = 'dm_clamp_u')
      and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c5')) = 0, 'clamp (not controlled): 3 missing from 1 leaves 0 and says clamped');
select is((select count(*)::int from public.inventory_audit_log where entity_id = pg_temp.id('c5') and action = 'damage' and (before ->> 'qty_on_hand')::numeric = 1 and (after ->> 'qty_on_hand')::numeric = 0), 1,
  'clamp (not controlled): one audit row 1 -> 0 (inventory_qty_at_v1 reads it)');
select ok((select (v -> 'rows' -> 0 ->> 'clamped')::boolean and (v -> 'rows' -> 0 ->> 'after')::numeric = 0 from _t where k = 'dm_clamp_c')
      and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c6')) = 0
      and exists (select 1 from public.inventory_stock_movements m where m.item_id = pg_temp.id('c6') and m.kind = 'adjustment' and m.quantity_before = 1 and m.quantity_after = 0 and m.reason like 'Damage broken%'),
  'clamp (controlled): 2 broken from 1 leaves 0 and the ledger has the adjustment 1 -> 0');
select ok((select qty_on_hand from public.inventory_items where id = pg_temp.id('c2')) = 3
      and exists (select 1 from public.inventory_stock_movements m where m.item_id = pg_temp.id('c2') and m.kind = 'adjustment' and m.quantity_before = 4 and m.quantity_after = 3 and m.actor_user_id = pg_temp.id('03'))
      and (select quantity_after from public.inventory_stock_movements where item_id = pg_temp.id('c2') order by sequence_no desc limit 1) = 3, 'controlled pan: 4 -> 3, one movement by the actor, ledger and shelf agree');
select ok((select count(*) = 1 from public.inventory_shopping_list s where s.item_id = pg_temp.id('c2') and s.status = 'proposed' and s.quantity = 1 and s.idempotency_key like 'damage-' || pg_temp.rid('dm_ctl') || '-%'),
  'shopping list: the replacement is proposed (a table, so a row)');
select ok((select count(*) = 1 and min(s.purchase_unit) = 'pc' from public.inventory_shopping_list s where s.idempotency_key like 'damage-' || pg_temp.rid('dm_ctl') || '-%'),
  'shopping list: an item with no pack name is bought in its unit (pc)');
select ok((select count(*) = 1 and min(t.title) like 'Damage reported: 1 x Zz S132 Pan (broken)%' and min(t.detail) like '%zz s132 pan handle%' and min(t.status) = 'open'
             from public.follow_up_tasks t where t.source_kind = 'inventory_damage' and t.source_ref = pg_temp.rid('dm_ctl')), 'task: ONE open follow-up for the report, naming the item, the quantity, the reason and the note');

-- idempotent key
select pg_temp.as_user(pg_temp.id('01')); insert into _t select 'dm_dup', pg_temp.dm('zz-s132-dmg-owner-0001', jsonb_build_array(pg_temp.rw('c1', 1))); reset role;
select ok((select (v ->> 'duplicate')::boolean and (v ->> 'report_id') = pg_temp.rid('dm_role_owner') from _t where k = 'dm_dup')
      and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c1')) = 15
      and (select count(*) from public.inventory_damage_reports where idempotency_key = 'zz-s132-dmg-owner-0001') = 1, 'idempotent: the same key says duplicate, the same report, no second write');
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'dm_reuse', pg_temp.dm('zz-s132-dmg-owner-0001', jsonb_build_array(pg_temp.rw('c1', 1))); reset role;
select is((select v ->> 'err' from _t where k = 'dm_reuse'), '22023', 'idempotent: another person sending the same key is refused (idempotency_key_reused)');

-- a guest stay, no shopping row
select pg_temp.as_user(pg_temp.id('02'));
insert into _t select 'dm_guest', pg_temp.dm('zz-s132-dmg-guest-0001', jsonb_build_array(pg_temp.rw('ca', 1, 'broken', 'zz s132 hist damage')), 'zz/s132/photo1.jpg', pg_temp.id('f1'), false, 'zz s132 guest broke it');
reset role;
select ok((select count(*) = 1 and min(t.title) like 'Damage during a guest stay:%' and min(t.detail) like '%guest stay%' and min(t.detail) like '%zz s132 guest broke it%' and min(t.detail) like '%photo%'
             from public.follow_up_tasks t where t.source_kind = 'inventory_damage' and t.source_ref = pg_temp.rid('dm_guest'))
      and (select photo_path = 'zz/s132/photo1.jpg' and booking_id = pg_temp.id('f1') and note = 'zz s132 guest broke it' and source = 'update' and reason = 'broken' from public.inventory_damage_reports where id = pg_temp.rid('dm_guest')::uuid),
  'guest stay: the task says so; the report keeps photo, booking, note, source and the first row''s reason');
select is((select count(*)::int from public.inventory_shopping_list s where s.idempotency_key like 'damage-' || pg_temp.rid('dm_guest') || '-%'), 0, 'p_add_to_list false: no shopping row');
-- F4 (free text of the task goes through staff_redact_v1) and F5 (the shopping row is bought in the pack name)
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'dm_red', pg_temp.dm('zz-s132-dmg-redact-0001', jsonb_build_array(pg_temp.rw('d2', 1, 'broken', 'call 0917 123 4567')), null, null, true, 'mail zz-s132@example.com');
reset role;
select ok((select count(*) = 1 and min(t.detail) like '%[hidden]%' and min(t.detail) not like '%0917%' and min(t.detail) not like '%example.com%'
             from public.follow_up_tasks t where t.source_kind = 'inventory_damage' and t.source_ref = pg_temp.rid('dm_red')),
  'damage task text: a phone number (row note) and an e-mail (report note) are hidden by staff_redact_v1');
select ok((select count(*) = 1 and min(s.purchase_unit) = 'box' from public.inventory_shopping_list s where s.idempotency_key like 'damage-' || pg_temp.rid('dm_red') || '-%'),
  'shopping list: an item with a pack name (box) is bought in it');

-- =============================================================================================================================================
-- 4. damage: undo (15 minutes for the actor, manage_inventory any time)
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'u1', pg_temp.dm('zz-s132-dmg-undo1-0001', jsonb_build_array(pg_temp.rw('c1', 2, 'missing', 'zz s132 undone note')));
insert into _t select 'u2', pg_temp.dm('zz-s132-dmg-undo2-0001', jsonb_build_array(pg_temp.rw('c1', 1)));
insert into _t select 'u3', pg_temp.dm('zz-s132-dmg-undo3-0001', jsonb_build_array(pg_temp.rw('c1', 1)));
reset role;
select is((select qty_on_hand from public.inventory_items where id = pg_temp.id('c1')), 11::numeric, 'before the undos: the whisk is at 15 - 4 = 11');
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'u1_undo', pg_temp.try(format('select public.undo_inventory_damage_v1(%L::uuid)', pg_temp.rid('u1'))); reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'u1_undo') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c1')) = 13
      and (select undone_at is not null from public.inventory_damage_reports where id = pg_temp.rid('u1')::uuid)
      and (select count(*) from public.inventory_audit_log where entity_id = pg_temp.id('c1') and action = 'damage_undo' and (before ->> 'qty_on_hand')::numeric = 11 and (after ->> 'qty_on_hand')::numeric = 13) = 1,
  'undo (actor, inside 15 minutes): stock 11 -> 13, undone_at set, an audit row for inventory_qty_at_v1');
select ok((select count(*) = 1 and min(s.status) = 'cancelled' from public.inventory_shopping_list s where s.idempotency_key like 'damage-' || pg_temp.rid('u1') || '-%')
      and (select status from public.follow_up_tasks where source_kind = 'inventory_damage' and source_ref = pg_temp.rid('u1')) = 'cancelled', 'undo: the proposed replacement is cancelled and the task is closed');
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'u1_again', pg_temp.try(format('select public.undo_inventory_damage_v1(%L::uuid)', pg_temp.rid('u1'))); reset role;
select is((select v ->> 'reason' from _t where k = 'u1_again'), 'already_undone', 'undo twice: already_undone');
select pg_temp.as_user(pg_temp.id('04')); insert into _t select 'u2_other', pg_temp.try(format('select public.undo_inventory_damage_v1(%L::uuid)', pg_temp.rid('u2'))); reset role;
select is((select v ->> 'reason' from _t where k = 'u2_other'), 'not_allowed', 'undo by another cleaner: not_allowed');
select pg_temp.as_user(pg_temp.id('06')); insert into _t select 'u2_fin', pg_temp.try(format('select public.undo_inventory_damage_v1(%L::uuid)', pg_temp.rid('u2'))); reset role;
select is((select v ->> 'reason' from _t where k = 'u2_fin'), 'not_allowed', 'undo by finance: not_allowed');
update public.inventory_damage_reports set created_at = now() - interval '20 minutes' where id = pg_temp.rid('u2')::uuid;
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'u2_late', pg_temp.try(format('select public.undo_inventory_damage_v1(%L::uuid)', pg_temp.rid('u2'))); reset role;
select is((select v ->> 'reason' from _t where k = 'u2_late'), 'too_late', 'undo by the actor after 15 minutes: too_late');
select pg_temp.as_user(pg_temp.id('01')); insert into _t select 'u2_owner', pg_temp.try(format('select public.undo_inventory_damage_v1(%L::uuid)', pg_temp.rid('u2'))); reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'u2_owner') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c1')) = 14, 'undo by manage_inventory after 15 minutes: ok, stock 13 -> 14');
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'u_none', pg_temp.try(format('select public.undo_inventory_damage_v1(%L::uuid)', pg_temp.id('f9'))); reset role;
select is((select v ->> 'reason' from _t where k = 'u_none'), 'not_found', 'undo of an unknown report: not_found');
-- a controlled item: the ledger gets the compensating adjustment
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'u_ctl', pg_temp.try(format('select public.undo_inventory_damage_v1(%L::uuid)', pg_temp.rid('dm_ctl'))); reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'u_ctl') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c2')) = 4
      and (select quantity_after from public.inventory_stock_movements where item_id = pg_temp.id('c2') order by sequence_no desc limit 1) = 4
      and exists (select 1 from public.inventory_stock_movements m where m.item_id = pg_temp.id('c2') and m.reason like 'Undo damage report%' and m.quantity_before = 3 and m.quantity_after = 4),
  'undo (controlled pan): 3 -> 4 through one adjustment, shelf and ledger agree');

-- =============================================================================================================================================
-- 5. laundry recount and its undo
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('05'));
insert into _t select 'rc_laundry', pg_temp.try(format('select public.reconcile_inventory_baseline_v1(%L::uuid, 7, %L, %L)', pg_temp.id('cb'), 'zz s132 laundry recount', 'zz-s132-recount-laundry-0001'));
reset role;
select ok((select (v ->> 'ok')::boolean and (v ->> 'variance')::numeric = 1 from _t where k = 'rc_laundry') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('cb')) = 7
      and exists (select 1 from public.inventory_stock_movements m where m.item_id = pg_temp.id('cb') and m.kind = 'reconcile' and m.actor_user_id = pg_temp.id('05') and m.quantity_after = 7), 'laundry recount: allowed, 6 -> 7, one reconcile movement by the laundry user');
select pg_temp.as_user(pg_temp.id('05'));
insert into _t select 'rc_undo', pg_temp.try(format('select public.inventory_undo_v1(%L::uuid, null)', (select m.id from public.inventory_stock_movements m where m.item_id = pg_temp.id('cb') order by m.sequence_no desc limit 1)));
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'rc_undo') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('cb')) = 6, 'laundry undo of the recount: ok, 7 -> 6');
select pg_temp.as_user(pg_temp.id('06'));
insert into _t select 'rc_fin', pg_temp.try(format('select public.reconcile_inventory_baseline_v1(%L::uuid, 9, %L, %L)', pg_temp.id('cb'), 'zz s132 finance recount', 'zz-s132-recount-finance-0001'));
insert into _t select 'rc_mnt_undo', pg_temp.try(format('select public.inventory_undo_v1(%L::uuid, null)', (select m.id from public.inventory_stock_movements m where m.item_id = pg_temp.id('cb') order by m.sequence_no desc limit 1)));
reset role;
select is((select v ->> 'err' from _t where k = 'rc_fin'), '42501', 'finance recount: refused 42501');
select is((select v ->> 'err' from _t where k = 'rc_mnt_undo'), '42501', 'finance undo of a count: refused 42501');

-- =============================================================================================================================================
-- 6. usage undo
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'us1', pg_temp.use('c7', 3, 'zz-s132-use-0001-aaaa');
insert into _t select 'us2', pg_temp.use('c7', 2, 'zz-s132-use-0002-aaaa');
insert into _t select 'us3', pg_temp.use('c7', 1, 'zz-s132-use-0003-aaaa');
insert into _t select 'us_ctl', pg_temp.use('c8', 5, 'zz-s132-use-0004-aaaa');
reset role;
select ok((select qty_on_hand from public.inventory_items where id = pg_temp.id('c7')) = 14 and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c8')) = 15, 'before the usage undos: bleach 20 - 6 = 14, tissue 20 - 5 = 15');
select pg_temp.as_user(pg_temp.id('06')); insert into _t select 'uu_fin', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-0001-aaaa')); reset role;
select is((select v ->> 'reason' from _t where k = 'uu_fin'), 'not_allowed', 'usage undo by finance: not_allowed');
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'uu1', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-0001-aaaa')); reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'uu1') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c7')) = 17
      and (select u.removed_qty = 3 and u.undone_at is not null and u.used_qty = 0 and u.undone_qty = 3 from public.inventory_usage u where u.notes like '%zz-s132-use-0001-aaaa%'),
  'usage undo (not controlled): stock 14 -> 17, the usage row stays as a tombstone (removed_qty 3, undone_at set, used_qty 0, undone_qty 3)');
select ok((select count(*) = 1 and bool_and((before ->> 'qty_on_hand')::numeric = 14 and (after ->> 'qty_on_hand')::numeric = 17) from public.inventory_audit_log where entity_id = pg_temp.id('c7') and action = 'usage_undo'),
  'usage undo: one audit row with the REAL shelf before (14) and after (17) the restore, so inventory_qty_at_v1 can see the window between the use and the undo (F8)');
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'uu1_again', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-0001-aaaa')); reset role;
select is((select v ->> 'reason' from _t where k = 'uu1_again'), 'already_undone', 'usage undo twice: already_undone');
select pg_temp.as_user(pg_temp.id('04')); insert into _t select 'uu2_other', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-0002-aaaa')); reset role;
select is((select v ->> 'reason' from _t where k = 'uu2_other'), 'not_allowed', 'usage undo by another cleaner: not_allowed');
update public.inventory_usage set created_at = now() - interval '20 minutes' where notes like '%zz-s132-use-0002-aaaa%';
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'uu2_late', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-0002-aaaa')); reset role;
select pg_temp.as_user(pg_temp.id('01')); insert into _t select 'uu2_owner', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-0002-aaaa')); reset role;
select ok((select v ->> 'reason' from _t where k = 'uu2_late') = 'too_late' and (select (v ->> 'ok')::boolean from _t where k = 'uu2_owner') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c7')) = 19,
  'usage undo after 15 minutes: too_late for the actor, ok for manage_inventory (17 -> 19)');
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'uu_ctl', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-0004-aaaa')); reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'uu_ctl') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c8')) = 20
      and (select quantity_after from public.inventory_stock_movements where item_id = pg_temp.id('c8') order by sequence_no desc limit 1) = 20
      and exists (select 1 from public.inventory_stock_movements m where m.item_id = pg_temp.id('c8') and m.reason like 'Undo usage%' and m.quantity_before = 15 and m.quantity_after = 20),
  'usage undo (controlled tissue): 15 -> 20 through one compensating movement, shelf and ledger agree');
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'uu_none', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-nope-aaaa')); reset role;
select is((select v ->> 'reason' from _t where k = 'uu_none'), 'not_found', 'usage undo of an unknown key: not_found');

-- F1: stock 1, a use of 3 clamps at 0 and takes 1; the undo puts back 1, not 3
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'uc_use', pg_temp.use('d1', 3, 'zz-s132-use-0005-aaaa'); reset role;
select ok((select qty_on_hand from public.inventory_items where id = pg_temp.id('d1')) = 0
      and (select u.removed_qty = 1 and u.used_qty = 3 from public.inventory_usage u where u.notes like '%zz-s132-use-0005-aaaa%'),
  'usage clamp: stock 1, a use of 3 leaves 0 and the row records that it took 1 (removed_qty)');
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'uc_undo', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-0005-aaaa')); reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'uc_undo') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('d1')) = 1,
  'usage undo of a clamped use: stock back to 1 (what was taken), not 3');
-- F7: the tombstone keeps the key, so the same usage_key sent again is a replay
select ok((select u.undone_at is not null and u.used_qty = 0 and u.undone_qty = 3 and u.notes like '%[key:zz-s132-use-0005-aaaa]%' from public.inventory_usage u where u.notes like '%zz-s132-use-0005-aaaa%'),
  'usage undo keeps a tombstone: undone_at set, used_qty 0, undone_qty 3, the key note stays');
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'uc_replay', pg_temp.use('d1', 3, 'zz-s132-use-0005-aaaa'); reset role;
select ok((select (v ->> 'ok')::boolean and (v ->> 'rows')::int = 1 from _t where k = 'uc_replay') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('d1')) = 1
      and (select count(*) = 1 and min(u.used_qty) = 0 from public.inventory_usage u where u.notes like '%zz-s132-use-0005-aaaa%'),
  'the same usage_key sent again after the undo is a replay: stock stays 1, no second usage row, the tombstone stays at 0');
-- the readers that count rows or days skip the undone row (the sums see used_qty 0)
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'uc_cat', pg_temp.try(format('select public.get_inventory_catalogue_v1(%L::uuid) -> %L', pg_temp.id('b1'), 'items'));
insert into _t select 'uc_mov', pg_temp.try(format('select public.get_inventory_item_moves_v1(%L::uuid) -> %L', pg_temp.id('d1'), 'usage'));
insert into _t select 'uc_hist', pg_temp.try(format('select pg_temp.hist(%L)', 'd1'));
reset role;
select ok((select (e ->> 'usageDays')::int = 0 and (e ->> 'usage30d')::numeric = 0 from jsonb_array_elements((select v from _t where k = 'uc_cat')) e where e ->> 'id' = pg_temp.id('d1')::text)
      and jsonb_array_length((select v from _t where k = 'uc_mov')) = 0
      and not exists (select 1 from jsonb_array_elements((select v from _t where k = 'uc_hist')) c where c ->> 'source' = 'usage'),
  'readers: an undone use is not counted by the catalogue (days and sum), the item moves list or the history');

-- =============================================================================================================================================
-- 6b. round 3: stock at a past time after an undo (F8), a direct insert (F9), the legacy median (F10), null and no-movement undo (F11), the lock (F13), the trigger function (F14)
--     Fixtures: e1 pail 10 (qty_at), e2 qty null (null undo), e3 controlled 4 (use without a movement), e4 5 (forged insert), e5 10 (median). The transaction clock is frozen, so every stamp below is set by hand.
-- =============================================================================================================================================
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, units_per_purchase, movement_controlled_at) values
  (pg_temp.id('e1'), pg_temp.id('b1'), 'Zz S132 Pail', 'Cleaning', 'pc', 10, true, true, 1, null),
  (pg_temp.id('e3'), pg_temp.id('b1'), 'Zz S132 Funnel', 'Cleaning', 'pc', 4, true, true, 1, now()),
  (pg_temp.id('e4'), pg_temp.id('b1'), 'Zz S132 Sieve', 'Cleaning', 'pc', 5, true, true, 1, null),
  (pg_temp.id('e5'), pg_temp.id('b1'), 'Zz S132 Rag', 'Cleaning', 'pc', 10, true, true, 1, null);
insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key) values
  (pg_temp.id('e3'), pg_temp.id('b1'), 'reconcile', 4, 4, 'Baseline count: zz s132 baseline', pg_temp.id('01'), 'zz-s132-baseline-e3-0001');
-- F8: stock 10, a use of 3 at t1 (3 hours ago), its undo at t2 (1 hour ago)
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'q_use', pg_temp.use('e1', 3, 'zz-s132-use-q1-aaaa-0001'); reset role;
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'q_undo', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-q1-aaaa-0001')); reset role;
update public.inventory_usage set created_at = now() - interval '3 hours' where notes like '%zz-s132-use-q1-aaaa-0001%';
update public.inventory_audit_log set created_at = now() - interval '1 hour' where entity_id = pg_temp.id('e1') and action = 'usage_undo';
select is(public.inventory_qty_at_v1(pg_temp.id('e1'), now() - interval '4 hours'), 10::numeric, 'qty_at before the use (T < t1): stock S = 10');
select is(public.inventory_qty_at_v1(pg_temp.id('e1'), now() - interval '2 hours'), 7::numeric, 'qty_at between the use and its undo (t1 < T < t2): S - r = 7');
select is(public.inventory_qty_at_v1(pg_temp.id('e1'), now() - interval '30 minutes'), 10::numeric, 'qty_at after the undo (T > t2): S = 10');
-- a controlled item still reads the ledger: baseline 20 -> use 20 -> 15 -> undo 15 -> 20 (c8, section 6)
update public.inventory_stock_movements set created_at = now() - interval '5 hours' where item_id = pg_temp.id('c8') and reason like 'Baseline%';
update public.inventory_stock_movements set created_at = now() - interval '4 hours' where item_id = pg_temp.id('c8') and kind = 'usage';
update public.inventory_stock_movements set created_at = now() - interval '3 hours' where item_id = pg_temp.id('c8') and reason like 'Undo usage%';
select ok(public.inventory_qty_at_v1(pg_temp.id('c8'), now() - interval '4 hours 30 minutes') = 20 and public.inventory_qty_at_v1(pg_temp.id('c8'), now() - interval '3 hours 30 minutes') = 15
      and public.inventory_qty_at_v1(pg_temp.id('c8'), now() - interval '2 hours') = 20, 'qty_at (controlled tissue): 20 before the use, 15 between the use and the undo, 20 after');
-- F9: a direct REST insert (authenticated has INSERT on inventory_usage live; a --no-acl restore has no grant, so the suite gives it, and a permissive insert policy, both rolled back)
grant insert on table public.inventory_usage to authenticated;
create policy zz_s132_forge on public.inventory_usage for insert to authenticated with check (true);
select pg_temp.as_user(pg_temp.id('03'));
insert into public.inventory_usage(item_id, used_qty, session_date, logged_by, notes, property_id, submitted_by_user_id)
values (pg_temp.id('e4'), 4, public.manila_today(), 'Zz Forger', 'zz s132 forged [key:zz-s132-forge-0001-aaaa]', pg_temp.id('b1'), pg_temp.id('03'));
reset role;
select ok((select u.removed_qty = 0 and u.used_qty = 4 from public.inventory_usage u where u.notes like '%zz-s132-forge-0001-aaaa%') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('e4')) = 5,
  'direct insert as authenticated: the row records removed_qty 0 (it never lowered the shelf), the shelf stays 5');
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'forge_undo', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-forge-0001-aaaa')); reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'forge_undo') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('e4')) = 5, 'undo of a forged row restores 0: the shelf stays 5, stock cannot be raised that way');
-- F10: the legacy median skips a tombstone (live rows 4 and 6 -> 5; the undone 2 must not pull it to 4)
insert into public.inventory_usage(item_id, used_qty, session_date, logged_by, notes, property_id) values
  (pg_temp.id('e5'), 4, public.manila_today(), 'Zz Tester', 'zz s132 median a', pg_temp.id('b1')), (pg_temp.id('e5'), 6, public.manila_today(), 'Zz Tester', 'zz s132 median b', pg_temp.id('b1'));
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'med_use', pg_temp.use('e5', 2, 'zz-s132-use-med1-aaaa-0001'); reset role;
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'med_undo', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-med1-aaaa-0001')); reset role;
select is((select m.median_used from public.get_usage_medians() m where m.item_id = pg_temp.id('e5')), 5.00::numeric, 'get_usage_medians: an undone use (tombstone, used_qty 0) does not lower the median (4 and 6 -> 5)');
-- F11: a null qty_on_hand is never turned into 0 (the column is NOT NULL live; the suite drops that for this check and puts it back)
alter table public.inventory_items alter column qty_on_hand drop not null;
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, units_per_purchase, movement_controlled_at)
values (pg_temp.id('e2'), pg_temp.id('b1'), 'Zz S132 Brush Null', 'Cleaning', 'pc', null, true, true, 1, null);
insert into public.inventory_usage(item_id, used_qty, session_date, logged_by, notes, property_id, submitted_by_user_id)
values (pg_temp.id('e2'), 2, public.manila_today(), 'Zz Tester', 'zz s132 null [key:zz-s132-use-null-aaaa-0001]', pg_temp.id('b1'), pg_temp.id('03'));
update public.inventory_usage set removed_qty = 2 where notes like '%zz-s132-use-null-aaaa-0001%';
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'null_undo', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-null-aaaa-0001')); reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'null_undo') and (select qty_on_hand is null from public.inventory_items where id = pg_temp.id('e2'))
      and (select u.undone_at is not null from public.inventory_usage u where u.notes like '%zz-s132-use-null-aaaa-0001%'), 'usage undo of an item with no shelf figure (null): ok, the shelf stays null, not 0');
delete from public.inventory_audit_log where entity_id = pg_temp.id('e2');
delete from public.inventory_usage where item_id = pg_temp.id('e2');
delete from public.inventory_items where id = pg_temp.id('e2');
alter table public.inventory_items alter column qty_on_hand set not null;
-- F11: an item that is controlled now but whose use has no movement: the undo writes one adjustment of removed_qty (the owner insert fills removed_qty 2 for a controlled item)
insert into public.inventory_usage(item_id, used_qty, session_date, logged_by, notes, property_id, submitted_by_user_id)
values (pg_temp.id('e3'), 2, public.manila_today(), 'Zz Tester', 'zz s132 nomove [key:zz-s132-use-nomv-aaaa-0001]', pg_temp.id('b1'), pg_temp.id('03'));
-- F16: the use happened before the item became controlled (controlled at now(), the use 2 minutes earlier)
update public.inventory_usage set created_at = now() - interval '2 minutes' where notes like '%zz-s132-use-nomv-aaaa-0001%';
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'nomv_undo', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-nomv-aaaa-0001')); reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'nomv_undo') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('e3')) = 6
      and (select quantity_after from public.inventory_stock_movements where item_id = pg_temp.id('e3') order by sequence_no desc limit 1) = 6
      and exists (select 1 from public.inventory_stock_movements m where m.item_id = pg_temp.id('e3') and m.kind = 'adjustment' and m.reason like 'Undo usage%' and m.quantity_before = 4 and m.quantity_after = 6),
  'usage undo (controlled now, no movement for the use): one adjustment 4 -> 6 for removed_qty, shelf and ledger agree');
-- F16: a use inserted AFTER control with no movement took nothing off the shelf: its undo restores 0
insert into public.inventory_usage(item_id, used_qty, session_date, logged_by, notes, property_id, submitted_by_user_id)
values (pg_temp.id('e3'), 2, public.manila_today(), 'Zz Tester', 'zz s132 nomove2 [key:zz-s132-use-nomv-aaaa-0002]', pg_temp.id('b1'), pg_temp.id('03'));
update public.inventory_usage set created_at = now() + interval '1 minute' where notes like '%zz-s132-use-nomv-aaaa-0002%';
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'nomv2_undo', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-nomv-aaaa-0002')); reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'nomv2_undo') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('e3')) = 6
      and (select quantity_after from public.inventory_stock_movements where item_id = pg_temp.id('e3') order by sequence_no desc limit 1) = 6,
  'usage undo (inserted after control, no movement): restores 0, shelf and ledger stay 6');
-- F13: the first phase locks the usage rows
select ok((select position('from public.inventory_usage where id = v_id for update' in replace(p.prosrc, chr(13), '')) > 0 from pg_proc p where p.oid = to_regprocedure('public.undo_inventory_usage_v1(text)')),
  'undo_inventory_usage_v1 locks the usage row (for update) before it checks and restores');
-- F14: the trigger function is internal: no grant to anon, authenticated or service_role, search_path pinned, and SECURITY INVOKER by design (it reads current_user to tell a REST insert from record_inventory_usage)
select ok(not has_function_privilege('anon', 'public.s_inventory_usage_removed_v1()', 'execute') and not has_function_privilege('authenticated', 'public.s_inventory_usage_removed_v1()', 'execute')
      and not has_function_privilege('service_role', 'public.s_inventory_usage_removed_v1()', 'execute')
      and (select not p.prosecdef and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = to_regprocedure('public.s_inventory_usage_removed_v1()'))
      and exists (select 1 from pg_trigger t where t.tgrelid = 'public.inventory_usage'::regclass and t.tgname = 'inventory_usage_removed_v1' and t.tgenabled = 'O'),
  'trigger function s_inventory_usage_removed_v1: no EXECUTE for anon / authenticated / service_role, security invoker, search_path pinned, trigger enabled');

-- =============================================================================================================================================
-- 7. staff supply entry: total paid, receipt photo, note; the admin receipt note
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'rcpt', pg_temp.try(format('select public.inventory_receipt_manual_v1(%L::jsonb, null, %L, %L, 450.5, %L, %L)',
  jsonb_build_array(jsonb_build_object('item_id', pg_temp.id('c9'), 'qty_units', 3))::text, 'Zz Vendor', 'zz-s132-rcpt-key-0001', 'zz/receipts/s132-r1.jpg', 'zz s132 receipt note'));
reset role;
select ok((select (v ->> 'ok')::boolean and (v ->> 'purchase_count')::int = 1 from _t where k = 'rcpt') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c9')) = 8, 'staff supply entry: ok, 5 + 3 = 8');
select ok((select d.total = 450.50 and d.receipt_path = 'zz/receipts/s132-r1.jpg' and d.note = 'zz s132 receipt note' and d.status = 'confirmed' from public.inventory_receipt_drafts d where d.id = (select (v ->> 'draft_id')::uuid from _t where k = 'rcpt')),
  'staff supply entry: the draft row stores the total paid, the receipt photo and the note');
select ok((select p.receipt_path = 'zz/receipts/s132-r1.jpg' and p.notes like 'Staff receipt [key:%' from public.inventory_purchases p where p.item_id = pg_temp.id('c9') order by p.created_at desc limit 1)
      and not exists (select 1 from public.transactions x where x.ocr_raw ->> 'draft_id' = (select v ->> 'draft_id' from _t where k = 'rcpt')), 'staff supply entry: the purchase row carries the photo; still no finance transaction');
select ok((select t.detail like '%Paid PHP 450.50%' and t.detail like '%receipt photo%' and t.detail like '%zz s132 receipt note%' and t.title like '%with a receipt photo%' and t.status = 'open'
             from public.follow_up_tasks t where t.source_kind = 'receipt_review' and t.source_ref = (select v ->> 'draft_id' from _t where k = 'rcpt')), 'staff supply entry: the owner/admin task says Paid PHP 450.50 and that a receipt is attached');
select pg_temp.as_user(pg_temp.id('05'));
insert into _t select 'rcpt_old', pg_temp.try(format('select public.inventory_receipt_manual_v1(%L::jsonb, null, null, %L)', jsonb_build_array(jsonb_build_object('item_id', pg_temp.id('c9'), 'qty_units', 1))::text, 'zz-s132-rcpt-key-0002'));
insert into _t select 'rcpt_neg', pg_temp.try(format('select public.inventory_receipt_manual_v1(%L::jsonb, null, null, %L, -5)', jsonb_build_array(jsonb_build_object('item_id', pg_temp.id('c9'), 'qty_units', 1))::text, 'zz-s132-rcpt-key-0003'));
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'rcpt_old') and (select t.detail like '%with no receipt photo%' and t.detail not like '%Paid%' from public.follow_up_tasks t where t.source_kind = 'receipt_review' and t.source_ref = (select v ->> 'draft_id' from _t where k = 'rcpt_old')),
  'staff supply entry: the old 4-argument call still works (laundry), the task is unchanged');
select is((select v ->> 'err' from _t where k = 'rcpt_neg'), '22023', 'staff supply entry: a negative total paid is refused 22023');
select pg_temp.as_user(pg_temp.id('06'));
insert into _t select 'rcpt_fin', pg_temp.try(format('select public.inventory_receipt_manual_v1(%L::jsonb, null, null, %L, 10)', jsonb_build_array(jsonb_build_object('item_id', pg_temp.id('c9'), 'qty_units', 1))::text, 'zz-s132-rcpt-key-0004'));
reset role;
select is((select v ->> 'error' from _t where k = 'rcpt_fin'), 'forbidden', 'staff supply entry: finance is refused (forbidden)');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'adm_rcpt', pg_temp.try(format('select public.record_inventory_receipt_v1(%L::uuid, 1, null, %L, null, null, null, %L, null, %L)', pg_temp.id('ca'), 'Zz Vendor', 'zz-s132-admrc-key-0001', 'zz s132 admin note'));
insert into _t select 'adm_rcpt8', pg_temp.try(format('select public.record_inventory_receipt_v1(%L::uuid, 1, null, %L, null, null, null, %L)', pg_temp.id('c3'), 'Zz Vendor', 'zz-s132-admrc-key-0002'));
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'adm_rcpt') and exists (select 1 from public.inventory_purchases p where p.item_id = pg_temp.id('ca') and p.notes = 'Admin receipt [key:zz-s132-admrc-key-0001] zz s132 admin note'),
  'admin receipt: p_note is stored after the key tag');
select ok((select (v ->> 'ok')::boolean from _t where k = 'adm_rcpt8') and exists (select 1 from public.inventory_purchases p where p.item_id = pg_temp.id('c3') and p.notes = 'Admin receipt [key:zz-s132-admrc-key-0002]'),
  'admin receipt: a call with the old 8 arguments still works and the notes are as before');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'adm_undo', pg_temp.try(format('select public.inventory_undo_v1(null, %L::uuid)', (select p.id from public.inventory_purchases p where p.item_id = pg_temp.id('c3') order by p.created_at desc limit 1)));
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'adm_undo'), 'admin receipt: the undo still finds a receipt with a note after the key tag');

-- =============================================================================================================================================
-- 8. linen: laundry allowed, reason / note / photo stored, undo reduces the task
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('05')); insert into _t select 'ln1', pg_temp.ln('zz-s132-linen-key-0001', 'c4', 2, 'needs_replacing', 'damaged', 'zz s132 linen note', 'zz/s132/linen1.jpg'); reset role;
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'ln2', pg_temp.ln('zz-s132-linen-key-0002', 'c4', 1, 'needs_replacing', 'stained'); reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'ln1') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c4')) = 7, 'linen: a laundry worker may report (10 - 2 - 1 = 7 after both reports)');
select ok((select r.reason = 'damaged' and r.note = 'zz s132 linen note' and r.photo_path = 'zz/s132/linen1.jpg' and r.outcome = 'needs_replacing' and r.qty = 2 from public.linen_stain_reports r where r.idempotency_key = 'zz-s132-linen-key-0001'),
  'linen: reason, note and photo are stored on the report row');
select ok((select count(*) = 1 and min(t.title) like 'Replace 3 x Zz S132 Towel, stained on %' and min(t.detail) not like '%Note:%'
             from public.follow_up_tasks t where t.source_kind = 'linen_replace' and t.source_ref like pg_temp.id('c4')::text || ':%' and t.status = 'open'), 'linen: the two reports feed ONE task for 3 towels');
select pg_temp.as_user(pg_temp.id('04')); insert into _t select 'ln_other', pg_temp.try(format('select public.undo_linen_stain_v1(%L)', 'zz-s132-linen-key-0002')); reset role;
select is((select v ->> 'reason' from _t where k = 'ln_other'), 'not_allowed', 'linen undo by another cleaner: not_allowed');
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'ln2_undo', pg_temp.try(format('select public.undo_linen_stain_v1(%L)', 'zz-s132-linen-key-0002')); reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'ln2_undo') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c4')) = 8
      and (select r.undone_at is not null from public.linen_stain_reports r where r.idempotency_key = 'zz-s132-linen-key-0002')
      and (select t.title from public.follow_up_tasks t where t.source_kind = 'linen_replace' and t.source_ref like pg_temp.id('c4')::text || ':%' and t.status = 'open') like 'Replace 2 x Zz S132 Towel, damaged on %',
  'linen undo (actor, inside 15 minutes): stock 7 -> 8, the report is undone, the open task now says 2 towels');
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'ln2_again', pg_temp.try(format('select public.undo_linen_stain_v1(%L)', 'zz-s132-linen-key-0002')); reset role;
select is((select v ->> 'reason' from _t where k = 'ln2_again'), 'already_undone', 'linen undo twice: already_undone');
update public.linen_stain_reports set created_at = now() - interval '20 minutes' where idempotency_key = 'zz-s132-linen-key-0001';
select pg_temp.as_user(pg_temp.id('05')); insert into _t select 'ln1_late', pg_temp.try(format('select public.undo_linen_stain_v1(%L)', 'zz-s132-linen-key-0001')); reset role;
select pg_temp.as_user(pg_temp.id('01')); insert into _t select 'ln1_owner', pg_temp.try(format('select public.undo_linen_stain_v1(%L)', 'zz-s132-linen-key-0001')); reset role;
select ok((select v ->> 'reason' from _t where k = 'ln1_late') = 'too_late' and (select (v ->> 'ok')::boolean from _t where k = 'ln1_owner') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('c4')) = 10
      and (select count(*) from public.follow_up_tasks t where t.source_kind = 'linen_replace' and t.source_ref like pg_temp.id('c4')::text || ':%' and t.status in ('open', 'in_progress')) = 0,
  'linen undo after 15 minutes: too_late for the laundry worker, ok for manage_inventory; stock is back to 10 and the task is closed');
select pg_temp.as_user(pg_temp.id('06')); insert into _t select 'ln_fin', pg_temp.ln('zz-s132-linen-key-0003', 'c4', 1, 'cleaned'); insert into _t select 'ln_fin_undo', pg_temp.try(format('select public.undo_linen_stain_v1(%L)', 'zz-s132-linen-key-0002')); reset role;
select ok((select v ->> 'err' from _t where k = 'ln_fin') = '42501' and (select v ->> 'reason' from _t where k = 'ln_fin_undo') = 'not_allowed', 'linen: finance is refused for the report (42501) and for the undo (not_allowed)');
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'ln_badreason', pg_temp.ln('zz-s132-linen-key-0004', 'c4', 1, 'cleaned', 'ripped'); insert into _t select 'ln_old5', public.record_linen_stains_v1(pg_temp.id('b1'), public.manila_today(), 'Zz Tester', 'zz-s132-linen-key-0005', jsonb_build_array(jsonb_build_object('item_id', pg_temp.id('c4'), 'qty', 1, 'outcome', 'cleaned'))); reset role;
select ok((select v ->> 'err' from _t where k = 'ln_badreason') = '22023' and (select (v ->> 'ok')::boolean from _t where k = 'ln_old5')
      and (select r.reason is null and r.note is null and r.photo_path is null from public.linen_stain_reports r where r.idempotency_key = 'zz-s132-linen-key-0005'),
  'linen: an unknown reason is refused 22023; the old 5-argument call still works and stores nulls');

-- F4 (the linen task text goes through staff_redact_v1) and F6 (a cleaned row stays in the history, kind cleaned, before = after)
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'ln_red', pg_temp.ln('zz-s132-linen-red-0001', 'cb', 1, 'needs_replacing', 'stained', 'call 0917 123 4567');
insert into _t select 'ln_clean', pg_temp.ln('zz-s132-linen-clean-001', 'cb', 1, 'cleaned', null, 'zz s132 cleaned note');
reset role;
select pg_temp.as_user(pg_temp.id('01')); insert into _t select 'h_cb', pg_temp.try(format('select pg_temp.hist(%L)', 'cb')); reset role;
select ok((select count(*) = 1 and min(t.detail) like '%[hidden]%' and min(t.detail) not like '%0917%'
             from public.follow_up_tasks t where t.source_kind = 'linen_replace' and t.source_ref like pg_temp.id('cb')::text || ':%' and t.status = 'open'),
  'linen task text: a phone number in the note is hidden by staff_redact_v1');
select ok(exists (select 1 from jsonb_array_elements((select v from _t where k = 'h_cb')) c
                   where c ->> 'source' = 'linen' and c ->> 'kind' = 'cleaned' and c ->> 'before' = c ->> 'after' and c ->> 'note' = 'zz s132 cleaned note'),
  'history: a cleaned linen row stays, source linen, kind cleaned, before = after');

-- =============================================================================================================================================
-- 9. history: note and source on every row, all five sources
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'h_use', pg_temp.use('ca', 1, 'zz-s132-hist-use-0001', 'zz s132 hist usage'); reset role;
select pg_temp.as_user(pg_temp.id('05')); insert into _t select 'h_lin', pg_temp.ln('zz-s132-hist-linen-0001', 'ca', 1, 'needs_replacing', 'stained', 'zz s132 hist linen'); reset role;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'h_count', pg_temp.try(format('select public.reconcile_inventory_baseline_v1(%L::uuid, 5, %L, %L)', pg_temp.id('c2'), 'zz s132 hist count', 'zz-s132-hist-count-0001'));
insert into _t select 'h_ladle', pg_temp.try(format('select pg_temp.hist(%L)', 'ca'));
insert into _t select 'h_pan', pg_temp.try(format('select pg_temp.hist(%L)', 'c2'));
insert into _t select 'h_mixer', pg_temp.try(format('select pg_temp.hist(%L)', 'c9'));
insert into _t select 'h_whisk', pg_temp.try(format('select pg_temp.hist(%L)', 'c1'));
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'h_count') and exists (select 1 from jsonb_array_elements((select v from _t where k = 'h_pan')) c where c ->> 'source' = 'count' and c ->> 'note' = 'zz s132 hist count'),
  'history: a count carries its note, source count');
select ok(exists (select 1 from jsonb_array_elements((select v from _t where k = 'h_ladle')) c where c ->> 'source' = 'usage' and c ->> 'note' = 'zz s132 hist usage'), 'history: a usage line carries its note, source usage');
select ok(exists (select 1 from jsonb_array_elements((select v from _t where k = 'h_ladle')) c where c ->> 'source' = 'receipt' and c ->> 'note' = 'zz s132 admin note'), 'history: an admin receipt carries its note, source receipt');
select ok(exists (select 1 from jsonb_array_elements((select v from _t where k = 'h_ladle')) c where c ->> 'source' = 'damage' and c ->> 'note' = 'zz s132 hist damage' and c ->> 'kind' = 'broken'), 'history: a damage report carries the row note, source damage');
select ok(exists (select 1 from jsonb_array_elements((select v from _t where k = 'h_ladle')) c where c ->> 'source' = 'linen' and c ->> 'note' = 'zz s132 hist linen' and c ->> 'kind' = 'stained'), 'history: a linen report carries its note, source linen');
select ok(exists (select 1 from jsonb_array_elements((select v from _t where k = 'h_mixer')) c where c ->> 'source' = 'receipt' and c ->> 'note' = 'zz s132 receipt note'), 'history: a staff supply entry carries the note typed with it');
select ok((select bool_and(c ? 'note' and c ? 'source' and c ? 'at' and c ? 'kind' and (c ->> 'source') in ('count', 'usage', 'receipt', 'damage', 'linen', 'edit')) from jsonb_array_elements((select v from _t where k = 'h_ladle')) c),
  'history: every row has at, kind, note and a source from the six allowed');
select ok((select array_agg(c ->> 'at' order by ord) = array_agg(c ->> 'at' order by (c ->> 'at')::timestamptz desc, ord) from jsonb_array_elements((select v from _t where k = 'h_ladle')) with ordinality e(c, ord)), 'history: newest first');
select ok(not exists (select 1 from jsonb_array_elements((select v from _t where k = 'h_whisk')) c where c ->> 'note' = 'zz s132 undone note'), 'history: an undone damage report is not listed');

-- =============================================================================================================================================
-- 10. the lasting default for Kitchen utensils and Appliances
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'cr_app', pg_temp.try(format('select public.inventory_item_create_v1(%L::uuid, %L::jsonb, null, null, %L)', pg_temp.id('b1'), '{"name":"Zz S132 Kettle","category":"Appliances"}', 'zz-s132-create-key-0001'));
insert into _t select 'cr_ute', pg_temp.try(format('select public.inventory_item_create_v1(%L::uuid, %L::jsonb, null, null, %L)', pg_temp.id('b1'), '{"name":"Zz S132 Grater","category":"Kitchen utensils"}', 'zz-s132-create-key-0002'));
insert into _t select 'up_app', pg_temp.try(format('select public.inventory_item_update_v1(%L::uuid, %L::jsonb)', pg_temp.id('cc'), '{"category":"Appliances"}'));
insert into _t select 'up_app_c', pg_temp.try(format('select public.inventory_item_update_v1(%L::uuid, %L::jsonb)', pg_temp.id('cd'), '{"category":"Appliances","consumable":true}'));
insert into _t select 'up_other', pg_temp.try(format('select public.inventory_item_update_v1(%L::uuid, %L::jsonb)', pg_temp.id('ce'), '{"category":"Cleaning"}'));
reset role;
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'up_cleaner', pg_temp.try(format('select public.inventory_item_update_v1(%L::uuid, %L::jsonb)', pg_temp.id('cf'), '{"category":"Kitchen utensils"}')); reset role;
select ok((select coalesce(bool_and(i.is_consumable = false), false) and count(*) = 2 from public.inventory_items i where i.property_id = pg_temp.id('b1') and i.name in ('Zz S132 Kettle', 'Zz S132 Grater')),
  'create: an Appliances or Kitchen utensils item with no consumable sent is lasting');
select ok((select (v ->> 'ok')::boolean from _t where k = 'up_app') and (select not is_consumable from public.inventory_items where id = pg_temp.id('cc')), 'update: a move into Appliances with no consumable sent makes the item lasting');
select ok((select is_consumable from public.inventory_items where id = pg_temp.id('cd')) and (select category from public.inventory_items where id = pg_temp.id('cd')) = 'Appliances', 'update: an explicit consumable true is kept');
select ok((select is_consumable from public.inventory_items where id = pg_temp.id('ce')) and (select category from public.inventory_items where id = pg_temp.id('ce')) = 'Cleaning', 'update: a move into another group changes nothing else');
select ok((select (v ->> 'ok')::boolean from _t where k = 'up_cleaner') and (select category = 'Kitchen utensils' and is_consumable from public.inventory_items where id = pg_temp.id('cf')),
  'update: a cleaner moving an item into Kitchen utensils changes the group only, is_consumable stays (the default is manage_inventory only)');

-- =============================================================================================================================================
-- 10b. round 2: laundry "Used up", the undo of a created item after an undone use, the same item twice in one usage call
-- =============================================================================================================================================
-- d3 pad 5 and d4 liner 2 (used up, not controlled)
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, units_per_purchase, movement_controlled_at) values
  (pg_temp.id('d3'), pg_temp.id('b1'), 'Zz S132 Pad', 'Toiletries', 'pc', 5, true, true, 1, null),
  (pg_temp.id('d4'), pg_temp.id('b1'), 'Zz S132 Liner', 'Toiletries', 'pc', 2, true, true, 1, null);
-- contract rev 1: record_inventory_usage accepts report_supply (laundry); finance is refused 42501
select pg_temp.as_user(pg_temp.id('05')); insert into _t select 'r2_ul', pg_temp.use('d3', 1, 'zz-s132-use-r2-laundry-aaaa'); reset role;
select pg_temp.as_user(pg_temp.id('06')); insert into _t select 'r2_uf', pg_temp.use('d3', 1, 'zz-s132-use-r2-finance-aaaa'); reset role;
select ok((select (v ->> 'ok')::boolean and (v ->> 'rows')::int = 1 from _t where k = 'r2_ul') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('d3')) = 4
      and (select count(*) = 1 and min(u.removed_qty) = 1 from public.inventory_usage u where u.notes like '%zz-s132-use-r2-laundry-aaaa%'),
  'usage: a laundry worker (report_supply) records Used up, stock 5 -> 4, one usage row');
select ok((select v ->> 'err' = '42501' from _t where k = 'r2_uf') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('d3')) = 4
      and not exists (select 1 from public.inventory_usage u where u.notes like '%zz-s132-use-r2-finance-aaaa%'),
  'usage: finance is refused 42501 and writes nothing');
select ok(has_function_privilege('authenticated', 'public.record_inventory_usage(uuid,date,text,text,jsonb)', 'execute') and has_function_privilege('service_role', 'public.record_inventory_usage(uuid,date,text,text,jsonb)', 'execute')
      and not has_function_privilege('anon', 'public.record_inventory_usage(uuid,date,text,text,jsonb)', 'execute'),
  'usage: record_inventory_usage keeps its grants (authenticated and service_role, not anon)');
-- inventory_item_change_undo_v1: a created item whose only use was undone can be undone; a live use still blocks it
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r2_n1', pg_temp.try(format('select public.inventory_item_create_v1(%L::uuid, %L::jsonb)', pg_temp.id('b1'), '{"name":"Zz S132 R2 Pad One","category":"Toiletries","unit":"pc","consumable":true}'));
insert into _t select 'r2_n2', pg_temp.try(format('select public.inventory_item_create_v1(%L::uuid, %L::jsonb)', pg_temp.id('b1'), '{"name":"Zz S132 R2 Pad Two","category":"Toiletries","unit":"pc","consumable":true}'));
reset role;
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'r2_a1', pg_temp.try(format('select public.record_inventory_usage(%L::uuid, public.manila_today(), %L, %L, %L::jsonb)', pg_temp.id('b1'), 'Zz Tester', 'zz s132 r2',
  jsonb_build_array(jsonb_build_object('item_id', (select v ->> 'item_id' from _t where k = 'r2_n1'), 'used_qty', 1, 'usage_key', 'zz-s132-use-r2-n1-aaaa'))));
insert into _t select 'r2_a2', pg_temp.try(format('select public.record_inventory_usage(%L::uuid, public.manila_today(), %L, %L, %L::jsonb)', pg_temp.id('b1'), 'Zz Tester', 'zz s132 r2',
  jsonb_build_array(jsonb_build_object('item_id', (select v ->> 'item_id' from _t where k = 'r2_n2'), 'used_qty', 1, 'usage_key', 'zz-s132-use-r2-n2-aaaa'))));
reset role;
-- the transaction clock is frozen: stamp both usage rows after the create rows (their created_at is clock_timestamp()) so "used since the add" is true for them
update public.inventory_usage set created_at = clock_timestamp() where notes like '%zz-s132-use-r2-n%';
select pg_temp.as_user(pg_temp.id('03')); insert into _t select 'r2_ua', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-r2-n1-aaaa')); reset role;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r2_c1', pg_temp.try(format('select public.inventory_item_change_undo_v1(%L::uuid)', (select v ->> 'change_id' from _t where k = 'r2_n1')));
insert into _t select 'r2_c2', pg_temp.try(format('select public.inventory_item_change_undo_v1(%L::uuid)', (select v ->> 'change_id' from _t where k = 'r2_n2')));
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'r2_ua') and (select (v ->> 'ok')::boolean and v ->> 'kind' = 'created' from _t where k = 'r2_c1')
      and (select not is_active from public.inventory_items where id = ((select v ->> 'item_id' from _t where k = 'r2_n1'))::uuid),
  'change undo: a created item whose only use was undone is undone (the tombstone is not "used since the add")');
select ok((select v ->> 'reason' = 'changed_since' from _t where k = 'r2_c2') and (select is_active from public.inventory_items where id = ((select v ->> 'item_id' from _t where k = 'r2_n2'))::uuid),
  'change undo: a created item with a live use is still refused changed_since and stays active');
-- one usage call with the same item twice: stock 2, a use of 2 and a use of 2 (the second finds the shelf already at 0 and takes nothing)
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'r2_tw', pg_temp.try(format('select public.record_inventory_usage(%L::uuid, public.manila_today(), %L, %L, %L::jsonb)', pg_temp.id('b1'), 'Zz Tester', 'zz s132 twice',
  jsonb_build_array(jsonb_build_object('item_id', pg_temp.id('d4'), 'used_qty', 2, 'usage_key', 'zz-s132-use-r2-tw1-aaaa'), jsonb_build_object('item_id', pg_temp.id('d4'), 'used_qty', 2, 'usage_key', 'zz-s132-use-r2-tw2-aaaa'))));
reset role;
select ok((select (v ->> 'ok')::boolean and (v ->> 'rows')::int = 2 from _t where k = 'r2_tw') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('d4')) = 0
      and (select count(*) = 2 and sum(u.removed_qty) = 2 and sum(u.used_qty) = 4 from public.inventory_usage u where u.item_id = pg_temp.id('d4')),
  'usage twice in one call: stock 2 -> 0, the two rows took 2 in total (removed_qty 2 and 0), not 4');
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'r2_tu1', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-r2-tw1-aaaa'));
insert into _t select 'r2_tu2', pg_temp.try(format('select public.undo_inventory_usage_v1(%L)', 'zz-s132-use-r2-tw2-aaaa'));
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'r2_tu1') and (select (v ->> 'ok')::boolean from _t where k = 'r2_tu2') and (select qty_on_hand from public.inventory_items where id = pg_temp.id('d4')) = 2,
  'usage twice in one call: undoing both puts back 2 (what was taken), not 4');

-- =============================================================================================================================================
-- 11. finance is refused everywhere (one line over what the sections above showed)
-- =============================================================================================================================================
select ok((select (v ->> 'reason') = 'not_allowed' from _t where k = 'dm_fin') and (select (v ->> 'reason') = 'not_allowed' from _t where k = 'u2_fin') and (select (v ->> 'reason') = 'not_allowed' from _t where k = 'uu_fin')
      and (select (v ->> 'err') = '42501' from _t where k = 'rc_fin') and (select (v ->> 'error') = 'forbidden' from _t where k = 'rcpt_fin') and (select (v ->> 'err') = '42501' from _t where k = 'ln_fin'),
  'finance: damage, damage undo, usage undo, recount, supply entry and linen are all refused');

select * from finish();
rollback;
