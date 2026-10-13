-- Session 82, lane S, fix round: release s82_staff_31_20261015. (1) staff_pay_admin_create_v1 refuses the caller as payee and a disabled or ineligible payee, and the
-- admin list marks the caller's own work `self`; (3a) apply_inventory_purchase on a movement-controlled item writes the receipt movement (idempotent on the
-- transaction), an uncontrolled item behaves as before; (3b) a cleaner cannot read inventory_shopping_list cost columns or edit other people's rows.
-- Synthetic fixtures only (uuids d8300000-...). Everything rolls back.
begin;
select plan(48);

grant usage on schema public, auth, storage to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
-- Supabase's service_role bypasses row level security; a rehearsal copy's stand-in role does not (rolled back with the suite)
alter role service_role bypassrls;
-- the table ACLs a --no-acl restore lacks (production has them; rolled back with the suite). The Telegram restock runs as service_role with invoker rights.
grant select, update on public.inventory_items to service_role;
grant select, insert on public.inventory_purchases to service_role;
grant insert on public.inventory_audit_log to service_role;
grant select on public.inventory_items to authenticated;
grant select, insert on public.inventory_purchases to authenticated;
grant insert on public.inventory_audit_log to authenticated;

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal2', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_service() returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true), set_config('role', 'service_role', true);
$$;

insert into auth.users(id, email) values
  ('d8300000-0000-4000-8000-0000000000a1', 'zz-honey2@example.com'), ('d8300000-0000-4000-8000-0000000000a3', 'zz-admin2@example.com'),
  ('d8300000-0000-4000-8000-0000000000a4', 'zz-finance2@example.com'), ('d8300000-0000-4000-8000-0000000000a5', 'zz-owner2@example.com'),
  ('d8300000-0000-4000-8000-0000000000a6', 'zz-gone@example.com'), ('d8300000-0000-4000-8000-0000000000a7', 'zz-admin3@example.com');
insert into public.staff_access_profiles(user_id, role, disabled_at) values
  ('d8300000-0000-4000-8000-0000000000a1', 'cleaner', null), ('d8300000-0000-4000-8000-0000000000a3', 'admin', null),
  ('d8300000-0000-4000-8000-0000000000a4', 'finance', null), ('d8300000-0000-4000-8000-0000000000a5', 'owner', null),
  ('d8300000-0000-4000-8000-0000000000a6', 'cleaner', now()), ('d8300000-0000-4000-8000-0000000000a7', 'admin', null);
insert into public.properties(id, name, is_active) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Cascade Hideaway', true) on conflict (id) do nothing;
insert into public.staff_property_access(user_id, property_id) select u, '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
  from unnest(array['d8300000-0000-4000-8000-0000000000a1', 'd8300000-0000-4000-8000-0000000000a3', 'd8300000-0000-4000-8000-0000000000a4', 'd8300000-0000-4000-8000-0000000000a5', 'd8300000-0000-4000-8000-0000000000a6', 'd8300000-0000-4000-8000-0000000000a7']::uuid[]) u;
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, transport_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2026-09-30', 500, 1000, 150, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-09-30');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '1900-01-01', 250, 250, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '1900-01-01');
-- the admin (a3) and the other admin (a7) each did a clean of their own; the disabled cleaner (a6) has an unpaid clean; Honey one.
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, submitted_by_user_id) values
  ('d8300000-0000-4000-8000-0000000000b1', 'zz-s82f-a', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzadmin Three', date '2026-10-05', 'turnover', 'd8300000-0000-4000-8000-0000000000a3'),
  ('d8300000-0000-4000-8000-0000000000b2', 'zz-s82f-b', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzgone', date '2026-10-06', 'turnover', 'd8300000-0000-4000-8000-0000000000a6'),
  ('d8300000-0000-4000-8000-0000000000b3', 'zz-s82f-c', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney2', date '2026-10-07', 'turnover', 'd8300000-0000-4000-8000-0000000000a1');

-- =============================================================== 1. pay: self and eligibility
select pg_temp.as_user('d8300000-0000-4000-8000-0000000000a3');
insert into _t select 'self', public.staff_pay_admin_create_v1('d8300000-0000-4000-8000-0000000000a3', '[{"id":"d8300000-0000-4000-8000-0000000000b1"}]'::jsonb, '{}'::uuid[], 'zz-s82f-key-self1');
insert into _t select 'gone', public.staff_pay_admin_create_v1('d8300000-0000-4000-8000-0000000000a6', '[{"id":"d8300000-0000-4000-8000-0000000000b2"}]'::jsonb, '{}'::uuid[], 'zz-s82f-key-gone1');
insert into _t select 'list_a3', public.staff_pay_admin_list_v1();
reset role;
select pg_temp.as_user('d8300000-0000-4000-8000-0000000000a7');
insert into _t select 'list_a7', public.staff_pay_admin_list_v1();
insert into _t select 'by_other_admin', public.staff_pay_admin_create_v1('d8300000-0000-4000-8000-0000000000a3', '[{"id":"d8300000-0000-4000-8000-0000000000b1"}]'::jsonb, '{}'::uuid[], 'zz-s82f-key-oth01');
reset role;
select is((select v->>'reason' from _t where k = 'self'), 'self', 'an admin cannot make a pay request with herself as the payee');
select is((select v->>'reason' from _t where k = 'gone'), 'payee_not_allowed', 'a disabled profile cannot be a payee');
select is((select count(*)::int from public.staff_pay_requests where payee_user_id = 'd8300000-0000-4000-8000-0000000000a6' or created_by_user_id = payee_user_id), 0, 'and neither refusal wrote a request');
select is((select count(*)::int from public.cleaning_sessions where id = 'd8300000-0000-4000-8000-0000000000b2' and pay_request_id is not null), 0, 'nor locked a clean');
select is((select (e->>'self')::boolean from _t, jsonb_array_elements(v->'unrequested') e where k = 'list_a3' and e->>'payee_user_id' = 'd8300000-0000-4000-8000-0000000000a3'), true, 'the admin''s own unpaid work is listed and marked self for her');
select is((select (e->>'self')::boolean from _t, jsonb_array_elements(v->'unrequested') e where k = 'list_a3' and e->>'payee_user_id' = 'd8300000-0000-4000-8000-0000000000a1'), false, 'Honey''s work is not self');
select is((select (e->>'self')::boolean from _t, jsonb_array_elements(v->'unrequested') e where k = 'list_a7' and e->>'payee_user_id' = 'd8300000-0000-4000-8000-0000000000a3'), false, 'a second admin sees the first admin''s work, not marked self');
select is((select v->>'ok' from _t where k = 'by_other_admin'), 'true', 'and the second admin can make that request');

-- =============================================================== 3a. apply_inventory_purchase
insert into public.inventory_items(id, property_id, name, category, qty_on_hand, units_per_purchase, movement_controlled_at, baseline_reviewed_by) values
  ('d8300000-0000-4000-8000-0000000000c1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zz controlled soap', 'zz', 10, 1, now(), 'd8300000-0000-4000-8000-0000000000a5');
insert into public.inventory_items(id, property_id, name, category, qty_on_hand, units_per_purchase) values
  ('d8300000-0000-4000-8000-0000000000c2', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zz plain soap', 'zz', 5, 6);
insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key) values
  ('d8300000-0000-4000-8000-0000000000c1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'reconcile', 0, 10, 'Baseline count: zz', 'd8300000-0000-4000-8000-0000000000a5', 'zz-s82f-baseline-0001');

select pg_temp.as_service();
insert into _t select 'buy1', public.apply_inventory_purchase('d8300000-0000-4000-8000-0000000000c1', 2, 40, 'Zz Store', current_date, 'd8300000-0000-4000-8000-0000000000e1');
insert into _t select 'buy1_again', public.apply_inventory_purchase('d8300000-0000-4000-8000-0000000000c1', 2, 40, 'Zz Store', current_date, 'd8300000-0000-4000-8000-0000000000e1');
insert into _t select 'buy_plain', public.apply_inventory_purchase('d8300000-0000-4000-8000-0000000000c2', 2, 40, 'Zz Store', current_date, 'd8300000-0000-4000-8000-0000000000e2');
insert into _t select 'buy_plain_again', public.apply_inventory_purchase('d8300000-0000-4000-8000-0000000000c2', 2, 40, 'Zz Store', current_date, 'd8300000-0000-4000-8000-0000000000e2');
reset role;
select is((select v->>'ok' from _t where k = 'buy1'), 'true', 'a Telegram restock of a controlled item succeeds');
select is((select qty_on_hand from public.inventory_items where id = 'd8300000-0000-4000-8000-0000000000c1'), 12::numeric, 'and adds the units once (10 + 2)');
select is((select m.quantity_after from public.inventory_stock_movements m where m.item_id = 'd8300000-0000-4000-8000-0000000000c1' order by m.sequence_no desc limit 1), 12::numeric, 'the last movement now equals qty_on_hand (the ledger stays consistent)');
select is((select m.kind from public.inventory_stock_movements m where m.item_id = 'd8300000-0000-4000-8000-0000000000c1' order by m.sequence_no desc limit 1), 'receipt', 'it is a receipt movement, as record_inventory_receipt_v1 writes');
select is((select m.actor_user_id from public.inventory_stock_movements m where m.item_id = 'd8300000-0000-4000-8000-0000000000c1' order by m.sequence_no desc limit 1), 'd8300000-0000-4000-8000-0000000000a5'::uuid, 'with the person who reconciled the item as actor (a service role has no user)');
select ok((select (v->>'replayed')::boolean and v->>'ok' = 'true' from _t where k = 'buy1_again'), 'the same receipt transaction again is answered as a replay');
select is((select count(*)::int from public.inventory_stock_movements where item_id = 'd8300000-0000-4000-8000-0000000000c1'), 2, 'and writes no second movement');
select is((select count(*)::int from public.inventory_purchases where item_id = 'd8300000-0000-4000-8000-0000000000c1'), 1, 'nor a second purchase row');
select is((select qty_on_hand from public.inventory_items where id = 'd8300000-0000-4000-8000-0000000000c1'), 12::numeric, 'the stock did not double');
select ok((select count(*) = 0 from public.inventory_items i where i.id = 'd8300000-0000-4000-8000-0000000000c1' and i.qty_on_hand is distinct from (select m.quantity_after from public.inventory_stock_movements m where m.item_id = i.id order by m.sequence_no desc limit 1)),
  'inventory_ledger_consistent would read pass for it (on hand = last movement)');
-- a later receipt and an adjustment still work on the item
select pg_temp.as_user('d8300000-0000-4000-8000-0000000000a5');
insert into _t select 'rcpt', public.record_inventory_receipt_v1('d8300000-0000-4000-8000-0000000000c1', 1, null, null, current_date, null, null, 'zz-s82f-receipt-00001');
insert into _t select 'adj', to_jsonb(public.record_inventory_movement('d8300000-0000-4000-8000-0000000000c1', 'adjustment', -1, 'zz adjust', 'zz-s82f-adjust-000001'));
reset role;
select is((select v->>'ok' from _t where k = 'rcpt'), 'true', 'a later receipt through record_inventory_receipt_v1 still works');
select is((select v from _t where k = 'adj') is not null, true, 'and so does an adjustment');
select is((select qty_on_hand from public.inventory_items where id = 'd8300000-0000-4000-8000-0000000000c1'), 12::numeric, 'on hand is 12 + 1 - 1');
-- uncontrolled: exactly the old behaviour (units_per_purchase 6: 5 + 2*6 = 17, no movement, and the old function has no replay guard)
select is((select (v->>'qty_after')::numeric from _t where k = 'buy_plain'), 17::numeric, 'an uncontrolled item restocks as before (5 + 2 x 6)');
select is((select count(*)::int from public.inventory_stock_movements where item_id = 'd8300000-0000-4000-8000-0000000000c2'), 0, 'and writes no movement');
select is((select (v->>'qty_after')::numeric from _t where k = 'buy_plain_again'), 29::numeric, 'and keeps the old behaviour on a repeat (no replay guard, byte-identical)');
select is((select count(*)::int from public.inventory_audit_log where entity_id = 'd8300000-0000-4000-8000-0000000000c2' and action = 'ocr_restock'), 2, 'the audit rows are still written');
-- guards of the controlled path
select pg_temp.as_user('d8300000-0000-4000-8000-0000000000a1');
select throws_ok($$select public.apply_inventory_purchase('d8300000-0000-4000-8000-0000000000c1', 1, null, null, current_date, null)$$, '42501', null, 'a cleaner session cannot restock a controlled item');
reset role;
select is((select count(*)::int from public.inventory_purchases where item_id = 'd8300000-0000-4000-8000-0000000000c1'), 2, 'and the refusal left no purchase row (the receipt above wrote the second)');
update public.inventory_items set qty_on_hand = 99 where id = 'd8300000-0000-4000-8000-0000000000c1';
select pg_temp.as_service();
select throws_ok($$select public.apply_inventory_purchase('d8300000-0000-4000-8000-0000000000c1', 1, null, null, current_date, null)$$, '22023', 'stock reconciliation required', 'an item whose ledger disagrees is refused, not made worse');
reset role;

-- the helper is not a door of its own: no purchase row, no movement (the item's ledger is consistent again here)
update public.inventory_items set qty_on_hand = 12 where id = 'd8300000-0000-4000-8000-0000000000c1';
select pg_temp.as_user('d8300000-0000-4000-8000-0000000000a5');
select throws_ok($$select public.s_inventory_purchase_movement_v1('d8300000-0000-4000-8000-0000000000c1', 5, 'zz direct call', 'made-up-ref')$$, '22023', 'no purchase for this movement', 'an owner calling the helper directly with an arbitrary source ref is refused');
reset role;
select pg_temp.as_service();
select throws_ok($$select public.s_inventory_purchase_movement_v1('d8300000-0000-4000-8000-0000000000c1', 5, 'zz direct call', (select id::text from public.inventory_purchases where item_id = 'd8300000-0000-4000-8000-0000000000c2' limit 1))$$, '22023', 'no purchase for this movement', 'nor with the purchase of another item');
reset role;

-- =============================================================== 3b. inventory_shopping_list
insert into public.inventory_shopping_list(id, property_id, item_name, quantity, estimated_cost, reason, status, proposed_by, unit_cost, supplier, idempotency_key) values
  ('d8300000-0000-4000-8000-0000000000d1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zz admin item', 2, 99, 'zz', 'proposed', 'd8300000-0000-4000-8000-0000000000a3', 55, 'ZZ Supplier', 'zz-s82f-shop-000000001'),
  ('d8300000-0000-4000-8000-0000000000d2', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zz honey item', 1, null, 'zz', 'proposed', 'd8300000-0000-4000-8000-0000000000a1', null, null, 'zz-s82f-shop-000000002');
select pg_temp.as_user('d8300000-0000-4000-8000-0000000000a1');
select throws_ok($$select unit_cost from public.inventory_shopping_list$$, '42501', null, 'a cleaner cannot select unit_cost directly');
select throws_ok($$select supplier from public.inventory_shopping_list$$, '42501', null, 'nor supplier');
select throws_ok($$select estimated_cost from public.inventory_shopping_list$$, '42501', null, 'nor estimated_cost');
select throws_ok($$select * from public.inventory_shopping_list$$, '42501', null, 'nor select * (the dashboard must call get_shopping_list_v1)');
select lives_ok($$select id, item_name, quantity, status, reason from public.inventory_shopping_list$$, 'the non-cost columns stay readable (the staff module selects only those)');
insert into _t select 'sl_cl', public.get_shopping_list_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');
reset role;
select pg_temp.as_user('d8300000-0000-4000-8000-0000000000a4');
insert into _t select 'sl_fi', public.get_shopping_list_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');
reset role;
select ok((select jsonb_array_length(v->'rows') >= 2 and not (v::text ~ '(estimated_cost|unit_cost|supplier|ZZ Supplier)') from _t where k = 'sl_cl'), 'get_shopping_list_v1 as a cleaner: the rows, no cost key and no supplier');
select ok((select (r->>'unit_cost')::numeric = 55 and r->>'supplier' = 'ZZ Supplier' and (r->>'estimated_cost')::numeric = 99 from _t, jsonb_array_elements(v->'rows') r where k = 'sl_fi' and r->>'id' = 'd8300000-0000-4000-8000-0000000000d1'),
  'as a finance session the same call carries the costs');
-- save_shopping_item_v1
select pg_temp.as_user('d8300000-0000-4000-8000-0000000000a1');
insert into _t select 'sv_new', public.save_shopping_item_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', '{"item_name":"Zz new thing","quantity":3}'::jsonb, 'zz-s82f-save-0000000001');
insert into _t select 'sv_own', public.save_shopping_item_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', '{"id":"d8300000-0000-4000-8000-0000000000d2","quantity":4,"reason":"zz more"}'::jsonb, 'zz-s82f-save-0000000002');
select throws_ok($$select public.save_shopping_item_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', '{"id":"d8300000-0000-4000-8000-0000000000d1","quantity":50}'::jsonb, 'zz-s82f-save-0000000003')$$, '42501', null, 'a cleaner cannot change the quantity of someone else''s row');
select throws_ok($$select public.save_shopping_item_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', '{"id":"d8300000-0000-4000-8000-0000000000d1","status":"cancelled"}'::jsonb, 'zz-s82f-save-0000000004')$$, '42501', null, 'nor cancel it');
select throws_ok($$select public.save_shopping_item_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', '{"id":"d8300000-0000-4000-8000-0000000000d1","status":"proposed"}'::jsonb, 'zz-s82f-save-0000000005')$$, '42501', null, 'nor set it back to proposed');
select throws_ok($$select public.save_shopping_item_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', '{"id":"d8300000-0000-4000-8000-0000000000d2","approval_note":"fine"}'::jsonb, 'zz-s82f-save-0000000006')$$, '42501', null, 'nor write an approval note on her own row');
select throws_ok($$select public.save_shopping_item_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', '{"id":"d8300000-0000-4000-8000-0000000000d2","status":"approved"}'::jsonb, 'zz-s82f-save-0000000007')$$, '42501', null, 'nor approve her own row (unchanged)');
insert into _t select 'sv_cancel', public.save_shopping_item_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', '{"id":"d8300000-0000-4000-8000-0000000000d2","status":"cancelled"}'::jsonb, 'zz-s82f-save-0000000008');
reset role;
select ok((select (v->>'ok')::boolean from _t where k = 'sv_new') and (select proposed_by from public.inventory_shopping_list where id = (select (v->>'id')::uuid from _t where k = 'sv_new')) = 'd8300000-0000-4000-8000-0000000000a1', 'a cleaner can still add a row');
select ok((select (v->>'ok')::boolean from _t where k = 'sv_own') and (select quantity from public.inventory_shopping_list where id = 'd8300000-0000-4000-8000-0000000000d2') = 4, 'and edit her own proposed row');
select is((select status from public.inventory_shopping_list where id = 'd8300000-0000-4000-8000-0000000000d2'), 'cancelled', 'and cancel it');
select is((select quantity from public.inventory_shopping_list where id = 'd8300000-0000-4000-8000-0000000000d1'), 2::numeric, 'while the admin''s row was never touched');
select pg_temp.as_user('d8300000-0000-4000-8000-0000000000a5');
insert into _t select 'sv_owner', public.save_shopping_item_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', '{"id":"d8300000-0000-4000-8000-0000000000d2","status":"proposed","quantity":9}'::jsonb, 'zz-s82f-save-0000000009');
insert into _t select 'sv_approve', public.save_shopping_item_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', '{"id":"d8300000-0000-4000-8000-0000000000d1","status":"approved","approval_note":"ok"}'::jsonb, 'zz-s82f-save-0000000010');
reset role;
select ok((select (v->>'ok')::boolean from _t where k = 'sv_owner') and (select status = 'proposed' and quantity = 9 from public.inventory_shopping_list where id = 'd8300000-0000-4000-8000-0000000000d2'), 'the owner can edit and re-open anyone''s row');
select is((select status from public.inventory_shopping_list where id = 'd8300000-0000-4000-8000-0000000000d1'), 'approved', 'and approve it');

select * from finish();
rollback;
