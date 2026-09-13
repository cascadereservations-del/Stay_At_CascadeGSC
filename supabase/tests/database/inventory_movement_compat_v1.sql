begin;
select plan(10);

select has_column('public','inventory_items','movement_controlled_at','baseline flag column exists');
select has_function('public','reconcile_inventory_baseline_v1',array['uuid','numeric','text','text'],'baseline RPC exists');
select has_function('public','record_inventory_receipt_v1',array['uuid','numeric','numeric','text','date','text','uuid','text'],'receipt RPC exists');

insert into public.properties(id,name,is_active) values('e1000000-0000-4000-8000-0000000000c1','Synthetic Stock',true);
insert into auth.users(id) values('e2000000-0000-4000-8000-0000000000c1');
insert into public.staff_access_profiles(user_id,role) values('e2000000-0000-4000-8000-0000000000c1','admin');
insert into public.staff_property_access(user_id,property_id) values('e2000000-0000-4000-8000-0000000000c1','e1000000-0000-4000-8000-0000000000c1');
insert into public.inventory_items(id,property_id,name,category,unit,qty_on_hand,is_consumable,is_active,units_per_purchase) values('e4000000-0000-4000-8000-0000000000c1','e1000000-0000-4000-8000-0000000000c1','Toilet paper','bath','roll',7,true,true,1);
select set_config('request.jwt.claims', json_build_object('sub','e2000000-0000-4000-8000-0000000000c1','role','authenticated','aal','aal2','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role','authenticated',true);

-- Acceptance: opening 10, receipt 5, usage 3 -> 12; replaying the usage leaves 12.
select is((public.reconcile_inventory_baseline_v1('e4000000-0000-4000-8000-0000000000c1',10,'Counted on shelf','key-000000000000-baseline')->>'after'),'10','baseline sets 10');
select ok((public.record_inventory_receipt_v1('e4000000-0000-4000-8000-0000000000c1',5,20,'SM','2026-09-01',null,null,'key-000000000000-receipt-1')->>'ok')::boolean,'receipt of 5 recorded');
select ok((public.record_inventory_usage('e1000000-0000-4000-8000-0000000000c1','2026-09-02','Honey',null,'[{"item_id":"e4000000-0000-4000-8000-0000000000c1","used_qty":3,"usage_key":"usage-abc-1"}]')->>'ok')::boolean,'usage of 3 recorded');
-- Direct table reads run as the test owner: rehearsal copies are restored from a
-- --no-acl backup, so table grants do not exist there. RPC calls stay authenticated.
reset role;
select is((select qty_on_hand from public.inventory_items where id='e4000000-0000-4000-8000-0000000000c1'),12::numeric,'10 + 5 - 3 = 12');
select set_config('role','authenticated',true);
select ok((public.record_inventory_usage('e1000000-0000-4000-8000-0000000000c1','2026-09-02','Honey',null,'[{"item_id":"e4000000-0000-4000-8000-0000000000c1","used_qty":3,"usage_key":"usage-abc-1"}]')->>'ok')::boolean,'replayed usage accepted');
reset role;
select is((select qty_on_hand from public.inventory_items where id='e4000000-0000-4000-8000-0000000000c1'),12::numeric,'replay leaves 12');
select is((select count(*) from public.inventory_stock_movements where item_id='e4000000-0000-4000-8000-0000000000c1' and kind='usage'),1::bigint,'replay created no second usage movement');

select * from finish();
rollback;
