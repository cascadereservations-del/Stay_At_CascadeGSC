-- Session 133: release s133_option_stock_20261203 (D-399 to D-402). Per-product stock: the options column and the clamp trigger, inventory_option_count_v1, inventory_receipt_lines_v1, inventory_option_use_v1,
-- inventory_group_update_v1, inventory_item_history_v2, the relaxed product link / photo rules, the options read with qty_on_hand, and inventory_log_v1 (contract 5). Synthetic fixtures only (uuids e1330000-...,
-- names "Zz S133 ..."); everything rolls back. Fixture rows and the reads run as the owner role (a --no-acl restore gives authenticated no table grants); only the RPC calls run as the staff roles.
-- NOT RUN when it was written (the builder has no local Postgres and no pgTAP): the rehearsal (scripts/recovery/p6/migration-rehearsal-on-host.sh <backup> <release.json> <this file>) is the first run.
-- The same functions were run (not through pgTAP) against a stub schema in PGlite: count, trigger, receipt split, use, group rollback, payload and table checks, and the log paging and filters all passed there.
begin;
select plan(87);

-- baseline grants for a --no-acl rehearsal restore (idempotent, rolled back with the suite)
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt(), auth.role() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
alter role service_role bypassrls;

create function pg_temp.as_user(p_uid uuid, p_aal text default 'aal1') returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', p_aal, 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
grant execute on function pg_temp.as_user(uuid, text) to public;
create function pg_temp.try(p text) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  execute p into r;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
create function pg_temp.id(p text) returns uuid language sql immutable as $$ select ('e1330000-0000-4000-8000-0000000000' || p)::uuid $$;
create function pg_temp.q(p_item uuid) returns numeric language sql stable as $$ select qty_on_hand from public.inventory_items where id = p_item $$;
create function pg_temp.oq(p_opt uuid) returns numeric language sql stable as $$ select qty_on_hand from public.inventory_item_options where id = p_opt $$;
create function pg_temp.keys(p_rows jsonb) returns text language sql immutable as $$
  select coalesce(string_agg(e.value ->> 'at' || '|' || (e.value ->> 'kind') || '|' || (e.value ->> 'item_id') || '|' || coalesce(e.value ->> 'qty_before', '-') || '|' || coalesce(e.value ->> 'qty_after', '-') || '|' || coalesce(e.value ->> 'source_note', '-'), ',' order by e.ord), '')
  from jsonb_array_elements(p_rows) with ordinality e(value, ord)
$$;
-- paging helper: 2 rows at a time, joined by the cursor (a page is extended to finish a run of rows with one timestamp)
create function pg_temp.pages(p_old boolean) returns text language plpgsql as $f$
declare cur timestamptz := null; pg jsonb; acc text := ''; n integer := 0;
begin
  loop
    pg := public.inventory_log_v1(pg_temp.id('b1'), cur, 2, null, null, p_old);
    acc := acc || case when acc = '' then '' else ',' end || pg_temp.keys(pg -> 'rows');
    n := n + 1;
    exit when pg ->> 'next_before' is null or n > 200;
    cur := (pg ->> 'next_before')::timestamptz;
  end loop;
  return acc;
end $f$;
grant execute on function pg_temp.pages(boolean), pg_temp.keys(jsonb), pg_temp.q(uuid), pg_temp.oq(uuid), pg_temp.id(text), pg_temp.try(text) to public;
create temp table _t(k text primary key, v jsonb);
grant all on _t to public;

-- =============================================================================================================================================
-- Fixtures: 01 owner, 03 cleaner, 04 outsider (staff, no access to the house); house b1, house b2 (its own item e1 is used to check the property wall)
--   a1 Tissue 20 (pack 12 units, 5 per unit; options o1 Sofia pack 12 price 120 usual, o2 Presto pack 6 price 70)   a2 Soap 3   a3 Cloth 5   a4 Salt 4   a5 Rice 2
--   e1 Other house item 3
-- =============================================================================================================================================
insert into auth.users(id, email) values (pg_temp.id('01'), 'zz133-owner@example.com'), (pg_temp.id('03'), 'zz133-cleaner@example.com'), (pg_temp.id('04'), 'zz133-outsider@example.com');
insert into public.properties(id, name, is_active) values (pg_temp.id('b1'), 'Zz S133 House', true), (pg_temp.id('b2'), 'Zz S133 Other House', true);
insert into public.staff_access_profiles(user_id, role) values (pg_temp.id('01'), 'owner'), (pg_temp.id('03'), 'cleaner'), (pg_temp.id('04'), 'cleaner');
insert into public.staff_property_access(user_id, property_id) values (pg_temp.id('03'), pg_temp.id('b1'));
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, units_per_purchase, unit_cost, purchase_unit) values
  (pg_temp.id('a1'), pg_temp.id('b1'), 'Zz S133 Tissue', 'Toiletries', 'roll', 20, true, true, 12, 5, 'pack'),
  (pg_temp.id('a2'), pg_temp.id('b1'), 'Zz S133 Soap', 'Toiletries', 'pc', 3, true, true, 1, 20, null),
  (pg_temp.id('a3'), pg_temp.id('b1'), 'Zz S133 Cloth', 'Toiletries', 'pc', 5, true, true, 1, 10, null),
  (pg_temp.id('a4'), pg_temp.id('b1'), 'Zz S133 Salt', 'Kitchen', 'pc', 4, true, true, 1, 8, null),
  (pg_temp.id('a5'), pg_temp.id('b1'), 'Zz S133 Rice', 'Kitchen', 'pc', 2, true, true, 1, 50, null),
  (pg_temp.id('e1'), pg_temp.id('b2'), 'Zz S133 Other', 'Kitchen', 'pc', 3, true, true, 1, 1, null);
insert into public.inventory_suppliers(id, property_id, name, payment_method) values (pg_temp.id('d1'), pg_temp.id('b1'), 'Zz S133 Shop', 'cash');
insert into public.inventory_item_options(id, property_id, item_id, supplier_id, title, brand, pack_size, price, is_usual) values
  (pg_temp.id('f1'), pg_temp.id('b1'), pg_temp.id('a1'), pg_temp.id('d1'), 'Sofia 12', 'Sofia', 12, 120, true),
  (pg_temp.id('f2'), pg_temp.id('b1'), pg_temp.id('a1'), pg_temp.id('d1'), 'Presto 6', 'Presto', 6, 70, false),
  (pg_temp.id('f3'), pg_temp.id('b1'), pg_temp.id('a2'), pg_temp.id('d1'), 'Zz Soap Bar', 'Zz', 1, 20, true);

-- =============================================================================================================================================
-- 1. schema, grants, Rule 0
-- =============================================================================================================================================
select ok((select count(*) = 2 from information_schema.columns where table_schema = 'public' and ((table_name = 'inventory_item_options' and column_name = 'qty_on_hand') or (table_name = 'inventory_purchases' and column_name = 'option_id'))),
  'the two new columns exist');
select ok((select count(*) = 6 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('inventory_option_count_v1', 'inventory_receipt_lines_v1', 'inventory_option_use_v1', 'inventory_group_update_v1', 'inventory_item_history_v2', 'inventory_log_v1')),
  'the six new callable functions exist');
select ok((select bool_and(has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute') and not has_function_privilege('service_role', p.oid, 'execute'))
             from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('inventory_option_count_v1', 'inventory_receipt_lines_v1', 'inventory_option_use_v1', 'inventory_group_update_v1', 'inventory_item_history_v2', 'inventory_log_v1')),
  'the new functions are authenticated only');
select ok((select bool_and(not has_function_privilege('anon', p.oid, 'execute') and not has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('service_role', p.oid, 'execute'))
             from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('s_inventory_option_clamp_v1', 's_inventory_derive_key_v1', 's_inventory_option_payload_v1')),
  'the internal functions have no grant to any client role');
select ok((select count(*) = 1 from pg_trigger t where t.tgrelid = 'public.inventory_items'::regclass and t.tgname = 'inventory_items_option_clamp_v1' and t.tgenabled = 'O'),
  'the clamp trigger is on and enabled');
select ok((select count(*) = 10 and bool_and(md5(replace(p.prosrc, chr(13), '')) = e.m)
             from (values ('public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)'::regprocedure, 'fdeaf212bebc578ee82f9240e6c05417'), ('public.record_inventory_usage(uuid,date,text,text,jsonb)'::regprocedure, '365f7c6d50258a611612465e4ad3624b'),
                          ('public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid,text)'::regprocedure, 'd190f6b6051be034e9e9babb99cbbf56'),
                          ('public.inventory_receipt_manual_v1(jsonb,date,text,text,numeric,text,text)'::regprocedure, '8c407320edbbc9d944a86461bef23adf'),
                          ('public.record_inventory_damage_v1(uuid,jsonb,text,uuid,boolean,text,text,text)'::regprocedure, '5e8e9bb09ce488f86566236d32620a01'),
                          ('public.undo_inventory_damage_v1(uuid)'::regprocedure, 'bbb566116e036671a30fa15f1c2ba1e7'), ('public.undo_inventory_usage_v1(text)'::regprocedure, '77de62aa768dc56b9c711beb9c10e49f'),
                          ('public.undo_linen_stain_v1(text)'::regprocedure, '5d6fdd96f8fd8e3a53ca158f3859d9e1'), ('public.inventory_undo_v1(uuid,uuid)'::regprocedure, '5125463a4d686d5a180f1ee599fa00b7'),
                          ('public.inventory_item_history_v1(uuid)'::regprocedure, 'bbf90cfbd5f97158307e12502ae1223e')) e(f, m) join pg_proc p on p.oid = e.f),
  'Rule 0: the released s132 functions (and history v1) are byte-identical');
select is(pg_temp.try($$update public.inventory_item_options set qty_on_hand = -1 where id = 'e1330000-0000-4000-8000-0000000000f1' returning 1$$) ->> 'err', '23514', 'a negative option quantity is refused by the check');

-- =============================================================================================================================================
-- 2. inventory_option_count_v1 and the clamp trigger
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'cnt1', public.inventory_option_count_v1(pg_temp.id('a1'), jsonb_build_array(jsonb_build_object('option_id', pg_temp.id('f1'), 'qty', 6), jsonb_build_object('option_id', pg_temp.id('f2'), 'qty', 3)), 2, 'shelf', 'zz133-count-0000000001');
insert into _t select 'cnt1b', public.inventory_option_count_v1(pg_temp.id('a1'), jsonb_build_array(jsonb_build_object('option_id', pg_temp.id('f1'), 'qty', 6), jsonb_build_object('option_id', pg_temp.id('f2'), 'qty', 3)), 2, 'shelf', 'zz133-count-0000000001');
insert into _t select 'cnt_over', public.inventory_option_count_v1(pg_temp.id('a1'), jsonb_build_array(jsonb_build_object('option_id', pg_temp.id('f1'), 'qty', 9)), 0, 'x', 'zz133-count-0000000002');
reset role;
select ok((select (v ->> 'ok')::boolean and (v ->> 'total')::numeric = 11 from _t where k = 'cnt1') and pg_temp.q(pg_temp.id('a1')) = 11 and pg_temp.oq(pg_temp.id('f1')) = 6 and pg_temp.oq(pg_temp.id('f2')) = 3,
  'count: the options and the item total (6 + 3 + 2 not sorted = 11) are saved');
select ok((select v ->> 'replayed' = 'true' from _t where k = 'cnt1b') and pg_temp.q(pg_temp.id('a1')) = 11 and pg_temp.oq(pg_temp.id('f1')) = 6, 'count: the same key again changes nothing and says replayed');
select ok((select v ->> 'ok' = 'false' and v ->> 'error' = 'counts_exceed' from _t where k = 'cnt_over') and pg_temp.q(pg_temp.id('a1')) = 11 and pg_temp.oq(pg_temp.id('f2')) = 3,
  'count: options not listed that would not fit under the new total return counts_exceed and change nothing');
select pg_temp.as_user(pg_temp.id('01'));
select is(pg_temp.try($$select public.inventory_option_count_v1('e1330000-0000-4000-8000-0000000000a1', '[{"option_id":"e1330000-0000-4000-8000-0000000000f3","qty":1}]'::jsonb, 0, 'x', 'zz133-count-0000000003')$$) ->> 'err', '22023', 'count: an option of another item is refused');
select is(pg_temp.try($$select public.inventory_option_count_v1('e1330000-0000-4000-8000-0000000000a1', '[{"option_id":"e1330000-0000-4000-8000-0000000000f1","qty":-1}]'::jsonb, 0, 'x', 'zz133-count-0000000004')$$) ->> 'err', '22023', 'count: a negative quantity is refused');
select is(pg_temp.try($$select public.inventory_option_count_v1('e1330000-0000-4000-8000-0000000000a1', '[{"option_id":"e1330000-0000-4000-8000-0000000000f1","qty":1},{"option_id":"e1330000-0000-4000-8000-0000000000f1","qty":2}]'::jsonb, 0, 'x', 'zz133-count-0000000005')$$) ->> 'err', '22023', 'count: an option listed twice is refused');
select is(pg_temp.try($$select public.inventory_option_count_v1('e1330000-0000-4000-8000-0000000000a1', '[]'::jsonb, 0, 'x', 'short')$$) ->> 'err', '22023', 'count: a key under 16 characters is refused');
select pg_temp.as_user(pg_temp.id('04'));
select is(pg_temp.try($$select public.inventory_option_count_v1('e1330000-0000-4000-8000-0000000000a1', '[]'::jsonb, 0, 'x', 'zz133-count-0000000006')$$) ->> 'err', '42501', 'count: staff without access to the house are refused');
reset role;
-- the trigger: the item falls below the options' sum (usual option first, then the larger), and rises without touching the options
update public.inventory_items set qty_on_hand = 7 where id = pg_temp.id('a1');
select ok(pg_temp.oq(pg_temp.id('f1')) = 4 and pg_temp.oq(pg_temp.id('f2')) = 3, 'trigger: the item falls 11 to 7: the usual option gives up 2 first (4 and 3)');
update public.inventory_items set qty_on_hand = 1 where id = pg_temp.id('a1');
select ok(pg_temp.oq(pg_temp.id('f1')) + pg_temp.oq(pg_temp.id('f2')) = 1 and pg_temp.oq(pg_temp.id('f1')) = 0, 'trigger: the item falls to 1: the options never add up to more than the item (usual emptied first)');
update public.inventory_items set qty_on_hand = 30 where id = pg_temp.id('a1');
select ok(pg_temp.oq(pg_temp.id('f1')) = 0 and pg_temp.oq(pg_temp.id('f2')) = 1, 'trigger: a rise of the item changes no option');

-- =============================================================================================================================================
-- 3. inventory_receipt_lines_v1
-- =============================================================================================================================================
update public.inventory_item_options set qty_on_hand = 0 where item_id = pg_temp.id('a1');
update public.inventory_items set qty_on_hand = 20 where id = pg_temp.id('a1');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'rl1', public.inventory_receipt_lines_v1(pg_temp.id('a1'), jsonb_build_array(jsonb_build_object('option_id', pg_temp.id('f1'), 'packs', 2), jsonb_build_object('option_id', pg_temp.id('f2'), 'packs', 1)), 300, current_date, null, 'zz133-rcpt-00000000001');
insert into _t select 'rl1b', public.inventory_receipt_lines_v1(pg_temp.id('a1'), jsonb_build_array(jsonb_build_object('option_id', pg_temp.id('f1'), 'packs', 2), jsonb_build_object('option_id', pg_temp.id('f2'), 'packs', 1)), 300, current_date, null, 'zz133-rcpt-00000000001');
insert into _t select 'rl_free', public.inventory_receipt_lines_v1(pg_temp.id('a1'), jsonb_build_array(jsonb_build_object('packs', 1)), null, current_date, null, 'zz133-rcpt-00000000002');
reset role;
select ok((select (v ->> 'ok')::boolean and (v ->> 'total_units')::numeric = 30 from _t where k = 'rl1') and pg_temp.q(pg_temp.id('a1')) = 62 and pg_temp.oq(pg_temp.id('f1')) = 24 and pg_temp.oq(pg_temp.id('f2')) = 6,
  'receipt lines: 2 packs of 12 and 1 pack of 6 add 30 units (item 20 + 30 + 12 = 62); the brands get 24 and 6');
select ok((select abs(sum(pu.total_cost) - 300) <= 0.05 from public.inventory_purchases pu where pu.item_id = pg_temp.id('a1') and pu.option_id is not null),
  'receipt lines: the total paid (300) is split over the lines and the shares add up to it (within the 4-decimal unit cost rounding)');
select ok((select count(*) = 2 and count(distinct pu.option_id) = 2 from public.inventory_purchases pu where pu.item_id = pg_temp.id('a1') and pu.option_id is not null), 'receipt lines: each purchase row keeps the brand it was for');
select ok((select v ->> 'replayed' = 'true' from _t where k = 'rl1b') and pg_temp.q(pg_temp.id('a1')) = 62 and pg_temp.oq(pg_temp.id('f1')) = 24, 'receipt lines: the same key again adds nothing');
select ok(pg_temp.oq(pg_temp.id('f1')) + pg_temp.oq(pg_temp.id('f2')) = 30 and pg_temp.q(pg_temp.id('a1')) - 30 = 32, 'receipt lines: a line with no brand (and no total) adds to Not sorted only (options stay 30, item 62)');
select pg_temp.as_user(pg_temp.id('03'));
select is(pg_temp.try($$select public.inventory_receipt_lines_v1('e1330000-0000-4000-8000-0000000000a1', '[{"packs":1}]'::jsonb, null, current_date, null, 'zz133-rcpt-00000000003')$$) ->> 'err', '42501', 'receipt lines: a cleaner is refused (manage_inventory)');
select pg_temp.as_user(pg_temp.id('01'));
select is(pg_temp.try($$select public.inventory_receipt_lines_v1('e1330000-0000-4000-8000-0000000000a1', '[{"packs":1,"option_id":"e1330000-0000-4000-8000-0000000000f3"}]'::jsonb, null, current_date, null, 'zz133-rcpt-00000000004')$$) ->> 'err', '22023', 'receipt lines: an option of another item is refused');
select is(pg_temp.try($$select public.inventory_receipt_lines_v1('e1330000-0000-4000-8000-0000000000a1', '[]'::jsonb, null, current_date, null, 'zz133-rcpt-00000000005')$$) ->> 'err', '22023', 'receipt lines: no lines is refused');
select is(pg_temp.try($$select public.inventory_receipt_lines_v1('e1330000-0000-4000-8000-0000000000a1', '[{"packs":0}]'::jsonb, null, current_date, null, 'zz133-rcpt-00000000006')$$) ->> 'err', '22023', 'receipt lines: zero packs is refused');
reset role;

-- =============================================================================================================================================
-- 4. inventory_option_use_v1
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'use1', public.inventory_option_use_v1(pg_temp.id('b1'), pg_temp.id('a1'), pg_temp.id('f2'), 4, 'wiped', public.manila_today(), 'zz133-use-000000000001');
insert into _t select 'use1b', public.inventory_option_use_v1(pg_temp.id('b1'), pg_temp.id('a1'), pg_temp.id('f2'), 4, 'wiped', public.manila_today(), 'zz133-use-000000000001');
insert into _t select 'use2', public.inventory_option_use_v1(pg_temp.id('b1'), pg_temp.id('a1'), pg_temp.id('f2'), 5, 'wiped', public.manila_today(), 'zz133-use-000000000002');
insert into _t select 'use3', public.inventory_option_use_v1(pg_temp.id('b1'), pg_temp.id('a1'), null, 2, 'plain', public.manila_today(), 'zz133-use-000000000003');
reset role;
select ok((select (v ->> 'from_option')::numeric = 4 and (v ->> 'from_not_sorted')::numeric = 0 from _t where k = 'use1'), 'use: 4 of a brand holding 6 all comes off the brand (2 left)');
select ok((select (v ->> 'from_option')::numeric = 2 and (v ->> 'from_not_sorted')::numeric = 3 from _t where k = 'use2') and pg_temp.oq(pg_temp.id('f2')) = 0, 'use: 5 of a brand with 2 left takes 2 off the brand and 3 from Not sorted');
select ok(pg_temp.q(pg_temp.id('a1')) = 62 - 4 - 5 - 2, 'use: the item total fell by every use (62 - 4 - 5 - 2 = 51)');
select ok(pg_temp.q(pg_temp.id('a1')) = 51 and pg_temp.oq(pg_temp.id('f2')) = 0, 'use: the same key again takes nothing more (the item stays 51, the brand 0)');
select ok((select not (v ? 'option_id') from _t where k = 'use3') and pg_temp.oq(pg_temp.id('f1')) + pg_temp.oq(pg_temp.id('f2')) <= pg_temp.q(pg_temp.id('a1')), 'use: with no brand it is the plain usage call and the invariant holds');
select pg_temp.as_user(pg_temp.id('03'));
select is(pg_temp.try($$select public.inventory_option_use_v1('e1330000-0000-4000-8000-0000000000b1', 'e1330000-0000-4000-8000-0000000000a1', 'e1330000-0000-4000-8000-0000000000f3', 1, 'x', public.manila_today(), 'zz133-use-000000000004')$$) ->> 'err', '22023', 'use: an option of another item is refused');
select is(pg_temp.try($$select public.inventory_option_use_v1('e1330000-0000-4000-8000-0000000000b1', 'e1330000-0000-4000-8000-0000000000a1', null, 0, 'x', public.manila_today(), 'zz133-use-000000000005')$$) ->> 'err', '22023', 'use: a quantity of 0 is refused');
reset role;

-- =============================================================================================================================================
-- 5. inventory_group_update_v1
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'g_count', public.inventory_group_update_v1(pg_temp.id('b1'), 'count', jsonb_build_array(jsonb_build_object('item_id', pg_temp.id('a2'), 'qty', 9), jsonb_build_object('item_id', pg_temp.id('a3'), 'qty', 8)), 'zz133-group-000000001');
insert into _t select 'g_countb', public.inventory_group_update_v1(pg_temp.id('b1'), 'count', jsonb_build_array(jsonb_build_object('item_id', pg_temp.id('a2'), 'qty', 9), jsonb_build_object('item_id', pg_temp.id('a3'), 'qty', 8)), 'zz133-group-000000001');
insert into _t select 'g_used', public.inventory_group_update_v1(pg_temp.id('b1'), 'used', jsonb_build_array(jsonb_build_object('item_id', pg_temp.id('a2'), 'qty', 2, 'option_id', pg_temp.id('f3')), jsonb_build_object('item_id', pg_temp.id('a3'), 'qty', 1)), 'zz133-group-000000002');
reset role;
select ok((select (v ->> 'ok')::boolean and jsonb_array_length(v -> 'rows') = 2 from _t where k = 'g_count') and pg_temp.q(pg_temp.id('a2')) = 7 and pg_temp.q(pg_temp.id('a3')) = 7, 'group count + used: two rows each saved (a2 9 then used 2 = 7, a3 8 then 1 = 7)');
select ok((select (v ->> 'ok')::boolean from _t where k = 'g_countb') and (select count(*) = 1 from public.inventory_stock_movements m where m.item_id = pg_temp.id('a2') and m.kind = 'reconcile'), 'group: the same key again records no second count');
select pg_temp.as_user(pg_temp.id('03'));
select is(pg_temp.try($$select public.inventory_group_update_v1('e1330000-0000-4000-8000-0000000000b1', 'count', '[{"item_id":"e1330000-0000-4000-8000-0000000000a4","qty":1},{"item_id":"e1330000-0000-4000-8000-0000000000a5","qty":"x"}]'::jsonb, 'zz133-group-000000003')$$) ->> 'msg', 'row 1: the row needs a qty', 'group: a bad second row fails with its 0-based index');
select is(pg_temp.try($$select public.inventory_group_update_v1('e1330000-0000-4000-8000-0000000000b1', 'count', '[{"item_id":"e1330000-0000-4000-8000-0000000000a4","qty":1},{"item_id":"e1330000-0000-4000-8000-0000000000a5","qty":"x"}]'::jsonb, 'zz133-group-000000003')$$) ->> 'err', '22023', 'group: the original SQLSTATE comes through');
reset role;
select ok(pg_temp.q(pg_temp.id('a4')) = 4 and pg_temp.q(pg_temp.id('a5')) = 2, 'group: nothing is half saved (row 0 was rolled back with row 1)');
select pg_temp.as_user(pg_temp.id('03'));
select is(pg_temp.try($$select public.inventory_group_update_v1('e1330000-0000-4000-8000-0000000000b1', 'count', '[{"item_id":"e1330000-0000-4000-8000-0000000000a4","qty":1},{"item_id":"e1330000-0000-4000-8000-0000000000a4","qty":2}]'::jsonb, 'zz133-group-000000004')$$) ->> 'msg', 'row 1: the same item is listed twice', 'group: the same item twice in a count is refused');
select is(pg_temp.try($$select public.inventory_group_update_v1('e1330000-0000-4000-8000-0000000000b1', 'count', '[{"item_id":"e1330000-0000-4000-8000-0000000000e1","qty":1}]'::jsonb, 'zz133-group-000000005')$$) ->> 'msg', 'row 0: the item is not in this property', 'group: an item of another house is refused');
select is(pg_temp.try($$select public.inventory_group_update_v1('e1330000-0000-4000-8000-0000000000b1', 'sell', '[{"item_id":"e1330000-0000-4000-8000-0000000000a4","qty":1}]'::jsonb, 'zz133-group-000000006')$$) ->> 'err', '22023', 'group: an unknown mode is refused');
select is(pg_temp.try($$select public.inventory_group_update_v1('e1330000-0000-4000-8000-0000000000b1', 'count', '[]'::jsonb, 'zz133-group-000000007')$$) ->> 'err', '22023', 'group: no rows is refused');
select is(pg_temp.try($$select public.inventory_group_update_v1('e1330000-0000-4000-8000-0000000000b1', 'bought', '[{"item_id":"e1330000-0000-4000-8000-0000000000a4","lines":[{"packs":1}]}]'::jsonb, 'zz133-group-000000008')$$) ->> 'err', '42501', 'group: a cleaner cannot save a bought sheet (the receipt gate answers)');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'g_bought', public.inventory_group_update_v1(pg_temp.id('b1'), 'bought', jsonb_build_array(jsonb_build_object('item_id', pg_temp.id('a4'), 'lines', jsonb_build_array(jsonb_build_object('packs', 3)), 'total_paid', 30)), 'zz133-group-000000009');
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'g_bought') and pg_temp.q(pg_temp.id('a4')) = 7, 'group bought: three single units are received (4 + 3 = 7)');

-- =============================================================================================================================================
-- 6. product link and photo rules, options read with qty_on_hand
-- =============================================================================================================================================
select ok(public.s_inventory_option_payload_v1(pg_temp.id('b1'), '{"source_url":"https://www.lazada.com.ph/p/1"}'::jsonb, true) ->> 'source_url' = 'https://www.lazada.com.ph/p/1', 'payload: any https product link is accepted');
select is(pg_temp.try($$select public.s_inventory_option_payload_v1('e1330000-0000-4000-8000-0000000000b1', '{"source_url":"http://shop.example/p"}'::jsonb, true)$$) ->> 'err', '22023', 'payload: an http link is refused');
select is(pg_temp.try($$select public.s_inventory_option_payload_v1('e1330000-0000-4000-8000-0000000000b1', '{"source_url":"https://nodot/p"}'::jsonb, true)$$) ->> 'err', '22023', 'payload: a host with no dot is refused');
select ok(public.s_inventory_option_payload_v1(pg_temp.id('b1'), '{"image_url":"items/e1330000-0000-4000-8000-0000000000a1/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.webp"}'::jsonb, true) ? 'image_url', 'payload: a stored photo path is accepted');
select is(pg_temp.try($$select public.s_inventory_option_payload_v1('e1330000-0000-4000-8000-0000000000b1', '{"image_url":"https://evil.example/a.jpg"}'::jsonb, true)$$) ->> 'err', '22023', 'payload: another image host is refused');
select ok(pg_temp.try($$update public.inventory_item_options set image_url = 'items/e1330000-0000-4000-8000-0000000000a1/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg' where id = 'e1330000-0000-4000-8000-0000000000f1' returning 1$$) ->> 'err' is null,
  'table: the photo path of the option''s own item is accepted');
select is(pg_temp.try($$update public.inventory_item_options set image_url = 'items/e1330000-0000-4000-8000-0000000000a2/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg' where id = 'e1330000-0000-4000-8000-0000000000f1' returning 1$$) ->> 'err', '23514', 'table: the photo path of another item is refused by the check');
select is(pg_temp.try($$update public.inventory_item_options set source_url = 'http://shop.example/p' where id = 'e1330000-0000-4000-8000-0000000000f1' returning 1$$) ->> 'err', '23514', 'table: an http product link is refused by the check');
select is(pg_temp.try($$select public.s_inventory_option_payload_v1('e1330000-0000-4000-8000-0000000000b1', '{"source_url":"https://shopee.ph@evil.example/"}'::jsonb, true)$$) ->> 'err', '22023', 'payload: a link with @ in the host part (userinfo) is refused');
select is(pg_temp.try($$update public.inventory_item_options set source_url = 'https://shopee.ph@evil.example/' where id = 'e1330000-0000-4000-8000-0000000000f1' returning 1$$) ->> 'err', '23514', 'table: a link with @ in the host part is refused by the check');
select pg_temp.as_user(pg_temp.id('01'));
select ok((select bool_and(o.value ? 'qty_on_hand') and count(*) = 2 from jsonb_array_elements(public.inventory_item_options_v1(pg_temp.id('a1')) -> 'options') o(value)), 'options read: every option carries qty_on_hand');
reset role;

-- =============================================================================================================================================
-- 7. inventory_item_history_v2
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('01'));
select ok(jsonb_array_length(public.inventory_item_history_v2(pg_temp.id('a1')) -> 'changes') = jsonb_array_length(public.inventory_item_history_v1(pg_temp.id('a1')) -> 'changes'), 'history v2: the same rows as v1');
select ok(exists (select 1 from jsonb_array_elements(public.inventory_item_history_v2(pg_temp.id('a1')) -> 'changes') c(value) where c.value ->> 'source' = 'receipt' and c.value ->> 'option_title' in ('Sofia 12', 'Presto 6')), 'history v2: a receipt row names the brand it was for');
select ok(not exists (select 1 from jsonb_array_elements(public.inventory_item_history_v1(pg_temp.id('a1')) -> 'changes') c(value) where c.value ? 'option_title'), 'history v1 is untouched: no option_title');
reset role;

-- =============================================================================================================================================
-- 8. inventory_log_v1 (contract 5)
-- =============================================================================================================================================
insert into public.inventory_item_changes(item_id, property_id, actor, kind, before, after, created_at) values
  (pg_temp.id('a5'), pg_temp.id('b1'), pg_temp.id('01'), 'details', '{"name":"Zz S133 Rice"}', '{"name":"Zz S133 Rice B"}', now() - interval '3 days'),
  (pg_temp.id('a5'), pg_temp.id('b1'), pg_temp.id('01'), 'price', '{"unit_cost":50}', '{"unit_cost":55}', now() - interval '2 days');
insert into public.inventory_damage_reports(property_id, rows, reason, source, actor_user_id, created_at, undone_at) values
  (pg_temp.id('b1'), jsonb_build_array(jsonb_build_object('item_id', pg_temp.id('a5'), 'qty', 1, 'reason', 'broken', 'before', 2, 'after', 1)), 'broken', 'update', pg_temp.id('01'), now() - interval '1 day', now());
select pg_temp.as_user(pg_temp.id('01'), 'aal2');
insert into _t select 'log_all', public.inventory_log_v1(pg_temp.id('b1'), null, 100);
insert into _t select 'log_asc', public.inventory_log_v1(pg_temp.id('b1'), null, 100, null, null, true);
insert into _t select 'log_bought', public.inventory_log_v1(pg_temp.id('b1'), null, 100, 'bought');
insert into _t select 'log_used', public.inventory_log_v1(pg_temp.id('b1'), null, 100, 'used');
insert into _t select 'log_count', public.inventory_log_v1(pg_temp.id('b1'), null, 100, 'count');
insert into _t select 'log_broken', public.inventory_log_v1(pg_temp.id('b1'), null, 100, 'broken');
insert into _t select 'log_edit', public.inventory_log_v1(pg_temp.id('b1'), null, 100, 'edit');
insert into _t select 'log_a1_used', public.inventory_log_v1(pg_temp.id('b1'), null, 100, 'used', pg_temp.id('a1'));
insert into _t select 'log_item', public.inventory_log_v1(pg_temp.id('b1'), null, 100, null, pg_temp.id('a5'));
insert into _t select 'log_lim0', public.inventory_log_v1(pg_temp.id('b1'), null, 0);
insert into _t select 'log_lim500', public.inventory_log_v1(pg_temp.id('b1'), null, 500);
insert into _t select 'pg_new', to_jsonb(pg_temp.pages(false));
insert into _t select 'pg_old', to_jsonb(pg_temp.pages(true));
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'log_staff', public.inventory_log_v1(pg_temp.id('b1'), null, 100);
select pg_temp.as_user(pg_temp.id('01'), 'aal2');
select is(pg_temp.try($$select public.inventory_log_v1('e1330000-0000-4000-8000-0000000000b1', null, 10, 'zzz')$$) ->> 'err', '22023', 'log: an unknown kind is refused');
select is(pg_temp.try($$select public.inventory_log_v1('e1330000-0000-4000-8000-0000000000b1', null, 10, null, 'e1330000-0000-4000-8000-0000000000e1')$$) ->> 'err', 'P0002', 'log: an item of another house is not found');
select pg_temp.as_user(pg_temp.id('04'));
select is(pg_temp.try($$select public.inventory_log_v1('e1330000-0000-4000-8000-0000000000b1', null, 10)$$) ->> 'err', '42501', 'log: staff without access to the house are refused');
reset role;
select ok((select jsonb_array_length(v -> 'rows') >= 10 and (v -> 'next_before') = 'null'::jsonb from _t where k = 'log_all'), 'log: every source is in the list and the last page has no next_before');
select ok((select (select array_agg((e.value ->> 'at')::timestamptz order by e.ord) from jsonb_array_elements(v -> 'rows') with ordinality e(value, ord)) = (select array_agg((e.value ->> 'at')::timestamptz order by e.ord desc) from _t a, jsonb_array_elements(a.v -> 'rows') with ordinality e(value, ord) where a.k = 'log_asc') from _t where k = 'log_all'), 'log: oldest first lists the same timestamps as newest first, in exactly the reverse order');
select ok((select (select bool_and(x.at >= x.nxt) from (select (e.value ->> 'at')::timestamptz as at, lead((e.value ->> 'at')::timestamptz) over (order by e.ord) as nxt from jsonb_array_elements(v -> 'rows') with ordinality e(value, ord)) x where x.nxt is not null)
                  from _t where k = 'log_all'), 'log: newest first is in descending time order');
select ok((select (select bool_and(x.at <= x.nxt) from (select (e.value ->> 'at')::timestamptz as at, lead((e.value ->> 'at')::timestamptz) over (order by e.ord) as nxt from jsonb_array_elements(v -> 'rows') with ordinality e(value, ord)) x where x.nxt is not null)
                  from _t where k = 'log_asc'), 'log: oldest first is in ascending time order');
select ok((select v #>> '{}' from _t where k = 'pg_new') = (select pg_temp.keys(v -> 'rows') from _t where k = 'log_all') and (select length(v #>> '{}') > 0 from _t where k = 'pg_new'), 'log: paging newest first by 2 returns exactly the full list, no gap and no duplicate');
select ok((select v #>> '{}' from _t where k = 'pg_old') = (select pg_temp.keys(v -> 'rows') from _t where k = 'log_asc'), 'log: paging oldest first by 2 returns exactly the full oldest-first list, no gap and no duplicate');
select ok((select bool_and(r.value -> 'money' = 'null'::jsonb) from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_staff'), 'log: money is null on every row for a cleaner');
select ok((select bool_or(r.value ->> 'kind' = 'bought' and r.value -> 'money' <> 'null'::jsonb) from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_all'), 'log: a bought row carries money for the owner (aal2)');
select ok((select bool_or(r.value ->> 'kind' = 'edit' and r.value -> 'money' <> 'null'::jsonb) from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_all'), 'log: a price change carries before / after for the owner');
select ok((select count(*) > 0 and bool_and(r.value ->> 'kind' = 'bought') from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_bought'), 'log: the bought filter');
select ok((select count(*) > 0 and bool_and(r.value ->> 'kind' = 'used') from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_used'), 'log: the used filter');
select ok((select count(*) > 0 and bool_and(r.value ->> 'kind' = 'count') from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_count'), 'log: the count filter');
select ok((select count(*) = 1 and bool_and(r.value ->> 'kind' = 'broken' and r.value ->> 'undone_at' is not null) from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_broken'), 'log: the broken filter, and an undone report keeps its undone_at');
select ok((select count(*) = 2 and bool_and(r.value ->> 'kind' in ('edit', 'created', 'moved', 'product', 'undo')) from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_edit'), 'log: the edit filter holds the two item changes');
select ok((select count(*) = 3 and bool_and(r.value ->> 'item_id' = pg_temp.id('a5')::text) from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_item'), 'log: p_item_id limits the log to one item (2 changes + 1 damage report)');
select ok((select jsonb_array_length(v -> 'rows') >= 1 from _t where k = 'log_lim0') and (select jsonb_array_length(v -> 'rows') between 1 and 120 from _t where k = 'log_lim500'), 'log: the limit is clamped to 1..100 (a page can run on only to finish one timestamp)');
select ok((select bool_and(r.value ? 'at' and r.value ? 'kind' and r.value ? 'item_id' and r.value ? 'item_name' and r.value ? 'summary_parts' and r.value ? 'qty_before' and r.value ? 'qty_after' and r.value ? 'delta' and r.value ? 'unit' and r.value ? 'option_title'
                         and r.value ? 'money' and r.value ? 'actor_first_name' and r.value ? 'source_note' and r.value ? 'undone_at' and r.value ? 'undone_by_first_name' and r.value ? 'group_key') from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_all'),
  'log: every row has the whole contract shape');
select ok((select bool_or(r.value ->> 'kind' = 'bought' and r.value ->> 'option_title' in ('Sofia 12', 'Presto 6')) from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_all'), 'log: a bought row names its brand');
select ok(not has_function_privilege('anon', 'public.inventory_log_v1(uuid,timestamptz,integer,text,uuid,boolean)', 'execute') and has_function_privilege('authenticated', 'public.inventory_log_v1(uuid,timestamptz,integer,text,uuid,boolean)', 'execute'), 'log: authenticated only');

select ok((select count(*) >= 3 and bool_and(r.value ->> 'item_id' = pg_temp.id('a1')::text) from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_a1_used'), 'log: usage rows of a not-controlled item (no stock movement) are listed as used');
select ok((select count(*) = 2 from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_all' and r.value ->> 'group_key' = 'zz133-group-000000001'), 'log: the two rows of one group call share its group_key');
select ok((select bool_and(r.value -> 'group_key' = 'null'::jsonb) from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_all' and r.value ->> 'kind' = 'used' and r.value ->> 'item_id' = pg_temp.id('a1')::text and r.value ->> 'source_note' = 'plain'), 'log: a single-call key has no group_key');
select ok((select bool_or(r.value ->> 'kind' = 'bought' and r.value ->> 'option_title' in ('Sofia 12', 'Presto 6') and (r.value -> 'money' ->> 'unit_cost') is not null and (r.value -> 'money' ->> 'total_cost') is not null) from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_all'), 'log: a bought row of a not-controlled item names its brand and carries {unit_cost,total_cost}');
select ok((select bool_or((r.value -> 'money' ->> 'before')::numeric = 50 and (r.value -> 'money' ->> 'after')::numeric = 55) from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_all'), 'log: a price edit carries money {before: 50, after: 55} as numbers');
select ok((select bool_and(r.value -> 'money' = 'null'::jsonb) from _t, jsonb_array_elements(v -> 'rows') r(value) where k = 'log_staff' and r.value ->> 'kind' in ('bought', 'edit')), 'log: money stays null on bought and price rows for a cleaner');

select * from finish();
rollback;
