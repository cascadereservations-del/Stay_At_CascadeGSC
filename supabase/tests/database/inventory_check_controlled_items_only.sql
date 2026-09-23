-- Session 46: release inventory_check_controlled_items_only_20260923.
-- The movement comparison judges only movement-controlled items; an uncontrolled item whose count moved
-- after a baseline movement (the Liquid Hand Soap case) stays silent. Fixtures go with the closing rollback.

begin;
select plan(4);

insert into public.properties(id, name, is_active) values ('e1000000-0000-4000-8000-000000000046', 'Synthetic Inventory 46', true);
insert into auth.users(id) values ('e2000000-0000-4000-8000-000000000046');

create function pg_temp.chk() returns jsonb language sql as $$
  select e from jsonb_array_elements(public.health_checks_core_v1('e1000000-0000-4000-8000-000000000046', false)->'checks') e
   where e->>'check_key' = 'inventory_ledger_consistent'
$$;

-- Baseline movement says 0, a plain count write later says 1: the production case.
insert into public.inventory_items(id, property_id, name, category, qty_on_hand, is_active)
values ('e3000000-0000-4000-8000-000000000046', 'e1000000-0000-4000-8000-000000000046', 'Synthetic Soap', 'Toiletries', 1, true);
insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key)
values ('e3000000-0000-4000-8000-000000000046', 'e1000000-0000-4000-8000-000000000046', 'reconcile', 50, 0,
        'synthetic baseline', 'e2000000-0000-4000-8000-000000000046', 'synthetic-inventory-46-baseline');

select is(pg_temp.chk()->>'status', 'pass',
  'an item no ledger controls is not judged against an old baseline movement');

update public.inventory_items set movement_controlled_at = now() where id = 'e3000000-0000-4000-8000-000000000046';
select is(pg_temp.chk()->>'status', 'fail',
  'a movement-controlled item whose count disagrees with its last movement is found');
select is((pg_temp.chk()->'detail'->0->>'item'), 'Synthetic Soap',
  'and the finding names the item');

update public.inventory_items set qty_on_hand = 0 where id = 'e3000000-0000-4000-8000-000000000046';
select is(pg_temp.chk()->>'status', 'pass',
  'a movement-controlled item that agrees with its last movement is silent');

select * from finish();
rollback;
