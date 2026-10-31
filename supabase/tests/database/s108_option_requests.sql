-- Session 108, lane SQL: release s108_option_requests_20261111. Staff option requests: table shape and grants, the four RPCs (request / list / decide / cancel),
-- price gating (a cleaner never sends or sees a price), approval with a price override, idempotency, property isolation, url checks, and the follow-up task.
-- Fixtures use uuids d1080000-... on properties of their own; everything rolls back. Needs the s106 + s107 + s108 migrations applied.
begin;
select plan(59);

-- baseline grants for a --no-acl rehearsal restore (idempotent, rolled back with the suite)
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt(), auth.role() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal1', 'iat', 1790000000)::text, true),
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
create function pg_temp.id(p text) returns uuid language sql immutable as $$ select ('d1080000-0000-4000-8000-0000000000' || p)::uuid $$;
create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.rid(p text) returns uuid language sql stable as $$ select (v ->> 'request_id')::uuid from _t where k = p $$;

-- =============================================================================================================================================
-- Fixtures: a1 cleaner, a3 admin, a4 finance, a5 owner on property b0; item c1 (b0) with options f1 f2 (usual) f3; item c0 and supplier e4 on property b1
-- =============================================================================================================================================
insert into auth.users(id, email) values
  (pg_temp.id('a1'), 'zz108-honey@example.com'), (pg_temp.id('a3'), 'zz108-admin@example.com'), (pg_temp.id('a4'), 'zz108-finance@example.com'), (pg_temp.id('a5'), 'zz108-owner@example.com');
update auth.users set raw_user_meta_data = '{"display_name": "Honey Cleaner"}'::jsonb where id = pg_temp.id('a1');
insert into public.staff_access_profiles(user_id, role) values
  (pg_temp.id('a1'), 'cleaner'), (pg_temp.id('a3'), 'admin'), (pg_temp.id('a4'), 'finance'), (pg_temp.id('a5'), 'owner');
insert into public.properties(id, name, is_active) values (pg_temp.id('b0'), 'Zz S108 fixture property', true), (pg_temp.id('b1'), 'Zz S108 other property', true);
insert into public.staff_property_access(user_id, property_id) select u, pg_temp.id('b0') from unnest(array[pg_temp.id('a1'), pg_temp.id('a3'), pg_temp.id('a4'), pg_temp.id('a5')]) u;
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, reorder_below, is_consumable, unit_cost, units_per_purchase, purchase_unit) values
  (pg_temp.id('c1'), pg_temp.id('b0'), 'Zz108 Soap', 'Toiletries', 'pc', 5, 2, true, null, 1, null),
  (pg_temp.id('c0'), pg_temp.id('b1'), 'Zz108 Elsewhere', 'Other', 'pc', 1, null, true, null, 1, null);
insert into public.inventory_suppliers(id, property_id, name, payment_method, is_active) values
  (pg_temp.id('e1'), pg_temp.id('b0'), 'Zz108 Shop A', 'online', true),
  (pg_temp.id('e2'), pg_temp.id('b0'), 'Zz108 Shop Closed', 'cash', false),
  (pg_temp.id('e4'), pg_temp.id('b1'), 'Zz108 Far Away', 'cash', true);
insert into public.inventory_item_options(id, property_id, item_id, supplier_id, title, brand, pack_label, pack_size, price, source_url, is_usual) values
  (pg_temp.id('f1'), pg_temp.id('b0'), pg_temp.id('c1'), pg_temp.id('e1'), 'Alpha Gel', 'Alpha', null, null, 120.00, 'https://shopsuki.ph/products/zz108-o1', false),
  (pg_temp.id('f2'), pg_temp.id('b0'), pg_temp.id('c1'), pg_temp.id('e1'), 'Zeta Bar Soap 6 pack', 'Zeta', '6 x 90g', 6, 100.00, 'https://shopsuki.ph/products/zz108-o2', true),
  (pg_temp.id('f3'), pg_temp.id('b0'), pg_temp.id('c1'), pg_temp.id('e1'), 'Plain Soap 90g', 'Zz', null, null, 90.00, 'https://shopsuki.ph/products/zz108-o3', false),
  (pg_temp.id('f4'), pg_temp.id('b1'), pg_temp.id('c0'), pg_temp.id('e4'), 'Elsewhere Soap', 'Else', null, null, 50.00, 'https://shopsuki.ph/products/zz108-o4', false);

-- =============================================================================================================================================
-- Part 1: shape, grants (13)
-- =============================================================================================================================================
select has_table('public', 'inventory_option_requests', 'the requests table exists');
select columns_are('public', 'inventory_option_requests', array['id', 'property_id', 'item_id', 'option_id', 'option_title', 'action', 'payload', 'status', 'note', 'idempotency_key',
  'requested_by', 'requested_at', 'decided_by', 'decided_at', 'decision_note', 'result_option_id'], 'the requests table has exactly the agreed columns');
select ok((select relrowsecurity from pg_class where oid = 'public.inventory_option_requests'::regclass), 'row level security is on');
select ok(not exists (select 1 from unnest(array['anon', 'authenticated', 'service_role']) r, unnest(array['select', 'insert', 'update', 'delete']) p
                       where has_table_privilege(r, 'public.inventory_option_requests', p)), 'no client or service role has any direct table privilege');
select ok(not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'inventory_option_requests'),
  'not in the realtime publication (vacuously true where the publication does not exist)');
select is((select count(*)::int from pg_proc where oid in ('public.inventory_option_request_v1(uuid,text,uuid,jsonb,text,text)'::regprocedure, 'public.inventory_option_requests_v1(uuid,text)'::regprocedure,
            'public.inventory_option_request_decide_v1(uuid,text,jsonb,text)'::regprocedure, 'public.inventory_option_request_cancel_v1(uuid)'::regprocedure)
            and prosecdef and proconfig = array['search_path=""']), 4, 'the four RPCs are security definer with an empty search_path');
select ok(has_function_privilege('authenticated', 'public.inventory_option_request_v1(uuid,text,uuid,jsonb,text,text)', 'execute')
          and has_function_privilege('authenticated', 'public.inventory_option_requests_v1(uuid,text)', 'execute')
          and has_function_privilege('authenticated', 'public.inventory_option_request_decide_v1(uuid,text,jsonb,text)', 'execute')
          and has_function_privilege('authenticated', 'public.inventory_option_request_cancel_v1(uuid)', 'execute'), 'authenticated may call the four RPCs');
select ok(not has_function_privilege('anon', 'public.inventory_option_request_v1(uuid,text,uuid,jsonb,text,text)', 'execute')
          and not has_function_privilege('service_role', 'public.inventory_option_request_v1(uuid,text,uuid,jsonb,text,text)', 'execute')
          and not has_function_privilege('anon', 'public.inventory_option_requests_v1(uuid,text)', 'execute')
          and not has_function_privilege('anon', 'public.inventory_option_request_decide_v1(uuid,text,jsonb,text)', 'execute')
          and not has_function_privilege('anon', 'public.inventory_option_request_cancel_v1(uuid)', 'execute'), 'anon and service_role may not call them');
select ok(not exists (select 1 from unnest(array['public.s_inventory_option_payload_v1(uuid,jsonb,boolean)', 'public.s_inventory_option_apply_v1(uuid,uuid,text,uuid,jsonb,uuid)',
            'public.s_inventory_option_request_task_v1(uuid,uuid)']) f, unnest(array['anon', 'authenticated', 'service_role']) r where has_function_privilege(r, f, 'execute')), 'the three internal functions have no grants');
select is(pg_temp.try($$insert into public.inventory_option_requests(property_id, item_id, action, idempotency_key, requested_by, status) values (pg_temp.id('b0'), pg_temp.id('c1'), 'add', 'zz108-key-bad-status-1', pg_temp.id('a1'), 'maybe') returning to_jsonb(id)$$) ->> 'err', '23514', 'a bad status is refused');
select is(pg_temp.try($$insert into public.inventory_option_requests(property_id, item_id, action, idempotency_key, requested_by) values (pg_temp.id('b0'), pg_temp.id('c1'), 'rename', 'zz108-key-bad-action-1', pg_temp.id('a1')) returning to_jsonb(id)$$) ->> 'err', '23514', 'a bad action is refused');
select is(pg_temp.try($$insert into public.inventory_option_requests(property_id, item_id, action, idempotency_key, requested_by) values (pg_temp.id('b0'), pg_temp.id('c1'), 'add', 'short', pg_temp.id('a1')) returning to_jsonb(id)$$) ->> 'err', '23514', 'a short idempotency key is refused');
select is(pg_temp.try($$insert into public.inventory_option_requests(property_id, item_id, action, idempotency_key, requested_by, payload) values (pg_temp.id('b0'), pg_temp.id('c1'), 'add', 'zz108-key-bad-payload-1', pg_temp.id('a1'), '[]') returning to_jsonb(id)$$) ->> 'err', '23514', 'a payload that is not an object is refused');

-- =============================================================================================================================================
-- Part 2: cleaner requests (15)
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 'r1', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'add', null, jsonb_build_object('title', '  Cl New Soap ', 'supplier_id', pg_temp.id('e1'), 'brand', 'Zz', 'source_url', 'https://shopsuki.ph/products/zz108-new'), 'need this one', 'zz108-key-cl-add-0001')$$);
insert into _t select 'r1_replay', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'add', null, jsonb_build_object('title', 'Cl New Soap', 'supplier_id', pg_temp.id('e1')), 'again', 'zz108-key-cl-add-0001')$$);
insert into _t select 'price', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'add', null, jsonb_build_object('title', 'With price', 'supplier_id', pg_temp.id('e1'), 'price', 50), null, 'zz108-key-cl-price-001')$$);
insert into _t select 'price_null', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'add', null, jsonb_build_object('title', 'Null price', 'supplier_id', pg_temp.id('e1'), 'price', null), null, 'zz108-key-cl-pricenull1')$$);
insert into _t select 'other_prop', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c0'), 'add', null, jsonb_build_object('title', 'Far', 'supplier_id', pg_temp.id('e4')), null, 'zz108-key-cl-other-0001')$$);
insert into _t select 'bad_src', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'add', null, jsonb_build_object('title', 'x', 'supplier_id', pg_temp.id('e1'), 'source_url', 'http://shopsuki.ph/p'), null, 'zz108-key-cl-badsrc-001')$$);
insert into _t select 'bad_img', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'add', null, jsonb_build_object('title', 'x', 'supplier_id', pg_temp.id('e1'), 'image_url', 'https://evil.example/a.jpg'), null, 'zz108-key-cl-badimg-001')$$);
insert into _t select 'sup_off', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'add', null, jsonb_build_object('title', 'x', 'supplier_id', pg_temp.id('e2')), null, 'zz108-key-cl-supoff-001')$$);
insert into _t select 'sup_far', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'add', null, jsonb_build_object('title', 'x', 'supplier_id', pg_temp.id('e4')), null, 'zz108-key-cl-supfar-001')$$);
insert into _t select 'no_sup', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'add', null, jsonb_build_object('title', 'x'), null, 'zz108-key-cl-nosup-0001')$$);
insert into _t select 'junk', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'add', null, jsonb_build_object('title', 'x', 'supplier_id', pg_temp.id('e1'), 'is_usual', true), null, 'zz108-key-cl-junk-00001')$$);
insert into _t select 'del_usual', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'delete', pg_temp.id('f2'), null, null, 'zz108-key-cl-delusual1')$$);
insert into _t select 'edit_far', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'edit', pg_temp.id('f4'), jsonb_build_object('title', 'x'), null, 'zz108-key-cl-editfar-01')$$);
insert into _t select 'r2', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'edit', pg_temp.id('f1'), jsonb_build_object('title', 'Alpha Gel Lemon', 'pack_label', '2 x 180g'), null, 'zz108-key-cl-edit-00001')$$);
insert into _t select 'r3', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'delete', pg_temp.id('f3'), null, 'not sold anymore', 'zz108-key-cl-delete-001')$$);
reset role;

select is((select v ->> 'applied' from _t where k = 'r1'), 'false', 'cleaner add: pending, not applied');
select is((select count(*)::int from public.inventory_item_options where item_id = pg_temp.id('c1') and title = 'Cl New Soap'), 0, 'cleaner add: the option is not created');
select is((select (status, title_ok)::text from (select r.status, r.payload ->> 'title' = 'Cl New Soap' as title_ok from public.inventory_option_requests r where r.id = pg_temp.rid('r1')) q), '(pending,t)', 'cleaner add: stored pending with the trimmed title');
select is((select v ->> 'msg' from _t where k = 'price'), 'price_not_allowed', 'cleaner add with a price: refused as price_not_allowed');
select is((select v ->> 'err' from _t where k = 'price'), '22023', 'cleaner add with a price: sqlstate 22023');
select ok((select not (payload ? 'price') from public.inventory_option_requests where id = pg_temp.rid('price_null')) and (select v ->> 'applied' from _t where k = 'price_null') = 'false', 'a null price is dropped, not stored');
select ok((select v ->> 'replay' = 'true' and v ->> 'request_id' = (select v ->> 'request_id' from _t where k = 'r1') from _t where k = 'r1_replay')
          and (select count(*)::int from public.inventory_option_requests where requested_by = pg_temp.id('a1') and idempotency_key = 'zz108-key-cl-add-0001') = 1, 'idempotency: replay returns the same request and creates no second row');
select is((select v ->> 'err' from _t where k = 'other_prop'), '42501', 'another property item: refused (no access)');
select is((select array[v ->> 'err', v ->> 'msg'] from _t where k = 'bad_src'), array['22023', 'product link must be https on shopsuki.ph or shopee.ph'], 'url check: an http product link is refused');
select is((select v ->> 'err' from _t where k = 'bad_img'), '22023', 'url check: an image off the allowed hosts is refused');
select ok((select bool_and(v ->> 'err' = '22023') from _t where k in ('sup_off', 'sup_far', 'no_sup', 'junk', 'edit_far')), 'inactive or foreign supplier, missing supplier, unknown field and foreign option are all 22023');
select is((select v ->> 'msg' from _t where k = 'del_usual'), 'usual_option', 'deleting the usual option is refused at request time');
select ok((select v ->> 'applied' = 'false' from _t where k = 'r2') and (select v ->> 'applied' = 'false' from _t where k = 'r3'), 'cleaner edit and delete: pending');
select is((select count(*)::int from public.inventory_item_options where id = pg_temp.id('f3')) + (select count(*)::int from public.inventory_item_options where id = pg_temp.id('f1') and title = 'Alpha Gel'), 2, 'cleaner edit and delete: the options are untouched');
select is((select count(*)::int from public.follow_up_tasks where source_kind = 'option_request' and source_ref = pg_temp.id('c1')::text and status = 'open'), 1, 'one open follow-up task for the item, however many requests');

-- =============================================================================================================================================
-- Part 3: lists and gates (9)
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('a4'));
insert into _t select 'r4', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'add', null, jsonb_build_object('title', 'Finance Soap', 'supplier_id', pg_temp.id('e1'), 'price', 55), null, 'zz108-key-fi-add-00001')$$);
insert into _t select 'fi_list', pg_temp.try($$select public.inventory_option_requests_v1(pg_temp.id('b0'))$$);
insert into _t select 'fi_decide', pg_temp.try($$select public.inventory_option_request_decide_v1(pg_temp.rid('r1'), 'approve', null, null)$$);
insert into _t select 'fi_cancel', pg_temp.try($$select public.inventory_option_request_cancel_v1(pg_temp.rid('r1'))$$);
reset role;
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 'cl_list', pg_temp.try($$select public.inventory_option_requests_v1(pg_temp.id('b0'))$$);
insert into _t select 'cl_decide', pg_temp.try($$select public.inventory_option_request_decide_v1(pg_temp.rid('r1'), 'approve', null, null)$$);
insert into _t select 'cl_tab', pg_temp.try($$select to_jsonb(count(*)) from public.inventory_option_requests$$);
reset role;
select pg_temp.as_user(pg_temp.id('a5'));
insert into _t select 'ow_list', pg_temp.try($$select public.inventory_option_requests_v1(pg_temp.id('b0'))$$);
reset role;

select is((select v ->> 'applied' from _t where k = 'r4'), 'false', 'finance (no manage_inventory) may send a price, and the request waits');
select ok((select (v -> 'requests' -> 0 -> 'payload' ->> 'price')::numeric = 55 and jsonb_array_length(v -> 'requests') = 1 and (v ->> 'manage') = 'false' from _t where k = 'fi_list'), 'finance list: only the own request, with its price');
select is((select count(*)::int from _t, jsonb_array_elements(v -> 'requests') e where k = 'cl_list'), 4, 'cleaner list: the four own pending requests only (not the finance one)');
select ok((select v::text !~ '"price"' and (select bool_and(e ->> 'requester' = 'Honey Cleaner' and e ->> 'mine' = 'true') from jsonb_array_elements(v -> 'requests') e) from _t where k = 'cl_list'), 'cleaner list: no price key anywhere, requester name shown, mine true');
select is((select count(*)::int from _t, jsonb_array_elements(v -> 'requests') e where k = 'ow_list'), 5, 'owner list: all five pending requests');
select ok((select (select e -> 'payload' ->> 'price' from jsonb_array_elements(v -> 'requests') e where e ->> 'id' = pg_temp.rid('r4')::text) = '55' and (v ->> 'manage') = 'true' from _t where k = 'ow_list'), 'owner list: sees the finance request price and manage = true');
select is((select v ->> 'err' from _t where k = 'cl_tab'), '42501', 'cleaner: cannot read the table directly');
select ok((select v ->> 'err' = '42501' from _t where k = 'cl_decide') and (select v ->> 'err' = '42501' from _t where k = 'fi_decide'), 'cleaner and finance: cannot decide');
select is((select v ->> 'err' from _t where k = 'fi_cancel'), '42501', 'only the requester can cancel (finance cannot cancel the cleaner request)');

-- =============================================================================================================================================
-- Part 4: owner / admin (immediate apply) and decisions (14)
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('a5'));
insert into _t select 'ow_add', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'add', null, jsonb_build_object('title', 'Owner Soap', 'supplier_id', pg_temp.id('e1'), 'price', 70), null, 'zz108-key-ow-add-00001')$$);
insert into _t select 'ow_del_usual', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'delete', pg_temp.id('f2'), null, null, 'zz108-key-ow-delusual1')$$);
insert into _t select 'ow_del', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'delete', pg_temp.id('f3'), null, null, 'zz108-key-ow-delete-001')$$);
insert into _t select 'ow_replay', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'add', null, jsonb_build_object('title', 'Owner Soap', 'supplier_id', pg_temp.id('e1')), null, 'zz108-key-ow-add-00001')$$);
reset role;
select pg_temp.as_user(pg_temp.id('a3'));
insert into _t select 'ad_approve', pg_temp.try($$select public.inventory_option_request_decide_v1(pg_temp.rid('r1'), 'approve', '{"price": 65.5}'::jsonb, 'ok')$$);
insert into _t select 'ad_again', pg_temp.try($$select public.inventory_option_request_decide_v1(pg_temp.rid('r1'), 'reject', null, null)$$);
insert into _t select 'ad_reject', pg_temp.try($$select public.inventory_option_request_decide_v1(pg_temp.rid('r2'), 'reject', null, 'keep the old name')$$);
insert into _t select 'ad_junk', pg_temp.try($$select public.inventory_option_request_decide_v1(pg_temp.rid('r4'), 'approve', '{"is_usual": true}'::jsonb, null)$$);
insert into _t select 'ad_badword', pg_temp.try($$select public.inventory_option_request_decide_v1(pg_temp.rid('r4'), 'maybe', null, null)$$);
reset role;
select is((select v ->> 'applied' from _t where k = 'ow_add'), 'true', 'owner add: applied at once');
select is((select (price, created_by = pg_temp.id('a5'))::text from public.inventory_item_options where id = (select (v ->> 'option_id')::uuid from _t where k = 'ow_add')), '(70.00,t)', 'owner add: the option exists with its price and creator');
select is((select (status, decided_by = pg_temp.id('a5'), result_option_id = (select (v ->> 'option_id')::uuid from _t where k = 'ow_add'))::text from public.inventory_option_requests where id = pg_temp.rid('ow_add')), '(approved,t,t)', 'owner add: recorded as an approved request decided by the owner');
select is((select v ->> 'msg' from _t where k = 'ow_del_usual'), 'usual_option', 'owner delete of the usual option: refused with usual_option');
select ok((select v ->> 'applied' = 'true' from _t where k = 'ow_del') and not exists (select 1 from public.inventory_item_options where id = pg_temp.id('f3')), 'owner delete: the option is gone');
select ok((select v ->> 'replay' = 'true' and v ->> 'applied' = 'true' and v ->> 'request_id' = (select v ->> 'request_id' from _t where k = 'ow_add') from _t where k = 'ow_replay')
          and (select count(*)::int from public.inventory_item_options where item_id = pg_temp.id('c1') and title = 'Owner Soap') = 1, 'owner replay: same request, no second option');
select is((select v ->> 'status' from _t where k = 'ad_approve'), 'approved', 'admin approve: status approved');
select is((select (title, brand, price, supplier_id = pg_temp.id('e1'), created_by = pg_temp.id('a1'))::text from public.inventory_item_options where id = (select (v ->> 'option_id')::uuid from _t where k = 'ad_approve')),
  '(Cl New Soap,Zz,65.50,t,t)', 'admin approve: applied with the price override, created by the requester');
select is((select (status, decided_by = pg_temp.id('a3'), decision_note, payload ->> 'price')::text from public.inventory_option_requests where id = pg_temp.rid('r1')), '(approved,t,ok,65.5)', 'admin approve: decision fields and the final payload are stored');
select is((select v ->> 'msg' from _t where k = 'ad_again'), 'not_pending', 'deciding a request twice: not_pending');
select ok((select v ->> 'status' = 'rejected' from _t where k = 'ad_reject') and (select title from public.inventory_item_options where id = pg_temp.id('f1')) = 'Alpha Gel'
          and (select status from public.inventory_option_requests where id = pg_temp.rid('r2')) = 'rejected', 'admin reject: status rejected, option unchanged');
select ok((select v ->> 'err' from _t where k = 'ad_junk') = '22023' and (select v ->> 'err' from _t where k = 'ad_badword') = '22023' and (select status from public.inventory_option_requests where id = pg_temp.rid('r4')) = 'pending', 'bad override field and bad decision: 22023 and the request stays pending');
select is((select count(*)::int from public.follow_up_tasks where source_kind = 'option_request' and source_ref = pg_temp.id('c1')::text and status = 'open'), 1, 'the follow-up task stays open while requests are pending');

-- =============================================================================================================================================
-- Part 5: edit of the usual option refreshes the link, cancel, task closing (10)
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 'r5', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'edit', pg_temp.id('f2'), jsonb_build_object('pack_label', '6 bars'), null, 'zz108-key-cl-edit-usual1')$$);
insert into _t select 'cl_cancel', pg_temp.try($$select public.inventory_option_request_cancel_v1(pg_temp.rid('r3'))$$);
insert into _t select 'cl_cancel2', pg_temp.try($$select public.inventory_option_request_cancel_v1(pg_temp.rid('price_null'))$$);
insert into _t select 'cl_cancel_again', pg_temp.try($$select public.inventory_option_request_cancel_v1(pg_temp.rid('r3'))$$);
insert into _t select 'cl_cancel_decided', pg_temp.try($$select public.inventory_option_request_cancel_v1(pg_temp.rid('r1'))$$);
reset role;
select pg_temp.as_user(pg_temp.id('a3'));
insert into _t select 'ad_edit_usual', pg_temp.try($$select public.inventory_option_request_decide_v1(pg_temp.rid('r5'), 'approve', '{"price": 105}'::jsonb, null)$$);
reset role;
select ok((select v ->> 'status' = 'cancelled' from _t where k = 'cl_cancel') and (select status from public.inventory_option_requests where id = pg_temp.rid('r3')) = 'cancelled', 'cleaner cancels own pending request');
select is((select v ->> 'msg' from _t where k = 'cl_cancel_again'), 'not_pending', 'cancelling a cancelled request: not_pending');
select is((select v ->> 'msg' from _t where k = 'cl_cancel_decided'), 'not_pending', 'cancelling an approved request: not_pending');
select is((select (price, pack_label, is_usual)::text from public.inventory_item_options where id = pg_temp.id('f2')), '(105.00,"6 bars",t)', 'admin approves an edit of the usual option with a price override');
select is((select (quoted_pack_price, pack_label)::text from public.inventory_item_suppliers where item_id = pg_temp.id('c1') and supplier_id = pg_temp.id('e1') and is_preferred), '(105.00,"6 bars")', 'the preferred supplier link follows the edited usual option');
select is((select count(*)::int from public.follow_up_tasks where source_kind = 'option_request' and source_ref = pg_temp.id('c1')::text and status = 'open'), 1, 'the task stays open: r4 is still pending');
select pg_temp.as_user(pg_temp.id('a3'));
insert into _t select 'ad_reject4', pg_temp.try($$select public.inventory_option_request_decide_v1(pg_temp.rid('r4'), 'reject', null, null)$$);
reset role;
select is((select count(*)::int from public.follow_up_tasks where source_kind = 'option_request' and source_ref = pg_temp.id('c1')::text and status = 'open'), 0, 'the task closes when no pending request remains');
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 'r6', pg_temp.try($$select public.inventory_option_request_v1(pg_temp.id('c1'), 'add', null, jsonb_build_object('title', 'Second wave', 'supplier_id', pg_temp.id('e1')), null, 'zz108-key-cl-add-0002x')$$);
reset role;
select is((select status from public.follow_up_tasks where source_kind = 'option_request' and source_ref = pg_temp.id('c1')::text), 'open', 'a new request reopens the closed task');
select pg_temp.as_user(pg_temp.id('a3'));
insert into _t select 'ad_list_all', pg_temp.try($$select public.inventory_option_requests_v1(pg_temp.id('b0'), 'all')$$);
reset role;
select ok((select jsonb_array_length(v -> 'requests') = 9 and (select e ->> 'option_title' from jsonb_array_elements(v -> 'requests') e where e ->> 'id' = pg_temp.rid('ow_del')::text) = 'Plain Soap 90g' from _t where k = 'ad_list_all'),
  'status all lists every request newest first and keeps the title of a deleted option');

select * from finish();
rollback;
