-- Session 120, lane R: release s120_linen_stains_20261120. record_linen_stains_v1 and linen_stain_reports. Synthetic rows (uuids e8200000-...); everything rolls back.
-- Fixture rows and the reads run as the owner role (a --no-acl restore gives authenticated no table grants); only the RPC calls run as the staff roles.
-- NOT RUN when it was written (the builder has no database): the orchestrator's rehearsal is the first run.
begin;
select plan(50);

create function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'aal', 'aal1', 'iat', extract(epoch from now())::bigint)::text, true),
         set_config('role', 'authenticated', true)
$$;
grant execute on function pg_temp.as_user(uuid) to public;
create temp table _t(k text primary key, v jsonb);
grant all on _t to public;

insert into public.properties(id, name, is_active) values ('e8200000-0000-4000-8000-0000000000a1', 'Synthetic Linen A', true), ('e8200000-0000-4000-8000-0000000000b1', 'Synthetic Linen B', true);
insert into auth.users(id) values ('e8200000-0000-4000-8000-000000000001'), ('e8200000-0000-4000-8000-000000000002'), ('e8200000-0000-4000-8000-000000000003'), ('e8200000-0000-4000-8000-000000000004');
insert into public.staff_access_profiles(user_id, role) values ('e8200000-0000-4000-8000-000000000001', 'cleaner'), ('e8200000-0000-4000-8000-000000000003', 'laundry'), ('e8200000-0000-4000-8000-000000000004', 'cleaner');
insert into public.staff_property_access(user_id, property_id) values ('e8200000-0000-4000-8000-000000000001', 'e8200000-0000-4000-8000-0000000000a1'), ('e8200000-0000-4000-8000-000000000003', 'e8200000-0000-4000-8000-0000000000a1'), ('e8200000-0000-4000-8000-000000000004', 'e8200000-0000-4000-8000-0000000000a1');
-- W1 towel 10, W2 pillow case 1 (clamp), W3 sheet 5, C4 controlled 5 with a baseline movement, C8 controlled with NO movement, K5 consumable, X6 inactive, F7 in property B
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, units_per_purchase, movement_controlled_at) values
  ('e8200000-0000-4000-8000-0000000000c1', 'e8200000-0000-4000-8000-0000000000a1', 'zz Bath Towel', 'Bedroom', 'pc', 10, false, true, 1, null),
  ('e8200000-0000-4000-8000-0000000000c2', 'e8200000-0000-4000-8000-0000000000a1', 'zz Pillow Case', 'Bedroom', 'pc', 1, false, true, 1, null),
  ('e8200000-0000-4000-8000-0000000000c3', 'e8200000-0000-4000-8000-0000000000a1', 'zz Fitted Sheet', 'Bedroom', 'pc', 5, false, true, 1, null),
  ('e8200000-0000-4000-8000-0000000000c4', 'e8200000-0000-4000-8000-0000000000a1', 'zz C4 controlled sheet', 'Bedroom', 'pc', 5, false, true, 1, now()),
  ('e8200000-0000-4000-8000-0000000000c8', 'e8200000-0000-4000-8000-0000000000a1', 'zz C8 no ledger', 'Bedroom', 'pc', 5, false, true, 1, now()),
  ('e8200000-0000-4000-8000-0000000000c5', 'e8200000-0000-4000-8000-0000000000a1', 'zz K5 soap', 'Toiletries', 'pc', 5, true, true, 1, null),
  ('e8200000-0000-4000-8000-0000000000c6', 'e8200000-0000-4000-8000-0000000000a1', 'zz X6 retired towel', 'Bedroom', 'pc', 5, false, false, 1, null),
  ('e8200000-0000-4000-8000-0000000000c7', 'e8200000-0000-4000-8000-0000000000b1', 'zz F7 other house', 'Bedroom', 'pc', 5, false, true, 1, null);
insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key) values
  ('e8200000-0000-4000-8000-0000000000c4', 'e8200000-0000-4000-8000-0000000000a1', 'reconcile', 5, 5, 'zz baseline count', 'e8200000-0000-4000-8000-000000000001', 'zz-s120r-baseline-c4-0001');

select ok(has_function_privilege('authenticated', 'public.record_linen_stains_v1(uuid,date,text,text,jsonb)', 'execute')
      and not has_function_privilege('anon', 'public.record_linen_stains_v1(uuid,date,text,text,jsonb)', 'execute')
      and not has_function_privilege('service_role', 'public.record_linen_stains_v1(uuid,date,text,text,jsonb)', 'execute'),
  'grants: authenticated only');

select pg_temp.as_user('e8200000-0000-4000-8000-000000000002');
select throws_ok($$select public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-refused-1', '[{"item_id":"e8200000-0000-4000-8000-0000000000c1","qty":1,"outcome":"cleaned"}]'::jsonb)$$, '42501', 'staff access denied', 'a user with no staff profile is refused');
reset role;
select pg_temp.as_user('e8200000-0000-4000-8000-000000000003');
select throws_ok($$select public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-refused-2', '[{"item_id":"e8200000-0000-4000-8000-0000000000c1","qty":1,"outcome":"cleaned"}]'::jsonb)$$, '42501', 'staff access denied', 'laundry has no submit_cleaning and is refused');
reset role;
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000b1', public.manila_today(), 'Honey', 'zz-s120r-key-refused-3', '[{"item_id":"e8200000-0000-4000-8000-0000000000c7","qty":1,"outcome":"cleaned"}]'::jsonb)$$, '42501', 'staff access denied', 'a cleaner of house A is refused on house B');
reset role;
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
insert into _t select 'k1', public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-cleaned-1', '[{"item_id":"e8200000-0000-4000-8000-0000000000c1","qty":2,"outcome":"cleaned"}]'::jsonb);
reset role;
select is((select (v->>'ok') || '/' || (v->>'replayed') from _t where k = 'k1'), 'true/false', 'cleaned: ok and not a replay');
select is((select qty_on_hand from public.inventory_items where id = 'e8200000-0000-4000-8000-0000000000c1'), 10::numeric, 'cleaned: stock does not change');
select ok((select count(*) = 1 and min(outcome) = 'cleaned' and min(qty) = 2 from public.linen_stain_reports where idempotency_key = 'zz-s120r-key-cleaned-1'), 'cleaned: one audit row with the outcome and the quantity');
select is((select count(*)::int from public.follow_up_tasks where source_kind = 'linen_replace' and source_ref like 'e8200000-0000-4000-8000-0000000000c1:%'), 0, 'cleaned: no task');
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
insert into _t select 'k2', public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-needs-1', '[{"item_id":"e8200000-0000-4000-8000-0000000000c1","qty":1,"outcome":"needs_replacing"}]'::jsonb);
reset role;
select is((select qty_on_hand from public.inventory_items where id = 'e8200000-0000-4000-8000-0000000000c1'), 9::numeric, 'needs replacing 1: stock 10 -> 9');
select is((select title from public.follow_up_tasks where source_kind = 'linen_replace' and source_ref like 'e8200000-0000-4000-8000-0000000000c1:%' and status = 'open'), 'Replace 1 zz Bath Towel, stained on ' || to_char(public.manila_today(), 'FMDD Mon'), 'needs replacing 1: the task reads in plain words');
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
insert into _t select 'k3', public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-needs-2', '[{"item_id":"e8200000-0000-4000-8000-0000000000c1","qty":2,"outcome":"needs_replacing"}]'::jsonb);
reset role;
select is((select qty_on_hand from public.inventory_items where id = 'e8200000-0000-4000-8000-0000000000c1'), 7::numeric, 'needs replacing 2 more: stock 9 -> 7');
select is((select count(*)::int from public.follow_up_tasks where source_kind = 'linen_replace' and source_ref like 'e8200000-0000-4000-8000-0000000000c1:%' and status = 'open'), 1, 'still ONE open task for the item');
select is((select title from public.follow_up_tasks where source_kind = 'linen_replace' and source_ref like 'e8200000-0000-4000-8000-0000000000c1:%' and status = 'open'), 'Replace 3 x zz Bath Towel, stained on ' || to_char(public.manila_today(), 'FMDD Mon'), 'the task adds the quantity up');
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
insert into _t select 'k3b', public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-needs-2', '[{"item_id":"e8200000-0000-4000-8000-0000000000c1","qty":2,"outcome":"needs_replacing"}]'::jsonb);
reset role;
select is((select v->>'replayed' from _t where k = 'k3b'), 'true', 'a replay says so');
select is((select qty_on_hand from public.inventory_items where id = 'e8200000-0000-4000-8000-0000000000c1'), 7::numeric, 'a replay leaves the stock at 7');
select is((select array_agg((a.before ->> 'qty_on_hand') || '>' || (a.after ->> 'qty_on_hand') order by (a.after ->> 'qty_on_hand')::numeric desc) from public.inventory_audit_log a where a.entity_id = 'e8200000-0000-4000-8000-0000000000c1' and a.action = 'linen_stain'), array['10.00>9.00', '9.00>7.00'], 'each stock change has one audit row, and the replay and the cleaned report add none');
select is((select count(*)::int from public.linen_stain_reports where idempotency_key = 'zz-s120r-key-needs-2'), 1, 'a replay writes no second audit row');
select pg_temp.as_user('e8200000-0000-4000-8000-000000000004');
select throws_ok($$select public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-needs-2', '[{"item_id":"e8200000-0000-4000-8000-0000000000c1","qty":2,"outcome":"needs_replacing"}]'::jsonb)$$, '22023', 'idempotency_key_reused', 'the same key from another person is refused');
reset role;
-- the same key with other rows is not a replay: it must not report success for a send that never happened
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-needs-2', '[{"item_id":"e8200000-0000-4000-8000-0000000000c1","qty":3,"outcome":"needs_replacing"}]'::jsonb)$$, '22023', 'idempotency_key_reused', 'same key, a different quantity: refused, not replayed');
reset role;
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-needs-2', '[{"item_id":"e8200000-0000-4000-8000-0000000000c1","qty":2,"outcome":"replaced"}]'::jsonb)$$, '22023', 'idempotency_key_reused', 'same key, a different outcome: refused');
reset role;
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-needs-2', '[{"item_id":"e8200000-0000-4000-8000-0000000000c1","qty":2,"outcome":"needs_replacing"},{"item_id":"e8200000-0000-4000-8000-0000000000c3","qty":1,"outcome":"cleaned"}]'::jsonb)$$, '22023', 'idempotency_key_reused', 'same key, an extra row: refused');
reset role;
select ok((select qty_on_hand from public.inventory_items where id = 'e8200000-0000-4000-8000-0000000000c1') = 7 and (select count(*) from public.linen_stain_reports where idempotency_key = 'zz-s120r-key-needs-2') = 1, 'the refused re-sends changed no stock and wrote no row');
-- the same rows in another order are the same send
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
insert into _t select 'o1', public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-order-01', '[{"item_id":"e8200000-0000-4000-8000-0000000000c1","qty":1,"outcome":"cleaned"},{"item_id":"e8200000-0000-4000-8000-0000000000c3","qty":1,"outcome":"cleaned"}]'::jsonb);
insert into _t select 'o2', public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-order-01', '[{"item_id":"e8200000-0000-4000-8000-0000000000c3","qty":1,"outcome":"cleaned"},{"item_id":"e8200000-0000-4000-8000-0000000000c1","qty":1,"outcome":"cleaned"}]'::jsonb);
reset role;
select is((select (v->>'replayed') || '/' || (v->>'rows') from _t where k = 'o2'), 'true/2', 'the same rows in another order replay');
select is((select count(*)::int from public.linen_stain_reports where idempotency_key = 'zz-s120r-key-order-01'), 2, 'and wrote nothing twice');
select ok((select count(*) > 0 and bool_and(char_length(rows_hash) = 64) from public.linen_stain_reports), 'every report row carries its send fingerprint');
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
insert into _t select 'k4', public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-replaced-1', '[{"item_id":"e8200000-0000-4000-8000-0000000000c3","qty":2,"outcome":"replaced"}]'::jsonb);
reset role;
select is((select qty_on_hand from public.inventory_items where id = 'e8200000-0000-4000-8000-0000000000c3'), 3::numeric, 'replaced: stock 5 -> 3');
select is((select count(*)::int from public.follow_up_tasks where source_kind = 'linen_replace' and source_ref like 'e8200000-0000-4000-8000-0000000000c3:%'), 0, 'replaced: no task');
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
insert into _t select 'k5', public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-clamp-001', '[{"item_id":"e8200000-0000-4000-8000-0000000000c2","qty":3,"outcome":"needs_replacing"}]'::jsonb);
reset role;
select is((select qty_on_hand from public.inventory_items where id = 'e8200000-0000-4000-8000-0000000000c2'), 0::numeric, 'clamp: 1 on the shelf, 3 reported, stock 0 and the cleaner is not refused');
select ok((select r.qty = 3 and r.stock_before = 1 and r.stock_after = 0 from public.linen_stain_reports r where r.idempotency_key = 'zz-s120r-key-clamp-001'), 'clamp: the audit row keeps the 3 reported and the stock it saw');
update public.follow_up_tasks set status = 'done', completed_at = now(), completion_note = 'bought' where source_kind = 'linen_replace' and source_ref like 'e8200000-0000-4000-8000-0000000000c1:%';
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
insert into _t select 'k6', public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-needs-3', '[{"item_id":"e8200000-0000-4000-8000-0000000000c1","qty":1,"outcome":"needs_replacing"}]'::jsonb);
reset role;
select is((select count(*)::int from public.follow_up_tasks where source_kind = 'linen_replace' and source_ref like 'e8200000-0000-4000-8000-0000000000c1:%'), 2, 'after the first task was closed a second one opens (generation 2)');
select is((select title from public.follow_up_tasks where source_kind = 'linen_replace' and source_ref like 'e8200000-0000-4000-8000-0000000000c1:%' and status = 'open'), 'Replace 1 zz Bath Towel, stained on ' || to_char(public.manila_today(), 'FMDD Mon'), 'and it counts only the new stain');
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
insert into _t select 'c1', public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-ctl-0001', '[{"item_id":"e8200000-0000-4000-8000-0000000000c4","qty":2,"outcome":"needs_replacing"}]'::jsonb);
reset role;
select is((select qty_on_hand from public.inventory_items where id = 'e8200000-0000-4000-8000-0000000000c4'), 3::numeric, 'controlled: stock 5 -> 3');
select ok((select m.kind = 'adjustment' and m.quantity_before = 5 and m.quantity_after = 3 from public.inventory_stock_movements m where m.item_id = 'e8200000-0000-4000-8000-0000000000c4' order by m.sequence_no desc limit 1), 'controlled: an adjustment movement 5 -> 3 (not usage)');
select ok((select r.movement_id = (select m.id from public.inventory_stock_movements m where m.item_id = 'e8200000-0000-4000-8000-0000000000c4' order by m.sequence_no desc limit 1) from public.linen_stain_reports r where r.idempotency_key = 'zz-s120r-key-ctl-0001'), 'controlled: the audit row points at its movement');
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-ctl-0002', '[{"item_id":"e8200000-0000-4000-8000-0000000000c8","qty":1,"outcome":"replaced"}]'::jsonb)$$, '22023', 'stock reconciliation required for zz C8 no ledger', 'a controlled item whose ledger is empty needs a count first');
reset role;
select is((select count(*)::int from public.linen_stain_reports where idempotency_key = 'zz-s120r-key-ctl-0002'), 0, 'and that refusal left no audit row');
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-val-0001', '[{"item_id":"e8200000-0000-4000-8000-0000000000c5","qty":1,"outcome":"cleaned"}]'::jsonb)$$, '22023', 'unknown linen item', 'a consumable is not linen');
reset role;
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-val-0002', '[{"item_id":"e8200000-0000-4000-8000-0000000000c6","qty":1,"outcome":"cleaned"}]'::jsonb)$$, '22023', 'unknown linen item', 'an inactive item is refused');
reset role;
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-val-0003', '[{"item_id":"e8200000-0000-4000-8000-0000000000c7","qty":1,"outcome":"cleaned"}]'::jsonb)$$, '22023', 'unknown linen item', 'an item of another house is refused');
reset role;
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-val-0004', '[{"item_id":"e8200000-0000-4000-8000-0000000000c1","qty":1,"outcome":"lost"}]'::jsonb)$$, '22023', 'each row needs item_id, a whole qty and an outcome', 'an unknown outcome is refused');
reset role;
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-val-0005', '[{"item_id":"e8200000-0000-4000-8000-0000000000c1","qty":0,"outcome":"cleaned"}]'::jsonb)$$, '22023', 'qty must be a whole number from 1 to 99', 'qty 0 is refused');
reset role;
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-val-0006', '[{"item_id":"e8200000-0000-4000-8000-0000000000c1","qty":1.5,"outcome":"cleaned"}]'::jsonb)$$, '22023', 'qty must be a whole number from 1 to 99', 'a fractional qty is refused');
reset role;
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-val-0007', '[]'::jsonb)$$, '22023', 'rows required (1 to 30)', 'no rows is refused');
reset role;
select pg_temp.as_user('e8200000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_linen_stains_v1('e8200000-0000-4000-8000-0000000000a1', public.manila_today(), 'Honey', 'zz-s120r-key-atomic-01', '[{"item_id":"e8200000-0000-4000-8000-0000000000c3","qty":1,"outcome":"needs_replacing"},{"item_id":"e8200000-0000-4000-8000-0000000000c5","qty":1,"outcome":"cleaned"}]'::jsonb)$$, '22023', 'unknown linen item', 'a bad second row refuses the whole submission');
reset role;
select ok((select qty_on_hand from public.inventory_items where id = 'e8200000-0000-4000-8000-0000000000c3') = 3 and not exists (select 1 from public.linen_stain_reports where idempotency_key = 'zz-s120r-key-atomic-01') and not exists (select 1 from public.follow_up_tasks where source_kind = 'linen_replace' and source_ref like 'e8200000-0000-4000-8000-0000000000c3:%'), 'and the good first row was rolled back: no stock change, audit row or task');
select is((select count(*)::int from public.inventory_usage where item_id in ('e8200000-0000-4000-8000-0000000000c1','e8200000-0000-4000-8000-0000000000c2','e8200000-0000-4000-8000-0000000000c3','e8200000-0000-4000-8000-0000000000c4')), 0, 'nothing was written to inventory_usage (KPI, cost and learning readers see no linen)');
select ok((select relrowsecurity from pg_class where oid = 'public.linen_stain_reports'::regclass) and not has_table_privilege('authenticated', 'public.linen_stain_reports', 'select, insert, update, delete') and not has_table_privilege('anon', 'public.linen_stain_reports', 'select, insert, update, delete') and not has_table_privilege('service_role', 'public.linen_stain_reports', 'select, insert, update, delete'), 'the audit table is closed: RLS on, no API grant');
select is((select count(*)::int from public.inventory_stock_movements where property_id = 'e8200000-0000-4000-8000-0000000000a1' and kind = 'usage'), 0, 'no usage movement was written for linen');

select is((select (v->>'rows') || '/' || (v->>'replayed') from _t where k = 'k3b'), '1/true', 'a replay returns the first result (one row) and not a second write');
select ok((select position('pg_advisory_xact_lock' in prosrc) > 0 and position('pg_advisory_xact_lock' in prosrc) < position('idempotency_key = p_idempotency_key' in prosrc) from pg_proc where oid = 'public.record_linen_stains_v1(uuid,date,text,text,jsonb)'::regprocedure), 'two taps at once: the key is locked before the replay check (a race waits, then replays; run twice from two sessions in the rehearsal to see it)');

select * from finish();
rollback;
